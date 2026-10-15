import Foundation

/// One git worktree. Reads parse git's machine formats; writes run the
/// matching porcelain command and throw `GitError` carrying git's own message.
///
/// Every method is safe to call from any task; none touches the main actor.
public struct Repository: Sendable, Hashable {
    /// Top-level directory of the worktree (`git rev-parse --show-toplevel`).
    public let root: URL
    /// `git rev-parse --absolute-git-dir` (a worktree's private git dir).
    public let gitDirectory: URL
    /// `git rev-parse --git-common-dir`, absolute (shared refs/objects for worktrees).
    public let commonDirectory: URL
    public let runner: GitRunner

    public init(root: URL, gitDirectory: URL, commonDirectory: URL, runner: GitRunner) {
        self.root = root
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
        self.runner = runner
    }

    public static func == (lhs: Repository, rhs: Repository) -> Bool { lhs.root == rhs.root }
    public func hash(into hasher: inout Hasher) { hasher.combine(root) }

    /// Resolves the worktree containing `url` (any subdirectory works).
    /// Throws `GitSetupError.notARepository` outside a worktree.
    public static func open(at url: URL, runner: GitRunner) async throws -> Repository {
        var directory = url.absoluteURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            directory = directory.deletingLastPathComponent()
        }
        let result: GitResult
        do {
            result = try await runner.run(
                ["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"],
                in: directory, isRead: true
            )
        } catch is GitError {
            throw GitSetupError.notARepository(url.path)
        }
        let lines = GitOutput.trimmedLines(result.stdout)
        guard lines.count == 3 else { throw GitSetupError.notARepository(url.path) }
        return Repository(
            root: URL(fileURLWithPath: lines[0], isDirectory: true),
            gitDirectory: URL(fileURLWithPath: lines[1], isDirectory: true),
            commonDirectory: URL(fileURLWithPath: absolutePath(lines[2], relativeTo: directory.path), isDirectory: true),
            runner: runner
        )
    }

    /// `path` made absolute against `base`, with "." and ".." resolved
    /// lexically (no symlink resolution, so /private stays /private).
    static func absolutePath(_ path: String, relativeTo base: String) -> String {
        let joined = path.hasPrefix("/") ? path : base + "/" + path
        var components: [Substring] = []
        for component in joined.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    // MARK: Reads

    /// HEAD, local and remote-tracking branches (with upstream and ahead/behind),
    /// tags (peeled), and remotes. Works in an empty repository.
    public func refs() async throws -> RefSnapshot {
        async let refData = read(["for-each-ref", "--format=\(RefParser.forEachRefFormat)", "refs/heads", "refs/remotes", "refs/tags"])
        async let symbolic = read(["symbolic-ref", "-q", "HEAD"], accepting: [0, 1, 128])
        async let headCommit = headCommitID()
        async let remoteData = read(["remote", "-v"])

        let remotes = RefParser.parseRemotes(try await remoteData.stdout)
        let parsed = RefParser.parseRefs(try await refData.stdout, remoteNames: remotes.map(\.name))
        let symbolicResult = try await symbolic
        let commit = try await headCommit

        let head: Head
        if symbolicResult.exitCode == 0 {
            let fullName = GitOutput.firstLine(symbolicResult.stdout)
            let name = fullName.hasPrefix("refs/heads/") ? String(fullName.dropFirst("refs/heads/".count)) : fullName
            head = commit == nil ? .unborn(name) : .branch(name)
        } else if let commit {
            head = .detached(commit)
        } else {
            head = .unborn("HEAD")
        }
        return RefSnapshot(
            head: head, headCommit: commit, localBranches: parsed.localBranches,
            remoteBranches: parsed.remoteBranches, tags: parsed.tags, remotes: remotes
        )
    }

    /// `git stash list`, newest first.
    public func stashes() async throws -> [Stash] {
        LogParser.parseStashes(try await read(["stash", "list", "-z", "--format=\(LogParser.stashFormat)"]).stdout)
    }

    /// Commits reachable from all local branches, remote-tracking branches, tags,
    /// HEAD and `extraTips` (stash bases), in `--date-order`, `limit` commits
    /// after skipping `skip`. Empty for a repository without commits.
    public func log(limit: Int, skip: Int, extraTips: [String]) async throws -> [Commit] {
        guard limit > 0 else { return [] }
        var arguments = [
            "log", "--date-order", "-z", "--format=\(LogParser.commitFormat)",
            "--max-count=\(limit)", "--skip=\(max(0, skip))",
            "--branches", "--remotes", "--tags",
        ]
        if try await headCommitID() != nil { arguments.append("HEAD") }
        arguments += extraTips
        arguments.append("--")
        return LogParser.parseCommits(try await read(arguments).stdout)
    }

    /// `git status --porcelain=v2` plus the operation git has paused, if any.
    public func status() async throws -> WorkingTreeStatus {
        let result = try await read(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"])
        return WorkingTreeStatus(
            entries: StatusParser.parseEntries(result.stdout),
            operation: StatusParser.operation(in: gitDirectory)
        )
    }

    /// Full message and changed files (vs first parent) of a commit or stash commit.
    public func commitDetail(_ id: String) async throws -> CommitDetail {
        let shown = try await read(["show", "-s", "-z", "--format=\(LogParser.detailFormat)", id, "--"])
        guard let (commit, message) = LogParser.parseDetail(shown.stdout) else {
            throw GitError(arguments: ["show", id], exitCode: 0, stdout: shown.stdoutString, stderr: "Unreadable commit \(id)")
        }
        var arguments = ["diff-tree", "-r", "-z", "-M", "--raw", "--numstat", "--no-commit-id"]
        if let parent = commit.parents.first {
            arguments += [parent, commit.id]
        } else {
            arguments += ["--root", commit.id]
        }
        let files = ChangedFileParser.parse(try await read(arguments).stdout)
        return CommitDetail(commit: commit, body: LogParser.body(ofMessage: message), files: files)
    }

    /// Files a stash changes, including its untracked files.
    public func stashFiles(_ index: Int) async throws -> [ChangedFile] {
        let stash = "stash@{\(index)}"
        let changes = ["diff-tree", "-r", "-z", "-M", "--raw", "--numstat", "--no-commit-id"]
        async let tracked = read(changes + ["\(stash)^1", stash])
        // The untracked-files commit (third parent) exists only for stashes
        // made with --include-untracked; git exits 128 otherwise.
        async let untracked = read(changes + ["--root", "\(stash)^3"], accepting: [0, 128])
        var files = ChangedFileParser.parse(try await tracked.stdout)
        let untrackedResult = try await untracked
        if untrackedResult.exitCode == 0 {
            files += ChangedFileParser.parse(untrackedResult.stdout, kindOverride: .untracked)
        }
        return files
    }

    /// Parsed unified diff for `target`; one `FileDiff` per file.
    public func diff(_ target: DiffTarget, contextLines: Int = 3, ignoreWhitespace: Bool = false) async throws -> [FileDiff] {
        var options = ["--no-color", "--no-ext-diff", "--no-textconv", "-U\(max(0, contextLines))", "-M"]
        if ignoreWhitespace { options.append("--ignore-all-space") }
        func pathspec(_ path: String?) -> [String] {
            ["--"] + (path.map { [GitOutput.literal($0)] } ?? [])
        }

        switch target {
        case let .staged(path):
            return DiffParser.parse(try await read(["diff", "--cached"] + options + pathspec(path)).stdout)

        case let .unstaged(path):
            let untracked = try await read(["ls-files", "-z", "--others", "--", GitOutput.literal(path)])
            if !GitOutput.nulFields(untracked.stdout).isEmpty {
                let result = try await read(["diff", "--no-index"] + options + ["--", "/dev/null", path], accepting: [0, 1])
                return DiffParser.parse(result.stdout)
            }
            return DiffParser.parse(try await read(["diff"] + options + pathspec(path)).stdout)

        case let .commit(id, path):
            let parents = try await parentIDs(of: id)
            let base: String
            if let parent = parents.first {
                base = parent
            } else {
                base = try await emptyTreeID()
            }
            return DiffParser.parse(try await read(["diff"] + options + [base, id] + pathspec(path)).stdout)

        case let .stash(index, path):
            let stash = "stash@{\(index)}"
            let parents = try await parentIDs(of: stash)
            guard let base = parents.first else { return [] }
            var files = DiffParser.parse(try await read(["diff"] + options + [base, stash] + pathspec(path)).stdout)
            if parents.count >= 3 {
                let emptyTree = try await emptyTreeID()
                files += DiffParser.parse(try await read(["diff"] + options + [emptyTree, parents[2]] + pathspec(path)).stdout)
            }
            return files
        }
    }

    // MARK: Staging and committing

    public func stage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await write(["add", "-A", "--"] + paths.map(GitOutput.literal))
    }

    public func stageAll() async throws {
        try await write(["add", "-A"])
    }

    public func unstage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let pathspecs = paths.map(GitOutput.literal)
        if try await headCommitID() == nil {
            try await write(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "--"] + pathspecs)
        } else {
            try await write(["reset", "-q", "HEAD", "--"] + pathspecs)
        }
    }

    public func unstageAll() async throws {
        if try await headCommitID() == nil {
            try await write(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "--", "."])
        } else {
            try await write(["reset", "-q"])
        }
    }

    /// Drops worktree changes; untracked paths are deleted.
    public func discard(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let pathspecs = paths.map(GitOutput.literal)
        let untrackedResult = try await read(["ls-files", "-z", "--others", "--exclude-standard", "--"] + pathspecs)
        let untracked = GitOutput.nulFields(untrackedResult.stdout)
        let untrackedSet = Set(untracked)
        // A path given as a directory of untracked files is fully untracked.
        let tracked = paths.filter { path in
            !untrackedSet.contains(path) && !untracked.contains(where: { $0.hasPrefix(path.hasSuffix("/") ? path : path + "/") })
        }
        if !tracked.isEmpty {
            try await write(["checkout", "-q", "--"] + tracked.map(GitOutput.literal))
        }
        try removeUntracked(untracked)
    }

    /// Applies one hunk of `file` (as produced by `diff`). `.unstaged` diffs:
    /// stage (to the index) or discard (reverse, worktree). `.staged` diffs:
    /// unstage (reverse, index).
    public func stageHunk(_ hunk: DiffHunk, of file: FileDiff) async throws {
        if file.kind == .added, let path = file.newPath {
            // An untracked file: record it as intent-to-add so the new-file
            // patch applies to the index.
            try await write(["add", "-N", "--", GitOutput.literal(path)])
        }
        try await apply(PatchBuilder.patch(for: hunk, of: file), options: ["--cached"])
    }

    public func unstageHunk(_ hunk: DiffHunk, of file: FileDiff) async throws {
        try await apply(PatchBuilder.patch(for: hunk, of: file), options: ["--cached", "--reverse"])
    }

    public func discardHunk(_ hunk: DiffHunk, of file: FileDiff) async throws {
        try await apply(PatchBuilder.patch(for: hunk, of: file), options: ["--reverse"])
    }

    /// Commits the index with `message` (passed on stdin). Hooks and signing
    /// follow the user's git config. Returns the new commit id.
    @discardableResult
    public func commit(message: String, amend: Bool) async throws -> String {
        var arguments = ["commit", "-F", "-"]
        if amend { arguments.append("--amend") }
        try await runner.run(arguments, in: root, stdin: Data(message.utf8))
        return GitOutput.firstLine(try await read(["rev-parse", "HEAD"]).stdout)
    }

    /// Full message of HEAD, for prefilling an amend.
    public func headMessage() async throws -> String {
        let message = try await read(["log", "-1", "--format=%B", "HEAD", "--"]).stdoutString
        return message.trimmingCharacters(in: .newlines)
    }

    // MARK: Branches and checkout

    public func checkout(branch name: String) async throws {
        try await write(["switch", name])
    }

    /// Detached checkout of a commit.
    public func checkout(commit id: String) async throws {
        try await write(["switch", "--detach", id])
    }

    /// Creates (or switches to) a local branch tracking `remoteBranch` ("origin/x").
    public func checkoutTracking(remoteBranch: String, localName: String) async throws {
        let exists = try await read(["show-ref", "--verify", "--quiet", "refs/heads/\(localName)"], accepting: [0, 1])
        if exists.exitCode == 0 {
            try await write(["switch", localName])
        } else {
            try await write(["switch", "-c", localName, "--track", remoteBranch])
        }
    }

    public func createBranch(_ name: String, at startPoint: String?, checkout: Bool) async throws {
        let arguments = checkout ? ["switch", "-c", name] : ["branch", name]
        try await write(arguments + (startPoint.map { [$0] } ?? []))
    }

    public func deleteBranch(_ name: String, force: Bool) async throws {
        try await write(["branch", force ? "-D" : "-d", name])
    }

    public func deleteRemoteBranch(remote: String, branch: String) async throws {
        try await write(["push", remote, "--delete", "refs/heads/\(branch)"])
    }

    public func renameBranch(_ name: String, to newName: String) async throws {
        try await write(["branch", "-m", name, newName])
    }

    public func setUpstream(of branch: String, to upstream: String) async throws {
        try await write(["branch", "--set-upstream-to=\(upstream)", branch])
    }

    // MARK: History rewriting and integration

    /// Merges `ref` into HEAD (`--no-edit`). Conflicts leave a paused merge and
    /// throw; `status().operation` then reports it.
    public func merge(_ ref: String, mode: MergeMode) async throws {
        var arguments = ["merge", "--no-edit"]
        switch mode {
        case .fastForwardIfPossible: break
        case .fastForwardOnly: arguments.append("--ff-only")
        case .noFastForward: arguments.append("--no-ff")
        }
        try await write(arguments + [ref])
    }

    public func rebase(onto ref: String) async throws {
        try await write(["rebase", ref])
    }

    /// Merge commits are picked/reverted against their first parent (`-m 1`).
    public func cherryPick(_ id: String) async throws {
        let mainline = try await parentIDs(of: id).count > 1 ? ["-m", "1"] : []
        try await write(["cherry-pick"] + mainline + [id])
    }

    public func revert(_ id: String) async throws {
        let mainline = try await parentIDs(of: id).count > 1 ? ["-m", "1"] : []
        try await write(["revert", "--no-edit"] + mainline + [id])
    }

    public func reset(to id: String, mode: ResetMode) async throws {
        try await write(["reset", "-q", "--\(mode.rawValue)", id])
    }

    /// Continue/abort/skip whatever `status().operation` reports. Continue never
    /// opens an editor (keeps git's prepared message).
    public func continueOperation() async throws {
        let noEditor = ["-c", "core.editor=true"]
        switch try await pausedOperation("continue") {
        case .merge: try await write(noEditor + ["commit", "--no-edit"])
        case .rebase: try await write(noEditor + ["rebase", "--continue"])
        case .cherryPick: try await write(noEditor + ["cherry-pick", "--continue"])
        case .revert: try await write(noEditor + ["revert", "--continue"])
        }
    }

    public func abortOperation() async throws {
        switch try await pausedOperation("abort") {
        case .merge: try await write(["merge", "--abort"])
        case .rebase: try await write(["rebase", "--abort"])
        case .cherryPick: try await write(["cherry-pick", "--abort"])
        case .revert: try await write(["revert", "--abort"])
        }
    }

    public func skipOperation() async throws {
        switch try await pausedOperation("skip") {
        case .merge:
            throw GitError(arguments: ["merge", "--skip"], exitCode: 1, stdout: "", stderr: "A merge cannot skip a commit; continue or abort it.")
        case .rebase: try await write(["rebase", "--skip"])
        case .cherryPick: try await write(["cherry-pick", "--skip"])
        case .revert: try await write(["revert", "--skip"])
        }
    }

    /// Resolves a conflicted path with one side (`checkout --ours/--theirs`, or
    /// `rm` when that side deleted it) and stages the result.
    public func resolveConflict(path: String, side: ConflictSide) async throws {
        let pathspec = GitOutput.literal(path)
        let result = try await read(["status", "--porcelain=v2", "-z", "--untracked-files=no", "--", pathspec])
        let conflict = StatusParser.parseEntries(result.stdout).first { $0.path == path }?.conflict
        let sideDeleted: Bool = switch (side, conflict) {
        case (.ours, .deletedByUs?), (.ours, .bothDeleted?), (.ours, .addedByThem?): true
        case (.theirs, .deletedByThem?), (.theirs, .bothDeleted?), (.theirs, .addedByUs?): true
        default: false
        }
        if sideDeleted {
            try await write(["rm", "-q", "--", pathspec])
        } else {
            try await write(["checkout", side == .ours ? "--ours" : "--theirs", "--", pathspec])
            try await write(["add", "--", pathspec])
        }
    }

    // MARK: Tags

    /// Annotated when `message` is non-nil.
    public func createTag(_ name: String, at id: String, message: String?) async throws {
        if let message {
            try await runner.run(["tag", "-a", name, "-F", "-", id], in: root, stdin: Data(message.utf8))
        } else {
            try await write(["tag", name, id])
        }
    }

    public func deleteTag(_ name: String) async throws {
        try await write(["tag", "-d", name])
    }

    public func pushTag(_ name: String, remote: String) async throws {
        try await write(["push", remote, "refs/tags/\(name)"])
    }

    public func deleteRemoteTag(_ name: String, remote: String) async throws {
        try await write(["push", remote, "--delete", "refs/tags/\(name)"])
    }

    // MARK: Stashes

    public func stash(message: String?, includeUntracked: Bool) async throws {
        var arguments = ["stash", "push"]
        if let message, !message.isEmpty { arguments += ["-m", message] }
        if includeUntracked { arguments.append("--include-untracked") }
        try await write(arguments)
    }

    public func applyStash(_ index: Int) async throws {
        try await write(["stash", "apply", "stash@{\(index)}"])
    }

    public func popStash(_ index: Int) async throws {
        try await write(["stash", "pop", "stash@{\(index)}"])
    }

    public func dropStash(_ index: Int) async throws {
        try await write(["stash", "drop", "stash@{\(index)}"])
    }

    // MARK: Remotes

    /// `git fetch --prune` of one remote, or `--all` when nil.
    public func fetch(remote: String?, onProgress: @escaping @Sendable (String) -> Void) async throws {
        let target = remote.map { [$0] } ?? ["--all"]
        try await runner.stream(["fetch", "--prune", "--progress"] + target, in: root, onProgress: onProgress)
    }

    public func pull(mode: PullMode, onProgress: @escaping @Sendable (String) -> Void) async throws {
        let modeFlag = switch mode {
        case .fastForwardIfPossible: "--ff"
        case .fastForwardOnly: "--ff-only"
        case .rebase: "--rebase"
        }
        try await runner.stream(["pull", modeFlag, "--no-edit", "--progress"], in: root, onProgress: onProgress)
    }

    /// Pushes `branch` to `remoteBranch` (default: the same name) on `remote`.
    /// `setUpstream` adds `--set-upstream`; `forceWithLease` adds `--force-with-lease`.
    public func push(
        branch: String, remote: String, remoteBranch: String? = nil, setUpstream: Bool, forceWithLease: Bool,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {
        var arguments = ["push", "--progress"]
        if setUpstream { arguments.append("--set-upstream") }
        if forceWithLease { arguments.append("--force-with-lease") }
        // Full refs so a tag with the branch's name never makes the refspec ambiguous.
        let refspec = "refs/heads/\(branch):refs/heads/\(remoteBranch ?? branch)"
        try await runner.stream(arguments + [remote, refspec], in: root, onProgress: onProgress)
    }
}

// MARK: - Helpers

extension Repository {
    @discardableResult
    func read(_ arguments: [String], accepting codes: Set<Int32> = [0]) async throws -> GitResult {
        try await runner.run(arguments, in: root, isRead: true, acceptedExitCodes: codes)
    }

    @discardableResult
    func write(_ arguments: [String]) async throws -> GitResult {
        try await runner.run(arguments, in: root)
    }

    /// The commit HEAD points at; nil on an unborn branch.
    func headCommitID() async throws -> String? {
        let result = try await read(["rev-parse", "-q", "--verify", "HEAD^{commit}"], accepting: [0, 1, 128])
        let id = GitOutput.firstLine(result.stdout)
        return result.exitCode == 0 && !id.isEmpty ? id : nil
    }

    func parentIDs(of revision: String) async throws -> [String] {
        let result = try await read(["rev-list", "--parents", "-n", "1", revision, "--"])
        return Array(GitOutput.firstLine(result.stdout).split(separator: " ").dropFirst().map(String.init))
    }

    /// The empty tree's id in this repository's hash (SHA-1 or SHA-256).
    func emptyTreeID() async throws -> String {
        GitOutput.firstLine(try await read(["hash-object", "-t", "tree", "/dev/null"]).stdout)
    }

    func apply(_ patch: Data, options: [String]) async throws {
        try await runner.run(
            ["apply"] + options + ["--recount", "--whitespace=nowarn", "-"], in: root, stdin: patch
        )
    }

    func pausedOperation(_ action: String) async throws -> OperationInProgress {
        guard let operation = StatusParser.operation(in: gitDirectory) else {
            throw GitError(
                arguments: [action], exitCode: 1, stdout: "",
                stderr: "There is no merge, rebase, cherry-pick or revert in progress."
            )
        }
        return operation
    }

    /// Deletes untracked files (relative to `root`) and then any directories
    /// that became empty, up to the worktree root.
    func removeUntracked(_ paths: [String]) throws {
        let fileManager = FileManager.default
        let rootPath = root.path
        var directories = Set<String>()
        for path in paths {
            let url = root.appendingPathComponent(path)
            if fileManager.fileExists(atPath: url.path) || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                try fileManager.removeItem(at: url)
            }
            var parent = url.deletingLastPathComponent()
            while parent.path.count > rootPath.count, parent.path.hasPrefix(rootPath + "/") {
                directories.insert(parent.path)
                parent = parent.deletingLastPathComponent()
            }
        }
        // Deepest first, so a parent is only removed after its children.
        for directory in directories.sorted(by: { $0.count > $1.count }) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: directory), contents.isEmpty {
                try? fileManager.removeItem(atPath: directory)
            }
        }
    }
}

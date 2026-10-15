import Foundation

/// One git worktree. Reads parse git's machine formats; writes run the
/// matching porcelain command and throw `GitError` carrying git's own message.
///
/// Interface contract (bodies implemented in Wave A, see docs/ARCHITECTURE.md).
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
        throw notImplemented(#function)
    }

    // MARK: Reads

    /// HEAD, local and remote-tracking branches (with upstream and ahead/behind),
    /// tags (peeled), and remotes. Works in an empty repository.
    public func refs() async throws -> RefSnapshot { throw notImplemented(#function) }

    /// `git stash list`, newest first.
    public func stashes() async throws -> [Stash] { throw notImplemented(#function) }

    /// Commits reachable from all local branches, remote-tracking branches, tags,
    /// HEAD and `extraTips` (stash bases), in `--date-order`, `limit` commits
    /// after skipping `skip`. Empty for a repository without commits.
    public func log(limit: Int, skip: Int, extraTips: [String]) async throws -> [Commit] {
        throw notImplemented(#function)
    }

    /// `git status --porcelain=v2` plus the operation git has paused, if any.
    public func status() async throws -> WorkingTreeStatus { throw notImplemented(#function) }

    /// Full message and changed files (vs first parent) of a commit or stash commit.
    public func commitDetail(_ id: String) async throws -> CommitDetail { throw notImplemented(#function) }

    /// Files a stash changes, including its untracked files.
    public func stashFiles(_ index: Int) async throws -> [ChangedFile] { throw notImplemented(#function) }

    /// Parsed unified diff for `target`; one `FileDiff` per file.
    public func diff(_ target: DiffTarget, contextLines: Int = 3, ignoreWhitespace: Bool = false) async throws -> [FileDiff] {
        throw notImplemented(#function)
    }

    // MARK: Staging and committing

    public func stage(paths: [String]) async throws { throw notImplemented(#function) }
    public func stageAll() async throws { throw notImplemented(#function) }
    public func unstage(paths: [String]) async throws { throw notImplemented(#function) }
    public func unstageAll() async throws { throw notImplemented(#function) }
    /// Drops worktree changes; untracked paths are deleted.
    public func discard(paths: [String]) async throws { throw notImplemented(#function) }

    /// Applies one hunk of `file` (as produced by `diff`). `.unstaged` diffs:
    /// stage (to the index) or discard (reverse, worktree). `.staged` diffs:
    /// unstage (reverse, index).
    public func stageHunk(_ hunk: DiffHunk, of file: FileDiff) async throws { throw notImplemented(#function) }
    public func unstageHunk(_ hunk: DiffHunk, of file: FileDiff) async throws { throw notImplemented(#function) }
    public func discardHunk(_ hunk: DiffHunk, of file: FileDiff) async throws { throw notImplemented(#function) }

    /// Commits the index with `message` (passed on stdin). Hooks and signing
    /// follow the user's git config. Returns the new commit id.
    @discardableResult
    public func commit(message: String, amend: Bool) async throws -> String { throw notImplemented(#function) }

    /// Full message of HEAD, for prefilling an amend.
    public func headMessage() async throws -> String { throw notImplemented(#function) }

    // MARK: Branches and checkout

    public func checkout(branch name: String) async throws { throw notImplemented(#function) }
    /// Detached checkout of a commit.
    public func checkout(commit id: String) async throws { throw notImplemented(#function) }
    /// Creates (or switches to) a local branch tracking `remoteBranch` ("origin/x").
    public func checkoutTracking(remoteBranch: String, localName: String) async throws { throw notImplemented(#function) }
    public func createBranch(_ name: String, at startPoint: String?, checkout: Bool) async throws { throw notImplemented(#function) }
    public func deleteBranch(_ name: String, force: Bool) async throws { throw notImplemented(#function) }
    public func deleteRemoteBranch(remote: String, branch: String) async throws { throw notImplemented(#function) }
    public func renameBranch(_ name: String, to newName: String) async throws { throw notImplemented(#function) }
    public func setUpstream(of branch: String, to upstream: String) async throws { throw notImplemented(#function) }

    // MARK: History rewriting and integration

    /// Merges `ref` into HEAD (`--no-edit`). Conflicts leave a paused merge and
    /// throw; `status().operation` then reports it.
    public func merge(_ ref: String, mode: MergeMode) async throws { throw notImplemented(#function) }
    public func rebase(onto ref: String) async throws { throw notImplemented(#function) }
    /// Merge commits are picked/reverted against their first parent (`-m 1`).
    public func cherryPick(_ id: String) async throws { throw notImplemented(#function) }
    public func revert(_ id: String) async throws { throw notImplemented(#function) }
    public func reset(to id: String, mode: ResetMode) async throws { throw notImplemented(#function) }

    /// Continue/abort/skip whatever `status().operation` reports. Continue never
    /// opens an editor (keeps git's prepared message).
    public func continueOperation() async throws { throw notImplemented(#function) }
    public func abortOperation() async throws { throw notImplemented(#function) }
    public func skipOperation() async throws { throw notImplemented(#function) }

    /// Resolves a conflicted path with one side (`checkout --ours/--theirs`, or
    /// `rm` when that side deleted it) and stages the result.
    public func resolveConflict(path: String, side: ConflictSide) async throws { throw notImplemented(#function) }

    // MARK: Tags

    /// Annotated when `message` is non-nil.
    public func createTag(_ name: String, at id: String, message: String?) async throws { throw notImplemented(#function) }
    public func deleteTag(_ name: String) async throws { throw notImplemented(#function) }
    public func pushTag(_ name: String, remote: String) async throws { throw notImplemented(#function) }
    public func deleteRemoteTag(_ name: String, remote: String) async throws { throw notImplemented(#function) }

    // MARK: Stashes

    public func stash(message: String?, includeUntracked: Bool) async throws { throw notImplemented(#function) }
    public func applyStash(_ index: Int) async throws { throw notImplemented(#function) }
    public func popStash(_ index: Int) async throws { throw notImplemented(#function) }
    public func dropStash(_ index: Int) async throws { throw notImplemented(#function) }

    // MARK: Remotes

    /// `git fetch --prune` of one remote, or `--all` when nil.
    public func fetch(remote: String?, onProgress: @escaping @Sendable (String) -> Void) async throws {
        throw notImplemented(#function)
    }

    public func pull(mode: PullMode, onProgress: @escaping @Sendable (String) -> Void) async throws {
        throw notImplemented(#function)
    }

    /// Pushes `branch` to `remote`. `setUpstream` adds `--set-upstream`;
    /// `forceWithLease` adds `--force-with-lease`.
    public func push(
        branch: String, remote: String, setUpstream: Bool, forceWithLease: Bool,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {
        throw notImplemented(#function)
    }
}

private func notImplemented(_ function: String) -> GitSetupError {
    .launchFailed("Repository.\(function) is not implemented yet")
}

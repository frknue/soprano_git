import AppKit
import SopranoGitCore

/// User-facing git flows shared by the toolbar, palette, key bindings and the
/// graph/sidebar context menus: each asks what it needs (Dialogs), runs the
/// repository call through `controller.run`, and moves selection/focus after.
///
/// Conflicts after a merge, rebase, cherry-pick, revert, pull or stash apply
/// are not failures: the activity notes the pause, the banner takes over, and
/// the working copy is selected with the commit panel focused.
@MainActor
enum GitActions {
    // MARK: Branches and checkout

    /// Branch: switch to it (remote → local tracking branch). Commit/tag: the
    /// local branch at that commit if exactly one, else detached after confirming.
    static func checkout(_ target: SelectionTarget, in workspace: any RepoWorkspace) async {
        let controller = workspace.controller
        guard let plan = CheckoutPlan.plan(for: target, refs: controller.refs) else { return }
        let outcome: Outcome
        switch plan {
        case let .switchTo(name):
            outcome = await perform("Checkout \(name)", in: workspace) { repo, _ in
                try await repo.checkout(branch: name)
            }
        case let .track(remoteBranch, localName):
            outcome = await perform("Checkout \(localName)", in: workspace) { repo, _ in
                try await repo.checkoutTracking(remoteBranch: remoteBranch, localName: localName)
            }
        case let .detach(id, label):
            let confirmed = await Dialogs.confirm(
                title: "Checkout \(label)",
                message: "HEAD will be detached at \(String(id.prefix(7))): new commits won't belong to any branch until you create one.",
                confirmTitle: "Checkout Detached",
                in: workspace.window
            )
            guard confirmed else { return }
            outcome = await perform("Checkout \(label)", in: workspace) { repo, _ in
                try await repo.checkout(commit: id)
            }
        }
        if outcome == .succeeded { revealHead(in: workspace) }
    }

    /// Prompts for a name; creates at the target's commit (HEAD when nil) and checks it out.
    static func createBranch(at target: SelectionTarget?, in workspace: any RepoWorkspace) async {
        let controller = workspace.controller
        let refs = controller.refs
        let existing = refs.localBranches.map(\.name)
        var startPoint: String?
        var startLabel = "HEAD (\(RefNames.current(refs)))"
        var initialValue = ""
        switch target {
        case let .branch(branch)?:
            startPoint = branch.fullName
            startLabel = branch.name
            if branch.isRemote {
                let localName = RefNames.localName(of: branch)
                if !existing.contains(localName) { initialValue = localName }
            }
        case let .tag(tag)?:
            startPoint = tag.target
            startLabel = tag.name
        case let .commit(id)?:
            startPoint = id
            startLabel = commitLabel(id, in: controller)
        case .workingCopy?, .stash?, nil:
            break
        }
        guard let name = await Dialogs.prompt(
            title: "Create Branch",
            message: "Starting at \(startLabel). The new branch is checked out.",
            placeholder: "feature/name",
            initialValue: initialValue,
            confirmTitle: "Create",
            validate: { RefNameRules.validate($0, kind: .branch, existing: existing) },
            in: workspace.window
        ) else { return }
        let start = startPoint
        let outcome = await perform("Create Branch \(name)", in: workspace) { repo, _ in
            try await repo.createBranch(name, at: start, checkout: true)
        }
        if outcome == .succeeded { revealHead(in: workspace) }
    }

    static func renameBranch(_ branch: Branch, in workspace: any RepoWorkspace) async {
        guard !branch.isRemote else { return }
        let existing = workspace.controller.refs.localBranches.map(\.name).filter { $0 != branch.name }
        guard let name = await Dialogs.prompt(
            title: "Rename Branch",
            message: "New name for “\(branch.name)”.",
            initialValue: branch.name,
            confirmTitle: "Rename",
            validate: { value in
                value == branch.name ? "Enter a new name." : RefNameRules.validate(value, kind: .branch, existing: existing)
            },
            in: workspace.window
        ) else { return }
        let oldName = branch.name
        await perform("Rename \(oldName) to \(name)", in: workspace) { repo, _ in
            try await repo.renameBranch(oldName, to: name)
        }
    }

    /// Branch (local, or on its remote), tag, or stash, after confirming.
    static func delete(_ target: SelectionTarget, in workspace: any RepoWorkspace) async {
        guard ActionRules.canDelete(target) else { return }
        switch target {
        case let .branch(branch) where !branch.isRemote:
            await deleteLocalBranch(branch, in: workspace)
        case let .branch(branch):
            await deleteRemoteBranch(branch, in: workspace)
        case let .tag(tag):
            await deleteTag(tag, in: workspace)
        case let .stash(stash):
            let confirmed = await Dialogs.confirm(
                title: "Drop \(stash.reference)",
                message: "Deletes the stash “\(stash.message)”. Its changes can't be recovered from the app.",
                confirmTitle: "Drop",
                isDestructive: true,
                in: workspace.window
            )
            guard confirmed else { return }
            let index = stash.index
            await perform("Drop \(stash.reference)", in: workspace) { repo, _ in
                try await repo.dropStash(index)
            }
        case .commit, .workingCopy:
            break
        }
    }

    private static func deleteLocalBranch(_ branch: Branch, in workspace: any RepoWorkspace) async {
        let remoteNote = branch.upstream.map { " Its remote branch \($0) stays." } ?? ""
        let confirmed = await Dialogs.confirm(
            title: "Delete \(branch.name)",
            message: "Deletes the local branch “\(branch.name)”.\(remoteNote)",
            confirmTitle: "Delete",
            isDestructive: true,
            in: workspace.window
        )
        guard confirmed else { return }
        let name = branch.name
        let outcome = await perform("Delete Branch \(name)", in: workspace, intercept: notFullyMerged) { repo, _ in
            try await repo.deleteBranch(name, force: false)
        }
        guard case .intercepted = outcome else { return }
        let choice = await Dialogs.choose(
            title: "\(name) Is Not Fully Merged",
            message: "“\(name)” has commits that aren't on HEAD or its upstream. Force deleting drops them unless another ref points at them.",
            options: [
                DialogOption(title: "Keep Branch", detail: "Leave “\(name)” as it is", key: "k"),
                DialogOption(title: "Force Delete", detail: "Delete “\(name)” and its unmerged commits", key: "f", isDestructive: true),
            ],
            in: workspace.window
        )
        guard choice == 1 else { return }
        await perform("Force Delete Branch \(name)", in: workspace) { repo, _ in
            try await repo.deleteBranch(name, force: true)
        }
    }

    private static func deleteRemoteBranch(_ branch: Branch, in workspace: any RepoWorkspace) async {
        guard let remote = branch.remoteName else { return }
        let name = RefNames.localName(of: branch)
        let confirmed = await Dialogs.confirm(
            title: "Delete \(name) on \(remote)",
            message: "Deletes the branch “\(name)” on \(remote) for everyone who uses it. A local branch of that name stays.",
            confirmTitle: "Delete on \(remote)",
            isDestructive: true,
            in: workspace.window
        )
        guard confirmed else { return }
        await perform("Delete \(branch.name)", in: workspace) { repo, _ in
            try await repo.deleteRemoteBranch(remote: remote, branch: name)
        }
    }

    private static func deleteTag(_ tag: Tag, in workspace: any RepoWorkspace) async {
        let remotes = RefNames.remotes(workspace.controller.refs)
        var options = [DialogOption(title: "Delete Locally", detail: "Remove the tag from this repository only", key: "l")]
        for (index, remote) in remotes.enumerated() {
            options.append(DialogOption(
                title: "Delete Locally and on \(remote)",
                detail: "Also remove it from \(remote) for everyone",
                key: remotes.count == 1 ? "r" : (index < 9 ? String(index + 1) : nil),
                isDestructive: true
            ))
        }
        guard let choice = await Dialogs.choose(
            title: "Delete Tag \(tag.name)",
            options: options,
            in: workspace.window
        ) else { return }
        let name = tag.name
        let remote = choice > 0 ? remotes[choice - 1] : nil
        let title = remote.map { "Delete Tag \(name) on \($0)" } ?? "Delete Tag \(name)"
        await perform(title, in: workspace) { repo, _ in
            // Remote first, so a failed remote delete keeps the local tag to retry with.
            if let remote { try await repo.deleteRemoteTag(name, remote: remote) }
            try await repo.deleteTag(name)
        }
    }

    static func setUpstream(of branch: Branch, in workspace: any RepoWorkspace) async {
        guard !branch.isRemote else { return }
        let remoteBranches = workspace.controller.refs.remoteBranches
        guard !remoteBranches.isEmpty else {
            await Dialogs.alert(
                title: "No Remote Branches",
                message: "Push “\(branch.name)” first to create a branch on a remote.",
                in: workspace.window
            )
            return
        }
        let sameName = remoteBranches.filter { RefNames.localName(of: $0) == branch.name }
        let ordered = sameName + remoteBranches.filter { RefNames.localName(of: $0) != branch.name }
        let options = ordered.enumerated().map { index, remote in
            DialogOption(
                title: remote.name,
                detail: remote.name == branch.upstream ? "Current upstream" : nil,
                key: index < 9 ? String(index + 1) : nil
            )
        }
        guard let choice = await Dialogs.choose(
            title: "Set Upstream of \(branch.name)",
            message: "Pull and push of “\(branch.name)” will use the chosen remote branch.",
            options: options,
            in: workspace.window
        ) else { return }
        let name = branch.name
        let upstream = ordered[choice].name
        await perform("Set Upstream of \(name) to \(upstream)", in: workspace, refresh: .refs) { repo, _ in
            try await repo.setUpstream(of: name, to: upstream)
        }
    }

    // MARK: Integration and history

    static func merge(_ target: SelectionTarget, in workspace: any RepoWorkspace) async {
        let controller = workspace.controller
        guard let resolved = ResolvedRef.resolve(target, refs: controller.refs) else { return }
        let current = RefNames.current(controller.refs)
        let title = "Merge \(resolved.displayName) into \(current)"
        guard let choice = await Dialogs.choose(
            title: title,
            options: [
                DialogOption(title: "Fast-forward if possible", detail: "Move \(current) ahead when it can, else create a merge commit", key: "f"),
                DialogOption(title: "Always create a merge commit", detail: "Record the merge even when a fast-forward is possible", key: "m"),
                DialogOption(title: "Fast-forward only", detail: "Stop instead of creating a merge commit", key: "o"),
            ],
            in: workspace.window
        ) else { return }
        let mode: MergeMode = [.fastForwardIfPossible, .noFastForward, .fastForwardOnly][choice]
        let revision = resolved.revision(in: controller.refs)
        let outcome = await perform(title, in: workspace, intercept: pausedOnConflicts) { repo, _ in
            try await repo.merge(revision, mode: mode)
        }
        finish(outcome, in: workspace)
    }

    static func rebaseCurrent(onto target: SelectionTarget, in workspace: any RepoWorkspace) async {
        let controller = workspace.controller
        guard let resolved = ResolvedRef.resolve(target, refs: controller.refs) else { return }
        let current = RefNames.current(controller.refs)
        let title = "Rebase \(current) onto \(resolved.displayName)"
        let confirmed = await Dialogs.confirm(
            title: title,
            message: "Replays the commits of \(current) that aren't on \(resolved.displayName) on top of it, rewriting them.",
            confirmTitle: "Rebase",
            in: workspace.window
        )
        guard confirmed else { return }
        let revision = resolved.revision(in: controller.refs)
        let outcome = await perform(title, in: workspace, intercept: pausedOnConflicts) { repo, _ in
            try await repo.rebase(onto: revision)
        }
        finish(outcome, in: workspace)
    }

    static func cherryPick(_ commitID: String, in workspace: any RepoWorkspace) async {
        let outcome = await perform("Cherry-pick \(String(commitID.prefix(7)))", in: workspace, intercept: pausedOnConflicts) { repo, _ in
            try await repo.cherryPick(commitID)
        }
        finish(outcome, in: workspace)
    }

    static func revert(_ commitID: String, in workspace: any RepoWorkspace) async {
        let controller = workspace.controller
        let short = String(commitID.prefix(7))
        let summary = controller.commits.first(where: { $0.id == commitID }).map { " “\($0.summary)”" } ?? ""
        let confirmed = await Dialogs.confirm(
            title: "Revert \(short)",
            message: "Creates a new commit on \(RefNames.current(controller.refs)) that undoes \(short)\(summary).",
            confirmTitle: "Revert",
            in: workspace.window
        )
        guard confirmed else { return }
        let outcome = await perform("Revert \(short)", in: workspace, intercept: pausedOnConflicts) { repo, _ in
            try await repo.revert(commitID)
        }
        finish(outcome, in: workspace)
    }

    /// Asks for soft/mixed/hard (hard confirms again).
    static func reset(to commitID: String, in workspace: any RepoWorkspace) async {
        let controller = workspace.controller
        let short = String(commitID.prefix(7))
        guard let choice = await Dialogs.choose(
            title: "Reset \(RefNames.current(controller.refs)) to \(short)",
            options: [
                DialogOption(title: "Soft", detail: "Keep every change, staged", key: "s"),
                DialogOption(title: "Mixed", detail: "Keep every change in the working copy, unstaged", key: "m"),
                DialogOption(title: "Hard", detail: "Discard all uncommitted changes and later commits", key: "h", isDestructive: true),
            ],
            in: workspace.window
        ) else { return }
        await reset(to: commitID, mode: [.soft, .mixed, .hard][choice], in: workspace)
    }

    /// Resets with a known mode (context menu submenu); hard confirms first.
    static func reset(to commitID: String, mode: ResetMode, in workspace: any RepoWorkspace) async {
        let current = RefNames.current(workspace.controller.refs)
        let short = String(commitID.prefix(7))
        if mode == .hard {
            let confirmed = await Dialogs.confirm(
                title: "Hard Reset \(current) to \(short)",
                message: "Discards every uncommitted change and moves \(current) to \(short). This can't be undone.",
                confirmTitle: "Reset Hard",
                isDestructive: true,
                in: workspace.window
            )
            guard confirmed else { return }
        }
        let outcome = await perform("Reset \(current) to \(short) (\(mode.rawValue))", in: workspace) { repo, _ in
            try await repo.reset(to: commitID, mode: mode)
        }
        guard outcome == .succeeded else { return }
        if workspace.controller.status.isClean {
            revealHead(in: workspace)
        } else {
            workspace.controller.select(.workingCopy)
        }
    }

    static func continueOperation(in workspace: any RepoWorkspace) async {
        guard let operation = workspace.controller.status.operation else { return }
        let outcome = await perform("Continue \(operation.title)", in: workspace, intercept: pausedOnNewConflicts) { repo, _ in
            let conflicts = try await repo.status().conflicted.count
            guard conflicts == 0 else {
                let files = conflicts == 1 ? "1 conflicted file" : "\(conflicts) conflicted files"
                throw ActionError(message: "Resolve the \(files) first: take ours or theirs in the commit panel, or stage your fix.")
            }
            try await repo.continueOperation()
        }
        finish(outcome, in: workspace)
    }

    static func abortOperation(in workspace: any RepoWorkspace) async {
        let controller = workspace.controller
        guard let operation = controller.status.operation else { return }
        let confirmed = await Dialogs.confirm(
            title: "Abort \(operation.title)",
            message: "Stops the \(operation.title.lowercased()) and puts \(RefNames.current(controller.refs)) back where it was. Conflict resolutions made so far are lost.",
            confirmTitle: "Abort \(operation.title)",
            isDestructive: true,
            in: workspace.window
        )
        guard confirmed else { return }
        let outcome = await perform("Abort \(operation.title)", in: workspace) { repo, _ in
            try await repo.abortOperation()
        }
        if outcome == .succeeded { revealHead(in: workspace) }
    }

    static func skipOperation(in workspace: any RepoWorkspace) async {
        guard let operation = workspace.controller.status.operation, operation.canSkip else { return }
        let outcome = await perform("Skip Commit", in: workspace, intercept: pausedOnConflicts) { repo, _ in
            try await repo.skipOperation()
        }
        finish(outcome, in: workspace)
    }

    // MARK: Tags

    static func createTag(at commitID: String, in workspace: any RepoWorkspace) async {
        let controller = workspace.controller
        let existing = controller.refs.tags.map(\.name)
        let label = commitLabel(commitID, in: controller)
        guard let name = await Dialogs.prompt(
            title: "Create Tag",
            message: "At \(label).",
            placeholder: "v1.0.0",
            confirmTitle: "Next",
            validate: { RefNameRules.validate($0, kind: .tag, existing: existing) },
            in: workspace.window
        ) else { return }
        guard let message = await Dialogs.prompt(
            title: "Tag \(name)",
            message: "A message makes it an annotated tag. Leave it empty for a lightweight tag.",
            placeholder: "Message (optional)",
            confirmTitle: "Create Tag",
            in: workspace.window
        ) else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await perform("Create Tag \(name)", in: workspace) { repo, _ in
            try await repo.createTag(name, at: commitID, message: trimmed.isEmpty ? nil : trimmed)
        }
        if outcome == .succeeded { controller.select(.commit(commitID)) }
    }

    static func pushTag(_ tag: Tag, in workspace: any RepoWorkspace) async {
        guard let remote = await chooseRemote(
            title: "Push Tag \(tag.name) to…",
            detail: { "Publish \(tag.name) on \($0)" },
            in: workspace
        ) else { return }
        let name = tag.name
        await perform("Push Tag \(name) to \(remote)", in: workspace, refresh: .refs) { repo, _ in
            try await repo.pushTag(name, remote: remote)
        }
    }

    // MARK: Stashes

    static func stash(in workspace: any RepoWorkspace) async {
        guard let message = await Dialogs.prompt(
            title: "Stash Changes",
            message: "Stashes staged, unstaged and untracked changes.",
            placeholder: "Message (optional)",
            confirmTitle: "Stash",
            in: workspace.window
        ) else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await perform("Stash Changes", in: workspace) { repo, _ in
            try await repo.stash(message: trimmed.isEmpty ? nil : trimmed, includeUntracked: true)
        }
        if outcome == .succeeded, !workspace.controller.stashes.isEmpty {
            workspace.controller.select(.stash(0))
        }
    }

    /// Pops `stash`, or the newest one when nil.
    static func popStash(_ stash: Stash?, in workspace: any RepoWorkspace) async {
        guard let stash = stash ?? workspace.controller.stashes.first else { return }
        let index = stash.index
        let outcome = await perform("Pop \(stash.reference)", in: workspace, intercept: conflictsAfterStash(kept: true)) { repo, _ in
            try await repo.popStash(index)
        }
        finishStash(outcome, in: workspace)
    }

    static func applyStash(_ stash: Stash, in workspace: any RepoWorkspace) async {
        let index = stash.index
        let outcome = await perform("Apply \(stash.reference)", in: workspace, intercept: conflictsAfterStash(kept: false)) { repo, _ in
            try await repo.applyStash(index)
        }
        finishStash(outcome, in: workspace)
    }

    // MARK: Remotes

    static func fetch(in workspace: any RepoWorkspace) async {
        await perform("Fetch All", in: workspace) { repo, progress in
            try await repo.fetch(remote: nil, onProgress: progress)
        }
    }

    static func pull(in workspace: any RepoWorkspace) async {
        guard let branch = workspace.controller.refs.currentBranch else { return }
        let title = "Pull \(branch.name)"
        guard branch.upstream != nil else {
            let pushKey = SettingsCenter.shared.shortcutText(for: "repo.push").map { " (\($0))" } ?? ""
            let message = "“\(branch.name)” has no upstream branch to pull from. Push it first\(pushKey) to create one, or set its upstream."
            await perform(title, in: workspace, refresh: []) { _, _ in
                throw ActionError(message: message)
            }
            return
        }
        let mode = SettingsCenter.shared.settings.pullMode
        let outcome = await perform(title, in: workspace, intercept: pausedOnConflicts) { repo, progress in
            try await repo.pull(mode: mode, onProgress: progress)
        }
        finish(outcome, in: workspace)
    }

    /// Pushes the current branch; sets the upstream (asking which remote when
    /// there are several) on first push; offers force-with-lease when rejected.
    static func push(in workspace: any RepoWorkspace) async {
        guard let branch = workspace.controller.refs.currentBranch else { return }
        await pushBranch(branch, in: workspace)
    }

    static func pushBranch(_ branch: Branch, in workspace: any RepoWorkspace) async {
        guard !branch.isRemote else { return }
        let refs = workspace.controller.refs
        let name = branch.name
        let remote: String
        let setUpstream: Bool
        if let upstream = branch.upstream, let upstreamRemote = RefNames.remote(ofUpstream: upstream, refs: refs) {
            remote = upstreamRemote
            setUpstream = false
        } else {
            let remotes = RefNames.remotes(refs)
            if remotes.count == 1 {
                let confirmed = await Dialogs.confirm(
                    title: "Push \(name)",
                    message: "“\(name)” has no upstream yet. Push it to \(remotes[0])/\(name) and track it?",
                    confirmTitle: "Push",
                    in: workspace.window
                )
                guard confirmed else { return }
                remote = remotes[0]
            } else {
                guard let chosen = await chooseRemote(
                    title: "Push \(name) to…",
                    message: "“\(name)” has no upstream yet; it will track the branch it creates.",
                    detail: { "Create and track \($0)/\(name)" },
                    in: workspace
                ) else { return }
                remote = chosen
            }
            setUpstream = true
        }

        let outcome = await perform("Push \(name)", in: workspace, intercept: rejectedPush) { repo, progress in
            try await repo.push(branch: name, remote: remote, setUpstream: setUpstream, forceWithLease: false, onProgress: progress)
        }
        guard case .intercepted = outcome else { return }

        let isCurrent = branch.isHead
        let choice = await Dialogs.choose(
            title: "Push Rejected",
            message: "\(remote)/\(name) has commits that \(name) doesn't. Integrate them first, or force push with lease: it replaces \(remote)/\(name) unless someone pushed since your last fetch.",
            options: [
                isCurrent
                    ? DialogOption(title: "Pull First", detail: "Bring the remote commits into \(name)", key: "p")
                    : DialogOption(title: "Fetch First", detail: "Update \(remote)/\(name) to see what's there", key: "p"),
                DialogOption(title: "Force Push with Lease", detail: "Replace \(remote)/\(name) with \(name)", key: "f", isDestructive: true),
            ],
            in: workspace.window
        )
        switch choice {
        case 0?:
            if isCurrent { await pull(in: workspace) } else { await fetch(in: workspace) }
        case 1?:
            await perform("Force Push \(name)", in: workspace) { repo, progress in
                try await repo.push(branch: name, remote: remote, setUpstream: setUpstream, forceWithLease: true, onProgress: progress)
            }
        default:
            break
        }
    }

    // MARK: Shared UI

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Running

    enum Outcome: Equatable {
        case succeeded
        case failed
        /// A failure the flow handles itself (paused on conflicts, rejected push…), with its note.
        case intercepted(String)
    }

    typealias Intercept = @Sendable (Error, Repository) async -> String?

    /// Runs `operation` through `controller.run`. When it throws and `intercept`
    /// returns a note, the failure is not reported: the activity shows the note.
    @discardableResult
    static func perform(
        _ title: String,
        in workspace: any RepoWorkspace,
        refresh: RepositoryController.RefreshParts = .all,
        intercept: Intercept? = nil,
        _ operation: @escaping @Sendable (Repository, _ progress: @escaping @Sendable (String) -> Void) async throws -> Void
    ) async -> Outcome {
        let controller = workspace.controller
        let box = NoteBox()
        let succeeded = await controller.run(title, refresh: []) { repo, progress in
            do {
                try await operation(repo, progress)
            } catch {
                if let intercept, let note = await intercept(error, repo) {
                    box.set(note)
                    return
                }
                throw error
            }
        }
        let note = box.value
        if let note { controller.annotateActivity(title, note: note) }
        if !refresh.isEmpty { await controller.refreshNow(refresh) }
        if let note { return .intercepted(note) }
        return succeeded ? .succeeded : .failed
    }

    /// A merge, rebase, cherry-pick or revert stopped on conflicts.
    nonisolated static let pausedOnConflicts: Intercept = { _, repo in
        guard let status = try? await repo.status(), status.operation != nil, !status.conflicted.isEmpty else { return nil }
        return conflictNote(status.conflicted.count)
    }

    /// Continue: only conflicts of the next step count (the closure checks
    /// there were none before), same test as `pausedOnConflicts`.
    nonisolated static let pausedOnNewConflicts: Intercept = { error, repo in
        guard !(error is ActionError) else { return nil }
        return await pausedOnConflicts(error, repo)
    }

    nonisolated static func conflictsAfterStash(kept: Bool) -> Intercept {
        { _, repo in
            guard let status = try? await repo.status(), !status.conflicted.isEmpty else { return nil }
            return conflictCount(status.conflicted.count) + (kept ? ", stash kept" : "")
        }
    }

    nonisolated static let notFullyMerged: Intercept = { error, _ in
        guard let error = error as? GitError, error.stderr.contains("not fully merged") else { return nil }
        return "not fully merged"
    }

    nonisolated static let rejectedPush: Intercept = { error, _ in
        guard let error = error as? GitError, error.stderr.contains("[rejected]"),
              error.stderr.contains("non-fast-forward") || error.stderr.contains("fetch first")
        else { return nil }
        return "rejected, the remote has new commits"
    }

    nonisolated static func conflictNote(_ count: Int) -> String {
        "paused on " + conflictCount(count)
    }

    nonisolated static func conflictCount(_ count: Int) -> String {
        count == 1 ? "1 conflict" : "\(count) conflicts"
    }

    // MARK: - After running

    private static func finish(_ outcome: Outcome, in workspace: any RepoWorkspace) {
        switch outcome {
        case .succeeded:
            if workspace.controller.status.operation == nil { revealHead(in: workspace) }
        case .intercepted:
            showConflicts(in: workspace)
        case .failed:
            break
        }
    }

    private static func finishStash(_ outcome: Outcome, in workspace: any RepoWorkspace) {
        switch outcome {
        case .succeeded: workspace.controller.select(.workingCopy)
        case .intercepted: showConflicts(in: workspace)
        case .failed: break
        }
    }

    /// The banner shows the paused operation; the commit panel lists the conflicts.
    private static func showConflicts(in workspace: any RepoWorkspace) {
        workspace.controller.select(.workingCopy)
        workspace.focus(.detail)
    }

    private static func revealHead(in workspace: any RepoWorkspace) {
        guard let head = workspace.controller.refs.headCommit else { return }
        workspace.controller.select(.commit(head))
    }

    // MARK: - Helpers

    /// "a1b2c3d Summary" when the commit is loaded, else the short id.
    static func commitLabel(_ id: String, in controller: RepositoryController) -> String {
        let short = String(id.prefix(7))
        guard let commit = controller.commits.first(where: { $0.id == id }) else { return short }
        return "\(short) “\(commit.summary)”"
    }

    /// The only remote, or the user's pick among several (origin first).
    private static func chooseRemote(
        title: String,
        message: String? = nil,
        detail: (String) -> String,
        in workspace: any RepoWorkspace
    ) async -> String? {
        let remotes = RefNames.remotes(workspace.controller.refs)
        guard remotes.count > 1 else { return remotes.first }
        let options = remotes.enumerated().map { index, remote in
            DialogOption(title: remote, detail: detail(remote), key: index < 9 ? String(index + 1) : nil)
        }
        guard let choice = await Dialogs.choose(title: title, message: message, options: options, in: workspace.window) else {
            return nil
        }
        return remotes[choice]
    }
}

/// A flow's own error message, reported like a git error.
struct ActionError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Carries an intercepted note out of the `@Sendable` operation closure.
private final class NoteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var note: String?

    var value: String? { lock.withLock { note } }

    func set(_ value: String) {
        lock.withLock { note = value }
    }
}

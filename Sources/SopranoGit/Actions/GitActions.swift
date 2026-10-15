import AppKit
import SopranoGitCore

/// User-facing git flows shared by the toolbar, palette, key bindings and the
/// graph/sidebar context menus: each asks what it needs (Dialogs), runs the
/// repository call through `controller.run`, and moves selection/focus after.
///
/// Interface contract (implemented in Wave B, see docs/ARCHITECTURE.md).
@MainActor
enum GitActions {
    // MARK: Branches and checkout

    /// Branch: switch to it (remote → local tracking branch). Commit/tag: the
    /// local branch at that commit if exactly one, else detached after confirming.
    static func checkout(_ target: SelectionTarget, in workspace: any RepoWorkspace) async {}
    /// Prompts for a name; creates at the target's commit (HEAD when nil) and checks it out.
    static func createBranch(at target: SelectionTarget?, in workspace: any RepoWorkspace) async {}
    static func renameBranch(_ branch: Branch, in workspace: any RepoWorkspace) async {}
    /// Branch (local, or on its remote), tag, or stash, after confirming.
    static func delete(_ target: SelectionTarget, in workspace: any RepoWorkspace) async {}
    static func setUpstream(of branch: Branch, in workspace: any RepoWorkspace) async {}

    // MARK: Integration and history

    static func merge(_ target: SelectionTarget, in workspace: any RepoWorkspace) async {}
    static func rebaseCurrent(onto target: SelectionTarget, in workspace: any RepoWorkspace) async {}
    static func cherryPick(_ commitID: String, in workspace: any RepoWorkspace) async {}
    static func revert(_ commitID: String, in workspace: any RepoWorkspace) async {}
    /// Asks for soft/mixed/hard (hard confirms again).
    static func reset(to commitID: String, in workspace: any RepoWorkspace) async {}
    static func continueOperation(in workspace: any RepoWorkspace) async {}
    static func abortOperation(in workspace: any RepoWorkspace) async {}
    static func skipOperation(in workspace: any RepoWorkspace) async {}

    // MARK: Tags

    static func createTag(at commitID: String, in workspace: any RepoWorkspace) async {}
    static func pushTag(_ tag: Tag, in workspace: any RepoWorkspace) async {}

    // MARK: Stashes

    static func stash(in workspace: any RepoWorkspace) async {}
    /// Pops `stash`, or the newest one when nil.
    static func popStash(_ stash: Stash?, in workspace: any RepoWorkspace) async {}
    static func applyStash(_ stash: Stash, in workspace: any RepoWorkspace) async {}

    // MARK: Remotes

    static func fetch(in workspace: any RepoWorkspace) async {}
    static func pull(in workspace: any RepoWorkspace) async {}
    /// Pushes the current branch; sets the upstream (asking which remote when
    /// there are several) on first push; offers force-with-lease when rejected.
    static func push(in workspace: any RepoWorkspace) async {}
    static func pushBranch(_ branch: Branch, in workspace: any RepoWorkspace) async {}

    // MARK: Shared UI

    static func copyToPasteboard(_ text: String) {}

    /// Right-click menu for a target, used by both the graph and the sidebar so
    /// they offer the same actions with the same shortcut hints.
    static func contextMenu(for target: SelectionTarget, in workspace: any RepoWorkspace) -> NSMenu {
        NSMenu()
    }
}

@MainActor
enum GitActionCommands {
    static var all: [AppCommand] { [] }
}

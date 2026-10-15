import AppKit
import SopranoGitCore

/// The Actions rows of the binding table. Each command acts on the command
/// target (`ActionRules.target`) and is enabled by the same `ActionRules` the
/// context menus use.
@MainActor
enum GitActionCommands {
    static var all: [AppCommand] {
        [
            // Remote
            AppCommand(
                id: "repo.fetch", title: "Fetch All", category: .remote,
                defaultKeys: ["cmd+l", "prefix+f"], icon: "arrow.triangle.2.circlepath",
                isEnabled: { $0.controller.map(ActionRules.hasRemotes) ?? false },
                perform: run { workspace, _ in await GitActions.fetch(in: workspace) }
            ),
            AppCommand(
                id: "repo.pull", title: "Pull", category: .remote,
                defaultKeys: ["prefix+p"], icon: "arrow.down.circle",
                isEnabled: { $0.controller.map(ActionRules.canPull) ?? false },
                perform: run { workspace, _ in await GitActions.pull(in: workspace) }
            ),
            AppCommand(
                id: "repo.push", title: "Push", category: .remote,
                defaultKeys: ["prefix+shift+p"], icon: "arrow.up.circle",
                isEnabled: { context in
                    guard let controller = context.controller, let branch = controller.refs.currentBranch else { return false }
                    return ActionRules.canPush(branch, controller)
                },
                perform: run { workspace, _ in await GitActions.push(in: workspace) }
            ),
            AppCommand(
                id: "branch.push", title: "Push Branch", category: .remote,
                icon: "arrow.up.circle",
                isEnabled: { context in
                    guard let controller = context.controller, let branch = pushableBranch(context) else { return false }
                    return ActionRules.canPush(branch, controller)
                },
                perform: run { workspace, context in
                    guard let branch = pushableBranch(context) else { return }
                    await GitActions.pushBranch(branch, in: workspace)
                }
            ),

            // Branch
            AppCommand(
                id: "branch.create", title: "Create Branch…", category: .branch,
                defaultKeys: ["cmd+b", "b"], icon: "arrow.triangle.branch",
                isEnabled: { $0.controller.map(ActionRules.canCreateBranch) ?? false },
                perform: run { workspace, context in
                    await GitActions.createBranch(at: ActionRules.target(context), in: workspace)
                }
            ),
            AppCommand(
                id: "ref.checkout", title: "Checkout", category: .branch,
                scopes: [.graph, .sidebar], defaultKeys: ["c"], icon: "checkmark.circle",
                isEnabled: { check($0, ActionRules.canCheckout) },
                perform: run { workspace, context in
                    guard let target = ActionRules.target(context) else { return }
                    await GitActions.checkout(target, in: workspace)
                }
            ),
            AppCommand(
                id: "branch.rename", title: "Rename Branch…", category: .branch,
                scopes: [.sidebar], defaultKeys: ["e"], icon: "pencil",
                isEnabled: { ActionRules.localBranch(ActionRules.target($0)) != nil },
                perform: run { workspace, context in
                    guard let branch = ActionRules.localBranch(ActionRules.target(context)) else { return }
                    await GitActions.renameBranch(branch, in: workspace)
                }
            ),
            AppCommand(
                id: "branch.setUpstream", title: "Set Upstream…", category: .branch,
                icon: "link",
                isEnabled: { context in
                    guard let controller = context.controller, let branch = pushableBranch(context) else { return false }
                    return ActionRules.canSetUpstream(branch, controller)
                },
                perform: run { workspace, context in
                    guard let branch = pushableBranch(context) else { return }
                    await GitActions.setUpstream(of: branch, in: workspace)
                }
            ),
            AppCommand(
                id: "ref.delete", title: "Delete Branch/Tag/Stash…", category: .branch,
                scopes: [.sidebar], defaultKeys: ["d"], icon: "trash",
                isEnabled: { ActionRules.target($0).map(ActionRules.canDelete) ?? false },
                perform: run { workspace, context in
                    guard let target = ActionRules.target(context) else { return }
                    await GitActions.delete(target, in: workspace)
                }
            ),
            AppCommand(
                id: "ref.copy", title: "Copy SHA / Name", category: .branch,
                scopes: [.graph, .sidebar, .detail], defaultKeys: ["y"], icon: "doc.on.doc",
                isEnabled: { ActionRules.target($0).flatMap(ActionRules.copyText) != nil },
                perform: { context in
                    guard let text = ActionRules.target(context).flatMap(ActionRules.copyText) else { return }
                    GitActions.copyToPasteboard(text)
                }
            ),

            // Merge & rebase
            AppCommand(
                id: "ref.merge", title: "Merge into Current Branch", category: .operation,
                scopes: [.graph, .sidebar], defaultKeys: ["m"], icon: "arrow.triangle.merge",
                isEnabled: { check($0, ActionRules.canIntegrate) },
                perform: run { workspace, context in
                    guard let target = ActionRules.target(context) else { return }
                    await GitActions.merge(target, in: workspace)
                }
            ),
            AppCommand(
                id: "ref.rebase", title: "Rebase Current Branch onto…", category: .operation,
                scopes: [.graph, .sidebar], defaultKeys: ["r"], icon: "arrow.triangle.pull",
                isEnabled: { check($0, ActionRules.canIntegrate) },
                perform: run { workspace, context in
                    guard let target = ActionRules.target(context) else { return }
                    await GitActions.rebaseCurrent(onto: target, in: workspace)
                }
            ),
            AppCommand(
                id: "operation.continue", title: "Continue Merge/Rebase/…", category: .operation,
                defaultKeys: ["prefix+c"], icon: "play.circle",
                isEnabled: { $0.controller?.status.operation != nil },
                perform: run { workspace, _ in await GitActions.continueOperation(in: workspace) }
            ),
            AppCommand(
                id: "operation.abort", title: "Abort Merge/Rebase/…", category: .operation,
                defaultKeys: ["prefix+x"], icon: "xmark.octagon",
                isEnabled: { $0.controller?.status.operation != nil },
                perform: run { workspace, _ in await GitActions.abortOperation(in: workspace) }
            ),
            AppCommand(
                id: "operation.skip", title: "Skip Commit", category: .operation,
                icon: "forward.end",
                isEnabled: { $0.controller?.status.operation?.canSkip == true },
                perform: run { workspace, _ in await GitActions.skipOperation(in: workspace) }
            ),

            // Commit
            AppCommand(
                id: "commit.cherryPick", title: "Cherry-pick Commit", category: .commit,
                scopes: [.graph], defaultKeys: ["p"], icon: "arrow.uturn.right",
                isEnabled: { check($0, ActionRules.canCherryPick) },
                perform: run { workspace, context in
                    guard case let .commit(id)? = ActionRules.target(context) else { return }
                    await GitActions.cherryPick(id, in: workspace)
                }
            ),
            AppCommand(
                id: "commit.revert", title: "Revert Commit", category: .commit,
                scopes: [.graph], defaultKeys: ["v"], icon: "arrow.uturn.backward",
                isEnabled: { check($0, ActionRules.canRewrite) },
                perform: run { workspace, context in
                    guard case let .commit(id)? = ActionRules.target(context) else { return }
                    await GitActions.revert(id, in: workspace)
                }
            ),
            AppCommand(
                id: "commit.reset", title: "Reset Current Branch to Here…", category: .commit,
                scopes: [.graph], defaultKeys: ["shift+r"], icon: "arrow.counterclockwise",
                isEnabled: { check($0, ActionRules.canRewrite) },
                perform: run { workspace, context in
                    guard case let .commit(id)? = ActionRules.target(context) else { return }
                    await GitActions.reset(to: id, in: workspace)
                }
            ),

            // Tag
            AppCommand(
                id: "tag.create", title: "Create Tag Here…", category: .tag,
                scopes: [.graph, .sidebar], defaultKeys: ["t"], icon: "tag",
                isEnabled: { context in
                    guard let controller = context.controller, let target = ActionRules.target(context) else { return false }
                    return ActionRules.tagCommit(for: target, controller) != nil
                },
                perform: run { workspace, context in
                    guard let target = ActionRules.target(context),
                          let id = ActionRules.tagCommit(for: target, workspace.controller) else { return }
                    await GitActions.createTag(at: id, in: workspace)
                }
            ),
            AppCommand(
                id: "tag.push", title: "Push Tag", category: .tag,
                icon: "tag.circle",
                isEnabled: { context in
                    guard case .tag? = ActionRules.target(context), let controller = context.controller else { return false }
                    return ActionRules.hasRemotes(controller)
                },
                perform: run { workspace, context in
                    guard case let .tag(tag)? = ActionRules.target(context) else { return }
                    await GitActions.pushTag(tag, in: workspace)
                }
            ),

            // Stash
            AppCommand(
                id: "stash.save", title: "Stash Changes", category: .stash,
                defaultKeys: ["prefix+s"], icon: "tray.and.arrow.down",
                isEnabled: { $0.controller.map(ActionRules.canStash) ?? false },
                perform: run { workspace, _ in await GitActions.stash(in: workspace) }
            ),
            AppCommand(
                id: "stash.pop", title: "Pop Stash", category: .stash,
                defaultKeys: ["prefix+shift+s"], icon: "tray.and.arrow.up",
                isEnabled: { $0.controller.map(ActionRules.canApplyStash) ?? false },
                perform: run { workspace, context in
                    await GitActions.popStash(targetStash(context), in: workspace)
                }
            ),
            AppCommand(
                id: "stash.apply", title: "Apply Stash", category: .stash,
                icon: "tray.full",
                isEnabled: { $0.controller.map(ActionRules.canApplyStash) ?? false },
                perform: run { workspace, context in
                    guard let stash = targetStash(context) ?? workspace.controller.stashes.first else { return }
                    await GitActions.applyStash(stash, in: workspace)
                }
            ),
        ]
    }

    /// Wraps an async flow as a command action on the context's workspace.
    private static func run(
        _ flow: @escaping @MainActor (any RepoWorkspace, CommandContext) async -> Void
    ) -> @MainActor (CommandContext) -> Void {
        { context in
            guard let workspace = context.workspace else { return }
            Task { @MainActor in await flow(workspace, context) }
        }
    }

    private static func check(
        _ context: CommandContext,
        _ rule: @MainActor (SelectionTarget, RepositoryController) -> Bool
    ) -> Bool {
        guard let controller = context.controller, let target = ActionRules.target(context) else { return false }
        return rule(target, controller)
    }

    /// The targeted local branch, else the current branch.
    private static func pushableBranch(_ context: CommandContext) -> Branch? {
        ActionRules.localBranch(ActionRules.target(context)) ?? context.controller?.refs.currentBranch
    }

    private static func targetStash(_ context: CommandContext) -> Stash? {
        guard case let .stash(stash)? = ActionRules.target(context) else { return nil }
        return stash
    }
}

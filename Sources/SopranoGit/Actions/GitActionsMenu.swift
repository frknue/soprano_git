import AppKit
import SopranoGitCore

extension GitActions {
    /// Right-click menu for a target, used by both the graph and the sidebar so
    /// they offer the same actions with the same shortcut hints.
    static func contextMenu(for target: SelectionTarget, in workspace: any RepoWorkspace) -> NSMenu {
        let controller = workspace.controller
        let refs = controller.refs
        let current = RefNames.current(refs)
        let menu = NSMenu()
        menu.autoenablesItems = false
        weak let weakWorkspace = workspace as AnyObject
        func act(_ flow: @escaping @MainActor (any RepoWorkspace) async -> Void) -> @MainActor () -> Void {
            {
                guard let workspace = weakWorkspace as? any RepoWorkspace else { return }
                Task { @MainActor in await flow(workspace) }
            }
        }
        func item(_ title: String, _ commandID: String?, enabled: Bool, _ flow: @escaping @MainActor (any RepoWorkspace) async -> Void) -> ActionMenuItem {
            ActionMenuItem(title: title, commandID: commandID, isEnabled: enabled, handler: act(flow))
        }
        let canCreateBranch = ActionRules.canCreateBranch(controller)
        let canCheckout = ActionRules.canCheckout(target, controller)
        let canIntegrate = ActionRules.canIntegrate(target, controller)

        switch target {
        case let .commit(id):
            let canRewrite = ActionRules.canRewrite(target, controller)
            menu.addItem(item("Checkout", "ref.checkout", enabled: canCheckout) { await checkout(target, in: $0) })
            menu.addItem(item("Create Branch Here…", "branch.create", enabled: canCreateBranch) { await createBranch(at: target, in: $0) })
            menu.addItem(item("Create Tag Here…", "tag.create", enabled: true) { await createTag(at: id, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Merge into \(current)", "ref.merge", enabled: canIntegrate) { await merge(target, in: $0) })
            menu.addItem(item("Rebase \(current) onto This", "ref.rebase", enabled: canIntegrate) { await rebaseCurrent(onto: target, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Cherry-pick", "commit.cherryPick", enabled: ActionRules.canCherryPick(target, controller)) { await cherryPick(id, in: $0) })
            menu.addItem(item("Revert", "commit.revert", enabled: canRewrite) { await revert(id, in: $0) })
            let reset = ActionMenuItem(title: "Reset \(current) to This", commandID: "commit.reset", isEnabled: canRewrite, handler: nil)
            let modes = NSMenu()
            modes.autoenablesItems = false
            for (title, mode) in [("Soft", ResetMode.soft), ("Mixed", .mixed), ("Hard", .hard)] {
                modes.addItem(item(title, nil, enabled: canRewrite) { await GitActions.reset(to: id, mode: mode, in: $0) })
            }
            reset.submenu = modes
            menu.addItem(reset)
            menu.addItem(.separator())
            menu.addItem(item("Copy SHA", "ref.copy", enabled: true) { _ in copyToPasteboard(id) })

        case let .branch(branch) where !branch.isRemote:
            menu.addItem(item("Checkout \(branch.name)", "ref.checkout", enabled: canCheckout) { await checkout(target, in: $0) })
            menu.addItem(item("Merge \(branch.name) into \(current)", "ref.merge", enabled: canIntegrate) { await merge(target, in: $0) })
            menu.addItem(item("Rebase \(current) onto \(branch.name)", "ref.rebase", enabled: canIntegrate) { await rebaseCurrent(onto: target, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Push \(branch.name)", "branch.push", enabled: ActionRules.canPush(branch, controller)) { await pushBranch(branch, in: $0) })
            menu.addItem(item("Set Upstream…", "branch.setUpstream", enabled: ActionRules.canSetUpstream(branch, controller)) { await setUpstream(of: branch, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Rename…", "branch.rename", enabled: true) { await renameBranch(branch, in: $0) })
            menu.addItem(item("Delete…", "ref.delete", enabled: ActionRules.canDelete(target)) { await delete(target, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Create Branch Here…", "branch.create", enabled: canCreateBranch) { await createBranch(at: target, in: $0) })
            menu.addItem(item("Create Tag Here…", "tag.create", enabled: true) { await createTag(at: branch.target, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Copy Name", "ref.copy", enabled: true) { _ in copyToPasteboard(branch.name) })

        case let .branch(branch):
            let remote = branch.remoteName ?? "remote"
            menu.addItem(item("Checkout \(branch.name)", "ref.checkout", enabled: canCheckout) { await checkout(target, in: $0) })
            menu.addItem(item("Merge \(branch.name) into \(current)", "ref.merge", enabled: canIntegrate) { await merge(target, in: $0) })
            menu.addItem(item("Rebase \(current) onto \(branch.name)", "ref.rebase", enabled: canIntegrate) { await rebaseCurrent(onto: target, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Delete \(RefNames.localName(of: branch)) on \(remote)…", "ref.delete", enabled: ActionRules.canDelete(target)) { await delete(target, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Copy Name", "ref.copy", enabled: true) { _ in copyToPasteboard(branch.name) })

        case let .tag(tag):
            menu.addItem(item("Checkout \(tag.name)", "ref.checkout", enabled: canCheckout) { await checkout(target, in: $0) })
            menu.addItem(item("Merge \(tag.name) into \(current)", "ref.merge", enabled: canIntegrate) { await merge(target, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Push Tag", "tag.push", enabled: ActionRules.hasRemotes(controller)) { await pushTag(tag, in: $0) })
            menu.addItem(item("Delete…", "ref.delete", enabled: true) { await delete(target, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Copy Name", "ref.copy", enabled: true) { _ in copyToPasteboard(tag.name) })

        case let .stash(stash):
            let canApply = ActionRules.isIdle(controller)
            menu.addItem(item("Apply Stash", "stash.apply", enabled: canApply) { await applyStash(stash, in: $0) })
            menu.addItem(item("Pop Stash", "stash.pop", enabled: canApply) { await popStash(stash, in: $0) })
            menu.addItem(.separator())
            menu.addItem(item("Delete Stash…", "ref.delete", enabled: true) { await delete(target, in: $0) })

        case .workingCopy:
            menu.addItem(item("Stash Changes", "stash.save", enabled: ActionRules.canStash(controller)) { await stash(in: $0) })
        }
        ActionMenuItem.alignShortcuts(in: menu)
        return menu
    }
}

/// A context-menu item running a flow, with its command's bound key shown
/// right-aligned (the keymap is live, so the text comes from settings).
@MainActor
final class ActionMenuItem: NSMenuItem {
    let commandID: String?
    /// The title without the shortcut column.
    let label: String
    /// Display text of the command's first chord, nil when unbound.
    let shortcut: String?
    private let handler: (@MainActor () -> Void)?

    init(title: String, commandID: String?, isEnabled: Bool, handler: (@MainActor () -> Void)?) {
        self.commandID = commandID
        self.label = title
        self.shortcut = commandID.flatMap { SettingsCenter.shared.shortcutText(for: $0) }
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        target = self
        self.isEnabled = isEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler?()
    }

    /// Lays every item out as "title ⇥ shortcut" with one right tab stop past
    /// the widest title.
    static func alignShortcuts(in menu: NSMenu) {
        let font = NSFont.menuFont(ofSize: 0)
        let items = menu.items.compactMap { $0 as? ActionMenuItem }
        let widest = items.map { ($0.label as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let shortcutWidth = items.compactMap(\.shortcut).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: ceil(widest + 32 + shortcutWidth))]
        for item in items {
            if let submenu = item.submenu { alignShortcuts(in: submenu) }
            guard let shortcut = item.shortcut else { continue }
            let text = NSMutableAttributedString(string: item.label, attributes: [.font: font, .paragraphStyle: paragraph])
            text.append(NSAttributedString(string: "\t" + shortcut, attributes: [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = text
        }
    }
}

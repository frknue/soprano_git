import AppKit

/// App, tab, view and focus commands (the Shell rows of the binding table).
@MainActor
enum ShellCommands {
    static var all: [AppCommand] {
        var commands: [AppCommand] = [
            AppCommand(
                id: "palette.open", title: "Command Palette", category: .app,
                defaultKeys: ["cmd+p"], icon: "command", inPalette: false,
                isEnabled: { windowController($0) != nil },
                perform: { windowController($0)?.showPalette() }
            ),
            AppCommand(
                id: "help.shortcuts", title: "Keyboard Shortcuts", category: .app,
                defaultKeys: ["cmd+/", "?"], icon: "keyboard",
                isEnabled: { windowController($0) != nil },
                perform: { windowController($0)?.showShortcuts() }
            ),
            AppCommand(
                id: "settings.open", title: "Settings", category: .app,
                defaultKeys: ["cmd+,"], icon: "gearshape",
                isEnabled: { windowController($0) != nil },
                perform: { windowController($0)?.showSettings() }
            ),
            AppCommand(
                id: "settings.openFile", title: "Open settings.json", category: .app,
                icon: "doc.text",
                perform: { _ in SettingsCenter.shared.openInEditor() }
            ),
            AppCommand(
                id: "settings.nextPage", title: "Next Settings Page", category: .navigation,
                scopes: [.settings], defaultKeys: ["j"], icon: "arrow.down", inPalette: false,
                perform: { settings($0)?.movePage(by: 1) }
            ),
            AppCommand(
                id: "settings.previousPage", title: "Previous Settings Page", category: .navigation,
                scopes: [.settings], defaultKeys: ["k"], icon: "arrow.up", inPalette: false,
                perform: { settings($0)?.movePage(by: -1) }
            ),
            AppCommand(
                id: "settings.filterShortcuts", title: "Filter Shortcuts", category: .navigation,
                scopes: [.settings], defaultKeys: ["/"], icon: "magnifyingglass", inPalette: false,
                perform: { settings($0)?.focusShortcutFilter() }
            ),
            AppCommand(
                id: "settings.close", title: "Close Settings", category: .tabs,
                scopes: [.settings], defaultKeys: ["escape"], icon: "xmark.square", inPalette: false,
                perform: { windowController($0)?.closeCurrentTab() }
            ),
            AppCommand(
                id: "repo.open", title: "Open Repository…", category: .app,
                defaultKeys: ["cmd+o"], icon: "folder",
                isEnabled: { windowController($0) != nil },
                perform: { windowController($0)?.showOpenPanel() }
            ),
            AppCommand(
                id: "repo.openRecent", title: "Open Recent Repository…", category: .app,
                defaultKeys: ["cmd+shift+o"], icon: "clock.arrow.circlepath",
                isEnabled: { context in
                    guard let controller = windowController(context) else { return false }
                    return !controller.state.recentRepositories.isEmpty
                },
                perform: { windowController($0)?.showRecentPicker() }
            ),
            AppCommand(
                id: "tab.new", title: "New Tab", category: .tabs,
                defaultKeys: ["cmd+t"], icon: "plus.square",
                isEnabled: { windowController($0) != nil },
                perform: { windowController($0)?.newTab() }
            ),
            AppCommand(
                id: "tab.close", title: "Close Tab", category: .tabs,
                defaultKeys: ["cmd+w"], icon: "xmark.square",
                isEnabled: { windowController($0) != nil },
                perform: { windowController($0)?.closeCurrentTab() }
            ),
            AppCommand(
                id: "tab.next", title: "Next Tab", category: .tabs,
                defaultKeys: ["ctrl+tab"], icon: "arrow.right.square",
                isEnabled: { (windowController($0)?.tabs.count ?? 0) > 1 },
                perform: { windowController($0)?.selectNextTab(1) }
            ),
            AppCommand(
                id: "tab.previous", title: "Previous Tab", category: .tabs,
                defaultKeys: ["ctrl+shift+tab"], icon: "arrow.left.square",
                isEnabled: { (windowController($0)?.tabs.count ?? 0) > 1 },
                perform: { windowController($0)?.selectNextTab(-1) }
            ),
            AppCommand(
                id: "view.toggleSidebar", title: "Toggle Left Panel", category: .view,
                defaultKeys: ["cmd+j"], icon: "sidebar.left",
                isEnabled: { $0.workspace != nil },
                perform: { context in
                    guard let workspace = context.workspace else { return }
                    workspace.isSidebarVisible.toggle()
                }
            ),
            AppCommand(
                id: "view.toggleCommitPanel", title: "Toggle Commit Panel", category: .view,
                defaultKeys: ["cmd+k"], icon: "sidebar.right",
                isEnabled: { $0.workspace != nil },
                perform: { context in
                    guard let workspace = context.workspace else { return }
                    workspace.isCommitPanelVisible.toggle()
                }
            ),
            AppCommand(
                id: "focus.left", title: "Focus Panel Left", category: .navigation,
                scopes: [.sidebar, .graph, .detail, .diff], defaultKeys: ["h", "prefix+h"], icon: "arrow.left",
                isEnabled: { context in
                    guard context.workspace != nil, let focus = context.focus else { return false }
                    return focus != .sidebar
                },
                perform: { context in
                    (context.workspace as? RepoWorkspaceViewController)?.moveFocus(by: -1)
                }
            ),
            AppCommand(
                id: "focus.right", title: "Focus Panel Right", category: .navigation,
                scopes: [.sidebar, .graph, .detail, .diff], defaultKeys: ["l", "prefix+l"], icon: "arrow.right",
                isEnabled: { context in
                    guard context.workspace != nil, let focus = context.focus else { return false }
                    return focus != .detail
                },
                perform: { context in
                    (context.workspace as? RepoWorkspaceViewController)?.moveFocus(by: 1)
                }
            ),
            AppCommand(
                id: "toast.dismiss", title: "Dismiss Error", category: .app,
                defaultKeys: ["escape"], icon: "xmark.circle", inPalette: false,
                isEnabled: { ($0.workspace as? RepoWorkspaceViewController)?.isToastVisible == true },
                perform: { ($0.workspace as? RepoWorkspaceViewController)?.dismissToast() }
            ),
            AppCommand(
                id: "welcome.next", title: "Next Recent Repository", category: .navigation,
                scopes: [.welcome], defaultKeys: ["j"], icon: "arrow.down", inPalette: false,
                perform: { windowController($0)?.currentTab?.welcome?.moveSelection(by: 1) }
            ),
            AppCommand(
                id: "welcome.previous", title: "Previous Recent Repository", category: .navigation,
                scopes: [.welcome], defaultKeys: ["k"], icon: "arrow.up", inPalette: false,
                perform: { windowController($0)?.currentTab?.welcome?.moveSelection(by: -1) }
            ),
            AppCommand(
                id: "welcome.open", title: "Open Selected Repository", category: .navigation,
                scopes: [.welcome], defaultKeys: ["enter"], icon: "folder", inPalette: false,
                perform: { windowController($0)?.currentTab?.welcome?.openSelected() }
            ),
        ]
        for number in 1...9 {
            commands.append(AppCommand(
                id: "tab.select.\(number)", title: "Go to Tab \(number)", category: .tabs,
                defaultKeys: ["cmd+\(number)"], icon: "\(number).square", inPalette: false,
                isEnabled: { (windowController($0)?.tabs.count ?? 0) >= number },
                perform: { windowController($0)?.selectTab(number - 1) }
            ))
        }
        return commands
    }

    static func windowController(_ context: CommandContext) -> MainWindowController? {
        context.window?.windowController as? MainWindowController
    }

    static func settings(_ context: CommandContext) -> SettingsViewController? {
        windowController(context)?.currentTab?.settings
    }
}

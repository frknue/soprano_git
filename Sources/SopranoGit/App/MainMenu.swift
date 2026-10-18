import AppKit

/// The menu bar, built from the command registry: titles and ⌘ key
/// equivalents follow the live keymap and are rebuilt on settings changes.
/// Command items validate against the main window's command context.
@MainActor
final class MainMenuController: NSObject, NSMenuItemValidation, NSMenuDelegate {
    var windowController: () -> MainWindowController?
    private let registry: CommandRegistry
    private let recentMenu = NSMenu(title: "Open Recent")

    init(registry: CommandRegistry = .shared, windowController: @escaping () -> MainWindowController?) {
        self.registry = registry
        self.windowController = windowController
        super.init()
        recentMenu.delegate = self
    }

    /// Repository menu commands in order (owned by Actions; disabled until registered).
    static let repositoryCommands: [(id: String, fallbackTitle: String)] = [
        ("repo.fetch", "Fetch All"),
        ("repo.pull", "Pull"),
        ("repo.push", "Push"),
        ("branch.create", "Create Branch…"),
        ("stash.save", "Stash Changes"),
        ("stash.pop", "Pop Stash"),
        ("operation.continue", "Continue Merge/Rebase/…"),
        ("operation.abort", "Abort Merge/Rebase/…"),
    ]

    func install() {
        NSApp.mainMenu = buildMenu()
    }

    func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Soprano Git")
        appMenu.addItem(withTitle: "About Soprano Git", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(commandItem("settings.open", title: "Settings…"))
        appMenu.addItem(commandItem("settings.openFile"))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Soprano Git", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Soprano Git", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(commandItem("repo.open"))
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(commandItem("repo.openRecent", title: "Open Recent Repository…"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("tab.new"))
        fileMenu.addItem(commandItem("tab.close"))
        add(fileMenu, to: main)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(editMenu, to: main)

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(commandItem("palette.open", title: "Command Palette…"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("view.toggleSidebar"))
        viewMenu.addItem(commandItem("view.toggleCommitPanel"))
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        add(viewMenu, to: main)

        let repositoryMenu = NSMenu(title: "Repository")
        for (index, entry) in Self.repositoryCommands.enumerated() {
            if index == 3 || index == 4 || index == 6 { repositoryMenu.addItem(.separator()) }
            repositoryMenu.addItem(commandItem(entry.id, title: registry.command(entry.id)?.title ?? entry.fallbackTitle))
        }
        add(repositoryMenu, to: main)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(commandItem("tab.next"))
        windowMenu.addItem(commandItem("tab.previous"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(windowMenu, to: main)
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(commandItem("help.shortcuts"))
        add(helpMenu, to: main)
        NSApp.helpMenu = helpMenu

        return main
    }

    private func add(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }

    /// A menu item running `id`; shows the first direct ⌘ chord as key equivalent.
    func commandItem(_ id: String, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(
            title: title ?? registry.command(id)?.title ?? id,
            action: #selector(performCommand(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = id
        if let equivalent = SettingsCenter.shared.chords(for: id).lazy.compactMap(\.menuKeyEquivalent).first {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
        return item
    }

    @objc func performCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let controller = windowController() {
            controller.perform(id)
        } else if let command = registry.command(id) {
            let context = CommandContext(window: nil, workspace: nil, focus: nil, isTextInput: false)
            if command.isEnabled(context) { command.perform(context) }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performCommand(_:)) else {
            return menuItem.action == #selector(openRecent(_:))
        }
        guard let id = menuItem.representedObject as? String, let command = registry.command(id) else { return false }
        // While a dialog, the palette or the shortcut sheet has the keyboard, commands wait.
        if let key = NSApp.keyWindow, !(key is MainWindow) { return false }
        if let main = windowController()?.window, main.attachedSheet != nil { return false }
        if let controller = windowController() {
            return command.isEnabled(controller.commandContext())
        }
        return command.isEnabled(CommandContext(window: nil, workspace: nil, focus: nil, isTextInput: false))
    }

    // MARK: - Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let recents = windowController()?.state.recentRepositories ?? []
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Repositories", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.toolTip = url.path
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let controller = windowController() else { return }
        Task { @MainActor in
            await controller.openRepository(at: url, inNewTab: controller.currentTab?.welcome == nil)
        }
    }
}

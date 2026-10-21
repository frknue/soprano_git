import AppKit

/// Normal launch: settings → theme → commands → menus → main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowController: MainWindowController?
    private var menuController: MainMenuController?
    /// Directories handed to the app before the window existed.
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.installApplicationIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsCenter.shared
        settings.start()
        ThemeCenter.shared.apply(setting: settings.settings.theme)
        ThemeCenter.shared.startDrivingApplicationAppearance()

        AllCommands.registerAll()
        settings.reloadKeymap()

        let menu = MainMenuController(windowController: { [weak self] in self?.windowController })
        menu.install()
        menuController = menu

        settings.addObserver(self) { [weak self] in
            ThemeCenter.shared.apply(setting: SettingsCenter.shared.settings.theme)
            self?.menuController?.install()
        }

        let controller = MainWindowController(state: AppStateStore(), persistsState: true)
        windowController = controller
        controller.restoreSession()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        didFinishLaunching = true
        openPendingURLs()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let directories = urls.filter { url in
            var isDirectory: ObjCBool = false
            return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        pendingURLs.append(contentsOf: directories)
        if didFinishLaunching { openPendingURLs() }
    }

    private func openPendingURLs() {
        guard let controller = windowController, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        Task { @MainActor in
            await controller.openExternally(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.window?.makeKeyAndOrderFront(nil) }
        return true
    }

    static func installApplicationIcon() {
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? AppResources.bundle.url(forResource: "AppIcon", withExtension: "icns")
        if let url, let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }
}

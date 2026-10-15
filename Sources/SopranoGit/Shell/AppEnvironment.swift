import AppKit
import OSLog
import SopranoGitCore

/// Resolved user settings (from ~/.config/soprano-git/settings.json).
struct AppSettings: Equatable, Sendable {
    enum DateStyle: String, Equatable, Sendable, CaseIterable {
        case relative
        case absolute
    }

    /// An id from `AppTheme.allThemes`, or "soprano" to follow Soprano's own theme setting.
    var theme: String = "soprano"
    /// Explicit git executable; nil = auto-detect.
    var gitPath: String?
    /// Directories prepended to PATH for git and its hooks.
    var extraPath: [String] = []
    var graphPageSize: Int = 2000
    var dateStyle: DateStyle = .relative
    var pullMode: PullMode = .fastForwardIfPossible
    var diffContextLines: Int = 3

    static let defaults = AppSettings()
}

private let settingsLog = Logger(subsystem: "com.soprano.git", category: "settings")

/// The live theme. Views read `theme` when they build and re-style in their
/// observer when it changes.
///
/// `theme: "soprano"` follows the `theme` key of Soprano's settings.json
/// (watched live); Mission Control when that file or key is missing or unknown.
@MainActor
final class ThemeCenter {
    static let shared = ThemeCenter()

    /// Vendored manager, for Soprano components that take one (CommandPalettePanel).
    let manager = ThemeManager(themeId: AppTheme.missionControl.id)

    var theme: AppTheme { manager.currentTheme }

    /// Soprano's settings.json, read when following Soprano.
    let sopranoSettingsURL: URL
    /// The `theme` setting currently applied ("soprano" or a theme id).
    private(set) var setting = "soprano"
    /// Forced theme id (snapshot `--theme`); wins over settings.
    var forcedThemeID: String? {
        didSet { applyResolvedTheme() }
    }

    private let observers = ObserverList<AppTheme>()
    private var sopranoWatcher: ConfigFileWatcher?
    private var watchesSoprano = false

    init(sopranoSettingsURL: URL = SettingsFile.sopranoURL()) {
        self.sopranoSettingsURL = sopranoSettingsURL
    }

    /// Handlers fire after the theme changes, until `owner` is deallocated.
    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (AppTheme) -> Void) {
        observers.add(owner, handler)
    }

    /// Applies the `theme` setting. `watch` keeps following Soprano's file live.
    func apply(setting: String, watch: Bool = true) {
        self.setting = setting
        watchesSoprano = watch && setting == "soprano"
        updateSopranoWatcher()
        applyResolvedTheme()
    }

    /// Re-reads Soprano's settings (called by the watcher).
    func reloadSopranoTheme() {
        applyResolvedTheme()
    }

    /// The theme id `setting` resolves to, given Soprano's settings text.
    nonisolated static func resolveThemeID(setting: String, sopranoSettingsText: String?) -> String {
        guard setting == "soprano" else {
            return AppTheme.allThemes.contains(where: { $0.id == setting }) ? setting : AppTheme.missionControl.id
        }
        guard let text = sopranoSettingsText,
              let data = try? JSONCText.strictJSONData(from: text),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["theme"] as? String,
              AppTheme.allThemes.contains(where: { $0.id == id })
        else {
            return AppTheme.missionControl.id
        }
        return id
    }

    private func applyResolvedTheme() {
        let id: String
        if let forcedThemeID {
            id = AppTheme.theme(for: forcedThemeID).id
        } else {
            let text = setting == "soprano" ? (try? SettingsFile.read(at: sopranoSettingsURL)) ?? nil : nil
            id = Self.resolveThemeID(setting: setting, sopranoSettingsText: text)
        }
        guard id != manager.currentTheme.id else { return }
        manager.setTheme(id: id)
        observers.notify(manager.currentTheme)
    }

    private func updateSopranoWatcher() {
        if watchesSoprano {
            guard sopranoWatcher == nil else { return }
            let watcher = ConfigFileWatcher(url: sopranoSettingsURL) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reloadSopranoTheme()
                }
            }
            watcher.start()
            sopranoWatcher = watcher
        } else {
            sopranoWatcher?.stop()
            sopranoWatcher = nil
        }
    }
}

/// Settings and key bindings, live-reloaded from settings.json.
///
/// A syntax error keeps the last good settings running and is reported as an
/// error issue; bad values become warnings (logged), never launch failures.
@MainActor
final class SettingsCenter {
    static let shared = SettingsCenter()

    let fileURL: URL
    /// Commands the keymap resolves against.
    let registry: CommandRegistry

    private(set) var settings = AppSettings.defaults
    private(set) var keybindingSettings = KeybindingSettings()
    /// Problems reading the file (syntax errors); the last good resolution stays.
    private(set) var fileIssues: [ConfigIssue] = []
    private(set) var settingsIssues: [ConfigIssue] = []
    var issues: [ConfigIssue] { fileIssues + settingsIssues + keymap.issues }

    private var cachedKeymap: Keymap?
    private var cachedKeymapCommandCount = -1
    private var lastText: String?
    private var watcher: ConfigFileWatcher?
    private let observers = ObserverList<Void>()

    init(fileURL: URL = SettingsFile.url(), registry: CommandRegistry? = nil) {
        self.fileURL = fileURL
        self.registry = registry ?? .shared
    }

    var displayPath: String { SettingsFile.displayPath(for: fileURL) }

    /// Creates the file from the template when missing (unless `createIfMissing`
    /// is false, e.g. snapshots), loads it, and starts watching it.
    func start(createIfMissing: Bool = true, watching: Bool = true) {
        if createIfMissing {
            do {
                try SettingsFile.createIfMissing(at: fileURL)
            } catch {
                settingsLog.error("Could not create \(self.displayPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        reloadFromDisk(notify: false)
        if watching, watcher == nil {
            let watcher = ConfigFileWatcher(url: fileURL) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reloadFromDisk()
                }
            }
            watcher.start()
            self.watcher = watcher
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    func reloadFromDisk(notify: Bool = true) {
        let text: String?
        do {
            text = try SettingsFile.read(at: fileURL)
        } catch {
            fileIssues = [ConfigIssue(severity: .error, message: "Could not read \(displayPath): \(error.localizedDescription)")]
            logIssues()
            if notify { observers.notify(()) }
            return
        }
        guard text != lastText || lastText == nil else { return }
        lastText = text
        apply(text: text ?? "{}", notify: notify)
    }

    /// Applies a document. A syntax error keeps the last good settings.
    func apply(text: String, notify: Bool = true) {
        do {
            let resolved = try SettingsResolver.resolve(text: text)
            fileIssues = []
            settings = resolved.settings
            keybindingSettings = resolved.keybindings
            settingsIssues = resolved.issues
            cachedKeymap = nil
        } catch let error as JSONCText.ParseError {
            fileIssues = [ConfigIssue(severity: .error, message: "\(displayPath): \(error.message)", line: error.line)]
        } catch {
            fileIssues = [ConfigIssue(severity: .error, message: "\(displayPath): \(error.localizedDescription)")]
        }
        logIssues()
        if notify { observers.notify(()) }
    }

    /// Key bindings resolved against the registry; rebuilt when settings or
    /// the registered commands change.
    var keymap: Keymap {
        if let cachedKeymap, cachedKeymapCommandCount == registry.commands.count {
            return cachedKeymap
        }
        let keymap = Keymap.resolve(commands: registry.commands, settings: keybindingSettings)
        cachedKeymap = keymap
        cachedKeymapCommandCount = registry.commands.count
        return keymap
    }

    /// Re-resolves the keymap after commands were registered, logging its issues.
    func reloadKeymap() {
        cachedKeymap = nil
        logIssues()
        observers.notify(())
    }

    /// Chords bound to a command after settings.json overrides; the first is
    /// the one menus and the palette display. Empty when unbound.
    func chords(for commandID: String) -> [KeyChord] {
        keymap.chords(for: commandID)
    }

    /// Display text of the command's first chord ("⌘B", "Prefix → P", "J"), nil when unbound.
    func shortcutText(for commandID: String) -> String? {
        chords(for: commandID).first?.displayString
    }

    /// Compact keycap text of the first chord ("⌘B", "⌃A P"), nil when unbound.
    func keycapText(for commandID: String) -> String? {
        chords(for: commandID).first?.compactText(prefixKey: keymap.prefixKey)
    }

    /// Handlers fire after settings.json changes, until `owner` is deallocated.
    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.add(owner) { _ in handler() }
    }

    /// Opens settings.json in the user's editor, creating it first if needed.
    func openInEditor() {
        _ = try? SettingsFile.createIfMissing(at: fileURL)
        let workspace = NSWorkspace.shared
        if let editor = workspace.urlForApplication(toOpen: fileURL) {
            workspace.open([fileURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else if let textEdit = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([fileURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private var loggedIssueIDs: Set<String> = []

    private func logIssues() {
        let current = issues
        for issue in current where !loggedIssueIDs.contains(issue.id) {
            switch issue.severity {
            case .error: settingsLog.error("\(issue.message, privacy: .public)")
            case .warning: settingsLog.warning("\(issue.message, privacy: .public)")
            }
        }
        loggedIssueIDs = Set(current.map(\.id))
    }
}

import AppKit
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

/// The live theme. Views read `theme` when they build and re-style in their
/// observer when it changes.
///
/// Interface contract (implemented in Wave A, see docs/ARCHITECTURE.md).
@MainActor
final class ThemeCenter {
    static let shared = ThemeCenter()

    /// Vendored manager, for Soprano components that take one (CommandPalettePanel).
    let manager = ThemeManager(themeId: AppTheme.missionControl.id)

    var theme: AppTheme { manager.currentTheme }

    /// Handlers fire after the theme changes, until `owner` is deallocated.
    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (AppTheme) -> Void) {}
}

/// Settings and key bindings, live-reloaded from settings.json.
///
/// Interface contract (implemented in Wave A, see docs/ARCHITECTURE.md).
@MainActor
final class SettingsCenter {
    static let shared = SettingsCenter()

    private(set) var settings = AppSettings.defaults

    /// Chords bound to a command after settings.json overrides; the first is
    /// the one menus and the palette display. Empty when unbound.
    func chords(for commandID: String) -> [KeyChord] { [] }

    /// Display text of the command's first chord ("⌘B", "Prefix → P", "J"), nil when unbound.
    func shortcutText(for commandID: String) -> String? { nil }

    /// Handlers fire after settings.json changes, until `owner` is deallocated.
    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {}
}

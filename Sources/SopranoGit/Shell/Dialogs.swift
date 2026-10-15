import AppKit

struct DialogOption: Equatable {
    var title: String
    var detail: String?
    /// Single-character shortcut shown as a keycap and accepted while the dialog is open.
    var key: String?
    var isDestructive: Bool

    init(title: String, detail: String? = nil, key: String? = nil, isDestructive: Bool = false) {
        self.title = title
        self.detail = detail
        self.key = key
        self.isDestructive = isDestructive
    }
}

/// Keyboard-first modal dialogs in the Mission Control chrome, attached to a
/// window as a sheet (centered panel when `window` is nil). Return confirms,
/// Esc cancels, j/k or arrows move between options, option keys pick directly.
///
/// Interface contract (implemented in Wave A, see docs/ARCHITECTURE.md).
@MainActor
enum Dialogs {
    /// Asks for one line of text. `validate` returns an error message to show
    /// inline (confirm stays disabled) or nil when the value is acceptable.
    static func prompt(
        title: String,
        message: String? = nil,
        placeholder: String? = nil,
        initialValue: String = "",
        confirmTitle: String = "OK",
        validate: ((String) -> String?)? = nil,
        in window: NSWindow?
    ) async -> String? {
        nil
    }

    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = false,
        in window: NSWindow?
    ) async -> Bool {
        false
    }

    /// Returns the index of the chosen option, nil when cancelled.
    static func choose(
        title: String,
        message: String? = nil,
        options: [DialogOption],
        in window: NSWindow?
    ) async -> Int? {
        nil
    }
}

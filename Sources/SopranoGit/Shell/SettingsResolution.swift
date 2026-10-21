import Foundation
import SopranoGitCore

/// A problem found while resolving settings.json. Issues never block startup:
/// a bad value keeps its default and is logged (Soprano's `ConfigIssue`).
struct ConfigIssue: Equatable, Identifiable, Sendable {
    enum Severity: Equatable, Sendable {
        /// The document could not be read at all; the last good settings stay in force.
        case error
        /// One key was ignored; everything else applied.
        case warning
    }

    let severity: Severity
    let message: String
    /// 1-based line in settings.json, when the problem has a position.
    var line: Int?

    var id: String { "\(severity)-\(line ?? 0)-\(message)" }
}

/// A `keybindings.bindings` value: one chord, several, or `null` to unbind.
enum BindingOverride: Equatable, Sendable {
    case chords([String])
    case disabled
}

/// Raw keybinding settings, applied to the command registry by `Keymap.resolve`.
struct KeybindingSettings: Equatable, Sendable {
    var prefixKey = "a"
    var prefixTimeoutMs = 1500
    var overrides: [String: BindingOverride] = [:]
}

/// settings.json applied on top of the defaults.
struct ResolvedSettings: Equatable, Sendable {
    var settings = AppSettings.defaults
    var keybindings = KeybindingSettings()
    var issues: [ConfigIssue] = []

    static let defaults = ResolvedSettings()
}

enum SettingsResolver {
    enum Limits {
        static let prefixTimeoutMs = 300...5000
        static let graphPageSize = 100...20000
        static let diffContextLines = 0...50
    }

    /// Parses JSONC text. Throws `JSONCText.ParseError` (or a decoding error)
    /// when the document is not a JSON object.
    static func resolve(text: String) throws -> ResolvedSettings {
        let data = try JSONCText.strictJSONData(from: text)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = object as? [String: Any] else {
            throw JSONCText.ParseError(message: "The settings document must be a JSON object", line: 1, column: 1)
        }
        return resolve(root)
    }

    static func resolve(_ root: [String: Any]) -> ResolvedSettings {
        var result = ResolvedSettings()
        var issues: [ConfigIssue] = []
        func warn(_ message: String) {
            issues.append(ConfigIssue(severity: .warning, message: message))
        }

        let knownTopLevel: Set<String> = ["theme", "git", "graph", "pull", "diff", "keybindings"]
        for key in root.keys.sorted() where !knownTopLevel.contains(key) {
            warn("Unknown setting \"\(key)\".")
        }

        if let value = root["theme"] {
            if let theme = value as? String, theme == "soprano" || AppTheme.isKnownId(theme) {
                result.settings.theme = theme
            } else {
                let known = (["soprano"] + AppTheme.options.map(\.id)).joined(separator: ", ")
                warn("Unknown theme \(describe(value)). Known themes: \(known).")
            }
        }

        if let git = section("git", in: root, warn: warn) {
            for key in git.keys.sorted() where !["path", "extraPath"].contains(key) {
                warn("Unknown setting \"git.\(key)\".")
            }
            if let value = git["path"] {
                if value is NSNull {
                    result.settings.gitPath = nil
                } else if let path = value as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.settings.gitPath = expandingTilde(path)
                } else {
                    warn("git.path must be a path string; using auto-detect.")
                }
            }
            if let value = git["extraPath"] {
                if let paths = value as? [Any], paths.allSatisfy({ $0 is String }) {
                    result.settings.extraPath = paths.compactMap { $0 as? String }
                        .filter { !$0.isEmpty }
                        .map(expandingTilde)
                } else if let single = value as? String {
                    result.settings.extraPath = [expandingTilde(single)]
                } else {
                    warn("git.extraPath must be an array of directory strings.")
                }
            }
        }

        if let graph = section("graph", in: root, warn: warn) {
            for key in graph.keys.sorted() where !["pageSize", "dateStyle"].contains(key) {
                warn("Unknown setting \"graph.\(key)\".")
            }
            if let value = graph["pageSize"] {
                if let size = integer(value) {
                    let clamped = clamp(size, to: Limits.graphPageSize)
                    if clamped != size {
                        warn("graph.pageSize must be \(Limits.graphPageSize.lowerBound)–\(Limits.graphPageSize.upperBound); clamped to \(clamped).")
                    }
                    result.settings.graphPageSize = clamped
                } else {
                    warn("graph.pageSize must be a number.")
                }
            }
            if let value = graph["dateStyle"] {
                if let raw = value as? String, let style = AppSettings.DateStyle(rawValue: raw) {
                    result.settings.dateStyle = style
                } else {
                    warn("graph.dateStyle must be \"relative\" or \"absolute\".")
                }
            }
        }

        if let pull = section("pull", in: root, warn: warn) {
            for key in pull.keys.sorted() where key != "mode" {
                warn("Unknown setting \"pull.\(key)\".")
            }
            if let value = pull["mode"] {
                if let raw = value as? String, let mode = PullMode(rawValue: raw) {
                    result.settings.pullMode = mode
                } else {
                    warn("pull.mode must be \"ff\", \"ff-only\" or \"rebase\".")
                }
            }
        }

        if let diff = section("diff", in: root, warn: warn) {
            for key in diff.keys.sorted() where key != "contextLines" {
                warn("Unknown setting \"diff.\(key)\".")
            }
            if let value = diff["contextLines"] {
                if let lines = integer(value) {
                    let clamped = clamp(lines, to: Limits.diffContextLines)
                    if clamped != lines {
                        warn("diff.contextLines must be \(Limits.diffContextLines.lowerBound)–\(Limits.diffContextLines.upperBound); clamped to \(clamped).")
                    }
                    result.settings.diffContextLines = clamped
                } else {
                    warn("diff.contextLines must be a number.")
                }
            }
        }

        if let keybindings = section("keybindings", in: root, warn: warn) {
            for key in keybindings.keys.sorted() where !["prefixKey", "prefixTimeoutMs", "bindings"].contains(key) {
                warn("Unknown setting \"keybindings.\(key)\".")
            }
            if let value = keybindings["prefixKey"] {
                let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.count == 1 {
                    result.keybindings.prefixKey = trimmed.lowercased()
                } else {
                    warn("keybindings.prefixKey must be a single character; kept \"\(result.keybindings.prefixKey)\".")
                }
            }
            if let value = keybindings["prefixTimeoutMs"] {
                if let timeout = integer(value) {
                    let clamped = clamp(timeout, to: Limits.prefixTimeoutMs)
                    if clamped != timeout {
                        warn("keybindings.prefixTimeoutMs must be \(Limits.prefixTimeoutMs.lowerBound)–\(Limits.prefixTimeoutMs.upperBound); clamped to \(clamped).")
                    }
                    result.keybindings.prefixTimeoutMs = clamped
                } else {
                    warn("keybindings.prefixTimeoutMs must be a number.")
                }
            }
            if let value = keybindings["bindings"] {
                if let bindings = value as? [String: Any] {
                    for id in bindings.keys.sorted() {
                        let entry = bindings[id]
                        if entry is NSNull {
                            result.keybindings.overrides[id] = .disabled
                        } else if let chord = entry as? String {
                            result.keybindings.overrides[id] = .chords([chord])
                        } else if let chords = entry as? [Any], chords.allSatisfy({ $0 is String }) {
                            result.keybindings.overrides[id] = .chords(chords.compactMap { $0 as? String })
                        } else {
                            warn("keybindings.bindings.\(id) must be a chord string, an array of chords, or null.")
                        }
                    }
                } else {
                    warn("keybindings.bindings must be an object of command id → chord.")
                }
            }
        }

        result.issues = issues
        return result
    }

    private static func section(
        _ key: String,
        in root: [String: Any],
        warn: (String) -> Void
    ) -> [String: Any]? {
        guard let value = root[key] else { return nil }
        guard let object = value as? [String: Any] else {
            warn("\"\(key)\" must be an object.")
            return nil
        }
        return object
    }

    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1e9 else { return nil }
        return Int(double)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(range.lowerBound, value), range.upperBound)
    }

    private static func expandingTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return "\"\(string)\"" }
        return String(describing: value)
    }
}

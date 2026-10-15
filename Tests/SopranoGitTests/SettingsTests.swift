import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct SettingsTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sg-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func everyKeyResolvesFromAJSONCDocument() throws {
        let resolved = try SettingsResolver.resolve(text: """
        // comment
        {
          "theme": "nord",
          "git": { "path": "/opt/homebrew/bin/git", "extraPath": ["/opt/tools/bin", "~/bin"] },
          "graph": { "pageSize": 500, "dateStyle": "absolute" },
          "pull": { "mode": "rebase" },
          "diff": { "contextLines": 5 },
          "keybindings": { "prefixKey": "B", "prefixTimeoutMs": 900, "bindings": { "repo.fetch": "cmd+shift+l", "x": ["j", "k"], "y": null } },
        }
        """)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(resolved.issues.isEmpty)
        #expect(resolved.settings == AppSettings(
            theme: "nord",
            gitPath: "/opt/homebrew/bin/git",
            extraPath: ["/opt/tools/bin", home + "/bin"],
            graphPageSize: 500,
            dateStyle: .absolute,
            pullMode: .rebase,
            diffContextLines: 5
        ))
        #expect(resolved.keybindings == KeybindingSettings(
            prefixKey: "b",
            prefixTimeoutMs: 900,
            overrides: ["repo.fetch": .chords(["cmd+shift+l"]), "x": .chords(["j", "k"]), "y": .disabled]
        ))
    }

    @Test func badValuesKeepTheirDefaultsWithWarnings() throws {
        let resolved = try SettingsResolver.resolve(text: """
        {
          "theme": "neon",
          "graph": { "pageSize": 5, "dateStyle": "sometimes" },
          "pull": { "mode": "merge" },
          "diff": { "contextLines": "three" },
          "keybindings": { "prefixKey": "ab", "prefixTimeoutMs": 10, "bindings": { "repo.fetch": 4 } },
          "colour": true
        }
        """)
        #expect(resolved.settings.theme == "soprano")
        #expect(resolved.settings.graphPageSize == 100)
        #expect(resolved.settings.dateStyle == .relative)
        #expect(resolved.settings.pullMode == .fastForwardIfPossible)
        #expect(resolved.settings.diffContextLines == 3)
        #expect(resolved.keybindings.prefixKey == "a")
        #expect(resolved.keybindings.prefixTimeoutMs == 300)
        #expect(resolved.keybindings.overrides.isEmpty)
        #expect(resolved.issues.count == 9)
        #expect(resolved.issues.allSatisfy { $0.severity == .warning })
    }

    @Test func theTemplateIsValidAndResolvesToTheDefaults() throws {
        let resolved = try SettingsResolver.resolve(text: SettingsFile.template)
        #expect(resolved.issues.isEmpty)
        #expect(resolved.settings == .defaults)
        #expect(resolved.keybindings == KeybindingSettings())
    }

    @Test func theFileIsCreatedFromTheTemplateOnFirstStart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/settings.json")
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())

        center.start(watching: false)

        #expect(try String(contentsOf: url, encoding: .utf8) == SettingsFile.template)
        #expect(center.settings == .defaults)
        #expect(center.issues.isEmpty)
    }

    @Test func aSyntaxErrorKeepsTheLastGoodSettings() {
        let center = SettingsCenter(fileURL: URL(fileURLWithPath: "/dev/null/settings.json"), registry: CommandRegistry())
        var notifications = 0
        let owner = NSObject()
        center.addObserver(owner) { notifications += 1 }

        center.apply(text: #"{ "graph": { "pageSize": 300 } }"#)
        center.apply(text: #"{ "graph": { "pageSize": 900 "#)

        #expect(center.settings.graphPageSize == 300)
        #expect(center.issues.count == 1)
        #expect(center.issues.first?.severity == .error)
        #expect(center.issues.first?.line == 1)

        center.apply(text: #"{ "graph": { "pageSize": 900 } }"#)
        #expect(center.settings.graphPageSize == 900)
        #expect(center.issues.isEmpty)
        #expect(notifications == 3)
    }

    @Test func liveEditsToTheFileReachObservers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "pull": { "mode": "ff" } }"#.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        let owner = NSObject()
        var notified = false
        center.addObserver(owner) { notified = true }
        center.start()
        defer { center.stop() }
        // The watcher arms on its own queue; give it a moment like a real edit would.
        try await Task.sleep(for: .milliseconds(200))

        try #"{ "pull": { "mode": "rebase" } }"#.write(to: url, atomically: true, encoding: .utf8)
        for _ in 0..<60 where center.settings.pullMode != .rebase {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(center.settings.pullMode == .rebase)
        #expect(notified)
    }

    @Test func theSopranoThemeSettingResolvesFromSopranosSettingsText() throws {
        #expect(ThemeCenter.resolveThemeID(setting: "soprano", sopranoSettingsText: #"{ "theme": "dracula" } // x"#) == "dracula")
        #expect(ThemeCenter.resolveThemeID(setting: "soprano", sopranoSettingsText: nil) == "mission-control")
        #expect(ThemeCenter.resolveThemeID(setting: "soprano", sopranoSettingsText: #"{ "theme": "vaporwave" }"#) == "mission-control")
        #expect(ThemeCenter.resolveThemeID(setting: "soprano", sopranoSettingsText: "{ broken") == "mission-control")
        #expect(ThemeCenter.resolveThemeID(setting: "nord", sopranoSettingsText: #"{ "theme": "dracula" }"#) == "nord")
    }

    @Test func theSopranoThemeUpdatesLiveWhenSopranosFileChanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "theme": "gruvbox-dark" }"#.write(to: url, atomically: true, encoding: .utf8)
        let center = ThemeCenter(sopranoSettingsURL: url)
        let owner = NSObject()
        var seen: [String] = []
        center.addObserver(owner) { seen.append($0.id) }

        center.apply(setting: "soprano")
        #expect(center.theme.id == "gruvbox-dark")
        try await Task.sleep(for: .milliseconds(200))

        try #"{ "theme": "tokyo-night" }"#.write(to: url, atomically: true, encoding: .utf8)
        for _ in 0..<60 where center.theme.id != "tokyo-night" {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(center.theme.id == "tokyo-night")

        center.apply(setting: "nord", watch: false)
        #expect(center.theme.id == "nord")
        #expect(seen == ["gruvbox-dark", "tokyo-night", "nord"])
    }
}

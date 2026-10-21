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

    @Test func writingAKeyKeepsTheFilesCommentsAndAppliesTheValue() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try SettingsFile.template.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)
        var notifications = 0
        let owner = NSObject()
        center.addObserver(owner) { notifications += 1 }

        #expect(center.write(500, at: ["graph", "pageSize"]))
        #expect(center.write("prefix+g", at: ["keybindings", "bindings", "repo.fetch"]))

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("// Commits loaded per page."))
        #expect(text.contains(#"// "branch.create": null"#))
        #expect(center.settings.graphPageSize == 500)
        #expect(center.keybindingSettings.overrides["repo.fetch"] == .chords(["prefix+g"]))
        #expect(notifications == 2)
        let reread = try SettingsResolver.resolve(text: text)
        #expect(reread.settings.graphPageSize == 500)
    }

    @Test func removingAKeyRestoresItsDefault() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "git": { "path": "/opt/tools/git" }, "keybindings": { "bindings": { "repo.fetch": null } } }"#
            .write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)

        #expect(center.remove(at: ["git", "path"]))
        #expect(center.remove(at: ["keybindings", "bindings", "repo.fetch"]))

        #expect(center.settings.gitPath == nil)
        #expect(center.keybindingSettings.overrides.isEmpty)
        #expect(center.configuredValue(at: ["git", "path"]) == nil)
    }

    @Test func aWriteEditsTheFileOnDiskEvenBeforeAHandEditWasReloaded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{ "pull": { "mode": "ff" } }"#.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)

        // A hand edit the (debounced) watcher has not delivered yet.
        try #"{ "pull": { "mode": "rebase" } }"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(center.write(5, at: ["diff", "contextLines"]))

        #expect(center.settings.pullMode == .rebase)
        #expect(center.settings.diffContextLines == 5)
    }

    @Test func aWriteToAFileWithASyntaxErrorLeavesTheFileAloneAndReportsIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let broken = #"{ "graph": { "pageSize": 900 "#
        try broken.write(to: url, atomically: true, encoding: .utf8)
        let center = SettingsCenter(fileURL: url, registry: CommandRegistry())
        center.start(watching: false)

        #expect(!center.write("rebase", at: ["pull", "mode"]))

        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
        #expect(center.settings.pullMode == .fastForwardIfPossible)
        #expect(center.issues.first?.severity == .error)
        #expect(center.issues.first?.message.hasPrefix("Could not update") == true)
    }

    private func resolve(_ setting: String, _ text: String?, _ system: AppTheme.Appearance) -> String {
        ThemeCenter.resolveThemeID(setting: setting, sopranoSettingsText: text, systemAppearance: system)
    }

    @Test func theThemeSettingAcceptsFolioAndPinnedIdsAndWarnsOnTheRemovedOnes() throws {
        for id in ["soprano", "folio", "folio-paper", "folio-ink", "nord"] {
            let resolved = try SettingsResolver.resolve(text: #"{ "theme": "\#(id)" }"#)
            #expect(resolved.issues.isEmpty)
            #expect(resolved.settings.theme == id)
        }
        let removed = try SettingsResolver.resolve(text: #"{ "theme": "mission-control" }"#)
        #expect(removed.settings.theme == "soprano")
        #expect(removed.issues.count == 1)
        #expect(removed.issues.first?.message.contains("soprano, folio, folio-paper, folio-ink") == true)
        #expect(SettingsFile.template.contains(#""folio", "folio-paper", "folio-ink""#))
    }

    @Test func theSopranoThemeSettingResolvesFromSopranosSettingsText() throws {
        #expect(resolve("soprano", #"{ "theme": "dracula" } // x"#, .light) == "dracula")
        #expect(resolve("soprano", #"{ "theme": "dracula", "appearance": "light" }"#, .dark) == "dracula")
        #expect(resolve("soprano", #"{ "theme": "folio-ink" }"#, .light) == "folio-ink")
    }

    @Test func sopranoFallbacksResolveToFolioByTheSystemAppearance() throws {
        for text in [nil, #"{ "theme": "vaporwave" }"#, #"{ "theme": "mission-control" }"#, "{ broken", #"{ "theme": 4 }"#, "{}"] {
            #expect(resolve("soprano", text, .light) == "folio-paper")
            #expect(resolve("soprano", text, .dark) == "folio-ink")
        }
    }

    @Test func sopranosAppearanceKeyPicksPaperOrInkForFolio() throws {
        #expect(resolve("soprano", #"{ "theme": "folio", "appearance": "light" }"#, .dark) == "folio-paper")
        #expect(resolve("soprano", #"{ "theme": "folio", "appearance": "dark" }"#, .light) == "folio-ink")
        #expect(resolve("soprano", #"{ "theme": "folio", "appearance": "system" }"#, .dark) == "folio-ink")
        #expect(resolve("soprano", #"{ "theme": "folio", "appearance": "system" }"#, .light) == "folio-paper")
        // A missing theme key is Folio; an unknown appearance follows the system.
        #expect(resolve("soprano", #"{ "appearance": "dark" }"#, .light) == "folio-ink")
        #expect(resolve("soprano", #"{ "theme": "folio", "appearance": "sepia" }"#, .dark) == "folio-ink")
        #expect(resolve("soprano", #"{ "theme": "folio", "appearance": "sepia" }"#, .light) == "folio-paper")
    }

    @Test func ownThemeIdsIgnoreSopranoAndFollowTheSystemOnlyForFolio() throws {
        let soprano = #"{ "theme": "dracula", "appearance": "dark" }"#
        #expect(resolve("folio", soprano, .light) == "folio-paper")
        #expect(resolve("folio", soprano, .dark) == "folio-ink")
        #expect(resolve("folio-paper", soprano, .dark) == "folio-paper")
        #expect(resolve("folio-ink", soprano, .light) == "folio-ink")
        #expect(resolve("nord", soprano, .light) == "nord")
        #expect(resolve("neon", soprano, .light) == "folio-paper")
        #expect(resolve("neon", soprano, .dark) == "folio-ink")
    }

    @Test func aForcedThemeWinsOverTheSetting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = ThemeCenter(sopranoSettingsURL: directory.appendingPathComponent("settings.json"))
        center.apply(setting: "nord", watch: false)
        #expect(center.theme.id == "nord")

        center.forcedThemeID = "folio-ink"
        #expect(center.theme.id == "folio-ink")
        center.apply(setting: "dracula", watch: false)
        #expect(center.theme.id == "folio-ink")

        center.forcedThemeID = nil
        #expect(center.theme.id == "dracula")
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

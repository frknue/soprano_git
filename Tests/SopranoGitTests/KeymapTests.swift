import AppKit
import Testing
@testable import SopranoGit

@MainActor
struct KeymapTests {
    private func command(_ id: String, scopes: Set<FocusRegion> = [], keys: [String]) -> AppCommand {
        AppCommand(id: id, title: id, category: .app, scopes: scopes, defaultKeys: keys, perform: { _ in })
    }

    private var commands: [AppCommand] {
        [
            command("repo.fetch", keys: ["cmd+l", "prefix+f"]),
            command("branch.create", keys: ["cmd+b", "b"]),
            command("graph.next", scopes: [.graph], keys: ["j"]),
            command("sidebar.next", scopes: [.sidebar], keys: ["j"]),
        ]
    }

    private func resolve(_ overrides: [String: BindingOverride], commands: [AppCommand]? = nil) -> Keymap {
        Keymap.resolve(commands: commands ?? self.commands, settings: KeybindingSettings(overrides: overrides))
    }

    @Test func defaultsComeFromTheRegisteredCommands() {
        let keymap = resolve([:])
        #expect(keymap.chords(for: "repo.fetch").map(\.canonicalString) == ["cmd+l", "prefix+f"])
        #expect(keymap.issues.isEmpty)
    }

    @Test func aStringOverrideReplacesEveryDefaultChord() {
        let keymap = resolve(["repo.fetch": .chords(["cmd+shift+l"])])
        #expect(keymap.chords(for: "repo.fetch").map(\.canonicalString) == ["cmd+shift+l"])
        #expect(keymap.customizedIDs == ["repo.fetch"])
    }

    @Test func anArrayOverrideBindsSeveralChords() {
        let keymap = resolve(["branch.create": .chords(["cmd+n", "n", "prefix+b"])])
        #expect(keymap.chords(for: "branch.create").map(\.canonicalString) == ["cmd+n", "n", "prefix+b"])
    }

    @Test func nullUnbindsTheCommand() {
        let keymap = resolve(["branch.create": .disabled])
        #expect(keymap.chords(for: "branch.create").isEmpty)
        #expect(keymap.issues.isEmpty)
    }

    @Test func anUnknownCommandIDIsAWarning() {
        let keymap = resolve(["repo.teleport": .chords(["cmd+y"])])
        #expect(keymap.issues.map(\.message) == ["keybindings.bindings: unknown command \"repo.teleport\"."])
        #expect(keymap.issues.allSatisfy { $0.severity == .warning })
    }

    @Test func aBadChordIsAWarningAndKeepsTheDefaults() {
        let keymap = resolve(["repo.fetch": .chords(["alt+f"])])
        #expect(keymap.chords(for: "repo.fetch").map(\.canonicalString) == ["cmd+l", "prefix+f"])
        #expect(keymap.issues.map(\.message) == ["keybindings.bindings.repo.fetch: \"alt+f\" is not a valid chord."])
    }

    @Test func aPartlyBadListKeepsItsValidChords() {
        let keymap = resolve(["repo.fetch": .chords(["cmd+shift+l", "hyper+f"])])
        #expect(keymap.chords(for: "repo.fetch").map(\.canonicalString) == ["cmd+shift+l"])
        #expect(keymap.issues.count == 1)
    }

    @Test func twoGlobalCommandsOnOneChordConflict() {
        let keymap = resolve(["repo.fetch": .chords(["cmd+b"])])
        #expect(keymap.issues.count == 1)
        #expect(keymap.issues.first?.message.contains("\"branch.create\" and \"repo.fetch\"") == true)
        #expect(keymap.conflictingIDs == ["branch.create", "repo.fetch"])
    }

    @Test func overlappingScopesConflictButARegionOverAGlobalBindingDoesNot() {
        // graph.next "j" (graph) vs sidebar.next "j" (sidebar): disjoint → fine.
        // branch.create "b" (global) vs a graph-scoped "b": region beats global → fine.
        var commands = commands
        commands.append(command("graph.branch", scopes: [.graph], keys: ["b"]))
        #expect(resolve([:], commands: commands).issues.isEmpty)
        #expect(resolve([:], commands: commands).conflictingIDs.isEmpty)

        let conflicting = resolve(["sidebar.next": .chords(["j"])], commands: commands + [
            command("graph.down", scopes: [.graph, .detail], keys: ["j"]),
        ])
        #expect(conflicting.issues.map(\.message) == [
            "\"graph.down\" and \"graph.next\" are both bound to J in graph; only \"graph.next\" will fire.",
        ])
    }

    @Test func symbolChordsConflictRegardlessOfShift() {
        let keymap = resolve([:], commands: [
            command("help.shortcuts", keys: ["?"]),
            command("other", keys: ["shift+?"]),
        ])
        #expect(keymap.issues.count == 1)
    }

    @Test func bindingThePrefixChordItselfIsAWarning() {
        let keymap = resolve(["repo.fetch": .chords(["ctrl+a"])])
        #expect(keymap.issues.count == 1)
        #expect(keymap.issues.first?.message.contains("prefix key") == true)
        #expect(keymap.conflictingIDs == ["repo.fetch"])
    }

    @Test func settingsCenterMergesRegistryDefaultsWithOverridesForDisplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sg-keymap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CommandRegistry()
        registry.register(commands)
        let center = SettingsCenter(fileURL: directory.appendingPathComponent("settings.json"), registry: registry)
        center.apply(text: """
        { "keybindings": { "prefixKey": "b", "bindings": { "repo.fetch": ["prefix+shift+f", "cmd+l"], "branch.create": null } } }
        """)

        #expect(center.shortcutText(for: "repo.fetch") == "Prefix → Shift+F")
        #expect(center.keycapText(for: "repo.fetch") == "⌃B ⇧F")
        #expect(center.chords(for: "repo.fetch").count == 2)
        #expect(center.shortcutText(for: "branch.create") == nil)
        #expect(center.shortcutText(for: "graph.next") == "J")
        #expect(center.keymap.prefixKey == "b")
    }
}

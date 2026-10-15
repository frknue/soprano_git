import AppKit
import Testing
@testable import SopranoGit

/// The binding table is spread over every module's `…Commands.all`; only the
/// assembled set shows whether two modules claim the same key.
@MainActor
struct DefaultKeymapTests {
    private func allCommands() -> [AppCommand] {
        let registry = CommandRegistry()
        AllCommands.registerAll(in: registry)
        return registry.commands
    }

    @Test func theShippedBindingsResolveWithoutAnyConflict() {
        let keymap = Keymap.resolve(commands: allCommands(), settings: KeybindingSettings(overrides: [:]))
        #expect(keymap.issues.map(\.message) == [])
    }

    @Test func everyDefaultChordParses() {
        for command in allCommands() {
            for key in command.defaultKeys {
                #expect(KeyChord.parse(key) != nil, "\(command.id): \(key)")
            }
        }
    }

    @Test func slashFiltersTheSidebarThereAndSearchesTheGraphEverywhereElse() {
        let commands = allCommands()
        let slash = commands.filter { $0.defaultKeys.contains("/") }
        #expect(Set(slash.map(\.id)) == ["graph.search", "sidebar.focusFilter"])
        #expect(slash.first { $0.id == "sidebar.focusFilter" }?.scopes == [.sidebar])
        #expect(slash.first { $0.id == "graph.search" }?.scopes == [])
    }
}

import AppKit
import Testing
@testable import SopranoGit

/// The welcome tab's key hints: K1 caps from the live keymap, J and K as two
/// caps, unbound commands left out.
@MainActor
struct WelcomeScreenTests {
    private func makeCenter(_ text: String) throws -> (SettingsCenter, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sg-welcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = CommandRegistry()
        AllCommands.registerAll(in: registry)
        let center = SettingsCenter(fileURL: directory.appendingPathComponent("settings.json"), registry: registry)
        center.apply(text: text)
        return (center, directory)
    }

    @Test func moveIsTwoCapsAndOpenSelectedIsReturn() throws {
        let (center, directory) = try makeCenter("{}")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hints = WelcomeViewController.hints(settings: center)
        #expect(hints.first { $0.label == "Move" }?.caps == ["J", "K"])
        #expect(hints.first { $0.label == "Open Selected" }?.caps == ["↵"])
        #expect(hints.map(\.label).contains("Commands"))
    }

    @Test func anUnboundCommandDropsItsHint() throws {
        let (center, directory) = try makeCenter(#"{ "keybindings": { "bindings": { "help.shortcuts": null } } }"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!WelcomeViewController.hints(settings: center).map(\.label).contains("Shortcuts"))
    }
}

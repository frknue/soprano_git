import AppKit
import Testing
@testable import SopranoGit

/// The settings tab: one per window, keyboard-routed as the settings region,
/// and shortcut recording that hands keys from the router to settings.json.
@MainActor
struct SettingsScreenTests {
    private func makeCenter() throws -> (SettingsCenter, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sg-screen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        let registry = CommandRegistry()
        AllCommands.registerAll(in: registry)
        let center = SettingsCenter(fileURL: url, registry: registry)
        center.start(watching: false)
        return (center, directory)
    }

    private func makeScreen(_ center: SettingsCenter) -> (SettingsViewController, KeyboardRouter) {
        let router = KeyboardRouter(registry: center.registry, keymap: { center.keymap }, context: { nil })
        let screen = SettingsViewController(center: center, router: router)
        _ = screen.view
        screen.show(.keyboard)
        return (screen, router)
    }

    @Test func settingsOpenAsOneTabThatIsReselectedAndRoutesAsTheSettingsRegion() {
        let controller = MainWindowController(state: .volatile(), persistsState: false, frame: NSRect(x: -20000, y: -20000, width: 1200, height: 800))
        controller.newTab()

        controller.showSettings()
        controller.selectTab(0)
        controller.showSettings(page: .git)

        #expect(controller.tabs.count == 2)
        #expect(controller.currentTab?.settings?.page == .git)
        #expect(controller.currentTab?.title == "Settings")
        #expect(controller.commandContext().focus == .settings)
        controller.closeCurrentTab()
        #expect(controller.tabs.allSatisfy { $0.settings == nil })
    }

    @Test func aRecordedPrefixChordIsWrittenAsTheCommandsBinding() throws {
        let (center, directory) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (screen, router) = makeScreen(center)

        screen.startRecording("repo.fetch")
        router.capture?(KeyStroke(key: "a", ctrl: true))
        router.capture?(KeyStroke(key: "g"))

        #expect(center.keybindingSettings.overrides["repo.fetch"] == .chords(["prefix+g"]))
        #expect(center.chords(for: "repo.fetch").map(\.canonicalString) == ["prefix+g"])
        #expect(router.capture == nil)
        #expect(screen.recordingCommandID == nil)
        let text = try String(contentsOf: center.fileURL, encoding: .utf8)
        #expect(text.contains("// Soprano Git settings."))
    }

    @Test func escapeCancelsRecordingWithoutTouchingTheFile() throws {
        let (center, directory) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try String(contentsOf: center.fileURL, encoding: .utf8)
        let (screen, router) = makeScreen(center)

        screen.startRecording("repo.fetch")
        router.capture?(KeyStroke(key: "l", meta: true, option: true))
        #expect(router.capture != nil)
        router.capture?(KeyStroke(key: "\u{1B}"))

        #expect(router.capture == nil)
        #expect(screen.recordingCommandID == nil)
        #expect(try String(contentsOf: center.fileURL, encoding: .utf8) == before)
    }

    @Test func leavingTheSettingsTabStopsRecording() {
        let controller = MainWindowController(state: .volatile(), persistsState: false, frame: NSRect(x: -20000, y: -20000, width: 1200, height: 800))
        controller.newTab()
        controller.showSettings(page: .keyboard)
        controller.currentTab?.settings?.startRecording("repo.fetch")
        #expect(controller.router.capture != nil)

        controller.selectTab(0)

        #expect(controller.router.capture == nil)
        #expect(controller.tabs[1].settings?.recordingCommandID == nil)
    }
}

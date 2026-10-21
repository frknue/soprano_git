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

    @Test func theThemePopupFollowsSopranoThenListsEveryThemeOption() throws {
        let (center, directory) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (screen, _) = makeScreen(center)
        screen.show(.general)

        let popup = try #require(screen.themePopup)
        let values = popup.itemArray.map { $0.representedObject as? String }
        #expect(values == ["soprano"] + AppTheme.options.map(\.id))
        #expect(popup.itemArray.first?.title == "Follow Soprano")
        #expect(popup.itemArray.map(\.title).contains("Folio Paper"))
        #expect(popup.selectedItem?.representedObject as? String == center.settings.theme)
    }

    @Test func keyboardRowsShowOneNeutralCapGroupPerChordAndACustomChipWhenCustomized() throws {
        let (center, directory) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        center.write("prefix+g", at: ["keybindings", "bindings", "repo.fetch"])
        let (screen, _) = makeScreen(center)

        let fetch = try #require(screen.shortcutRows["repo.fetch"])
        #expect(fetch.keycapGroups.map(\.caps) == [["⌃A", "G"]])
        #expect(fetch.keycapGroups.allSatisfy { $0.tone == .primary })
        let chip = try #require(fetch.customChip)
        #expect(chip.text == "Custom")
        #expect(chip.style == .outline)

        let other = try #require(screen.shortcutRows.first { $0.key != "repo.fetch" && !$0.value.keycapGroups.isEmpty }?.value)
        #expect(other.keycapGroups.allSatisfy { $0.tone == .primary })
        #expect(other.customChip == nil)
    }

    @Test func theRecordingPromptIsMutedLabelText() throws {
        let (center, directory) = try makeCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (screen, _) = makeScreen(center)

        screen.startRecording("repo.fetch")
        defer { screen.stopRecording(rerender: false) }
        let prompt = try #require(screen.shortcutRows["repo.fetch"]?.recordingPrompt)
        let attributes = prompt.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        #expect(attributes[.foregroundColor] as? NSColor == ThemeCenter.shared.theme.colors.textMuted)
        #expect((attributes[.font] as? NSFont)?.pointSize == ChromeFont.label.pointSize)
    }

    @Test func aSettingsTextFieldShowsTheFocusEdgeWhileFocused() throws {
        let theme = AppTheme.folioPaper
        let field = try #require(SettingsForm(theme: theme).textField("value", width: 120) as? FocusReportingTextField)
        #expect(field.layer?.borderColor == theme.colors.borderStrong.cgColor)
        field.onFocusChange?(true)
        #expect(field.layer?.borderColor == theme.colors.fieldFocusEdge.cgColor)
        field.onFocusChange?(false)
        #expect(field.layer?.borderColor == theme.colors.borderStrong.cgColor)
    }
}

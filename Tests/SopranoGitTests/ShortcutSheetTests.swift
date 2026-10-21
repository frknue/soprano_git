import AppKit
import Testing
@testable import SopranoGit

/// The shortcut sheet: one K1 keycap group per chord, a floating panel that
/// follows the theme's appearance.
@MainActor
struct ShortcutSheetTests {
    @Test func eachChordIsItsOwnKeycapGroup() {
        let entry = ShortcutEntry(id: "repo.fetch", title: "Fetch", category: .remote, keys: [["⌘L"], ["⌃A", "F"]])
        let row = ShortcutRow(entry: entry, theme: .folioPaper)
        #expect(row.keycapGroups.map(\.caps) == [["⌘L"], ["⌃A", "F"]])
        #expect(ShortcutRow(entry: ShortcutEntry(id: "x", title: "X", category: .remote, keys: []), theme: .folioInk).keycapGroups.isEmpty)
    }

    @Test func thePanelTakesItsAppearanceFromTheTheme() {
        let sheet = ShortcutSheetPanel()
        #expect(sheet.appearance?.name == ThemeCenter.shared.theme.appearance.nsAppearance.name)
        #expect(!sheet.hasShadow)
    }
}

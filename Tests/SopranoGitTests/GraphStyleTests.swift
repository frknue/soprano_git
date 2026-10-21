import AppKit
import Testing
@testable import SopranoGit

@MainActor
struct GraphStyleTests {
    private func theme(_ id: String) -> AppTheme {
        AppTheme.theme(for: id, appearance: .light)
    }

    @Test(arguments: [AppTheme.folioPaper.id, AppTheme.folioInk.id, AppTheme.nord.id])
    func lanesAreTheThemesGraphLanes(themeID: String) {
        let theme = theme(themeID)
        #expect(theme.id == themeID)
        let style = GraphStyle(theme: theme)

        #expect(style.lanes == theme.graphLanes)
        #expect(style.lanes.count == 8)
        #expect(style.lanes.first == theme.colors.textMuted, "lane 0 is the graphite trunk")
    }

    /// Folio's lanes use no accent slot; a third-party theme's accent may coincide
    /// with one of its signal colors.
    @Test(arguments: [AppTheme.folioPaper.id, AppTheme.folioInk.id])
    func noLaneIsTheAccent(themeID: String) {
        let theme = theme(themeID)
        let accent = theme.colors.accent.usingColorSpace(.sRGB)!
        for lane in GraphStyle(theme: theme).lanes {
            let color = lane.usingColorSpace(.sRGB)!
            let isAccent = abs(color.redComponent - accent.redComponent) < 0.01
                && abs(color.greenComponent - accent.greenComponent) < 0.01
                && abs(color.blueComponent - accent.blueComponent) < 0.01
            #expect(!isAccent, "\(theme.id): a lane equals the accent")
        }
    }

    @Test func laneColorsRepeatAfterThePalette() {
        let style = GraphStyle(theme: .folioPaper)
        #expect(style.laneColor(style.lanes.count + 2) == style.laneColor(2))
    }

    @Test func theSelectedRowDrawsAuthorDateAndShaInInk() {
        let theme = AppTheme.folioPaper
        let style = GraphStyle(theme: theme)

        #expect(style.metaAttributes[.foregroundColor] as? NSColor == theme.colors.textMuted)
        #expect(style.selectedMetaAttributes[.foregroundColor] as? NSColor == theme.colors.textPrimary)
        #expect(style.shaAttributes[.foregroundColor] as? NSColor == theme.colors.textMuted)
        #expect(style.selectedShaAttributes[.foregroundColor] as? NSColor == theme.colors.textPrimary)
        #expect((style.shaAttributes[.font] as? NSFont)?.isFixedPitch == true, "SHAs are SF Mono")
    }
}

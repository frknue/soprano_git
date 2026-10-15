import AppKit
import Testing
@testable import SopranoGit

@MainActor
struct GraphStyleTests {
    @Test(arguments: AppTheme.allThemes.map(\.id))
    func everyThemeGivesEightToTenDistinctLaneColors(themeID: String) {
        let palette = GraphStyle.palette(for: AppTheme.theme(for: themeID))
        let rgb = palette.map { color -> [Double] in
            let srgb = color.usingColorSpace(.sRGB)!
            return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map(Double.init)
        }

        #expect((8 ... 10).contains(palette.count), "\(themeID): \(palette.count) lane colors")
        for (index, color) in rgb.enumerated() {
            for other in rgb[(index + 1)...] {
                #expect(zip(color, other).contains { abs($0 - $1) > 0.02 }, "\(themeID): duplicate lane color")
            }
        }
    }

    @Test func theFirstLaneIsTheThemeAccent() {
        let theme = AppTheme.missionControl
        #expect(GraphStyle.palette(for: theme).first == theme.colors.accent)
    }

    @Test func laneColorsRepeatAfterThePalette() {
        let style = GraphStyle(theme: .missionControl)
        #expect(style.laneColor(style.lanes.count + 2) == style.laneColor(2))
    }
}

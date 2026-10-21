import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct ChangeKindBadgeTests {
    let colors = AppTheme.folioPaper.colors

    @Test func everyKindMapsToItsLetter() {
        let expected: [(ChangeKind, String)] = [
            (.added, "A"), (.modified, "M"), (.deleted, "D"), (.renamed, "R"),
            (.copied, "C"), (.typeChanged, "T"), (.unmerged, "U"), (.untracked, "?"),
        ]
        for (kind, letter) in expected {
            #expect(ChangeKindBadge.letter(for: kind) == letter)
        }
    }

    @Test func everyKindMapsToItsThemeColor() {
        let expected: [(ChangeKind, NSColor)] = [
            (.added, colors.success), (.untracked, colors.success),
            (.modified, colors.yellow),
            (.deleted, colors.danger), (.unmerged, colors.danger),
            (.renamed, colors.cyan), (.copied, colors.cyan),
            (.typeChanged, colors.blue),
        ]
        for (kind, color) in expected {
            #expect(ChangeKindBadge.color(for: kind, colors: colors) == color)
        }
    }

    @Test func badgeIsABareTwelvePointLetterInTheKindColor() {
        let badge = ChangeKindBadge(kind: .modified, theme: .folioPaper)
        #expect(badge.intrinsicContentSize.width == 12)
        #expect(badge.layer?.borderWidth ?? 0 == 0)
        badge.kind = .deleted
        badge.apply(theme: .nord)
        #expect(badge.letterText == "D")
        #expect(badge.letterColor == AppTheme.nord.colors.danger)
    }
}

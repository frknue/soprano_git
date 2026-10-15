import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct ChangeKindBadgeTests {
    let colors = AppTheme.missionControl.colors

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

    @Test func badgeIsAFixedSixteenPointSquare() {
        let badge = ChangeKindBadge(kind: .modified, theme: .missionControl)
        #expect(badge.intrinsicContentSize == NSSize(width: 16, height: 16))
        badge.kind = .deleted
        badge.apply(theme: .nord)
        #expect(badge.layer?.borderColor == AppTheme.nord.colors.danger.cgColor)
    }
}

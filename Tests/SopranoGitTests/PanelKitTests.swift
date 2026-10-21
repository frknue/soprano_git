import AppKit
import Testing
@testable import SopranoGit

@MainActor
struct PanelKitTests {
    let colors = AppTheme.folioPaper.colors

    private func width(_ path: String) -> CGFloat {
        ceil(PanelText.path(path, colors: colors).size().width)
    }

    private func color(of text: NSAttributedString, at substring: String) -> NSColor? {
        let range = (text.string as NSString).range(of: substring)
        return text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    @Test func aPathThatFitsIsShownWhole() {
        let path = "Sources/Soprano/Views/SidebarView.swift"
        #expect(PanelText.path(path, colors: colors).string == path)
        #expect(PanelText.path(path, colors: colors, availableWidth: width(path)).string == path)
    }

    @Test func aLongPathDropsWholeLeadingComponents() {
        let path = "Sources/Soprano/Views/SidebarView.swift"
        let views = "…/Views/SidebarView.swift"
        #expect(PanelText.path(path, colors: colors, availableWidth: width(views)).string == views)
        #expect(PanelText.path(path, colors: colors, availableWidth: width(views) - 1).string == "…/SidebarView.swift")
        // Narrower than the file name: the label truncates the head of `…/name`.
        #expect(PanelText.path(path, colors: colors, availableWidth: 10).string == "…/SidebarView.swift")
        #expect(PanelText.path("README.md", colors: colors, availableWidth: 10).string == "README.md")
    }

    @Test func aRenameShortensItsOldSideFirst() {
        let text = PanelText.path(
            "Sources/New/Name.swift",
            oldPath: "Sources/Old/Name.swift",
            colors: colors,
            availableWidth: width("Name.swift → Sources/New/Name.swift")
        )
        #expect(text.string == "Name.swift → Sources/New/Name.swift")
    }

    @Test func thePathMutesTheDirectoryAndSetsTheNameInSemiboldMono() {
        let text = PanelText.path("Sources/App/main.swift", colors: colors)
        #expect(color(of: text, at: "Sources/App/") == colors.textMuted)
        #expect(color(of: text, at: "main.swift") == colors.textPrimary)
        let range = (text.string as NSString).range(of: "main.swift")
        let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
        #expect(font == ChromeFont.monospaced(size: 12, weight: .semibold))
    }

    @Test func aZeroSideOfTheDiffstatIsMuted() {
        let added = PanelText.counts(additions: 2, deletions: 0, colors: colors)
        #expect(added.string == "+2 −0")
        #expect(color(of: added, at: "+2") == colors.success)
        #expect(color(of: added, at: "−0") == colors.textMuted)

        let deleted = PanelText.counts(additions: 0, deletions: 3, colors: colors)
        #expect(color(of: deleted, at: "+0") == colors.textMuted)
        #expect(color(of: deleted, at: "−3") == colors.danger)

        #expect(PanelText.counts(additions: 0, deletions: 0, colors: colors).string.isEmpty)
        #expect(PanelText.counts(additions: nil, deletions: nil, colors: colors).string == "bin")
        let font = added.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font == ChromeFont.monoSmall)
    }

    @Test func keyHintsDrawOneCapPerChord() {
        let button = KeyHintButton(title: "Stage", hint: nil, theme: .folioPaper)
        let bare = button.intrinsicContentSize.width
        button.hint = ["⌃A"]
        let oneCap = button.intrinsicContentSize.width
        button.hint = ["⌃A", "P"]
        let twoCaps = button.intrinsicContentSize.width
        #expect(oneCap > bare)
        #expect(twoCaps > oneCap)
        #expect(button.intrinsicContentSize.height == KeyHintButton.compactHeight)
    }

    @Test func headsRefIsTheInkPillAndOthersTakeTheLaneColor() {
        let theme = AppTheme.folioPaper
        let head = RefPillView(ref: .init(name: "main", kind: .localBranch, isHead: true), lane: 1, theme: theme)
        #expect(head.fillColor == theme.colors.inkButtonFill)
        #expect(RefPillView.symbolNames(for: head.ref) == ["checkmark", "laptopcomputer"])

        let remote = RefPillView(ref: .init(name: "origin/main", kind: .remoteBranch), lane: 1, theme: theme)
        #expect(remote.fillColor == theme.graphLanes[1].withAlphaComponent(0.10))
        #expect(remote.fillColor != theme.colors.accent.withAlphaComponent(0.10))
        #expect(RefPillView.symbolNames(for: remote.ref) == ["cloud"])
    }
}

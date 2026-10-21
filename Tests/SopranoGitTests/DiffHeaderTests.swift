import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct DiffHeaderTests {
    private func header() -> DiffHeaderView {
        let header = DiffHeaderView(theme: ThemeCenter.shared.theme)
        header.update(
            path: "Sources/SopranoGit/App/MainWindowController.swift", oldPath: nil, kind: .modified,
            additions: 16, deletions: 1, showCounts: true, side: .identifier("b7cc3da"), position: "Hunk 1 of 3"
        )
        header.show(layout: .split)
        return header
    }

    @Test func aWideStripShowsEverything() {
        let header = header()
        header.setFrameSize(NSSize(width: 1200, height: DiffHeaderView.height))
        #expect(header.compaction == .full)
        #expect(header.isPositionShown)
        #expect(header.positionText == "Hunk 1 of 3")
        #expect(header.isSideShown)
        #expect(header.sideText == "b7cc3da")
        #expect(header.previousButton.title == "Previous")
        #expect(header.nextButton.title == "Next")
        #expect(header.layoutControl.visibleTitles == ["Split", "Inline"])
        #expect(header.layoutControl.layout == .split)
        #expect(header.closeButton.title == "Close")
    }

    @Test func narrowingGivesUpPositionThenSideThenCaptionsThenCountsBeforeTheFileName() {
        let header = header()
        var seen: [DiffHeaderView.Compaction] = []
        for width in stride(from: 1200, through: 120, by: -5) {
            header.setFrameSize(NSSize(width: CGFloat(width), height: DiffHeaderView.height))
            if seen.last != header.compaction {
                seen.append(header.compaction)
            }
        }
        #expect(seen == DiffHeaderView.Compaction.allCases)

        header.setFrameSize(NSSize(width: 120, height: DiffHeaderView.height))
        #expect(!header.isPositionShown)
        #expect(!header.isSideShown)
        #expect(header.previousButton.title.isEmpty)
        #expect(header.nextButton.title.isEmpty)
        #expect(header.layoutControl.visibleTitles.isEmpty)
        #expect(header.closeButton.title.isEmpty)
        // The layout is still reported, and the texts stay available.
        #expect(header.layoutText == "Split")
        #expect(header.positionText == "Hunk 1 of 3")
        #expect(header.pathText == "Sources/SopranoGit/App/MainWindowController.swift")
    }

    @Test func theUnifiedLayoutIsTitledInline() {
        let header = header()
        header.show(layout: .unified)
        #expect(header.layoutText == "Inline")
        #expect(header.layoutControl.layout == .unified)
        #expect(DiffLayout.unified.rawValue == "unified")
    }

    @Test func clickingTheOtherSegmentAsksForItsLayout() {
        let header = header()
        var selected: [DiffLayout] = []
        header.layoutControl.onSelect = { selected.append($0) }
        #expect(header.layoutControl.accessibilityPerformPress())
        #expect(selected == [.unified])
    }

    @Test func theFocusRuleShowsOnlyWhileTheDiffIsFocused() {
        let header = header()
        #expect(!header.isFocusRuleShown)
        header.isFocused = true
        #expect(header.isFocusRuleShown)
        header.isFocused = false
        #expect(!header.isFocusRuleShown)
    }
}

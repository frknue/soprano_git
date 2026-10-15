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
            additions: 16, deletions: 1, showCounts: true, side: "b7cc3da", sideColor: nil, position: "Hunk 1/3"
        )
        header.show(layout: .split)
        return header
    }

    @Test func aWideStripShowsEverything() {
        let header = header()
        header.setFrameSize(NSSize(width: 1200, height: DiffHeaderView.height))
        #expect(header.compaction == .full)
        #expect(header.isPositionShown)
        #expect(header.isSideShown)
        #expect(header.layoutButton.title == "Split")
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
        #expect(header.layoutButton.title.isEmpty)
        #expect(header.closeButton.title.isEmpty)
        // The layout is still reported, and the texts stay available.
        #expect(header.layoutText == "Split")
        #expect(header.positionText == "Hunk 1/3")
        #expect(header.pathText == "Sources/SopranoGit/App/MainWindowController.swift")
    }
}

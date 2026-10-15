import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct GraphRefsViewTests {
    private func pill(_ name: String, isHead: Bool = false) -> RefPill {
        let branch = Branch(name: name, fullName: "refs/heads/\(name)", target: "c1", isRemote: false, isHead: isHead)
        return RefPill(kind: .branch(branch, remotes: []), isHead: isHead)
    }

    private func render(_ pills: [RefPill], width: CGFloat) throws -> GraphRefsView {
        let view = GraphRefsView(frame: NSRect(x: 0, y: 0, width: width, height: GraphMetrics.rowHeight))
        view.configure(pills: pills, lane: 0, match: .none, style: GraphStyle(theme: .missionControl))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return view
    }

    @Test func pillsThatDoNotFitCollapseIntoAPlusNChip() throws {
        let pills = [pill("main", isHead: true), pill("feature/login"), pill("release/2.0"), pill("hotfix")]

        let view = try render(pills, width: 170)

        #expect(view.pillFrames.count == 1)
        let chip = try #require(view.overflowFrame)
        #expect(chip.maxX <= 170)
        #expect(view.pill(at: NSPoint(x: chip.midX, y: chip.midY))?.name == "feature/login")
        #expect(view.pill(at: NSPoint(x: view.pillFrames[0].midX, y: chip.midY))?.name == "main")
        #expect(view.toolTip == "main\nfeature/login\nrelease/2.0\nhotfix")
    }

    @Test func pillsThatFitAreAllShownWithoutAChip() throws {
        let view = try render([pill("main", isHead: true), pill("dev")], width: 400)

        #expect(view.pillFrames.count == 2)
        #expect(view.overflowFrame == nil)
    }

    @Test func aSinglePillTooWideForTheColumnIsTruncatedNotDropped() throws {
        let view = try render([pill("feature/a-very-long-branch-name-that-never-fits")], width: 110)

        #expect(view.pillFrames.count == 1)
        #expect(view.pillFrames[0].maxX <= 110)
        #expect(view.overflowFrame == nil)
    }
}

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
        try renderWithBitmap(pills, width: width).view
    }

    private func renderWithBitmap(_ pills: [RefPill], width: CGFloat) throws -> (view: GraphRefsView, rep: NSBitmapImageRep) {
        let view = GraphRefsView(frame: NSRect(x: 0, y: 0, width: width, height: GraphMetrics.rowHeight))
        view.configure(pills: pills, lane: 1, match: .none, style: GraphStyle(theme: .folioPaper))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return (view, rep)
    }

    /// The pixel at view point (`x`, `y`) of a flipped view, in sRGB.
    private func pixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, viewWidth: CGFloat) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / viewWidth
        let color = try #require(rep.colorAt(x: Int(x * scale), y: Int(y * scale)))
        return try #require(color.usingColorSpace(.sRGB))
    }

    private func isClose(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.03
            && abs(a.greenComponent - b.greenComponent) < 0.03
            && abs(a.blueComponent - b.blueComponent) < 0.03
    }

    @Test func theHeadPillIsTheInkPill() throws {
        let colors = AppTheme.folioPaper.colors
        let (view, rep) = try renderWithBitmap([pill("main", isHead: true), pill("dev")], width: 400)
        let head = view.pillFrames[0]
        let other = view.pillFrames[1]

        let headFill = try pixel(rep, x: head.minX + 3, y: head.midY, viewWidth: 400)
        let otherFill = try pixel(rep, x: other.minX + 3, y: other.midY, viewWidth: 400)

        #expect(isClose(headFill, colors.inkButtonFill), "HEAD pill: ink fill")
        #expect(!isClose(otherFill, colors.inkButtonFill), "other pills: lane tint")
        #expect(!isClose(otherFill, colors.accent))
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

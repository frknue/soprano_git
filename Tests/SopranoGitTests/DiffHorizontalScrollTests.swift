import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
@Suite(.serialized)
struct DiffHorizontalScrollTests {
    private static let longLine = String(repeating: "wide ", count: 60) + "END"

    /// A repo whose `long.txt` gains a 303-character line and whose `short.txt`
    /// changes one short line.
    private func makeHarness() async throws -> PanelHarness {
        try await PanelHarness.make { script in
            try await script.commit("first", ["long.txt": "a\n", "short.txt": "b\n"])
            try script.write("long.txt", "a\n\(Self.longLine)\n")
            try script.write("short.txt", "c\n")
        }
    }

    /// An offscreen window the diff view moves into, so it is 900 pt wide
    /// (the harness window's center column is only as wide as it must be).
    private let host = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
        styleMask: [.borderless], backing: .buffered, defer: false
    )

    /// Opens `path`'s unstaged diff, laid out 900 pt wide.
    private func open(_ path: String, in harness: PanelHarness) async throws {
        let target = DiffTarget.unstaged(path: path)
        harness.controller.showDiff(OpenDiff(target: target, title: path))
        try await harness.waitUntil { harness.diff.loadedDiff?.target == target && !harness.diff.isLoading }
        let view = harness.diff.view
        if let content = host.contentView, view.superview !== content {
            host.isReleasedWhenClosed = false
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = [.width, .height]
            view.frame = content.bounds
            content.addSubview(view)
        }
        host.layoutIfNeeded()
        #expect(harness.diff.tableView.enclosingScrollView?.contentView.bounds.width ?? 0 > 800)
    }

    private func lineCellOffsets(_ diff: DiffViewController) -> [CGFloat] {
        (0..<diff.tableView.numberOfRows).compactMap {
            (diff.tableView.view(atColumn: 0, row: $0, makeIfNecessary: true) as? DiffLineRowCell)?.textOffset
        }
    }

    private func scrollEvent(dx: Int32, dy: Int32) throws -> NSEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0
        ))
        return try #require(NSEvent(cgEvent: event))
    }

    @Test func arrowScrollingMovesEveryLinesTextAndStopsAtTheEndOfTheWidestLine() async throws {
        let harness = try await makeHarness()
        defer { harness.close(); host.close() }
        try await open("long.txt", in: harness)
        let diff = harness.diff
        let limit = diff.textScroll.limit
        #expect(limit > 0)
        #expect(!diff.textScroller.isHidden)

        try harness.perform("diff.scrollRight", focus: .diff)
        let column = DiffRowStyle(theme: ThemeCenter.shared.theme, maxLineNumber: 1).columnWidth
        #expect(diff.textOffset == CGFloat(DiffViewController.arrowColumns) * column)
        #expect(lineCellOffsets(diff).allSatisfy { $0 == diff.textOffset })
        try harness.perform("diff.scrollLeft", focus: .diff)
        #expect(diff.textOffset == 0)

        diff.scrollText(columns: 10_000)
        #expect(diff.textOffset == limit)
        diff.scrollText(columns: -10_000)
        #expect(diff.textOffset == 0)

        // Split sides are half as wide, so the same line overflows further.
        diff.scrollText(columns: 10_000)
        diff.toggleLayout()
        #expect(diff.textScroll.limit > limit)
        #expect(diff.textOffset == limit)
        #expect(lineCellOffsets(diff).allSatisfy { $0 == limit })
    }

    @Test func anotherFileOpensUnscrolledAndShortLinesHideTheScroller() async throws {
        let harness = try await makeHarness()
        defer { harness.close(); host.close() }
        try await open("long.txt", in: harness)
        harness.diff.scrollText(columns: 20)
        #expect(harness.diff.textOffset > 0)

        try await open("short.txt", in: harness)
        #expect(harness.diff.textOffset == 0)
        #expect(harness.diff.textScroll.limit == 0)
        #expect(harness.diff.textScroller.isHidden)
        harness.diff.scrollText(columns: 20)
        #expect(harness.diff.textOffset == 0)
    }

    @Test func aSidewaysWheelScrollsTheTextAndAnUprightOneLeavesIt() async throws {
        let harness = try await makeHarness()
        defer { harness.close(); host.close() }
        try await open("long.txt", in: harness)
        let diff = harness.diff

        diff.tableView.scrollWheel(with: try scrollEvent(dx: -40, dy: 2))
        #expect(diff.textOffset > 0)
        let offset = diff.textOffset

        diff.tableView.scrollWheel(with: try scrollEvent(dx: 2, dy: -40))
        #expect(diff.textOffset == offset)
    }
}

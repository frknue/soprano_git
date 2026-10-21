import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
@Suite(.serialized)
struct DiffRowStylingTests {
    /// A hunk from `" ctx"`, `"-old"` and `"+new"` lines.
    private func hunk(_ spec: [String]) -> DiffHunk {
        var old = 1
        var new = 1
        var lines: [DiffLine] = []
        for item in spec {
            let text = String(item.dropFirst())
            switch item.first {
            case "-":
                lines.append(DiffLine(kind: .removed, text: text, oldNumber: old, newNumber: nil))
                old += 1
            case "+":
                lines.append(DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: new))
                new += 1
            default:
                lines.append(DiffLine(kind: .context, text: text, oldNumber: old, newNumber: new))
                old += 1
                new += 1
            }
        }
        return DiffHunk(oldStart: 1, oldCount: old - 1, newStart: 1, newCount: new - 1, section: "", lines: lines)
    }

    private func document(_ hunks: [DiffHunk]) -> DiffDocument {
        let file = FileDiff(oldPath: "a.swift", newPath: "a.swift", kind: .modified, isBinary: false, headerLines: [], hunks: hunks)
        return DiffDocument.build(files: [file], title: "a.swift")
    }

    private func style() -> DiffRowStyle {
        DiffRowStyle(theme: .folioPaper, maxLineNumber: 99)
    }

    /// The `.backgroundColor` runs of `text` as (range, color).
    private func backgrounds(_ text: NSAttributedString?) -> [(NSRange, NSColor)] {
        guard let text else { return [] }
        var runs: [(NSRange, NSColor)] = []
        text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let color = value as? NSColor { runs.append((range, color)) }
        }
        return runs
    }

    private static let change = ["    let plusButton = make()", "-        plusButton.leadingAnchor", "+        collapseAllButton.leadingAnchor"]

    @Test func wordEmphasisLandsOnTheChangedRangeInUnifiedCells() throws {
        let document = document([hunk(Self.change)])
        let lines = try #require(document.file?.hunks.first?.lines)
        let style = style()
        let removedRange = try #require(document.changedRange(hunk: 0, line: 1))
        let addedRange = try #require(document.changedRange(hunk: 0, line: 2))

        let cell = DiffLineCellView()
        cell.configure(line: lines[1], tokens: nil, emphasis: removedRange, style: style, isCurrentChange: false)
        let removed = backgrounds(cell.text)
        #expect(removed.map(\.0) == [removedRange])
        #expect(removed.map(\.1) == [style.colors.diffDeleteWord])
        #expect((cell.text.string as NSString).substring(with: removedRange) == "plus")

        cell.configure(line: lines[2], tokens: nil, emphasis: addedRange, style: style, isCurrentChange: false)
        let added = backgrounds(cell.text)
        #expect(added.map(\.0) == [addedRange])
        #expect(added.map(\.1) == [style.colors.diffAddWord])
        #expect((cell.text.string as NSString).substring(with: addedRange) == "collapseAll")

        cell.configure(line: lines[0], tokens: nil, emphasis: document.changedRange(hunk: 0, line: 0), style: style,
                       isCurrentChange: false)
        #expect(backgrounds(cell.text).isEmpty)
    }

    @Test func wordEmphasisLandsOnTheChangedRangeOnBothSidesOfASplitCell() throws {
        let document = document([hunk(Self.change)])
        let lines = try #require(document.file?.hunks.first?.lines)
        let style = style()
        #expect(document.splitRows.contains(.pair(hunk: 0, old: 1, new: 2)))
        let oldRange = try #require(document.changedRange(hunk: 0, line: 1))
        let newRange = try #require(document.changedRange(hunk: 0, line: 2))

        let cell = DiffSplitLineCellView()
        cell.configure(
            old: lines[1], oldTokens: nil, oldEmphasis: oldRange, new: lines[2], newTokens: nil, newEmphasis: newRange,
            style: style, isCurrentChange: false
        )
        #expect(backgrounds(cell.old.text).map(\.0) == [oldRange])
        #expect(backgrounds(cell.old.text).map(\.1) == [style.colors.diffDeleteWord])
        #expect(backgrounds(cell.new.text).map(\.0) == [newRange])
        #expect(backgrounds(cell.new.text).map(\.1) == [style.colors.diffAddWord])
    }

    @Test func wordEmphasisIsClampedToTheDrawnTextAndFollowsExpandedTabs() {
        let style = style()
        let long = DiffLine(
            kind: .added, text: String(repeating: "x", count: DiffRowStyle.maximumDrawnLength + 50), oldNumber: nil, newNumber: 1
        )
        let clamped = style.text(
            of: long, tokens: nil, emphasis: NSRange(location: DiffRowStyle.maximumDrawnLength - 10, length: 40)
        )
        #expect(backgrounds(clamped).map(\.0) == [NSRange(location: DiffRowStyle.maximumDrawnLength - 10, length: 10)])
        let past = style.text(of: long, tokens: nil, emphasis: NSRange(location: DiffRowStyle.maximumDrawnLength + 5, length: 3))
        #expect(backgrounds(past).isEmpty)

        // "a\tb" with "\tb" changed: the tab expands to four emphasised spaces.
        let tabbed = DiffLine(kind: .removed, text: "a\tb", oldNumber: 1, newNumber: nil)
        let text = style.text(of: tabbed, tokens: nil, emphasis: NSRange(location: 1, length: 2))
        #expect(text.string == "a    b")
        #expect(backgrounds(text).map(\.0) == [NSRange(location: 1, length: 5)])
    }

    @Test func rowsUseFoliosDiffTintsAndSemiboldMarkers() {
        let style = style()
        let colors = style.colors
        #expect(style.tint(for: .added) == colors.diffAdd)
        #expect(style.tint(for: .removed) == colors.diffDelete)
        #expect(style.tint(for: .context) == nil)
        #expect(style.numberWidth == DiffRowStyle.minimumNumberWidth)
        #expect(style.gutterWidth == 2 * DiffRowStyle.minimumNumberWidth)
        for marker in [style.addedMarker, style.removedMarker] {
            #expect(marker.attribute(.font, at: 0, effectiveRange: nil) as? NSFont === style.semiboldFont)
        }
        #expect(style.addedMarker.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == colors.success)
        #expect(style.removedMarker.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == colors.danger)
        #expect(style.number(12)?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == colors.textMuted)
    }

    @Test func theTickRowIsTheFirstChangeOfTheHunkInBothLayouts() {
        let document = document([hunk([" a", " b", "-c", "+C", "-d", " e"]), hunk([" f", "+g"])])
        // Unified: hunk 0 header at 0, its first change (-c) at 3; hunk 1 header at 7, +g at 9.
        #expect(document.firstChangedRow(ofHunk: 0, in: .unified) == 3)
        #expect(document.firstChangedRow(ofHunk: 1, in: .unified) == 9)
        // Split: a, b, (c|C), (d|-), e → the first pair with a change is row 3.
        #expect(document.firstChangedRow(ofHunk: 0, in: .split) == 3)
        #expect(document.splitRows[3] == .pair(hunk: 0, old: 2, new: 3))
        #expect(document.firstChangedRow(ofHunk: 1, in: .split) == 8)
        #expect(document.firstChangedRow(ofHunk: 2, in: .split) == nil)
        #expect(self.document([hunk([" only context"])]).firstChangedRow(ofHunk: 0, in: .unified) == nil)
    }

    @Test func theTickSitsOnTheRemovedSideOfASplitRowElseTheAddedSide() throws {
        let document = document([hunk(["-a", "+b", "+c"])])
        let lines = try #require(document.file?.hunks.first?.lines)
        let style = style()

        let unified = DiffLineCellView()
        unified.configure(line: lines[0], tokens: nil, emphasis: nil, style: style, isCurrentChange: true)
        #expect(unified.tickX == Chrome.tickInset)
        unified.configure(line: lines[1], tokens: nil, emphasis: nil, style: style, isCurrentChange: false)
        #expect(unified.tickX == nil)

        let split = DiffSplitLineCellView()
        split.frame = NSRect(x: 0, y: 0, width: 800, height: DiffSplitLineCellView.rowHeight)
        split.configure(
            old: lines[0], oldTokens: nil, oldEmphasis: nil, new: lines[1], newTokens: nil, newEmphasis: nil,
            style: style, isCurrentChange: true
        )
        #expect(split.tickX == Chrome.tickInset)
        split.configure(
            old: nil, oldTokens: nil, oldEmphasis: nil, new: lines[2], newTokens: nil, newEmphasis: nil,
            style: style, isCurrentChange: true
        )
        #expect(split.tickX == split.dividerX + 1 + Chrome.tickInset)
        split.configure(
            old: nil, oldTokens: nil, oldEmphasis: nil, new: lines[2], newTokens: nil, newEmphasis: nil,
            style: style, isCurrentChange: false
        )
        #expect(split.tickX == nil)
    }

    // MARK: - In the diff view

    /// 20 lines; the working copy changes line 2 and line 18 (two hunks).
    private static let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
    private static let edited = (1...20).map { index in
        index == 2 || index == 18 ? "line \(index) changed" : "line \(index)"
    }.joined(separator: "\n") + "\n"

    /// Rows whose line cell carries the pencil tick.
    private func tickRows(_ diff: DiffViewController) -> [Int] {
        (0..<diff.tableView.numberOfRows).filter { row in
            (diff.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? DiffLineRowCell)?.isCurrentChange == true
        }
    }

    @Test func onlyTheFirstChangedRowOfTheCurrentHunkCarriesTheTick() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["f.txt": Self.original])
            try script.write("f.txt", Self.edited)
        }
        defer { harness.close() }
        harness.controller.showDiff(OpenDiff(target: .unstaged(path: "f.txt"), title: "f.txt"))
        try await harness.waitUntil {
            harness.diff.loadedDiff?.target == .unstaged(path: "f.txt") && !harness.diff.isLoading
        }
        let diff = harness.diff
        #expect(diff.currentHunk == 0)
        let first = try #require(diff.currentChangeRow)
        #expect(tickRows(diff) == [first])
        guard case let .line(hunk, line) = diff.rows[first] else {
            Issue.record("the tick row is not a line")
            return
        }
        #expect(diff.document.file?.hunks[hunk].lines[line].kind == .removed)

        #expect(try harness.perform("diff.nextHunk", focus: .diff))
        let second = try #require(diff.currentChangeRow)
        #expect(second != first)
        #expect(tickRows(diff) == [second])

        #expect(try harness.perform("diff.toggleLayout", focus: .diff))
        let split = try #require(diff.currentChangeRow)
        #expect(tickRows(diff) == [split])
        guard case let .pair(_, old?, _) = diff.rows[split] else {
            Issue.record("the split tick row has no removed line")
            return
        }
        #expect(diff.document.file?.hunks[1].lines[old].kind == .removed)
    }
}

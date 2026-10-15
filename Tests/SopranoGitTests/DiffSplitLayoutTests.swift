import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct DiffSplitLayoutTests {
    /// A hunk from `" ctx"`, `"-old"`, `"+new"` and `"\\"` (no newline) lines,
    /// numbered from `oldStart` / `newStart` like git's parser does.
    private func hunk(oldStart: Int = 1, newStart: Int = 1, _ spec: [String]) -> DiffHunk {
        var old = oldStart
        var new = newStart
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
            case "\\":
                lines.append(DiffLine(kind: .noNewlineMarker, text: "", oldNumber: nil, newNumber: nil))
            default:
                lines.append(DiffLine(kind: .context, text: text, oldNumber: old, newNumber: new))
                old += 1
                new += 1
            }
        }
        return DiffHunk(
            oldStart: oldStart, oldCount: old - oldStart, newStart: newStart, newCount: new - newStart, section: "",
            lines: lines
        )
    }

    private func document(_ hunks: [DiffHunk], oldMode: String? = nil, newMode: String? = nil,
                          lineLimit: Int = DiffDocument.lineLimit) -> DiffDocument {
        let file = FileDiff(
            oldPath: "a.txt", newPath: "a.txt", kind: .modified, isBinary: false, oldMode: oldMode, newMode: newMode,
            headerLines: [], hunks: hunks
        )
        return DiffDocument.build(files: [file], title: "a.txt", lineLimit: lineLimit)
    }

    /// The split rows after the hunk header, as (old, new) line indices.
    private func pairs(_ document: DiffDocument) -> [[Int?]] {
        document.splitRows.compactMap { row in
            if case let .pair(_, old, new) = row { [old, new] } else { nil }
        }
    }

    @Test func removedAndAddedLinesFaceEachOtherAndTheShorterSideGetsFillers() {
        let removedLonger = document([hunk([" c1", "-r1", "-r2", "-r3", "+a1", " c2"])])
        #expect(pairs(removedLonger) == [[0, 0], [1, 4], [2, nil], [3, nil], [5, 5]])

        let addedLonger = document([hunk([" c", "-r", "+a1", "+a2", "+a3"])])
        #expect(pairs(addedLonger) == [[0, 0], [1, 2], [nil, 3], [nil, 4]])
    }

    @Test func eachChangeBlockOfAHunkPairsOnItsOwn() {
        let document = document([hunk([" c1", "-r1", "+a1", "+a2", " c2", "-r2", "-r3", "+a3", "-r4", "+a4"])])
        #expect(pairs(document) == [
            [0, 0], [1, 2], [nil, 3],
            [4, 4], [5, 7], [6, nil],
            // A removed line after added ones starts the next block.
            [8, 9],
        ])
    }

    @Test func pureAdditionsAndPureDeletionsFaceFillers() {
        #expect(pairs(document([hunk(["+a1", "+a2"])])) == [[nil, 0], [nil, 1]])
        #expect(pairs(document([hunk(["-r1", "-r2", " c"])])) == [[0, nil], [1, nil], [2, 2]])
    }

    @Test func contextLinesShowTheirOwnOldAndNewNumbersOnBothSides() throws {
        let document = document([hunk(oldStart: 10, newStart: 12, [" before", "-gone", " after"])])
        #expect(pairs(document) == [[0, 0], [1, nil], [2, 2]])
        let lines = try #require(document.file?.hunks.first?.lines)
        let style = DiffRowStyle(theme: ThemeCenter.shared.theme, maxLineNumber: 99)
        let cell = DiffSplitLineCellView()
        cell.configure(old: lines[2], oldTokens: nil, new: lines[2], newTokens: nil, style: style, isCurrentHunk: false)
        #expect(cell.old.number?.string == "12")
        #expect(cell.new.number?.string == "13")
        #expect(cell.old.text?.string == "after")
        #expect(cell.new.text?.string == "after")

        cell.configure(old: lines[1], oldTokens: nil, new: nil, newTokens: nil, style: style, isCurrentHunk: false)
        #expect(cell.old.number?.string == "11")
        #expect(cell.new.line == nil)
    }

    @Test func noNewlineMarkersStayOnTheSideOfTheLineTheyFollow() {
        // Both sides end without a newline: the markers face each other.
        #expect(pairs(document([hunk(["-old", "\\", "+new", "\\"])])) == [[0, 2], [1, 3]])
        // Only the old side lacked one.
        #expect(pairs(document([hunk(["-old", "\\", "+new"])])) == [[0, 2], [1, nil]])
        // Only the new side lacks one.
        #expect(pairs(document([hunk([" a", "-b", "+c", "\\"])])) == [[0, 0], [1, 2], [nil, 3]])
        // A last context line without a newline: on both sides.
        #expect(pairs(document([hunk(["-x", "+y", " end", "\\"])])) == [[0, 1], [2, 2], [3, 3]])
    }

    @Test func hunkHeaderRowsLeadEachHunkAndNoticesCarryOver() {
        let document = document(
            [hunk(["-a", "+b"]), hunk(oldStart: 40, newStart: 40, [" c", "+d"])],
            oldMode: "100644", newMode: "100755"
        )
        #expect(document.splitRows == [
            .notice("File mode changed from 100644 to 100755."),
            .hunk(0), .pair(hunk: 0, old: 0, new: 1),
            .hunk(1), .pair(hunk: 1, old: 0, new: 0), .pair(hunk: 1, old: nil, new: 1),
        ])
        #expect(document.splitHunkRows == [1, 3])
        #expect(document.hunkRows(in: .split) == [1, 3])
        #expect(document.hunk(ofRow: 2, in: .split) == 0)
        #expect(document.hunk(ofRow: 5, in: .split) == 1)
        #expect(document.hunk(ofRow: 0, in: .split) == nil)
    }

    @Test func theSplitRowsStopAtTheSameLineLimitAsTheUnifiedOnes() {
        let document = document([hunk(["-a", "-b", "-c", "+d", "+e", "+f"])], lineLimit: 4)
        #expect(document.isTruncated)
        #expect(pairs(document) == [[0, 3], [1, nil], [2, nil]])
        #expect(document.splitRows.last == .notice("Large diff: showing the first 4 of 6 lines."))
    }
}

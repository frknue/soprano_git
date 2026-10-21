import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct DiffWordEmphasisTests {
    /// A hunk from `" ctx"`, `"-old"`, `"+new"` and `"\\"` (no newline) lines.
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
            case "\\":
                lines.append(DiffLine(kind: .noNewlineMarker, text: "", oldNumber: nil, newNumber: nil))
            default:
                lines.append(DiffLine(kind: .context, text: text, oldNumber: old, newNumber: new))
                old += 1
                new += 1
            }
        }
        return DiffHunk(oldStart: 1, oldCount: old - 1, newStart: 1, newCount: new - 1, section: "", lines: lines)
    }

    private func document(_ hunks: [DiffHunk], lineLimit: Int = DiffDocument.lineLimit) -> DiffDocument {
        let file = FileDiff(oldPath: "a.swift", newPath: "a.swift", kind: .modified, isBinary: false, headerLines: [], hunks: hunks)
        return DiffDocument.build(files: [file], title: "a.swift", lineLimit: lineLimit)
    }

    private func ranges(_ old: String, _ new: String) -> [NSRange]? {
        DiffDocument.changedRanges(old: old, new: new).map { [$0.old, $0.new] }
    }

    @Test func theDifferingMiddleBetweenASharedPrefixAndSuffixIsEmphasized() {
        let old = "                plusButton.leadingAnchor, constant: -6),"
        let new = "                collapseAllButton.leadingAnchor, constant: -6),"
        #expect(ranges(old, new) == [NSRange(location: 16, length: 4), NSRange(location: 16, length: 11)])
    }

    @Test func equalLinesAndLinesThatShareNeitherEndHaveNoEmphasis() {
        #expect(ranges("let a = 1", "let a = 1") == nil)
        #expect(ranges("alpha", "gamma!") == nil)
        #expect(ranges("", "") == nil)
    }

    @Test func aPureInsertionInsideALineLeavesTheOtherSideEmpty() {
        #expect(ranges("let a = 1", "let a = 10") == [NSRange(location: 9, length: 0), NSRange(location: 9, length: 1)])
        #expect(ranges("f(a, b)", "f(a)") == [NSRange(location: 3, length: 3), NSRange(location: 3, length: 0)])
    }

    @Test func rangesCountUTF16UnitsAndNeverSplitASurrogatePair() {
        // 😀 and 😃 share their lead surrogate: the prefix stops before it.
        #expect(ranges("a😀b", "a😃b") == [NSRange(location: 1, length: 2), NSRange(location: 1, length: 2)])
        // U+1F600 and U+1FA00 share their trail surrogate: the suffix stops after it.
        #expect(ranges("x\u{1F600}", "x\u{1FA00}") == [NSRange(location: 1, length: 2), NSRange(location: 1, length: 2)])
        #expect(ranges("é = 1", "é = 2") == [NSRange(location: 4, length: 1), NSRange(location: 4, length: 1)])
    }

    @Test func theNthRemovedLineOfAChangeIsComparedWithItsNthAddedLine() {
        let document = document([hunk([
            " ctx", "-let a = 1", "-let b = 2", "+let a = 10", "+let c = 2", "+extra", " end",
        ])])
        #expect(document.changedRange(hunk: 0, line: 1) == nil)
        #expect(document.changedRange(hunk: 0, line: 3) == NSRange(location: 9, length: 1))
        #expect(document.changedRange(hunk: 0, line: 2) == NSRange(location: 4, length: 1))
        #expect(document.changedRange(hunk: 0, line: 4) == NSRange(location: 4, length: 1))
        #expect(document.changedRange(hunk: 0, line: 5) == nil)
        #expect(document.changedRange(hunk: 0, line: 0) == nil)
        #expect(document.changedRanges.count == 3)
    }

    @Test func eachChangeBlockAndEachHunkPairsOnItsOwn() {
        let document = document([
            hunk(["-one x", "+one y", " c", "-two x", "+two y"]),
            hunk(["-a(1)", "+a(2)"]),
        ])
        #expect(document.changedRange(hunk: 0, line: 0) == NSRange(location: 4, length: 1))
        #expect(document.changedRange(hunk: 0, line: 1) == NSRange(location: 4, length: 1))
        #expect(document.changedRange(hunk: 0, line: 3) == NSRange(location: 4, length: 1))
        #expect(document.changedRange(hunk: 0, line: 4) == NSRange(location: 4, length: 1))
        #expect(document.changedRange(hunk: 1, line: 0) == NSRange(location: 2, length: 1))
        #expect(document.changedRange(hunk: 1, line: 1) == NSRange(location: 2, length: 1))
    }

    @Test func noNewlineMarkersAndLinesPastTheLineLimitGetNoEmphasis() {
        let marked = document([hunk(["-end x", "\\", "+end y", "+more"])])
        #expect(marked.changedRange(hunk: 0, line: 0) == NSRange(location: 4, length: 1))
        #expect(marked.changedRange(hunk: 0, line: 2) == NSRange(location: 4, length: 1))
        #expect(marked.changedRange(hunk: 0, line: 1) == nil)
        #expect(marked.changedRange(hunk: 0, line: 3) == nil)

        let capped = document([hunk(["-value x", "+value y"])], lineLimit: 1)
        #expect(capped.changedRanges.isEmpty)
    }
}

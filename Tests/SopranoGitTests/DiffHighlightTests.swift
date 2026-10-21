import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
@Suite(.serialized)
struct DiffHighlightTests {
    private func open(_ target: DiffTarget, title: String, in harness: PanelHarness) async throws {
        harness.controller.showDiff(OpenDiff(target: target, title: title))
        try await harness.waitUntil {
            harness.diff.loadedDiff?.target == target && !harness.diff.isLoading && !harness.diff.isHighlighting
        }
    }

    private func kinds(_ tokens: [SyntaxToken]?) -> [SyntaxTokenKind] {
        (tokens ?? []).map(\.kind)
    }

    @Test func aBlockCommentOpenedAboveTheHunkColorsTheHunkAsCommentOnBothSides() async throws {
        // Line 1 opens a comment that closes on line 30; the change is on line 20.
        let lines = ["/*"] + (2...29).map { "text \($0)" } + ["*/", "let x = 1"]
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.swift": lines.joined(separator: "\n") + "\n"])
            var edited = lines
            edited[19] = "changed 20"
            try script.write("a.swift", edited.joined(separator: "\n") + "\n")
        }
        defer { harness.close() }
        try await open(.unstaged(path: "a.swift"), title: "a.swift", in: harness)

        let hunk = try #require(harness.diff.document.file?.hunks.first)
        #expect(hunk.oldStart > 1, "the shown hunk does not contain the comment opener")
        let highlights = harness.diff.highlights
        #expect(highlights.old[20] == [SyntaxToken(range: NSRange(location: 0, length: 7), kind: .comment)])
        #expect(highlights.new[20] == [SyntaxToken(range: NSRange(location: 0, length: 10), kind: .comment)])
        #expect(kinds(highlights.old[18]) == [.comment])
        #expect(kinds(highlights.new[18]) == [.comment])

        // Both split cells of the changed row draw their text in the comment color.
        let comment = SyntaxTokenKind.comment.color(in: ThemeCenter.shared.theme.colors)
        harness.diff.toggleLayout()
        let row = try #require(harness.diff.rows.firstIndex { row in
            guard case let .pair(_, old?, new?) = row else { return false }
            return hunk.lines[old].kind == .removed && hunk.lines[new].kind == .added
        })
        let cell = try #require(harness.diff.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? DiffSplitLineCellView)
        for text in [cell.old.text, cell.new.text] {
            let color = text?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            #expect(color == comment)
        }
    }

    @Test func tokensLandOnTheirOwnOldAndNewLineNumbers() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.swift": "let a = 1\nlet b = 2\nlet c = 3\n"])
            try script.write("a.swift", "let a = 1\n// inserted\nlet b = \"two\"\nlet c = 3\n")
        }
        defer { harness.close() }
        try await open(.unstaged(path: "a.swift"), title: "a.swift", in: harness)
        let highlights = harness.diff.highlights

        // Old line 2 is `let b = 2`; new line 2 the comment, new line 3 `let b = "two"`.
        #expect(highlights.old[2] == [
            SyntaxToken(range: NSRange(location: 0, length: 3), kind: .keyword),
            SyntaxToken(range: NSRange(location: 8, length: 1), kind: .number),
        ])
        #expect(highlights.new[2] == [SyntaxToken(range: NSRange(location: 0, length: 11), kind: .comment)])
        #expect(highlights.new[3] == [
            SyntaxToken(range: NSRange(location: 0, length: 3), kind: .keyword),
            SyntaxToken(range: NSRange(location: 8, length: 5), kind: .string),
        ])
        // The unchanged last line: old line 3, new line 4.
        #expect(kinds(highlights.old[3]) == [.keyword, .number])
        #expect(kinds(highlights.new[4]) == [.keyword, .number])
        #expect(highlights.new[5] == nil)
    }

    @Test func aRenameHighlightsEachSideInTheLanguageOfItsOwnPath() async throws {
        let original = "# Title\n\nlet value = 1\nline four\nline five\nline six\n"
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["notes.md": original])
            try await script.git("mv", "notes.md", "notes.swift")
            try script.write("notes.swift", original.replacingOccurrences(of: "line six", with: "line 6"))
            try await script.git("add", "notes.swift")
        }
        defer { harness.close() }
        try await open(.staged(path: "notes.swift"), title: "notes.swift", in: harness)
        #expect(harness.diff.document.file?.kind == .renamed)
        let highlights = harness.diff.highlights

        // Markdown on the old side: a heading, and `let` is just text.
        #expect(kinds(highlights.old[1]) == [.heading])
        #expect(!kinds(highlights.old[3]).contains(.keyword))
        // Swift on the new side.
        #expect(!kinds(highlights.new[1]).contains(.heading))
        #expect(kinds(highlights.new[3]) == [.keyword, .number])
    }

    @Test func plainTextGetsNoColorsAndNeverFetchesTheWholeFile() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["f.txt": "let a = 1\n"])
            try script.write("f.txt", "let a = \"2\"\n")
        }
        defer { harness.close() }
        harness.controller.showDiff(OpenDiff(target: .unstaged(path: "f.txt"), title: "f.txt"))
        try await harness.waitUntil { harness.diff.loadedDiff != nil && !harness.diff.isLoading }
        #expect(!harness.diff.isHighlighting)
        #expect(harness.diff.highlights.isEmpty)
    }

    @Test func aSideOverTheSizeLimitStaysUncoloredWhileTheOtherSideIsColored() async throws {
        let long = "let s = \"" + String(repeating: "x", count: DiffHighlights.maximumLength + 10) + "\""
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["big.swift": "let a = 1\n"])
            try script.write("big.swift", "let a = 1\n" + long + "\n")
        }
        defer { harness.close() }
        try await open(.unstaged(path: "big.swift"), title: "big.swift", in: harness)
        #expect(!harness.diff.document.isTruncated)
        #expect(kinds(harness.diff.highlights.old[1]) == [.keyword, .number])
        #expect(harness.diff.highlights.new.isEmpty)
    }

    @Test func colorsOfAnEarlierLoadAreDroppedOnceTheDiffMovesOn() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.swift": "let a = 1\n", "b.swift": "let b = 1\n"])
            try script.write("a.swift", "let a = 2\n")
            try script.write("b.swift", "var b = 2\n")
        }
        defer { harness.close() }
        try await open(.unstaged(path: "a.swift"), title: "a.swift", in: harness)
        let first = harness.diff.loadGeneration
        #expect(!harness.diff.highlights.isEmpty)

        try await open(.unstaged(path: "b.swift"), title: "b.swift", in: harness)
        let current = harness.diff.highlights
        #expect(kinds(current.new[1]) == [.keyword, .number])
        let stale = DiffHighlights(old: [1: [SyntaxToken(range: NSRange(location: 0, length: 1), kind: .string)]], new: [:])
        #expect(!harness.diff.applyHighlights(stale, generation: first))
        #expect(harness.diff.highlights == current)
    }

    @Test func colorsAreRecomputedAfterAHunkIsStaged() async throws {
        let original = (1...20).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let edited = original
            .replacingOccurrences(of: "let v2 = 2\n", with: "let v2 = \"two\"\n")
            .replacingOccurrences(of: "let v18 = 18\n", with: "let v18 = \"eighteen\"\n")
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.swift": original])
            try script.write("a.swift", edited)
        }
        defer { harness.close() }
        try await open(.unstaged(path: "a.swift"), title: "a.swift", in: harness)
        #expect(kinds(harness.diff.highlights.old[2]) == [.keyword, .number])
        let generation = harness.diff.loadGeneration

        #expect(try harness.perform("diff.stageHunk", focus: .diff))
        try await harness.waitUntil {
            harness.diff.document.hunkCount == 1 && harness.diff.loadGeneration > generation
                && !harness.diff.isHighlighting
        }
        // The index now has line 2's new text, so the old side colors it as a string.
        #expect(kinds(harness.diff.highlights.old[2]) == [.keyword, .string])
        #expect(kinds(harness.diff.highlights.new[18]) == [.keyword, .string])
    }

    @Test func tokenKindsUseFoliosSyntaxColorsAndNeverTheAccent() {
        for theme in [AppTheme.folioPaper, AppTheme.folioInk] {
            let colors = theme.colors
            #expect(SyntaxTokenKind.keyword.color(in: colors) == colors.textPrimary)
            #expect(SyntaxTokenKind.heading.color(in: colors) == colors.textPrimary)
            #expect(SyntaxTokenKind.type.color(in: colors) == colors.cyan)
            #expect(SyntaxTokenKind.tag.color(in: colors) == colors.textPrimary)
            #expect(SyntaxTokenKind.string.color(in: colors) == colors.success)
            #expect(SyntaxTokenKind.inserted.color(in: colors) == colors.success)
            #expect(SyntaxTokenKind.comment.color(in: colors) == colors.textMuted)
            #expect(SyntaxTokenKind.number.color(in: colors) == colors.yellow)
            #expect(SyntaxTokenKind.attribute.color(in: colors) == colors.yellow)
            #expect(SyntaxTokenKind.function.color(in: colors) == colors.blue)
            #expect(SyntaxTokenKind.key.color(in: colors) == colors.blue)
            #expect(SyntaxTokenKind.deleted.color(in: colors) == colors.danger)
            let kinds: [SyntaxTokenKind] = [
                .keyword, .string, .comment, .number, .type, .function, .attribute, .key, .tag, .heading, .inserted, .deleted,
            ]
            for kind in kinds {
                #expect(kind.color(in: colors) != colors.accent)
                #expect(kind.color(in: colors) != colors.accentStrong)
            }
        }
    }

    @Test func keywordsDrawSemiboldAndCommentsItalic() throws {
        let style = DiffRowStyle(theme: .folioPaper, maxLineNumber: 9)
        let line = DiffLine(kind: .context, text: "let x = 1 // one", oldNumber: 1, newNumber: 1)
        let tokens = [
            SyntaxToken(range: NSRange(location: 0, length: 3), kind: .keyword),
            SyntaxToken(range: NSRange(location: 8, length: 1), kind: .number),
            SyntaxToken(range: NSRange(location: 10, length: 6), kind: .comment),
        ]
        let text = style.text(of: line, tokens: tokens, emphasis: nil)
        func font(at index: Int) -> NSFont? { text.attribute(.font, at: index, effectiveRange: nil) as? NSFont }
        func color(at index: Int) -> NSColor? { text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor }

        #expect(font(at: 0) === style.semiboldFont)
        #expect(color(at: 0) == style.colors.textPrimary)
        #expect(font(at: 12) === style.italicFont)
        #expect(style.italicFont.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(color(at: 12) == style.colors.textMuted)
        // Plain code and other tokens keep the regular SF Mono 12.
        let regular = try #require(font(at: 4))
        #expect(regular !== style.semiboldFont && regular !== style.italicFont)
        #expect(regular.pointSize == 12)
        #expect(font(at: 8) === regular)
        #expect(color(at: 8) == style.colors.yellow)
    }
}

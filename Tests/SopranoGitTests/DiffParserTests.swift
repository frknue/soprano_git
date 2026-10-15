import AppKit
import Testing
@testable import SopranoGitCore

struct DiffParserTests {
    /// `git diff --cached -M` of a commit touching every kind of change.
    private let patch = """
    diff --git a/bin.dat b/bin.dat
    index bdc955b..8835708 100644
    Binary files a/bin.dat and b/bin.dat differ
    diff --git a/crlf.txt b/crlf.txt
    index c30dea8..57213eb 100644
    --- a/crlf.txt
    +++ b/crlf.txt
    @@ -1,2 +1,2 @@
     a\r
    -b\r
    +B\r
    diff --git a/del.txt b/del.txt
    deleted file mode 100644
    index abaddc0..0000000
    --- a/del.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -del
    diff --git a/mode.sh b/mode.sh
    old mode 100644
    new mode 100755
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..3e75765
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1 @@
    +new
    diff --git a/nonl.txt b/nonl.txt
    index 1b32298..6e94b48 100644
    --- a/nonl.txt
    +++ b/nonl.txt
    @@ -1,2 +1,2 @@ func section()
     x
    -y
    \\ No newline at end of file
    +z
    \\ No newline at end of file
    diff --git a/ren.txt b/re named.txt
    similarity index 88%
    rename from ren.txt
    rename to re named.txt
    index 535d2b0..0719398 100644
    --- a/ren.txt
    +++ b/re named.txt\t
    @@ -6,3 +6,4 @@
     6
     7
     8
    +9

    """

    private var files: [FileDiff] { DiffParser.parse(Data(patch.utf8)) }

    @Test func eachDiffGitHeaderStartsOneFile() {
        #expect(files.map(\.path) == ["bin.dat", "crlf.txt", "del.txt", "mode.sh", "new.txt", "nonl.txt", "re named.txt"])
        #expect(files.map(\.kind) == [.modified, .modified, .deleted, .modified, .added, .modified, .renamed])
    }

    @Test func binaryFilesHaveNoHunks() {
        let binary = files[0]
        #expect(binary.isBinary)
        #expect(binary.hunks.isEmpty)
        #expect(binary.oldPath == "bin.dat" && binary.newPath == "bin.dat")
        #expect(binary.headerLines.last == "Binary files a/bin.dat and b/bin.dat differ")
    }

    @Test func crlfLinesKeepTheirCarriageReturn() {
        let hunk = files[1].hunks[0]
        #expect(hunk.lines.map(\.text) == ["a\r", "b\r", "B\r"])
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added])
        #expect(PatchBuilder.patch(for: hunk, of: files[1]).contains(Data("+B\r\n".utf8)))
    }

    @Test func deletedAndAddedFilesUseDevNullSides() {
        let deleted = files[2]
        #expect(deleted.oldPath == "del.txt" && deleted.newPath == nil)
        #expect(deleted.oldMode == "100644")
        #expect(deleted.hunks[0].oldStart == 1 && deleted.hunks[0].oldCount == 1)
        #expect(deleted.hunks[0].newStart == 0 && deleted.hunks[0].newCount == 0)

        let added = files[4]
        #expect(added.oldPath == nil && added.newPath == "new.txt")
        #expect(added.newMode == "100644")
        #expect(added.hunks[0].lines == [DiffLine(kind: .added, text: "new", oldNumber: nil, newNumber: 1)])
    }

    @Test func modeChangesRecordBothModes() {
        let mode = files[3]
        #expect(mode.oldMode == "100644" && mode.newMode == "100755")
        #expect(mode.hunks.isEmpty)
        #expect(mode.headerLines == ["diff --git a/mode.sh b/mode.sh", "old mode 100644", "new mode 100755"])
    }

    @Test func missingNewlineMarkersFollowTheirLine() {
        let hunk = files[5].hunks[0]
        #expect(hunk.section == "func section()")
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .noNewlineMarker, .added, .noNewlineMarker])
        #expect(hunk.lines[2].text == "\\ No newline at end of file")
        #expect(hunk.lines[2].oldNumber == nil && hunk.lines[2].newNumber == nil)
        #expect(hunk.lines[1].oldNumber == 2 && hunk.lines[3].newNumber == 2)
    }

    @Test func renamesUseTheRenameHeadersAndStripTheTrailingTab() {
        let renamed = files[6]
        #expect(renamed.oldPath == "ren.txt")
        #expect(renamed.newPath == "re named.txt")
        let hunk = renamed.hunks[0]
        #expect((hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount) == (6, 3, 6, 4))
        #expect(hunk.lines.map(\.oldNumber) == [6, 7, 8, nil])
        #expect(hunk.lines.map(\.newNumber) == [6, 7, 8, 9])
        #expect(renamed.headerLines.count == 7)
        #expect(renamed.headerLines.last == "+++ b/re named.txt\t")
    }

    @Test func patchBuilderRebuildsAFileByteExactly() {
        let text = patch
        let sections = text.components(separatedBy: "diff --git ").dropFirst().map { "diff --git " + $0 }
        for (file, original) in zip(files, sections) {
            #expect(String(decoding: PatchBuilder.patch(for: file.hunks, of: file), as: UTF8.self) == original)
        }
    }

    @Test func linesThatLookLikeHeadersInsideAHunkStayContent() {
        let tricky = """
        diff --git a/x b/x
        index 1..2 100644
        --- a/x
        +++ b/x
        @@ -1,2 +1,2 @@
        --- not a header
        +++ not a header either
         @@ context @@
        diff --git a/y b/y
        index 3..4 100644
        --- a/y
        +++ b/y
        @@ -1 +1 @@
        -1
        +2

        """
        let parsed = DiffParser.parse(Data(tricky.utf8))
        #expect(parsed.count == 2)
        #expect(parsed[0].hunks[0].lines.map(\.text) == ["-- not a header", "++ not a header either", "@@ context @@"])
        #expect(parsed[0].headerLines.count == 4)
    }

    @Test func quotedPathsAreUnquoted() {
        let quoted = """
        diff --git "a/tab\\there" "b/tab\\there"
        new file mode 100644
        index 0000000..1
        Binary files /dev/null and "b/tab\\there" differ
        diff --git "a/caf\\303\\251 \\"q\\"" "b/caf\\303\\251 \\"q\\""
        old mode 100644
        new mode 100755

        """
        let parsed = DiffParser.parse(Data(quoted.utf8))
        #expect(parsed[0].newPath == "tab\there")
        #expect(parsed[0].oldPath == nil)
        #expect(parsed[0].isBinary && parsed[0].kind == .added)
        #expect(parsed[1].path == "café \"q\"")
    }

    @Test func unquotedPathsWithSpacesSplitAtTheMiddle() {
        let modeOnly = "diff --git a/a b/c d b/a b/c d\nold mode 100644\nnew mode 100755\n"
        #expect(DiffParser.parse(Data(modeOnly.utf8)).first?.path == "a b/c d")
    }

    @Test func invalidUTF8DecodesLossily() {
        var data = Data("diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0x0A])
        data.append(Data("+ok\n".utf8))
        let line = DiffParser.parse(data).first?.hunks.first?.lines.first
        #expect(line?.kind == .removed)
        #expect(line?.text == "\u{FFFD}\u{FFFD}")
    }

    @Test func hunkHeadersWithoutCountsDefaultToOne() throws {
        let header = try #require(DiffParser.HunkHeader("@@ -3 +4 @@"))
        #expect((header.oldStart, header.oldCount, header.newStart, header.newCount) == (3, 1, 4, 1))
        #expect(header.section == "")
        #expect(DiffParser.HunkHeader("@@ nonsense") == nil)
    }
}

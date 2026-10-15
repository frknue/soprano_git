import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
@Suite(.serialized)
struct DiffHunkTests {
    /// 20 lines; the working copy changes line 2 and line 18 (two hunks).
    private static let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
    private static let edited = (1...20).map { index in
        index == 2 || index == 18 ? "line \(index) changed" : "line \(index)"
    }.joined(separator: "\n") + "\n"

    private func makeTwoHunkHarness(staged: Bool = false) async throws -> PanelHarness {
        try await PanelHarness.make { script in
            try await script.commit("first", ["f.txt": Self.original])
            try script.write("f.txt", Self.edited)
            if staged { try await script.git("add", "f.txt") }
        }
    }

    private func open(_ target: DiffTarget, in harness: PanelHarness) async throws {
        harness.controller.showDiff(OpenDiff(target: target, title: "f.txt"))
        try await harness.waitUntil { harness.diff.loadedDiff?.target == target && !harness.diff.isLoading }
    }

    private func hunkTexts(_ harness: PanelHarness) -> [String] {
        harness.diff.document.file?.hunks.map { $0.lines.filter { $0.kind == .added }.map(\.text).joined() } ?? []
    }

    @Test func stagingAHunkPutsOnlyThatHunkInTheIndexAndKeepsItsPosition() async throws {
        let harness = try await makeTwoHunkHarness()
        defer { harness.close() }
        try await open(.unstaged(path: "f.txt"), in: harness)
        #expect(harness.diff.document.hunkCount == 2)
        #expect(harness.diff.currentHunk == 0)

        #expect(try harness.perform("diff.stageHunk", focus: .diff))
        try await harness.waitUntil { harness.diff.document.hunkCount == 1 }
        let index = try await harness.script.indexContents("f.txt")
        #expect(index.contains("line 2 changed"))
        #expect(!index.contains("line 18 changed"))
        // The remaining (former second) hunk is now the current one.
        #expect(harness.diff.currentHunk == 0)
        #expect(hunkTexts(harness) == ["line 18 changed"])
        #expect(harness.controller.openDiff != nil)
    }

    @Test func stagingTheSecondHunkReloadsOntoTheHunkBeforeIt() async throws {
        let harness = try await makeTwoHunkHarness()
        defer { harness.close() }
        try await open(.unstaged(path: "f.txt"), in: harness)

        #expect(try harness.perform("diff.nextHunk", focus: .diff))
        #expect(harness.diff.currentHunk == 1)
        #expect(try harness.perform("diff.stageHunk", focus: .diff))
        try await harness.waitUntil { harness.diff.document.hunkCount == 1 }
        #expect(harness.diff.currentHunk == 0)
        #expect(hunkTexts(harness) == ["line 2 changed"])
        let index = try await harness.script.indexContents("f.txt")
        #expect(index.contains("line 18 changed"))
        #expect(!index.contains("line 2 changed"))
    }

    @Test func unstagingAHunkFromTheStagedDiffTakesItOutOfTheIndex() async throws {
        let harness = try await makeTwoHunkHarness(staged: true)
        defer { harness.close() }
        try await open(.staged(path: "f.txt"), in: harness)
        #expect(try !harness.isEnabled("diff.stageHunk", focus: .diff))
        #expect(try harness.isEnabled("diff.unstageHunk", focus: .diff))

        #expect(try harness.perform("diff.nextHunk", focus: .diff))
        #expect(try harness.perform("diff.unstageHunk", focus: .diff))
        try await harness.waitUntil { harness.diff.document.hunkCount == 1 }
        let index = try await harness.script.indexContents("f.txt")
        #expect(index.contains("line 2 changed"))
        #expect(!index.contains("line 18 changed"))
        #expect(try harness.script.read("f.txt") == Self.edited)
        #expect(hunkTexts(harness) == ["line 2 changed"])
    }

    @Test func discardingAHunkAsksThenRestoresThatPartOfTheWorktree() async throws {
        try await DialogTurn.exclusive {
            let harness = try await makeTwoHunkHarness()
            defer { harness.close() }
            try await open(.unstaged(path: "f.txt"), in: harness)

            #expect(try harness.perform("diff.nextHunk", focus: .diff))
            #expect(try harness.perform("diff.discardHunk", focus: .diff))
            try await harness.confirmDialog()
            try await harness.waitUntil { harness.diff.document.hunkCount == 1 }
            let contents = try harness.script.read("f.txt")
            #expect(contents.contains("line 2 changed"))
            #expect(!contents.contains("line 18 changed"))
            #expect(hunkTexts(harness) == ["line 2 changed"])
        }
    }

    @Test func stagingTheLastHunkClosesTheDiffAndFocusesTheCommitPanel() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["f.txt": "a\n"])
            try script.write("f.txt", "b\n")
        }
        defer { harness.close() }
        try await open(.unstaged(path: "f.txt"), in: harness)
        harness.workspace.focus(.diff)
        #expect(harness.workspace.focusedRegion == .diff)

        #expect(try harness.perform("diff.stageHunk", focus: .diff))
        try await harness.waitUntil { harness.controller.openDiff == nil }
        #expect(harness.entry("f.txt")?.staged == .modified)
        #expect(harness.workspace.focusedRegion == .detail)
    }

    @Test func nextAndPreviousFileFollowThePanelListAcrossSections() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "1\n", "b.txt": "1\n", "c.txt": "1\n"])
            try script.write("a.txt", "2\n")
            try script.write("b.txt", "2\n")
            try script.write("c.txt", "2\n")
            try await script.git("add", "c.txt")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()
        try harness.selectFile("a.txt", in: .unstaged)
        #expect(try harness.perform("panel.openFile"))
        #expect(harness.controller.openDiff == OpenDiff(target: .unstaged(path: "a.txt"), title: "a.txt"))

        #expect(try harness.perform("diff.nextFile", focus: .diff))
        #expect(harness.controller.openDiff?.target == .unstaged(path: "b.txt"))
        #expect(try harness.perform("diff.nextFile", focus: .diff))
        #expect(harness.controller.openDiff?.target == .staged(path: "c.txt"))
        #expect(harness.panel.selectedFile?.key == PanelFile.Key(section: .staged, path: "c.txt"))
        #expect(try harness.perform("diff.previousFile", focus: .diff))
        #expect(harness.controller.openDiff?.target == .unstaged(path: "b.txt"))
        try await harness.waitUntil { harness.diff.loadedDiff?.target == .unstaged(path: "b.txt") && !harness.diff.isLoading }
        #expect(harness.diff.document.file?.path == "b.txt")

        #expect(try harness.perform("diff.close", focus: .diff))
        #expect(harness.controller.openDiff == nil)
    }

    @Test func copyPutsTheCurrentHunkOnThePasteboard() async throws {
        let harness = try await makeTwoHunkHarness()
        defer { harness.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sg-panel-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        harness.diff.pasteboard = pasteboard
        try await open(.unstaged(path: "f.txt"), in: harness)

        #expect(try harness.perform("diff.nextHunk", focus: .diff))
        harness.diff.copy(nil)
        let text = try #require(pasteboard.string(forType: .string))
        #expect(text.contains("\n-line 18\n+line 18 changed\n"))
        #expect(text.hasPrefix("@@ -15,6 +15,6 @@"))
    }
}

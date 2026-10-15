import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
@Suite(.serialized)
struct DiffLayoutTests {
    /// 20 lines; the working copy changes line 2 and line 18 (two hunks).
    private static let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
    private static let edited = (1...20).map { index in
        index == 2 || index == 18 ? "line \(index) changed" : "line \(index)"
    }.joined(separator: "\n") + "\n"

    private func makeTwoHunkHarness(state: AppStateStore = .volatile(), staged: Bool = false) async throws -> PanelHarness {
        try await PanelHarness.make(state: state) { script in
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

    /// The list is scrolled so the current hunk's header row is at the top.
    private func isScrolledToCurrentHunk(_ harness: PanelHarness) -> Bool {
        let diff = harness.diff
        guard let row = diff.currentHunkRow, let clip = diff.tableView.enclosingScrollView?.contentView else { return false }
        return clip.bounds.minY == diff.tableView.rect(ofRow: row).minY
    }

    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let name = "sg-diff-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    @Test func theLayoutIsUnifiedByDefaultAndPersistsInTheStore() async throws {
        try await withDefaults { defaults in
            let store = AppStateStore(defaults: defaults)
            #expect(store.diffLayout == .unified)
            store.diffLayout = .split
            #expect(AppStateStore(defaults: defaults).diffLayout == .split)
        }
    }

    @Test func togglingKeepsTheCurrentHunkAndCarriesIntoANewDiffView() async throws {
        try await withDefaults { defaults in
            let first = try await makeTwoHunkHarness(state: AppStateStore(defaults: defaults))
            try await open(.unstaged(path: "f.txt"), in: first)
            #expect(first.diff.layout == .unified)
            #expect(first.diff.layoutToggleTitle == "Unified")
            #expect(try first.perform("diff.nextHunk", focus: .diff))
            #expect(isScrolledToCurrentHunk(first))
            let unifiedRow = first.diff.currentHunkRow

            #expect(try first.perform("diff.toggleLayout", focus: .diff))
            #expect(first.diff.layout == .split)
            #expect(first.diff.layoutToggleTitle == "Split")
            #expect(first.diff.currentHunk == 1)
            #expect(first.diff.currentHunkRow == first.diff.document.splitHunkRows[1])
            #expect(first.diff.currentHunkRow != unifiedRow)
            #expect(first.diff.tableView.numberOfRows == first.diff.document.splitRows.count)
            #expect(isScrolledToCurrentHunk(first))
            first.close()

            let second = try await makeTwoHunkHarness(state: AppStateStore(defaults: defaults))
            defer { second.close() }
            #expect(second.diff.layout == .split)
            try await open(.unstaged(path: "f.txt"), in: second)
            #expect(second.diff.rows == second.diff.document.splitRows)
            #expect(second.diff.layoutToggleTitle == "Split")

            #expect(try second.perform("diff.toggleLayout", focus: .diff))
            #expect(second.diff.rows == second.diff.document.rows)
            #expect(AppStateStore(defaults: defaults).diffLayout == .unified)
        }
    }

    @Test func theToggleWorksBeforeADiffIsOpenAndReachesEveryOpenTab() async throws {
        let state = AppStateStore.volatile()
        let first = try await makeTwoHunkHarness(state: state)
        defer { first.close() }
        let second = try await makeTwoHunkHarness(state: state)
        defer { second.close() }
        try await open(.unstaged(path: "f.txt"), in: second)

        #expect(first.controller.openDiff == nil)
        #expect(try first.isEnabled("diff.toggleLayout", focus: nil))
        #expect(try first.perform("diff.toggleLayout", focus: nil))
        #expect(first.diff.layout == .split)
        #expect(second.diff.layout == .split)
        #expect(second.diff.tableView.numberOfRows == second.diff.document.splitRows.count)
        #expect(second.diff.currentHunk == 0)
    }

    @Test func stagingAHunkWorksInTheSplitLayoutAndStaysSplit() async throws {
        let harness = try await makeTwoHunkHarness()
        defer { harness.close() }
        harness.diff.toggleLayout()
        try await open(.unstaged(path: "f.txt"), in: harness)
        #expect(harness.diff.layout == .split)

        #expect(try harness.perform("diff.nextHunk", focus: .diff))
        #expect(try harness.perform("diff.stageHunk", focus: .diff))
        try await harness.waitUntil { harness.diff.document.hunkCount == 1 }
        let index = try await harness.script.indexContents("f.txt")
        #expect(index.contains("line 18 changed"))
        #expect(!index.contains("line 2 changed"))
        #expect(harness.diff.currentHunk == 0)
        #expect(hunkTexts(harness) == ["line 2 changed"])
        #expect(harness.diff.layout == .split)
        #expect(harness.diff.tableView.numberOfRows == harness.diff.document.splitRows.count)
    }

    @Test func unstagingAHunkWorksInTheSplitLayout() async throws {
        let harness = try await makeTwoHunkHarness(staged: true)
        defer { harness.close() }
        harness.diff.toggleLayout()
        try await open(.staged(path: "f.txt"), in: harness)

        #expect(try harness.perform("diff.unstageHunk", focus: .diff))
        try await harness.waitUntil { harness.diff.document.hunkCount == 1 }
        let index = try await harness.script.indexContents("f.txt")
        #expect(!index.contains("line 2 changed"))
        #expect(index.contains("line 18 changed"))
        #expect(hunkTexts(harness) == ["line 18 changed"])
    }

    @Test func discardingAHunkWorksInTheSplitLayout() async throws {
        try await DialogTurn.exclusive {
            let harness = try await makeTwoHunkHarness()
            defer { harness.close() }
            harness.diff.toggleLayout()
            try await open(.unstaged(path: "f.txt"), in: harness)

            #expect(try harness.perform("diff.discardHunk", focus: .diff))
            try await harness.confirmDialog()
            try await harness.waitUntil { harness.diff.document.hunkCount == 1 }
            let contents = try harness.script.read("f.txt")
            #expect(!contents.contains("line 2 changed"))
            #expect(contents.contains("line 18 changed"))
        }
    }

    @Test func copyPutsTheSameUnifiedHunkTextOnThePasteboardInTheSplitLayout() async throws {
        let harness = try await makeTwoHunkHarness()
        defer { harness.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sg-split-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        harness.diff.pasteboard = pasteboard
        harness.diff.toggleLayout()
        try await open(.unstaged(path: "f.txt"), in: harness)

        #expect(try harness.perform("diff.nextHunk", focus: .diff))
        harness.diff.copy(nil)
        let text = try #require(pasteboard.string(forType: .string))
        #expect(text.hasPrefix("@@ -15,6 +15,6 @@"))
        #expect(text.contains("\n-line 18\n+line 18 changed\n"))
    }
}

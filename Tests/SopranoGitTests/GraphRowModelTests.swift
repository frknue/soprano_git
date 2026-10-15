import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

struct GraphRowModelTests {
    private typealias H = GraphHistory

    private func ids(_ model: GraphRowModel) -> [String] {
        model.entries.map(\.node.id)
    }

    @Test func aCleanTreeHasNoWorkingCopyRow() {
        let model = GraphRowModel(commits: H.forkAndMerge, stashes: [], workingCopy: .none, isComplete: true)

        #expect(ids(model) == ["m", "f2", "c", "f1", "b", "a"])
        #expect(!model.hasWorkingCopyRow)
        #expect(model.row(for: .workingCopy) == nil)
    }

    @Test func aDirtyTreeAddsTheWorkingCopyRowOnTopLeadingToHead() {
        let model = GraphRowModel(commits: H.forkAndMerge, stashes: [], workingCopy: .onHead("m"), isComplete: true)

        #expect(ids(model).first == GraphNode.workingCopyID)
        #expect(model.entries[0].layout.kind == .workingCopy)
        #expect(model.firstParentRow(of: 0) == 1)
        #expect(model.entries[0].layout.edges.allSatisfy { $0.isDashed })
    }

    @Test func aDirtyUnbornBranchStillGetsAWorkingCopyRow() {
        let model = GraphRowModel(commits: [], stashes: [], workingCopy: .unborn, isComplete: true)

        #expect(ids(model) == [GraphNode.workingCopyID])
        #expect(model.entries[0].layout.edges.isEmpty)
        #expect(model.selection(at: 0) == .workingCopy)
    }

    @Test func stashesSitAboveTheCommitTheyWereMadeOn() {
        let stashes = [
            H.stash(0, id: "s0", base: "c", hour: 7, message: "newest"),
            H.stash(1, id: "s1", base: "b", hour: 2, message: "on the fork point"),
        ]
        let model = GraphRowModel(commits: H.forkAndMerge, stashes: stashes, workingCopy: .none, isComplete: true)

        #expect(ids(model) == ["s0", "m", "f2", "c", "f1", "s1", "b", "a"])
        #expect(model.row(for: .stash(1)) == 5)
        #expect(model.selection(at: 0) == .stash(0))
        #expect(model.entries[5].layout.kind == .stash)
    }

    @Test func appendingAPageKeepsEveryEarlierRowUnchanged() {
        let commits = H.forkAndMerge
        var model = GraphRowModel(commits: Array(commits[0 ..< 3]), stashes: [], workingCopy: .onHead("m"), isComplete: false)
        let before = model.entries.map(\.layout)

        let range = model.append(Array(commits[3...]), isComplete: true)

        #expect(range == 4 ..< 7)
        #expect(Array(model.entries.prefix(before.count).map(\.layout)) == before)
        #expect(ids(model) == [GraphNode.workingCopyID, "m", "f2", "c", "f1", "b", "a"])
        #expect(model.commitCount == commits.count)
        #expect(model.isComplete)
    }

    @Test func pagedAndSingleShotLayoutsAreIdentical() {
        let history = RandomHistory(seed: 5, count: 900, mergePercent: 12, branchPercent: 10, rootPercent: 1, stashCount: 4)
        let whole = GraphRowModel(commits: history.commits, stashes: history.stashes, workingCopy: .onHead(history.head), isComplete: true)
        var paged = GraphRowModel(stashes: history.stashes, workingCopy: .onHead(history.head))
        var start = 0
        while start < history.commits.count {
            let end = min(start + 250, history.commits.count)
            paged.append(Array(history.commits[start ..< end]), isComplete: end == history.commits.count)
            start = end
        }

        #expect(paged.entries.map(\.layout) == whole.entries.map(\.layout))
    }

    @Test func leftoverStashesAppearOnceTheLastPageArrivesEvenIfItIsEmpty() {
        let orphan = H.stash(0, id: "orphan", base: "never-loaded", hour: 0)
        var model = GraphRowModel(commits: H.forkAndMerge, stashes: [orphan], workingCopy: .none, isComplete: false)
        #expect(model.row(for: .stash(0)) == nil)

        model.append([], isComplete: true)

        #expect(model.row(for: .stash(0)) == H.forkAndMerge.count)
        #expect(model.append([H.commit("late", hour: 0)], isComplete: true).isEmpty)
    }

    @Test func aRebuiltModelStartsFromScratch() {
        let first = GraphRowModel(commits: H.forkAndMerge, stashes: [], workingCopy: .onHead("m"), isComplete: true)
        let rebuilt = GraphRowModel(commits: Array(H.forkAndMerge.dropFirst()), stashes: [], workingCopy: .none, isComplete: true)

        #expect(first.count == 7)
        #expect(ids(rebuilt) == ["f2", "c", "f1", "b", "a"])
        #expect(rebuilt.row(forID: "m") == nil)
    }

    @Test func selectionsMapToRowsAndBack() {
        let stashes = [H.stash(0, id: "s0", base: "c", hour: 7)]
        let model = GraphRowModel(commits: H.forkAndMerge, stashes: stashes, workingCopy: .onHead("m"), isComplete: true)

        for row in 0 ..< model.count {
            let selection = model.selection(at: row)
            #expect(selection.flatMap { model.row(for: $0) } == row)
        }
        #expect(model.row(for: .commit("f1")) == 5)
        #expect(model.row(for: .commit("unknown")) == nil)
        #expect(model.selection(at: 99) == nil)
    }

    @Test func followingTheFirstParentWalksDownTheMainline() {
        let model = GraphRowModel(commits: H.forkAndMerge, stashes: [], workingCopy: .onHead("m"), isComplete: true)
        var path: [String] = []
        var row: Int? = 0
        while let current = row {
            path.append(model.entries[current].node.id)
            row = model.firstParentRow(of: current)
        }

        #expect(path == [GraphNode.workingCopyID, "m", "c", "b", "a"])
    }

    @Test func goingUpPrefersTheChildOnTheSameLane() {
        let model = GraphRowModel(commits: H.forkAndMerge, stashes: [], workingCopy: .none, isComplete: true)
        let row = { (id: String) in model.row(forID: id)! }
        let child = { (id: String) in model.childRow(of: row(id)).map { model.entries[$0].node.id } }

        // b has children f1 (right above, lane 1) and c (its own lane 0).
        #expect(model.entries[row("b")].layout.lane == model.entries[row("c")].layout.lane)
        #expect(child("b") == "c")
        #expect(child("c") == "m")
        #expect(child("f1") == "f2")
        // f2's only child is the merge on another lane.
        #expect(child("f2") == "m")
        #expect(child("m") == nil)
    }

    @Test func searchMatchesSummaryAuthorEmailAndIdPrefixIgnoringCase() {
        let commits = [
            H.commit("abc123", hour: 3, summary: "Add login screen", author: "Ada Lovelace", email: "ada@example.com"),
            H.commit("def456", ["abc123"], hour: 2, summary: "Fix crash", author: "Grace Hopper", email: "grace@navy.mil"),
        ]
        let model = GraphRowModel(commits: commits, stashes: [], workingCopy: .onHead("abc123"), isComplete: true)
        let rows = { (query: String) in GraphSearch.matchingRows(in: model.entries, range: 0 ..< model.count, query: query) }

        #expect(rows("LOGIN") == [1])
        #expect(rows("hopper") == [2])
        #expect(rows("NAVY.MIL") == [2])
        #expect(rows("DEF4") == [2])
        #expect(rows("456") == [], "ids match by prefix only")
        #expect(rows("wip") == [], "the working-copy row never matches")
        #expect(GraphSearch.normalized("   ") == nil)
    }
}

import AppKit
import Testing
@testable import SopranoGitCore

/// Builders shared by the graph tests.
enum GraphFixture {
    typealias Edge = GraphLayout.Edge

    static func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + seconds)) }

    static func commit(_ id: String, _ parents: [String] = [], date seconds: Int = 0) -> Commit {
        let signature = Signature(name: "Tester", email: "tester@example.com", date: date(seconds))
        return Commit(id: id, parents: parents, author: signature, committer: signature, summary: id)
    }

    static func stash(_ index: Int, _ id: String, base: String, date seconds: Int) -> Stash {
        Stash(index: index, id: id, base: base, message: "WIP on \(base)", date: date(seconds))
    }

    /// Commit nodes from `(id, parents)` pairs, in the given order.
    static func nodes(_ spec: [(String, [String])]) -> [GraphNode] {
        spec.map { GraphNode.commit(commit($0.0, $0.1)) }
    }

    static func pass(_ lane: Int, dashed: Bool = false) -> Edge {
        Edge(.passThrough, from: lane, to: lane, colorLane: lane, isDashed: dashed)
    }

    static func into(_ from: Int, _ to: Int, dashed: Bool = false) -> Edge {
        Edge(.intoNode, from: from, to: to, colorLane: from, isDashed: dashed)
    }

    static func out(_ from: Int, _ to: Int, color: Int, dashed: Bool = false) -> Edge {
        Edge(.outOfNode, from: from, to: to, colorLane: color, isDashed: dashed)
    }

    static func layout(_ nodes: [GraphNode]) -> [GraphLayout.Row] {
        var layout = GraphLayout()
        return layout.append(nodes)
    }
}

struct GraphLayoutTests {
    typealias F = GraphFixture

    @Test func linearHistoryStaysInLaneZero() {
        let rows = F.layout(F.nodes([("c3", ["c2"]), ("c2", ["c1"]), ("c1", [])]))

        #expect(rows.map(\.id) == ["c3", "c2", "c1"])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.map(\.kind) == [.commit, .commit, .commit])
        #expect(rows[0].edges == [F.out(0, 0, color: 0)])
        #expect(rows[1].edges == [F.into(0, 0), F.out(0, 0, color: 0)])
        #expect(rows[2].edges == [F.into(0, 0)])
        #expect(rows.map(\.laneCount) == [1, 1, 1])
        #expect(rows.map(\.maxLaneCount) == [1, 1, 1])
    }

    @Test func aSingleRootCommitIsOneNodeWithoutLines() {
        let rows = F.layout(F.nodes([("root", [])]))

        #expect(rows == [GraphLayout.Row(id: "root", kind: .commit, lane: 0, edges: [], laneCount: 1, maxLaneCount: 1)])
    }

    @Test func emptyInputProducesNoRows() {
        var layout = GraphLayout()

        #expect(layout.append([]).isEmpty)
        #expect(layout.maxLaneCount == 0)
        #expect(layout.openLaneCount == 0)
    }

    @Test func aFeatureBranchForksOffAndMergesBackWithNoFastForward() {
        // main: c0 ← c1 ← m; feature: c1 ← f1 ← f2, merged by m.
        let rows = F.layout(F.nodes([
            ("m", ["c1", "f2"]), ("f2", ["f1"]), ("f1", ["c1"]), ("c1", ["c0"]), ("c0", []),
        ]))

        #expect(rows.map(\.lane) == [0, 1, 1, 0, 0])
        #expect(rows.map(\.kind) == [.merge, .commit, .commit, .commit, .commit])
        // Merge: first parent stays in lane 0, second parent opens lane 1 in lane 1's color.
        #expect(rows[0].edges == [F.out(0, 0, color: 0), F.out(0, 1, color: 1)])
        #expect(rows[1].edges == [F.pass(0), F.into(1, 1), F.out(1, 1, color: 1)])
        // The feature line keeps its lane down to the fork point c1 and converges there.
        #expect(rows[2].edges == [F.pass(0), F.into(1, 1), F.out(1, 1, color: 1)])
        #expect(rows[3].edges == [F.into(0, 0), F.into(1, 0), F.out(0, 0, color: 0)])
        #expect(rows[4].edges == [F.into(0, 0)])
        #expect(rows.map(\.laneCount) == [2, 2, 2, 2, 1])
        #expect(rows.map(\.maxLaneCount) == [2, 2, 2, 2, 2])
    }

    @Test func twoTipsSharingAParentConvergeAtTheParentsRow() {
        let rows = F.layout(F.nodes([("a", ["p"]), ("b", ["p"]), ("p", [])]))

        #expect(rows.map(\.lane) == [0, 1, 0])
        #expect(rows[0].edges == [F.out(0, 0, color: 0)])
        #expect(rows[1].edges == [F.pass(0), F.out(1, 1, color: 1)])
        #expect(rows[2].edges == [F.into(0, 0), F.into(1, 0)])
        #expect(rows.map(\.laneCount) == [1, 2, 2])
    }

    @Test func anOlderMainCommitKeepsItsLaneWhenANewerFeatureTipSharesItsParent() {
        // main: mt ← m1 ← p ← r; feature: p ← f1 ← f2 (newer than m1); o2 ← o1 is unrelated.
        let rows = F.layout(F.nodes([
            ("mt", ["m1"]), ("f2", ["f1"]), ("f1", ["p"]), ("m1", ["p"]), ("o2", ["o1"]), ("o1", []),
            ("p", ["r"]), ("r", []),
        ]))
        let lane = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.lane) })

        #expect(["mt", "m1", "p", "r"].map { lane[$0] } == [0, 0, 0, 0])
        #expect(["f2", "f1"].map { lane[$0] } == [1, 1])
        #expect(["o2", "o1"].map { lane[$0] } == [2, 2])
        // m1 goes straight down lane 0 although the feature lane already waits for p.
        #expect(rows[3].edges == [F.into(0, 0), F.pass(1), F.out(0, 0, color: 0)])
        #expect(rows[4].edges == [F.pass(0), F.pass(1), F.out(2, 2, color: 2)])
        #expect(rows[5].edges == [F.pass(0), F.pass(1), F.into(2, 2)])
        // The feature lane ends at p's row, in its own color.
        #expect(rows[6].edges == [F.into(0, 0), F.into(1, 0), F.out(0, 0, color: 0)])
        #expect(rows[7].edges == [F.into(0, 0)])
        #expect(rows.map(\.laneCount) == [1, 2, 2, 2, 3, 3, 2, 1])
    }

    @Test func linesWaitingForTheSameCommitConvergeIntoItsRow() {
        // The working copy (dashed, HEAD = h) and a newer tip t on h both wait for h.
        let nodes = [GraphNode.workingCopy(head: "h")] + F.nodes([("t", ["h"]), ("h", ["r"]), ("r", [])])
        let rows = F.layout(nodes)

        #expect(rows.map(\.lane) == [0, 1, 0, 0])
        #expect(rows[1].edges == [F.pass(0, dashed: true), F.out(1, 1, color: 1)])
        #expect(rows[2].edges == [F.into(0, 0, dashed: true), F.into(1, 0), F.out(0, 0, color: 0)])
        #expect(rows[3].edges == [F.into(0, 0)])
        #expect(rows.map(\.laneCount) == [1, 2, 2, 1])
    }

    @Test func anOctopusMergeOpensOneLanePerExtraParent() {
        let rows = F.layout(F.nodes([("o", ["a", "b", "c"]), ("a", ["r"]), ("b", ["r"]), ("c", ["r"]), ("r", [])]))

        #expect(rows.map(\.lane) == [0, 0, 1, 2, 0])
        #expect(rows[0].kind == .merge)
        #expect(rows[0].edges == [F.out(0, 0, color: 0), F.out(0, 1, color: 1), F.out(0, 2, color: 2)])
        #expect(rows[1].edges == [F.into(0, 0), F.pass(1), F.pass(2), F.out(0, 0, color: 0)])
        #expect(rows[2].edges == [F.pass(0), F.into(1, 1), F.pass(2), F.out(1, 1, color: 1)])
        #expect(rows[3].edges == [F.pass(0), F.pass(1), F.into(2, 2), F.out(2, 2, color: 2)])
        #expect(rows[4].edges == [F.into(0, 0), F.into(1, 0), F.into(2, 0)])
        #expect(rows.map(\.laneCount) == [3, 3, 3, 3, 3])
        #expect(rows.last?.maxLaneCount == 3)
    }

    @Test func crissCrossMergesRouteMergeLinesIntoTheLanesAlreadyWaiting() {
        // m1 merges b into a, m2 merges a into b.
        let rows = F.layout(F.nodes([("m1", ["a", "b"]), ("m2", ["b", "a"]), ("a", ["r"]), ("b", ["r"]), ("r", [])]))

        #expect(rows.map(\.lane) == [0, 2, 0, 2, 0])
        #expect(rows[0].edges == [F.out(0, 0, color: 0), F.out(0, 1, color: 1)])
        // First parent continues down lane 2; second parent joins lane 0 in lane 0's color.
        #expect(rows[1].edges == [F.pass(0), F.pass(1), F.out(2, 2, color: 2), F.out(2, 0, color: 0)])
        #expect(rows[2].edges == [F.into(0, 0), F.pass(1), F.pass(2), F.out(0, 0, color: 0)])
        // b lands in m2's first-parent lane; m1's merge line ends there.
        #expect(rows[3].edges == [F.pass(0), F.into(1, 2), F.into(2, 2), F.out(2, 2, color: 2)])
        #expect(rows[4].edges == [F.into(0, 0), F.into(2, 0)])
        #expect(rows.map(\.laneCount) == [2, 3, 3, 3, 3])
    }

    @Test func aFreedLaneIsReusedAndTrailingFreeLanesAreDropped() {
        let rows = F.layout(F.nodes([
            ("a", ["c2"]), ("b", ["c2"]), ("d", ["c1"]), ("c2", ["c1"]), ("t", ["c1"]), ("c1", ["c0"]),
            ("u", ["c0"]), ("c0", []),
        ]))

        #expect(rows.map(\.lane) == [0, 1, 2, 0, 1, 0, 1, 0])
        // b's lane ends at c2; the next tip t takes the hole between lanes 0 and 2.
        #expect(rows[3].edges == [F.into(0, 0), F.into(1, 0), F.pass(2), F.out(0, 0, color: 0)])
        #expect(rows[4].edges == [F.pass(0), F.pass(2), F.out(1, 1, color: 1)])
        #expect(rows[5].edges == [F.into(0, 0), F.into(1, 0), F.into(2, 0), F.out(0, 0, color: 0)])
        // After lanes 1 and 2 end at c1, the next tip u is placed in lane 1, not lane 3.
        #expect(rows[6].edges == [F.pass(0), F.out(1, 1, color: 1)])
        #expect(rows.map(\.laneCount) == [1, 2, 3, 3, 3, 3, 2, 2])
        #expect(rows.map(\.maxLaneCount) == [1, 2, 3, 3, 3, 3, 3, 3])
    }

    @Test func aParentOnTheNextPageKeepsItsLaneOpenAcrossAppends() {
        let all = F.nodes([("m", ["c1", "f1"]), ("c1", ["c0"]), ("f1", ["c0"]), ("c0", [])])
        var layout = GraphLayout()

        let first = layout.append(Array(all[0 ..< 2]))
        #expect(layout.openLaneCount == 2)
        let second = layout.append(Array(all[2...]))

        #expect(first.map(\.id) == ["m", "c1"])
        #expect(second.map(\.id) == ["f1", "c0"])
        #expect(first[1].edges == [F.into(0, 0), F.pass(1), F.out(0, 0, color: 0)])
        #expect(second[0].edges == [F.pass(0), F.into(1, 1), F.out(1, 1, color: 1)])
        #expect(second[1].edges == [F.into(0, 0), F.into(1, 0)])
        #expect(first + second == F.layout(all))
        #expect(layout.openLaneCount == 0)
    }

    @Test func aParentThatIsNeverLoadedKeepsItsLaneOpenToTheLastRow() {
        let rows = F.layout(F.nodes([("c2", ["c1"]), ("c1", ["gone"]), ("x", [])]))

        #expect(rows.map(\.lane) == [0, 0, 1])
        #expect(rows[1].edges == [F.into(0, 0), F.out(0, 0, color: 0)])
        #expect(rows[2].edges == [F.pass(0)])
        #expect(rows[2].laneCount == 2)
    }

    @Test func theWorkingCopyRowDrawsADashedLineDownToAnOlderHead() {
        let nodes = [GraphNode.workingCopy(head: "h")]
            + F.nodes([("x2", ["x1"]), ("x1", ["b"]), ("h", ["b"]), ("b", [])])
        let rows = F.layout(nodes)

        #expect(rows.map(\.id) == [GraphNode.workingCopyID, "x2", "x1", "h", "b"])
        #expect(rows.map(\.kind) == [.workingCopy, .commit, .commit, .commit, .commit])
        #expect(rows.map(\.lane) == [0, 1, 1, 0, 0])
        #expect(rows[0].edges == [F.out(0, 0, color: 0, dashed: true)])
        #expect(rows[1].edges == [F.pass(0, dashed: true), F.out(1, 1, color: 1)])
        #expect(rows[2].edges == [F.pass(0, dashed: true), F.into(1, 1), F.out(1, 1, color: 1)])
        // HEAD ends the dashed line and continues solid in lane 0; x's lane ends at b.
        #expect(rows[3].edges == [F.into(0, 0, dashed: true), F.pass(1), F.out(0, 0, color: 0)])
        #expect(rows[4].edges == [F.into(0, 0), F.into(1, 0)])
        #expect(rows.map(\.laneCount) == [1, 2, 2, 2, 2])
    }

    @Test func aStashDrawsADashedSideLineThatConvergesIntoItsBase() {
        var sequence = GraphSequence(
            stashes: [F.stash(0, "s1", base: "c1", date: 25)], workingCopyParent: nil
        )
        let nodes = sequence.append(
            [F.commit("c3", ["c2"], date: 30), F.commit("c2", ["c1"], date: 20), F.commit("c1", [], date: 10)],
            isComplete: true
        )
        let rows = F.layout(nodes)

        #expect(rows.map(\.id) == ["c3", "s1", "c2", "c1"])
        #expect(rows.map(\.kind) == [.commit, .stash, .commit, .commit])
        #expect(rows.map(\.lane) == [0, 1, 0, 0])
        #expect(rows[1].edges == [F.pass(0), F.out(1, 1, color: 1, dashed: true)])
        // c2's first parent is c1 too; both lines run straight down and meet at c1.
        #expect(rows[2].edges == [F.into(0, 0), F.pass(1, dashed: true), F.out(0, 0, color: 0)])
        #expect(rows[3].edges == [F.into(0, 0), F.into(1, 0, dashed: true)])
    }

    @Test func aStashWhoseBaseIsAlreadyExpectedKeepsItsOwnDashedLine() {
        let nodes = F.nodes([("c2", ["c1"])])
            + [GraphNode.stash(F.stash(0, "s", base: "c1", date: 0))]
            + F.nodes([("c1", [])])
        let rows = F.layout(nodes)

        #expect(rows.map(\.lane) == [0, 1, 0])
        #expect(rows[1].edges == [F.pass(0), F.out(1, 1, color: 1, dashed: true)])
        #expect(rows[2].edges == [F.into(0, 0), F.into(1, 0, dashed: true)])
    }

    @Test func aStashWhoseBaseLoadsOnPageTwoKeepsItsDashedLaneOpen() {
        var sequence = GraphSequence(stashes: [F.stash(0, "s", base: "f1", date: 25)], workingCopyParent: nil)
        var layout = GraphLayout()

        let first = layout.append(sequence.append(
            [F.commit("c3", ["c2"], date: 30), F.commit("c2", ["c1"], date: 20)], isComplete: false
        ))
        let second = layout.append(sequence.append(
            [F.commit("f1", ["c1"], date: 15), F.commit("c1", [], date: 10)], isComplete: true
        ))

        #expect(first.map(\.id) == ["c3", "s", "c2"])
        #expect(first[2].edges == [F.into(0, 0), F.pass(1, dashed: true), F.out(0, 0, color: 0)])
        #expect(second.map(\.id) == ["f1", "c1"])
        #expect(second.map(\.lane) == [1, 0])
        // The stash's base takes the dashed lane and continues it solid down to c1.
        #expect(second[0].edges == [F.pass(0), F.into(1, 1, dashed: true), F.out(1, 1, color: 1)])
        #expect(second[1].edges == [F.into(0, 0), F.into(1, 0)])
    }
}

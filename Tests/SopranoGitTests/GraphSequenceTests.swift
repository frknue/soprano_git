import AppKit
import Testing
@testable import SopranoGitCore

struct GraphSequenceTests {
    typealias F = GraphFixture

    @Test func emptyHistoryWithoutStashesOrChangesHasNoNodes() {
        var sequence = GraphSequence(stashes: [], workingCopyParent: nil)

        #expect(sequence.append([], isComplete: true).isEmpty)
        #expect(sequence.isComplete)
    }

    @Test func theWorkingCopyComesFirstWithHeadAsItsOnlyParent() {
        var sequence = GraphSequence(stashes: [], workingCopyParent: "c1")

        let nodes = sequence.append([F.commit("c2", ["c1"], date: 20), F.commit("c1", [], date: 10)], isComplete: true)

        #expect(nodes.map(\.id) == [GraphNode.workingCopyID, "c2", "c1"])
        #expect(nodes.map(\.kind) == [.workingCopy, .commit, .commit])
        #expect(nodes[0].parents == ["c1"])
        #expect(nodes[0].content == .workingCopy(head: "c1"))
    }

    @Test func aMergeCommitBecomesAMergeNode() {
        var sequence = GraphSequence(stashes: [], workingCopyParent: nil)

        let nodes = sequence.append([F.commit("m", ["a", "b"])], isComplete: false)

        #expect(nodes.map(\.kind) == [.merge])
        #expect(nodes[0].parents == ["a", "b"])
    }

    @Test func stashesAreInsertedBeforeTheFirstOlderCommit() {
        let older = F.stash(1, "s-old", base: "c1", date: 15)
        let newer = F.stash(0, "s-new", base: "c1", date: 25)
        var sequence = GraphSequence(stashes: [older, newer], workingCopyParent: nil)

        let nodes = sequence.append(
            [F.commit("c3", ["c2"], date: 30), F.commit("c2", ["c1"], date: 20), F.commit("c1", [], date: 10)],
            isComplete: true
        )

        #expect(nodes.map(\.id) == ["c3", "s-new", "c2", "s-old", "c1"])
        #expect(nodes[1].kind == .stash)
        #expect(nodes[1].parents == ["c1"])
        #expect(nodes[1].content == .stash(newer))
    }

    @Test func aStashDatedBelowItsBaseStillComesBeforeTheBase() {
        // Clock skew: the stash claims to be older than the commit it was made on.
        let skewed = F.stash(0, "s", base: "c2", date: 5)
        var sequence = GraphSequence(stashes: [skewed], workingCopyParent: nil)

        let nodes = sequence.append(
            [F.commit("c3", ["c2"], date: 30), F.commit("c2", ["c1"], date: 20), F.commit("c1", [], date: 10)],
            isComplete: true
        )

        #expect(nodes.map(\.id) == ["c3", "s", "c2", "c1"])
    }

    @Test func stashesDueAtTheSameCommitComeNewestFirst() {
        let stashes = [
            F.stash(2, "s2", base: "c1", date: 12),
            F.stash(0, "s0", base: "c1", date: 18),
            F.stash(1, "s1", base: "c1", date: 18),
        ]
        var sequence = GraphSequence(stashes: stashes, workingCopyParent: nil)

        let nodes = sequence.append([F.commit("c2", ["c1"], date: 20), F.commit("c1", [], date: 10)], isComplete: true)

        #expect(nodes.map(\.id) == ["c2", "s0", "s1", "s2", "c1"])
    }

    @Test func aStashOlderThanTheFirstPageWaitsForTheNextPage() {
        let stash = F.stash(0, "s", base: "f1", date: 12)
        var sequence = GraphSequence(stashes: [stash], workingCopyParent: "c3")

        let first = sequence.append([F.commit("c3", ["c2"], date: 30), F.commit("c2", ["c1"], date: 20)], isComplete: false)
        let second = sequence.append([F.commit("f1", ["c1"], date: 15), F.commit("c1", [], date: 10)], isComplete: true)

        #expect(first.map(\.id) == [GraphNode.workingCopyID, "c3", "c2"])
        #expect(second.map(\.id) == ["s", "f1", "c1"])
    }

    @Test func stashesStillPendingAtTheEndOfHistoryComeLast() {
        let lost = F.stash(0, "s-lost", base: "unloaded", date: 5)
        var sequence = GraphSequence(stashes: [lost], workingCopyParent: nil)

        let first = sequence.append([F.commit("c2", ["c1"], date: 20)], isComplete: false)
        let second = sequence.append([F.commit("c1", [], date: 10)], isComplete: true)
        let afterwards = sequence.append([F.commit("late", [], date: 1)], isComplete: true)

        #expect(first.map(\.id) == ["c2"])
        #expect(second.map(\.id) == ["c1", "s-lost"])
        #expect(afterwards.isEmpty)
    }

    @Test func laterPagesNeverRepeatEarlierNodes() {
        var sequence = GraphSequence(stashes: [F.stash(0, "s", base: "c2", date: 25)], workingCopyParent: "c3")

        let first = sequence.append([F.commit("c3", ["c2"], date: 30), F.commit("c2", ["c1"], date: 20)], isComplete: false)
        let second = sequence.append([F.commit("c2", ["c1"], date: 20), F.commit("c1", [], date: 10)], isComplete: false)
        let third = sequence.append([], isComplete: true)

        #expect(first.map(\.id) == [GraphNode.workingCopyID, "c3", "s", "c2"])
        #expect(second.map(\.id) == ["c1"])
        #expect(third.isEmpty)
    }
}

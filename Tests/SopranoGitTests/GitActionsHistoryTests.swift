import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct GitActionsHistoryTests {
    /// main: Base → Main work; topic: Base → Topic work (no overlap unless `conflicting`).
    private func diverged(conflicting: Bool = false) async throws -> ActionFixture {
        let fixture = try await ActionFixture.make()
        try await fixture.script.git("switch", "-q", "-c", "topic")
        try await fixture.script.commit("Topic work", conflicting ? ["a.txt": "topic\n"] : ["t.txt": "t\n"])
        try await fixture.script.git("switch", "-q", "main")
        try await fixture.script.commit("Main work", conflicting ? ["a.txt": "main\n"] : ["m.txt": "m\n"])
        await fixture.reload()
        return fixture
    }

    @Test func mergeOffersTheThreeModesWithFastForwardFirst() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await diverged()
            defer { fixture.remove() }
            let topic = try fixture.branch("topic")

            let run = FlowRun { await GitActions.merge(.branch(topic), in: fixture.workspace) }
            let dialog = try await run.dialog()
            #expect(dialog.spec.title == "Merge topic into main")
            #expect(dialog.optionTitles == ["Fast-forward if possible", "Always create a merge commit", "Fast-forward only"])
            dialog.confirm()
            try await run.finish()

            let parents = try await fixture.output("rev-list", "--parents", "-n", "1", "HEAD").split(separator: " ")
            #expect(parents.count == 3)
            #expect(try await fixture.output("log", "-1", "--format=%s") == "Merge branch 'topic'")
            #expect(fixture.controller.selection == .commit(try #require(fixture.controller.refs.headCommit)))
        }
    }

    @Test func mergeCommitModeRecordsAMergeEvenWhenFastForwardIsPossible() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            try await fixture.script.git("switch", "-q", "-c", "ahead")
            let tip = try await fixture.script.commit("Ahead", ["b.txt": "b\n"])
            try await fixture.script.git("switch", "-q", "main")
            await fixture.reload()

            let run = FlowRun { await GitActions.merge(.commit(tip), in: fixture.workspace) }
            let dialog = try await run.dialog()
            #expect(dialog.spec.title == "Merge ahead into main")
            dialog.choose(1)
            try await run.finish()

            let parents = try await fixture.output("rev-list", "--parents", "-n", "1", "HEAD").split(separator: " ")
            #expect(parents.count == 3)
        }
    }

    @Test func fastForwardOnlyFailsLoudlyWhenTheBranchesDiverged() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await diverged()
            defer { fixture.remove() }
            let head = fixture.controller.refs.headCommit
            let topic = try fixture.branch("topic")

            let run = FlowRun { await GitActions.merge(.branch(topic), in: fixture.workspace) }
            try await run.dialog().choose(2)
            try await run.finish()

            #expect(fixture.controller.refs.headCommit == head)
            #expect(fixture.activity("Merge topic into main")?.outcome != .succeeded)
            #expect(fixture.controller.status.operation == nil)
        }
    }

    @Test func aConflictingMergePausesWithoutReportingAFailure() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await diverged(conflicting: true)
            defer { fixture.remove() }
            var failures: [String] = []
            let observer = NSObject()
            fixture.controller.addObserver(observer) { event in
                if case let .failed(title, _) = event { failures.append(title) }
            }
            let topic = try fixture.branch("topic")

            let run = FlowRun { await GitActions.merge(.branch(topic), in: fixture.workspace) }
            try await run.dialog().confirm()
            try await run.finish()

            #expect(failures.isEmpty)
            #expect(fixture.controller.status.operation != nil)
            #expect(fixture.controller.status.conflicted.map(\.path) == ["a.txt"])
            let entry = try #require(fixture.activity("Merge topic into main"))
            #expect(entry.outcome == .succeeded)
            #expect(entry.note == "paused on 1 conflict")
            #expect(fixture.controller.selection == .workingCopy)
            #expect(fixture.workspace.focusedRegion == .detail)
        }
    }

    @Test func continuingAfterResolvingFinishesTheMerge() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await diverged(conflicting: true)
            defer { fixture.remove() }
            try await fixture.script.git("merge", "topic", accepting: [1])
            await fixture.reload()

            let early = FlowRun { await GitActions.continueOperation(in: fixture.workspace) }
            try await early.finish()
            #expect(fixture.controller.status.operation != nil)
            #expect(fixture.activity("Continue Merge")?.outcome == .failed("Resolve the 1 conflicted file first: take ours or theirs in the commit panel, or stage your fix."))

            try fixture.script.write("a.txt", "resolved\n")
            try await fixture.script.git("add", "a.txt")
            await fixture.reload()
            let run = FlowRun { await GitActions.continueOperation(in: fixture.workspace) }
            try await run.finish()

            #expect(fixture.controller.status.operation == nil)
            #expect(try await fixture.output("show", "HEAD:a.txt") == "resolved")
            #expect(fixture.controller.selection == .commit(try #require(fixture.controller.refs.headCommit)))
        }
    }

    @Test func abortingAsksFirstAndRestoresTheBranch() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await diverged(conflicting: true)
            defer { fixture.remove() }
            let head = fixture.controller.refs.headCommit
            try await fixture.script.git("merge", "topic", accepting: [1])
            await fixture.reload()

            let cancelled = FlowRun { await GitActions.abortOperation(in: fixture.workspace) }
            let dialog = try await cancelled.dialog()
            #expect(dialog.spec.title == "Abort Merge")
            #expect(dialog.spec.isDestructive)
            dialog.finish(.cancelled)
            try await cancelled.finish()
            #expect(fixture.controller.status.operation != nil)

            let run = FlowRun { await GitActions.abortOperation(in: fixture.workspace) }
            try await run.dialog().confirm()
            try await run.finish()
            #expect(fixture.controller.status.operation == nil)
            #expect(fixture.controller.refs.headCommit == head)
            #expect(try fixture.script.read("a.txt") == "main\n")
        }
    }

    @Test func rebaseReplaysTheCurrentBranchAfterConfirming() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await diverged()
            defer { fixture.remove() }
            let topic = try fixture.branch("topic")

            let run = FlowRun { await GitActions.rebaseCurrent(onto: .branch(topic), in: fixture.workspace) }
            let dialog = try await run.dialog()
            #expect(dialog.spec.title == "Rebase main onto topic")
            dialog.confirm()
            try await run.finish()

            #expect(try await fixture.output("log", "--format=%s", "-3") == "Main work\nTopic work\nBase")
            #expect(fixture.controller.refs.head == .branch("main"))
        }
    }

    @Test func aConflictingRebasePausesAndSkipMovesOn() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await diverged(conflicting: true)
            defer { fixture.remove() }
            let topic = try fixture.branch("topic")

            let run = FlowRun { await GitActions.rebaseCurrent(onto: .branch(topic), in: fixture.workspace) }
            try await run.dialog().confirm()
            try await run.finish()
            guard case .rebase? = fixture.controller.status.operation else {
                Issue.record("expected a paused rebase")
                return
            }
            #expect(fixture.activity("Rebase main onto topic")?.note == "paused on 1 conflict")

            try await FlowRun { await GitActions.skipOperation(in: fixture.workspace) }.finish()
            #expect(fixture.controller.status.operation == nil)
            #expect(try await fixture.output("log", "--format=%s", "-1") == "Topic work")
        }
    }

    @Test func cherryPickAppliesTheCommitImmediately() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await diverged()
            defer { fixture.remove() }
            let topicTip = try fixture.branch("topic").target

            try await FlowRun { await GitActions.cherryPick(topicTip, in: fixture.workspace) }.finish()

            #expect(try await fixture.output("log", "--format=%s", "-1") == "Topic work")
            #expect(try fixture.script.read("t.txt") == "t\n")
        }
    }

    @Test func aConflictingCherryPickPausesOnTheCommitPanel() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await diverged(conflicting: true)
            defer { fixture.remove() }
            let topicTip = try fixture.branch("topic").target

            try await FlowRun { await GitActions.cherryPick(topicTip, in: fixture.workspace) }.finish()

            guard case .cherryPick? = fixture.controller.status.operation else {
                Issue.record("expected a paused cherry-pick")
                return
            }
            #expect(fixture.workspace.focusedRegion == .detail)
        }
    }

    @Test func revertConfirmsThenAddsAnUndoCommit() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            let change = try await fixture.script.commit("Change", ["a.txt": "changed\n"])
            await fixture.reload()

            let cancelled = FlowRun { await GitActions.revert(change, in: fixture.workspace) }
            let dialog = try await cancelled.dialog()
            #expect(dialog.spec.message?.contains("“Change”") == true)
            dialog.finish(.cancelled)
            try await cancelled.finish()
            #expect(fixture.controller.refs.headCommit == change)

            let run = FlowRun { await GitActions.revert(change, in: fixture.workspace) }
            try await run.dialog().confirm()
            try await run.finish()
            #expect(try await fixture.output("log", "--format=%s", "-1") == "Revert \"Change\"")
            #expect(try fixture.script.read("a.txt") == "a\n")
        }
    }

    @Test func resetModesKeepStageOrDiscardChanges() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            let base = try #require(fixture.controller.refs.headCommit)

            @MainActor func resetChoosing(_ index: Int) async throws {
                let run = FlowRun { await GitActions.reset(to: base, in: fixture.workspace) }
                let dialog = try await run.dialog()
                #expect(dialog.optionTitles == ["Soft", "Mixed", "Hard"])
                dialog.choose(index)
                if index == 2 {
                    let confirm = try await run.dialog()
                    #expect(confirm.spec.isDestructive)
                    confirm.confirm()
                }
                try await run.finish()
            }

            try await fixture.script.commit("Soft", ["a.txt": "soft\n"])
            await fixture.reload()
            try await resetChoosing(0)
            #expect(fixture.controller.refs.headCommit == base)
            #expect(fixture.controller.status.staged.map(\.path) == ["a.txt"])
            #expect(fixture.controller.selection == .workingCopy)

            try await fixture.script.commit("Mixed", ["a.txt": "mixed\n"])
            await fixture.reload()
            try await resetChoosing(1)
            #expect(fixture.controller.status.staged.isEmpty)
            #expect(fixture.controller.status.unstaged.map(\.path) == ["a.txt"])

            try await fixture.script.commit("Hard", ["a.txt": "hard\n"])
            await fixture.reload()
            try await resetChoosing(2)
            #expect(fixture.controller.refs.headCommit == base)
            #expect(fixture.controller.status.isClean)
            #expect(fixture.controller.selection == .commit(base))
        }
    }

    @Test func cancellingTheHardResetConfirmationKeepsEverything() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            let base = try #require(fixture.controller.refs.headCommit)
            let head = try await fixture.script.commit("Keep", ["a.txt": "keep\n"])
            await fixture.reload()

            let run = FlowRun { await GitActions.reset(to: base, in: fixture.workspace) }
            try await run.dialog().choose(2)
            try await run.dialog().finish(.cancelled)
            try await run.finish()

            #expect(fixture.controller.refs.headCommit == head)
            #expect(fixture.controller.activity.entries.isEmpty)
        }
    }
}

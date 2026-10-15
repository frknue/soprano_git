import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct GitActionsBranchTests {
    @Test func checkingOutALocalBranchSwitchesWithoutAsking() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            try await fixture.script.git("branch", "topic")
            await fixture.reload()

            let topic = try fixture.branch("topic")
            let run = FlowRun { await GitActions.checkout(.branch(topic), in: fixture.workspace) }
            try await run.finish()

            #expect(fixture.controller.refs.currentBranch?.name == "topic")
            #expect(fixture.controller.selection == .commit(try #require(fixture.controller.refs.headCommit)))
        }
    }

    @Test func checkingOutARemoteBranchCreatesATrackingBranchOrReusesTheLocalOne() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            try await fixture.script.git("switch", "-q", "-c", "feature")
            try await fixture.script.commit("Feature", ["f.txt": "f\n"])
            try await fixture.script.git("push", "-q", "origin", "feature")
            try await fixture.script.git("switch", "-q", "main")
            try await fixture.script.git("branch", "-q", "-D", "feature")
            await fixture.reload()

            let originFeature = try fixture.branch("origin/feature")
            try await FlowRun { await GitActions.checkout(.branch(originFeature), in: fixture.workspace) }.finish()
            let feature = try fixture.branch("feature")
            #expect(feature.isHead)
            #expect(feature.upstream == "origin/feature")

            try await fixture.script.git("switch", "-q", "main")
            await fixture.reload()
            try await FlowRun { await GitActions.checkout(.branch(originFeature), in: fixture.workspace) }.finish()
            #expect(fixture.controller.refs.currentBranch?.name == "feature")
            #expect(fixture.localBranchNames == ["feature", "main"])
        }
    }

    @Test func checkingOutACommitWithOneBranchSwitchesToThatBranch() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            try await fixture.script.git("switch", "-q", "-c", "topic")
            let tip = try await fixture.script.commit("Topic", ["t.txt": "t\n"])
            try await fixture.script.git("switch", "-q", "main")
            await fixture.reload()

            try await FlowRun { await GitActions.checkout(.commit(tip), in: fixture.workspace) }.finish()

            #expect(fixture.controller.refs.head == .branch("topic"))
        }
    }

    @Test func checkingOutABareCommitConfirmsADetachedHead() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            let base = try #require(fixture.controller.refs.headCommit)
            try await fixture.script.commit("Second", ["a.txt": "b\n"])
            await fixture.reload()

            let cancelled = FlowRun { await GitActions.checkout(.commit(base), in: fixture.workspace) }
            let cancelDialog = try await cancelled.dialog()
            #expect(cancelDialog.spec.title == "Checkout \(base.prefix(7))")
            cancelDialog.finish(.cancelled)
            try await cancelled.finish()
            #expect(fixture.controller.refs.head == .branch("main"))

            let run = FlowRun { await GitActions.checkout(.commit(base), in: fixture.workspace) }
            let dialog = try await run.dialog()
            #expect(dialog.spec.confirmTitle == "Checkout Detached")
            dialog.confirm()
            try await run.finish()
            #expect(fixture.controller.refs.head == .detached(base))
            #expect(fixture.controller.selection == .commit(base))
        }
    }

    @Test func creatingABranchAtACommitChecksItOutAndSelectsIt() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            let base = try #require(fixture.controller.refs.headCommit)
            try await fixture.script.commit("Second", ["a.txt": "b\n"])
            await fixture.reload()

            let run = FlowRun { await GitActions.createBranch(at: .commit(base), in: fixture.workspace) }
            let dialog = try await run.dialog()
            #expect(dialog.spec.title == "Create Branch")
            #expect(dialog.spec.message?.contains(String(base.prefix(7))) == true)
            #expect(dialog.validation(of: "main") == "A branch named “main” already exists.")
            #expect(dialog.validation(of: "my branch") == "Branch names can't contain spaces.")
            dialog.enter("fix/thing")
            try await run.finish()

            #expect(fixture.controller.refs.head == .branch("fix/thing"))
            #expect(fixture.controller.refs.headCommit == base)
            #expect(fixture.controller.selection == .commit(base))
        }
    }

    @Test func creatingABranchFromARemoteBranchPrefillsItsName() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            try await fixture.script.git("push", "-q", "origin", "main:feature/remote")
            await fixture.reload()

            let originFeatureRemote = try fixture.branch("origin/feature/remote")
            let run = FlowRun { await GitActions.createBranch(at: .branch(originFeatureRemote), in: fixture.workspace) }
            let dialog = try await run.dialog()
            #expect(dialog.inputField?.stringValue == "feature/remote")
            dialog.confirm()
            try await run.finish()

            let branch = try fixture.branch("feature/remote")
            #expect(branch.isHead)
            #expect(branch.upstream == "origin/feature/remote")
        }
    }

    @Test func cancellingTheBranchPromptCreatesNothing() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }

            let run = FlowRun { await GitActions.createBranch(at: nil, in: fixture.workspace) }
            let dialog = try await run.dialog()
            dialog.setValue("unused")
            dialog.finish(.cancelled)
            try await run.finish()

            #expect(fixture.localBranchNames == ["main"])
            #expect(fixture.controller.activity.entries.isEmpty)
        }
    }

    @Test func renamingABranchRejectsTheOldAndTakenNames() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            try await fixture.script.git("branch", "old")
            try await fixture.script.git("branch", "taken")
            await fixture.reload()

            let old = try fixture.branch("old")
            let run = FlowRun { await GitActions.renameBranch(old, in: fixture.workspace) }
            let dialog = try await run.dialog()
            #expect(dialog.inputField?.stringValue == "old")
            #expect(dialog.validation(of: "old") == "Enter a new name.")
            #expect(dialog.validation(of: "taken") == "A branch named “taken” already exists.")
            dialog.enter("new")
            try await run.finish()

            #expect(fixture.localBranchNames == ["main", "new", "taken"])
        }
    }

    @Test func deletingAnUnmergedBranchOffersForceDelete() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            try await fixture.script.git("branch", "merged")
            try await fixture.script.git("switch", "-q", "-c", "unmerged")
            try await fixture.script.commit("Unmerged", ["u.txt": "u\n"])
            try await fixture.script.git("switch", "-q", "main")
            await fixture.reload()

            let mergedBranch = try fixture.branch("merged")
            let merged = FlowRun { await GitActions.delete(.branch(mergedBranch), in: fixture.workspace) }
            let confirm = try await merged.dialog()
            #expect(confirm.spec.isDestructive)
            confirm.confirm()
            try await merged.finish()
            #expect(fixture.localBranchNames == ["main", "unmerged"])

            let unmerged = try fixture.branch("unmerged")
            let kept = FlowRun { await GitActions.delete(.branch(unmerged), in: fixture.workspace) }
            try await kept.dialog().confirm()
            let keepChoice = try await kept.dialog()
            #expect(keepChoice.optionTitles == ["Keep Branch", "Force Delete"])
            keepChoice.confirm()
            try await kept.finish()
            #expect(fixture.localBranchNames == ["main", "unmerged"])
            #expect(fixture.activity("Delete Branch unmerged")?.note == "not fully merged")

            let forced = FlowRun { await GitActions.delete(.branch(unmerged), in: fixture.workspace) }
            try await forced.dialog().confirm()
            let choice = try await forced.dialog()
            #expect(choice.options[1].isDestructive)
            choice.choose(1)
            try await forced.finish()
            #expect(fixture.localBranchNames == ["main"])
        }
    }

    @Test func deletingARemoteBranchRemovesItOnTheRemoteOnly() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            try await fixture.script.git("push", "-q", "origin", "main:gone")
            try await fixture.script.git("branch", "gone")
            await fixture.reload()

            let originGone = try fixture.branch("origin/gone")
            let run = FlowRun { await GitActions.delete(.branch(originGone), in: fixture.workspace) }
            let dialog = try await run.dialog()
            #expect(dialog.spec.confirmTitle == "Delete on origin")
            dialog.confirm()
            try await run.finish()

            #expect(fixture.controller.refs.remoteBranches.map(\.name) == ["origin/main"])
            #expect(fixture.localBranchNames == ["gone", "main"])
            #expect(try await fixture.output("ls-remote", "--heads", "origin").contains("refs/heads/gone") == false)
        }
    }

    @Test func settingTheUpstreamOffersTheSameNamedRemoteBranchFirst() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            try await fixture.script.git("push", "-q", "origin", "main:aaa")
            try await fixture.script.git("push", "-q", "origin", "main:topic")
            try await fixture.script.git("branch", "topic")
            await fixture.reload()

            let topic = try fixture.branch("topic")
            let run = FlowRun { await GitActions.setUpstream(of: topic, in: fixture.workspace) }
            let dialog = try await run.dialog()
            #expect(dialog.optionTitles == ["origin/topic", "origin/aaa", "origin/main"])
            dialog.confirm()
            try await run.finish()

            #expect(try fixture.branch("topic").upstream == "origin/topic")
        }
    }
}

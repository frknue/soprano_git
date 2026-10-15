import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct GitActionsRemoteTests {
    /// A second clone of the fixture's origin, for commits made "elsewhere".
    private func otherClone(of fixture: ActionFixture) async throws -> GitScript {
        let url = fixture.sandbox.url("other")
        try await fixture.sandbox.runner.run(["clone", "-q", fixture.sandbox.url("origin.git").path, url.path], in: fixture.sandbox.directory)
        return GitScript(try await Repository.open(at: url, runner: fixture.sandbox.runner), sandbox: fixture.sandbox)
    }

    @Test func fetchAndPullBringInRemoteCommits() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            let other = try await otherClone(of: fixture)
            let remoteTip = try await other.commit("Elsewhere", ["e.txt": "e\n"])
            try await other.git("push", "-q", "origin", "main")

            try await FlowRun { await GitActions.fetch(in: fixture.workspace) }.finish()
            #expect(try fixture.branch("origin/main").target == remoteTip)
            #expect(try fixture.branch("main").behind == 1)

            try await FlowRun { await GitActions.pull(in: fixture.workspace) }.finish()
            #expect(fixture.controller.refs.headCommit == remoteTip)
            #expect(fixture.controller.selection == .commit(remoteTip))
        }
    }

    @Test func pullingABranchWithoutUpstreamSuggestsPushing() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            try await fixture.script.git("switch", "-q", "-c", "local-only")
            await fixture.reload()
            var failures: [String] = []
            let observer = NSObject()
            fixture.controller.addObserver(observer) { event in
                if case let .failed(_, message) = event { failures.append(message) }
            }

            try await FlowRun { await GitActions.pull(in: fixture.workspace) }.finish()

            #expect(failures.count == 1)
            #expect(failures.first?.contains("has no upstream branch to pull from. Push it first") == true)
        }
    }

    @Test func theFirstPushConfirmsAndSetsTheUpstream() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            try await fixture.script.git("switch", "-q", "-c", "fresh")
            try await fixture.script.commit("Fresh", ["f.txt": "f\n"])
            await fixture.reload()

            let cancelled = FlowRun { await GitActions.push(in: fixture.workspace) }
            let cancelDialog = try await cancelled.dialog()
            #expect(cancelDialog.spec.message == "“fresh” has no upstream yet. Push it to origin/fresh and track it?")
            cancelDialog.finish(.cancelled)
            try await cancelled.finish()
            #expect(try fixture.branch("fresh").upstream == nil)

            let run = FlowRun { await GitActions.push(in: fixture.workspace) }
            try await run.dialog().confirm()
            try await run.finish()
            #expect(try fixture.branch("fresh").upstream == "origin/fresh")
            #expect(try fixture.branch("origin/fresh").target == fixture.controller.refs.headCommit)
        }
    }

    @Test func theFirstPushAsksWhichRemoteWhenThereAreSeveral() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            let backup = fixture.sandbox.url("backup.git")
            try await fixture.sandbox.runner.run(["init", "-q", "--bare", backup.path], in: fixture.sandbox.directory)
            try await fixture.script.git("remote", "add", "backup", backup.path)
            try await fixture.script.git("switch", "-q", "-c", "fresh")
            await fixture.reload()

            let run = FlowRun { await GitActions.push(in: fixture.workspace) }
            let dialog = try await run.dialog()
            #expect(dialog.optionTitles == ["origin", "backup"])
            dialog.choose(1)
            try await run.finish()

            #expect(try fixture.branch("fresh").upstream == "backup/fresh")
        }
    }

    @Test func aRejectedPushOffersForcePushWithLease() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            let other = try await otherClone(of: fixture)
            try await other.commit("Elsewhere", ["e.txt": "e\n"])
            try await other.git("push", "-q", "origin", "main")
            let local = try await fixture.script.commit("Local", ["l.txt": "l\n"])
            try await fixture.script.git("fetch", "-q", "origin")
            await fixture.reload()
            var failures: [String] = []
            let observer = NSObject()
            fixture.controller.addObserver(observer) { event in
                if case let .failed(title, _) = event { failures.append(title) }
            }

            let kept = FlowRun { await GitActions.push(in: fixture.workspace) }
            let keptChoice = try await kept.dialog()
            #expect(keptChoice.spec.title == "Push Rejected")
            #expect(keptChoice.optionTitles == ["Pull First", "Force Push with Lease"])
            keptChoice.finish(.cancelled)
            try await kept.finish()
            #expect(fixture.activity("Push main")?.note == "rejected, the remote has new commits")
            #expect(failures.isEmpty)

            let run = FlowRun { await GitActions.push(in: fixture.workspace) }
            let choice = try await run.dialog()
            #expect(choice.options[1].isDestructive)
            choice.choose(1)
            try await run.finish()

            #expect(try await fixture.output("ls-remote", "origin", "refs/heads/main").hasPrefix(local))
            #expect(failures.isEmpty)
        }
    }

    @Test func pushingANonCurrentBranchUsesItsUpstream() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            try await fixture.script.git("switch", "-q", "-c", "side")
            try await fixture.script.git("push", "-q", "-u", "origin", "side")
            let tip = try await fixture.script.commit("Side", ["s.txt": "s\n"])
            try await fixture.script.git("switch", "-q", "main")
            await fixture.reload()

            let side = try fixture.branch("side")
            try await FlowRun { await GitActions.pushBranch(side, in: fixture.workspace) }.finish()

            #expect(try fixture.branch("origin/side").target == tip)
        }
    }

    @Test func tagsAreCreatedAnnotatedPushedAndDeletedEverywhere() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make(remote: true)
            defer { fixture.remove() }
            let head = try #require(fixture.controller.refs.headCommit)

            let create = FlowRun { await GitActions.createTag(at: head, in: fixture.workspace) }
            let name = try await create.dialog()
            #expect(name.validation(of: "v 1") == "Tag names can't contain spaces.")
            name.enter("v1.0")
            let message = try await create.dialog()
            #expect(message.spec.title == "Tag v1.0")
            message.enter("First release")
            try await create.finish()
            let tag = try fixture.tag("v1.0")
            #expect(tag.isAnnotated)
            #expect(tag.target == head)
            #expect(try await fixture.output("tag", "-l", "--format=%(contents:subject)", "v1.0") == "First release")

            let light = FlowRun { await GitActions.createTag(at: head, in: fixture.workspace) }
            try await light.dialog().enter("light")
            try await light.dialog().enter("")
            try await light.finish()
            #expect(try fixture.tag("light").isAnnotated == false)

            try await FlowRun { await GitActions.pushTag(tag, in: fixture.workspace) }.finish()
            #expect(try await fixture.output("ls-remote", "--tags", "origin").contains("refs/tags/v1.0"))

            let delete = FlowRun { await GitActions.delete(.tag(tag), in: fixture.workspace) }
            let choice = try await delete.dialog()
            #expect(choice.optionTitles == ["Delete Locally", "Delete Locally and on origin"])
            choice.choose(1)
            try await delete.finish()
            #expect(fixture.controller.refs.tags.map(\.name) == ["light"])
            #expect(try await fixture.output("ls-remote", "--tags", "origin").isEmpty)
        }
    }

    @Test func cancellingTheTagMessageCreatesNoTag() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            let head = try #require(fixture.controller.refs.headCommit)

            let run = FlowRun { await GitActions.createTag(at: head, in: fixture.workspace) }
            try await run.dialog().enter("v2")
            try await run.dialog().finish(.cancelled)
            try await run.finish()

            #expect(fixture.controller.refs.tags.isEmpty)
        }
    }

    @Test func stashingIncludesUntrackedFilesAndPopRestoresThem() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            try fixture.script.write("a.txt", "edited\n")
            try fixture.script.write("new.txt", "new\n")
            await fixture.reload()

            let stash = FlowRun { await GitActions.stash(in: fixture.workspace) }
            try await stash.dialog().enter("WIP thing")
            try await stash.finish()
            #expect(fixture.controller.status.isClean)
            #expect(fixture.controller.stashes.map(\.message).first?.hasSuffix("WIP thing") == true)
            #expect(fixture.controller.selection == .stash(0))

            try await FlowRun { await GitActions.popStash(nil, in: fixture.workspace) }.finish()
            #expect(fixture.controller.stashes.isEmpty)
            #expect(try fixture.script.read("new.txt") == "new\n")
            #expect(try fixture.script.read("a.txt") == "edited\n")
            #expect(fixture.controller.selection == .workingCopy)
        }
    }

    @Test func applyKeepsTheStashAndDropAsksFirst() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            try fixture.script.write("a.txt", "edited\n")
            try await fixture.script.git("stash", "push", "-q", "-m", "keep me")
            await fixture.reload()
            let stash = try #require(fixture.controller.stashes.first)

            try await FlowRun { await GitActions.applyStash(stash, in: fixture.workspace) }.finish()
            #expect(fixture.controller.stashes.count == 1)
            #expect(try fixture.script.read("a.txt") == "edited\n")

            let cancelled = FlowRun { await GitActions.delete(.stash(stash), in: fixture.workspace) }
            let dialog = try await cancelled.dialog()
            #expect(dialog.spec.title == "Drop stash@{0}")
            #expect(dialog.spec.isDestructive)
            dialog.finish(.cancelled)
            try await cancelled.finish()
            #expect(fixture.controller.stashes.count == 1)

            let run = FlowRun { await GitActions.delete(.stash(stash), in: fixture.workspace) }
            try await run.dialog().confirm()
            try await run.finish()
            #expect(fixture.controller.stashes.isEmpty)
        }
    }

    @Test func aConflictingPopKeepsTheStashAndShowsTheConflicts() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            try fixture.script.write("a.txt", "stashed\n")
            try await fixture.script.git("stash", "push", "-q")
            try await fixture.script.commit("Clash", ["a.txt": "committed\n"])
            await fixture.reload()

            try await FlowRun { await GitActions.popStash(nil, in: fixture.workspace) }.finish()

            #expect(fixture.controller.stashes.count == 1)
            #expect(fixture.controller.status.conflicted.map(\.path) == ["a.txt"])
            #expect(fixture.activity("Pop stash@{0}")?.note == "1 conflict, stash kept")
            #expect(fixture.workspace.focusedRegion == .detail)
        }
    }
}

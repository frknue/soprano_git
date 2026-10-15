import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct RepositoryControllerTests {
    private final class Recorder {
        var events: [RepositoryController.Event] = []
    }

    private func waitUntil(_ timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeController(
        _ repository: Repository,
        pageSize: Int = 100
    ) async throws -> (RepositoryController, Recorder) {
        let controller = RepositoryController(repository: repository)
        controller.pageSize = { pageSize }
        let recorder = Recorder()
        controller.addObserver(recorder) { recorder.events.append($0) }
        controller.start(watching: false)
        try await waitUntil { controller.hasLoaded }
        return (controller, recorder)
    }

    @Test func theFirstLoadSelectsHeadsCommitOnACleanTree() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        let head = try await script.commit("second", ["a.txt": "b"])

        let (controller, recorder) = try await makeController(script.repository)

        #expect(controller.selection == .commit(head))
        #expect(controller.commits.map(\.summary) == ["second", "first"])
        #expect(controller.refs.currentBranch?.name == "main")
        #expect(recorder.events.contains(.commits(reset: true)))
        #expect(recorder.events.contains(.selection))
    }

    @Test func theFirstLoadSelectsTheWorkingCopyWhenTheTreeIsDirty() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        try script.write("a.txt", "changed")

        let (controller, _) = try await makeController(script.repository)

        #expect(controller.selection == .workingCopy)
        #expect(!controller.status.isClean)
    }

    @Test func commitsLoadInPagesAndLoadMoreAppends() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        for index in 1...5 {
            try await script.commit("c\(index)", ["f.txt": "\(index)"])
        }

        let (controller, recorder) = try await makeController(script.repository, pageSize: 2)
        #expect(controller.commits.map(\.summary) == ["c5", "c4"])
        #expect(controller.hasMoreCommits)

        controller.loadMoreCommits()
        try await waitUntil { controller.commits.count == 4 }
        controller.loadMoreCommits()
        try await waitUntil { controller.commits.count == 5 }

        #expect(controller.commits.map(\.summary) == ["c5", "c4", "c3", "c2", "c1"])
        #expect(!controller.hasMoreCommits)
        #expect(recorder.events.filter { $0 == .commits(reset: false) }.count == 2)
    }

    @Test func aMovedTipReloadsCommitsFromTheTop() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        let (controller, recorder) = try await makeController(script.repository)
        recorder.events.removeAll()

        try await script.commit("second", ["a.txt": "b"])
        await controller.refreshNow()

        #expect(controller.commits.map(\.summary) == ["second", "first"])
        #expect(recorder.events.contains(.refs))
        #expect(recorder.events.contains(.commits(reset: true)))
    }

    @Test func refreshesThatFindNothingNewEmitNoEvents() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        let (controller, recorder) = try await makeController(script.repository)
        recorder.events.removeAll()

        await controller.refreshNow()

        #expect(recorder.events.isEmpty)
    }

    @Test func burstsOfRefreshRequestsCoalesceIntoOneRead() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        let (controller, _) = try await makeController(script.repository)
        controller.minimumRefreshInterval = .milliseconds(300)
        let before = controller.refreshCycleCount

        for _ in 0..<10 {
            controller.refresh([.status])
        }
        controller.refresh(.all)
        try await Task.sleep(for: .milliseconds(900))

        #expect(controller.refreshCycleCount == before + 1)
    }

    @Test func aSelectedCommitThatDisappearsFallsBackToHead() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        let head = try await script.commit("first", ["a.txt": "a"])
        try await script.git("checkout", "-q", "-b", "topic")
        let topic = try await script.commit("topic work", ["b.txt": "b"])
        try await script.git("checkout", "-q", "main")
        let (controller, _) = try await makeController(script.repository)

        controller.select(.commit(topic))
        #expect(controller.selection == .commit(topic))
        try await script.git("branch", "-D", "topic")
        await controller.refreshNow()

        #expect(controller.selection == .commit(head))
    }

    @Test func aSelectedStashFollowsItsCommitWhenTheListShifts() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        try script.write("a.txt", "one")
        try await script.git("stash", "push", "-q", "-m", "one")
        let (controller, _) = try await makeController(script.repository)
        controller.select(.stash(0))

        try script.write("a.txt", "two")
        try await script.git("stash", "push", "-q", "-m", "two")
        await controller.refreshNow()

        #expect(controller.selection == .stash(1))
        try await script.git("stash", "drop", "-q", "stash@{1}")
        await controller.refreshNow()
        #expect(controller.selection != .stash(1))
        #expect(controller.selection != .stash(0))
    }

    @Test func runReportsSuccessLogsActivityAndRefreshes() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        let (controller, recorder) = try await makeController(script.repository)
        recorder.events.removeAll()

        let succeeded = await controller.run("Create Branch") { repository, progress in
            progress("creating")
            try await repository.createBranch("feature", at: nil, checkout: false)
        }

        #expect(succeeded)
        #expect(controller.activity.latest?.title == "Create Branch")
        #expect(controller.activity.latest?.outcome == .succeeded)
        #expect(controller.refs.localBranches.map(\.name).contains("feature"))
        #expect(recorder.events.contains(.activity))
        #expect(recorder.events.contains(.refs))
    }

    @Test func runReportsFailureWithGitsMessageAndStillRefreshes() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        let (controller, recorder) = try await makeController(script.repository)
        recorder.events.removeAll()
        let cycles = controller.refreshCycleCount

        let succeeded = await controller.run("Checkout") { repository, _ in
            try await repository.checkout(branch: "does-not-exist")
        }

        #expect(!succeeded)
        guard case let .failed(message)? = controller.activity.latest?.outcome else {
            Issue.record("expected a failed activity entry")
            return
        }
        #expect(!message.isEmpty)
        #expect(recorder.events.contains(.failed(title: "Checkout", message: message)))
        #expect(controller.refreshCycleCount == cycles + 1)
    }

    @Test func selectionAndOpenDiffEmitOnlyOnChange() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        let (controller, recorder) = try await makeController(script.repository)
        recorder.events.removeAll()

        controller.select(.workingCopy)
        controller.select(.workingCopy)
        let diff = OpenDiff(target: .unstaged(path: "a.txt"), title: "a.txt")
        controller.showDiff(diff)
        controller.showDiff(diff)
        controller.showDiff(nil)

        #expect(recorder.events == [.selection, .openDiff, .openDiff])
    }

    @Test func objectChurnLocksAndBuildOutputNeverTriggerRefreshes() {
        #expect(RepositoryController.isIgnoredChange("/r/.git/objects/ab/cdef"))
        #expect(RepositoryController.isIgnoredChange("/r/.git/index.lock"))
        #expect(RepositoryController.isIgnoredChange("/r/.build/debug/x.o"))
        #expect(RepositoryController.isIgnoredChange("/r/web/node_modules/a/b.js"))
        #expect(RepositoryController.isIgnoredChange("/common/objects/pack/p.idx", objectDirectories: ["/common/objects"]))
        #expect(!RepositoryController.isIgnoredChange("/r/.git/HEAD"))
        #expect(!RepositoryController.isIgnoredChange("/r/.git/refs/heads/main"))
        #expect(!RepositoryController.isIgnoredChange("/r/Sources/objects.swift"))
    }
}

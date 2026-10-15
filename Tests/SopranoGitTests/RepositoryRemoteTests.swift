import AppKit
import Testing
@testable import SopranoGitCore

/// Push, pull and fetch against a local bare repository.
struct RepositoryRemoteTests {
    private struct Setup {
        let sandbox: GitSandbox
        let origin: URL
        let repository: Repository
        let script: GitScript
        let other: Repository
        let otherScript: GitScript
    }

    /// `repo` and `other` are both clones of a bare `origin.git` holding one commit on main.
    private func makeSetup() async throws -> Setup {
        let sandbox = try GitSandbox()
        let origin = sandbox.url("origin.git")
        try await sandbox.runner.run(["init", "-q", "--bare", origin.path], in: sandbox.directory)
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.git("remote", "add", "origin", origin.path)
        try await script.commit("Base", ["a.txt": "a\n"])
        try await script.git("push", "-q", "-u", "origin", "main")
        try await sandbox.runner.run(["clone", "-q", origin.path, sandbox.url("other").path], in: sandbox.directory)
        let other = try await Repository.open(at: sandbox.url("other"), runner: sandbox.runner)
        return Setup(
            sandbox: sandbox, origin: origin, repository: repository, script: script,
            other: other, otherScript: GitScript(other, sandbox: sandbox)
        )
    }

    private func main(_ repository: Repository) async throws -> Branch {
        try #require(try await repository.refs().localBranches.first { $0.name == "main" })
    }

    @Test func pushFetchAndPullKeepAheadBehindInStep() async throws {
        let setup = try await makeSetup()
        defer { setup.sandbox.remove() }
        let repository = setup.repository

        try await setup.script.commit("Local one", ["b.txt": "b\n"])
        try await setup.script.commit("Local two", ["c.txt": "c\n"])
        var branch = try await main(repository)
        #expect(branch.ahead == 2 && branch.behind == 0)

        let progress = LineCollector()
        try await repository.push(branch: "main", remote: "origin", setUpstream: false, forceWithLease: false) { progress.append($0) }
        branch = try await main(repository)
        #expect(branch.ahead == 0 && branch.behind == 0)
        #expect(!progress.lines.isEmpty)

        try await setup.otherScript.git("pull", "-q")
        try await setup.otherScript.commit("Remote change", ["d.txt": "d\n"])
        try await setup.otherScript.git("push", "-q")

        try await repository.fetch(remote: "origin") { _ in }
        branch = try await main(repository)
        #expect(branch.ahead == 0 && branch.behind == 1)

        try await repository.pull(mode: .fastForwardOnly) { _ in }
        branch = try await main(repository)
        #expect(branch.ahead == 0 && branch.behind == 0)
        #expect(setup.script.exists("d.txt"))

        // Diverged: --ff merges, --rebase replays.
        try await setup.script.commit("Local three", ["e.txt": "e\n"])
        try await setup.otherScript.git("pull", "-q")
        try await setup.otherScript.commit("Remote two", ["f.txt": "f\n"])
        try await setup.otherScript.git("push", "-q")
        try await repository.fetch(remote: nil) { _ in }
        branch = try await main(repository)
        #expect(branch.ahead == 1 && branch.behind == 1)

        await #expect(throws: GitError.self) { try await repository.pull(mode: .fastForwardOnly) { _ in } }
        try await repository.pull(mode: .fastForwardIfPossible) { _ in }
        branch = try await main(repository)
        #expect(branch.ahead == 2 && branch.behind == 0)
        let head = try await repository.commitDetail(try #require(branch.target as String?))
        #expect(head.commit.isMerge)

        try await repository.reset(to: "HEAD~1", mode: .hard)
        branch = try await main(repository)
        #expect(branch.ahead == 1 && branch.behind == 1)
        try await repository.pull(mode: .rebase) { _ in }
        branch = try await main(repository)
        #expect(branch.ahead == 1 && branch.behind == 0)
        #expect(try await repository.log(limit: 1, skip: 0, extraTips: []).first?.parents.count == 1)
    }

    @Test func pushSetsUpstreamAndForcesWithLease() async throws {
        let setup = try await makeSetup()
        defer { setup.sandbox.remove() }
        let repository = setup.repository

        try await repository.createBranch("feature", at: nil, checkout: true)
        let first = try await setup.script.commit("Feature", ["f.txt": "1\n"])
        try await repository.push(branch: "feature", remote: "origin", setUpstream: true, forceWithLease: false) { _ in }
        var refs = try await repository.refs()
        #expect(refs.currentBranch?.upstream == "origin/feature")
        #expect(refs.remoteBranches.first { $0.name == "origin/feature" }?.target == first)

        try await setup.script.git("commit", "-q", "--amend", "-m", "Feature amended")
        await #expect(throws: GitError.self) {
            try await repository.push(branch: "feature", remote: "origin", setUpstream: false, forceWithLease: false) { _ in }
        }
        try await repository.push(branch: "feature", remote: "origin", setUpstream: false, forceWithLease: true) { _ in }
        refs = try await repository.refs()
        #expect(refs.currentBranch?.ahead == 0 && refs.currentBranch?.behind == 0)
        #expect(refs.remoteBranches.first { $0.name == "origin/feature" }?.target == refs.headCommit)

        try await repository.checkout(branch: "main")
        try await repository.deleteRemoteBranch(remote: "origin", branch: "feature")
        refs = try await repository.refs()
        #expect(!refs.remoteBranches.contains { $0.name == "origin/feature" })
        #expect(refs.localBranches.first { $0.name == "feature" }?.upstreamGone == true)

        try await repository.setUpstream(of: "feature", to: "origin/main")
        refs = try await repository.refs()
        let feature = try #require(refs.localBranches.first { $0.name == "feature" })
        #expect(feature.upstream == "origin/main" && feature.ahead == 1 && !feature.upstreamGone)
    }

    @Test func checkoutTrackingCreatesOrReusesTheLocalBranch() async throws {
        let setup = try await makeSetup()
        defer { setup.sandbox.remove() }
        let repository = setup.repository
        try await setup.otherScript.git("switch", "-q", "-c", "remote-only")
        let tip = try await setup.otherScript.commit("Remote only", ["r.txt": "r\n"])
        try await setup.otherScript.git("push", "-q", "origin", "remote-only")
        try await repository.fetch(remote: "origin") { _ in }

        try await repository.checkoutTracking(remoteBranch: "origin/remote-only", localName: "remote-only")
        var refs = try await repository.refs()
        #expect(refs.head == .branch("remote-only"))
        #expect(refs.currentBranch?.upstream == "origin/remote-only" && refs.headCommit == tip)

        try await repository.checkout(branch: "main")
        try await repository.checkoutTracking(remoteBranch: "origin/remote-only", localName: "remote-only")
        refs = try await repository.refs()
        #expect(refs.head == .branch("remote-only"))
        #expect(refs.localBranches.filter { $0.name == "remote-only" }.count == 1)
    }

    @Test func tagsArePushedAndDeletedOnTheRemote() async throws {
        let setup = try await makeSetup()
        defer { setup.sandbox.remove() }
        let repository = setup.repository
        let head = try #require(try await repository.refs().headCommit)
        try await repository.createTag("v1.0", at: head, message: "Release")
        try await repository.createTag("main", at: head, message: nil)

        try await repository.pushTag("v1.0", remote: "origin")
        try await repository.pushTag("main", remote: "origin")
        let remoteTags = try await setup.sandbox.runner.run(["ls-remote", "--tags", "origin"], in: repository.root).stdoutString
        #expect(remoteTags.contains("refs/tags/v1.0"))
        #expect(remoteTags.contains("refs/tags/main"))

        try await repository.deleteRemoteTag("v1.0", remote: "origin")
        let after = try await setup.sandbox.runner.run(["ls-remote", "--tags", "origin"], in: repository.root).stdoutString
        #expect(!after.contains("refs/tags/v1.0"))
        #expect(after.contains("refs/tags/main"))

        // A tag named like the branch must not make pushing the branch ambiguous.
        try await setup.script.commit("After tags", ["t.txt": "t\n"])
        try await repository.push(branch: "main", remote: "origin", setUpstream: false, forceWithLease: false) { _ in }
        let main = try #require(try await repository.refs().currentBranch)
        #expect(main.ahead == 0 && main.behind == 0)
    }
}

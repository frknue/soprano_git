import AppKit
import Testing
@testable import SopranoGitCore

struct RepositoryOperationTests {
    /// main and `topic` both change `shared.txt`; `topic` also deletes
    /// `doomed.txt`, which main modifies.
    private func makeConflict(_ script: GitScript) async throws -> (main: String, topic: String) {
        try await script.commit("Base", ["shared.txt": "base\n", "doomed.txt": "keep me\n", "other.txt": "o\n"])
        try await script.git("switch", "-q", "-c", "topic")
        try await script.git("rm", "-q", "doomed.txt")
        let topic = try await script.commit("Topic", ["shared.txt": "topic\n"])
        try await script.git("switch", "-q", "main")
        let main = try await script.commit("Main", ["shared.txt": "main\n", "doomed.txt": "changed on main\n"])
        return (main, topic)
    }

    @Test func aConflictedMergeIsResolvedBySideAndContinued() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let (main, topic) = try await makeConflict(script)

        await #expect(throws: GitError.self) {
            try await repository.merge("topic", mode: .fastForwardIfPossible)
        }
        var status = try await repository.status()
        #expect(status.operation == .merge(mergingHead: topic))
        #expect(status.conflicted == [
            StatusEntry(path: "doomed.txt", conflict: .deletedByThem),
            StatusEntry(path: "shared.txt", conflict: .bothModified),
        ])

        await #expect(throws: GitError.self) { try await repository.continueOperation() }
        await #expect(throws: GitError.self) { try await repository.skipOperation() }

        try await repository.resolveConflict(path: "shared.txt", side: .theirs)
        try await repository.resolveConflict(path: "doomed.txt", side: .theirs)
        status = try await repository.status()
        #expect(status.conflicted.isEmpty)
        #expect(try script.read("shared.txt") == "topic\n")
        #expect(!script.exists("doomed.txt"))

        try await repository.continueOperation()
        status = try await repository.status()
        #expect(status.operation == nil && status.isClean)
        let head = try await repository.commitDetail(try await script.output("rev-parse", "HEAD"))
        #expect(head.commit.parents == [main, topic])
        #expect(head.commit.summary == "Merge branch 'topic'")
    }

    @Test func resolvingWithOursKeepsOurVersionAndOurModifiedFile() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await makeConflict(script)
        await #expect(throws: GitError.self) { try await repository.merge("topic", mode: .noFastForward) }
        try await repository.resolveConflict(path: "shared.txt", side: .ours)
        try await repository.resolveConflict(path: "doomed.txt", side: .ours)
        #expect(try script.read("shared.txt") == "main\n")
        #expect(try script.read("doomed.txt") == "changed on main\n")
        #expect(try await repository.status().conflicted.isEmpty)
        try await repository.abortOperation()
        #expect(try await repository.status() == .clean)
    }

    @Test func mergeModesControlFastForwarding() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let base = try await script.commit("Base", ["a.txt": "a\n"])
        try await script.git("switch", "-q", "-c", "ahead")
        let ahead = try await script.commit("Ahead", ["b.txt": "b\n"])
        try await script.git("switch", "-q", "main")

        try await repository.merge("ahead", mode: .noFastForward)
        let mergeCommit = try await repository.refs().headCommit
        #expect(mergeCommit != ahead)
        #expect(try await repository.commitDetail(mergeCommit!).commit.parents == [base, ahead])

        try await repository.reset(to: base, mode: .hard)
        try await repository.merge("ahead", mode: .fastForwardOnly)
        #expect(try await repository.refs().headCommit == ahead)

        try await repository.reset(to: base, mode: .hard)
        try await repository.merge("ahead", mode: .fastForwardIfPossible)
        #expect(try await repository.refs().headCommit == ahead)

        try await repository.reset(to: base, mode: .hard)
        try await script.commit("Diverge", ["c.txt": "c\n"])
        await #expect(throws: GitError.self) { try await repository.merge("ahead", mode: .fastForwardOnly) }
    }

    @Test func aConflictedRebaseAbortRestoresTheBranch() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let (main, topic) = try await makeConflict(script)
        try await repository.checkout(branch: "topic")

        await #expect(throws: GitError.self) { try await repository.rebase(onto: "main") }
        let status = try await repository.status()
        guard case let .rebase(headName, onto, step, total)? = status.operation else {
            Issue.record("expected a paused rebase, got \(String(describing: status.operation))")
            return
        }
        #expect(headName == "topic" && onto == main && step == 1 && total == 1)
        #expect(!status.conflicted.isEmpty)

        try await repository.abortOperation()
        #expect(try await repository.status() == .clean)
        let refs = try await repository.refs()
        #expect(refs.head == .branch("topic") && refs.headCommit == topic)
    }

    @Test func aRebaseContinuesAfterResolvingAndSkipsADroppedCommit() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let (main, _) = try await makeConflict(script)
        try await repository.checkout(branch: "topic")
        try await script.commit("Topic two", ["extra.txt": "x\n"])

        await #expect(throws: GitError.self) { try await repository.rebase(onto: "main") }
        try await repository.resolveConflict(path: "shared.txt", side: .theirs)
        try await repository.resolveConflict(path: "doomed.txt", side: .theirs)
        try await repository.continueOperation()
        var status = try await repository.status()
        #expect(status.operation == nil)
        let log = try await repository.log(limit: 3, skip: 0, extraTips: [])
        #expect(log.map(\.summary) == ["Topic two", "Topic", "Main"])
        #expect(log[2].id == main)

        // Skip: replay a commit whose change conflicts, and drop it.
        try await repository.createBranch("again", at: "main", checkout: true)
        try await script.commit("Again", ["shared.txt": "again\n"])
        await #expect(throws: GitError.self) { try await repository.rebase(onto: "topic") }
        try await repository.skipOperation()
        status = try await repository.status()
        #expect(status.operation == nil)
        #expect(try await repository.refs().headCommit == log[0].id)
    }

    @Test func cherryPickingAMergeCommitUsesTheFirstParent() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let base = try await script.commit("Base", ["a.txt": "a\n"])
        try await script.git("switch", "-q", "-c", "side")
        try await script.commit("Side", ["side.txt": "s\n"])
        try await script.git("switch", "-q", "main")
        try await script.commit("Main", ["main.txt": "m\n"])
        try await script.git("merge", "-q", "--no-ff", "--no-edit", "side")
        let merge = try await script.output("rev-parse", "HEAD")
        let plain = try await script.commit("Plain", ["plain.txt": "p\n"])

        try await repository.createBranch("target", at: base, checkout: true)
        try await repository.cherryPick(merge)
        #expect(script.exists("side.txt") && !script.exists("main.txt"))
        try await repository.cherryPick(plain)
        #expect(script.exists("plain.txt"))
        let picked = try await repository.commitDetail(try await script.output("rev-parse", "HEAD~1"))
        #expect(picked.commit.summary == "Merge branch 'side'" && picked.commit.id != merge)
        #expect(picked.commit.parents == [base])
        #expect(picked.files.map(\.path) == ["side.txt"])

        try await repository.revert(plain)
        #expect(!script.exists("plain.txt"))
        try await repository.revert(merge)
        #expect(!script.exists("side.txt"))
        #expect(try await repository.status().isClean)
        #expect(try await repository.headMessage().hasPrefix("Revert \"Merge branch 'side'\""))
    }

    @Test func aConflictedCherryPickReportsAndSkips() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let (main, topic) = try await makeConflict(script)
        await #expect(throws: GitError.self) { try await repository.cherryPick(topic) }
        #expect(try await repository.status().operation == .cherryPick(commit: topic))
        try await repository.skipOperation()
        #expect(try await repository.status() == .clean)
        #expect(try await repository.refs().headCommit == main)

        await #expect(throws: GitError.self) { try await repository.cherryPick(topic) }
        try await repository.resolveConflict(path: "shared.txt", side: .theirs)
        try await repository.resolveConflict(path: "doomed.txt", side: .ours)
        try await repository.continueOperation()
        #expect(try await repository.status() == .clean)
        #expect(try await repository.headMessage() == "Topic")
    }

    @Test func aConflictedRevertReportsAndAborts() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("First", ["a.txt": "1\n"])
        let second = try await script.commit("Second", ["a.txt": "2\n"])
        let third = try await script.commit("Third", ["a.txt": "3\n"])
        await #expect(throws: GitError.self) { try await repository.revert(second) }
        #expect(try await repository.status().operation == .revert(commit: second))
        try await repository.abortOperation()
        #expect(try await repository.status() == .clean)
        #expect(try await repository.refs().headCommit == third)
        await #expect(throws: GitError.self) { try await repository.abortOperation() }

        await #expect(throws: GitError.self) { try await repository.revert(second) }
        try await repository.resolveConflict(path: "a.txt", side: .theirs)
        try await repository.continueOperation()
        #expect(try await repository.status() == .clean)
        #expect(try script.read("a.txt") == "1\n")
        #expect(try await repository.headMessage().hasPrefix("Revert \"Second\""))
    }

    @Test func resetModesMoveTheBranchIndexAndWorktree() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let base = try await script.commit("Base", ["a.txt": "1\n"])
        let tip = try await script.commit("Tip", ["a.txt": "2\n"])

        try await repository.reset(to: base, mode: .soft)
        #expect(try await repository.refs().headCommit == base)
        #expect(try await repository.status().entries == [StatusEntry(path: "a.txt", staged: .modified)])

        try await repository.reset(to: tip, mode: .hard)
        try await repository.reset(to: base, mode: .mixed)
        #expect(try await repository.status().entries == [StatusEntry(path: "a.txt", unstaged: .modified)])
        #expect(try script.read("a.txt") == "2\n")

        try await repository.reset(to: base, mode: .hard)
        #expect(try await repository.status() == .clean)
        #expect(try script.read("a.txt") == "1\n")
    }
}

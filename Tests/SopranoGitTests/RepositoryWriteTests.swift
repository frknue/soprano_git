import AppKit
import Testing
@testable import SopranoGitCore

struct RepositoryWriteTests {
    private let twenty = (1...20).map { "line \($0)" }

    private func text(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    @Test func stageUnstageAndDiscardPaths() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("Base", ["a.txt": "a\n", "b.txt": "b\n", "c.txt": "c\n", "weird [x]*.txt": "w\n"])
        try script.write("a.txt", "a2\n")
        try script.write("b.txt", "b2\n")
        try script.write("weird [x]*.txt", "w2\n")
        try FileManager.default.removeItem(at: repository.root.appendingPathComponent("c.txt"))
        try script.write("new dir/untracked.txt", "u\n")
        try script.write("keep.txt", "k\n")

        try await repository.stage(paths: ["a.txt", "c.txt", "weird [x]*.txt", "new dir/untracked.txt"])
        var status = try await repository.status()
        #expect(status.staged.map(\.path) == ["a.txt", "c.txt", "new dir/untracked.txt", "weird [x]*.txt"])
        #expect(status.entries.first { $0.path == "c.txt" }?.staged == .deleted)

        try await repository.unstage(paths: ["a.txt", "new dir/untracked.txt"])
        status = try await repository.status()
        #expect(status.staged.map(\.path) == ["c.txt", "weird [x]*.txt"])
        #expect(status.entries.first { $0.path == "a.txt" }?.unstaged == .modified)

        try await repository.discard(paths: ["a.txt", "b.txt", "new dir/untracked.txt"])
        #expect(try script.read("a.txt") == "a\n")
        #expect(try script.read("b.txt") == "b\n")
        #expect(!script.exists("new dir/untracked.txt"))
        #expect(!script.exists("new dir"))
        #expect(script.exists("keep.txt"))

        try await repository.stageAll()
        status = try await repository.status()
        #expect(status.unstaged.isEmpty)
        #expect(status.staged.map(\.path) == ["c.txt", "keep.txt", "weird [x]*.txt"])

        try await repository.unstageAll()
        status = try await repository.status()
        #expect(status.staged.isEmpty)
        #expect(status.unstaged.map(\.path) == ["c.txt", "weird [x]*.txt", "keep.txt"])
    }

    @Test func unstageWorksBeforeTheFirstCommit() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try script.write("one.txt", "1\n")
        try script.write("two.txt", "2\n")
        try await repository.stageAll()
        try await repository.unstage(paths: ["one.txt"])
        #expect(try await repository.status().entries == [
            StatusEntry(path: "two.txt", staged: .added),
            StatusEntry(path: "one.txt", unstaged: .untracked),
        ])
        try await repository.unstageAll()
        #expect(try await repository.status().staged.isEmpty)
        try await repository.unstageAll()

        try await repository.stage(paths: ["one.txt"])
        let id = try await repository.commit(message: "First commit\n\nWith a body.", amend: false)
        let refs = try await repository.refs()
        #expect(refs.head == .branch("main") && refs.headCommit == id)
        #expect(try await repository.headMessage() == "First commit\n\nWith a body.")
        #expect(try await repository.log(limit: 10, skip: 0, extraTips: []).map(\.id) == [id])
    }

    @Test func hunksStageUnstageAndDiscardIndependently() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("Base", ["file.txt": text(twenty)])
        var edited = twenty
        edited[1] = "top change"
        edited[18] = "bottom change"
        try script.write("file.txt", text(edited))
        var topOnly = twenty
        topOnly[1] = "top change"

        let unstaged = try await repository.diff(.unstaged(path: "file.txt"))
        #expect(unstaged[0].hunks.count == 2)
        try await repository.stageHunk(unstaged[0].hunks[0], of: unstaged[0])
        #expect(try await script.indexContents("file.txt") == text(topOnly))
        #expect(try script.read("file.txt") == text(edited))

        let staged = try await repository.diff(.staged(path: "file.txt"))
        #expect(staged[0].hunks.count == 1)
        try await repository.unstageHunk(staged[0].hunks[0], of: staged[0])
        #expect(try await script.indexContents("file.txt") == text(twenty))
        #expect(try script.read("file.txt") == text(edited))

        let again = try await repository.diff(.unstaged(path: "file.txt"))
        try await repository.discardHunk(again[0].hunks[1], of: again[0])
        #expect(try script.read("file.txt") == text(topOnly))
        #expect(try await script.indexContents("file.txt") == text(twenty))

        let last = try await repository.diff(.unstaged(path: "file.txt"))
        try await repository.discardHunk(last[0].hunks[0], of: last[0])
        #expect(try script.read("file.txt") == text(twenty))
        #expect(try await repository.status().isClean)
    }

    @Test func hunksRoundTripCRLFAndMissingNewlines() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("Base", ["crlf.txt": "a\r\nb\r\nc\r\n", "nonl.txt": "x\ny"])
        try script.write("crlf.txt", "a\r\nB\r\nc\r\n")
        try script.write("nonl.txt", "x\nz")

        for path in ["crlf.txt", "nonl.txt"] {
            let diff = try await repository.diff(.unstaged(path: path))
            try await repository.stageHunk(diff[0].hunks[0], of: diff[0])
        }
        #expect(try await script.indexContents("crlf.txt") == "a\r\nB\r\nc\r\n")
        #expect(try await script.indexContents("nonl.txt") == "x\nz")
        #expect(try await repository.status().unstaged.isEmpty)

        for path in ["crlf.txt", "nonl.txt"] {
            let diff = try await repository.diff(.staged(path: path))
            try await repository.unstageHunk(diff[0].hunks[0], of: diff[0])
        }
        #expect(try await script.indexContents("crlf.txt") == "a\r\nb\r\nc\r\n")
        #expect(try await script.indexContents("nonl.txt") == "x\ny")
    }

    @Test func aHunkOfAnUntrackedFileStagesTheNewFile() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("Base", ["a.txt": "a\n"])
        try script.write("dir/new file.txt", "n1\nn2\n")

        let diff = try await repository.diff(.unstaged(path: "dir/new file.txt"))
        try await repository.stageHunk(diff[0].hunks[0], of: diff[0])
        #expect(try await script.indexContents("dir/new file.txt") == "n1\nn2\n")
        #expect(try await repository.status().entries == [StatusEntry(path: "dir/new file.txt", staged: .added)])

        let staged = try await repository.diff(.staged(path: "dir/new file.txt"))
        try await repository.unstageHunk(staged[0].hunks[0], of: staged[0])
        #expect(try await repository.status().entries == [StatusEntry(path: "dir/new file.txt", unstaged: .untracked)])

        let untracked = try await repository.diff(.unstaged(path: "dir/new file.txt"))
        try await repository.discardHunk(untracked[0].hunks[0], of: untracked[0])
        #expect(!script.exists("dir/new file.txt"))
        #expect(try await repository.status().isClean)
    }

    @Test func commitAndAmendReturnTheNewHead() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let base = try await script.commit("Base", ["a.txt": "a\n"])
        try script.write("a.txt", "b\n")
        try await repository.stageAll()
        let message = "Subject: with \"quotes\" and # hash\n\n# not a comment, kept\nÜnïcödé body"
        let first = try await repository.commit(message: message, amend: false)
        #expect(try await script.output("rev-parse", "HEAD") == first)
        #expect(try await repository.headMessage() == message)
        #expect(try await repository.commitDetail(first).commit.parents == [base])

        let amended = try await repository.commit(message: "Amended", amend: true)
        #expect(amended != first)
        #expect(try await repository.commitDetail(amended).commit.parents == [base])
        #expect(try await repository.headMessage() == "Amended")

        await #expect(throws: GitError.self) {
            try await repository.commit(message: "Nothing staged", amend: false)
        }
    }

    @Test func branchesAreCreatedCheckedOutRenamedAndDeleted() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let base = try await script.commit("Base", ["a.txt": "a\n"])
        let second = try await script.commit("Second", ["a.txt": "b\n"])

        try await repository.createBranch("topic", at: base, checkout: false)
        var refs = try await repository.refs()
        #expect(refs.head == .branch("main"))
        #expect(refs.localBranches.first { $0.name == "topic" }?.target == base)

        try await repository.createBranch("work", at: nil, checkout: true)
        refs = try await repository.refs()
        #expect(refs.head == .branch("work") && refs.headCommit == second)

        try await repository.checkout(branch: "topic")
        #expect(try await repository.refs().head == .branch("topic"))
        #expect(try script.read("a.txt") == "a\n")

        try await repository.checkout(commit: second)
        #expect(try await repository.refs().head == .detached(second))

        try await repository.checkout(branch: "main")
        try await repository.renameBranch("topic", to: "renamed/topic")
        refs = try await repository.refs()
        #expect(refs.localBranches.map(\.name) == ["main", "renamed/topic", "work"])

        try await repository.deleteBranch("work", force: false)
        await #expect(throws: GitError.self) {
            try await repository.deleteBranch("main", force: true)
        }
        try await repository.createBranch("unmerged", at: nil, checkout: true)
        try await script.commit("Unmerged", ["u.txt": "u\n"])
        try await repository.checkout(branch: "main")
        await #expect(throws: GitError.self) {
            try await repository.deleteBranch("unmerged", force: false)
        }
        try await repository.deleteBranch("unmerged", force: true)
        #expect(try await repository.refs().localBranches.map(\.name) == ["main", "renamed/topic"])
    }

    @Test func tagsAreCreatedLightweightOrAnnotatedAndDeleted() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let base = try await script.commit("Base", ["a.txt": "a\n"])
        try await script.commit("Second", ["a.txt": "b\n"])

        try await repository.createTag("light", at: base, message: nil)
        try await repository.createTag("v1.0", at: base, message: "Release 1.0\n\nDetails here.")
        let tags = try await repository.refs().tags
        #expect(tags == [
            Tag(name: "light", fullName: "refs/tags/light", target: base, isAnnotated: false),
            Tag(name: "v1.0", fullName: "refs/tags/v1.0", target: base, isAnnotated: true, message: "Release 1.0"),
        ])
        #expect(try await script.output("tag", "-l", "--format=%(contents)", "v1.0") == "Release 1.0\n\nDetails here.")

        try await repository.deleteTag("light")
        #expect(try await repository.refs().tags.map(\.name) == ["v1.0"])
    }

    @Test func stashesArePushedAppliedPoppedAndDropped() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("Base", ["a.txt": "a\n"])

        try script.write("a.txt", "first\n")
        try await repository.stash(message: nil, includeUntracked: false)
        #expect(try script.read("a.txt") == "a\n")

        try script.write("a.txt", "second\n")
        try script.write("scratch/u.txt", "u\n")
        try await repository.stash(message: "With untracked", includeUntracked: true)
        #expect(!script.exists("scratch/u.txt"))
        #expect(try await repository.status().isClean)

        var stashes = try await repository.stashes()
        #expect(stashes.count == 2)
        #expect(stashes[0].message == "On main: With untracked")
        #expect(stashes[1].message.hasPrefix("WIP on main:"))
        #expect(try await repository.stashFiles(0).map(\.path) == ["a.txt", "scratch/u.txt"])
        #expect(try await repository.stashFiles(0).last?.kind == .untracked)

        try await repository.popStash(0)
        #expect(try script.read("a.txt") == "second\n")
        #expect(try script.read("scratch/u.txt") == "u\n")
        stashes = try await repository.stashes()
        #expect(stashes.count == 1)

        try await repository.discard(paths: ["a.txt", "scratch/u.txt"])
        try await repository.applyStash(0)
        #expect(try script.read("a.txt") == "first\n")
        #expect(try await repository.stashes().count == 1)

        try await repository.dropStash(0)
        #expect(try await repository.stashes().isEmpty)
    }
}

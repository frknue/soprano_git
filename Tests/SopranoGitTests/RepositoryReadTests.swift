import AppKit
import Testing
@testable import SopranoGitCore

struct RepositoryReadTests {
    @Test func openResolvesTheRootFromASubdirectory() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try script.write("src/deep/file.txt", "x\n")

        let opened = try await Repository.open(at: repository.root.appendingPathComponent("src/deep"), runner: sandbox.runner)
        #expect(opened.root.path == sandbox.url("repo").path)
        #expect(opened.gitDirectory.path == sandbox.url("repo/.git").path)
        #expect(opened.commonDirectory.path == sandbox.url("repo/.git").path)
        #expect(opened == repository)

        let fromFile = try await Repository.open(at: repository.root.appendingPathComponent("src/deep/file.txt"), runner: sandbox.runner)
        #expect(fromFile.root == opened.root)
    }

    @Test func openResolvesALinkedWorktree() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("Initial", ["a.txt": "a\n"])
        try await script.git("worktree", "add", "-q", "-b", "side", sandbox.url("linked").path)

        let linked = try await Repository.open(at: sandbox.url("linked"), runner: sandbox.runner)
        #expect(linked.root.path == sandbox.url("linked").path)
        #expect(linked.gitDirectory.path == sandbox.url("repo/.git/worktrees/linked").path)
        #expect(linked.commonDirectory.path == sandbox.url("repo/.git").path)
        let refs = try await linked.refs()
        #expect(refs.head == .branch("side"))
        #expect(refs.currentBranch?.name == "side")
    }

    @Test func relativeCommonDirectoriesResolveLexically() {
        #expect(Repository.absolutePath(".git", relativeTo: "/private/tmp/repo/sub") == "/private/tmp/repo/sub/.git")
        #expect(Repository.absolutePath("../../.git", relativeTo: "/private/tmp/repo/a/b") == "/private/tmp/repo/.git")
        #expect(Repository.absolutePath("/abs/.git", relativeTo: "/ignored") == "/abs/.git")
    }

    @Test func openOutsideARepositoryThrowsNotARepository() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let plain = sandbox.url("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        await #expect(throws: GitSetupError.notARepository(plain.path)) {
            try await Repository.open(at: plain, runner: sandbox.runner)
        }
    }

    @Test func anUnbornRepositoryReadsAsEmpty() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)

        let refs = try await repository.refs()
        #expect(refs.head == .unborn("main"))
        #expect(refs.headCommit == nil)
        #expect(refs.localBranches.isEmpty && refs.remoteBranches.isEmpty && refs.tags.isEmpty && refs.remotes.isEmpty)
        #expect(try await repository.log(limit: 100, skip: 0, extraTips: []).isEmpty)
        #expect(try await repository.stashes().isEmpty)
        #expect(try await repository.status() == .clean)

        try script.write("first.txt", "one\ntwo\n")
        try script.write("staged.txt", "s\n")
        try await script.git("add", "staged.txt")
        let status = try await repository.status()
        #expect(status.entries == [
            StatusEntry(path: "staged.txt", staged: .added),
            StatusEntry(path: "first.txt", unstaged: .untracked),
        ])
        let staged = try await repository.diff(.staged(path: "staged.txt"))
        #expect(staged.count == 1 && staged[0].kind == .added)
        #expect(staged[0].hunks[0].lines.map(\.text) == ["s"])
        let untracked = try await repository.diff(.unstaged(path: "first.txt"))
        #expect(untracked.count == 1 && untracked[0].kind == .added && untracked[0].newPath == "first.txt")
        #expect(untracked[0].hunks[0].lines.map(\.text) == ["one", "two"])
    }

    @Test func refsReportHeadBranchesTagsRemotesAndTracking() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        try await sandbox.runner.run(["init", "-q", "--bare", sandbox.url("origin.git").path], in: sandbox.directory)
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.git("remote", "add", "origin", sandbox.url("origin.git").path)
        let first = try await script.commit("First", ["a.txt": "1\n"])
        try await script.commit("Second", ["a.txt": "2\n"])
        try await script.git("push", "-q", "-u", "origin", "main")
        try await script.git("push", "-q", "origin", "main:gone-soon")
        try await script.git("branch", "--track", "tracker", "origin/gone-soon")
        try await script.git("push", "-q", "origin", "--delete", "gone-soon")
        try await script.git("fetch", "-q", "--prune")
        try await script.git("reset", "-q", "--hard", first)
        try await script.commit("Local", ["b.txt": "b\n"])
        try await script.git("tag", "light", first)
        try await script.git("tag", "-a", "v1.0", "-m", "Release 1.0\n\nNotes", first)

        let refs = try await repository.refs()
        let head = try await script.output("rev-parse", "HEAD")
        #expect(refs.head == .branch("main"))
        #expect(refs.headCommit == head)
        #expect(refs.remotes == [Remote(name: "origin", fetchURL: sandbox.url("origin.git").path, pushURL: sandbox.url("origin.git").path)])

        let main = try #require(refs.localBranches.first { $0.name == "main" })
        #expect(main.isHead && main.upstream == "origin/main" && main.ahead == 1 && main.behind == 1 && !main.upstreamGone)
        let tracker = try #require(refs.localBranches.first { $0.name == "tracker" })
        #expect(!tracker.isHead && tracker.upstreamGone)
        #expect(refs.currentBranch == main)

        #expect(refs.remoteBranches.map(\.name) == ["origin/main"])
        #expect(refs.remoteBranches.first?.remoteName == "origin")

        let light = try #require(refs.tags.first { $0.name == "light" })
        #expect(light.target == first && !light.isAnnotated && light.message == nil)
        let annotated = try #require(refs.tags.first { $0.name == "v1.0" })
        #expect(annotated.target == first && annotated.isAnnotated && annotated.message == "Release 1.0")

        try await script.git("switch", "-q", "--detach", first)
        let detached = try await repository.refs()
        #expect(detached.head == .detached(first))
        #expect(detached.currentBranch == nil)
    }

    @Test func logListsEveryTipInDateOrderWithPaging() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let root = try await script.commit("Root", ["a.txt": "1\n"])
        try await script.git("switch", "-q", "-c", "feature")
        let feature = try await script.commit("Feature", ["f.txt": "f\n"])
        try await script.git("switch", "-q", "main")
        let mainline = try await script.commit("Main", ["a.txt": "2\n"])
        try await script.git("merge", "-q", "--no-ff", "--no-edit", "feature")
        let merge = try await script.output("rev-parse", "HEAD")
        try await script.git("switch", "-q", "--orphan", "lonely")
        let lonely = try await script.commit("Lonely root", ["z.txt": "z\n"])
        try await script.git("switch", "-q", "main")
        try script.write("a.txt", "dirty\n")
        try script.write("untracked.txt", "u\n")
        try await script.git("stash", "push", "-q", "--include-untracked", "-m", "Saved")

        let all = try await repository.log(limit: 100, skip: 0, extraTips: [])
        #expect(all.map(\.id) == [lonely, merge, mainline, feature, root])
        #expect(all[1].parents == [mainline, feature] && all[1].isMerge)
        #expect(all[1].summary == "Merge branch 'feature'")
        #expect(all.last?.parents == [])
        #expect(all[0].author == Signature(name: "Test Author", email: "test@example.com", date: all[0].author.date))
        #expect(all[0].committer.date > all[1].committer.date)

        let page = try await repository.log(limit: 2, skip: 1, extraTips: [])
        #expect(page.map(\.id) == [merge, mainline])

        // A stash's internal commits never show; its base comes in via extraTips.
        let stashes = try await repository.stashes()
        #expect(stashes.count == 1)
        let withTips = try await repository.log(limit: 100, skip: 0, extraTips: [stashes[0].base])
        #expect(Set(withTips.map(\.id)) == Set(all.map(\.id)))
    }

    @Test func statusReportsEveryKindOfChange() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("Base", [
            "modified.txt": "1\n", "both.txt": "1\n", "deleted.txt": "1\n",
            "old name.txt": "same content that is long enough to be detected as a rename\n",
        ])
        try script.write("modified.txt", "2\n")
        try script.write("both.txt", "2\n")
        try await script.git("add", "both.txt")
        try script.write("both.txt", "3\n")
        try FileManager.default.removeItem(at: repository.root.appendingPathComponent("deleted.txt"))
        try await script.git("mv", "old name.txt", "Ünï name.txt")
        try script.write("new/untracked file.txt", "u\n")

        let status = try await repository.status()
        #expect(status.operation == nil)
        #expect(status.entries == [
            StatusEntry(path: "both.txt", staged: .modified, unstaged: .modified),
            StatusEntry(path: "deleted.txt", unstaged: .deleted),
            StatusEntry(path: "modified.txt", unstaged: .modified),
            StatusEntry(path: "Ünï name.txt", oldPath: "old name.txt", staged: .renamed),
            StatusEntry(path: "new/untracked file.txt", unstaged: .untracked),
        ])
        #expect(status.staged.count == 2 && status.unstaged.count == 4 && status.conflicted.isEmpty)
    }

    @Test func commitDetailListsFilesAgainstTheFirstParent() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let root = try await script.commit("Root commit", ["a.txt": "1\n2\n", "gone.txt": "g\n", "rename me.txt": "long enough content to be a rename target\n"])
        try script.write("bin.dat", Data([0, 1, 2, 0]))
        try await script.git("rm", "-q", "gone.txt")
        try await script.git("mv", "rename me.txt", "renamed.txt")
        try script.write("a.txt", "1\nchanged\nadded\n")
        try await script.git("add", "-A")
        try await script.git("commit", "-q", "-F", "-", stdin: "Change things\n\nBody line one.\n\nBody line two.\n")
        let id = try await script.output("rev-parse", "HEAD")

        let detail = try await repository.commitDetail(id)
        #expect(detail.commit.id == id && detail.commit.parents == [root])
        #expect(detail.commit.summary == "Change things")
        #expect(detail.body == "Body line one.\n\nBody line two.")
        #expect(detail.files == [
            ChangedFile(path: "a.txt", kind: .modified, additions: 2, deletions: 1),
            ChangedFile(path: "bin.dat", kind: .added, additions: nil, deletions: nil),
            ChangedFile(path: "gone.txt", kind: .deleted, additions: 0, deletions: 1),
            ChangedFile(path: "renamed.txt", oldPath: "rename me.txt", kind: .renamed, additions: 0, deletions: 0),
        ])

        let rootDetail = try await repository.commitDetail(root)
        #expect(rootDetail.body == "")
        #expect(rootDetail.files.map(\.path) == ["a.txt", "gone.txt", "rename me.txt"])
        #expect(rootDetail.files.allSatisfy { $0.kind == .added })
    }

    @Test func stashFilesIncludeUntrackedFilesAndStashDiffsShowThem() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("Base", ["a.txt": "1\n"])
        try script.write("a.txt", "plain\n")
        try await script.git("stash", "push", "-q", "-m", "Plain")
        try script.write("a.txt", "2\n")
        try script.write("scratch/new.txt", "n1\nn2\n")
        try await script.git("stash", "push", "-q", "--include-untracked", "-m", "With untracked")

        let stashes = try await repository.stashes()
        #expect(stashes.map(\.message) == ["On main: With untracked", "On main: Plain"])
        #expect(stashes.map(\.index) == [0, 1])
        let head = try await script.output("rev-parse", "HEAD")
        #expect(stashes.allSatisfy { $0.base == head })

        #expect(try await repository.stashFiles(0) == [
            ChangedFile(path: "a.txt", kind: .modified, additions: 1, deletions: 1),
            ChangedFile(path: "scratch/new.txt", kind: .untracked, additions: 2, deletions: 0),
        ])
        #expect(try await repository.stashFiles(1) == [ChangedFile(path: "a.txt", kind: .modified, additions: 1, deletions: 1)])

        let diffs = try await repository.diff(.stash(index: 0, path: nil))
        #expect(diffs.map(\.path) == ["a.txt", "scratch/new.txt"])
        #expect(diffs[1].kind == .added && diffs[1].hunks[0].lines.map(\.text) == ["n1", "n2"])
        let onlyNew = try await repository.diff(.stash(index: 0, path: "scratch/new.txt"))
        #expect(onlyNew.map(\.path) == ["scratch/new.txt"])

        let detail = try await repository.commitDetail(stashes[1].id)
        #expect(detail.files.map(\.path) == ["a.txt"])
    }

    @Test func diffsCoverStagedUnstagedAndCommits() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let lines = (1...20).map { "line \($0)" }
        let root = try await script.commit("Root", ["file.txt": lines.joined(separator: "\n") + "\n", "crlf.txt": "a\r\nb\r\n"])
        var changed = lines
        changed[1] = "changed 2"
        changed[17] = "changed 18"
        try script.write("file.txt", changed.joined(separator: "\n") + "\n")
        try script.write("crlf.txt", "a\r\nB\r\n")
        try await script.git("add", "crlf.txt")
        try script.write("spaces only.txt", "x\n")

        let unstaged = try await repository.diff(.unstaged(path: "file.txt"))
        #expect(unstaged.count == 1 && unstaged[0].hunks.count == 2)
        #expect(unstaged[0].hunks[0].lines.filter { $0.kind == .added }.map(\.text) == ["changed 2"])
        let wide = try await repository.diff(.unstaged(path: "file.txt"), contextLines: 10)
        #expect(wide[0].hunks.count == 1)

        let staged = try await repository.diff(.staged(path: "crlf.txt"))
        #expect(staged[0].hunks[0].lines.map(\.text) == ["a\r", "b\r", "B\r"])
        #expect(try await repository.diff(.staged(path: "file.txt")).isEmpty)

        try script.write("ws.txt", "a b\n")
        try await script.git("add", "ws.txt")
        try await script.git("commit", "-q", "-m", "ws")
        try script.write("ws.txt", "a  b\n")
        #expect(try await repository.diff(.unstaged(path: "ws.txt"), ignoreWhitespace: true).allSatisfy(\.hunks.isEmpty))
        #expect(try await repository.diff(.unstaged(path: "ws.txt")).first?.hunks.count == 1)

        let rootDiff = try await repository.diff(.commit(id: root, path: nil))
        #expect(rootDiff.map(\.path) == ["crlf.txt", "file.txt"])
        #expect(rootDiff.allSatisfy { $0.kind == .added })
        let wsCommit = try await script.output("rev-parse", "HEAD")
        let one = try await repository.diff(.commit(id: wsCommit, path: "ws.txt"))
        #expect(one.map(\.path) == ["ws.txt"] && one[0].kind == .added)
    }

    @Test func aStagedRenameDiffsAsARenameOfItsSource() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        let lines = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try await script.commit("Root", ["src/old name.txt": lines])
        try await script.git("mv", "src/old name.txt", "src/new name.txt")

        let staged = try await repository.diff(.staged(path: "src/new name.txt"))

        #expect(staged.count == 1)
        #expect(staged.first?.kind == .renamed)
        #expect(staged.first?.oldPath == "src/old name.txt")
        #expect(staged.first?.hunks.isEmpty == true)
    }

    @Test func diffOfAMergeCommitIsAgainstItsFirstParent() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("Root", ["a.txt": "a\n"])
        try await script.git("switch", "-q", "-c", "side")
        try await script.commit("Side", ["side.txt": "s\n"])
        try await script.git("switch", "-q", "main")
        try await script.commit("Main", ["main.txt": "m\n"])
        try await script.git("merge", "-q", "--no-edit", "side")
        let merge = try await script.output("rev-parse", "HEAD")
        #expect(try await repository.diff(.commit(id: merge, path: nil)).map(\.path) == ["side.txt"])
        #expect(try await repository.commitDetail(merge).files.map(\.path) == ["side.txt"])
    }
}

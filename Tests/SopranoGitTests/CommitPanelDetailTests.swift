import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
@Suite(.serialized)
struct CommitPanelDetailTests {
    @Test func commitModeShowsTheMessageAuthorFilesAndParentLinks() async throws {
        var first = ""
        var second = ""
        let harness = try await PanelHarness.make { script in
            first = try await script.commit("first", ["a.txt": "one\n"])
            try script.write("a.txt", "one\ntwo\n")
            try script.write("b.txt", "new\n")
            try await script.git("add", "-A")
            try await script.git("commit", "-q", "-m", "Second change", "-m", "A longer body.")
            second = try await script.output("rev-parse", "HEAD")
        }
        defer { harness.close() }
        harness.controller.select(.commit(second))
        try await harness.waitUntil { harness.panel.files.count == 2 }

        let panel = harness.panel
        #expect(panel.selectionTarget == .commit(second))
        #expect(panel.infoView.summaryText == "Second change")
        #expect(panel.infoView.bodyText == "A longer body.")
        #expect(panel.infoView.metaLines.first == "Author: Test Author <test@example.com>")
        #expect(!panel.infoView.metaLines.contains { $0.hasPrefix("Committer") })
        #expect(panel.infoView.linkedCommits == [first])
        #expect(panel.files.map(\.path) == ["a.txt", "b.txt"])
        #expect(panel.files.first?.additions == 1)
        #expect(panel.composer.isHidden)

        panel.infoView.onSelectCommit?(first)
        try await harness.waitUntil { panel.files.map(\.path) == ["a.txt"] }
        #expect(panel.selectionTarget == .commit(first))
        #expect(panel.infoView.linkedCommits.isEmpty)
    }

    @Test func openingACommitFileShowsItsDiffAndRenamesKeepBothPaths() async throws {
        var renamed = ""
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["old.txt": "same content\n"])
            try await script.git("mv", "old.txt", "new.txt")
            renamed = try await script.commit("rename")
        }
        defer { harness.close() }
        harness.controller.select(.commit(renamed))
        try await harness.waitUntil { harness.panel.files.count == 1 }
        #expect(harness.panel.files.first?.oldPath == "old.txt")

        harness.workspace.focus(.detail)
        #expect(try harness.perform("panel.openFile"))
        #expect(harness.controller.openDiff == OpenDiff(target: .commit(id: renamed, path: nil), title: "new.txt"))
        try await harness.waitUntil { harness.diff.document.file != nil }
        #expect(harness.diff.document.file?.kind == .renamed)
        #expect(harness.diff.noticeText == "Renamed without content changes: old.txt → new.txt.")
        #expect(try !harness.isEnabled("diff.stageHunk", focus: .diff))
    }

    @Test func stashModeListsTheStashsUntrackedFiles() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n"])
            try script.write("a.txt", "two\n")
            try script.write("scratch/u.txt", "untracked\n")
            try await script.git("stash", "push", "-q", "--include-untracked", "-m", "Keep this")
        }
        defer { harness.close() }
        try await harness.waitUntil { !harness.controller.stashes.isEmpty }
        harness.controller.select(.stash(0))
        try await harness.waitUntil { harness.panel.files.count == 2 }

        let panel = harness.panel
        let stash = try #require(harness.controller.stashes.first)
        #expect(panel.selectionTarget == .stash(stash))
        #expect(panel.infoView.summaryText.hasSuffix("Keep this"))
        #expect(panel.infoView.linkedCommits == [stash.base])
        #expect(panel.files.map(\.path) == ["a.txt", "scratch/u.txt"])
        #expect(panel.files.last?.kind == .untracked)

        harness.workspace.focus(.detail)
        #expect(try harness.perform("panel.next"))
        #expect(try harness.perform("panel.next"))
        #expect(try harness.perform("panel.openFile"))
        #expect(harness.controller.openDiff?.target == .stash(index: 0, path: "scratch/u.txt"))
        try await harness.waitUntil { harness.diff.document.hunkCount == 1 }
        #expect(harness.diff.document.additions == 1)
    }

    @Test func aStaleCommitDetailResultIsDroppedForTheNewerRequest() async throws {
        let loader = LatestRequestLoader<String, String>(capacity: 2)
        var applied: [String] = []
        loader.load("slow", fetch: {
            try await Task.sleep(for: .milliseconds(300))
            return "slow result"
        }, apply: { result in
            if case let .success(value) = result { applied.append(value) }
        })
        loader.load("fast", fetch: { "fast result" }, apply: { result in
            if case let .success(value) = result { applied.append(value) }
        })
        try await Task.sleep(for: .milliseconds(600))
        #expect(applied == ["fast result"])
        #expect(loader.cached("slow") == nil)
        #expect(loader.cached("fast") == "fast result")

        // A cached value applies at once; a cancelled request never applies.
        loader.load("fast", fetch: { "refetched" }, apply: { result in
            if case let .success(value) = result { applied.append("cached " + value) }
        })
        #expect(applied == ["fast result", "cached fast result"])
        loader.load("other", fetch: { "other result" }, apply: { _ in applied.append("cancelled") })
        loader.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!applied.contains("cancelled"))
    }

    @Test func theLoaderForgetsTheLeastRecentlyUsedValue() async throws {
        let loader = LatestRequestLoader<Int, Int>(capacity: 2)
        for key in 1...3 {
            loader.load(key, fetch: { key * 10 }, apply: { _ in })
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(loader.cached(1) == nil)
        #expect(loader.cached(2) == 20)
        #expect(loader.cached(3) == 30)
    }

    @Test func theWorkingCopyHeaderNamesTheBranchAndSectionsCountTheirFiles() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n"])
            try script.write("a.txt", "two\n")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()
        #expect(harness.panel.rows == [
            .section(.unstaged, count: 1),
            .file(PanelFile(section: .unstaged, path: "a.txt", kind: .modified)),
            .section(.staged, count: 0),
        ])
        #expect(!harness.panel.composer.isHidden)
        #expect(harness.panel.infoView.isHidden)
    }
}

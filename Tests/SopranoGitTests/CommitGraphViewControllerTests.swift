import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct CommitGraphViewControllerTests {
    private struct Harness {
        let sandbox: GitSandbox
        let script: GitScript
        let controller: RepositoryController
        let graph: CommitGraphViewController
        let defaults: UserDefaults
    }

    private func makeGraph(
        pageSize: Int = 100,
        _ setUp: (GitScript) async throws -> Void
    ) async throws -> Harness {
        let sandbox = try GitSandbox()
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await setUp(script)
        let controller = RepositoryController(repository: script.repository)
        controller.pageSize = { pageSize }
        let graph = CommitGraphViewController(controller: controller)
        let suite = "com.soprano.git.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        graph.defaults = defaults
        graph.loadViewIfNeeded()
        controller.start(watching: false)
        try await waitForGraph { controller.hasLoaded && graph.model.commitCount == controller.commits.count && graph.model.count > 0 }
        return Harness(sandbox: sandbox, script: script, controller: controller, graph: graph, defaults: defaults)
    }

    private func rowIDs(_ graph: CommitGraphViewController) -> [String] {
        graph.model.entries.map(\.node.id)
    }

    @Test func theWorkingCopyRowAppearsOnlyWhileTheTreeIsDirty() async throws {
        let harness = try await makeGraph { script in
            try await script.commit("first", ["a.txt": "a"])
            try await script.commit("second", ["a.txt": "b"])
        }
        defer { harness.sandbox.remove() }
        let graph = harness.graph
        #expect(graph.workingCopyRow == nil)
        #expect(graph.tableView.numberOfRows == 2)

        try harness.script.write("a.txt", "dirty")
        await harness.controller.refreshNow()
        try await waitForGraph { graph.workingCopyRow != nil }
        #expect(graph.workingCopyRow == 0)
        #expect(graph.tableView.numberOfRows == 3)
        let message = graph.configuredCell(column: .message, row: 0) as? GraphTextView
        #expect(message?.text == "// WIP")

        try await harness.script.git("checkout", "--", "a.txt")
        await harness.controller.refreshNow()
        try await waitForGraph { graph.workingCopyRow == nil }
        #expect(graph.tableView.numberOfRows == 2)
    }

    @Test func tableSelectionAndControllerSelectionFollowEachOther() async throws {
        let harness = try await makeGraph { script in
            try await script.commit("first", ["a.txt": "a"])
            try await script.commit("second", ["a.txt": "b"])
            try script.write("a.txt", "stashed")
            try await script.git("stash", "push", "-q", "-m", "parked")
            try script.write("b.txt", "dirty")
        }
        defer { harness.sandbox.remove() }
        let graph = harness.graph
        let controller = harness.controller
        let first = try #require(controller.commits.last?.id)

        try await waitForGraph { graph.tableView.selectedRow >= 0 }
        #expect(controller.selection == .workingCopy)
        #expect(graph.tableView.selectedRow == graph.workingCopyRow)
        #expect(graph.selectionTarget == .workingCopy)

        controller.select(.commit(first))
        try await waitForGraph { graph.tableView.selectedRow == graph.model.row(for: .commit(first)) }
        #expect(graph.selectionTarget == .commit(first))

        let stashRow = try #require(graph.model.row(for: .stash(0)))
        graph.tableView.selectRowIndexes(IndexSet(integer: stashRow), byExtendingSelection: false)
        #expect(controller.selection == .stash(0))
        let parked = try #require(controller.stashes.first)
        #expect(graph.selectionTarget == .stash(parked))

        // Stashing again rebuilds the rows (new stash, clean tree) and shifts the parked
        // stash to stash@{1}; the table follows it there.
        try harness.script.write("c.txt", "more")
        try await harness.script.git("stash", "push", "-q", "-u", "-m", "second")
        await controller.refreshNow()
        try await waitForGraph { graph.workingCopyRow == nil && graph.model.row(for: .stash(1)) != nil }
        #expect(controller.selection == .stash(1))
        #expect(graph.tableView.selectedRow == graph.model.row(for: .stash(1)))
        #expect(controller.stashes.first(where: { $0.index == 1 })?.message.hasSuffix("parked") == true)
    }

    @Test func jAndKMoveOneRowAndClampAtTheEnds() async throws {
        let harness = try await makeGraph { script in
            for index in 1 ... 3 { try await script.commit("c\(index)", ["f.txt": "\(index)"]) }
        }
        defer { harness.sandbox.remove() }
        let graph = harness.graph
        let commits = harness.controller.commits.map(\.id)
        try await waitForGraph { graph.tableView.selectedRow == 0 }

        graph.moveSelection(by: 1)
        #expect(harness.controller.selection == .commit(commits[1]))
        graph.moveSelection(by: 1)
        graph.moveSelection(by: 1)
        #expect(harness.controller.selection == .commit(commits[2]))
        graph.moveSelection(by: -1)
        #expect(graph.tableView.selectedRow == 1)
        graph.selectFirstRow()
        #expect(harness.controller.selection == .commit(commits[0]))
        graph.selectLastRow()
        #expect(harness.controller.selection == .commit(commits[2]))
        graph.selectHead()
        #expect(harness.controller.selection == .commit(commits[0]))
    }

    @Test func branchNavigationFollowsFirstParentsDownAndSameLaneChildrenUp() async throws {
        let harness = try await makeGraph { script in
            try await script.commit("root", ["a.txt": "a"])
            try await script.commit("fork point", ["a.txt": "b"])
            try await script.git("checkout", "-q", "-b", "feature")
            try await script.commit("feature one", ["f.txt": "1"])
            try await script.commit("feature two", ["f.txt": "2"])
            try await script.git("checkout", "-q", "main")
            try await script.commit("main fix", ["a.txt": "c"])
            try await script.git("merge", "-q", "--no-ff", "-m", "merge feature", "feature")
        }
        defer { harness.sandbox.remove() }
        let graph = harness.graph
        let controller = harness.controller
        let summary = { (selection: RepoSelection) -> String? in
            guard case let .commit(id) = selection else { return nil }
            return controller.commits.first(where: { $0.id == id })?.summary
        }
        #expect(controller.commits.map(\.summary) == ["merge feature", "main fix", "feature two", "feature one", "fork point", "root"])

        graph.selectHead()
        graph.followFirstParent()
        #expect(summary(controller.selection) == "main fix")
        graph.followFirstParent()
        #expect(summary(controller.selection) == "fork point")

        graph.followChild()
        #expect(summary(controller.selection) == "main fix", "the child on the same lane, not the nearer feature commit")
        graph.followChild()
        #expect(summary(controller.selection) == "merge feature")

        let featureOne = try #require(controller.commits.first(where: { $0.summary == "feature one" })?.id)
        controller.select(.commit(featureOne))
        try await waitForGraph { graph.tableView.selectedRow == graph.model.row(for: .commit(featureOne)) }
        graph.followChild()
        #expect(summary(controller.selection) == "feature two")
        graph.followChild()
        #expect(summary(controller.selection) == "merge feature")
    }

    @Test func pagingAsksForTheNextPageOncePerPageAndAppendsInPlace() async throws {
        let harness = try await makeGraph(pageSize: 2) { script in
            for index in 1 ... 5 { try await script.commit("c\(index)", ["f.txt": "\(index)"]) }
        }
        defer { harness.sandbox.remove() }
        let graph = harness.graph
        let controller = harness.controller
        var requests = 0
        graph.pageLoader = { requests += 1 }

        graph.checkPaging(lastVisibleRow: 0)
        graph.checkPaging(lastVisibleRow: 1)
        graph.checkPaging(lastVisibleRow: 1)
        #expect(requests == 1)

        controller.select(.commit(controller.commits[1].id))
        try await waitForGraph { graph.tableView.selectedRow == 1 }
        let firstPage = graph.model.entries.map(\.layout)
        controller.loadMoreCommits()
        try await waitForGraph { graph.model.commitCount == 4 }

        #expect(Array(graph.model.entries.prefix(2).map(\.layout)) == firstPage)
        #expect(graph.tableView.numberOfRows == 4)
        #expect(graph.tableView.selectedRow == 1)
        #expect(controller.selection == .commit(controller.commits[1].id))

        graph.checkPaging(lastVisibleRow: 3)
        graph.checkPaging(lastVisibleRow: 3)
        #expect(requests == 2)
    }

    @Test func searchHighlightsMatchesAndWrapsAround() async throws {
        let harness = try await makeGraph { script in
            try await script.commit("feat: parser", ["a.txt": "1"])
            try await script.commit("fix: crash", ["a.txt": "2"])
            try await script.commit("Feat: lexer", ["a.txt": "3"])
            try await script.commit("docs: readme", ["a.txt": "4"])
        }
        defer { harness.sandbox.remove() }
        let graph = harness.graph
        let controller = harness.controller
        let row = { (summary: String) in
            graph.model.row(for: .commit(controller.commits.first(where: { $0.summary == summary })!.id))!
        }

        graph.openSearch()
        graph.search("FEAT")

        #expect(graph.searchMatches == [row("Feat: lexer"), row("feat: parser")])
        #expect(graph.searchCountText == "1 / 2")
        #expect(graph.tableView.selectedRow == row("Feat: lexer"))
        #expect(graph.matchState(row("Feat: lexer")) == .current)
        #expect(graph.matchState(row("feat: parser")) == .match)
        #expect(graph.matchState(row("fix: crash")) == .none)

        graph.stepSearch(by: 1)
        #expect(graph.searchCountText == "2 / 2")
        #expect(graph.tableView.selectedRow == row("feat: parser"))
        graph.stepSearch(by: 1)
        #expect(graph.searchCountText == "1 / 2", "wraps past the last match")
        graph.stepSearch(by: -1)
        #expect(graph.searchCountText == "2 / 2", "wraps before the first match")

        graph.search("nothing like this")
        #expect(graph.searchCountText == "0 / 0")
        #expect(!graph.hasSearchMatches)

        graph.closeSearch()
        #expect(!graph.isSearchOpen)
        #expect(graph.matchState(row("Feat: lexer")) == .none)
    }

    @Test func refPillsComeFromTheRefsAndTheHeadBranchIsLit() async throws {
        let harness = try await makeGraph { script in
            try await script.commit("first", ["a.txt": "a"])
            try await script.git("tag", "v1")
            try await script.git("branch", "topic")
            try await script.commit("second", ["a.txt": "b"])
        }
        defer { harness.sandbox.remove() }
        let graph = harness.graph
        let refs = try #require(graph.configuredCell(column: .refs, row: 1) as? GraphRefsView)
        let head = try #require(graph.configuredCell(column: .refs, row: 0) as? GraphRefsView)

        #expect(refs.pills.map(\.name) == ["topic", "v1"])
        #expect(head.pills.map(\.name) == ["main"])
        #expect(head.pills.first?.isHead == true)
    }

    @Test func userResizedColumnWidthsPersistInTheInjectedDefaults() async throws {
        let harness = try await makeGraph { script in
            try await script.commit("first", ["a.txt": "a"])
        }
        defer { harness.sandbox.remove() }
        let column = try #require(harness.graph.tableView.tableColumns.first { $0.identifier.rawValue == "author" })

        column.width = 180

        let stored = harness.defaults.dictionary(forKey: CommitGraphViewController.columnWidthsKey) as? [String: Double]
        #expect(stored?["author"] == 180)
        let reopened = CommitGraphViewController(controller: harness.controller)
        reopened.defaults = harness.defaults
        reopened.loadViewIfNeeded()
        #expect(reopened.width(of: .author) == 180)
    }
}

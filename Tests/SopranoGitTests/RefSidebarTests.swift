import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct RefSidebarTests {
    /// Records focus moves; hosts real region controllers for the protocol.
    private final class FakeWorkspace: RepoWorkspace {
        let controller: RepositoryController
        let window: NSWindow? = nil
        let sidebar: RefSidebarViewController
        let graph: CommitGraphViewController
        let commitPanel: CommitPanelViewController
        let diff: DiffViewController
        var focused: [FocusRegion] = []
        var focusedRegion: FocusRegion? { focused.last }
        var isSidebarVisible = true
        var isCommitPanelVisible = true

        init(controller: RepositoryController, sidebar: RefSidebarViewController) {
            self.controller = controller
            self.sidebar = sidebar
            graph = CommitGraphViewController(controller: controller)
            commitPanel = CommitPanelViewController(controller: controller)
            diff = DiffViewController(controller: controller)
        }

        func focus(_ region: FocusRegion) { focused.append(region) }
        func addFocusObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (FocusRegion?) -> Void) {}
        func selectionProvider(for region: FocusRegion) -> SelectionTargetProvider? { nil }
    }

    private struct Harness {
        let sandbox: GitSandbox
        let script: GitScript
        let controller: RepositoryController
        let sidebar: RefSidebarViewController
        let workspace: FakeWorkspace
        let defaults: UserDefaults
        let suite: String
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// main (HEAD), feature/login, feature/api/v2, tag v1.0, one stash.
    private func makeHarness(suite: String? = nil, setUp: Bool = true) async throws -> Harness {
        let sandbox = try GitSandbox()
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        try await script.git("branch", "feature/login")
        try await script.commit("second", ["a.txt": "b"])
        try await script.git("branch", "feature/api/v2")
        try await script.git("tag", "-a", "v1.0", "-m", "Release one", "HEAD~1")
        try script.write("a.txt", "stashed")
        try await script.git("stash", "push", "-q", "-m", "work in progress")
        return try await harness(sandbox: sandbox, script: script, suite: suite ?? "com.soprano.git.test.\(UUID().uuidString)")
    }

    private func harness(sandbox: GitSandbox, script: GitScript, suite: String) async throws -> Harness {
        let controller = RepositoryController(repository: script.repository)
        controller.start(watching: false)
        try await waitUntil { controller.hasLoaded }
        let sidebar = RefSidebarViewController(controller: controller)
        let defaults = UserDefaults(suiteName: suite)!
        sidebar.stateDefaults = defaults
        let workspace = FakeWorkspace(controller: controller, sidebar: sidebar)
        sidebar.workspace = workspace
        _ = sidebar.view
        return Harness(sandbox: sandbox, script: script, controller: controller, sidebar: sidebar, workspace: workspace, defaults: defaults, suite: suite)
    }

    private func cleanUp(_ harness: Harness) {
        harness.controller.stop()
        harness.defaults.removePersistentDomain(forName: harness.suite)
        harness.sandbox.remove()
    }

    @Test func theCurrentBranchIsShownAndOtherFoldersStartCollapsed() async throws {
        let h = try await makeHarness()
        defer { cleanUp(h) }
        let rows = h.sidebar.visibleRowIDs
        #expect(rows.contains("ref:refs/heads/main"))
        #expect(rows.contains("folder:local:feature"))
        #expect(!rows.contains("ref:refs/heads/feature/login"))
        #expect(rows.contains("ref:refs/tags/v1.0"))
        #expect(rows.contains { $0.hasPrefix("stash:") })
    }

    @Test func aBranchCheckedOutInsideAFolderIsRevealedOnLoad() async throws {
        let sandbox = try GitSandbox()
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await script.commit("first", ["a.txt": "a"])
        try await script.git("checkout", "-q", "-b", "feature/api/v2")
        let h = try await harness(sandbox: sandbox, script: script, suite: "com.soprano.git.test.\(UUID().uuidString)")
        defer { cleanUp(h) }
        #expect(h.sidebar.visibleRowIDs.contains("ref:refs/heads/feature/api/v2"))
    }

    @Test func selectingABranchOrTagSelectsItsCommitAndAStashSelectsTheStash() async throws {
        let h = try await makeHarness()
        defer { cleanUp(h) }
        let first = try await h.script.output("rev-parse", "HEAD~1")
        h.sidebar.selectRow(id: "ref:refs/tags/v1.0")
        #expect(h.controller.selection == .commit(first))
        if case let .tag(tag)? = h.sidebar.selectionTarget { #expect(tag.name == "v1.0") } else { Issue.record("no tag target") }

        let stash = try #require(h.controller.stashes.first)
        h.sidebar.selectRow(id: "stash:\(stash.id)")
        #expect(h.controller.selection == .stash(0))
        #expect(h.sidebar.selectionTarget == .stash(stash))

        h.sidebar.selectRow(id: "ref:refs/heads/main")
        #expect(h.controller.selection == .commit(try await h.script.output("rev-parse", "HEAD")))
        #expect(h.workspace.focused.isEmpty)
    }

    @Test func theSelectedRefStaysSelectedWhenRefsRefresh() async throws {
        let h = try await makeHarness()
        defer { cleanUp(h) }
        #expect(h.sidebar.selectRow(id: "ref:refs/tags/v1.0"))
        // New refs sort before the tag and shift its row.
        try await h.script.git("branch", "aaa")
        try await h.script.git("tag", "v0.1")
        await h.controller.refreshNow(.all)
        try await waitUntil { h.sidebar.visibleRowIDs.contains("ref:refs/tags/v0.1") }
        #expect(h.sidebar.selectedNode?.id == "ref:refs/tags/v1.0")
        #expect(h.sidebar.selectedID == "ref:refs/tags/v1.0")
    }

    @Test func filteringShowsMatchesInsideExpandedFoldersAndClearingRestoresTheTree() async throws {
        let h = try await makeHarness()
        defer { cleanUp(h) }
        h.sidebar.setFilter("V2")
        #expect(h.sidebar.visibleRowIDs == [
            "section:local", "folder:local:feature", "folder:local:feature/api", "ref:refs/heads/feature/api/v2",
        ])
        h.sidebar.setFilter("")
        #expect(!h.sidebar.visibleRowIDs.contains("ref:refs/heads/feature/api/v2"))
        #expect(h.sidebar.visibleRowIDs.contains("section:tags"))
    }

    @Test func togglingAFolderPersistsAcrossSidebarsForTheSameRepository() async throws {
        let h = try await makeHarness()
        defer { cleanUp(h) }
        h.sidebar.selectRow(id: "folder:local:feature")
        h.sidebar.toggleSelected()
        #expect(h.sidebar.visibleRowIDs.contains("ref:refs/heads/feature/login"))
        h.sidebar.selectRow(id: "section:tags")
        h.sidebar.toggleSelected()
        #expect(!h.sidebar.visibleRowIDs.contains("ref:refs/tags/v1.0"))

        let second = RefSidebarViewController(controller: h.controller)
        second.stateDefaults = h.defaults
        _ = second.view
        #expect(second.visibleRowIDs.contains("ref:refs/heads/feature/login"))
        #expect(!second.visibleRowIDs.contains("ref:refs/tags/v1.0"))
    }

    @Test func activatingATagRevealsItInTheGraphAndAStashInTheCommitPanel() async throws {
        let h = try await makeHarness()
        defer { cleanUp(h) }
        let first = try await h.script.output("rev-parse", "HEAD~1")
        h.sidebar.selectRow(id: "ref:refs/tags/v1.0")
        h.sidebar.activateSelected()
        #expect(h.controller.selection == .commit(first))
        #expect(h.workspace.focused == [.graph])

        let stash = try #require(h.controller.stashes.first)
        h.sidebar.selectRow(id: "stash:\(stash.id)")
        h.sidebar.activateSelected()
        #expect(h.controller.selection == .stash(0))
        #expect(h.workspace.focused == [.graph, .detail])
    }

    @Test func activatingAFolderTogglesIt() async throws {
        let h = try await makeHarness()
        defer { cleanUp(h) }
        h.sidebar.selectRow(id: "folder:local:feature")
        h.sidebar.activateSelected()
        #expect(h.sidebar.visibleRowIDs.contains("ref:refs/heads/feature/login"))
    }

    @Test func jAndKMoveThroughEveryRowAndStopAtTheEnds() async throws {
        let h = try await makeHarness()
        defer { cleanUp(h) }
        h.sidebar.moveSelection(by: 1)
        #expect(h.sidebar.selectedNode?.id == "section:local")
        h.sidebar.moveSelection(by: -1)
        #expect(h.sidebar.selectedNode?.id == "section:local")
        for _ in 0..<50 { h.sidebar.moveSelection(by: 1) }
        #expect(h.sidebar.selectedNode?.id == h.sidebar.visibleRowIDs.last)
    }

    @Test func sidebarCommandsMatchTheBindingTable() {
        let commands = SidebarCommands.all
        #expect(commands.map(\.id) == ["sidebar.filter", "sidebar.focusFilter", "sidebar.next", "sidebar.previous", "sidebar.activate", "sidebar.toggle"])
        #expect(commands.map(\.defaultKeys) == [["cmd+shift+f"], ["/"], ["j"], ["k"], ["enter"], ["space"]])
        #expect(commands[0].scopes.isEmpty)
        #expect(commands.dropFirst().allSatisfy { $0.scopes == [.sidebar] })
        #expect(commands.filter(\.inPalette).map(\.id) == ["sidebar.filter", "sidebar.activate", "sidebar.toggle"])
    }
}

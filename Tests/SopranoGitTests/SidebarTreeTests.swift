import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct SidebarTreeTests {
    private func local(_ name: String, head: Bool = false, ahead: Int = 0, behind: Int = 0, gone: Bool = false) -> Branch {
        Branch(
            name: name, fullName: "refs/heads/\(name)", target: "c-\(name)", isRemote: false,
            upstream: "origin/\(name)", ahead: ahead, behind: behind, upstreamGone: gone, isHead: head
        )
    }

    private func remote(_ name: String) -> Branch {
        Branch(
            name: name, fullName: "refs/remotes/\(name)", target: "c-\(name)", isRemote: true,
            remoteName: String(name.split(separator: "/")[0])
        )
    }

    private func tag(_ name: String) -> SopranoGitCore.Tag {
        SopranoGitCore.Tag(name: name, fullName: "refs/tags/\(name)", target: "c-\(name)", isAnnotated: false)
    }

    private var refs: RefSnapshot {
        RefSnapshot(
            head: .branch("main"), headCommit: "c-main",
            localBranches: [local("main", head: true), local("feature/login"), local("feature/api/v2"), local("feature/api/v10"), local("Bugfix")],
            remoteBranches: [remote("origin/main"), remote("origin/feature/login"), remote("upstream/main")],
            tags: [tag("v10.0"), tag("v2.0"), tag("v1.0")],
            remotes: [Remote(name: "upstream", fetchURL: nil, pushURL: nil), Remote(name: "origin", fetchURL: nil, pushURL: nil), Remote(name: "empty", fetchURL: nil, pushURL: nil)]
        )
    }

    private let stashes = [
        Stash(index: 1, id: "s1", base: "c-main", message: "On main: older", date: Date(timeIntervalSince1970: 0)),
        Stash(index: 0, id: "s0", base: "c-main", message: "On main: newer", date: Date(timeIntervalSince1970: 10)),
    ]

    private func titles(_ nodes: [SidebarNode]) -> [String] { nodes.map(\.title) }

    private func count(_ node: SidebarNode) -> Int? {
        if case let .section(_, count) = node.kind { return count }
        return nil
    }

    @Test func sectionsAreLocalRemoteTagsStashesWithLeafCounts() {
        let tree = SidebarTree.build(refs: refs, stashes: stashes)
        #expect(tree.map(\.id) == ["section:local", "section:remote", "section:tags", "section:stashes"])
        #expect(tree.map(count) == [5, 3, 3, 2])
    }

    @Test func branchesAreGroupedIntoFoldersBySlashWithFoldersFirstInNaturalOrder() {
        let localSection = SidebarTree.build(refs: refs, stashes: [])[0]
        #expect(titles(localSection.children) == ["feature", "Bugfix", "main"])
        let feature = localSection.children[0]
        #expect(feature.id == "folder:local:feature")
        #expect(titles(feature.children) == ["api", "login"])
        let api = feature.children[0]
        #expect(api.id == "folder:local:feature/api")
        #expect(titles(api.children) == ["v2", "v10"])
        #expect(api.children[1].id == "ref:refs/heads/feature/api/v10")
    }

    @Test func remotesAreGroupsWithTheirOwnFoldersAndEmptyRemotesStillShow() {
        let remoteSection = SidebarTree.build(refs: refs, stashes: [])[1]
        #expect(titles(remoteSection.children) == ["empty", "origin", "upstream"])
        let origin = remoteSection.children[1]
        #expect(titles(origin.children) == ["feature", "main"])
        #expect(origin.children[0].id == "folder:remote:origin:feature")
        #expect(titles(origin.children[0].children) == ["login"])
        #expect(remoteSection.children[0].children.isEmpty)
    }

    @Test func tagsSortNaturallyAndStashesNewestFirst() {
        let tree = SidebarTree.build(refs: refs, stashes: stashes)
        #expect(titles(tree[2].children) == ["v1.0", "v2.0", "v10.0"])
        #expect(titles(tree[3].children) == ["On main: newer", "On main: older"])
    }

    @Test func filteringKeepsMatchingRefsWithTheirFoldersCaseInsensitively() {
        let tree = SidebarTree.build(refs: refs, stashes: stashes, filter: "LOG")
        #expect(tree.map(\.id) == ["section:local", "section:remote"])
        #expect(tree.map(count) == [1, 1])
        #expect(titles(tree[0].children) == ["feature"])
        #expect(titles(tree[0].children[0].children) == ["login"])
        #expect(titles(tree[1].children) == ["origin"])
        #expect(titles(tree[1].children[0].children[0].children) == ["login"])
    }

    @Test func filteringMatchesFolderNamesAndStashMessages() {
        let tree = SidebarTree.build(refs: refs, stashes: stashes, filter: "api")
        #expect(titles(tree[0].children[0].children[0].children) == ["v2", "v10"])
        let stashOnly = SidebarTree.build(refs: refs, stashes: stashes, filter: "older")
        #expect(stashOnly.map(\.id) == ["section:stashes"])
        #expect(titles(stashOnly[0].children) == ["On main: older"])
    }

    @Test func aFilterWithoutMatchesShowsNothing() {
        #expect(SidebarTree.build(refs: refs, stashes: stashes, filter: "zzz").isEmpty)
    }

    @Test func ancestorsOfANestedBranchAreItsSectionAndFolders() {
        #expect(SidebarTree.ancestorIDs(of: local("feature/api/v2")) == [
            "section:local", "folder:local:feature", "folder:local:feature/api",
        ])
        #expect(SidebarTree.ancestorIDs(of: remote("origin/feature/login")) == [
            "section:remote", "remote:origin", "folder:remote:origin:feature",
        ])
    }

    @Test func activationChecksOutBranchesAndRevealsTagsAndStashes() {
        let tree = SidebarTree.build(refs: refs, stashes: stashes)
        let main = tree[0].children[2]
        let remoteMain = tree[1].children[1].children[1]
        #expect(SidebarActivation.of(main) == .checkout(local("main", head: true)))
        #expect(SidebarActivation.of(remoteMain) == .checkout(remote("origin/main")))
        #expect(SidebarActivation.of(tree[2].children[0]) == .revealCommit("c-v1.0"))
        #expect(SidebarActivation.of(tree[3].children[1]) == .revealStash(1))
        #expect(SidebarActivation.of(tree[0]) == .toggle)
        #expect(SidebarActivation.of(tree[0].children[0]) == .toggle)
    }

    @Test func trackingTextShowsAheadBehindOrGone() {
        let colors = AppTheme.theme(for: "mission-control").colors
        #expect(SidebarCellView.trackingText(for: local("a", ahead: 2, behind: 1), colors: colors).string == "↑2 ↓1")
        #expect(SidebarCellView.trackingText(for: local("a", behind: 3), colors: colors).string == "↓3")
        #expect(SidebarCellView.trackingText(for: local("a", ahead: 2, gone: true), colors: colors).string == "gone")
        #expect(SidebarCellView.trackingText(for: local("a"), colors: colors).string.isEmpty)
    }

    @Test func expansionPersistsPerRepositoryWithSectionsOpenAndFoldersClosedByDefault() {
        let suite = "com.soprano.git.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: "/tmp/repo-a")
        let tree = SidebarTree.build(refs: refs, stashes: [])
        let section = tree[0]
        let folder = tree[0].children[0]

        let store = SidebarExpansionStore(defaults: defaults, repositoryRoot: root)
        #expect(store.isExpanded(section))
        #expect(!store.isExpanded(folder))
        store.set(section.id, expanded: false)
        store.set(folder.id, expanded: true)

        let reopened = SidebarExpansionStore(defaults: defaults, repositoryRoot: root)
        #expect(!reopened.isExpanded(section))
        #expect(reopened.isExpanded(folder))
        let otherRepo = SidebarExpansionStore(defaults: defaults, repositoryRoot: URL(fileURLWithPath: "/tmp/repo-b"))
        #expect(otherRepo.isExpanded(section))
    }
}

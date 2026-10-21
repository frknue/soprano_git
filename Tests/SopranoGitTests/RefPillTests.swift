import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

struct RefPillTests {
    private func local(_ name: String, at target: String, upstream: String? = nil, isHead: Bool = false) -> Branch {
        Branch(name: name, fullName: "refs/heads/\(name)", target: target, isRemote: false, upstream: upstream, isHead: isHead)
    }

    private func remote(_ name: String, at target: String) -> Branch {
        let remoteName = String(name.split(separator: "/").first!)
        return Branch(name: name, fullName: "refs/remotes/\(name)", target: target, isRemote: true, remoteName: remoteName)
    }

    private func refs(
        head: Head = .branch("main"),
        headCommit: String? = "c1",
        local: [Branch] = [],
        remote: [Branch] = [],
        tags: [SopranoGitCore.Tag] = []
    ) -> RefSnapshot {
        RefSnapshot(head: head, headCommit: headCommit, localBranches: local, remoteBranches: remote, tags: tags, remotes: [])
    }

    @Test func aLocalBranchAndItsUpstreamAtTheSameCommitShareOnePill() {
        let snapshot = refs(
            local: [local("main", at: "c1", upstream: "origin/main", isHead: true)],
            remote: [remote("origin/main", at: "c1"), remote("origin/HEAD", at: "c1")]
        )

        let pills = RefPill.index(snapshot)["c1"] ?? []

        #expect(pills.count == 1)
        #expect(pills[0].name == "main")
        #expect(pills[0].isLocal && pills[0].isRemote)
        #expect(pills[0].refNames == ["main", "origin/main"])
    }

    @Test func anUpstreamOnAnotherCommitGetsItsOwnCloudPill() {
        let snapshot = refs(
            local: [local("main", at: "c1", upstream: "origin/main", isHead: true)],
            remote: [remote("origin/main", at: "c0")]
        )
        let index = RefPill.index(snapshot)

        #expect(index["c1"]?.map(\.isRemote) == [false])
        #expect(index["c0"]?.map(\.name) == ["origin/main"])
        #expect(index["c0"]?.first?.isLocal == false)
        #expect(index["c0"]?.first?.target == .branch(remote("origin/main", at: "c0")))
    }

    @Test func aSameNamedBranchOnAnotherRemoteMergesToo() {
        let snapshot = refs(
            local: [local("feature", at: "c2")],
            remote: [remote("fork/feature", at: "c2"), remote("origin/other", at: "c2")]
        )

        let pills = RefPill.index(snapshot)["c2"] ?? []

        #expect(pills.map(\.name) == ["feature", "origin/other"])
        #expect(pills[0].refNames == ["feature", "fork/feature"])
    }

    @Test func tagsGetTheirOwnPillsAfterBranches() {
        let snapshot = refs(
            local: [local("release", at: "c3")],
            tags: [
                SopranoGitCore.Tag(name: "v2.0", fullName: "refs/tags/v2.0", target: "c3", isAnnotated: true, message: "Two"),
                SopranoGitCore.Tag(name: "v1.9", fullName: "refs/tags/v1.9", target: "c3", isAnnotated: false),
            ]
        )

        let pills = RefPill.index(snapshot)["c3"] ?? []

        #expect(pills.map(\.name) == ["release", "v1.9", "v2.0"])
        #expect(pills.map(\.isTag) == [false, true, true])
        #expect(pills[1].target == .tag(snapshot.tags[1]))
    }

    @Test func theCheckedOutBranchIsTheHeadPillAndComesFirst() {
        let snapshot = refs(
            local: [local("alpha", at: "c1"), local("main", at: "c1", isHead: true)],
            tags: [SopranoGitCore.Tag(name: "v1", fullName: "refs/tags/v1", target: "c1", isAnnotated: false)]
        )

        let pills = RefPill.index(snapshot)["c1"] ?? []

        #expect(pills.map(\.name) == ["main", "alpha", "v1"])
        #expect(pills.map(\.isHead) == [true, false, false])
    }

    @Test func aDetachedHeadShowsAHeadPill() {
        let snapshot = refs(head: .detached("c5"), headCommit: "c5", local: [local("main", at: "c5")])

        let pills = RefPill.index(snapshot)["c5"] ?? []

        #expect(pills.map(\.name) == ["HEAD", "main"])
        #expect(pills[0].isHead)
        #expect(pills[0].target == .commit("c5"))
        #expect(!pills[1].isHead)
    }
}

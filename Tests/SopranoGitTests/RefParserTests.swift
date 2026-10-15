import AppKit
import Testing
@testable import SopranoGitCore

struct RefParserTests {
    private let a = String(repeating: "a", count: 40)
    private let b = String(repeating: "b", count: 40)
    private let c = String(repeating: "c", count: 40)

    private func refs(_ records: [[String]]) -> Data {
        Data(records.map { $0.joined(separator: "\u{1F}") + "\0\n" }.joined().utf8)
    }

    @Test func localBranchesCarryUpstreamTrackingAndHead() {
        let output = refs([
            ["refs/heads/main", a, "", "commit", "origin/main", "ahead 2, behind 1", "*", "Latest subject"],
            ["refs/heads/feature/x", b, "", "commit", "origin/feature/x", "gone", " ", "x"],
            ["refs/heads/behind", c, "", "commit", "origin/behind", "behind 3", " ", "y"],
            ["refs/heads/local", c, "", "commit", "", "", " ", "z"],
        ])
        let parsed = RefParser.parseRefs(output, remoteNames: ["origin"])
        #expect(parsed.localBranches == [
            Branch(name: "main", fullName: "refs/heads/main", target: a, isRemote: false, upstream: "origin/main", ahead: 2, behind: 1, isHead: true),
            Branch(name: "feature/x", fullName: "refs/heads/feature/x", target: b, isRemote: false, upstream: "origin/feature/x", upstreamGone: true),
            Branch(name: "behind", fullName: "refs/heads/behind", target: c, isRemote: false, upstream: "origin/behind", behind: 3),
            Branch(name: "local", fullName: "refs/heads/local", target: c, isRemote: false),
        ])
    }

    @Test func remoteBranchesSkipRemoteHeadAndMatchTheLongestRemoteName() {
        let output = refs([
            ["refs/remotes/origin/HEAD", a, "", "commit", "", "", " ", ""],
            ["refs/remotes/origin/main", a, "", "commit", "", "", " ", ""],
            ["refs/remotes/team/upstream/feature/y", b, "", "commit", "", "", " ", ""],
            ["refs/remotes/team/z", c, "", "commit", "", "", " ", ""],
        ])
        let parsed = RefParser.parseRefs(output, remoteNames: ["origin", "team", "team/upstream"])
        #expect(parsed.remoteBranches == [
            Branch(name: "origin/main", fullName: "refs/remotes/origin/main", target: a, isRemote: true, remoteName: "origin"),
            Branch(name: "team/upstream/feature/y", fullName: "refs/remotes/team/upstream/feature/y", target: b, isRemote: true, remoteName: "team/upstream"),
            Branch(name: "team/z", fullName: "refs/remotes/team/z", target: c, isRemote: true, remoteName: "team"),
        ])
    }

    @Test func annotatedTagsArePeeledAndKeepTheirSubject() {
        let output = refs([
            ["refs/tags/v0.1", a, "", "commit", "", "", " ", "Commit subject, not a tag message"],
            ["refs/tags/v1.0", b, c, "tag", "", "", " ", "Release 1.0"],
        ])
        let parsed = RefParser.parseRefs(output, remoteNames: [])
        #expect(parsed.tags == [
            Tag(name: "v0.1", fullName: "refs/tags/v0.1", target: a, isAnnotated: false, message: nil),
            Tag(name: "v1.0", fullName: "refs/tags/v1.0", target: c, isAnnotated: true, message: "Release 1.0"),
        ])
    }

    @Test func subjectsMayContainTheSeparatorAndCombiningMarks() {
        let output = refs([["refs/tags/v2", b, c, "tag", "", "", " ", "\u{301}accent \u{1F} kept"]])
        #expect(RefParser.parseRefs(output, remoteNames: []).tags.first?.message == "\u{301}accent \u{1F} kept")
    }

    @Test func trackTextParsesEveryForm() {
        #expect(RefParser.parseTrack("ahead 2, behind 1") == (2, 1, false))
        #expect(RefParser.parseTrack("ahead 4") == (4, 0, false))
        #expect(RefParser.parseTrack("[behind 7]") == (0, 7, false))
        #expect(RefParser.parseTrack("gone") == (0, 0, true))
        #expect(RefParser.parseTrack("[gone]") == (0, 0, true))
        #expect(RefParser.parseTrack("") == (0, 0, false))
    }

    @Test func remotesCollectFetchAndPushURLs() {
        let output = Data("""
        origin\t/tmp/origin.git (fetch)
        origin\tssh://git@example.com/x.git (push)
        upstream\thttps://example.com/my repo.git (fetch)
        upstream\thttps://example.com/my repo.git (push)

        """.utf8)
        #expect(RefParser.parseRemotes(output) == [
            Remote(name: "origin", fetchURL: "/tmp/origin.git", pushURL: "ssh://git@example.com/x.git"),
            Remote(name: "upstream", fetchURL: "https://example.com/my repo.git", pushURL: "https://example.com/my repo.git"),
        ])
    }
}

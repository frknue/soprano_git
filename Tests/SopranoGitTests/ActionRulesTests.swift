import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

struct ActionRulesTests {
    @Test func branchNamesAreAcceptedExactlyWhenGitAcceptsThem() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let names = [
            "feature/x", "fix-1", "v1.0", "a.b", "über", "dir/sub/leaf", "x@y", "plain",
            "my branch", "tab\there", "-lead", "a..b", "a~1", "a^", "a:b", "a?", "a*", "a[b", "a\\b",
            "trail/", "/lead", "a//b", "x.lock", "dir/y.lock/z", "end.", ".hidden", "dir/.hidden", "a@{b", "HEAD",
        ]
        for name in names {
            let result = try await sandbox.runner.run(
                ["check-ref-format", "--branch", name], in: sandbox.directory, acceptedExitCodes: [0, 1, 128]
            )
            let gitAccepts = result.exitCode == 0
            let message = RefNameRules.validate(name, kind: .branch)
            #expect((message == nil) == gitAccepts, "\(name): git \(gitAccepts ? "accepts" : "rejects"), rule says \(message ?? "ok")")
        }
    }

    @Test func eachBranchNameRuleExplainsItself() {
        let cases: [(String, String)] = [
            ("", "Enter a branch name."),
            ("my branch", "Branch names can't contain spaces."),
            ("a..b", "Branch names can't contain “..”."),
            ("a~1", "Branch names can't contain ~ ^ : ? * [ or \\."),
            ("-x", "Branch names can't start with “-”."),
            ("x.lock", "Branch names can't end with “.lock”."),
            ("x/", "Branch names can't end with “/”."),
            // `check-ref-format --branch` expands "@" to HEAD's branch; `git branch @` refuses it.
            ("@", "“@” isn't a valid branch name."),
            ("main", "A branch named “main” already exists."),
            ("main/sub", "“main/sub” clashes with the existing branch “main”."),
        ]
        for (name, message) in cases {
            #expect(RefNameRules.validate(name, kind: .branch, existing: ["main"]) == message)
        }
        #expect(RefNameRules.validate("v 1", kind: .tag) == "Tag names can't contain spaces.")
        #expect(RefNameRules.validate("v1", kind: .tag, existing: ["v1"]) == "A tag named “v1” already exists.")
    }

    private func branch(_ name: String, at target: String, head: Bool = false) -> Branch {
        Branch(name: name, fullName: "refs/heads/\(name)", target: target, isRemote: false, isHead: head)
    }

    private func remote(_ name: String, at target: String) -> Branch {
        Branch(name: name, fullName: "refs/remotes/\(name)", target: target, isRemote: true, remoteName: "origin")
    }

    private func refs(_ locals: [Branch], _ remotes: [Branch] = [], head: String = "h") -> RefSnapshot {
        RefSnapshot(
            head: .branch(locals.first(where: \.isHead)?.name ?? "main"), headCommit: head,
            localBranches: locals, remoteBranches: remotes, tags: [],
            remotes: [Remote(name: "origin", fetchURL: nil, pushURL: nil)]
        )
    }

    @Test func aCommitResolvesToItsOnlyLocalBranchIgnoringHeads() {
        let snapshot = refs([branch("main", at: "c", head: true), branch("topic", at: "c")], [remote("origin/topic", at: "c")])
        #expect(ResolvedRef.resolve(.commit("c"), refs: snapshot) == .local(branch("topic", at: "c")))
    }

    @Test func aCommitWithoutOneLocalBranchFallsBackToItsOnlyRemoteBranch() {
        let two = refs([branch("a", at: "c"), branch("b", at: "c")], [remote("origin/a", at: "c")])
        #expect(ResolvedRef.resolve(.commit("c"), refs: two) == .remote(remote("origin/a", at: "c")))
        let none = refs([branch("main", at: "h", head: true)], [remote("origin/x", at: "c")])
        #expect(ResolvedRef.resolve(.commit("c"), refs: none) == .remote(remote("origin/x", at: "c")))
    }

    @Test func aCommitWithoutAnUnambiguousRefResolvesToItself() {
        let snapshot = refs([branch("a", at: "c"), branch("b", at: "c")], [remote("origin/a", at: "c"), remote("origin/b", at: "c")])
        #expect(ResolvedRef.resolve(.commit("c"), refs: snapshot) == .commit("c"))
        #expect(ResolvedRef.resolve(.commit("lonely"), refs: snapshot) == .commit("lonely"))
    }

    @Test func revisionsUseShortNamesUnlessAnotherRefSharesTheName() {
        var snapshot = refs([branch("main", at: "h", head: true), branch("v1", at: "c")])
        #expect(ResolvedRef.local(branch("v1", at: "c")).revision(in: snapshot) == "v1")
        snapshot.tags = [Tag(name: "v1", fullName: "refs/tags/v1", target: "c", isAnnotated: false)]
        #expect(ResolvedRef.local(branch("v1", at: "c")).revision(in: snapshot) == "refs/heads/v1")
    }

    @Test func checkoutPlansPreferBranchesAndSkipNoOps() {
        let main = branch("main", at: "h", head: true)
        let snapshot = refs([main, branch("topic", at: "t")], [remote("origin/main", at: "h"), remote("origin/new", at: "n")])
        #expect(CheckoutPlan.plan(for: .branch(main), refs: snapshot) == nil)
        #expect(CheckoutPlan.plan(for: .branch(remote("origin/main", at: "h")), refs: snapshot) == nil)
        #expect(CheckoutPlan.plan(for: .commit("t"), refs: snapshot) == .switchTo("topic"))
        #expect(CheckoutPlan.plan(for: .commit("n"), refs: snapshot) == .track(remoteBranch: "origin/new", localName: "new"))
        #expect(CheckoutPlan.plan(for: .commit("x"), refs: snapshot) == .detach(id: "x", label: "x"))
        let tag = Tag(name: "v1", fullName: "refs/tags/v1", target: "h", isAnnotated: true)
        #expect(CheckoutPlan.plan(for: .tag(tag), refs: snapshot) == .detach(id: "h", label: "v1"))
    }
}

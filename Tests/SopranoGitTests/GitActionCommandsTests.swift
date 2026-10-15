import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct GitActionCommandsTests {
    private func command(_ id: String) throws -> AppCommand {
        try #require(GitActionCommands.all.first { $0.id == id })
    }

    @Test func theCommandsMatchTheBindingTable() {
        let expected: [(String, String, Set<FocusRegion>, [String])] = [
            ("repo.fetch", "Fetch All", [], ["cmd+l", "prefix+f"]),
            ("repo.pull", "Pull", [], ["prefix+p"]),
            ("repo.push", "Push", [], ["prefix+shift+p"]),
            ("branch.push", "Push Branch", [], []),
            ("branch.create", "Create Branch…", [], ["cmd+b", "b"]),
            ("ref.checkout", "Checkout", [.graph, .sidebar], ["c"]),
            ("branch.rename", "Rename Branch…", [.sidebar], ["e"]),
            ("branch.setUpstream", "Set Upstream…", [], []),
            ("ref.delete", "Delete Branch/Tag/Stash…", [.sidebar], ["d"]),
            ("ref.copy", "Copy SHA / Name", [.graph, .sidebar, .detail], ["y"]),
            ("ref.merge", "Merge into Current Branch", [.graph, .sidebar], ["m"]),
            ("ref.rebase", "Rebase Current Branch onto…", [.graph, .sidebar], ["r"]),
            ("operation.continue", "Continue Merge/Rebase/…", [], ["prefix+c"]),
            ("operation.abort", "Abort Merge/Rebase/…", [], ["prefix+x"]),
            ("operation.skip", "Skip Commit", [], []),
            ("commit.cherryPick", "Cherry-pick Commit", [.graph], ["p"]),
            ("commit.revert", "Revert Commit", [.graph], ["v"]),
            ("commit.reset", "Reset Current Branch to Here…", [.graph], ["shift+r"]),
            ("tag.create", "Create Tag Here…", [.graph, .sidebar], ["t"]),
            ("tag.push", "Push Tag", [], []),
            ("stash.save", "Stash Changes", [], ["prefix+s"]),
            ("stash.pop", "Pop Stash", [], ["prefix+shift+s"]),
            ("stash.apply", "Apply Stash", [], []),
        ]
        let commands = GitActionCommands.all
        #expect(commands.map(\.id) == expected.map(\.0))
        for (command, row) in zip(commands, expected) {
            #expect(command.title == row.1, "\(row.0)")
            #expect(command.scopes == row.2, "\(row.0)")
            #expect(command.defaultKeys == row.3, "\(row.0)")
            #expect(command.inPalette, "\(row.0)")
        }
        let keymap = Keymap.resolve(commands: ShellCommands.all + commands, settings: KeybindingSettings())
        #expect(keymap.issues.isEmpty)
    }

    @Test func nothingIsEnabledOutsideARepository() {
        let context = CommandContext(window: nil, workspace: nil, focus: nil, isTextInput: false)
        for command in GitActionCommands.all {
            #expect(!command.isEnabled(context), "\(command.id)")
        }
    }

    @Test func mergeAndRebaseAreDisabledForHeadItself() async throws {
        let fixture = try await ActionFixture.make()
        defer { fixture.remove() }
        try await fixture.script.git("branch", "same")
        try await fixture.script.git("switch", "-q", "-c", "ahead")
        try await fixture.script.commit("Ahead", ["b.txt": "b\n"])
        try await fixture.script.git("switch", "-q", "main")
        await fixture.reload()
        let workspace = fixture.workspace
        let head = try #require(fixture.controller.refs.headCommit)

        for id in ["ref.merge", "ref.rebase"] {
            let command = try command(id)
            #expect(!command.isEnabled(workspace.context(.branch(try fixture.branch("main")), focus: .sidebar)))
            #expect(!command.isEnabled(workspace.context(.branch(try fixture.branch("same")), focus: .sidebar)))
            #expect(!command.isEnabled(workspace.context(.commit(head))))
            #expect(command.isEnabled(workspace.context(.branch(try fixture.branch("ahead")), focus: .sidebar)))
            #expect(!command.isEnabled(workspace.context(.workingCopy)))
        }
        #expect(!(try command("commit.cherryPick")).isEnabled(workspace.context(.commit(head))))
        #expect(try command("commit.cherryPick").isEnabled(workspace.context(.commit(try fixture.branch("ahead").target))))
        #expect(!(try command("commit.cherryPick")).isEnabled(workspace.context(.branch(try fixture.branch("ahead")))))
        #expect(try command("commit.reset").isEnabled(workspace.context(.commit(head))))
        #expect(!(try command("ref.checkout")).isEnabled(workspace.context(.branch(try fixture.branch("main")))))
        #expect(try command("ref.checkout").isEnabled(workspace.context(.branch(try fixture.branch("ahead")))))
    }

    @Test func deleteRenameAndCopyFollowTheTargetKind() async throws {
        let fixture = try await ActionFixture.make(remote: true)
        defer { fixture.remove() }
        try await fixture.script.git("branch", "other")
        try await fixture.script.git("tag", "v1")
        try fixture.script.write("a.txt", "dirty\n")
        try await fixture.script.git("stash", "push", "-q")
        await fixture.reload()
        let workspace = fixture.workspace
        let head = try #require(fixture.controller.refs.headCommit)
        let stash = try #require(fixture.controller.stashes.first)
        let delete = try command("ref.delete")
        let rename = try command("branch.rename")
        let copy = try command("ref.copy")

        #expect(!delete.isEnabled(workspace.context(.branch(try fixture.branch("main")), focus: .sidebar)))
        #expect(delete.isEnabled(workspace.context(.branch(try fixture.branch("other")), focus: .sidebar)))
        #expect(delete.isEnabled(workspace.context(.branch(try fixture.branch("origin/main")), focus: .sidebar)))
        #expect(delete.isEnabled(workspace.context(.tag(try fixture.tag("v1")), focus: .sidebar)))
        #expect(delete.isEnabled(workspace.context(.stash(stash), focus: .sidebar)))
        #expect(!delete.isEnabled(workspace.context(.commit(head))))

        #expect(rename.isEnabled(workspace.context(.branch(try fixture.branch("main")), focus: .sidebar)))
        #expect(!rename.isEnabled(workspace.context(.branch(try fixture.branch("origin/main")), focus: .sidebar)))
        #expect(!rename.isEnabled(workspace.context(.tag(try fixture.tag("v1")), focus: .sidebar)))

        #expect(!copy.isEnabled(workspace.context(.workingCopy)))
        #expect(copy.isEnabled(workspace.context(.commit(head))))
        #expect(ActionRules.copyText(for: .commit(head)) == head)
        #expect(ActionRules.copyText(for: .stash(stash)) == stash.id)
        #expect(ActionRules.copyText(for: .branch(try fixture.branch("origin/main"))) == "origin/main")
        #expect(ActionRules.copyText(for: .tag(try fixture.tag("v1"))) == "v1")
    }

    @Test func remoteAndStashCommandsNeedSomethingToWorkOn() async throws {
        let fixture = try await ActionFixture.make()
        defer { fixture.remove() }
        let workspace = fixture.workspace
        let head = try #require(fixture.controller.refs.headCommit)
        let context = workspace.context(.commit(head))

        for id in ["repo.fetch", "repo.pull", "repo.push", "branch.push", "tag.push", "stash.save", "stash.pop", "stash.apply"] {
            #expect(!(try command(id)).isEnabled(context), "\(id)")
        }
        #expect(try command("branch.create").isEnabled(context))

        try fixture.script.write("a.txt", "dirty\n")
        await fixture.reload()
        #expect(try command("stash.save").isEnabled(context))
        try await fixture.script.git("stash", "push", "-q")
        await fixture.reload()
        #expect(try command("stash.pop").isEnabled(context))
        #expect(try command("stash.apply").isEnabled(context))
    }

    @Test func pushNeedsACurrentBranch() async throws {
        let fixture = try await ActionFixture.make(remote: true)
        defer { fixture.remove() }
        let workspace = fixture.workspace
        let head = try #require(fixture.controller.refs.headCommit)
        let push = try command("repo.push")
        #expect(push.isEnabled(workspace.context(.commit(head))))
        #expect(try command("repo.pull").isEnabled(workspace.context(.commit(head))))

        try await fixture.script.git("switch", "-q", "--detach")
        await fixture.reload()
        #expect(!push.isEnabled(workspace.context(.commit(head))))
        #expect(!(try command("repo.pull")).isEnabled(workspace.context(.commit(head))))
    }

    @Test func operationCommandsFollowThePausedOperation() async throws {
        let fixture = try await ActionFixture.make()
        defer { fixture.remove() }
        try await fixture.script.git("switch", "-q", "-c", "topic")
        try await fixture.script.commit("Topic", ["a.txt": "topic\n"])
        try await fixture.script.commit("Topic 2", ["b.txt": "b\n"])
        try await fixture.script.git("switch", "-q", "main")
        try await fixture.script.commit("Main", ["a.txt": "main\n"])
        await fixture.reload()
        let workspace = fixture.workspace
        let context = workspace.context(.workingCopy)
        let ids = ["operation.continue", "operation.abort", "operation.skip"]

        #expect(try ids.map { try command($0).isEnabled(context) } == [false, false, false])

        try await fixture.script.git("merge", "topic", accepting: [1])
        await fixture.reload()
        #expect(try ids.map { try command($0).isEnabled(context) } == [true, true, false])
        #expect(!(try command("ref.checkout")).isEnabled(workspace.context(.branch(try fixture.branch("topic")))))

        try await fixture.script.git("merge", "--abort")
        try await fixture.script.git("rebase", "topic", accepting: [1])
        await fixture.reload()
        #expect(try ids.map { try command($0).isEnabled(context) } == [true, true, true])
    }

    @Test func theCommandTargetFallsBackToTheSharedSelection() async throws {
        let fixture = try await ActionFixture.make()
        defer { fixture.remove() }
        let head = try #require(fixture.controller.refs.headCommit)
        let context = CommandContext(window: nil, workspace: fixture.workspace, focus: nil, isTextInput: false)
        fixture.controller.select(.commit(head))

        #expect(ActionRules.target(context) == .commit(head))
    }
}

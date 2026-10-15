import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct GitActionsMenuTests {
    init() {
        // Shortcut hints come from the shared keymap.
        if CommandRegistry.shared.command("ref.checkout") == nil {
            CommandRegistry.shared.register(GitActionCommands.all)
        }
    }

    /// Titles with separators as "—", submenus as "Title ▸ A/B/C".
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            let label = (item as? ActionMenuItem)?.label ?? item.title
            if let submenu = item.submenu { return label + " ▸ " + submenu.items.map(\.title).joined(separator: "/") }
            return label
        }
    }

    private func item(_ menu: NSMenu, _ title: String) throws -> ActionMenuItem {
        try #require(menu.items.lazy.compactMap { $0 as? ActionMenuItem }.first { $0.label == title })
    }

    @Test func aCommitOffersTheGitKrakenCommitActions() async throws {
        let fixture = try await ActionFixture.make()
        defer { fixture.remove() }
        let base = try #require(fixture.controller.refs.headCommit)
        try await fixture.script.commit("Second", ["a.txt": "b\n"])
        await fixture.reload()

        let menu = GitActions.contextMenu(for: .commit(base), in: fixture.workspace)

        #expect(titles(menu) == [
            "Checkout", "Create Branch Here…", "Create Tag Here…", "—",
            "Merge into main", "Rebase main onto This", "—",
            "Cherry-pick", "Revert", "Reset main to This ▸ Soft/Mixed/Hard", "—",
            "Copy SHA",
        ])
        #expect(menu.items.allSatisfy { $0.isSeparatorItem || $0.isEnabled })
        #expect(try item(menu, "Checkout").shortcut == "C")
        #expect(try item(menu, "Reset main to This").shortcut == "Shift+R")
        #expect(try item(menu, "Create Branch Here…").shortcut == "⌘B")
        #expect(try item(menu, "Copy SHA").attributedTitle?.string == "Copy SHA\tY")
    }

    @Test func headsOwnCommitDisablesWhatWouldDoNothing() async throws {
        let fixture = try await ActionFixture.make()
        defer { fixture.remove() }
        let head = try #require(fixture.controller.refs.headCommit)

        let menu = GitActions.contextMenu(for: .commit(head), in: fixture.workspace)

        for title in ["Checkout", "Merge into main", "Rebase main onto This", "Cherry-pick"] {
            #expect(try !item(menu, title).isEnabled, "\(title)")
        }
        for title in ["Revert", "Reset main to This", "Create Branch Here…", "Copy SHA"] {
            #expect(try item(menu, title).isEnabled, "\(title)")
        }
    }

    @Test func aLocalBranchOffersBranchActions() async throws {
        let fixture = try await ActionFixture.make()
        defer { fixture.remove() }
        try await fixture.script.git("switch", "-q", "-c", "topic")
        try await fixture.script.commit("Topic", ["t.txt": "t\n"])
        try await fixture.script.git("switch", "-q", "main")
        await fixture.reload()

        let menu = GitActions.contextMenu(for: .branch(try fixture.branch("topic")), in: fixture.workspace)

        #expect(titles(menu) == [
            "Checkout topic", "Merge topic into main", "Rebase main onto topic", "—",
            "Push topic", "Set Upstream…", "—",
            "Rename…", "Delete…", "—",
            "Create Branch Here…", "Create Tag Here…", "—",
            "Copy Name",
        ])
        // No remote yet.
        #expect(try !item(menu, "Push topic").isEnabled)
        #expect(try !item(menu, "Set Upstream…").isEnabled)
        #expect(try item(menu, "Delete…").isEnabled)
        #expect(try item(menu, "Delete…").shortcut == "D")

        let current = GitActions.contextMenu(for: .branch(try fixture.branch("main")), in: fixture.workspace)
        for title in ["Checkout main", "Merge main into main", "Delete…"] {
            #expect(try !item(current, title).isEnabled, "\(title)")
        }
        #expect(try item(current, "Rename…").isEnabled)
    }

    @Test func remoteBranchesTagsStashesAndTheWorkingCopyHaveTheirOwnMenus() async throws {
        let fixture = try await ActionFixture.make(remote: true)
        defer { fixture.remove() }
        try await fixture.script.git("push", "-q", "origin", "main:feature")
        try await fixture.script.git("tag", "v1")
        try fixture.script.write("a.txt", "dirty\n")
        try await fixture.script.git("stash", "push", "-q")
        await fixture.reload()

        let remote = GitActions.contextMenu(for: .branch(try fixture.branch("origin/feature")), in: fixture.workspace)
        #expect(titles(remote) == [
            "Checkout origin/feature", "Merge origin/feature into main", "Rebase main onto origin/feature", "—",
            "Delete feature on origin…", "—", "Copy Name",
        ])
        #expect(try item(remote, "Checkout origin/feature").isEnabled)

        let tag = GitActions.contextMenu(for: .tag(try fixture.tag("v1")), in: fixture.workspace)
        #expect(titles(tag) == ["Checkout v1", "Merge v1 into main", "—", "Push Tag", "Delete…", "—", "Copy Name"])
        #expect(try item(tag, "Push Tag").isEnabled)

        let stash = GitActions.contextMenu(for: .stash(try #require(fixture.controller.stashes.first)), in: fixture.workspace)
        #expect(titles(stash) == ["Apply Stash", "Pop Stash", "—", "Delete Stash…"])
        #expect(try item(stash, "Pop Stash").shortcut == "Prefix → Shift+S")

        let clean = GitActions.contextMenu(for: .workingCopy, in: fixture.workspace)
        #expect(titles(clean) == ["Stash Changes"])
        #expect(try !item(clean, "Stash Changes").isEnabled)
        try fixture.script.write("a.txt", "dirty again\n")
        await fixture.reload()
        let dirty = GitActions.contextMenu(for: .workingCopy, in: fixture.workspace)
        #expect(try item(dirty, "Stash Changes").isEnabled)
    }

    @Test func choosingAMenuItemRunsItsFlow() async throws {
        try await DialogTurn.exclusive {
            let fixture = try await ActionFixture.make()
            defer { fixture.remove() }
            let head = try #require(fixture.controller.refs.headCommit)
            try await fixture.script.commit("Second", ["a.txt": "b\n"])
            await fixture.reload()
            let menu = GitActions.contextMenu(for: .commit(head), in: fixture.workspace)
            let reset = try #require(try item(menu, "Reset main to This").submenu)

            let mixed = try #require(reset.items.compactMap { $0 as? ActionMenuItem }.first { $0.label == "Mixed" })
            _ = mixed.target?.perform(mixed.action, with: mixed)
            try await fixture.waitUntil { fixture.controller.refs.headCommit == head }

            #expect(fixture.controller.status.unstaged.map(\.path) == ["a.txt"])
        }
    }
}

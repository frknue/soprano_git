import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
@Suite(.serialized)
struct CommitPanelStagingTests {
    @Test func stagingAndUnstagingAFileMovesItBetweenSections() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n"])
            try script.write("a.txt", "two\n")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()

        try harness.selectFile("a.txt", in: .unstaged)
        #expect(try harness.perform("wip.stageFile"))
        try await harness.waitUntil { harness.entry("a.txt")?.staged == .modified }
        #expect(harness.entry("a.txt")?.unstaged == nil)
        #expect(harness.panel.rows.contains(.file(PanelFile(section: .staged, path: "a.txt", kind: .modified))))

        try harness.selectFile("a.txt", in: .staged)
        #expect(try harness.perform("wip.unstageFile"))
        try await harness.waitUntil { harness.entry("a.txt")?.unstaged == .modified }
        #expect(harness.entry("a.txt")?.staged == nil)
    }

    @Test func discardingAfterConfirmingRestoresTrackedFilesAndDeletesUntrackedOnes() async throws {
        try await DialogTurn.exclusive {
            let harness = try await PanelHarness.make { script in
                try await script.commit("first", ["a.txt": "one\n"])
                try script.write("a.txt", "changed\n")
                try script.write("new.txt", "scratch\n")
            }
            defer { harness.close() }
            try await harness.showWorkingCopy()

            try harness.selectFile("new.txt", in: .unstaged)
            #expect(try harness.perform("wip.discardFile"))
            try await harness.confirmDialog()
            try await harness.waitUntil { harness.entry("new.txt") == nil }
            #expect(!harness.script.exists("new.txt"))

            try harness.selectFile("a.txt", in: .unstaged)
            #expect(try harness.perform("wip.discardFile"))
            try await harness.confirmDialog()
            try await harness.waitUntil { harness.controller.status.isClean }
            #expect(try harness.script.read("a.txt") == "one\n")
        }
    }

    @Test func cancellingTheDiscardDialogKeepsTheChange() async throws {
        try await DialogTurn.exclusive {
            let harness = try await PanelHarness.make { script in
                try await script.commit("first", ["a.txt": "one\n"])
                try script.write("a.txt", "changed\n")
            }
            defer { harness.close() }
            try await harness.showWorkingCopy()

            try harness.selectFile("a.txt", in: .unstaged)
            #expect(try harness.perform("wip.discardFile"))
            try await harness.waitUntil { Dialogs.current?.isVisible == true }
            Dialogs.current?.finish(.cancelled)
            try await harness.waitUntil { Dialogs.current == nil }
            await harness.controller.refreshNow(.status)
            #expect(try harness.script.read("a.txt") == "changed\n")
            #expect(harness.entry("a.txt")?.unstaged == .modified)
        }
    }

    @Test func fileCommandsOnlyApplyToTheirSection() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n", "b.txt": "one\n"])
            try script.write("a.txt", "two\n")
            try await script.git("add", "a.txt")
            try script.write("b.txt", "two\n")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()

        try harness.selectFile("a.txt", in: .staged)
        #expect(try harness.isEnabled("wip.unstageFile"))
        #expect(try !harness.isEnabled("wip.stageFile"))
        #expect(try !harness.isEnabled("wip.discardFile"))

        try harness.selectFile("b.txt", in: .unstaged)
        #expect(try harness.isEnabled("wip.stageFile"))
        #expect(try harness.isEnabled("wip.discardFile"))
        #expect(try !harness.isEnabled("wip.unstageFile"))
        #expect(try !harness.isEnabled("conflict.takeOurs"))
    }

    @Test func stageAllAndUnstageAllMoveEveryFile() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n"])
            try script.write("a.txt", "two\n")
            try script.write("dir/new.txt", "new\n")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()

        #expect(try harness.perform("wip.stageAll", focus: .graph))
        try await harness.waitUntil { harness.controller.status.unstaged.isEmpty }
        #expect(harness.controller.status.staged.map(\.path).sorted() == ["a.txt", "dir/new.txt"])
        #expect(try !harness.isEnabled("wip.stageAll"))

        #expect(try harness.perform("wip.unstageAll", focus: .graph))
        try await harness.waitUntil { harness.controller.status.staged.isEmpty }
        #expect(harness.controller.status.unstaged.count == 2)
    }

    @Test func jAndKWalkTheFilesAcrossSectionsSkippingHeadings() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n", "c.txt": "one\n"])
            try script.write("a.txt", "two\n")
            try script.write("b.txt", "new\n")
            try script.write("c.txt", "two\n")
            try await script.git("add", "c.txt")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()
        let panel = harness.panel
        #expect(panel.rows.map { row -> String in
            switch row {
            case let .section(section, count): "\(section.title) (\(count))"
            case let .file(file): file.path
            }
        } == ["Unstaged (2)", "a.txt", "b.txt", "Staged (1)", "c.txt"])

        harness.workspace.focus(.detail)
        #expect(harness.workspace.focusedRegion == .detail)
        #expect(panel.selectedFile?.path == "a.txt")
        #expect(try harness.perform("panel.next"))
        #expect(panel.selectedFile?.key == PanelFile.Key(section: .unstaged, path: "b.txt"))
        #expect(try harness.perform("panel.next"))
        #expect(panel.selectedFile?.key == PanelFile.Key(section: .staged, path: "c.txt"))
        #expect(try harness.perform("panel.next"))
        #expect(panel.selectedFile?.path == "c.txt")
        #expect(try harness.perform("panel.previous"))
        #expect(panel.selectedFile?.path == "b.txt")
        #expect(panel.selectionTarget == .workingCopy)
    }

    @Test func stagingTheSelectedFileSelectsTheNextOneInItsPlace() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n", "b.txt": "one\n"])
            try script.write("a.txt", "two\n")
            try script.write("b.txt", "two\n")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()

        try harness.selectFile("a.txt", in: .unstaged)
        #expect(try harness.perform("wip.stageFile"))
        try await harness.waitUntil { harness.entry("a.txt")?.staged != nil }
        #expect(harness.panel.selectedFile?.key == PanelFile.Key(section: .unstaged, path: "b.txt"))
    }

    @Test func conflictsAreListedFirstAndResolveWithTheirs() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("base", ["c.txt": "base\n"])
            try await script.git("checkout", "-q", "-b", "feature")
            try await script.commit("theirs", ["c.txt": "theirs\n"])
            try await script.git("checkout", "-q", "main")
            try await script.commit("ours", ["c.txt": "ours\n"])
            try await script.git("merge", "feature", accepting: [1])
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()

        #expect(harness.panel.rows.first == .section(.conflicts, count: 1))
        try harness.selectFile("c.txt", in: .conflicts)
        #expect(try harness.isEnabled("conflict.takeOurs"))
        #expect(try harness.perform("conflict.takeTheirs"))
        try await harness.waitUntil { harness.controller.status.conflicted.isEmpty }
        #expect(try harness.script.read("c.txt") == "theirs\n")
        #expect(harness.panel.rows.first == .section(.unstaged, count: 0))
    }
}

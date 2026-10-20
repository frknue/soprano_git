import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
@Suite(.serialized)
struct CommitPanelSelectionTests {
    private func clickButton(_ title: String, inRow row: Int, of harness: PanelHarness) throws {
        func find(in view: NSView) -> KeyHintButton? {
            if let button = view as? KeyHintButton, button.title == title { return button }
            for child in view.subviews {
                if let button = find(in: child) { return button }
            }
            return nil
        }
        let cell = try #require(harness.panel.tableView.view(atColumn: 0, row: row, makeIfNecessary: true))
        let button = try #require(find(in: cell))
        button.performClick(nil)
    }

    @Test func modifierClicksToggleIndividualFilesWithoutOpeningTheirDiffs() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("base", ["a.txt": "base\n", "b.txt": "base\n", "c.txt": "base\n"])
            for path in ["a.txt", "b.txt", "c.txt"] { try script.write(path, "changed\n") }
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()

        try SnapshotCommand.clickFile("ctrl+unstaged:a.txt", in: harness.workspace)
        try SnapshotCommand.clickFile("ctrl+unstaged:c.txt", in: harness.workspace)
        #expect(harness.panel.selectedFiles.map(\.path) == ["a.txt", "c.txt"])
        #expect(harness.controller.openDiff == nil)
        try SnapshotCommand.clickFile("cmd+unstaged:b.txt", in: harness.workspace)
        try SnapshotCommand.clickFile("ctrl+unstaged:a.txt", in: harness.workspace)
        #expect(harness.panel.selectedFiles.map(\.path) == ["b.txt", "c.txt"])
        #expect(harness.controller.openDiff == nil)
        for row in harness.panel.tableView.selectedRowIndexes {
            let cell = harness.panel.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? PanelFileCellView
            #expect(cell?.isRowSelected == true)
        }

        try SnapshotCommand.clickFile("unstaged:a.txt", in: harness.workspace)
        #expect(harness.panel.selectedFiles.map(\.path) == ["a.txt"])
        #expect(harness.controller.openDiff?.target == .unstaged(path: "a.txt"))
    }

    @Test func escapeClosesTheDiffAfterClickingAnotherFileInThePanel() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("base", ["a.txt": "base\n", "b.txt": "base\n"])
            for path in ["a.txt", "b.txt"] { try script.write(path, "changed\n") }
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()

        try SnapshotCommand.clickFile("unstaged:a.txt", in: harness.workspace)
        try SnapshotCommand.clickFile("unstaged:b.txt", in: harness.workspace)
        #expect(harness.controller.openDiff?.target == .unstaged(path: "b.txt"))
        #expect(harness.workspace.focusedRegion == .detail)

        #expect(harness.press(KeyStroke(key: "\u{1B}")) == .handled)
        #expect(harness.controller.openDiff == nil)
    }

    @Test func shiftClickSelectsARangeAcrossSectionsWithoutSelectingHeadings() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("base", ["a.txt": "base\n", "b.txt": "base\n", "c.txt": "base\n"])
            for path in ["a.txt", "b.txt", "c.txt"] { try script.write(path, "changed\n") }
            try await script.git("add", "c.txt")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()

        try SnapshotCommand.clickFile("unstaged:a.txt", in: harness.workspace)
        let openDiff = harness.controller.openDiff
        try SnapshotCommand.clickFile("shift+staged:c.txt", in: harness.workspace)
        #expect(harness.panel.selectedFiles.map(\.path) == ["a.txt", "b.txt", "c.txt"])
        #expect(harness.panel.tableView.selectedRowIndexes.allSatisfy { harness.panel.rows[$0].file != nil })
        #expect(harness.controller.openDiff == openDiff)
    }

    @Test func stageAndUnstageOnlyTouchTheSelectedFiles() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("base", ["a.txt": "base\n", "b.txt": "base\n"])
            try script.write("a.txt", "stage this\n")
            try script.write("b.txt", "leave unstaged\n")
            try script.write("new.txt", "stage this addition\n")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()
        try SnapshotCommand.clickFile("ctrl+unstaged:a.txt", in: harness.workspace)
        try SnapshotCommand.clickFile("ctrl+unstaged:new.txt", in: harness.workspace)

        try clickButton("Stage 2", inRow: 0, of: harness)
        try await harness.waitUntil { harness.controller.status.staged.count == 2 }
        #expect(try await harness.script.indexContents("a.txt") == "stage this\n")
        #expect(try await harness.script.indexContents("new.txt") == "stage this addition\n")
        #expect(try await harness.script.indexContents("b.txt") == "base\n")
        #expect(harness.entry("b.txt")?.unstaged == .modified)

        // Include the remaining unstaged row: unstage must ignore that side.
        harness.panel.tableView.deselectAll(nil)
        try SnapshotCommand.clickFile("ctrl+unstaged:b.txt", in: harness.workspace)
        try SnapshotCommand.clickFile("ctrl+staged:a.txt", in: harness.workspace)
        try SnapshotCommand.clickFile("ctrl+staged:new.txt", in: harness.workspace)
        #expect(try harness.perform("wip.unstageFile"))
        try await harness.waitUntil { harness.controller.status.staged.isEmpty }
        #expect(try await harness.script.indexContents("a.txt") == "base\n")
        #expect(harness.entry("new.txt")?.unstaged == .untracked)
        #expect(try harness.script.read("b.txt") == "leave unstaged\n")
    }

    @Test func discardingTheSelectionKeepsUnselectedChangesAndTheIndex() async throws {
        try await DialogTurn.exclusive {
            let harness = try await PanelHarness.make { script in
                try await script.commit("base", ["a.txt": "base\n", "b.txt": "base\n"])
                try script.write("a.txt", "staged\n")
                try await script.git("add", "a.txt")
                try script.write("a.txt", "unstaged\n")
                try script.write("b.txt", "keep this\n")
                try script.write("new.txt", "delete this\n")
            }
            defer { harness.close() }
            try await harness.showWorkingCopy()
            try SnapshotCommand.clickFile("ctrl+unstaged:a.txt", in: harness.workspace)
            try SnapshotCommand.clickFile("ctrl+unstaged:new.txt", in: harness.workspace)
            try SnapshotCommand.clickFile("ctrl+staged:a.txt", in: harness.workspace)

            try clickButton("Discard 2", inRow: 1, of: harness)
            try await harness.confirmDialog()
            try await harness.waitUntil { harness.entry("new.txt") == nil && harness.entry("a.txt")?.unstaged == nil }
            #expect(try harness.script.read("a.txt") == "staged\n")
            #expect(try await harness.script.indexContents("a.txt") == "staged\n")
            #expect(try harness.script.read("b.txt") == "keep this\n")
            #expect(!harness.script.exists("new.txt"))
            #expect(harness.panel.selectedFiles.map(\.key) == [PanelFile.Key(section: .staged, path: "a.txt")])
        }
    }

    @Test func cancellingSelectedDiscardLeavesEverySelectedFileIntact() async throws {
        try await DialogTurn.exclusive {
            let harness = try await PanelHarness.make { script in
                try await script.commit("base", ["a.txt": "base\n"])
                try script.write("a.txt", "keep modification\n")
                try script.write("new.txt", "keep addition\n")
            }
            defer { harness.close() }
            try await harness.showWorkingCopy()
            try SnapshotCommand.clickFile("ctrl+unstaged:a.txt", in: harness.workspace)
            try SnapshotCommand.clickFile("ctrl+unstaged:new.txt", in: harness.workspace)
            #expect(try harness.perform("wip.discardFile"))
            try await harness.waitUntil { Dialogs.current?.isVisible == true }
            Dialogs.current?.finish(.cancelled)
            try await harness.waitUntil { Dialogs.current == nil }
            await harness.controller.refreshNow(.status)
            #expect(try harness.script.read("a.txt") == "keep modification\n")
            #expect(try harness.script.read("new.txt") == "keep addition\n")
            #expect(harness.panel.selectedFiles.map(\.path) == ["a.txt", "new.txt"])
        }
    }

    @Test func refreshAndOpeningASelectedDiffPreserveSelectionByFileIdentity() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("base", ["b.txt": "base\n", "c.txt": "base\n"])
            try script.write("b.txt", "changed b\n")
            try script.write("c.txt", "changed c\n")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()
        try SnapshotCommand.clickFile("ctrl+unstaged:b.txt", in: harness.workspace)
        try SnapshotCommand.clickFile("ctrl+unstaged:c.txt", in: harness.workspace)
        harness.controller.showDiff(OpenDiff(target: .unstaged(path: "c.txt"), title: "c.txt"))
        #expect(harness.panel.selectedFiles.map(\.path) == ["b.txt", "c.txt"])
        try harness.script.write("a.txt", "new row before the selection\n")
        await harness.controller.refreshNow(.status)
        #expect(harness.panel.selectedFiles.map(\.path) == ["b.txt", "c.txt"])
        try await harness.script.git("add", "b.txt")
        await harness.controller.refreshNow(.status)
        #expect(harness.panel.selectedFiles.map(\.key) == [PanelFile.Key(section: .unstaged, path: "c.txt")])
    }
}

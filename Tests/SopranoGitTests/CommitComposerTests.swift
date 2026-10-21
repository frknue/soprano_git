import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
@Suite(.serialized)
struct CommitComposerTests {
    @Test func committingUsesSummaryAndDescriptionThenSelectsTheNewHead() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n"])
            try script.write("a.txt", "two\n")
            try await script.git("add", "a.txt")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()
        let composer = harness.panel.composer

        #expect(try !harness.isEnabled("wip.commit"))
        #expect(composer.hintText == "Write a summary to commit.")
        #expect(composer.commitButton.title == "Commit 1 file")

        composer.summary = "Change a"
        composer.descriptionText = "Explain why.\n"
        #expect(try harness.isEnabled("wip.commit", focus: .graph))
        #expect(composer.hintText == nil)
        #expect(composer.commitButton.isEnabled)

        #expect(try harness.perform("wip.commit", focus: .graph))
        try await harness.waitUntil { harness.controller.status.isClean && composer.summary.isEmpty }
        #expect(try await harness.script.output("log", "-1", "--format=%B") == "Change a\n\nExplain why.")
        #expect(composer.descriptionText.isEmpty)
        let head = try await harness.script.output("rev-parse", "HEAD")
        try await harness.waitUntil { harness.controller.selection == .commit(head) }
    }

    @Test func aCommitThatLeavesChangesKeepsTheWorkingCopySelected() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n", "b.txt": "one\n"])
            try script.write("a.txt", "two\n")
            try script.write("b.txt", "two\n")
            try await script.git("add", "a.txt")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()

        harness.panel.composer.summary = "Only a"
        #expect(await harness.panel.commit())
        #expect(harness.controller.selection == .workingCopy)
        #expect(harness.entry("b.txt")?.unstaged == .modified)
        #expect(try await harness.script.output("log", "-1", "--format=%s") == "Only a")
    }

    @Test func nothingStagedDisablesCommitUntilAmendIsOn() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n"])
            try script.write("b.txt", "b\n")
            try await script.git("add", "b.txt")
            try await script.git("commit", "-q", "-m", "second", "-m", "Body of second.")
            try script.write("a.txt", "two\n")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()
        let composer = harness.panel.composer
        composer.summary = "Typed"

        #expect(!harness.panel.composerState.canCommit)
        #expect(composer.hintText == "Stage files, or turn on Amend, to commit.")
        #expect(try harness.isEnabled("wip.stageAllAndCommit"))

        #expect(try harness.perform("wip.toggleAmend"))
        try await harness.waitUntil { composer.summary == "second" }
        #expect(composer.descriptionText == "Body of second.")
        #expect(composer.isAmending)
        #expect(composer.commitButton.title == "Amend commit")
        #expect(harness.panel.composerState.canCommit)

        let before = try await harness.script.output("rev-parse", "HEAD")
        let parent = try await harness.script.output("rev-parse", "HEAD~1")
        composer.summary = "second, reworded"
        #expect(await harness.panel.commit())
        let after = try await harness.script.output("rev-parse", "HEAD")
        #expect(after != before)
        #expect(try await harness.script.output("rev-parse", "HEAD~1") == parent)
        #expect(try await harness.script.output("log", "-1", "--format=%B") == "second, reworded\n\nBody of second.")
        #expect(!composer.isAmending)
        #expect(harness.entry("a.txt")?.unstaged == .modified)
    }

    @Test func turningAmendOffBringsTheDraftBack() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n"])
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()
        let composer = harness.panel.composer
        composer.summary = "draft"

        harness.panel.toggleAmend()
        try await harness.waitUntil { composer.summary == "first" }
        harness.panel.toggleAmend()
        #expect(composer.summary == "draft")
        #expect(!composer.isAmending)
    }

    @Test func aPausedMergePrefillsItsMessageAndCommitsTheMerge() async throws {
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
        let composer = harness.panel.composer

        try await harness.waitUntil { composer.summary == "Merge branch 'feature'" }
        #expect(!composer.descriptionText.contains("#"))
        #expect(!harness.panel.composerState.canCommit)
        #expect(composer.hintText == "Resolve conflicts before committing.")

        try harness.selectFile("c.txt", in: .conflicts)
        #expect(try harness.perform("conflict.takeOurs"))
        try await harness.waitUntil { harness.controller.status.conflicted.isEmpty }
        // Taking ours leaves nothing staged; the merge still commits.
        #expect(harness.controller.status.staged.isEmpty)
        #expect(composer.summary == "Merge branch 'feature'")
        #expect(composer.commitButton.title == "Commit merge")
        #expect(try harness.isEnabled("wip.commit"))
        #expect(await harness.panel.commit())
        #expect(try await harness.script.output("log", "-1", "--format=%p").split(separator: " ").count == 2)
        #expect(composer.summary.isEmpty)
    }

    @Test func aResolvedMergeCommitsFromTheComposerWithTwoParents() async throws {
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
        let composer = harness.panel.composer
        try await harness.waitUntil { composer.summary == "Merge branch 'feature'" }

        try harness.selectFile("c.txt", in: .conflicts)
        #expect(try harness.perform("conflict.takeTheirs"))
        try await harness.waitUntil { harness.controller.status.conflicted.isEmpty }
        #expect(try harness.isEnabled("wip.commit"))
        #expect(await harness.panel.commit())
        #expect(try await harness.script.output("log", "-1", "--format=%s") == "Merge branch 'feature'")
        #expect(try await harness.script.output("log", "-1", "--format=%p").split(separator: " ").count == 2)
        #expect(composer.summary.isEmpty)
    }

    @Test func stageAllAndCommitCommitsUntrackedAndModifiedFiles() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n"])
            try script.write("a.txt", "two\n")
            try script.write("new.txt", "new\n")
        }
        defer { harness.close() }
        try await harness.showWorkingCopy()
        harness.panel.composer.summary = "Everything"

        #expect(try harness.perform("wip.stageAllAndCommit", focus: .graph))
        try await harness.waitUntil { harness.controller.status.isClean }
        #expect(try await harness.script.output("show", "--name-only", "--format=", "HEAD") == "a.txt\nnew.txt")
    }

    @Test func composerStateExplainsEveryDisabledCase() {
        var state = ComposerState(stagedCount: 0, changeCount: 0, conflictCount: 0, isAmending: false, hasSummary: true, isBusy: false)
        #expect(!state.canCommit)
        #expect(state.hint == "Nothing to commit. Turn on Amend to reword HEAD.")
        state.isAmending = true
        #expect(state.canCommit)
        #expect(state.commitTitle == "Amend commit")
        state.hasSummary = false
        #expect(!state.canCommit)
        #expect(state.hint == "Write a summary to commit.")
        state = ComposerState(stagedCount: 2, changeCount: 3, conflictCount: 1, isAmending: false, hasSummary: true, isBusy: false)
        #expect(!state.canCommit && !state.canStageAllAndCommit)
        #expect(state.hint == "Resolve conflicts before committing.")
        state.conflictCount = 0
        #expect(state.canCommit && state.commitTitle == "Commit 2 files")
        state.isBusy = true
        #expect(!state.canCommit)
    }

    @Test func mergeMessagesLoseCommentLinesAndSplitIntoSummaryAndDescription() {
        let prepared = CommitMessage.preparedMessage("Merge branch 'x'\n\n# Conflicts:\n#\tc.txt\n")
        #expect(prepared == "Merge branch 'x'")
        let parts = CommitMessage.split("Title\n\n\nBody line\nmore\n")
        #expect(parts.summary == "Title")
        #expect(parts.description == "Body line\nmore")
        #expect(CommitMessage.join(summary: " Title ", description: "\n") == "Title")
    }

    @Test func theSummaryCounterWarnsPastSeventyTwoCharacters() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n"])
        }
        defer { harness.close() }
        let composer = harness.panel.composer
        composer.summary = String(repeating: "x", count: 72)
        #expect(composer.counterText == "72")
        #expect(!composer.isSummaryTooLong)
        composer.summary = String(repeating: "x", count: 73)
        #expect(composer.counterText == "73/72")
        #expect(composer.isSummaryTooLong)
    }

    @Test func theSummaryShowsItsFocusEdgeAsSoonAsItTakesFocus() {
        let composer = CommitComposerView(theme: .folioPaper)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [], backing: .buffered, defer: true)
        window.contentView = composer
        #expect(!composer.summaryBox.isFocused)
        #expect(window.makeFirstResponder(composer.summaryField))
        #expect(composer.summaryBox.isFocused)
        #expect(window.makeFirstResponder(nil))
        #expect(!composer.summaryBox.isFocused)
    }

    @Test func pressingTheAmendCheckboxReportsTheToggleOnlyWhenEnabled() {
        let composer = CommitComposerView(theme: .folioPaper)
        var toggles: [Bool] = []
        composer.onAmendToggled = { toggles.append($0) }

        #expect(composer.amendCheckbox.accessibilityPerformPress())
        #expect(toggles == [true])

        composer.isAmendEnabled = false
        #expect(!composer.amendCheckbox.accessibilityPerformPress())
        #expect(toggles == [true])
        #expect(composer.isAmending)
    }

    @Test func clickingTheAmendLabelReportsTheToggleOnlyWhenEnabled() throws {
        let composer = CommitComposerView(theme: .folioPaper)
        var toggles: [Bool] = []
        composer.onAmendToggled = { toggles.append($0) }
        let click = try #require(composer.amendLabel.gestureRecognizers.first as? NSClickGestureRecognizer)
        let target = try #require(click.target as? NSObject)
        let action = try #require(click.action)

        _ = target.perform(action, with: click)
        #expect(toggles == [true])
        #expect(composer.isAmending)

        composer.isAmendEnabled = false
        _ = target.perform(action, with: click)
        #expect(toggles == [true])
        #expect(composer.isAmending)
    }
}

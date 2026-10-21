import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct WorkspaceChromeTests {
    private func makeSettings(_ text: String = "{}") -> (SettingsCenter, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sg-chrome-\(UUID().uuidString)")
        let registry = CommandRegistry()
        AllCommands.registerAll(in: registry)
        let center = SettingsCenter(fileURL: directory.appendingPathComponent("settings.json"), registry: registry)
        center.apply(text: text)
        return (center, directory)
    }

    private func hint(_ caps: [String], _ label: String) -> HintsView.Hint {
        HintsView.Hint(caps: caps, label: label)
    }

    @Test func theBannerNamesTheOperationStepAndConflicts() {
        #expect(OperationBannerView.text(for: .merge(mergingHead: nil), conflicts: 2) == "Merge in progress · 2 conflicts")
        #expect(OperationBannerView.text(for: .cherryPick(commit: nil), conflicts: 1) == "Cherry-pick in progress · 1 conflict")
        #expect(
            OperationBannerView.text(for: .rebase(headName: "topic", onto: nil, step: 2, total: 5), conflicts: 0)
                == "Rebase in progress · step 2/5 · ready to continue"
        )
    }

    @Test func theBannerIsAnErrorWhileConflictsRemainAndNeedsInputOnceGitCanContinue() {
        #expect(OperationBannerView.status(conflicts: 2) == .error)
        #expect(OperationBannerView.status(conflicts: 0) == .needsInput)
    }

    @Test func theStatusBarSummarizesGitErrorsByTheirErrorLine() {
        let message = """
        To origin.git
         ! [rejected]        main -> main (fetch first)
        error: failed to push some refs to 'origin.git'
        """
        #expect(WorkspaceStatusBarView.summaryLine(of: message) == "failed to push some refs to 'origin.git'")
        #expect(WorkspaceStatusBarView.summaryLine(of: "fatal: not a git repository\n") == "not a git repository")
        #expect(WorkspaceStatusBarView.summaryLine(of: "\n  plain words  \n") == "plain words")
    }

    @Test func graphSidebarAndDetailShowTheGlobalHintsWithTheirShortestCaps() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = [hint(["⌘P"], "Commands"), hint(["⌃A"], "Prefix"), hint(["?"], "Shortcuts")]

        for region: FocusRegion? in [.graph, .sidebar, .detail, nil] {
            #expect(WorkspaceStatusBarView.hints(for: region, settings: settings) == expected)
        }
    }

    @Test func theFocusedDiffShowsItsNavigationHints() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(WorkspaceStatusBarView.hints(for: .diff, settings: settings) == [
            hint(["J", "K"], "change"),
            hint(["⇧J", "⇧K"], "file"),
            hint(["V"], "split"),
            hint(["esc"], "close"),
        ])
    }

    @Test func statusBarHintsFollowTheKeyBindings() {
        let (settings, directory) = makeSettings("""
        { "keybindings": { "prefixKey": "b", "bindings": { "palette.open": "cmd+shift+k", "diff.toggleLayout": null } } }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(Array(WorkspaceStatusBarView.hints(for: .graph, settings: settings).prefix(2)) == [
            hint(["⇧⌘K"], "Commands"),
            hint(["⌃B"], "Prefix"),
        ])
        #expect(!WorkspaceStatusBarView.hints(for: .diff, settings: settings).map(\.label).contains("split"))
    }

    @Test func theToolbarTogglesMirrorPanelVisibility() {
        let toolbar = WorkspaceToolbarView(theme: .folioPaper)

        toolbar.setPanelVisibility(sidebar: true, commitPanel: false)
        #expect(toolbar.sidebarToggle.isToggledOn == true)
        #expect(toolbar.commitPanelToggle.isToggledOn == false)

        toolbar.setPanelVisibility(sidebar: false, commitPanel: true)
        #expect(toolbar.sidebarToggle.isToggledOn == false)
        #expect(toolbar.commitPanelToggle.isToggledOn == true)
        #expect(toolbar.commandButtons.allSatisfy { $0.isToggledOn == nil })
    }

    @Test func hidingAPanelTurnsItsToolbarToggleOff() async throws {
        let harness = try await PanelHarness.make { script in
            try await script.commit("first", ["a.txt": "one\n"])
        }
        defer { harness.close() }
        let workspace = harness.workspace
        #expect(workspace.toolbar.sidebarToggle.isToggledOn == workspace.isSidebarVisible)

        workspace.isCommitPanelVisible = true
        #expect(workspace.toolbar.commitPanelToggle.isToggledOn == true)
        workspace.isCommitPanelVisible = false
        #expect(workspace.toolbar.commitPanelToggle.isToggledOn == false)
        workspace.isSidebarVisible = false
        #expect(workspace.toolbar.sidebarToggle.isToggledOn == false)
        workspace.isSidebarVisible = true
        #expect(workspace.toolbar.sidebarToggle.isToggledOn == true)
    }
}

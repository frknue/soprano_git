import AppKit
@testable import SopranoGit
@testable import SopranoGitCore

/// A real repository workspace (offscreen window, no file watching) over a
/// sandbox repository, for commit panel and diff view tests.
@MainActor
final class PanelHarness {
    let sandbox: GitSandbox
    let script: GitScript
    let window: NSWindow
    let workspace: RepoWorkspaceViewController

    var controller: RepositoryController { workspace.controller }
    var panel: CommitPanelViewController { workspace.commitPanel }
    var diff: DiffViewController { workspace.diff }

    private init(sandbox: GitSandbox, script: GitScript, state: AppStateStore) {
        self.sandbox = sandbox
        self.script = script
        DialogPanel.presentsAsSheet = false
        DialogPanel.activatesApp = false
        let controller = RepositoryController(repository: script.repository)
        controller.minimumRefreshInterval = .zero
        workspace = RepoWorkspaceViewController(controller: controller, state: state)
        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1400, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.layoutIfNeeded()
    }

    /// Builds the repository with `setup`, opens it and waits for the first
    /// load. `state` defaults to a throwaway store.
    static func make(state: AppStateStore = .volatile(), _ setup: (GitScript) async throws -> Void) async throws -> PanelHarness {
        let sandbox = try GitSandbox()
        let script = GitScript(try await sandbox.makeRepository(), sandbox: sandbox)
        try await setup(script)
        let harness = PanelHarness(sandbox: sandbox, script: script, state: state)
        harness.controller.start(watching: false)
        harness.workspace.didAttach(to: harness.window)
        try await harness.waitUntil { harness.controller.hasLoaded }
        return harness
    }

    func close() {
        workspace.close()
        window.close()
        sandbox.remove()
    }

    func waitUntil(_ timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw HarnessError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    enum HarnessError: Error {
        case timedOut
        case unknownCommand(String)
    }

    func context(focus: FocusRegion?) -> CommandContext {
        CommandContext(window: window, workspace: workspace, focus: focus, isTextInput: false)
    }

    func command(_ id: String) throws -> AppCommand {
        guard let command = (CommitPanelCommands.all + DiffCommands.all).first(where: { $0.id == id }) else {
            throw HarnessError.unknownCommand(id)
        }
        return command
    }

    func isEnabled(_ id: String, focus: FocusRegion? = .detail) throws -> Bool {
        try command(id).isEnabled(context(focus: focus))
    }

    /// Runs a command the way the router does: only when enabled. Returns whether it ran.
    @discardableResult
    func perform(_ id: String, focus: FocusRegion? = .detail) throws -> Bool {
        let command = try command(id)
        let context = context(focus: focus)
        guard command.isEnabled(context) else { return false }
        command.perform(context)
        return true
    }

    /// Selects the working copy and waits until its rows show.
    func showWorkingCopy() async throws {
        controller.select(.workingCopy)
        try await waitUntil { panel.mode == .workingCopy }
    }

    /// Selects the panel row of `path` in `section`.
    func selectFile(_ path: String, in section: PanelSection) throws {
        guard let row = panel.rows.firstIndex(where: { $0.file?.path == path && $0.file?.section == section }) else {
            throw HarnessError.unknownCommand("no row \(path)")
        }
        panel.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Confirms the dialog that is (or is about to be) on screen.
    func confirmDialog() async throws {
        try await waitUntil { Dialogs.current?.isVisible == true }
        Dialogs.current?.confirm()
    }

    func entry(_ path: String) -> StatusEntry? {
        controller.status.entries.first { $0.path == path }
    }
}

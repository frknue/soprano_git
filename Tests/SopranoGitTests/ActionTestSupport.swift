import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

/// A workspace without a window: dialogs open as standalone panels, focus
/// requests are recorded.
@MainActor
final class TestWorkspace: RepoWorkspace {
    let controller: RepositoryController
    var window: NSWindow? { nil }
    lazy var sidebar = RefSidebarViewController(controller: controller)
    lazy var graph = CommitGraphViewController(controller: controller)
    lazy var commitPanel = CommitPanelViewController(controller: controller)
    lazy var diff = DiffViewController(controller: controller)
    private(set) var focusedRegion: FocusRegion?
    var isSidebarVisible = true
    var isCommitPanelVisible = true

    init(controller: RepositoryController) {
        self.controller = controller
    }

    func focus(_ region: FocusRegion) {
        focusedRegion = region
    }

    func addFocusObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (FocusRegion?) -> Void) {}

    /// What the focused area reports as its selection (see `context(focus:)`).
    var providedTarget: SelectionTarget?
    private lazy var provider = StubProvider(workspace: self)

    func selectionProvider(for region: FocusRegion) -> SelectionTargetProvider? { provider }

    /// A command context focused on `focus` whose target is `target`.
    func context(_ target: SelectionTarget?, focus: FocusRegion = .graph) -> CommandContext {
        providedTarget = target
        return CommandContext(window: nil, workspace: self, focus: focus, isTextInput: false)
    }

    private final class StubProvider: SelectionTargetProvider {
        weak var workspace: TestWorkspace?
        init(workspace: TestWorkspace) { self.workspace = workspace }
        var selectionTarget: SelectionTarget? { workspace?.providedTarget }
    }
}

/// A sandbox repository (optionally cloned from a bare `origin.git`) opened
/// in a started controller and a test workspace.
@MainActor
struct ActionFixture {
    let sandbox: GitSandbox
    let script: GitScript
    let workspace: TestWorkspace
    var controller: RepositoryController { workspace.controller }
    var repository: Repository { script.repository }

    /// `main` with one commit ("Base", a.txt) pushed to `origin` when `remote`.
    static func make(remote: Bool = false) async throws -> ActionFixture {
        let sandbox = try GitSandbox()
        let repository = try await sandbox.makeRepository()
        let script = GitScript(repository, sandbox: sandbox)
        try await script.commit("Base", ["a.txt": "a\n"])
        if remote {
            let origin = sandbox.url("origin.git")
            try await sandbox.runner.run(["init", "-q", "--bare", origin.path], in: sandbox.directory)
            try await script.git("remote", "add", "origin", origin.path)
            try await script.git("push", "-q", "-u", "origin", "main")
        }
        let controller = RepositoryController(repository: repository)
        controller.start(watching: false)
        let fixture = ActionFixture(sandbox: sandbox, script: script, workspace: TestWorkspace(controller: controller))
        try await fixture.waitUntil { controller.hasLoaded }
        return fixture
    }

    /// Re-reads everything after the script changed the repository.
    func reload() async {
        await controller.refreshNow(.all)
    }

    func waitUntil(_ timeout: Double = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func branch(_ name: String) throws -> Branch {
        try #require(controller.refs.localBranches.first { $0.name == name } ?? controller.refs.remoteBranches.first { $0.name == name })
    }

    func tag(_ name: String) throws -> SopranoGitCore.Tag {
        try #require(controller.refs.tags.first { $0.name == name })
    }

    func output(_ arguments: String...) async throws -> String {
        try await sandbox.runner.run(arguments, in: script.root).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short names of local branches, sorted.
    var localBranchNames: [String] { controller.refs.localBranches.map(\.name).sorted() }

    /// The latest activity entry for `title`.
    func activity(_ title: String) -> ActivityLog.Entry? {
        controller.activity.entries.last { $0.title == title }
    }

    func remove() {
        sandbox.remove()
    }
}

enum FlowError: Error {
    case finishedWithoutDialog
    case noDialog
    case stillRunning
}

/// Runs a flow and hands out its dialogs one at a time.
@MainActor
final class FlowRun {
    private(set) var isDone = false
    private weak var lastDialog: DialogPanel?

    init(_ flow: @escaping @MainActor () async -> Void) {
        DialogPanel.presentsAsSheet = false
        DialogPanel.activatesApp = false
        _ = NSApplication.shared
        Task { @MainActor in
            await flow()
            self.isDone = true
        }
    }

    /// The next dialog the flow shows.
    func dialog(timeout: Double = 30) async throws -> DialogPanel {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let dialog = Dialogs.current, dialog !== lastDialog {
                lastDialog = dialog
                return dialog
            }
            if isDone { throw FlowError.finishedWithoutDialog }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FlowError.noDialog
    }

    /// Waits for the flow to end (it must not show another dialog).
    func finish(timeout: Double = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !isDone {
            if let dialog = Dialogs.current, dialog !== lastDialog {
                Issue.record("Unexpected dialog: \(dialog.spec.title)")
                dialog.finish(.cancelled)
            }
            guard Date() < deadline else { throw FlowError.stillRunning }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

extension DialogPanel {
    var optionTitles: [String] {
        guard case let .choose(options) = spec.kind else { return [] }
        return options.map(\.title)
    }

    var options: [DialogOption] {
        guard case let .choose(options) = spec.kind else { return [] }
        return options
    }

    /// The prompt's inline validation for `value`.
    func validation(of value: String) -> String? {
        guard case let .prompt(_, _, _, validate) = spec.kind else { return nil }
        return validate?(value)
    }

    func choose(_ index: Int) {
        selectOption(index)
        confirm()
    }

    func enter(_ value: String) {
        setValue(value)
        confirm()
    }
}

/// Dialog tests share `Dialogs.current`; they take turns.
@MainActor
enum DialogTurn {
    private static var busy = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func exclusive(_ body: @MainActor () async throws -> Void) async throws {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        try await body()
    }
}

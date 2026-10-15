import AppKit
import SopranoGitCore

/// Right panel: details and changed files of the selected commit or stash, or the
/// working copy's unstaged/staged/conflicted files and the commit composer.
/// Owned by the Commit Panel module (Wave B).
@MainActor
final class CommitPanelViewController: NSViewController, FocusRegionController, SelectionTargetProvider {
    let controller: RepositoryController
    /// Set by the workspace right after creating the controller.
    weak var workspace: (any RepoWorkspace)?

    init(controller: RepositoryController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView()
    }

    var focusRegion: FocusRegion { .detail }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(view)
    }

    var selectionTarget: SelectionTarget? { nil }
}

@MainActor
enum CommitPanelCommands {
    static var all: [AppCommand] { [] }
}

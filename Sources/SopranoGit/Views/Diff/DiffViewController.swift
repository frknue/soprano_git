import AppKit
import SopranoGitCore

/// Center area while `controller.openDiff` is set: the file's hunks with line
/// numbers and hunk staging. Owned by the Commit Panel module (Wave B).
@MainActor
final class DiffViewController: NSViewController, FocusRegionController {
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

    var focusRegion: FocusRegion { .diff }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(view)
    }
}

@MainActor
enum DiffCommands {
    static var all: [AppCommand] { [] }
}

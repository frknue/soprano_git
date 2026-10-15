import AppKit
import SopranoGitCore

/// Center area: the commit graph (refs column, lanes, message, author, date, id), with the
/// working-copy row on top and stashes inline. Owned by the Graph module (Wave B).
@MainActor
final class CommitGraphViewController: NSViewController, FocusRegionController, SelectionTargetProvider {
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

    var focusRegion: FocusRegion { .graph }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(view)
    }

    var selectionTarget: SelectionTarget? { nil }
}

@MainActor
enum GraphCommands {
    static var all: [AppCommand] { [] }
}

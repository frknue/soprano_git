import AppKit
import SopranoGitCore

/// Left panel: local branches, remotes, tags and stashes, with a filter. Owned by the
/// Sidebar module (Wave B).
@MainActor
final class RefSidebarViewController: NSViewController, FocusRegionController, SelectionTargetProvider {
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

    var focusRegion: FocusRegion { .sidebar }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(view)
    }

    var selectionTarget: SelectionTarget? { nil }
}

@MainActor
enum SidebarCommands {
    static var all: [AppCommand] { [] }
}

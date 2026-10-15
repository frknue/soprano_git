import AppKit
import SopranoGitCore

/// One open repository tab: toolbar, left panel (refs), center (graph, or a
/// diff while one is open), commit panel, status bar. Implemented by the
/// shell's `RepoWorkspaceViewController`; region modules talk to each other
/// only through this and the shared `RepositoryController`.
@MainActor
protocol RepoWorkspace: AnyObject {
    var controller: RepositoryController { get }
    var window: NSWindow? { get }

    var sidebar: RefSidebarViewController { get }
    var graph: CommitGraphViewController { get }
    var commitPanel: CommitPanelViewController { get }
    var diff: DiffViewController { get }

    /// Area holding keyboard focus; nil when focus is outside the regions.
    var focusedRegion: FocusRegion? { get }
    /// Moves keyboard focus into an area, showing its panel if hidden.
    func focus(_ region: FocusRegion)
    /// Handlers fire whenever the focused area changes (region headers
    /// highlight with it), until `owner` is deallocated.
    func addFocusObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (FocusRegion?) -> Void)

    var isSidebarVisible: Bool { get set }
    var isCommitPanelVisible: Bool { get set }

    /// The area's selection provider (sidebar, graph, commit panel), if any.
    func selectionProvider(for region: FocusRegion) -> SelectionTargetProvider?
}

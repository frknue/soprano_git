import AppKit
import SopranoGitCore

/// One open repository tab: toolbar, one hairline, sidebar | center (banner +
/// graph or diff) | commit panel, status bar, and the error toast.
@MainActor
final class RepoWorkspaceViewController: NSViewController, RepoWorkspace, NSSplitViewDelegate {
    enum Layout {
        static let sidebarWidth: CGFloat = 240
        static let sidebarRange: ClosedRange<CGFloat> = 180...420
        static let commitPanelWidth: CGFloat = 380
        static let commitPanelRange: ClosedRange<CGFloat> = 300...600
        static let minimumCenterWidth: CGFloat = 320
    }

    let controller: RepositoryController
    let sidebar: RefSidebarViewController
    let graph: CommitGraphViewController
    let commitPanel: CommitPanelViewController
    let diff: DiffViewController

    /// Runs a command id in this workspace's window context (set by the window controller).
    var performCommand: ((String) -> Void)?
    /// The command context of the window (set by the window controller).
    var commandContext: (() -> CommandContext?)?

    private let state: AppStateStore
    private var theme: AppTheme
    let toolbar: WorkspaceToolbarView
    private let toolbarRule = ChromeRuleView(axis: .horizontal)
    private let splitView = WorkspaceSplitView()
    private let sidebarContainer = NSView()
    private let centerContainer = NSView()
    private let commitContainer = NSView()
    private let banner: OperationBannerView
    private let centerHost = NSView()
    let statusBar: WorkspaceStatusBarView
    private let toast: ErrorToastView
    private var bannerHeight: NSLayoutConstraint!
    private var didApplyInitialWidths = false
    private var showsDiff = false
    private var firstResponderObservation: NSKeyValueObservation?
    private var lastFocusedRegion: FocusRegion?
    private let focusObservers = ObserverList<FocusRegion?>()

    init(controller: RepositoryController, state: AppStateStore) {
        self.controller = controller
        self.state = state
        self.theme = ThemeCenter.shared.theme
        sidebar = RefSidebarViewController(controller: controller)
        graph = CommitGraphViewController(controller: controller)
        commitPanel = CommitPanelViewController(controller: controller)
        diff = DiffViewController(controller: controller)
        toolbar = WorkspaceToolbarView(theme: theme)
        banner = OperationBannerView(theme: theme)
        statusBar = WorkspaceStatusBarView(theme: theme)
        toast = ErrorToastView(theme: theme)
        super.init(nibName: nil, bundle: nil)
        sidebar.workspace = self
        sidebar.stateDefaults = state.defaults
        graph.workspace = self
        commitPanel.workspace = self
        graph.defaults = state.defaults
        diff.workspace = self
        diff.state = state
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var window: NSWindow? { viewIfLoaded?.window }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        for child in [sidebar, graph, commitPanel, diff] as [NSViewController] {
            addChild(child)
        }
        embed(sidebar.view, in: sidebarContainer)
        embed(commitPanel.view, in: commitContainer)
        embed(graph.view, in: centerHost)

        for view in [banner, centerHost] {
            view.translatesAutoresizingMaskIntoConstraints = false
            centerContainer.addSubview(view)
        }
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: centerContainer.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: centerContainer.trailingAnchor),
            banner.topAnchor.constraint(equalTo: centerContainer.topAnchor),
            bannerHeight,
            centerHost.leadingAnchor.constraint(equalTo: centerContainer.leadingAnchor),
            centerHost.trailingAnchor.constraint(equalTo: centerContainer.trailingAnchor),
            centerHost.topAnchor.constraint(equalTo: banner.bottomAnchor),
            centerHost.bottomAnchor.constraint(equalTo: centerContainer.bottomAnchor),
        ])
        banner.isHidden = true

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(sidebarContainer)
        splitView.addArrangedSubview(centerContainer)
        splitView.addArrangedSubview(commitContainer)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 2)
        sidebarContainer.isHidden = !state.bool(forKey: AppStateStore.Key.sidebarVisible, default: true)
        commitContainer.isHidden = !state.bool(forKey: AppStateStore.Key.commitPanelVisible, default: true)

        toast.isHidden = true
        toast.onDismiss = { [weak self] in self?.refreshChrome() }

        for view in [toolbar, toolbarRule, splitView, statusBar, toast] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: WorkspaceToolbarView.height),
            toolbarRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarRule.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: toolbarRule.bottomAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: WorkspaceStatusBarView.height),
            toast.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            toast.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -16),
        ])

        toolbar.onPerform = { [weak self] id in self?.performCommand?(id) }
        banner.onPerform = { [weak self] id in self?.performCommand?(id) }

        view = root
        applyTheme()

        controller.addObserver(self) { [weak self] event in
            self?.handle(event)
        }
        ThemeCenter.shared.addObserver(self) { [weak self] theme in
            self?.theme = theme
            self?.applyTheme()
        }
        SettingsCenter.shared.addObserver(self) { [weak self] in
            self?.refreshChrome()
        }
        refreshChrome()
    }

    private func embed(_ child: NSView, in container: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialWidthsIfNeeded()
    }

    private func applyInitialWidthsIfNeeded() {
        guard !didApplyInitialWidths, splitView.bounds.width > 0 else { return }
        didApplyInitialWidths = true
        applyPanelWidths()
    }

    private func applyPanelWidths() {
        let total = splitView.bounds.width
        let divider = splitView.dividerThickness
        let sidebarWidth = state.width(forKey: AppStateStore.Key.sidebarWidth, default: Layout.sidebarWidth, range: Layout.sidebarRange)
        let commitWidth = state.width(forKey: AppStateStore.Key.commitPanelWidth, default: Layout.commitPanelWidth, range: Layout.commitPanelRange)
        if !sidebarContainer.isHidden {
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        }
        if !commitContainer.isHidden {
            splitView.setPosition(total - commitWidth - divider, ofDividerAt: 1)
        }
        splitView.adjustSubviews()
    }

    private func applyTheme() {
        let colors = theme.colors
        view.layer?.backgroundColor = colors.bgBase.cgColor
        toolbarRule.color = colors.borderSubtle
        splitView.dividerTint = colors.borderSubtle
        splitView.needsDisplay = true
        // Side panels sit on bgPanel, the graph and diff on bgBase.
        for container in [sidebarContainer, commitContainer] {
            container.wantsLayer = true
            container.layer?.backgroundColor = colors.bgPanel.cgColor
        }
        for container in [centerContainer, centerHost] {
            container.wantsLayer = true
            container.layer?.backgroundColor = colors.bgBase.cgColor
        }
        toolbar.apply(theme: theme)
        banner.apply(theme: theme)
        statusBar.apply(theme: theme)
        toast.apply(theme: theme)
        refreshChrome()
    }

    // MARK: - Lifecycle

    /// Called once the view sits in its window: watches the first responder
    /// for focus changes and starts the controller.
    func didAttach(to window: NSWindow) {
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.focusMaybeChanged()
            }
        }
        controller.start()
        focusMaybeChanged()
    }

    func willDetach() {
        firstResponderObservation = nil
    }

    func close() {
        firstResponderObservation = nil
        controller.stop()
        toast.dismiss()
    }

    // MARK: - Events

    private func handle(_ event: RepositoryController.Event) {
        switch event {
        case .openDiff:
            updateCenter()
        case let .failed(title, message):
            toast.show(title: title, message: message, theme: theme)
            refreshChrome()
        default:
            refreshChrome()
        }
    }

    private func updateCenter() {
        let wantsDiff = controller.openDiff != nil
        guard wantsDiff != showsDiff else { return }
        let hadFocus = focusedRegion == (showsDiff ? .diff : .graph)
        showsDiff = wantsDiff
        centerHost.subviews.forEach { $0.removeFromSuperview() }
        embed(wantsDiff ? diff.view : graph.view, in: centerHost)
        if wantsDiff || hadFocus {
            (wantsDiff ? diff as FocusRegionController : graph).takeFocus()
        }
        focusMaybeChanged()
    }

    /// Re-reads toolbar, banner and status bar from the controller; the status
    /// bar's hints follow the focused region.
    func refreshChrome() {
        guard isViewLoaded else { return }
        let context = commandContext?()
        toolbar.update(repoName: controller.displayName, refs: controller.refs, context: context)
        toolbar.setPanelVisibility(sidebar: isSidebarVisible, commitPanel: isCommitPanelVisible)
        if let operation = controller.status.operation {
            banner.isHidden = false
            bannerHeight.constant = OperationBannerView.height
            banner.update(operation: operation, conflicts: controller.status.conflicted.count, context: context)
        } else {
            banner.isHidden = true
            bannerHeight.constant = 0
        }
        statusBar.update(
            activity: controller.activity.latest,
            refs: controller.refs,
            commitCount: controller.commits.count,
            hasMore: controller.hasMoreCommits,
            loading: !controller.hasLoaded,
            loadError: controller.loadError,
            focus: lastFocusedRegion
        )
    }

    func setKeyboardMode(_ mode: KeyboardRouter.State) {
        statusBar.setMode(mode)
    }

    var isToastVisible: Bool { !toast.isHidden }

    func dismissToast() {
        toast.dismiss()
    }

    // MARK: - Focus

    private var regions: [FocusRegionController] {
        var result: [FocusRegionController] = []
        if !sidebarContainer.isHidden { result.append(sidebar) }
        result.append(showsDiff ? diff : graph)
        if !commitContainer.isHidden { result.append(commitPanel) }
        return result
    }

    var focusedRegion: FocusRegion? {
        guard let window, let view = Self.responderView(window.firstResponder) else { return nil }
        for region in regions where view === region.focusRootView || view.isDescendant(of: region.focusRootView) {
            return region.focusRegion
        }
        return nil
    }

    /// The view standing for a responder (a field editor stands for its field).
    static func responderView(_ responder: NSResponder?) -> NSView? {
        if let textView = responder as? NSTextView, textView.isFieldEditor, let field = textView.delegate as? NSView {
            return field
        }
        return responder as? NSView
    }

    func focus(_ region: FocusRegion) {
        switch region {
        case .sidebar:
            if !isSidebarVisible { isSidebarVisible = true }
            sidebar.takeFocus()
        case .detail:
            if !isCommitPanelVisible { isCommitPanelVisible = true }
            commitPanel.takeFocus()
        case .graph:
            if showsDiff {
                controller.showDiff(nil)
            }
            graph.takeFocus()
        case .diff:
            if showsDiff { diff.takeFocus() }
        case .welcome, .settings:
            break
        }
        focusMaybeChanged()
    }

    /// Moves focus to the visible region left (-1) or right (+1) of the focused one.
    func moveFocus(by delta: Int) {
        let order: [FocusRegion] = [.sidebar, showsDiff ? .diff : .graph, .detail]
        let current = focusedRegion.flatMap { order.firstIndex(of: $0) } ?? 1
        let next = current + delta
        guard order.indices.contains(next) else { return }
        focus(order[next])
    }

    /// Handlers fire when the focused region changes (headers highlight with it).
    func addFocusObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (FocusRegion?) -> Void) {
        focusObservers.add(owner, handler)
    }

    private func focusMaybeChanged() {
        let region = focusedRegion
        guard region != lastFocusedRegion else { return }
        lastFocusedRegion = region
        focusObservers.notify(region)
        refreshChrome()
    }

    // MARK: - Panels

    var isSidebarVisible: Bool {
        get { !sidebarContainer.isHidden }
        set { setPanel(sidebarContainer, visible: newValue, key: AppStateStore.Key.sidebarVisible) }
    }

    var isCommitPanelVisible: Bool {
        get { !commitContainer.isHidden }
        set { setPanel(commitContainer, visible: newValue, key: AppStateStore.Key.commitPanelVisible) }
    }

    private func setPanel(_ container: NSView, visible: Bool, key: String) {
        guard container.isHidden == visible else { return }
        let hadFocus = focusedRegion
        container.isHidden = !visible
        state.setBool(visible, forKey: key)
        toolbar.setPanelVisibility(sidebar: isSidebarVisible, commitPanel: isCommitPanelVisible)
        splitView.adjustSubviews()
        if didApplyInitialWidths { applyPanelWidths() }
        if !visible, hadFocus == (container === sidebarContainer ? .sidebar : .detail) {
            focus(showsDiff ? .diff : .graph)
        }
        focusMaybeChanged()
    }

    func selectionProvider(for region: FocusRegion) -> SelectionTargetProvider? {
        switch region {
        case .sidebar: sidebar
        case .graph: graph
        case .detail: commitPanel
        case .diff, .welcome, .settings: nil
        }
    }

    // MARK: - Split view

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 { return Layout.sidebarRange.lowerBound }
        return max(proposedMinimumPosition, splitView.bounds.width - Layout.commitPanelRange.upperBound - splitView.dividerThickness)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 { return Layout.sidebarRange.upperBound }
        return min(proposedMaximumPosition, splitView.bounds.width - Layout.commitPanelRange.lowerBound - splitView.dividerThickness)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only user drags carry a divider index; window resizes keep the stored widths.
        guard didApplyInitialWidths, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        if !sidebarContainer.isHidden {
            state.setWidth(sidebarContainer.frame.width, forKey: AppStateStore.Key.sidebarWidth)
        }
        if !commitContainer.isHidden {
            state.setWidth(commitContainer.frame.width, forKey: AppStateStore.Key.commitPanelWidth)
        }
    }
}

/// Split view with a single hairline divider in the theme's `borderSubtle`.
final class WorkspaceSplitView: NSSplitView {
    var dividerTint: NSColor = .separatorColor

    override var dividerColor: NSColor { dividerTint }
    override var dividerThickness: CGFloat { Chrome.hairline }
}

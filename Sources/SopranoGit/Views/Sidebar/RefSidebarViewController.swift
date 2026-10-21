import AppKit
import SopranoGitCore

/// Left panel: local branches, remotes, tags and stashes, with a filter (a
/// `SearchField` in an 8 10 6 strip). Owned by the
/// Sidebar module (Wave B).
@MainActor
final class RefSidebarViewController: NSViewController, FocusRegionController, SelectionTargetProvider,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate
{
    static let rowHeight: CGFloat = SidebarCellView.contentHeight
    /// Section rows carry their top margin: 8 pt, 2 pt for the first.
    static let sectionMargin: CGFloat = 8
    static let firstSectionMargin: CGFloat = 2

    let controller: RepositoryController
    /// Set by the workspace right after creating the controller.
    weak var workspace: (any RepoWorkspace)? {
        didSet { observeFocus() }
    }

    /// Where expanded groups persist (the workspace passes its state store's suite).
    var stateDefaults: UserDefaults = .standard {
        didSet { expansion = SidebarExpansionStore(defaults: stateDefaults, repositoryRoot: controller.repository.root) }
    }

    private(set) var expansion: SidebarExpansionStore
    private var theme: AppTheme
    private(set) var roots: [SidebarNode] = []
    private(set) var filterText = ""
    /// Identity of the selected row, kept across rebuilds.
    private(set) var selectedID: String?
    private var didRevealHead = false
    /// Set while the outline is changed programmatically, so restoring rows
    /// neither re-selects in the graph nor persists expansion.
    private var isRestoring = false

    private let header: PanelHeaderView
    private let searchField: SearchField
    private let searchStrip = NSView()
    let outlineView = ListOutlineView()
    private var scrollView: NSScrollView!

    init(controller: RepositoryController) {
        self.controller = controller
        self.theme = ThemeCenter.shared.theme
        self.expansion = SidebarExpansionStore(defaults: .standard, repositoryRoot: controller.repository.root)
        header = PanelHeaderView(title: "Refs", theme: ThemeCenter.shared.theme)
        searchField = SearchField(placeholder: "Filter", theme: ThemeCenter.shared.theme, hint: "/")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ref"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        // Cells indent themselves and draw their own chevrons.
        outlineView.indentationPerLevel = 0
        outlineView.indentationMarkerFollowsCell = true
        outlineView.autoresizesOutlineColumn = false
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        ListStyle.apply(to: outlineView, theme: theme, rowHeight: Self.rowHeight)
        scrollView = ListStyle.makeScrollView(documentView: outlineView, theme: theme)

        searchField.field.delegate = self
        searchStrip.wantsLayer = true
        for view in [header, searchStrip, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchStrip.addSubview(searchField)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: PanelHeaderView.height),
            searchStrip.topAnchor.constraint(equalTo: header.bottomAnchor),
            searchStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: searchStrip.topAnchor, constant: 8),
            searchField.bottomAnchor.constraint(equalTo: searchStrip.bottomAnchor, constant: -6),
            searchField.leadingAnchor.constraint(equalTo: searchStrip.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: searchStrip.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchStrip.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        applyTheme()
        rebuild()

        controller.addObserver(self) { [weak self] event in
            switch event {
            case .refs, .stashes: self?.rebuild()
            default: break
            }
        }
        ThemeCenter.shared.addObserver(self) { [weak self] theme in
            self?.theme = theme
            self?.applyTheme()
        }
        observeFocus()
    }

    private func observeFocus() {
        guard isViewLoaded, let workspace else { return }
        workspace.addFocusObserver(self) { [weak self] region in
            self?.header.isFocused = region == .sidebar
        }
        header.isFocused = workspace.focusedRegion == .sidebar
    }

    private func applyTheme() {
        let colors = theme.colors
        view.layer?.backgroundColor = colors.bgPanel.cgColor
        searchStrip.layer?.backgroundColor = colors.bgPanel.cgColor
        header.apply(theme: theme)
        searchField.apply(theme: theme)
        ListStyle.apply(to: outlineView, theme: theme, rowHeight: Self.rowHeight)
        ListStyle.applyScrollView(scrollView, theme: theme)
        reloadPreservingState()
    }

    // MARK: - FocusRegionController

    var focusRegion: FocusRegion { .sidebar }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(outlineView)
    }

    var selectionTarget: SelectionTarget? { selectedNode?.selectionTarget }

    var selectedNode: SidebarNode? {
        let row = outlineView.selectedRow
        return row >= 0 ? outlineView.item(atRow: row) as? SidebarNode : nil
    }

    // MARK: - Tree

    /// Rebuilds from the controller's refs and stashes, keeping expansion and
    /// the selected ref (by identity).
    func rebuild() {
        roots = SidebarTree.build(refs: controller.refs, stashes: controller.stashes, filter: filterText)
        if !didRevealHead, let head = controller.refs.currentBranch {
            didRevealHead = true
            for id in SidebarTree.ancestorIDs(of: head) { expansion.set(id, expanded: true) }
        }
        reloadPreservingState()
    }

    private func reloadPreservingState() {
        guard isViewLoaded else { return }
        isRestoring = true
        defer { isRestoring = false }
        outlineView.reloadData()
        restoreExpansion(roots)
        if let selectedID, let row = row(forID: selectedID) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            outlineView.deselectAll(nil)
            selectedID = nil
        }
    }

    private func restoreExpansion(_ nodes: [SidebarNode]) {
        for node in nodes where node.isGroup {
            if !filterText.isEmpty || expansion.isExpanded(node) {
                outlineView.expandItem(node)
                restoreExpansion(node.children)
            } else {
                outlineView.collapseItem(node)
            }
        }
    }

    func row(forID id: String) -> Int? {
        (0..<outlineView.numberOfRows).first { (outlineView.item(atRow: $0) as? SidebarNode)?.id == id }
    }

    /// Ids of the visible rows, top to bottom.
    var visibleRowIDs: [String] {
        (0..<outlineView.numberOfRows).compactMap { (outlineView.item(atRow: $0) as? SidebarNode)?.id }
    }

    /// Selects the row with `id` (as a click would) and reports whether it is visible.
    @discardableResult
    func selectRow(id: String) -> Bool {
        guard let row = row(forID: id) else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        return true
    }

    // MARK: - Filter

    func setFilter(_ text: String) {
        if searchField.field.stringValue != text { searchField.field.stringValue = text }
        guard text != filterText else { return }
        filterText = text
        rebuild()
    }

    /// `sidebar.filter`: shows the panel and puts the cursor in the filter.
    func beginFilter() {
        workspace?.focus(.sidebar)
        view.window?.makeFirstResponder(searchField.field)
        searchField.field.currentEditor()?.selectAll(nil)
    }

    var isFilterEditing: Bool {
        guard let editor = searchField.field.currentEditor() else { return false }
        return view.window?.firstResponder === editor
    }

    func controlTextDidChange(_ notification: Notification) {
        setFilter(searchField.field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            setFilter("")
            takeFocus()
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            takeFocus()
            if outlineView.selectedRow < 0 { moveSelection(by: 1) }
            return true
        default:
            return false
        }
    }

    // MARK: - Keyboard (sidebar.* commands)

    func moveSelection(by delta: Int) {
        let count = outlineView.numberOfRows
        guard count > 0 else { return }
        let current = outlineView.selectedRow
        let start = current < 0 ? (delta > 0 ? -1 : count) : current
        let next = min(max(0, start + delta), count - 1)
        outlineView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        outlineView.scrollRowToVisible(next)
    }

    /// Expands or collapses the selected group (`sidebar.toggle`).
    func toggleSelected() {
        guard let node = selectedNode else { return }
        toggle(node)
    }

    /// Expands or collapses `node` (chevron click, `sidebar.toggle`).
    func toggle(_ node: SidebarNode) {
        guard node.isGroup else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    /// Enter / double-click on the selected row (`sidebar.activate`).
    func activateSelected() {
        guard let node = selectedNode else { return }
        switch SidebarActivation.of(node) {
        case let .checkout(branch):
            guard let workspace else { return }
            Task { await GitActions.checkout(.branch(branch), in: workspace) }
        case let .revealCommit(id):
            controller.select(.commit(id))
            workspace?.focus(.graph)
        case let .revealStash(index):
            controller.select(.stash(index))
            workspace?.focus(.detail)
        case .toggle:
            toggleSelected()
        }
    }

    @objc private func rowDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        activateSelected()
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode,
              let target = node.selectionTarget, let workspace
        else { return }
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let source = GitActions.contextMenu(for: target, in: workspace)
        let items = source.items
        source.removeAllItems()
        items.forEach(menu.addItem)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.isGroup ?? false
    }

    // MARK: - NSOutlineViewDelegate

    /// Section rows carry their top margin inside the row; their pill and tick align
    /// to the bottom `rowHeight` points, where the eyebrow sits.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = self.outlineView.makeListRowView(row: outlineView.row(forItem: item))
        if let node = item as? SidebarNode, case .section = node.kind { rowView.contentHeight = Self.rowHeight }
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarNode, case .section = node.kind else { return Self.rowHeight }
        let isFirst = roots.first === node
        return Self.rowHeight + (isFirst ? Self.firstSectionMargin : Self.sectionMargin)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: SidebarCellView.identifier, owner: self) as? SidebarCellView
            ?? SidebarCellView()
        cell.configure(node, level: outlineView.level(forItem: node), isExpanded: outlineView.isItemExpanded(node), theme: theme)
        cell.onToggle = { [weak self, weak node] in
            guard let self, let node else { return }
            self.toggle(node)
        }
        return cell
    }

    /// Turns the chevron of `node`'s visible cell.
    private func updateDisclosure(of node: SidebarNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView
        else { return }
        cell.setExpanded(outlineView.isItemExpanded(node))
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoring else { return }
        let node = selectedNode
        selectedID = node?.id
        switch node?.kind {
        case let .branch(branch): controller.select(.commit(branch.target))
        case let .tag(tag): controller.select(.commit(tag.target))
        case let .stash(stash): controller.select(.stash(stash.index))
        default: break
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        persistExpansion(notification, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        persistExpansion(notification, expanded: false)
    }

    private func persistExpansion(_ notification: Notification, expanded: Bool) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        updateDisclosure(of: node)
        guard !isRestoring, filterText.isEmpty else { return }
        expansion.set(node.id, expanded: expanded)
        if expanded {
            // Children keep their own remembered state.
            isRestoring = true
            restoreExpansion(node.children)
            isRestoring = false
        }
    }
}

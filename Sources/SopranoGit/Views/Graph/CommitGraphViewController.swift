import AppKit
import SopranoGitCore

/// Center area: the commit graph (refs column, lanes, message, author, date, id), with the
/// working-copy row on top and stashes inline. Owned by the Graph module.
///
/// Rows come from `GraphRowModel`, rebuilt from scratch when the commits reset or the
/// working-copy row / stash list changes, and appended page by page otherwise (rows never
/// change once appended, so appends keep scroll position and selection). Controller
/// events coalesce into one sync per run-loop turn; big pages are laid out off the main
/// thread.
@MainActor
final class CommitGraphViewController: NSViewController, FocusRegionController, SelectionTargetProvider,
    NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate
{
    enum Column: String, CaseIterable {
        case refs
        case graph
        case message
        case author
        case date
        case id

        var title: String {
            switch self {
            case .refs: "Branch / Tag"
            case .graph: "Graph"
            case .message: "Commit Message"
            case .author: "Author"
            case .date: "Date"
            case .id: "SHA"
            }
        }

        /// Starting width; the graph follows its lanes and the message takes the rest.
        var defaultWidth: CGFloat {
            switch self {
            case .refs: 170
            case .graph: 76
            case .message: 300
            case .author: 130
            case .date: 100
            case .id: 72
            }
        }

        var widthRange: ClosedRange<CGFloat> {
            switch self {
            case .refs: 60 ... 420
            case .graph: GraphMetrics.graphWidthRange
            case .message: 120 ... 10_000
            case .author: 60 ... 320
            case .date: 50 ... 220
            case .id: 50 ... 160
            }
        }
    }

    /// UserDefaults key of the user-resized column widths (`[column: width]`).
    static let columnWidthsKey = "graph.columnWidths"
    /// Pages at most this many nodes are laid out on the main thread.
    static let synchronousBuildLimit = 4000
    /// Searches over more rows than this run off the main thread.
    static let synchronousSearchLimit = 20_000
    /// The next page loads when the visible range comes this close to the end.
    static let pagingDistance = 200
    /// Columns hidden first as the center area narrows.
    private static let collapsibleColumns: [Column] = [.id, .author, .date]
    private static let minimumMessageWidth: CGFloat = 200

    let controller: RepositoryController
    /// Set by the workspace right after creating the controller.
    weak var workspace: (any RepoWorkspace)? {
        didSet { observeFocus() }
    }

    /// Where column widths persist; the workspace passes its state store's defaults.
    var defaults: UserDefaults = .standard
    /// Requests the next page of commits (tests count the calls).
    var pageLoader: @MainActor () -> Void

    private(set) var model = GraphRowModel(stashes: [], workingCopy: .none)
    private var pillsByCommit: [String: [RefPill]] = [:]
    private var wipCounts = GraphTextView.WorkingCopyCounts(conflicted: 0, unstaged: 0, staged: 0)
    private var dateCache: [String?] = []
    private var theme: AppTheme
    private(set) var style: GraphStyle

    let tableView = RetroTableView()
    private let headerView = GraphHeaderView()
    private var scrollView: NSScrollView!
    private var columns: [Column: NSTableColumn] = [:]
    private var customWidths: [String: Double] = [:]
    private var isApplyingWidths = false
    private let rowMenu = NSMenu()

    let searchBar: GraphSearchBar
    private var searchBarHeight: NSLayoutConstraint!

    // Sync state.
    private var needsRebuild = true
    private var needsVisibleRefresh = false
    private var isSyncScheduled = false
    private var isBuilding = false
    private var needsSyncAfterBuild = false
    private var revealsSelection = true
    private var isApplyingSelection = false
    /// Commit count the last page request was made at (one request per page).
    private var requestedPageAt: Int?
    /// The selected commit is not loaded yet; keep paging until it is.
    private var isRevealingUnloadedSelection = false

    // Search state.
    private(set) var isSearchOpen = false
    private var searchQuery: String?
    private(set) var searchMatches: [Int] = []
    private var searchCurrent: Int?
    private var searchGeneration = 0

    init(controller: RepositoryController) {
        self.controller = controller
        theme = ThemeCenter.shared.theme
        style = GraphStyle(theme: theme)
        searchBar = GraphSearchBar(theme: theme)
        pageLoader = { [weak controller] in controller?.loadMoreCommits() }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.minWidth = column.widthRange.lowerBound
            tableColumn.maxWidth = column.widthRange.upperBound
            tableColumn.width = column.defaultWidth
            tableColumn.resizingMask = column == .message ? [] : .userResizingMask
            tableView.addTableColumn(tableColumn)
            columns[column] = tableColumn
        }
        customWidths = defaults.dictionary(forKey: Self.columnWidthsKey) as? [String: Double] ?? [:]
        for (key, width) in customWidths {
            guard let column = Column(rawValue: key), column != .message, let tableColumn = columns[column] else { continue }
            tableColumn.width = min(max(CGFloat(width), column.widthRange.lowerBound), column.widthRange.upperBound)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.allowsTypeSelect = false
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        rowMenu.delegate = self
        tableView.menu = rowMenu
        tableView.setAccessibilityLabel("Commit graph")

        headerView.frame = NSRect(x: 0, y: 0, width: 600, height: GraphMetrics.headerHeight)
        styleTable()

        scrollView = RetroListStyle.makeScrollView(documentView: tableView, theme: theme)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnResized(_:)),
            name: NSTableView.columnDidResizeNotification, object: tableView
        )

        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = true
        searchBar.field.delegate = self
        root.addSubview(searchBar)
        root.addSubview(scrollView)
        searchBarHeight = searchBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchBar.topAnchor.constraint(equalTo: root.topAnchor),
            searchBarHeight,
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        root.layer?.backgroundColor = theme.colors.bgPanel.cgColor

        controller.addObserver(self) { [weak self] event in
            self?.handle(event)
        }
        ThemeCenter.shared.addObserver(self) { [weak self] theme in
            self?.apply(theme: theme)
        }
        SettingsCenter.shared.addObserver(self) { [weak self] in
            self?.settingsChanged()
        }
        observeFocus()

        pillsByCommit = RefPill.index(controller.refs)
        updateWorkingCopyCounts()
        if controller.hasLoaded {
            sync()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutColumns()
    }

    private func styleTable() {
        RetroListStyle.apply(to: tableView, theme: theme, rowHeight: GraphMetrics.rowHeight)
        tableView.headerView = headerView
        tableView.cornerView = nil
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        headerView.style = style
    }

    private func observeFocus() {
        guard isViewLoaded, let workspace else { return }
        workspace.addFocusObserver(self) { [weak self] region in
            self?.headerView.isFocused = region == .graph
        }
        headerView.isFocused = workspace.focusedRegion == .graph
    }

    var focusRegion: FocusRegion { .graph }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(tableView)
    }

    var selectionTarget: SelectionTarget? {
        switch controller.selection {
        case .workingCopy:
            return .workingCopy
        case let .commit(id):
            return .commit(id)
        case let .stash(index):
            return controller.stashes.first(where: { $0.index == index }).map(SelectionTarget.stash)
        }
    }

    // MARK: - Theme and settings

    private func apply(theme: AppTheme) {
        self.theme = theme
        style = GraphStyle(theme: theme)
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        styleTable()
        RetroListStyle.applyScrollView(scrollView, theme: theme)
        searchBar.apply(theme: theme)
        headerView.needsDisplay = true
        reloadVisibleRows()
    }

    private func settingsChanged() {
        dateCache = Array(repeating: nil, count: model.count)
        reloadVisibleRows()
    }

    // MARK: - Controller events

    private func handle(_ event: RepositoryController.Event) {
        switch event {
        case let .commits(reset):
            if reset { needsRebuild = true }
            scheduleSync()
        case .stashes:
            scheduleSync()
        case .status:
            updateWorkingCopyCounts()
            needsVisibleRefresh = true
            scheduleSync()
        case .refs:
            pillsByCommit = RefPill.index(controller.refs)
            needsVisibleRefresh = true
            scheduleSync()
        case .selection:
            revealsSelection = true
            if isSyncScheduled || isBuilding {
                return // applied once the rows are current
            }
            applySelection()
        case .openDiff, .activity, .failed:
            break
        }
    }

    private func updateWorkingCopyCounts() {
        let status = controller.status
        wipCounts = GraphTextView.WorkingCopyCounts(
            conflicted: status.conflicted.count,
            unstaged: status.unstaged.count,
            staged: status.staged.count
        )
    }

    private func scheduleSync() {
        guard !isSyncScheduled else { return }
        isSyncScheduled = true
        Task { @MainActor [weak self] in
            self?.sync()
        }
    }

    private var desiredWorkingCopy: GraphRowModel.WorkingCopy {
        guard !controller.status.isClean else { return .none }
        if let head = controller.refs.headCommit { return .onHead(head) }
        return .unborn
    }

    /// Brings the rows up to date with the controller: rebuild, append, or just redraw.
    private func sync() {
        isSyncScheduled = false
        guard !isBuilding else {
            needsSyncAfterBuild = true
            return
        }
        let workingCopy = desiredWorkingCopy
        let stashes = controller.stashes
        let commits = controller.commits
        let isComplete = !controller.hasMoreCommits
        if needsRebuild || workingCopy != model.workingCopy || stashes != model.stashes || commits.count < model.commitCount {
            needsRebuild = false
            let make: @Sendable () -> GraphRowModel = {
                GraphRowModel(commits: commits, stashes: stashes, workingCopy: workingCopy, isComplete: isComplete)
            }
            if commits.count <= Self.synchronousBuildLimit {
                applyRebuild(make())
            } else {
                buildOffMain(make) { [weak self] newModel in
                    self?.applyRebuild(newModel)
                }
            }
        } else if commits.count > model.commitCount || (isComplete && !model.isComplete) {
            let page = Array(commits[model.commitCount...])
            if page.count <= Self.synchronousBuildLimit {
                // In place: the model's storage is uniquely ours, so nothing is copied.
                applyAppend(range: model.append(page, isComplete: isComplete))
            } else {
                let base = model
                buildOffMain {
                    var next = base
                    let range = next.append(page, isComplete: isComplete)
                    return (next, range)
                } apply: { [weak self] result in
                    self?.model = result.0
                    self?.applyAppend(range: result.1)
                }
            }
        } else {
            if needsVisibleRefresh { reloadVisibleRows() }
            applySelection()
        }
    }

    /// Runs `work` off the main thread, then `apply` on the main actor. Builds are
    /// serialized: syncs requested meanwhile run once it lands.
    private func buildOffMain<Result: Sendable>(
        _ work: @escaping @Sendable () -> Result,
        apply: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        isBuilding = true
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { work() }.value
            guard let self else { return }
            self.isBuilding = false
            apply(result)
            if self.needsSyncAfterBuild {
                self.needsSyncAfterBuild = false
                self.sync()
            }
        }
    }

    /// Shows rows laid out elsewhere (benchmarks); the next controller change rebuilds.
    func replaceRows(with newModel: GraphRowModel) {
        needsRebuild = true
        applyRebuild(newModel)
    }

    private func applyRebuild(_ newModel: GraphRowModel) {
        let anchor = scrollAnchor()
        model = newModel
        dateCache = Array(repeating: nil, count: model.count)
        requestedPageAt = nil
        needsVisibleRefresh = false
        isApplyingSelection = true
        tableView.reloadData()
        isApplyingSelection = false
        restore(anchor)
        layoutColumns()
        if searchQuery != nil { rerunSearch(keepingPosition: true) }
        applySelection()
        checkPaging()
    }

    private func applyAppend(range: Range<Int>) {
        if !range.isEmpty {
            dateCache.append(contentsOf: repeatElement(nil, count: range.count))
            isApplyingSelection = true
            tableView.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
            isApplyingSelection = false
            layoutColumns()
            if searchQuery != nil { extendSearch(over: range) }
        }
        if needsVisibleRefresh {
            needsVisibleRefresh = false
            reloadVisibleRows()
        }
        applySelection()
        checkPaging()
    }

    private func reloadVisibleRows() {
        needsVisibleRefresh = false
        guard isViewLoaded, model.count > 0 else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        let rows = IndexSet(integersIn: visible.location ..< min(model.count, visible.location + visible.length))
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0 ..< tableView.numberOfColumns))
    }

    // MARK: - Scroll anchoring

    private struct ScrollAnchor {
        let id: String
        let offset: CGFloat
    }

    /// The top visible row and how far it is scrolled, so a rebuild that adds or drops
    /// rows above (WIP row, stashes) does not move what the user looks at.
    private func scrollAnchor() -> ScrollAnchor? {
        let visible = tableView.visibleRect
        guard model.count > 0, visible.height > 0, visible.minY > 0 else { return nil }
        let row = tableView.row(at: NSPoint(x: 0, y: visible.minY))
        guard model.entries.indices.contains(row) else { return nil }
        return ScrollAnchor(id: model.entries[row].node.id, offset: visible.minY - tableView.rect(ofRow: row).minY)
    }

    private func restore(_ anchor: ScrollAnchor?) {
        guard let anchor, let row = model.row(forID: anchor.id) else { return }
        let y = tableView.rect(ofRow: row).minY + anchor.offset
        if abs(y - tableView.visibleRect.minY) > 0.5 {
            tableView.scroll(NSPoint(x: tableView.visibleRect.minX, y: y))
        }
    }

    // MARK: - Columns

    private func layoutColumns() {
        guard isViewLoaded, let scrollView else { return }
        let available = scrollView.contentSize.width
        guard available > 0 else { return }
        isApplyingWidths = true
        defer { isApplyingWidths = false }

        if let graph = columns[.graph], customWidths[Column.graph.rawValue] == nil {
            let range = Column.graph.widthRange
            let width = min(max(GraphMetrics.graphWidth(lanes: model.maxLaneCount), range.lowerBound), range.upperBound)
            if graph.width != width { graph.width = width }
        }
        if let refs = columns[.refs] {
            let stored = customWidths[Column.refs.rawValue].map { CGFloat($0) } ?? Column.refs.defaultWidth
            let width = min(stored, max(100, floor(available * 0.3)))
            if refs.width != width { refs.width = width }
        }

        var hidden = Set<Column>()
        func fixedWidth() -> CGFloat {
            Column.allCases.filter { $0 != .message && !hidden.contains($0) }.reduce(0) { $0 + (columns[$1]?.width ?? 0) }
        }
        for column in Self.collapsibleColumns where available - fixedWidth() < Self.minimumMessageWidth {
            hidden.insert(column)
        }
        for column in Self.collapsibleColumns {
            let isHidden = hidden.contains(column)
            if columns[column]?.isHidden != isHidden { columns[column]?.isHidden = isHidden }
        }
        if let message = columns[.message] {
            let width = max(Column.message.widthRange.lowerBound, floor(available - fixedWidth()))
            if message.width != width { message.width = width }
        }
        headerView.needsDisplay = true
    }

    @objc private func columnResized(_ notification: Notification) {
        guard !isApplyingWidths,
              let tableColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue), column != .message
        else { return }
        customWidths[column.rawValue] = Double(tableColumn.width)
        defaults.set(customWidths, forKey: Self.columnWidthsKey)
        layoutColumns()
    }

    /// Visible columns (tests, narrow layouts).
    var visibleColumns: [Column] {
        Column.allCases.filter { columns[$0]?.isHidden == false }
    }

    func width(of column: Column) -> CGFloat {
        columns[column]?.width ?? 0
    }

    // MARK: - Data source and cells

    func numberOfRows(in tableView: NSTableView) -> Int {
        model.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
              model.entries.indices.contains(row)
        else { return nil }
        let entry = model.entries[row]
        switch column {
        case .refs:
            let view = reusable(GraphRefsView.identifier) { GraphRefsView() }
            view.configure(pills: pills(for: entry), lane: entry.layout.lane, match: matchState(row), style: style)
            return view
        case .graph:
            let view = reusable(GraphLaneView.identifier) { GraphLaneView() }
            view.configure(
                row: entry.layout, index: row, isHead: isHead(entry), hasRefs: !pills(for: entry).isEmpty, style: style
            )
            return view
        case .message:
            let view = reusable(GraphTextView.messageIdentifier) { GraphTextView() }
            switch entry.node.content {
            case .workingCopy:
                view.configureWorkingCopy(wipCounts, style: style)
            case let .commit(commit):
                view.configure(
                    text: commit.summary,
                    attributes: commit.isMerge ? style.mergeMessageAttributes : style.messageAttributes,
                    highlight: highlightRange(in: commit.summary, row: row),
                    style: style
                )
            case let .stash(stash):
                view.configure(
                    text: stash.message,
                    attributes: style.mergeMessageAttributes,
                    highlight: highlightRange(in: stash.message, row: row),
                    style: style
                )
            }
            return view
        case .author:
            let view = reusable(GraphTextView.authorIdentifier) { GraphTextView() }
            if case let .commit(commit) = entry.node.content {
                view.configure(text: commit.author.name, attributes: style.mutedAttributes, style: style)
            } else {
                view.configure(text: "", attributes: style.mutedAttributes, style: style)
            }
            return view
        case .date:
            let view = reusable(GraphTextView.dateIdentifier) { GraphTextView() }
            view.configure(text: dateText(row: row, entry: entry), attributes: style.mutedAttributes, style: style)
            return view
        case .id:
            let view = reusable(GraphTextView.idIdentifier) { GraphTextView() }
            let text: String = switch entry.node.content {
            case .workingCopy: ""
            case let .commit(commit): commit.shortID
            case let .stash(stash): String(stash.id.prefix(7))
            }
            view.configure(text: text, attributes: style.mutedAttributes, style: style)
            return view
        }
    }

    private func reusable<View: NSView>(_ identifier: NSUserInterfaceItemIdentifier, make: () -> View) -> View {
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? View {
            return view
        }
        let view = make()
        view.identifier = identifier
        return view
    }

    private static let noPills: [RefPill] = []

    private func pills(for entry: GraphEntry) -> [RefPill] {
        guard case let .commit(commit) = entry.node.content else { return Self.noPills }
        return pillsByCommit[commit.id] ?? Self.noPills
    }

    private func isHead(_ entry: GraphEntry) -> Bool {
        guard case .commit = entry.node.content, let head = controller.refs.headCommit else { return false }
        return entry.node.id == head
    }

    private func dateText(row: Int, entry: GraphEntry) -> String {
        if dateCache.indices.contains(row), let text = dateCache[row] { return text }
        let date: Date? = switch entry.node.content {
        case .workingCopy: nil
        case let .commit(commit): commit.author.date
        case let .stash(stash): stash.date
        }
        let text = date.map { DateText.format($0, style: SettingsCenter.shared.settings.dateStyle) } ?? ""
        if dateCache.indices.contains(row) { dateCache[row] = text }
        return text
    }

    /// The configured cells of a row, by column (tests and the perf check).
    func configuredCell(column: Column, row: Int) -> NSView? {
        guard let tableColumn = columns[column] else { return nil }
        return tableView(tableView, viewFor: tableColumn, row: row)
    }

    // MARK: - Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let row = tableView.selectedRow
        guard let selection = model.selection(at: row) else {
            // Clicking empty space must not leave the table out of step with the panel.
            applySelection()
            return
        }
        controller.select(selection)
    }

    private func setTableSelection(_ row: Int?) {
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        if let row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// Mirrors `controller.selection` into the table; reveals it after outside changes.
    private func applySelection() {
        var shouldReveal = revealsSelection
        revealsSelection = false
        guard let row = model.row(for: controller.selection) else {
            if tableView.selectedRow >= 0 { setTableSelection(nil) }
            if case .commit = controller.selection, controller.hasMoreCommits {
                isRevealingUnloadedSelection = true
                requestPage()
            }
            return
        }
        shouldReveal = shouldReveal || isRevealingUnloadedSelection
        isRevealingUnloadedSelection = false
        if tableView.selectedRow != row { setTableSelection(row) }
        if shouldReveal { reveal(row: row) }
    }

    /// Scrolls `row` into view: minimally when it is partly visible, else a third
    /// from the top so its surroundings show.
    private func reveal(row: Int) {
        let visible = tableView.visibleRect
        let rect = tableView.rect(ofRow: row)
        guard visible.height > 0, !visible.contains(rect) else { return }
        if visible.intersects(rect) {
            tableView.scrollRowToVisible(row)
        } else {
            let y = max(0, rect.minY - floor(visible.height / 3))
            tableView.scroll(NSPoint(x: visible.minX, y: y))
        }
    }

    /// Selects a row the way a click would (updates the controller) and reveals it.
    func select(row: Int) {
        guard model.entries.indices.contains(row) else { return }
        if let selection = model.selection(at: row) {
            controller.select(selection)
        }
        if tableView.selectedRow != row { setTableSelection(row) }
        reveal(row: row)
    }

    /// The selected row, from the table or else the controller's selection.
    var selectedRow: Int? {
        let row = tableView.selectedRow
        return row >= 0 ? row : model.row(for: controller.selection)
    }

    // MARK: - Navigation (graph commands)

    var hasRows: Bool { model.count > 0 }

    func moveSelection(by delta: Int) {
        guard model.count > 0 else { return }
        let target = selectedRow.map { min(max($0 + delta, 0), model.count - 1) } ?? 0
        select(row: target)
    }

    func selectFirstRow() {
        guard model.count > 0 else { return }
        select(row: 0)
    }

    func selectLastRow() {
        guard model.count > 0 else { return }
        select(row: model.count - 1)
    }

    /// `graph.nextInBranch`: down the first-parent line.
    func followFirstParent() {
        guard let row = selectedRow else { return }
        if let parent = model.firstParentRow(of: row) {
            select(row: parent)
        } else if model.entries[row].node.parents.first != nil {
            requestPage() // the parent is further down; the next press finds it
        }
    }

    /// `graph.previousInBranch`: up to the nearest child, on the same lane when possible.
    func followChild() {
        guard let row = selectedRow, let child = model.childRow(of: row) else { return }
        select(row: child)
    }

    var headRow: Int? {
        controller.refs.headCommit.flatMap { model.row(forID: $0) }
    }

    func selectHead() {
        guard let row = headRow else { return }
        select(row: row)
    }

    var workingCopyRow: Int? { model.row(for: .workingCopy) }

    func selectWorkingCopy() {
        guard let row = workingCopyRow else { return }
        select(row: row)
    }

    // MARK: - Paging

    @objc private func scrolled(_ notification: Notification) {
        checkPaging()
    }

    private func checkPaging() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        checkPaging(lastVisibleRow: visible.location + visible.length - 1)
    }

    /// Asks for the next page when `lastVisibleRow` is within `pagingDistance` of the
    /// end and more commits exist; once per page.
    func checkPaging(lastVisibleRow: Int) {
        guard controller.hasMoreCommits, model.count > 0, lastVisibleRow >= model.count - Self.pagingDistance else { return }
        requestPage()
    }

    private func requestPage() {
        let loaded = controller.commits.count
        guard controller.hasMoreCommits, !isBuilding, requestedPageAt != loaded else { return }
        requestedPageAt = loaded
        pageLoader()
    }

    // MARK: - Context menu and double click

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let workspace, let target = clickedTarget() else { return }
        let source = GitActions.contextMenu(for: target, in: workspace)
        let items = source.items
        source.removeAllItems()
        items.forEach { menu.addItem($0) }
    }

    /// What a click at the current event acts on: the pill under the pointer, else the row.
    private func clickedTarget() -> SelectionTarget? {
        let row = tableView.clickedRow
        guard model.entries.indices.contains(row) else { return nil }
        if let pill = clickedPill(row: row) { return pill.target }
        return target(at: row)
    }

    private func clickedPill(row: Int) -> RefPill? {
        guard let event = NSApp.currentEvent, let refsIndex = tableView.tableColumns.firstIndex(where: { $0 === columns[.refs] }),
              let refsView = tableView.view(atColumn: refsIndex, row: row, makeIfNecessary: false) as? GraphRefsView
        else { return nil }
        return refsView.pill(at: refsView.convert(event.locationInWindow, from: nil))
    }

    func target(at row: Int) -> SelectionTarget? {
        guard model.entries.indices.contains(row) else { return nil }
        switch model.entries[row].node.content {
        case .workingCopy: return .workingCopy
        case let .commit(commit): return .commit(commit.id)
        case let .stash(stash): return .stash(stash)
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard model.entries.indices.contains(row), let pill = clickedPill(row: row), let workspace else { return }
        Task { @MainActor in
            await GitActions.checkout(pill.target, in: workspace)
        }
    }

    // MARK: - Search

    /// `graph.search`: shows the search bar and focuses its field.
    func openSearch() {
        if !isSearchOpen {
            isSearchOpen = true
            searchBar.isHidden = false
            searchBarHeight.constant = GraphSearchBar.height
            updateSearchCount()
        }
        view.window?.makeFirstResponder(searchBar.field)
        searchBar.field.currentEditor()?.selectAll(nil)
    }

    /// Hides the bar, clears the highlights and returns focus to the table.
    func closeSearch() {
        guard isSearchOpen else { return }
        isSearchOpen = false
        searchBar.isHidden = true
        searchBarHeight.constant = 0
        searchBar.field.stringValue = ""
        searchGeneration += 1
        searchQuery = nil
        searchMatches = []
        searchCurrent = nil
        reloadVisibleRows()
        takeFocus()
    }

    /// Runs the search for `query` (what typing in the field does) and moves to the
    /// first match at or below the selection.
    func search(_ query: String) {
        if searchBar.field.stringValue != query { searchBar.field.stringValue = query }
        searchQuery = GraphSearch.normalized(query)
        rerunSearch(keepingPosition: false)
    }

    var hasSearchMatches: Bool { isSearchOpen && !searchMatches.isEmpty }

    /// `3 / 17` as shown in the bar.
    var searchCountText: String { searchBar.countString }

    func controlTextDidChange(_ notification: Notification) {
        search(searchBar.field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            stepSearch(by: backwards ? -1 : 1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeSearch()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveDown(_:)):
            takeFocus()
            return true
        default:
            return false
        }
    }

    /// `graph.searchNext` / `graph.searchPrevious`: wraps around both ends.
    func stepSearch(by delta: Int) {
        guard !searchMatches.isEmpty else { return }
        let next: Int
        if let current = searchCurrent, searchMatches[current] == selectedRow {
            next = (current + delta + searchMatches.count) % searchMatches.count
        } else if let selected = selectedRow {
            // The selection moved since the last hit: continue from where it is now.
            if delta > 0 {
                next = searchMatches.firstIndex(where: { $0 > selected }) ?? 0
            } else {
                next = searchMatches.lastIndex(where: { $0 < selected }) ?? searchMatches.count - 1
            }
        } else {
            next = delta > 0 ? 0 : searchMatches.count - 1
        }
        moveToMatch(next)
    }

    private func moveToMatch(_ index: Int) {
        searchCurrent = index
        select(row: searchMatches[index])
        updateSearchCount()
        reloadVisibleRows()
    }

    /// Matches over every loaded row. `keepingPosition` (rows were rebuilt): the current
    /// match becomes the one at or below the selection, without moving the selection.
    private func rerunSearch(keepingPosition: Bool) {
        searchGeneration += 1
        let generation = searchGeneration
        guard let query = searchQuery else {
            searchMatches = []
            searchCurrent = nil
            updateSearchCount()
            reloadVisibleRows()
            return
        }
        let entries = model.entries
        let finish: @MainActor ([Int]) -> Void = { [weak self] rows in
            guard let self, generation == self.searchGeneration else { return }
            self.searchMatches = rows
            let start = self.selectedRow ?? 0
            let current = rows.isEmpty ? nil : (rows.firstIndex(where: { $0 >= start }) ?? 0)
            if keepingPosition {
                self.searchCurrent = current.flatMap { rows[$0] == self.selectedRow ? $0 : nil }
                self.updateSearchCount()
                self.reloadVisibleRows()
            } else if let current {
                self.moveToMatch(current)
            } else {
                self.searchCurrent = nil
                self.updateSearchCount()
                self.reloadVisibleRows()
            }
        }
        if entries.count <= Self.synchronousSearchLimit {
            finish(GraphSearch.matchingRows(in: entries, range: 0 ..< entries.count, query: query))
        } else {
            Task.detached(priority: .userInitiated) {
                let rows = GraphSearch.matchingRows(in: entries, range: 0 ..< entries.count, query: query)
                await finish(rows)
            }
        }
    }

    /// Adds matches among appended rows.
    private func extendSearch(over range: Range<Int>) {
        guard let query = searchQuery else { return }
        let generation = searchGeneration
        let entries = model.entries
        let finish: @MainActor ([Int]) -> Void = { [weak self] rows in
            guard let self, generation == self.searchGeneration, !rows.isEmpty else { return }
            self.searchMatches.append(contentsOf: rows)
            self.updateSearchCount()
        }
        if range.count <= Self.synchronousSearchLimit {
            finish(GraphSearch.matchingRows(in: entries, range: range, query: query))
        } else {
            Task.detached(priority: .userInitiated) {
                let rows = GraphSearch.matchingRows(in: entries, range: range, query: query)
                await finish(rows)
            }
        }
    }

    private func updateSearchCount() {
        searchBar.setCount(
            current: searchCurrent.map { $0 + 1 },
            total: searchMatches.count,
            hasQuery: searchQuery != nil
        )
    }

    func matchState(_ row: Int) -> GraphMatchState {
        guard searchQuery != nil, !searchMatches.isEmpty else { return .none }
        if let current = searchCurrent, searchMatches[current] == row { return .current }
        var low = 0
        var high = searchMatches.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if searchMatches[middle] == row { return .match }
            if searchMatches[middle] < row { low = middle + 1 } else { high = middle - 1 }
        }
        return .none
    }

    private func highlightRange(in text: String, row: Int) -> NSRange? {
        guard let query = searchQuery, matchState(row) != .none else { return nil }
        let range = (text as NSString).range(of: query, options: .caseInsensitive)
        return range.location == NSNotFound ? nil : range
    }
}

import AppKit
import SopranoGitCore

/// Center area while `controller.openDiff` is set: the file's hunks with line
/// numbers and hunk staging, unified or split (`layout`, app-wide), syntax
/// colored once the whole-file highlight arrives. Long lines scroll
/// horizontally (`textOffset`): only the code text moves, both split sides
/// together, while gutters and hunk headers stay put. Owned by the Commit Panel module.
@MainActor
final class DiffViewController: NSViewController, FocusRegionController, NSTableViewDataSource, NSTableViewDelegate {
    let controller: RepositoryController
    /// Set by the workspace right after creating the controller.
    weak var workspace: (any RepoWorkspace)?
    /// The app-wide layout store; set once by the workspace right after
    /// creating the controller. Without one the layout is not persisted.
    var state: AppStateStore? {
        didSet {
            guard let state else { return }
            setLayout(state.diffLayout)
            state.addDiffLayoutObserver(self) { [weak self] layout in
                self?.setLayout(layout)
            }
        }
    }

    /// Where ⌘C puts the current hunk (tests use a private pasteboard).
    var pasteboard: NSPasteboard = .general

    private var theme = ThemeCenter.shared.theme
    private(set) var document = DiffDocument.empty
    private(set) var layout: DiffLayout = .unified
    /// Syntax colors of the loaded document; empty until they arrive.
    private(set) var highlights = DiffHighlights.none
    /// A whole-file highlight for the loaded document is being computed.
    private(set) var isHighlighting = false
    /// Index into `document.file.hunks` of the hunk j/k and the hunk keys act on.
    private(set) var currentHunk: Int?
    /// The diff `document` was loaded for.
    private(set) var loadedDiff: OpenDiff?
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// The open file is unmerged: hunks cannot be staged from git's combined diff.
    private(set) var isConflicted = false
    /// Bumped by every load; results (documents, highlights) of older loads are dropped.
    private(set) var loadGeneration = 0
    private var style: DiffRowStyle
    /// How far the code text of every line row is scrolled left, in points;
    /// within `0...textScroll.limit`. Back to 0 for every newly opened file.
    private(set) var textOffset: CGFloat = 0

    private let header: DiffHeaderView
    let tableView = DiffTableView()
    private var scrollView: NSScrollView!
    /// Scroller for `textOffset` along the bottom of the list; hidden when no
    /// line overflows.
    let textScroller = DiffTextScroller()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")

    init(controller: RepositoryController) {
        self.controller = controller
        header = DiffHeaderView(theme: theme)
        style = DiffRowStyle(theme: theme, maxLineNumber: 999)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        // The view loads when the first diff opens; the theme may have changed since init.
        theme = ThemeCenter.shared.theme
        let root = NSView()
        root.wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.setAccessibilityLabel("Diff")
        ListStyle.apply(to: tableView, theme: theme, rowHeight: DiffLineCellView.rowHeight, surface: .base)
        tableView.selectionHighlightStyle = .none
        scrollView = ListStyle.makeScrollView(documentView: tableView, theme: theme, surface: .base)
        tableView.scrollText = { [weak self] delta in
            guard let self, textScroll.limit > 0 else { return false }
            setTextOffset(textOffset + delta)
            return true
        }
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(listResized), name: NSView.frameDidChangeNotification, object: scrollView.contentView
        )
        textScroller.scrollerStyle = .legacy
        textScroller.isEnabled = true
        textScroller.isHidden = true
        textScroller.target = self
        textScroller.action = #selector(textScrolled)

        header.previousButton.target = self
        header.previousButton.action = #selector(previousHunkClicked)
        header.nextButton.target = self
        header.nextButton.action = #selector(nextHunkClicked)
        header.closeButton.target = self
        header.closeButton.action = #selector(closeClicked)
        header.layoutControl.onSelect = { [weak self] layout in
            self?.select(layout)
        }
        header.show(layout: layout)

        noticeLabel.alignment = .center
        for view in [header, scrollView!, textScroller, noticeLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            noticeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            noticeLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            noticeLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 32),
            textScroller.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            textScroller.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            textScroller.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            textScroller.heightAnchor.constraint(
                equalToConstant: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
            ),
        ])
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
            self?.header.apply(theme: self?.theme ?? ThemeCenter.shared.theme)
            self?.tableView.reloadData()
        }
        workspace?.addFocusObserver(self) { [weak self] region in
            self?.header.isFocused = region == .diff
        }
        if controller.openDiff != nil {
            Task { await reload(isRefresh: false) }
        }
    }

    private func applyTheme() {
        view.layer?.backgroundColor = theme.colors.bgBase.cgColor
        header.apply(theme: theme)
        ListStyle.apply(to: tableView, theme: theme, rowHeight: DiffLineCellView.rowHeight, surface: .base)
        tableView.selectionHighlightStyle = .none
        ListStyle.applyScrollView(scrollView, theme: theme, surface: .base)
        textScroller.colors = theme.colors
        rebuildStyle()
        updateHeader()
        updateNotice()
        tableView.reloadData()
        setTextOffset(textOffset)
    }

    private func rebuildStyle() {
        var maxNumber = 1
        if let last = document.file?.hunks.last {
            maxNumber = max(last.oldStart + last.oldCount, last.newStart + last.newCount)
        }
        style = DiffRowStyle(theme: theme, maxLineNumber: maxNumber)
    }

    // MARK: - Region

    var focusRegion: FocusRegion { .diff }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - Loading

    private func handle(_ event: RepositoryController.Event) {
        switch event {
        case .openDiff:
            guard let open = controller.openDiff else {
                loadGeneration += 1
                loadedDiff = nil
                isHighlighting = false
                return
            }
            if open != loadedDiff {
                Task { await reload(isRefresh: false) }
            }
        case .status:
            guard let open = controller.openDiff, open == loadedDiff else { return }
            switch open.target {
            case .unstaged, .staged:
                Task { await reload(isRefresh: true) }
            case .commit, .stash:
                break
            }
        default:
            break
        }
    }

    /// Loads the open diff. A refresh keeps the current hunk's position and
    /// closes the diff when the file has no changes left on its side. The
    /// rows of both layouts are built off the main thread; syntax colors
    /// follow (`highlights`).
    func reload(isRefresh: Bool) async {
        guard isViewLoaded, let open = controller.openDiff else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let repository = controller.repository
        let contextLines = SettingsCenter.shared.settings.diffContextLines
        let path = Self.path(of: open.target) ?? open.title
        let conflicted = controller.status.entries.contains { $0.path == path && $0.conflict != nil }
        if !isRefresh {
            isLoading = true
            loadError = nil
            document = .empty
            highlights = .none
            isHighlighting = false
            currentHunk = nil
            textOffset = 0
            loadedDiff = open
            tableView.reloadData()
            updateHeader()
            updateNotice()
        }
        let target = open.target
        let title = open.title
        let result = await RepositoryController.capture {
            DiffDocument.build(files: try await repository.diff(target, contextLines: contextLines), title: title)
        }
        guard generation == loadGeneration, controller.openDiff == open else { return }
        isLoading = false
        loadedDiff = open
        isConflicted = conflicted
        // A refresh that changed nothing keeps its colors while they are recomputed.
        var keepsColors = false
        switch result {
        case let .success(next):
            if isRefresh, next.file == nil {
                closeAfterLastChange()
                return
            }
            keepsColors = isRefresh && next == document
            let previous = currentHunk
            document = next
            loadError = nil
            if next.hunkCount == 0 {
                currentHunk = nil
            } else if isRefresh, let previous {
                currentHunk = min(previous, next.hunkCount - 1)
            } else {
                currentHunk = 0
            }
        case let .failure(error):
            document = .empty
            currentHunk = nil
            loadError = RepositoryController.message(for: error)
        }
        startHighlighting(open, generation: generation, keepingColors: keepsColors)
        rebuildStyle()
        tableView.reloadData()
        setTextOffset(textOffset)
        updateHeader()
        updateNotice()
        if isRefresh {
            scrollToCurrentHunk()
        } else {
            tableView.scrollRowToVisible(0)
        }
    }

    /// Shows the document uncolored (unless `keepingColors`) and computes its
    /// colors off the main thread from a full-context diff of the same target,
    /// so constructs opened outside the hunks (block comments, strings) color
    /// correctly.
    private func startHighlighting(_ open: OpenDiff, generation: Int, keepingColors: Bool) {
        if !keepingColors { highlights = .none }
        guard DiffHighlights.applies(to: document, isConflicted: isConflicted) else {
            isHighlighting = false
            return
        }
        isHighlighting = true
        let repository = controller.repository
        let target = open.target
        let title = open.title
        Task { [weak self] in
            let result = await RepositoryController.capture {
                let files = try await repository.diff(target, contextLines: Int(Int32.max))
                return DiffDocument.pick(files, title: title).map(DiffHighlights.compute(file:)) ?? .none
            }
            self?.applyHighlights((try? result.get()) ?? .none, generation: generation)
        }
    }

    /// Applies colors computed for load `generation`; a later load (another
    /// file, a reload after hunk staging) makes them stale and they are dropped.
    @discardableResult
    func applyHighlights(_ next: DiffHighlights, generation: Int) -> Bool {
        guard generation == loadGeneration, loadedDiff != nil, controller.openDiff == loadedDiff else { return false }
        isHighlighting = false
        guard next != highlights else { return true }
        highlights = next
        tableView.enumerateAvailableRowViews { rowView, row in
            if let cell = rowView.view(atColumn: 0) as? NSView {
                configureLine(cell, row: row)
            }
        }
        return true
    }

    /// Nothing left to show on this side: back to the commit panel.
    private func closeAfterLastChange() {
        loadedDiff = nil
        document = .empty
        currentHunk = nil
        controller.showDiff(nil)
        workspace?.focus(.detail)
    }

    private static func path(of target: DiffTarget) -> String? {
        switch target {
        case let .unstaged(path), let .staged(path): path
        case let .commit(_, path), let .stash(_, path): path
        }
    }

    // MARK: - Header and notice

    private func updateHeader() {
        guard let open = controller.openDiff ?? loadedDiff else { return }
        let side: DiffHeaderView.Side = switch open.target {
        case .unstaged: .word("Unstaged")
        case .staged: .word("Staged")
        case let .commit(id, _): .identifier(String(id.prefix(7)))
        case let .stash(index, _): .identifier("stash@{\(index)}")
        }
        let file = document.file
        let position: String
        if let currentHunk, document.hunkCount > 0 {
            position = "Hunk \(currentHunk + 1) of \(document.hunkCount)"
        } else {
            position = ""
        }
        header.update(
            path: file?.path ?? open.title,
            oldPath: file?.kind == .renamed || file?.kind == .copied ? file?.oldPath : nil,
            kind: file?.kind,
            additions: file?.isBinary == true ? nil : document.additions,
            deletions: file?.isBinary == true ? nil : document.deletions,
            showCounts: file != nil,
            side: side,
            position: position
        )
    }

    private func updateNotice() {
        let text: String?
        var color = theme.colors.textMuted
        if let loadError {
            text = loadError
            color = theme.colors.danger
        } else if isLoading {
            text = "Loading diff…"
        } else {
            text = document.notice
        }
        noticeLabel.isHidden = text == nil
        noticeLabel.attributedStringValue = ChromeText.attributed(
            text ?? "", font: ChromeFont.label, color: color, alignment: .center, lineBreakMode: .byWordWrapping
        )
    }

    /// The one-line notice shown instead of hunks, if any.
    var noticeText: String? { noticeLabel.isHidden ? nil : noticeLabel.stringValue }

    /// The header's active layout title (Inline / Split).
    var layoutToggleTitle: String { header.layoutText }

    // MARK: - Layout

    /// `v`: switches every open diff between unified and split (persisted
    /// app-wide through `state`), keeping the current hunk in view.
    func toggleLayout() {
        let next = layout.toggled
        if let state {
            state.diffLayout = next
        } else {
            setLayout(next)
        }
    }

    private func setLayout(_ next: DiffLayout) {
        guard next != layout else { return }
        layout = next
        guard isViewLoaded else { return }
        header.show(layout: next)
        tableView.reloadData()
        setTextOffset(textOffset)
        if currentHunk != nil {
            scrollToCurrentHunk()
        } else if tableView.numberOfRows > 0 {
            tableView.scrollRowToVisible(0)
        }
    }

    /// A click on the header's Split | Inline control.
    private func select(_ next: DiffLayout) {
        guard next != layout else { return }
        toggleLayout()
    }

    // MARK: - Horizontal scroll

    /// How far the code text can scroll at the list's current width and
    /// layout (rows span the clip view; the table may lag behind it until drawn).
    var textScroll: (limit: CGFloat, visible: CGFloat) {
        style.textScroll(of: document, layout: layout, rowWidth: scrollView.contentView.bounds.width)
    }

    /// ←/→: scrolls the code text by `columns` characters (negative: left).
    func scrollText(columns: Int) {
        setTextOffset(textOffset + CGFloat(columns) * style.columnWidth)
    }

    /// Characters one ←/→ press scrolls.
    static let arrowColumns = 8

    /// Moves the code text of every line row to `offset` (clamped to the
    /// current limit) and syncs the scroller; also re-clamps after a resize,
    /// a layout switch or a reload.
    private func setTextOffset(_ offset: CGFloat) {
        let scroll = textScroll
        let next = min(max(0, offset), scroll.limit)
        textScroller.isHidden = scroll.limit <= 0
        if scroll.limit > 0 {
            textScroller.knobProportion = scroll.visible / (scroll.visible + scroll.limit)
            textScroller.doubleValue = next / scroll.limit
        }
        guard next != textOffset else { return }
        textOffset = next
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? DiffLineRowCell)?.textOffset = next
        }
    }

    @objc private func listResized() {
        setTextOffset(textOffset)
    }

    @objc private func textScrolled() {
        let scroll = textScroll
        switch textScroller.hitPart {
        case .knob, .knobSlot:
            setTextOffset(textScroller.doubleValue * scroll.limit)
        case .decrementPage, .decrementLine:
            setTextOffset(textOffset - scroll.visible * 0.9)
        case .incrementPage, .incrementLine:
            setTextOffset(textOffset + scroll.visible * 0.9)
        default:
            break
        }
    }

    /// The list's rows in the current layout.
    var rows: [DiffDocument.Row] { document.rows(in: layout) }

    /// List row of the current hunk's header in the current layout.
    var currentHunkRow: Int? {
        let hunkRows = document.hunkRows(in: layout)
        guard let currentHunk, hunkRows.indices.contains(currentHunk) else { return nil }
        return hunkRows[currentHunk]
    }

    // MARK: - Hunks

    /// j/k: the next or previous hunk, scrolled to the top of the list.
    func moveHunk(by delta: Int) {
        guard document.hunkCount > 0 else { return }
        let target = min(max((currentHunk ?? -1) + delta, 0), document.hunkCount - 1)
        guard currentHunk != target || delta == 0 else {
            scrollToCurrentHunk()
            return
        }
        setCurrentHunk(target)
        scrollToCurrentHunk()
    }

    private func setCurrentHunk(_ hunk: Int?) {
        guard hunk != currentHunk else { return }
        currentHunk = hunk
        let tickRow = currentChangeRow
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? DiffLineRowCell)?.isCurrentChange = row == tickRow
        }
        updateHeader()
    }

    /// The row carrying the pencil tick: the current hunk's first change.
    var currentChangeRow: Int? {
        currentHunk.flatMap { document.firstChangedRow(ofHunk: $0, in: layout) }
    }

    private func scrollToCurrentHunk() {
        guard let row = currentHunkRow else { return }
        let rect = tableView.rect(ofRow: row)
        let clip = scrollView.contentView
        let maxY = max(0, tableView.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, rect.minY), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The current hunk and its file, when hunk keys can act on it.
    private var currentHunkForActions: (DiffHunk, FileDiff)? {
        guard let file = document.file, !file.isBinary, !isConflicted, let currentHunk,
              file.hunks.indices.contains(currentHunk) else { return nil }
        return (file.hunks[currentHunk], file)
    }

    private var side: DiffTarget? { loadedDiff?.target }

    var canStageHunk: Bool {
        guard case .unstaged = side else { return false }
        return currentHunkForActions != nil
    }

    var canUnstageHunk: Bool {
        guard case .staged = side else { return false }
        return currentHunkForActions != nil
    }

    var canDiscardHunk: Bool { canStageHunk }

    @discardableResult
    func stageCurrentHunk() async -> Bool {
        guard canStageHunk, let (hunk, file) = currentHunkForActions else { return false }
        return await runHunkOperation("Stage hunk") { try await $0.stageHunk(hunk, of: file) }
    }

    @discardableResult
    func unstageCurrentHunk() async -> Bool {
        guard canUnstageHunk, let (hunk, file) = currentHunkForActions else { return false }
        return await runHunkOperation("Unstage hunk") { try await $0.unstageHunk(hunk, of: file) }
    }

    /// Asks first; the hunk's worktree change is lost.
    @discardableResult
    func discardCurrentHunk() async -> Bool {
        guard canDiscardHunk, let (hunk, file) = currentHunkForActions else { return false }
        let confirmed = await Dialogs.confirm(
            title: "Discard Hunk",
            message: "Discard this hunk's changes to \(file.path)? This cannot be undone.",
            confirmTitle: "Discard",
            isDestructive: true,
            in: view.window
        )
        guard confirmed else { return false }
        return await runHunkOperation("Discard hunk") { try await $0.discardHunk(hunk, of: file) }
    }

    private func runHunkOperation(_ title: String, _ operation: @escaping @Sendable (Repository) async throws -> Void) async -> Bool {
        let succeeded = await controller.run(title, refresh: [.status]) { repository, _ in
            try await operation(repository)
        }
        // The status can read the same after a hunk moves, so reload explicitly.
        if controller.openDiff != nil {
            await reload(isRefresh: true)
        }
        return succeeded
    }

    private func hunkActions(for index: Int) -> [PanelRowAction] {
        guard let file = document.file, !file.isBinary, !isConflicted else { return [] }
        let focusHunk: @MainActor () -> Void = { [weak self] in self?.setCurrentHunk(index) }
        switch side {
        case .unstaged:
            return [
                PanelRowAction(title: "Stage hunk", commandID: "diff.stageHunk") { [weak self] in
                    focusHunk()
                    Task { await self?.stageCurrentHunk() }
                },
                PanelRowAction(title: "Discard", commandID: "diff.discardHunk", kind: .danger) { [weak self] in
                    focusHunk()
                    Task { await self?.discardCurrentHunk() }
                },
            ]
        case .staged:
            return [
                PanelRowAction(title: "Unstage hunk", commandID: "diff.unstageHunk") { [weak self] in
                    focusHunk()
                    Task { await self?.unstageCurrentHunk() }
                },
            ]
        default:
            return []
        }
    }

    /// ⌘C: the current hunk as unified-diff text.
    @objc func copy(_ sender: Any?) {
        guard let currentHunk, let text = document.text(ofHunk: currentHunk) else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func close() {
        controller.showDiff(nil)
        if let workspace, workspace.isCommitPanelVisible {
            workspace.focus(.detail)
        }
    }

    @objc private func closeClicked() {
        close()
    }

    @objc private func previousHunkClicked() {
        moveHunk(by: -1)
    }

    @objc private func nextHunkClicked() {
        moveHunk(by: 1)
    }

    @objc private func rowClicked() {
        if let hunk = document.hunk(ofRow: tableView.clickedRow, in: layout) {
            setCurrentHunk(hunk)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let rows = rows
        guard rows.indices.contains(row) else { return DiffLineCellView.rowHeight }
        switch rows[row] {
        case .hunk: return DiffHunkHeaderCellView.rowHeight
        case .line: return DiffLineCellView.rowHeight
        case .pair: return DiffSplitLineCellView.rowHeight
        case .notice: return DiffNoticeCellView.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        NSTableRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rows = rows
        guard rows.indices.contains(row), let file = document.file else { return nil }
        switch rows[row] {
        case let .hunk(index):
            let cell = tableView.makeView(withIdentifier: DiffHunkHeaderCellView.identifier, owner: nil) as? DiffHunkHeaderCellView
                ?? DiffHunkHeaderCellView()
            cell.configure(hunk: file.hunks[index], actions: hunkActions(for: index), style: style, theme: theme)
            return cell
        case .line:
            let cell = tableView.makeView(withIdentifier: DiffLineCellView.identifier, owner: nil) as? DiffLineCellView
                ?? DiffLineCellView()
            configureLine(cell, row: row)
            return cell
        case .pair:
            let cell = tableView.makeView(withIdentifier: DiffSplitLineCellView.identifier, owner: nil) as? DiffSplitLineCellView
                ?? DiffSplitLineCellView()
            configureLine(cell, row: row)
            return cell
        case let .notice(text):
            let cell = tableView.makeView(withIdentifier: DiffNoticeCellView.identifier, owner: nil) as? DiffNoticeCellView
                ?? DiffNoticeCellView()
            cell.configure(text: text, style: style)
            return cell
        }
    }

    /// Configures a unified or split line cell for `row`: only that row's
    /// lines, tokens and word emphasis are looked up and turned into attributes.
    private func configureLine(_ cell: NSView, row: Int) {
        let rows = rows
        guard rows.indices.contains(row), let file = document.file else { return }
        let isCurrentChange = row == currentChangeRow
        switch rows[row] {
        case let .line(hunk, index):
            guard let cell = cell as? DiffLineCellView else { return }
            let line = file.hunks[hunk].lines[index]
            let tokens = line.kind == .removed ? oldTokens(of: line) : newTokens(of: line)
            cell.configure(
                line: line, tokens: tokens, emphasis: document.changedRange(hunk: hunk, line: index), style: style,
                isCurrentChange: isCurrentChange
            )
            cell.textOffset = textOffset
        case let .pair(hunk, old, new):
            guard let cell = cell as? DiffSplitLineCellView else { return }
            let lines = file.hunks[hunk].lines
            let oldLine = old.map { lines[$0] }
            let newLine = new.map { lines[$0] }
            cell.configure(
                old: oldLine, oldTokens: oldLine.flatMap(oldTokens(of:)),
                oldEmphasis: old.flatMap { document.changedRange(hunk: hunk, line: $0) },
                new: newLine, newTokens: newLine.flatMap(newTokens(of:)),
                newEmphasis: new.flatMap { document.changedRange(hunk: hunk, line: $0) },
                style: style, isCurrentChange: isCurrentChange
            )
            cell.textOffset = textOffset
        case .hunk, .notice:
            break
        }
    }

    private func oldTokens(of line: DiffLine) -> [SyntaxToken]? {
        line.oldNumber.flatMap { highlights.old[$0] }
    }

    private func newTokens(of line: DiffLine) -> [SyntaxToken]? {
        line.newNumber.flatMap { highlights.new[$0] }
    }
}

/// The diff list. Horizontal scroll gestures (trackpad, ⇧ + mouse wheel) go
/// to `scrollText` instead of the list, which never scrolls sideways; a
/// trackpad gesture and its momentum keep the axis they started on.
final class DiffTableView: ListTableView {
    /// Scrolls the code text by a point delta (positive: further into the
    /// lines); false when no line overflows, so the event scrolls the list.
    var scrollText: ((CGFloat) -> Bool)?
    /// Points one mouse-wheel line moves the text.
    static let wheelLine: CGFloat = 24
    private var gestureIsHorizontal: Bool?

    override func scrollWheel(with event: NSEvent) {
        if !event.phase.isDisjoint(with: [.began, .mayBegin]) {
            gestureIsHorizontal = nil
        }
        let inGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let isHorizontal: Bool
        if inGesture, let locked = gestureIsHorizontal {
            isHorizontal = locked
        } else if dx == 0, dy == 0 {
            super.scrollWheel(with: event)
            return
        } else {
            isHorizontal = abs(dx) > abs(dy)
            if inGesture { gestureIsHorizontal = isHorizontal }
        }
        let delta = -dx * (event.hasPreciseScrollingDeltas ? 1 : Self.wheelLine)
        if isHorizontal, let scrollText, scrollText(delta) { return }
        super.scrollWheel(with: event)
    }
}

/// The diff's horizontal text scroller: AppKit's tracking (knob drag, clicks
/// in the slot), drawn as a capsule `scrollbarThumb` knob without a slot.
final class DiffTextScroller: NSScroller {
    var colors: ThemeColors? {
        didSet { needsDisplay = true }
    }

    /// Wider than tall from the start: that makes the scroller horizontal.
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 15))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        let knob = rect(for: .knob)
        colors.scrollbarThumb.setFill()
        let bar = NSRect(x: knob.minX + 2, y: bounds.midY - 3, width: max(0, knob.width - 4), height: 6)
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    }
}

@MainActor
enum DiffCommands {
    private static func diff(_ context: CommandContext) -> DiffViewController? {
        guard let workspace = context.workspace, workspace.controller.openDiff != nil else { return nil }
        return workspace.diff
    }

    static var all: [AppCommand] {
        [
            AppCommand(
                // Also from the commit panel: clicking or j/k through its files
                // keeps focus there while the diff follows the selection.
                id: "diff.close", title: "Close Diff", category: .view,
                scopes: [.diff, .detail], defaultKeys: ["escape"], icon: "xmark",
                isEnabled: { diff($0) != nil },
                perform: { diff($0)?.close() }
            ),
            AppCommand(
                id: "diff.toggleLayout", title: "Toggle Split Diff", category: .view,
                scopes: [.diff], defaultKeys: ["v"], icon: "rectangle.split.2x1",
                // Also before a diff is open, so the layout can be chosen up front.
                isEnabled: { $0.workspace != nil },
                perform: { $0.workspace?.diff.toggleLayout() }
            ),
            AppCommand(
                id: "diff.nextHunk", title: "Next Hunk", category: .navigation,
                scopes: [.diff], defaultKeys: ["j"], icon: "arrow.down", inPalette: false,
                isEnabled: { (diff($0)?.document.hunkCount ?? 0) > 0 },
                perform: { diff($0)?.moveHunk(by: 1) }
            ),
            AppCommand(
                id: "diff.previousHunk", title: "Previous Hunk", category: .navigation,
                scopes: [.diff], defaultKeys: ["k"], icon: "arrow.up", inPalette: false,
                isEnabled: { (diff($0)?.document.hunkCount ?? 0) > 0 },
                perform: { diff($0)?.moveHunk(by: -1) }
            ),
            AppCommand(
                id: "diff.scrollLeft", title: "Scroll Diff Left", category: .navigation,
                scopes: [.diff], defaultKeys: ["left"], icon: "arrow.left.to.line", inPalette: false,
                isEnabled: { diff($0)?.textScroll.limit ?? 0 > 0 },
                perform: { diff($0)?.scrollText(columns: -DiffViewController.arrowColumns) }
            ),
            AppCommand(
                id: "diff.scrollRight", title: "Scroll Diff Right", category: .navigation,
                scopes: [.diff], defaultKeys: ["right"], icon: "arrow.right.to.line", inPalette: false,
                isEnabled: { diff($0)?.textScroll.limit ?? 0 > 0 },
                perform: { diff($0)?.scrollText(columns: DiffViewController.arrowColumns) }
            ),
            AppCommand(
                id: "diff.nextFile", title: "Next File", category: .navigation,
                scopes: [.diff], defaultKeys: ["shift+j"], icon: "chevron.down",
                isEnabled: { diff($0) != nil },
                perform: { $0.workspace?.commitPanel.openAdjacentFile(by: 1) }
            ),
            AppCommand(
                id: "diff.previousFile", title: "Previous File", category: .navigation,
                scopes: [.diff], defaultKeys: ["shift+k"], icon: "chevron.up",
                isEnabled: { diff($0) != nil },
                perform: { $0.workspace?.commitPanel.openAdjacentFile(by: -1) }
            ),
            AppCommand(
                id: "diff.stageHunk", title: "Stage Hunk", category: .staging,
                scopes: [.diff], defaultKeys: ["s"], icon: "plus.square",
                isEnabled: { diff($0)?.canStageHunk ?? false },
                perform: { context in
                    guard let diff = diff(context) else { return }
                    Task { await diff.stageCurrentHunk() }
                }
            ),
            AppCommand(
                id: "diff.unstageHunk", title: "Unstage Hunk", category: .staging,
                scopes: [.diff], defaultKeys: ["u"], icon: "minus.square",
                isEnabled: { diff($0)?.canUnstageHunk ?? false },
                perform: { context in
                    guard let diff = diff(context) else { return }
                    Task { await diff.unstageCurrentHunk() }
                }
            ),
            AppCommand(
                id: "diff.discardHunk", title: "Discard Hunk", category: .staging,
                scopes: [.diff], defaultKeys: ["d"], icon: "trash.square",
                isEnabled: { diff($0)?.canDiscardHunk ?? false },
                perform: { context in
                    guard let diff = diff(context) else { return }
                    Task { await diff.discardCurrentHunk() }
                }
            ),
        ]
    }
}

import AppKit
import SopranoGitCore

/// Center area while `controller.openDiff` is set: the file's hunks with line
/// numbers and hunk staging, unified or split (`layout`, app-wide), syntax
/// colored once the whole-file highlight arrives. Owned by the Commit Panel module.
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

    private let header: DiffHeaderView
    let tableView = RetroTableView()
    private var scrollView: NSScrollView!
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
        RetroListStyle.apply(to: tableView, theme: theme, rowHeight: DiffLineCellView.rowHeight)
        tableView.selectionHighlightStyle = .none
        scrollView = RetroListStyle.makeScrollView(documentView: tableView, theme: theme)

        header.closeButton.target = self
        header.closeButton.action = #selector(closeClicked)
        header.layoutButton.target = self
        header.layoutButton.action = #selector(layoutClicked)
        header.show(layout: layout)

        noticeLabel.alignment = .center
        for view in [header, scrollView!, noticeLabel] as [NSView] {
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
        view.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        header.apply(theme: theme)
        RetroListStyle.apply(to: tableView, theme: theme, rowHeight: DiffLineCellView.rowHeight)
        tableView.selectionHighlightStyle = .none
        RetroListStyle.applyScrollView(scrollView, theme: theme)
        rebuildStyle()
        updateHeader()
        updateNotice()
        tableView.reloadData()
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
        let colors = theme.colors
        let side: String
        var sideColor: NSColor?
        switch open.target {
        case .unstaged:
            side = "Unstaged"
            sideColor = colors.yellow
        case .staged:
            side = "Staged"
            sideColor = colors.success
        case let .commit(id, _):
            side = String(id.prefix(7))
        case let .stash(index, _):
            side = "stash@{\(index)}"
            sideColor = colors.cyan
        }
        let file = document.file
        let position: String
        if let currentHunk, document.hunkCount > 0 {
            position = "Hunk \(currentHunk + 1)/\(document.hunkCount)"
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
            sideColor: sideColor,
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        noticeLabel.attributedStringValue = NSAttributedString(string: text ?? "", attributes: [
            .font: RetroFont.body(12), .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }

    /// The one-line notice shown instead of hunks, if any.
    var noticeText: String? { noticeLabel.isHidden ? nil : noticeLabel.stringValue }

    /// The header's layout toggle title (Unified / Split).
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
        if currentHunk != nil {
            scrollToCurrentHunk()
        } else if tableView.numberOfRows > 0 {
            tableView.scrollRowToVisible(0)
        }
    }

    @objc private func layoutClicked() {
        toggleLayout()
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
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? DiffRowCell)?.isCurrentHunk = document.hunk(ofRow: row, in: layout) == hunk && hunk != nil
        }
        updateHeader()
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
            cell.configure(
                hunk: file.hunks[index], actions: hunkActions(for: index), style: style, theme: theme,
                textInset: layout == .unified ? style.gutterWidth : style.sideGutterWidth,
                isCurrentHunk: index == currentHunk
            )
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
    /// lines and tokens are looked up and turned into attributes.
    private func configureLine(_ cell: NSView, row: Int) {
        let rows = rows
        guard rows.indices.contains(row), let file = document.file else { return }
        switch rows[row] {
        case let .line(hunk, index):
            guard let cell = cell as? DiffLineCellView else { return }
            let line = file.hunks[hunk].lines[index]
            let tokens = line.kind == .removed ? oldTokens(of: line) : newTokens(of: line)
            cell.configure(line: line, tokens: tokens, style: style, isCurrentHunk: hunk == currentHunk)
        case let .pair(hunk, old, new):
            guard let cell = cell as? DiffSplitLineCellView else { return }
            let lines = file.hunks[hunk].lines
            let oldLine = old.map { lines[$0] }
            let newLine = new.map { lines[$0] }
            cell.configure(
                old: oldLine, oldTokens: oldLine.flatMap(oldTokens(of:)),
                new: newLine, newTokens: newLine.flatMap(newTokens(of:)),
                style: style, isCurrentHunk: hunk == currentHunk
            )
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

@MainActor
enum DiffCommands {
    private static func diff(_ context: CommandContext) -> DiffViewController? {
        guard let workspace = context.workspace, workspace.controller.openDiff != nil else { return nil }
        return workspace.diff
    }

    static var all: [AppCommand] {
        [
            AppCommand(
                id: "diff.close", title: "Close Diff", category: .view,
                scopes: [.diff], defaultKeys: ["escape"], icon: "xmark",
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

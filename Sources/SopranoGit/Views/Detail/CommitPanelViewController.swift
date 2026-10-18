import AppKit
import SopranoGitCore

/// Right panel: details and changed files of the selected commit or stash, or the
/// working copy's unstaged/staged/conflicted files and the commit composer.
/// Owned by the Commit Panel module (Wave B).
@MainActor
final class CommitPanelViewController: NSViewController, FocusRegionController, SelectionTargetProvider,
    NSTableViewDataSource, NSTableViewDelegate {
    let controller: RepositoryController
    /// Set by the workspace right after creating the controller.
    weak var workspace: (any RepoWorkspace)?

    private var theme = ThemeCenter.shared.theme
    private(set) var mode: PanelMode = .workingCopy
    private(set) var rows: [PanelRow] = []
    /// Commit/stash details are loading (or failed with `loadError`).
    private(set) var isLoading = false
    private(set) var loadError: String?

    let detailLoader = LatestRequestLoader<String, CommitDetail>()
    let stashLoader = LatestRequestLoader<String, [ChangedFile]>()

    private let header: PanelHeaderView
    private let copyKeycap: KeycapView
    private let copyLabel = NSTextField(labelWithString: "")
    let infoView: CommitInfoView
    let tableView = PanelFileTableView()
    private var scrollView: NSScrollView!
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    let composer: CommitComposerView

    private var isCommitting = false
    private var amendGeneration = 0
    private var amendDraft: (summary: String, description: String)?
    private var amendPrefill: String?
    /// The message prefilled from MERGE_MSG, and the operation it was read for.
    private var mergePrefill: String?
    private var mergeMessageOperation: OperationInProgress?

    init(controller: RepositoryController) {
        self.controller = controller
        header = PanelHeaderView(title: "Working Copy", theme: theme)
        copyKeycap = KeycapView(text: "Y", theme: theme)
        infoView = CommitInfoView(theme: theme)
        composer = CommitComposerView(theme: theme)
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

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.onOpenRow = { [weak self] row in self?.openFile(at: row) }
        tableView.setAccessibilityLabel("Changed files")
        RetroListStyle.apply(to: tableView, theme: theme, rowHeight: PanelFileCellView.rowHeight)
        scrollView = RetroListStyle.makeScrollView(documentView: tableView, theme: theme)
        scrollView.setContentHuggingPriority(.init(1), for: .vertical)
        scrollView.setContentCompressionResistancePriority(.init(1), for: .vertical)

        copyLabel.setContentHuggingPriority(.required, for: .horizontal)
        header.setAccessoryViews([copyKeycap, copyLabel])

        infoView.onSelectCommit = { [weak self] id in
            self?.controller.select(.commit(id))
        }

        composer.onCommit = { [weak self] in
            Task { await self?.commit() }
        }
        composer.onStageAllAndCommit = { [weak self] in
            Task { await self?.commit(stageAll: true) }
        }
        composer.onAmendToggled = { [weak self] on in
            self?.setAmend(on)
        }
        composer.onTextChange = { [weak self] in
            self?.updateComposer()
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, infoView, scrollView!, composer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        root.addSubview(stack)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.alignment = .center
        root.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            messageLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 84),
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
            self?.refreshKeyHints()
        }
        workspace?.addFocusObserver(self) { [weak self] region in
            self?.header.isFocused = region == .detail
        }
        applySelection()
    }

    private func applyTheme() {
        let colors = theme.colors
        view.layer?.backgroundColor = colors.bgPanel.cgColor
        header.apply(theme: theme)
        copyKeycap.apply(theme: theme)
        infoView.apply(theme: theme)
        composer.apply(theme: theme)
        RetroListStyle.apply(to: tableView, theme: theme, rowHeight: PanelFileCellView.rowHeight)
        RetroListStyle.applyScrollView(scrollView, theme: theme)
        refreshKeyHints()
        updateMessage()
    }

    private func refreshKeyHints() {
        copyKeycap.text = PanelText.keycap("ref.copy") ?? "Y"
        copyLabel.setRetroText("Copy", color: theme.colors.textMuted)
        reloadTablePreservingSelection()
        updateComposer()
    }

    // MARK: - Region

    var focusRegion: FocusRegion { .detail }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(tableView)
        if tableView.selectedRow < 0, let first = PanelRows.adjacentFileRow(in: rows, from: nil, delta: 1) {
            select(row: first)
        }
    }

    var selectionTarget: SelectionTarget? { mode.selectionTarget }

    // MARK: - Events

    private func handle(_ event: RepositoryController.Event) {
        switch event {
        case .selection:
            applySelection()
        case .status:
            if mode == .workingCopy {
                setRows(PanelRows.workingCopy(controller.status))
                updateHeader()
            }
            updateMergePrefill()
            updateComposer()
        case .refs:
            updateHeader()
            if case let .commit(id) = mode, let detail = detailLoader.cached(id) {
                infoView.show(detail, refs: refPills(at: id))
            }
            updateComposer()
        case .stashes:
            if case let .stash(stash) = mode, controller.stashes.first(where: { $0.index == stash.index }) != stash {
                applySelection()
            }
        case .openDiff:
            syncSelectionToOpenDiff()
        case .commits, .activity, .failed:
            break
        }
    }

    /// Switches mode to the controller's selection and loads what it needs.
    func applySelection() {
        guard isViewLoaded else { return }
        loadError = nil
        switch controller.selection {
        case .workingCopy:
            detailLoader.cancel()
            stashLoader.cancel()
            mode = .workingCopy
            isLoading = false
            infoView.isHidden = true
            composer.isHidden = false
            setRows(PanelRows.workingCopy(controller.status), resetSelection: true)
            updateMergePrefill()
        case let .commit(id):
            stashLoader.cancel()
            mode = .commit(id)
            composer.isHidden = true
            loadCommit(id)
        case let .stash(index):
            detailLoader.cancel()
            composer.isHidden = true
            guard let stash = controller.stashes.first(where: { $0.index == index }) else {
                mode = .workingCopy
                setRows([], resetSelection: true)
                return
            }
            mode = .stash(stash)
            loadStash(stash)
        }
        updateHeader()
        updateComposer()
        updateMessage()
    }

    private func loadCommit(_ id: String) {
        let repository = controller.repository
        isLoading = detailLoader.cached(id) == nil
        if isLoading {
            infoView.isHidden = true
            setRows([], resetSelection: true)
        }
        detailLoader.load(id, fetch: { try await repository.commitDetail(id) }) { [weak self] result in
            guard let self, self.mode == .commit(id) else { return }
            self.isLoading = false
            switch result {
            case let .success(detail):
                self.infoView.show(detail, refs: self.refPills(at: id))
                self.infoView.isHidden = false
                self.setRows(PanelRows.files(detail.files), resetSelection: true)
            case let .failure(error):
                self.loadError = RepositoryController.message(for: error)
                self.infoView.isHidden = true
                self.setRows([], resetSelection: true)
            }
            self.updateMessage()
        }
    }

    private func loadStash(_ stash: Stash) {
        let repository = controller.repository
        let index = stash.index
        infoView.show(stash)
        infoView.isHidden = false
        isLoading = stashLoader.cached(stash.id) == nil
        if isLoading {
            setRows([], resetSelection: true)
        }
        stashLoader.load(stash.id, fetch: { try await repository.stashFiles(index) }) { [weak self] result in
            guard let self, self.mode == .stash(stash) else { return }
            self.isLoading = false
            switch result {
            case let .success(files):
                self.setRows(PanelRows.files(files), resetSelection: true)
            case let .failure(error):
                self.loadError = RepositoryController.message(for: error)
                self.setRows([], resetSelection: true)
            }
            self.updateMessage()
        }
    }

    private func refPills(at id: String) -> [(String, RefPillView.Kind)] {
        let refs = controller.refs
        var pills: [(String, RefPillView.Kind)] = []
        if case let .detached(commit) = refs.head, commit == id {
            pills.append(("HEAD", .head))
        }
        for branch in refs.localBranches where branch.target == id {
            pills.append((branch.name, branch.isHead ? .head : .localBranch))
        }
        for branch in refs.remoteBranches where branch.target == id && !branch.name.hasSuffix("/HEAD") {
            pills.append((branch.name, .remoteBranch))
        }
        for tag in refs.tags where tag.target == id {
            pills.append((tag.name, .tag))
        }
        return pills
    }

    private func updateHeader() {
        switch mode {
        case .workingCopy:
            header.title = "Working Copy"
            var detail: String
            switch controller.refs.head {
            case let .branch(name), let .unborn(name): detail = name
            case let .detached(id): detail = "detached at \(id.prefix(7))"
            }
            if let operation = controller.status.operation {
                detail += " · \(operation.title.lowercased()) in progress"
            }
            header.detail = detail
            copyKeycap.isHidden = true
            copyLabel.isHidden = true
        case let .commit(id):
            header.title = "Commit"
            header.detail = String(id.prefix(7))
            copyKeycap.isHidden = false
            copyLabel.isHidden = false
        case let .stash(stash):
            header.title = "Stash"
            header.detail = stash.reference
            copyKeycap.isHidden = false
            copyLabel.isHidden = false
        }
    }

    private func updateMessage() {
        let text: String?
        let color: NSColor
        if let loadError {
            text = loadError
            color = theme.colors.danger
        } else if isLoading {
            text = "Loading…"
            color = theme.colors.textMuted
        } else if mode == .workingCopy, controller.status.isClean, controller.status.operation == nil, controller.hasLoaded {
            text = "Working tree clean"
            color = theme.colors.textMuted
        } else {
            text = nil
            color = theme.colors.textMuted
        }
        messageLabel.isHidden = text == nil
        messageLabel.attributedStringValue = NSAttributedString(
            string: text ?? "",
            attributes: [.font: RetroFont.body(12), .foregroundColor: color, .paragraphStyle: Self.centered]
        )
    }

    private static let centered: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()

    // MARK: - Rows and selection

    var selectedFile: PanelFile? {
        let row = tableView.selectedRow
        return rows.indices.contains(row) ? rows[row].file : nil
    }

    var selectedFiles: [PanelFile] {
        tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].file : nil }
    }

    var files: [PanelFile] { rows.compactMap(\.file) }

    /// Whether any file row is listed (cached; checked on every key press).
    private(set) var hasFiles = false

    /// Keeps every surviving selection by section and path; when all selected
    /// files move away, selects the next file at the old position.
    private func setRows(_ newRows: [PanelRow], resetSelection: Bool = false) {
        let changed = newRows != rows
        let previousKeys: Set<PanelFile.Key> = changed && !resetSelection
            ? Set(tableView.selectedRowIndexes.lazy.compactMap { self.rows.indices.contains($0) ? self.rows[$0].file?.key : nil })
            : []
        let previousRow = tableView.selectedRow
        rows = newRows
        if changed { hasFiles = newRows.contains { $0.file != nil } }
        if changed { tableView.reloadData() }
        updateMessage()
        if resetSelection {
            if let open = openDiffRow() {
                select(row: open)
            } else {
                tableView.deselectAll(nil)
                tableView.scrollRowToVisible(0)
            }
            return
        }
        guard changed else { return }
        var retained = IndexSet()
        for (index, row) in rows.enumerated() {
            if let key = row.file?.key, previousKeys.contains(key) { retained.insert(index) }
        }
        if !retained.isEmpty {
            tableView.selectRowIndexes(retained, byExtendingSelection: false)
            refreshSelectionActions()
        } else if previousRow >= 0 {
            let row = PanelRows.adjacentFileRow(in: rows, from: min(previousRow, rows.count) - 1, delta: 1)
                ?? PanelRows.adjacentFileRow(in: rows, from: min(previousRow, rows.count), delta: -1)
            if let row { select(row: row) } else { tableView.deselectAll(nil) }
        }
    }

    private func reloadTablePreservingSelection() {
        guard isViewLoaded else { return }
        let selected = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selected, byExtendingSelection: false)
    }

    private func select(row: Int) {
        guard rows.indices.contains(row), rows[row].file != nil else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func row(for target: DiffTarget, title: String) -> Int? {
        func matches(_ index: Int) -> Bool {
            guard rows.indices.contains(index), let file = rows[index].file else { return false }
            return file.path == title && PanelRows.diffTarget(for: file, in: mode) == target
        }
        // The open diff is nearly always the selected row; scan only otherwise.
        if matches(tableView.selectedRow) { return tableView.selectedRow }
        return rows.indices.first(where: matches)
    }

    private func openDiffRow() -> Int? {
        guard let open = controller.openDiff else { return nil }
        return row(for: open.target, title: open.title)
    }

    private func syncSelectionToOpenDiff() {
        guard let row = openDiffRow(), !tableView.selectedRowIndexes.contains(row) else { return }
        select(row: row)
    }

    /// j/k: the next or previous file; an open diff follows the selection.
    func moveSelection(by delta: Int) {
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        guard let row = PanelRows.adjacentFileRow(in: rows, from: current, delta: delta) else { return }
        select(row: row)
        if controller.openDiff != nil {
            openFile(at: row)
        }
    }

    /// Opens the diff of the file at `row`.
    func openFile(at row: Int) {
        guard rows.indices.contains(row), let file = rows[row].file else { return }
        controller.showDiff(OpenDiff(target: PanelRows.diffTarget(for: file, in: mode), title: file.path))
    }

    /// Enter/Space and ⌘D: the selected file, else the first one.
    func openSelectedFile() {
        if tableView.selectedRow >= 0, selectedFile != nil {
            openFile(at: tableView.selectedRow)
        } else if let first = PanelRows.adjacentFileRow(in: rows, from: nil, delta: 1) {
            select(row: first)
            openFile(at: first)
        }
    }

    /// The diff's ⇧J/⇧K: moves to the file after/before the open one and opens
    /// it. Returns false at either end or when the open diff is not listed here.
    @discardableResult
    func openAdjacentFile(by delta: Int) -> Bool {
        let base = openDiffRow() ?? (tableView.selectedRow >= 0 ? tableView.selectedRow : nil)
        guard let base, let row = PanelRows.adjacentFileRow(in: rows, from: base, delta: delta) else { return false }
        select(row: row)
        openFile(at: row)
        return true
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return PanelFileCellView.rowHeight }
        if case .section = rows[row] { return PanelSectionCellView.rowHeight }
        return PanelFileCellView.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if rows.indices.contains(row), case .section = rows[row] {
            return NSTableRowView()
        }
        return self.tableView.makeRetroRowView(row: row)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case let .section(section, count):
            let cell = tableView.makeView(withIdentifier: PanelSectionCellView.identifier, owner: nil) as? PanelSectionCellView
                ?? PanelSectionCellView()
            cell.configure(section: section, count: count, actions: sectionActions(section, count: count), theme: theme)
            return cell
        case let .file(file):
            let cell = tableView.makeView(withIdentifier: PanelFileCellView.identifier, owner: nil) as? PanelFileCellView
                ?? PanelFileCellView(theme: theme)
            cell.configure(file: file, actions: actions(for: file), theme: theme, selected: tableView.selectedRowIndexes.contains(row))
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].file != nil
    }

    /// Arrow keys step over section rows instead of stopping on them.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard proposed.count == 1, let row = proposed.first, rows.indices.contains(row), rows[row].file == nil else {
            var files = IndexSet()
            for index in proposed where rows.indices.contains(index) && rows[index].file != nil {
                files.insert(index)
            }
            return files
        }
        let current = tableView.selectedRow
        let delta = current >= 0 && row < current ? -1 : 1
        if let next = PanelRows.adjacentFileRow(in: rows, from: row, delta: delta) {
            return IndexSet(integer: next)
        }
        return current >= 0 ? IndexSet(integer: current) : IndexSet()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshSelectionActions()
    }

    private func refreshSelectionActions() {
        let selection = selectedFiles
        let indexes = tableView.selectedRowIndexes
        tableView.enumerateAvailableRowViews { rowView, row in
            guard self.rows.indices.contains(row) else { return }
            switch self.rows[row] {
            case let .section(section, count):
                (rowView.view(atColumn: 0) as? PanelSectionCellView)?.configure(
                    section: section, count: count,
                    actions: self.sectionActions(section, count: count, selection: selection), theme: self.theme
                )
            case let .file(file):
                (rowView.view(atColumn: 0) as? PanelFileCellView)?.configure(
                    file: file, actions: self.actions(for: file, selection: selection),
                    theme: self.theme, selected: indexes.contains(row)
                )
            }
        }
    }

    // MARK: - Row actions

    private func sectionActions(_ section: PanelSection, count: Int, selection: [PanelFile]? = nil) -> [PanelRowAction] {
        guard count > 0 else { return [] }
        let selection = selection ?? selectedFiles
        let targets = selection.filter { $0.section == section }
        if !selection.isEmpty {
            guard !targets.isEmpty else { return [] }
            switch section {
            case .unstaged:
                return [
                    PanelRowAction(title: "Discard \(targets.count)", commandID: "wip.discardFile", kind: .danger) { [weak self] in
                        Task { await self?.discard(targets) }
                    },
                    PanelRowAction(title: "Stage \(targets.count)", commandID: "wip.stageFile") { [weak self] in
                        Task { await self?.stage(targets) }
                    },
                ]
            case .staged:
                return [
                    PanelRowAction(title: "Unstage \(targets.count)", commandID: "wip.unstageFile") { [weak self] in
                        Task { await self?.unstage(targets) }
                    },
                ]
            case .conflicts, .files:
                break
            }
        }
        switch section {
        case .unstaged:
            return [
                PanelRowAction(title: "Discard all", commandID: "wip.discardAll", kind: .danger) { [weak self] in
                    Task { await self?.discardAll() }
                },
                PanelRowAction(title: "Stage all", commandID: "wip.stageAll") { [weak self] in
                    Task { await self?.stageAll() }
                },
            ]
        case .staged:
            return [
                PanelRowAction(title: "Unstage all", commandID: "wip.unstageAll") { [weak self] in
                    Task { await self?.unstageAll() }
                },
            ]
        case .conflicts, .files:
            return []
        }
    }

    private func actions(for file: PanelFile, selection: [PanelFile]? = nil) -> [PanelRowAction] {
        let selection = selection ?? selectedFiles
        let targets = selection.contains { $0.key == file.key }
            ? selection.filter { $0.section == file.section } : [file]
        let suffix = targets.count > 1 ? " \(targets.count)" : ""
        switch file.section {
        case .unstaged:
            return [
                PanelRowAction(title: "Stage\(suffix)", commandID: "wip.stageFile") { [weak self] in
                    Task { await self?.stage(targets) }
                },
                PanelRowAction(title: "Discard\(suffix)", commandID: "wip.discardFile", kind: .danger) { [weak self] in
                    Task { await self?.discard(targets) }
                },
            ]
        case .staged:
            return [
                PanelRowAction(title: "Unstage\(suffix)", commandID: "wip.unstageFile") { [weak self] in
                    Task { await self?.unstage(targets) }
                },
            ]
        case .conflicts:
            return [
                PanelRowAction(title: "Ours", commandID: "conflict.takeOurs") { [weak self] in
                    Task { await self?.resolve(file, side: .ours) }
                },
                PanelRowAction(title: "Theirs", commandID: "conflict.takeTheirs") { [weak self] in
                    Task { await self?.resolve(file, side: .theirs) }
                },
                PanelRowAction(title: "Resolved\(suffix)", commandID: "wip.stageFile") { [weak self] in
                    Task { await self?.stage(targets) }
                },
            ]
        case .files:
            return []
        }
    }

    // MARK: - Git operations

    private static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Stages the explicit selection (conflicted files are marked resolved).
    @discardableResult
    func stage(_ files: [PanelFile]) async -> Bool {
        guard !files.isEmpty else { return false }
        let paths = files.map(\.path)
        let title = files.count == 1
            ? (files[0].section == .conflicts ? "Mark \(Self.name(of: paths[0])) resolved" : "Stage \(Self.name(of: paths[0]))")
            : "Stage \(files.count) selected files"
        return await controller.run(title, refresh: [.status]) { repository, _ in
            try await repository.stage(paths: paths)
        }
    }

    @discardableResult
    func unstage(_ files: [PanelFile]) async -> Bool {
        guard !files.isEmpty else { return false }
        let paths = files.map(\.path)
        let title = files.count == 1 ? "Unstage \(Self.name(of: paths[0]))" : "Unstage \(files.count) selected files"
        return await controller.run(title, refresh: [.status]) { repository, _ in
            try await repository.unstage(paths: paths)
        }
    }

    /// Asks first; untracked files are deleted.
    @discardableResult
    func discard(_ files: [PanelFile]) async -> Bool {
        let files = files.filter { $0.section == .unstaged }
        guard let first = files.first else { return false }
        let paths = files.map(\.path)
        let untrackedCount = files.reduce(0) { $0 + ($1.isUntracked ? 1 : 0) }
        let message: String
        if files.count == 1 {
            message = first.isUntracked
                ? "\(first.path) is untracked and will be deleted. This cannot be undone."
                : "Discard all unstaged changes to \(first.path)? This cannot be undone."
        } else {
            let deletion = untrackedCount > 0
                ? " \(untrackedCount) untracked \(untrackedCount == 1 ? "file will" : "files will") be deleted."
                : ""
            message = "Discard unstaged changes in \(files.count) selected files?\(deletion) Unselected files, staged changes and conflicts will be kept. This cannot be undone."
        }
        let deletingSingleFile = files.count == 1 && first.isUntracked
        let confirmed = await Dialogs.confirm(
            title: deletingSingleFile ? "Delete Untracked File" : "Discard Selected Changes",
            message: message,
            confirmTitle: deletingSingleFile ? "Delete" : "Discard",
            isDestructive: true,
            in: view.window
        )
        guard confirmed else { return false }
        let title = files.count == 1 ? "Discard \(Self.name(of: first.path))" : "Discard \(files.count) selected files"
        return await controller.run(title, refresh: [.status]) { repository, _ in
            try await repository.discard(paths: paths)
        }
    }

    /// Drops only the listed unstaged paths; the index and conflicts are untouched.
    @discardableResult
    func discardAll() async -> Bool {
        let entries = controller.status.unstaged
        guard !entries.isEmpty else { return false }
        let paths = entries.map(\.path)
        let untrackedCount = entries.reduce(0) { $0 + ($1.unstaged == .untracked ? 1 : 0) }
        let deletion = untrackedCount > 0
            ? " \(untrackedCount) untracked \(untrackedCount == 1 ? "file will" : "files will") be deleted."
            : ""
        let confirmed = await Dialogs.confirm(
            title: "Discard All Unstaged Changes",
            message: "Discard unstaged changes in \(paths.count) \(paths.count == 1 ? "file" : "files")?\(deletion) Staged changes and conflicts will be kept. This cannot be undone.",
            confirmTitle: "Discard All",
            isDestructive: true,
            in: view.window
        )
        guard confirmed else { return false }
        return await controller.run("Discard all unstaged changes", refresh: [.status]) { repository, _ in
            try await repository.discard(paths: paths)
        }
    }

    @discardableResult
    func resolve(_ file: PanelFile, side: ConflictSide) async -> Bool {
        let path = file.path
        let title = side == .ours ? "Resolve \(Self.name(of: path)) with ours" : "Resolve \(Self.name(of: path)) with theirs"
        return await controller.run(title, refresh: [.status]) { repository, _ in
            try await repository.resolveConflict(path: path, side: side)
        }
    }

    /// Stages every unstaged change; while conflicts remain, only the listed
    /// unstaged paths, so conflicted files are never marked resolved by accident.
    @discardableResult
    func stageAll() async -> Bool {
        let status = controller.status
        guard !status.unstaged.isEmpty else { return false }
        let paths = status.unstaged.map(\.path)
        let hasConflicts = !status.conflicted.isEmpty
        return await controller.run("Stage all", refresh: [.status]) { repository, _ in
            if hasConflicts {
                try await repository.stage(paths: paths)
            } else {
                try await repository.stageAll()
            }
        }
    }

    @discardableResult
    func unstageAll() async -> Bool {
        guard !controller.status.staged.isEmpty else { return false }
        return await controller.run("Unstage all", refresh: [.status]) { repository, _ in
            try await repository.unstageAll()
        }
    }

    // MARK: - Composer

    /// Staged and conflicted counts of `countedStatus`, recomputed only when
    /// the status changes (the composer asks on every keystroke).
    private var statusCounts = (staged: 0, conflicts: 0)
    private var countedStatus: WorkingTreeStatus?

    var composerState: ComposerState {
        let status = controller.status
        if countedStatus != status {
            var staged = 0
            var conflicts = 0
            for entry in status.entries {
                if entry.staged != nil { staged += 1 }
                if entry.conflict != nil { conflicts += 1 }
            }
            statusCounts = (staged, conflicts)
            countedStatus = status
        }
        var isMerging = false
        if case .merge = status.operation { isMerging = true }
        return ComposerState(
            stagedCount: statusCounts.staged,
            changeCount: status.entries.count,
            conflictCount: statusCounts.conflicts,
            isAmending: composer.isAmending,
            hasSummary: composer.hasSummary,
            isBusy: isCommitting,
            isMerging: isMerging
        )
    }

    private func updateComposer() {
        guard isViewLoaded else { return }
        composer.amendCheckbox.isEnabled = controller.refs.headCommit != nil && !isCommitting
        composer.update(state: composerState)
    }

    /// ⌘⇧M: shows the working copy and puts the cursor in the summary.
    func focusMessage() {
        if controller.selection != .workingCopy {
            controller.select(.workingCopy)
        }
        workspace?.isCommitPanelVisible = true
        composer.focusSummary()
    }

    /// Amend on: the composer takes HEAD's message (the draft is kept and comes
    /// back when amend is turned off without editing the prefilled message).
    func setAmend(_ on: Bool) {
        composer.isAmending = on
        amendGeneration += 1
        if on {
            amendDraft = (composer.summary, composer.descriptionText)
            let generation = amendGeneration
            let repository = controller.repository
            Task { @MainActor [weak self] in
                let message = try? await repository.headMessage()
                guard let self, generation == self.amendGeneration, self.composer.isAmending, let message else { return }
                self.composer.setMessage(message)
                self.amendPrefill = self.composer.message
                self.updateComposer()
            }
        } else {
            if let draft = amendDraft, amendPrefill == nil || composer.message == amendPrefill {
                composer.summary = draft.summary
                composer.descriptionText = draft.description
            }
            amendDraft = nil
            amendPrefill = nil
        }
        updateComposer()
    }

    func toggleAmend() {
        guard controller.refs.headCommit != nil else { return }
        setAmend(!composer.isAmending)
    }

    /// While git has an operation paused, an empty composer takes its prepared
    /// message (MERGE_MSG without comments); it is cleared again afterwards if
    /// untouched.
    private func updateMergePrefill() {
        guard isViewLoaded else { return }
        guard let operation = controller.status.operation else {
            if let prefill = mergePrefill, composer.message == prefill {
                composer.summary = ""
                composer.descriptionText = ""
            }
            mergePrefill = nil
            mergeMessageOperation = nil
            return
        }
        guard mergeMessageOperation != operation else { return }
        guard composer.summary.isEmpty, composer.descriptionText.isEmpty, !composer.isAmending else { return }
        mergeMessageOperation = operation
        let url = controller.repository.gitDirectory.appendingPathComponent("MERGE_MSG")
        Task { @MainActor [weak self] in
            let text = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
            guard let self, let text, self.controller.status.operation == operation else { return }
            let message = CommitMessage.preparedMessage(text)
            guard !message.isEmpty, self.composer.summary.isEmpty, self.composer.descriptionText.isEmpty, !self.composer.isAmending else { return }
            self.composer.setMessage(message)
            self.mergePrefill = self.composer.message
            self.updateComposer()
        }
    }

    /// Commits the composer's message. Afterwards the composer is cleared and,
    /// when the tree is clean, the new HEAD commit is selected.
    @discardableResult
    func commit(stageAll: Bool = false) async -> Bool {
        let state = composerState
        guard stageAll ? state.canStageAllAndCommit : state.canCommit else { return false }
        let message = composer.message
        let amend = composer.isAmending
        let title = stageAll ? "Stage all and commit" : (amend ? "Amend commit" : "Commit")
        isCommitting = true
        updateComposer()
        let succeeded = await controller.run(title) { repository, _ in
            if stageAll { try await repository.stageAll() }
            try await repository.commit(message: message, amend: amend)
        }
        isCommitting = false
        if succeeded {
            amendGeneration += 1
            amendDraft = nil
            amendPrefill = nil
            mergePrefill = nil
            composer.clear()
            if controller.status.isClean, let head = controller.refs.headCommit {
                controller.select(.commit(head))
            }
        }
        updateComposer()
        return succeeded
    }
}

@MainActor
enum CommitPanelCommands {
    private static func panel(_ context: CommandContext) -> CommitPanelViewController? {
        context.workspace?.commitPanel
    }

    private static func selected(_ context: CommandContext, in sections: Set<PanelSection>) -> PanelFile? {
        guard let panel = panel(context), panel.mode == .workingCopy, let file = panel.selectedFile,
              sections.contains(file.section) else { return nil }
        return file
    }

    private static func selection(_ context: CommandContext, in sections: Set<PanelSection>) -> [PanelFile] {
        guard let panel = panel(context), panel.mode == .workingCopy else { return [] }
        return panel.selectedFiles.filter { sections.contains($0.section) }
    }

    static var all: [AppCommand] {
        [
            AppCommand(
                id: "panel.next", title: "Next File", category: .navigation,
                scopes: [.detail], defaultKeys: ["j"], icon: "arrow.down", inPalette: false,
                isEnabled: { panel($0)?.hasFiles ?? false },
                perform: { panel($0)?.moveSelection(by: 1) }
            ),
            AppCommand(
                id: "panel.previous", title: "Previous File", category: .navigation,
                scopes: [.detail], defaultKeys: ["k"], icon: "arrow.up", inPalette: false,
                isEnabled: { panel($0)?.hasFiles ?? false },
                perform: { panel($0)?.moveSelection(by: -1) }
            ),
            AppCommand(
                id: "panel.openFile", title: "Open Diff", category: .view,
                scopes: [.detail], defaultKeys: ["enter", "space"], icon: "doc.text.magnifyingglass",
                isEnabled: { panel($0)?.selectedFile != nil },
                perform: { panel($0)?.openSelectedFile() }
            ),
            AppCommand(
                id: "diff.openSelected", title: "Open Diff of Selected File", category: .view,
                defaultKeys: ["cmd+d"], icon: "doc.text.magnifyingglass",
                isEnabled: { panel($0)?.hasFiles ?? false },
                perform: { panel($0)?.openSelectedFile() }
            ),
            AppCommand(
                id: "wip.stageFile", title: "Stage Selected Files", category: .staging,
                scopes: [.detail], defaultKeys: ["s"], icon: "plus.circle",
                isEnabled: { !selection($0, in: [.unstaged, .conflicts]).isEmpty },
                perform: { context in
                    guard let panel = panel(context) else { return }
                    let files = selection(context, in: [.unstaged, .conflicts])
                    Task { await panel.stage(files) }
                }
            ),
            AppCommand(
                id: "wip.unstageFile", title: "Unstage Selected Files", category: .staging,
                scopes: [.detail], defaultKeys: ["u"], icon: "minus.circle",
                isEnabled: { !selection($0, in: [.staged]).isEmpty },
                perform: { context in
                    guard let panel = panel(context) else { return }
                    let files = selection(context, in: [.staged])
                    Task { await panel.unstage(files) }
                }
            ),
            AppCommand(
                id: "wip.discardFile", title: "Discard Selected Changes…", category: .staging,
                scopes: [.detail], defaultKeys: ["d"], icon: "trash",
                isEnabled: { !selection($0, in: [.unstaged]).isEmpty },
                perform: { context in
                    guard let panel = panel(context) else { return }
                    let files = selection(context, in: [.unstaged])
                    Task { await panel.discard(files) }
                }
            ),
            AppCommand(
                id: "wip.discardAll", title: "Discard All Unstaged Changes…", category: .staging,
                scopes: [.detail], defaultKeys: ["shift+d"], icon: "trash.fill",
                isEnabled: { context in
                    panel(context)?.mode == .workingCopy && !(context.controller?.status.unstaged.isEmpty ?? true)
                },
                perform: { context in
                    guard let panel = panel(context) else { return }
                    Task { await panel.discardAll() }
                }
            ),
            AppCommand(
                id: "wip.stageAll", title: "Stage All", category: .staging,
                defaultKeys: ["cmd+shift+s"], icon: "plus.circle.fill",
                isEnabled: { !($0.controller?.status.unstaged.isEmpty ?? true) && panel($0) != nil },
                perform: { context in
                    guard let panel = panel(context) else { return }
                    Task { await panel.stageAll() }
                }
            ),
            AppCommand(
                id: "wip.unstageAll", title: "Unstage All", category: .staging,
                defaultKeys: ["cmd+shift+u"], icon: "minus.circle.fill",
                isEnabled: { !($0.controller?.status.staged.isEmpty ?? true) && panel($0) != nil },
                perform: { context in
                    guard let panel = panel(context) else { return }
                    Task { await panel.unstageAll() }
                }
            ),
            AppCommand(
                id: "wip.commit", title: "Commit", category: .commit,
                defaultKeys: ["cmd+enter"], icon: "checkmark.circle",
                isEnabled: { context in
                    guard let panel = panel(context) else { return false }
                    return panel.mode == .workingCopy && panel.composerState.canCommit
                },
                perform: { context in
                    guard let panel = panel(context) else { return }
                    Task { await panel.commit() }
                }
            ),
            AppCommand(
                id: "wip.stageAllAndCommit", title: "Stage All and Commit", category: .commit,
                defaultKeys: ["cmd+shift+enter"], icon: "checkmark.circle.fill",
                isEnabled: { context in
                    guard let panel = panel(context) else { return false }
                    return panel.mode == .workingCopy && panel.composerState.canStageAllAndCommit
                },
                perform: { context in
                    guard let panel = panel(context) else { return }
                    Task { await panel.commit(stageAll: true) }
                }
            ),
            AppCommand(
                id: "wip.focusMessage", title: "Focus Commit Message", category: .commit,
                defaultKeys: ["cmd+shift+m"], icon: "text.cursor",
                isEnabled: { panel($0) != nil },
                perform: { panel($0)?.focusMessage() }
            ),
            AppCommand(
                id: "wip.toggleAmend", title: "Toggle Amend", category: .commit,
                scopes: [.detail], defaultKeys: ["a"], icon: "pencil.circle",
                isEnabled: { context in
                    guard let panel = panel(context) else { return false }
                    return panel.mode == .workingCopy && context.controller?.refs.headCommit != nil
                },
                perform: { panel($0)?.toggleAmend() }
            ),
            AppCommand(
                id: "conflict.takeOurs", title: "Resolve with Ours", category: .operation,
                scopes: [.detail], defaultKeys: ["o"], icon: "arrow.left.circle",
                isEnabled: { selected($0, in: [.conflicts]) != nil },
                perform: { context in
                    guard let panel = panel(context), let file = selected(context, in: [.conflicts]) else { return }
                    Task { await panel.resolve(file, side: .ours) }
                }
            ),
            AppCommand(
                id: "conflict.takeTheirs", title: "Resolve with Theirs", category: .operation,
                scopes: [.detail], defaultKeys: ["t"], icon: "arrow.right.circle",
                isEnabled: { selected($0, in: [.conflicts]) != nil },
                perform: { context in
                    guard let panel = panel(context), let file = selected(context, in: [.conflicts]) else { return }
                    Task { await panel.resolve(file, side: .theirs) }
                }
            ),
        ]
    }
}

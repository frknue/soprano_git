import AppKit

/// The tab content without a repository: the New York "Soprano Git" hero, a
/// keyboard-navigable list of recent repositories, key hints, and any error
/// from the last open attempt (e.g. git missing).
@MainActor
final class WelcomeViewController: NSViewController, FocusRegionController, NSTableViewDataSource, NSTableViewDelegate {
    var onOpen: ((URL) -> Void)?
    var onOpenPanel: (() -> Void)?

    private let state: AppStateStore
    private var recents: [URL] = []
    private var theme: AppTheme

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let errorBox = NSView()
    private let errorMark = ChromeStatusMark(shape: .diamond)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var heading: ChromeEyebrowView!
    private let tableView = ListTableView()
    private var scrollView: NSScrollView!
    private let emptyLabel = NSTextField(labelWithString: "")
    private var hintsView: HintsView!
    private var tableHeight: NSLayoutConstraint!

    static let rowHeight: CGFloat = 40

    init(state: AppStateStore) {
        self.state = state
        self.theme = ThemeCenter.shared.theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var focusRegion: FocusRegion { .welcome }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(tableView)
        if tableView.selectedRow < 0, !recents.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// The error shown above the list (nil hides it).
    var errorMessage: String? {
        didSet { updateError() }
    }

    override func loadView() {
        // The theme may have changed between init and the first load.
        theme = ThemeCenter.shared.theme
        let root = NSView()
        root.wantsLayer = true

        heading = ChromeEyebrowView(title: "Recent", theme: theme)
        hintsView = HintsView(theme: theme)
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        errorBox.wantsLayer = true
        errorBox.layer?.cornerRadius = Chrome.Radius.card
        errorLabel.isSelectable = true
        for view in [errorMark, errorLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            errorBox.addSubview(view)
        }

        let column0 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repo"))
        tableView.addTableColumn(column0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClicked)
        ListStyle.apply(to: tableView, theme: theme, rowHeight: Self.rowHeight, surface: .base)
        scrollView = ListStyle.makeScrollView(documentView: tableView, theme: theme, surface: .base)

        for view in [titleLabel, subtitleLabel, errorBox, heading, scrollView, emptyLabel, hintsView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(view)
        }

        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -20),
            column.widthAnchor.constraint(equalToConstant: 600),
            column.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 24),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),

            titleLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: column.topAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),

            errorBox.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            errorBox.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            errorBox.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            errorMark.leadingAnchor.constraint(equalTo: errorBox.leadingAnchor, constant: 12),
            errorMark.topAnchor.constraint(equalTo: errorBox.topAnchor, constant: 15),
            errorLabel.leadingAnchor.constraint(equalTo: errorMark.trailingAnchor, constant: 10),
            errorLabel.trailingAnchor.constraint(equalTo: errorBox.trailingAnchor, constant: -12),
            errorLabel.topAnchor.constraint(equalTo: errorBox.topAnchor, constant: 10),
            errorLabel.bottomAnchor.constraint(equalTo: errorBox.bottomAnchor, constant: -10),

            heading.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            heading.topAnchor.constraint(equalTo: errorBox.bottomAnchor, constant: 24),
            scrollView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            tableHeight,
            emptyLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 16),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            hintsView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            hintsView.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 20),
            hintsView.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        view = root
        applyTheme()
        reloadRecents()

        ThemeCenter.shared.addObserver(self) { [weak self] theme in
            self?.theme = theme
            self?.applyTheme()
        }
        SettingsCenter.shared.addObserver(self) { [weak self] in
            self?.rebuildHints()
        }
    }

    private func applyTheme() {
        let colors = theme.colors
        view.layer?.backgroundColor = colors.bgBase.cgColor
        titleLabel.setChromeText("Soprano Git", font: ChromeFont.title, color: colors.textPrimary, tracking: -0.4)
        subtitleLabel.setChromeText("Keyboard-first Git · open a repository to begin", font: ChromeFont.row, color: colors.textMuted)
        heading.apply(theme: theme)
        ListStyle.apply(to: tableView, theme: theme, rowHeight: Self.rowHeight, surface: .base)
        ListStyle.applyScrollView(scrollView, theme: theme, surface: .base)
        emptyLabel.setChromeText("No recent repositories yet", font: ChromeFont.empty, color: colors.textMuted)
        errorBox.layer?.backgroundColor = colors.errorWash.cgColor
        errorMark.set(status: .error, colors: colors)
        errorLabel.font = ChromeFont.label
        errorLabel.textColor = colors.textPrimary
        tableView.reloadData()
        hintsView.apply(theme: theme)
        rebuildHints()
    }

    private func updateError() {
        guard isViewLoaded else { return }
        errorLabel.stringValue = errorMessage ?? ""
        errorBox.isHidden = errorMessage == nil
        errorBox.constraints.first { $0.firstAttribute == .height && $0.identifier == "collapsed" }?.isActive = false
        if errorMessage == nil {
            let collapse = errorBox.heightAnchor.constraint(equalToConstant: 0)
            collapse.identifier = "collapsed"
            collapse.isActive = true
        }
    }

    func reloadRecents() {
        recents = state.recentRepositories
        tableView.reloadData()
        let visibleRows = min(max(recents.count, 1), 8)
        tableHeight.constant = CGFloat(visibleRows) * 40
        emptyLabel.isHidden = !recents.isEmpty
        if !recents.isEmpty, tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateError()
    }

    /// The hint row: open, open selected, move, commands, shortcuts, each with
    /// its live K1 caps; unbound commands drop out.
    static func hints(settings: SettingsCenter) -> [HintsView.Hint] {
        let move = [settings.keycaps(for: "welcome.next"), settings.keycaps(for: "welcome.previous")].compactMap { $0 }
        let entries: [([[String]]?, String)] = [
            (settings.keycaps(for: "repo.open").map { [$0] }, "Open"),
            (settings.keycaps(for: "welcome.open").map { [$0] }, "Open Selected"),
            (move.isEmpty ? nil : move, "Move"),
            (settings.keycaps(for: "palette.open").map { [$0] }, "Commands"),
            (settings.keycaps(for: "help.shortcuts").map { [$0] }, "Shortcuts"),
        ]
        return entries.compactMap { caps, label in caps.map { HintsView.Hint(caps: $0, label: label) } }
    }

    /// The hints currently shown (tests).
    var hints: [HintsView.Hint] { hintsView?.hints ?? [] }

    private func rebuildHints() {
        hintsView.hints = Self.hints(settings: SettingsCenter.shared)
    }

    // MARK: - Keyboard (welcome.* commands)

    func moveSelection(by delta: Int) {
        guard !recents.isEmpty else { return }
        let current = tableView.selectedRow < 0 ? (delta > 0 ? -1 : recents.count) : tableView.selectedRow
        let next = min(max(0, current + delta), recents.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func openSelected() {
        let row = tableView.selectedRow
        if recents.indices.contains(row) {
            onOpen?(recents[row])
        } else {
            onOpenPanel?()
        }
    }

    @objc private func openClicked() {
        let row = tableView.clickedRow
        guard recents.indices.contains(row) else { return }
        onOpen?(recents[row])
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        recents.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        self.tableView.makeListRowView(row: row)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = recents[row]
        let cell = RecentRepositoryCell()
        let exists = FileManager.default.fileExists(atPath: url.path)
        cell.configure(
            name: url.lastPathComponent,
            path: SettingsFile.displayPath(for: url) + (exists ? "" : "  (missing)"),
            index: row < 9 ? row + 1 : nil,
            theme: theme,
            dimmed: !exists
        )
        return cell
    }
}

/// A recent repository: name (SF Pro 13) over its path (SF Mono 11 muted),
/// with the row's number as a trailing muted count (not a cap: no digit
/// opens a recent).
final class RecentRepositoryCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.lineBreakMode = .byTruncatingTail
        for view in [nameLabel, pathLabel, indexLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Clears the pencil tick (pill inset 4 + tick inset 4 + 2 wide).
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            indexLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(name: String, path: String, index: Int?, theme: AppTheme, dimmed: Bool) {
        let colors = theme.colors
        nameLabel.setChromeText(name, font: ChromeFont.row, color: dimmed ? colors.textMuted : colors.textPrimary)
        pathLabel.setChromeText(path, font: ChromeFont.monoSmall, color: colors.textMuted)
        indexLabel.setChromeText(index.map(String.init) ?? "", font: ChromeFont.count, color: colors.textMuted)
        indexLabel.isHidden = index == nil
    }

    /// The trailing row number, nil when hidden (tests).
    var indexText: String? { indexLabel.isHidden ? nil : indexLabel.stringValue }
}

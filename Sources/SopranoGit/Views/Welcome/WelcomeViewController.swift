import AppKit

/// The tab content without a repository: stripe + "SOPRANO GIT", a
/// keyboard-navigable list of recent repositories, key hints, and any error
/// from the last open attempt (e.g. git missing).
@MainActor
final class WelcomeViewController: NSViewController, FocusRegionController, NSTableViewDataSource, NSTableViewDelegate {
    var onOpen: ((URL) -> Void)?
    var onOpenPanel: (() -> Void)?

    private let state: AppStateStore
    private var recents: [URL] = []
    private var theme: AppTheme

    private let stripe = RetroStripeView(layout: .slanted)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let errorBox = NSView()
    private let errorLamp = NSView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var heading: RetroHeadingView!
    private let tableView = RetroTableView()
    private var scrollView: NSScrollView!
    private let emptyLabel = NSTextField(labelWithString: "")
    private let hintStack = NSStackView()
    private var tableHeight: NSLayoutConstraint!

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
        let root = NSView()
        root.wantsLayer = true

        heading = RetroHeadingView(title: "Recent Repositories", theme: theme)
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        errorBox.wantsLayer = true
        errorLamp.wantsLayer = true
        errorLamp.layer?.cornerRadius = 4
        errorLabel.font = RetroFont.body(12)
        errorLabel.isSelectable = true
        for view in [errorLamp, errorLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            errorBox.addSubview(view)
        }

        let column0 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repo"))
        tableView.addTableColumn(column0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClicked)
        RetroListStyle.apply(to: tableView, theme: theme, rowHeight: 40)
        scrollView = RetroListStyle.makeScrollView(documentView: tableView, theme: theme)

        for view in [stripe, titleLabel, subtitleLabel, errorBox, heading, scrollView, emptyLabel, hintStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(view)
        }
        hintStack.spacing = 14

        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -20),
            column.widthAnchor.constraint(equalToConstant: 600),
            column.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 24),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),

            stripe.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            stripe.topAnchor.constraint(equalTo: column.topAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 44),
            stripe.heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: stripe.centerYAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: stripe.bottomAnchor, constant: 12),

            errorBox.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            errorBox.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            errorBox.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            errorLamp.leadingAnchor.constraint(equalTo: errorBox.leadingAnchor, constant: 12),
            errorLamp.topAnchor.constraint(equalTo: errorBox.topAnchor, constant: 14),
            errorLamp.widthAnchor.constraint(equalToConstant: 8),
            errorLamp.heightAnchor.constraint(equalToConstant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: errorLamp.trailingAnchor, constant: 10),
            errorLabel.trailingAnchor.constraint(equalTo: errorBox.trailingAnchor, constant: -12),
            errorLabel.topAnchor.constraint(equalTo: errorBox.topAnchor, constant: 10),
            errorLabel.bottomAnchor.constraint(equalTo: errorBox.bottomAnchor, constant: -10),

            heading.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            heading.topAnchor.constraint(equalTo: errorBox.bottomAnchor, constant: 22),
            scrollView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            tableHeight,
            emptyLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 10),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            hintStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            hintStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 18),
            hintStack.bottomAnchor.constraint(equalTo: column.bottomAnchor),
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
        stripe.colors = colors.stripe
        titleLabel.setRetroText("Soprano Git", color: colors.accent, size: 22, glow: true)
        subtitleLabel.setRetroText("Keyboard-first Git · open a repository to begin", color: colors.textMuted)
        heading.apply(theme: theme)
        RetroListStyle.apply(to: tableView, theme: theme, rowHeight: 40)
        RetroListStyle.applyScrollView(scrollView, theme: theme)
        emptyLabel.setRetroText("No recent repositories yet", color: colors.textMuted)
        errorBox.layer?.backgroundColor = colors.bgRaised.cgColor
        errorBox.layer?.borderColor = colors.danger.cgColor
        errorBox.layer?.borderWidth = Retro.hairline
        RetroLamp.light(errorLamp, color: colors.danger)
        errorLabel.textColor = colors.textPrimary
        tableView.reloadData()
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

    private func rebuildHints() {
        hintStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let settings = SettingsCenter.shared
        let hints: [(String?, String)] = [
            (settings.keycapText(for: "repo.open"), "Open"),
            ("↵", "Open Selected"),
            ("J K", "Move"),
            (settings.keycapText(for: "palette.open"), "Commands"),
            (settings.keycapText(for: "help.shortcuts"), "Shortcuts"),
        ]
        for (key, label) in hints {
            guard let key else { continue }
            let keycap = KeycapView(text: key, theme: theme)
            let text = NSTextField(labelWithString: "")
            text.setRetroText(label, color: theme.colors.textMuted)
            let pair = NSStackView(views: [keycap, text])
            pair.spacing = 6
            hintStack.addArrangedSubview(pair)
        }
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
        self.tableView.makeRetroRowView(row: row)
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

private final class RecentRepositoryCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let numberLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.lineBreakMode = .byTruncatingTail
        for view in [numberLabel, nameLabel, pathLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(name: String, path: String, index: Int?, theme: AppTheme, dimmed: Bool) {
        let colors = theme.colors
        nameLabel.setRetroText(name, color: dimmed ? colors.textMuted : colors.textPrimary)
        pathLabel.stringValue = path
        pathLabel.font = RetroFont.body(11)
        pathLabel.textColor = colors.textMuted
        numberLabel.setRetroText(index.map(String.init) ?? "", color: colors.textMuted)
    }
}

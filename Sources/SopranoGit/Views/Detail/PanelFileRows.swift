import AppKit
import SopranoGitCore

/// File-list mouse selection. Modified clicks only build the selection; an
/// unmodified click opens its diff. Keyboard selection remains AppKit-owned.
final class PanelFileTableView: ListTableView {
    var onOpenRow: ((Int) -> Void)?
    private var rangeAnchor: Int?

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, delegate?.tableView?(self, shouldSelectRow: row) ?? true else { return }
        window?.makeFirstResponder(self)
        let toggles = !event.modifierFlags.intersection([.control, .command]).isEmpty
        if event.modifierFlags.contains(.shift) {
            let anchor = rangeAnchor ?? (selectedRow >= 0 ? selectedRow : row)
            var proposed = IndexSet(integersIn: min(anchor, row)...max(anchor, row))
            if toggles { proposed.formUnion(selectedRowIndexes) }
            let allowed = delegate?.tableView?(self, selectionIndexesForProposedSelection: proposed) ?? proposed
            selectRowIndexes(allowed, byExtendingSelection: false)
        } else if toggles {
            if selectedRowIndexes.contains(row) {
                deselectRow(row)
            } else {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
            }
            rangeAnchor = row
        } else {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            onOpenRow?(row)
        }
    }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
        if !extend, indexes.count == 1 { rangeAnchor = indexes.first }
    }

    override func reloadData() {
        rangeAnchor = nil
        super.reloadData()
    }
}

/// A button a file row or section heading offers (stage, discard, ours, …).
struct PanelRowAction {
    var title: String
    /// Command whose keycaps the button shows.
    var commandID: String
    var kind: KeyHintButton.Kind = .standard
    var perform: @MainActor () -> Void
}

/// File row: bare kind letter, path in SF Mono (directory muted, name
/// Semibold, shortened at a path component), the diffstat, and action keys
/// that show while the row is hovered or selected.
final class PanelFileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PanelFileCell")
    static let rowHeight: CGFloat = 26
    /// Content inset from the row edge: the 4 pt pill margin plus 8 pt padding.
    static let inset: CGFloat = 12

    private let badge: ChangeKindBadge
    private let pathLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private var actions: [PanelRowAction] = []
    private var hoverArea: NSTrackingArea?
    private var theme: AppTheme
    private var file: PanelFile?
    /// Width the path was last shortened for; nil forces a rebuild.
    private var pathWidth: CGFloat?
    /// The path ends before the detail text, or before the action keys while they show.
    private var pathBeforeDetail: NSLayoutConstraint!
    private var pathBeforeActions: NSLayoutConstraint!

    private(set) var isHovered = false {
        didSet { if oldValue != isHovered { updateActionVisibility() } }
    }

    var isRowSelected = false {
        didSet { if oldValue != isRowSelected { updateActionVisibility() } }
    }

    /// Whether the action keys are showing (hovered or selected row).
    var showsActions: Bool { !actionStack.isHidden }
    var actionTitles: [String] { actions.map(\.title) }
    /// The path as displayed, after shortening.
    var displayedPath: String { pathLabel.stringValue }

    init(theme: AppTheme) {
        self.theme = theme
        badge = ChangeKindBadge(kind: .modified, theme: theme)
        super.init(frame: .zero)
        identifier = Self.identifier
        badge.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.setContentHuggingPriority(.required, for: .horizontal)
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [badge, pathLabel, detailLabel, actionStack] as [NSView] {
            addSubview(view)
        }
        pathBeforeDetail = detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: 8)
        pathBeforeActions = actionStack.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.inset),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathBeforeDetail,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(file: PanelFile, actions: [PanelRowAction], theme: AppTheme, selected: Bool) {
        self.theme = theme
        self.actions = actions
        self.file = file
        let colors = theme.colors
        badge.apply(theme: theme)
        badge.kind = file.kind
        pathWidth = nil
        updatePath()
        pathLabel.toolTip = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        if let conflict = file.conflict {
            detailLabel.attributedStringValue = NSAttributedString(
                string: Self.describe(conflict),
                attributes: [.font: ChromeFont.meta, .foregroundColor: colors.danger]
            )
        } else if file.section == .files {
            detailLabel.attributedStringValue = PanelText.counts(additions: file.additions, deletions: file.deletions, colors: colors)
        } else if file.isUntracked {
            detailLabel.attributedStringValue = NSAttributedString(
                string: "new",
                attributes: [.font: ChromeFont.meta, .foregroundColor: colors.textMuted]
            )
        } else {
            detailLabel.attributedStringValue = NSAttributedString()
        }
        for view in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, action) in actions.enumerated() {
            let button = KeyHintButton(
                title: action.title,
                hint: SettingsCenter.shared.keycaps(for: action.commandID),
                theme: theme,
                kind: action.kind
            )
            button.tag = index
            button.target = self
            button.action = #selector(runAction(_:))
            button.toolTip = action.title
            actionStack.addArrangedSubview(button)
        }
        isRowSelected = selected
        updateActionVisibility()
    }

    static func describe(_ conflict: ConflictKind) -> String {
        switch conflict {
        case .bothModified: "both modified"
        case .bothAdded: "both added"
        case .bothDeleted: "both deleted"
        case .addedByUs: "added by us"
        case .addedByThem: "added by them"
        case .deletedByUs: "deleted by us"
        case .deletedByThem: "deleted by them"
        }
    }

    @objc private func runAction(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].perform()
    }

    private func updateActionVisibility() {
        let show = !actions.isEmpty && (isHovered || isRowSelected)
        actionStack.isHidden = !show
        detailLabel.isHidden = show
        pathBeforeDetail.isActive = !show
        pathBeforeActions.isActive = show
        needsLayout = true
    }

    /// Room for the path between the kind letter and the trailing detail or
    /// actions, less the label cell's own text insets.
    private var availablePathWidth: CGFloat? {
        guard bounds.width > 0 else { return nil }
        let end: CGFloat
        if !actionStack.isHidden {
            end = bounds.width - Self.inset - actionStack.fittingSize.width - 8
        } else if detailLabel.attributedStringValue.length > 0 {
            end = bounds.width - Self.inset - detailLabel.intrinsicContentSize.width - 8
        } else {
            end = bounds.width - Self.inset
        }
        let start = Self.inset + badge.intrinsicContentSize.width + 8
        return max(0, floor(end - start) - 4)
    }

    private func updatePath() {
        guard let file else { return }
        let width = availablePathWidth
        guard width == nil || width != pathWidth else { return }
        pathWidth = width
        pathLabel.attributedStringValue = PanelText.path(file.path, oldPath: file.oldPath, colors: theme.colors, availableWidth: width)
    }

    override func layout() {
        updatePath()
        super.layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }
}

/// Section heading: an eyebrow with its count, no rule, and always-visible
/// plain actions whose keycaps hide when space is tight.
final class PanelSectionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PanelSectionCell")
    /// Space above the 28 pt heading that separates it from the rows before.
    static let topMargin: CGFloat = 6
    static let headingHeight: CGFloat = 28
    static let rowHeight: CGFloat = topMargin + headingHeight

    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private var buttons: [KeyHintButton] = []
    private var actions: [PanelRowAction] = []
    private var fullActionWidth: CGFloat = 0

    /// The heading as shown: `UNSTAGED 2`.
    var headingText: String { "\(titleLabel.stringValue) \(countLabel.stringValue)" }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        for label in [titleLabel, countLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        actionStack.orientation = .horizontal
        actionStack.spacing = 2
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.setHuggingPriority(.required, for: .horizontal)
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(actionStack)
        let headingCenter = centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor, constant: -Self.topMargin / 2)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headingCenter,
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            actionStack.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 8),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(section: PanelSection, count: Int, actions: [PanelRowAction], theme: AppTheme) {
        let colors = theme.colors
        let tint = section == .conflicts ? colors.danger : colors.textMuted
        titleLabel.setEyebrowText(section.title, color: tint)
        countLabel.setChromeText("\(count)", font: ChromeFont.count, color: tint)
        for button in buttons {
            actionStack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons.removeAll(keepingCapacity: true)
        self.actions = actions
        fullActionWidth = 0
        for (index, action) in actions.enumerated() {
            let button = KeyHintButton(
                title: action.title,
                hint: SettingsCenter.shared.keycaps(for: action.commandID),
                theme: theme,
                kind: action.kind == .standard ? .text : action.kind
            )
            button.isPlain = true
            button.tag = index
            button.target = self
            button.action = #selector(runAction(_:))
            button.setAccessibilityLabel(action.title)
            button.toolTip = action.title
            actionStack.addArrangedSubview(button)
            if index > 0 { fullActionWidth += actionStack.spacing }
            fullActionWidth += button.intrinsicContentSize.width
            buttons.append(button)
        }
        updateHints()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateHints()
    }

    private func updateHints() {
        let heading = titleLabel.intrinsicContentSize.width + 8 + countLabel.intrinsicContentSize.width
        let showHints = fullActionWidth + heading + 36 <= bounds.width
        for (button, action) in zip(buttons, actions) {
            let hint = showHints ? SettingsCenter.shared.keycaps(for: action.commandID) : nil
            if button.hint != hint { button.hint = hint }
        }
    }

    @objc private func runAction(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].perform()
    }
}

import AppKit
import SopranoGitCore

/// A button a file row or section heading offers (stage, discard, ours, …).
struct PanelRowAction {
    var title: String
    /// Command whose chord the keycap shows.
    var commandID: String
    var kind: KeyHintButton.Kind = .standard
    var perform: @MainActor () -> Void
}

/// File row: kind badge, path (directory muted, name bright), `+a −d`, and
/// action keys that show while the row is hovered or selected.
final class PanelFileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PanelFileCell")
    static let rowHeight: CGFloat = 26

    private let badge: ChangeKindBadge
    private let pathLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private var actions: [PanelRowAction] = []
    private var hoverArea: NSTrackingArea?
    private var theme: AppTheme
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
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathBeforeDetail,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(file: PanelFile, actions: [PanelRowAction], theme: AppTheme, selected: Bool) {
        self.theme = theme
        self.actions = actions
        let colors = theme.colors
        badge.apply(theme: theme)
        badge.kind = file.kind
        pathLabel.attributedStringValue = PanelText.path(file.path, oldPath: file.oldPath, colors: colors)
        pathLabel.toolTip = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        if let conflict = file.conflict {
            detailLabel.attributedStringValue = NSAttributedString(
                string: Self.describe(conflict),
                attributes: [.font: RetroFont.body(11), .foregroundColor: colors.danger]
            )
        } else if file.section == .files {
            detailLabel.attributedStringValue = PanelText.counts(additions: file.additions, deletions: file.deletions, colors: colors)
        } else if file.isUntracked {
            detailLabel.attributedStringValue = NSAttributedString(
                string: "new",
                attributes: [.font: RetroFont.body(11), .foregroundColor: colors.textMuted]
            )
        } else {
            detailLabel.attributedStringValue = NSAttributedString()
        }
        for view in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, action) in actions.enumerated() {
            let button = KeyHintButton(title: action.title, hint: PanelText.keycap(action.commandID), theme: theme, kind: action.kind)
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

/// Section heading row: `UNSTAGED (3) ────── [STAGE ALL ⌘⇧S]`.
final class PanelSectionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PanelSectionCell")
    static let rowHeight: CGFloat = 30

    private let titleLabel = NSTextField(labelWithString: "")
    private let rule = RetroRuleView(axis: .horizontal, style: .single)
    private var button: KeyHintButton?
    private var action: PanelRowAction?
    private var ruleTrailing: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(titleLabel)
        addSubview(rule)
        ruleTrailing = rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            rule.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            rule.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: Retro.hairline),
            ruleTrailing,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var buttonTitle: String? { button?.title }

    func configure(section: PanelSection, count: Int, action: PanelRowAction?, theme: AppTheme) {
        let colors = theme.colors
        let tint = section == .conflicts ? colors.danger : colors.textMuted
        titleLabel.setRetroText("\(section.title) (\(count))", color: tint)
        rule.color = section == .conflicts ? colors.danger.withAlphaComponent(0.5) : colors.borderSubtle
        button?.removeFromSuperview()
        button = nil
        self.action = action
        ruleTrailing.isActive = false
        if let action {
            let key = KeyHintButton(title: action.title, hint: PanelText.keycap(action.commandID), theme: theme, kind: action.kind)
            key.target = self
            key.action = #selector(runAction)
            addSubview(key)
            ruleTrailing = rule.trailingAnchor.constraint(equalTo: key.leadingAnchor, constant: -8)
            NSLayoutConstraint.activate([
                key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                key.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                ruleTrailing,
            ])
            button = key
        } else {
            ruleTrailing = rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
            ruleTrailing.isActive = true
        }
    }

    @objc private func runAction() {
        action?.perform()
    }
}

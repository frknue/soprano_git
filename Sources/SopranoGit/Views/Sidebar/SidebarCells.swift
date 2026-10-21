import AppKit
import SopranoGitCore

/// One ref-tree row. Sections: chevron, eyebrow title and a tabular count, no rule.
/// Groups and leaves: chevron (or a 12 pt spacer), SF Symbol, SF Pro 12 title and a
/// right-aligned detail (ahead/behind, `gone`, stash date). The checked-out branch shows
/// an ink checkmark and a Semibold title. The cell indents itself by tree level.
final class SidebarCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
    /// Leading padding of the row content.
    static let leadingPadding: CGFloat = 8
    /// Extra indent of level-1 rows, then per further level.
    static let firstLevelIndent: CGFloat = 4
    static let indentPerLevel: CGFloat = 18
    /// Chevron slot; leaves keep it as a spacer.
    static let disclosureWidth: CGFloat = 12
    static let gap: CGFloat = 6
    static let trailingPadding: CGFloat = 12
    /// Height of the row content; taller section rows carry their top margin above it.
    static let contentHeight: CGFloat = 24

    private let disclosure = NSButton()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var disclosureLeading: NSLayoutConstraint!
    /// Leaves and groups: icon, title, detail at the trailing edge.
    private var rowConstraints: [NSLayoutConstraint] = []
    /// Sections: `LOCAL 3`, count right after the title.
    private var sectionConstraints: [NSLayoutConstraint] = []
    private var colors: ThemeColors?
    private var isGroup = false

    /// Expands or collapses the row's group (chevron click).
    var onToggle: (() -> Void)?

    /// The row's displayed title and detail, for tests.
    var titleText: String { titleLabel.stringValue }
    var detailText: String { detailLabel.stringValue }
    /// The row's SF Symbol name, for tests (nil on sections).
    private(set) var iconName: String?
    /// Whether the chevron points down.
    private(set) var isExpanded = false
    /// The chevron button (tests press it).
    var disclosureButton: NSButton { disclosure }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyDown
        disclosure.isBordered = false
        disclosure.bezelStyle = .regularSquare
        disclosure.imagePosition = .imageOnly
        disclosure.imageScaling = .scaleProportionallyDown
        disclosure.focusRingType = .none
        disclosure.refusesFirstResponder = true
        disclosure.target = self
        disclosure.action = #selector(disclosureClicked)
        for label in [titleLabel, detailLabel] {
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.cell?.wraps = false
            label.lineBreakMode = .byTruncatingTail
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailLabel.alignment = .right
        detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        for view in [disclosure, icon, titleLabel, detailLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = titleLabel
        imageView = icon
        let centerOffset = -Self.contentHeight / 2
        disclosureLeading = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPadding)
        NSLayoutConstraint.activate([
            disclosureLeading,
            disclosure.widthAnchor.constraint(equalToConstant: Self.disclosureWidth),
            disclosure.heightAnchor.constraint(equalToConstant: Self.disclosureWidth),
            disclosure.centerYAnchor.constraint(equalTo: bottomAnchor, constant: centerOffset),
            icon.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: Self.gap),
            icon.centerYAnchor.constraint(equalTo: bottomAnchor, constant: centerOffset),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: bottomAnchor, constant: centerOffset),
            detailLabel.centerYAnchor.constraint(equalTo: bottomAnchor, constant: centerOffset),
        ])
        rowConstraints = [
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.gap),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingPadding),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: Self.gap),
        ]
        sectionConstraints = [
            titleLabel.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: Self.gap),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: Self.gap),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingPadding),
        ]
        NSLayoutConstraint.activate(rowConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Leading x of a row's chevron slot at outline `level` (sections are level 0).
    static func indent(level: Int) -> CGFloat {
        leadingPadding + (level > 0 ? firstLevelIndent + CGFloat(level - 1) * indentPerLevel : 0)
    }

    func configure(_ node: SidebarNode, level: Int, isExpanded: Bool, theme: AppTheme) {
        let colors = theme.colors
        self.colors = colors
        toolTip = nil
        iconName = nil
        isGroup = node.isGroup
        detailLabel.attributedStringValue = NSAttributedString()
        disclosureLeading.constant = Self.indent(level: level)
        var isSection = false

        switch node.kind {
        case let .section(_, count):
            isSection = true
            titleLabel.setEyebrowText(node.title, color: colors.textMuted)
            detailLabel.setChromeText("\(count)", font: ChromeFont.count, color: colors.textMuted)
        case .remote:
            setIcon("cloud", color: colors.textMuted)
            titleLabel.setChromeText(node.title, color: colors.textPrimary)
        case .folder:
            setIcon("folder", color: colors.textMuted)
            titleLabel.setChromeText(node.title, color: colors.textPrimary)
        case let .branch(branch):
            if branch.isHead {
                setIcon("checkmark", color: colors.textPrimary)
                titleLabel.setChromeText(node.title, font: ChromeFont.sans(size: 12, weight: .semibold), color: colors.textPrimary)
            } else {
                setIcon("arrow.triangle.branch", color: colors.textMuted)
                titleLabel.setChromeText(node.title, color: colors.textPrimary)
            }
            detailLabel.attributedStringValue = Self.trackingText(for: branch, colors: colors)
            toolTip = branch.upstream.map { "\(branch.name) → \($0)" } ?? branch.name
        case let .tag(tag):
            setIcon("tag", color: colors.textMuted)
            titleLabel.setChromeText(node.title, color: colors.textPrimary)
            toolTip = tag.message.flatMap { $0.isEmpty ? nil : $0 } ?? tag.name
        case let .stash(stash):
            setIcon("tray.and.arrow.down", color: colors.textMuted)
            titleLabel.setChromeText(stash.message, color: colors.textPrimary)
            detailLabel.setChromeText(DateText.format(stash.date, style: .relative), font: ChromeFont.count, color: colors.textMuted)
            toolTip = "\(stash.reference): \(stash.message)"
        }

        icon.isHidden = isSection
        disclosure.isHidden = !node.isGroup
        setExpanded(isExpanded)
        if isSection {
            NSLayoutConstraint.deactivate(rowConstraints)
            NSLayoutConstraint.activate(sectionConstraints)
        } else {
            NSLayoutConstraint.deactivate(sectionConstraints)
            NSLayoutConstraint.activate(rowConstraints)
        }
        titleLabel.setContentHuggingPriority(isSection ? .required : .defaultHigh, for: .horizontal)
    }

    /// Points the chevron down (expanded) or right.
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        guard isGroup, let colors else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colors.textMuted]))
        disclosure.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanded ? "Collapse" : "Expand"
        )?.withSymbolConfiguration(configuration)
    }

    /// `↑2 ↓1` in SF Pro 11 tabular (behind in yellow), or a muted `gone` when the
    /// upstream vanished.
    static func trackingText(for branch: Branch, colors: ThemeColors) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func append(_ text: String, _ color: NSColor) {
            result.append(ChromeText.attributed(text, font: ChromeFont.count, color: color))
        }
        if branch.upstreamGone {
            append("gone", colors.textMuted)
            return result
        }
        if branch.ahead > 0 {
            append("↑\(branch.ahead)", colors.textMuted)
        }
        if branch.behind > 0 {
            if result.length > 0 { append(" ", colors.textMuted) }
            append("↓\(branch.behind)", colors.yellow)
        }
        return result
    }

    @objc private func disclosureClicked() {
        onToggle?()
    }

    private func setIcon(_ symbol: String, color: NSColor) {
        iconName = symbol
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        icon.contentTintColor = color
    }
}

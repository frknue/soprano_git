import AppKit
import SopranoGitCore

/// One ref-tree row: section headings (`LOCAL 3 ───`), remote/folder groups,
/// and branch/tag/stash leaves with icon, display-face name, HEAD lamp and a
/// right-aligned detail (ahead/behind, `gone`, stash date).
final class SidebarCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
    static let lampSize: CGFloat = 6

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let lamp = NSView()
    private let rule = RetroRuleView(axis: .horizontal, style: .single)
    private var titleAfterIcon: NSLayoutConstraint!
    private var titleAtLeading: NSLayoutConstraint!
    /// Leaves and groups: detail at the trailing edge.
    private var rowConstraints: [NSLayoutConstraint] = []
    /// Sections: `LOCAL 3 ────`, count right after the title, rule to the edge.
    private var sectionConstraints: [NSLayoutConstraint] = []

    /// The row's displayed title and detail, for tests.
    var titleText: String { titleLabel.stringValue }
    var detailText: String { detailLabel.stringValue }
    var isLampVisible: Bool { !lamp.isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyDown
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
        lamp.wantsLayer = true
        lamp.layer?.cornerRadius = Self.lampSize / 2
        for view in [icon, titleLabel, detailLabel, lamp, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = titleLabel
        imageView = icon
        titleAfterIcon = titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        titleAtLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            lamp.widthAnchor.constraint(equalToConstant: Self.lampSize),
            lamp.heightAnchor.constraint(equalToConstant: Self.lampSize),
            lamp.centerYAnchor.constraint(equalTo: centerYAnchor),
            lamp.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: Retro.hairline),
        ])
        rowConstraints = [
            titleAfterIcon,
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: lamp.trailingAnchor, constant: 6),
        ]
        sectionConstraints = [
            titleAtLeading,
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            rule.leadingAnchor.constraint(equalTo: detailLabel.trailingAnchor, constant: 8),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ]
        NSLayoutConstraint.activate(rowConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ node: SidebarNode, theme: AppTheme) {
        let colors = theme.colors
        toolTip = nil
        lamp.isHidden = true
        rule.isHidden = true
        icon.isHidden = false
        detailLabel.attributedStringValue = NSAttributedString()
        var isSection = false

        switch node.kind {
        case let .section(_, count):
            isSection = true
            titleLabel.setRetroText(node.title, color: colors.textMuted)
            detailLabel.attributedStringValue = RetroText.display("\(count)", color: colors.textMuted)
            rule.isHidden = false
            rule.color = colors.borderStrong
        case .remote:
            setIcon("cloud", color: colors.textMuted)
            titleLabel.setRetroText(node.title, color: colors.textPrimary)
        case .folder:
            setIcon("folder", color: colors.textMuted)
            titleLabel.setRetroText(node.title, color: colors.textPrimary)
        case let .branch(branch):
            setIcon("arrow.triangle.branch", color: branch.isHead ? colors.accent : colors.textMuted)
            titleLabel.setRetroText(node.title, color: branch.isHead ? colors.accent : colors.textPrimary, glow: branch.isHead)
            if branch.isHead {
                lamp.isHidden = false
                RetroLamp.light(lamp, color: colors.accent)
            }
            detailLabel.attributedStringValue = Self.trackingText(for: branch, colors: colors)
            toolTip = branch.upstream.map { "\(branch.name) → \($0)" } ?? branch.name
        case let .tag(tag):
            setIcon("tag", color: colors.textMuted)
            titleLabel.setRetroText(node.title, color: colors.textPrimary)
            toolTip = tag.message.flatMap { $0.isEmpty ? nil : $0 } ?? tag.name
        case let .stash(stash):
            setIcon("tray.and.arrow.down", color: colors.textMuted)
            titleLabel.attributedStringValue = NSAttributedString(
                string: stash.message,
                attributes: [.font: RetroFont.body(11), .foregroundColor: colors.textPrimary, .paragraphStyle: Self.truncating]
            )
            detailLabel.attributedStringValue = NSAttributedString(
                string: DateText.format(stash.date, style: .relative),
                attributes: [.font: RetroFont.body(11), .foregroundColor: colors.textMuted, .paragraphStyle: Self.truncating]
            )
            toolTip = "\(stash.reference): \(stash.message)"
        }

        icon.isHidden = isSection
        if isSection {
            NSLayoutConstraint.deactivate(rowConstraints)
            NSLayoutConstraint.activate(sectionConstraints)
        } else {
            NSLayoutConstraint.deactivate(sectionConstraints)
            NSLayoutConstraint.activate(rowConstraints)
        }
        titleLabel.setContentHuggingPriority(isSection ? .required : .defaultHigh, for: .horizontal)
    }

    /// `↑2 ↓1` (behind in yellow), or `gone` when the upstream vanished.
    static func trackingText(for branch: Branch, colors: ThemeColors) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if branch.upstreamGone {
            result.append(RetroText.display("gone", color: colors.danger))
            return result
        }
        if branch.ahead > 0 {
            result.append(RetroText.display("↑\(branch.ahead)", color: colors.textMuted))
        }
        if branch.behind > 0 {
            if result.length > 0 { result.append(RetroText.display(" ", color: colors.textMuted)) }
            result.append(RetroText.display("↓\(branch.behind)", color: colors.yellow))
        }
        return result
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private func setIcon(_ symbol: String, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        icon.contentTintColor = color
    }
}

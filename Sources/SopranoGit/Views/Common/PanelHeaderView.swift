import AppKit

/// A region header (`.panel-header`): an eyebrow title, an optional count or
/// detail after it, and trailing accessories over a bottom hairline. While
/// the region holds focus the header is raised, the title turns ink, and the
/// 2 pt accent focus rule sits on its bottom edge.
final class PanelHeaderView: NSView {
    static let height: CGFloat = 28

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let accessoryStack = NSStackView()
    private let bottomRule = ChromeRuleView(axis: .horizontal)
    private let focusRule = ChromeRuleView(axis: .horizontal, thickness: Chrome.focusMarkWidth)
    private var theme: AppTheme

    var title: String {
        didSet { restyle() }
    }

    /// How `detail` reads: a muted tabular count, or an ink SF Mono SHA
    /// (`COMMIT d78be48`).
    enum DetailStyle {
        case count
        case sha
    }

    var detailStyle: DetailStyle = .count {
        didSet { restyle() }
    }

    var detail: String? {
        didSet { restyle() }
    }

    var isFocused = false {
        didSet { restyle() }
    }

    /// Whether the focus rule shows (tests).
    var showsFocusRule: Bool { !focusRule.isHidden }

    init(title: String, theme: AppTheme) {
        self.title = title
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        wantsLayer = true
        for label in [titleLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        accessoryStack.orientation = .horizontal
        accessoryStack.spacing = 8
        accessoryStack.alignment = .centerY
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(accessoryStack)
        for rule in [bottomRule, focusRule] {
            rule.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rule)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomRule.heightAnchor.constraint(equalToConstant: Chrome.hairline),
            focusRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            focusRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            focusRule.heightAnchor.constraint(equalToConstant: Chrome.focusMarkWidth),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.bar),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryStack.leadingAnchor.constraint(greaterThanOrEqualTo: detailLabel.trailingAnchor, constant: 8),
            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accessoryStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var accessoryViews: [NSView] { accessoryStack.arrangedSubviews }

    func setAccessoryViews(_ views: [NSView]) {
        for view in accessoryStack.arrangedSubviews {
            accessoryStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        views.forEach { accessoryStack.addArrangedSubview($0) }
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        restyle()
    }

    private func restyle() {
        let colors = theme.colors
        layer?.backgroundColor = (isFocused ? colors.raised : colors.bgPanel).cgColor
        bottomRule.color = colors.borderSubtle
        focusRule.color = colors.focusMark
        focusRule.isHidden = !isFocused
        titleLabel.setEyebrowText(title, color: isFocused ? colors.textPrimary : colors.textMuted)
        detailLabel.isHidden = detail == nil
        switch detailStyle {
        case .count:
            detailLabel.setChromeText(detail ?? "", font: ChromeFont.count, color: colors.textMuted)
        case .sha:
            detailLabel.setChromeText(detail ?? "", font: ChromeFont.monoSmall, color: colors.textPrimary)
        }
    }
}

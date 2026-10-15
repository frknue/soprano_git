import AppKit

/// A panel header after Soprano's PaneHeaderView: display-face title, an
/// optional count/detail after it, trailing accessories, and a 4pt accent
/// focus bar on a raised fill while the panel holds focus.
final class PanelHeaderView: NSView {
    static let height: CGFloat = 28
    static let focusBarWidth: CGFloat = 4

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let accessoryStack = NSStackView()
    private let focusBar = NSView()
    private let bottomRule = NSView()
    private var theme: AppTheme

    var title: String {
        didSet { restyle() }
    }

    var detail: String? {
        didSet { restyle() }
    }

    var isFocused = false {
        didSet { restyle() }
    }

    init(title: String, theme: AppTheme) {
        self.title = title
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        wantsLayer = true
        for view in [focusBar, bottomRule] {
            view.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for label in [titleLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        accessoryStack.orientation = .horizontal
        accessoryStack.spacing = 6
        accessoryStack.alignment = .centerY
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(accessoryStack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            focusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusBar.topAnchor.constraint(equalTo: topAnchor),
            focusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            focusBar.widthAnchor.constraint(equalToConstant: Self.focusBarWidth),
            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomRule.heightAnchor.constraint(equalToConstant: 1),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
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
        layer?.backgroundColor = (isFocused ? colors.bgRaised : colors.bgPanel).cgColor
        focusBar.isHidden = !isFocused
        focusBar.layer?.backgroundColor = colors.accent.cgColor
        bottomRule.layer?.backgroundColor = colors.borderSubtle.cgColor
        titleLabel.setRetroText(title, color: isFocused ? colors.textPrimary : colors.textMuted, size: 11)
        detailLabel.isHidden = detail == nil
        detailLabel.setRetroText(detail ?? "", color: colors.textMuted, size: 11)
    }
}

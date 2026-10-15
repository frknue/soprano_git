import AppKit

/// A keycap chip like the command palette's: display face 11 on a square
/// chip with a 1pt edge. Lit chips glow accent; `isOnAccent` chips sit on an
/// accent row with a transparent fill.
final class KeycapView: NSView {
    static let height: CGFloat = 16
    static let padding: CGFloat = 5

    private let label = NSTextField(labelWithString: "")
    private var theme: AppTheme

    var text: String {
        didSet { restyle() }
    }

    var isLit = false {
        didSet { restyle() }
    }

    var isOnAccent = false {
        didSet { restyle() }
    }

    init(text: String, theme: AppTheme) {
        self.text = text
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byClipping
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(theme: AppTheme) {
        self.theme = theme
        restyle()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + Self.padding * 2, height: Self.height)
    }

    var fillColor: NSColor {
        if isOnAccent { return .clear }
        return isLit ? theme.colors.accent : theme.colors.bgRaised
    }

    var inkColor: NSColor {
        isOnAccent || isLit ? theme.colors.bgPanel : theme.colors.textMuted
    }

    var edgeColor: NSColor {
        if isOnAccent { return theme.colors.bgPanel }
        return isLit ? theme.colors.accent : theme.colors.borderSubtle
    }

    private func restyle() {
        label.setRetroText(text, color: inkColor, size: 11)
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = edgeColor.cgColor
        invalidateIntrinsicContentSize()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

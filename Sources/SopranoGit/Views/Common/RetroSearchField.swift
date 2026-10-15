import AppKit

/// A search/filter input: a raised square box with a strong hairline, a
/// muted `❯` prompt, a borderless body-face field, and an optional keycap hint.
final class RetroSearchField: NSView {
    static let height: CGFloat = 26

    let field = NSTextField()
    private let prompt = NSTextField(labelWithString: "❯")
    private(set) var hintView: KeycapView?
    private var theme: AppTheme

    var placeholder: String {
        didSet { restyle() }
    }

    init(placeholder: String, theme: AppTheme, hint: String? = nil) {
        self.placeholder = placeholder
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        wantsLayer = true
        prompt.translatesAutoresizingMaskIntoConstraints = false
        prompt.setContentHuggingPriority(.required, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = RetroFont.body(12)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        addSubview(prompt)
        addSubview(field)
        var constraints = [
            heightAnchor.constraint(equalToConstant: Self.height),
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            prompt.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let hint {
            let keycap = KeycapView(text: hint, theme: theme)
            keycap.translatesAutoresizingMaskIntoConstraints = false
            addSubview(keycap)
            hintView = keycap
            constraints += [
                keycap.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
                keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        } else {
            constraints.append(field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8))
        }
        NSLayoutConstraint.activate(constraints)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(theme: AppTheme) {
        self.theme = theme
        hintView?.apply(theme: theme)
        restyle()
    }

    private func restyle() {
        let colors = theme.colors
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
        layer?.backgroundColor = colors.bgRaised.cgColor
        layer?.borderColor = colors.borderStrong.cgColor
        prompt.attributedStringValue = NSAttributedString(
            string: "❯",
            attributes: [.font: RetroFont.body(12), .foregroundColor: colors.textMuted]
        )
        field.textColor = colors.textPrimary
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: RetroFont.body(12), .foregroundColor: colors.textMuted]
        )
        (field.currentEditor() as? NSTextView)?.insertionPointColor = colors.accent
    }
}

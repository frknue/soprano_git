import AppKit

/// A search/filter input (`.search-field`): a raised 26 pt field with a
/// 6 pt radius and a borderStrong edge (the focus edge while editing), a
/// muted magnifying glass, SF Pro 12 text, and an optional small keycap hint.
final class SearchField: NSView {
    static let height: CGFloat = Chrome.fieldHeight

    let field: NSTextField = FocusReportingTextField()
    private let surface: ChromeFieldView
    private let icon = NSImageView()
    private(set) var hintView: ChromeKeycapView?
    private var theme: AppTheme

    var placeholder: String {
        didSet { restyle() }
    }

    init(placeholder: String, theme: AppTheme, hint: String? = nil) {
        self.placeholder = placeholder
        self.theme = theme
        surface = ChromeFieldView(theme: theme)
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        (field as? FocusReportingTextField)?.onFocusChange = { [weak self] focused in
            guard let self else { return }
            surface.isFocused = focused
            if focused { ChromeFieldView.styleEditor(of: field, colors: self.theme.colors) }
        }
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        addSubview(surface)
        addSubview(icon)
        addSubview(field)
        var constraints = [
            heightAnchor.constraint(equalToConstant: Self.height),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let hint {
            let keycap = ChromeKeycapView(legend: hint, theme: theme, style: .small, tone: .muted)
            keycap.translatesAutoresizingMaskIntoConstraints = false
            keycap.setContentHuggingPriority(.required, for: .horizontal)
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
        surface.apply(theme: theme)
        hintView?.apply(theme: theme)
        restyle()
    }

    private func restyle() {
        let colors = theme.colors
        ChromeFieldView.styleEmbedded(field, colors: colors)
        icon.contentTintColor = colors.textMuted
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: ChromeFont.label, .foregroundColor: colors.textMuted]
        )
        ChromeFieldView.styleEditor(of: field, colors: colors)
    }
}

/// A text field that reports when editing starts and ends, so its surface can
/// show the focus edge (search fields, the commit summary, settings fields).
final class FocusReportingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Return can end editing and re-focus the field inside `super`; the
        // field still has focus whenever an editor remains attached.
        onFocusChange?(currentEditor() != nil)
    }
}

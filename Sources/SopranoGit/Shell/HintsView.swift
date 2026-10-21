import AppKit

/// A row of key hints (`.hints`): each hint is a muted K1 keycap group of
/// 16 pt caps followed by its SF Pro 11 muted word (`↵ Open`, `J K Move`).
@MainActor
final class HintsView: NSStackView {
    struct Hint: Equatable {
        /// K1 caps, one per chord step (`["⌃A", "P"]`, `["J"]`, `["esc"]`).
        var caps: [String]
        var label: String
    }

    var hints: [Hint] {
        didSet {
            guard hints != oldValue else { return }
            rebuild()
        }
    }
    private var theme: AppTheme

    init(hints: [Hint] = [], theme: AppTheme) {
        self.hints = hints
        self.theme = theme
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 14
        translatesAutoresizingMaskIntoConstraints = false
        setHuggingPriority(.required, for: .horizontal)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        rebuild()
    }

    /// The words shown, in order (tests).
    var labels: [String] { hints.map(\.label) }

    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for hint in hints {
            let caps = ChromeKeycapGroupView(caps: hint.caps, theme: theme, style: .small, tone: .muted)
            let label = NSTextField(labelWithString: "")
            label.setChromeText(hint.label, font: ChromeFont.meta, color: theme.colors.textMuted)
            let pair = NSStackView(views: [caps, label])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = 5
            pair.setHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(pair)
        }
    }
}

import AppKit

/// A row of key hints (`.hints`): each hint is one muted K1 keycap group of
/// 16 pt caps per alternative chord, followed by its SF Pro 11 muted word
/// (`↵ Open`, `J K Move`).
@MainActor
final class HintsView: NSStackView {
    struct Hint: Equatable {
        /// One K1 cap sequence per alternative chord: `[["⌃A", "P"]]` is a
        /// prefix sequence, `[["J"], ["K"]]` is J or K.
        var caps: [[String]]
        var label: String

        /// What VoiceOver reads for the caps: steps joined with " then ",
        /// alternatives with " or " ("J or K", "⌃A then P").
        var accessibilityCaps: String {
            caps.map { $0.joined(separator: " then ") }.joined(separator: " or ")
        }
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
            let groups = hint.caps.map { ChromeKeycapGroupView(caps: $0, theme: theme, style: .small, tone: .muted) }
            let caps = NSStackView(views: groups)
            caps.orientation = .horizontal
            caps.alignment = .centerY
            caps.spacing = 3
            caps.setHuggingPriority(.required, for: .horizontal)
            caps.setAccessibilityElement(true)
            caps.setAccessibilityRole(.staticText)
            caps.setAccessibilityLabel(hint.accessibilityCaps)
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

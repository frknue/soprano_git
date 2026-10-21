import AppKit
import SopranoGitCore

/// A changed file's kind as a bare coloured letter (`.kind`): SF Mono 11
/// Semibold, 12 pt wide, in the kind's colour, with no box around it.
final class ChangeKindBadge: NSView {
    static let width: CGFloat = 12
    static let height: CGFloat = 16

    private let label = NSTextField(labelWithString: "")
    private var theme: AppTheme

    var kind: ChangeKind {
        didSet { restyle() }
    }

    /// The letter's colour (tests).
    var letterColor: NSColor? { label.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor }

    var letterText: String { label.stringValue }

    init(kind: ChangeKind, theme: AppTheme) {
        self.kind = kind
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.height) }

    func apply(theme: AppTheme) {
        self.theme = theme
        restyle()
    }

    static func color(for kind: ChangeKind, colors: ThemeColors) -> NSColor {
        switch kind {
        case .modified: colors.yellow
        case .added, .untracked: colors.success
        case .deleted, .unmerged: colors.danger
        case .renamed, .copied: colors.cyan
        case .typeChanged: colors.blue
        }
    }

    static func letter(for kind: ChangeKind) -> String {
        kind.rawValue
    }

    private func restyle() {
        label.setChromeText(
            Self.letter(for: kind),
            font: ChromeFont.monospaced(size: 11, weight: .semibold),
            color: Self.color(for: kind, colors: theme.colors)
        )
        toolTip = String(describing: kind)
    }
}

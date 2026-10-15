import AppKit
import SopranoGitCore

/// A one-letter status badge for a changed file: an outlined 16×16 square in
/// the kind's color with the letter in the same color.
final class ChangeKindBadge: NSView {
    static let side: CGFloat = 16

    private let label = NSTextField(labelWithString: "")
    private var theme: AppTheme

    var kind: ChangeKind {
        didSet { restyle() }
    }

    init(kind: ChangeKind, theme: AppTheme) {
        self.kind = kind
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
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

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

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
        let color = Self.color(for: kind, colors: theme.colors)
        label.setRetroText(Self.letter(for: kind), color: color, size: 11, tracking: 0)
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
        layer?.borderColor = color.cgColor
        layer?.backgroundColor = NSColor.clear.cgColor
        toolTip = String(describing: kind)
    }
}

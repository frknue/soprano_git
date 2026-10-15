import AppKit
import SopranoGitCore

/// A compact console key with an inline keycap hint, for row actions, section
/// headers, hunk headers and the composer: `[STAGE  S]`. Standard keys sit on
/// `bgRaised`; prominent keys are lit accent; danger keys light `danger` on hover.
final class KeyHintButton: NSButton {
    enum Kind {
        case standard
        case prominent
        case danger
    }

    static let compactHeight: CGFloat = 20
    static let padding: CGFloat = 6
    static let hintGap: CGFloat = 5

    var kind: Kind {
        didSet { needsDisplay = true }
    }

    /// Keycap text drawn after the title; nil hides it.
    var hint: String? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var theme: AppTheme
    private let height: CGFloat
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    init(title: String, hint: String?, theme: AppTheme, kind: Kind = .standard, height: CGFloat = KeyHintButton.compactHeight) {
        self.kind = kind
        self.hint = hint
        self.theme = theme
        self.height = height
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    /// Never steals keyboard focus from the list it sits in.
    override var acceptsFirstResponder: Bool { false }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    /// No gap before the keycap when the title is empty (a keycap-only button).
    private var gap: CGFloat { title.isEmpty ? 0 : Self.hintGap }

    override var intrinsicContentSize: NSSize {
        var width = ceil(RetroText.display(title, color: .labelColor).size().width) + Self.padding * 2
        if let hint {
            width += gap + capSize(for: hint).width
        }
        return NSSize(width: width, height: height)
    }

    private func capSize(for hint: String) -> NSSize {
        let text = RetroText.display(hint, color: .labelColor, tracking: 0)
        return NSSize(width: ceil(text.size().width) + 8, height: 14)
    }

    private struct Palette {
        var fill: NSColor
        var edge: NSColor
        var ink: NSColor
        var capEdge: NSColor
    }

    private var palette: Palette {
        let colors = theme.colors
        let pressed = isEnabled && isHighlighted
        guard isEnabled else {
            return Palette(fill: colors.bgRaised, edge: colors.borderSubtle, ink: colors.textMuted, capEdge: colors.borderSubtle)
        }
        switch kind {
        case .prominent:
            let fill = pressed ? colors.accentStrong : colors.accent
            return Palette(fill: fill, edge: fill, ink: colors.bgPanel, capEdge: colors.bgPanel.withAlphaComponent(0.6))
        case .danger:
            if pressed || isHovered {
                let fill = pressed ? colors.danger : colors.danger.withAlphaComponent(0.18)
                return Palette(fill: fill, edge: colors.danger, ink: pressed ? colors.bgPanel : colors.danger, capEdge: colors.danger)
            }
            return Palette(fill: colors.bgRaised, edge: colors.borderStrong, ink: colors.textPrimary, capEdge: colors.borderSubtle)
        case .standard:
            if pressed {
                return Palette(fill: colors.accentStrong, edge: colors.accentStrong, ink: colors.bgPanel, capEdge: colors.bgPanel)
            }
            return Palette(
                fill: isHovered ? colors.bgOverlay : colors.bgRaised,
                edge: isHovered ? colors.accent : colors.borderStrong,
                ink: colors.textPrimary,
                capEdge: colors.borderSubtle
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = palette
        palette.fill.setFill()
        bounds.fill()
        palette.edge.setStroke()
        let frame = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = Retro.hairline
        frame.stroke()

        let label = RetroText.display(title, color: palette.ink, lineBreakMode: .byClipping)
        let labelSize = label.size()
        var contentWidth = ceil(labelSize.width)
        var cap: NSSize = .zero
        if let hint {
            cap = capSize(for: hint)
            contentWidth += gap + cap.width
        }
        var x = floor((bounds.width - contentWidth) / 2)
        label.draw(at: NSPoint(x: x, y: floor((bounds.height - labelSize.height) / 2)))
        x += ceil(labelSize.width)
        if let hint {
            x += gap
            let capRect = NSRect(x: x, y: floor((bounds.height - cap.height) / 2), width: cap.width, height: cap.height)
            palette.capEdge.setStroke()
            let edge = NSBezierPath(rect: capRect.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = Retro.hairline
            edge.stroke()
            let text = RetroText.display(hint, color: palette.ink.withAlphaComponent(0.8), tracking: 0)
            let size = text.size()
            text.draw(at: NSPoint(x: capRect.midX - size.width / 2, y: capRect.midY - size.height / 2))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }
}

/// Text builders shared by the commit panel and the diff view.
enum PanelText {
    /// A path with its directory muted and the file name bright; renames read
    /// `old → new` with the old path muted.
    static func path(_ path: String, oldPath: String? = nil, colors: ThemeColors, size: CGFloat = 12) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = RetroFont.body(size)
        let muted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.textMuted]
        let bright: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.textPrimary]
        if let oldPath, oldPath != path {
            result.append(NSAttributedString(string: oldPath + " → ", attributes: muted))
        }
        if let slash = path.lastIndex(of: "/") {
            result.append(NSAttributedString(string: String(path[...slash]), attributes: muted))
            result.append(NSAttributedString(string: String(path[path.index(after: slash)...]), attributes: bright))
        } else {
            result.append(NSAttributedString(string: path, attributes: bright))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// `+a −d` in success/danger; `bin` for binary files; empty when unknown.
    static func counts(additions: Int?, deletions: Int?, colors: ThemeColors, size: CGFloat = 11) -> NSAttributedString {
        let font = RetroFont.body(size)
        guard let additions, let deletions else {
            return NSAttributedString(string: "bin", attributes: [.font: font, .foregroundColor: colors.textMuted])
        }
        if additions == 0 && deletions == 0 {
            return NSAttributedString()
        }
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "+\(additions)", attributes: [.font: font, .foregroundColor: colors.success]))
        result.append(NSAttributedString(string: " −\(deletions)", attributes: [.font: font, .foregroundColor: colors.danger]))
        return result
    }

    /// The compact keycap text of a command's first chord ("S", "⌘⇧S").
    @MainActor
    static func keycap(_ commandID: String) -> String? {
        SettingsCenter.shared.keycapText(for: commandID)
    }
}

/// A square ref label: display face 11, outlined in its color, lit (filled)
/// for the checked-out branch.
final class RefPillView: NSView {
    enum Kind {
        case head
        case localBranch
        case remoteBranch
        case tag
    }

    private let label = NSTextField(labelWithString: "")
    private let name: String
    private let kind: Kind

    init(name: String, kind: Kind, theme: AppTheme) {
        self.name = name
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(theme: AppTheme) {
        let colors = theme.colors
        let tint: NSColor = switch kind {
        case .head, .localBranch: colors.accent
        case .remoteBranch: colors.blue
        case .tag: colors.yellow
        }
        let lit = kind == .head
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
        layer?.borderColor = tint.cgColor
        layer?.backgroundColor = (lit ? tint : tint.withAlphaComponent(0.12)).cgColor
        label.setRetroText(name, color: lit ? colors.bgPanel : tint)
        toolTip = name
    }
}

/// Lays its subviews out left to right, wrapping into rows like text.
final class FlowLayoutView: NSView {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    override var isFlipped: Bool { true }

    func setViews(_ views: [NSView]) {
        subviews.forEach { $0.removeFromSuperview() }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func frames(for width: CGFloat) -> [NSRect] {
        var frames: [NSRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.fittingSize
            let itemWidth = min(size.width, max(width, 1))
            if x > 0, x + itemWidth > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(NSRect(x: x, y: y, width: itemWidth, height: size.height))
            x += itemWidth + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 0 ? bounds.width : 300
        let height = frames(for: width).map(\.maxY).max() ?? 0
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        for (view, frame) in zip(subviews, frames(for: bounds.width)) {
            view.frame = frame
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

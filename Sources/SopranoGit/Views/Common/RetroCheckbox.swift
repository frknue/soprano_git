import AppKit

/// A square retro checkbox: a 12pt box with a strong edge (accent on hover),
/// filled accent with a bgPanel check when on, and a display-face title.
/// Space toggles it from the keyboard; every toggle sends the action.
final class RetroCheckbox: NSButton {
    static let boxSide: CGFloat = 12
    static let gap: CGFloat = 6

    private var theme: AppTheme
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false {
        didSet { needsDisplay = true }
    }

    var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off; needsDisplay = true }
    }

    init(title: String, theme: AppTheme, target: AnyObject?, action: Selector?) {
        self.theme = theme
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        setButtonType(.switch)
        isBordered = false
        focusRingType = .none
        imagePosition = .noImage
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var title: String {
        didSet { restyle() }
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        restyle()
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: Self.boxSide + Self.gap + ceil(text.width), height: max(Self.boxSide, ceil(text.height)))
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        toggle()
    }

    /// Flips the state and sends the action.
    func toggle() {
        isOn.toggle()
        sendAction(action, to: target)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let box = NSRect(
            x: 0.5,
            y: floor((bounds.height - Self.boxSide) / 2) + 0.5,
            width: Self.boxSide - 1,
            height: Self.boxSide - 1
        )
        if isOn {
            colors.accent.setFill()
            box.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 2.5, y: box.midY))
            check.line(to: NSPoint(x: box.minX + 4.5, y: isFlipped ? box.maxY - 3 : box.minY + 3))
            check.line(to: NSPoint(x: box.maxX - 2.5, y: isFlipped ? box.minY + 3 : box.maxY - 3))
            check.lineWidth = 1.5
            check.lineCapStyle = .square
            colors.bgPanel.setStroke()
            check.stroke()
        }
        let edge = NSBezierPath(rect: box)
        edge.lineWidth = 1
        (isHovered && isEnabled ? colors.accent : colors.borderStrong).setStroke()
        edge.stroke()
        let text = attributedTitle
        let size = text.size()
        text.draw(at: NSPoint(x: Self.boxSide + Self.gap, y: floor((bounds.height - size.height) / 2)))
    }

    private func restyle() {
        attributedTitle = RetroText.display(title, color: theme.colors.textPrimary, size: 11)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

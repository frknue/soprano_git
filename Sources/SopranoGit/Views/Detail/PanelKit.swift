import AppKit
import SopranoGitCore

/// A Folio button with a trailing K1 keycap group, for row actions, section
/// headings, hunk headers and the composer: `Stage S`, `Commit ⌘↵`.
///
/// Kinds follow `ChromeButton`: `standard` is a raised 6 pt button with a
/// `borderStrong` edge, `ink` is the primary action, `text` is borderless.
/// `danger` stays calm at rest (standard, or borderless when `isPlain`) and
/// fills with `danger` under the pointer, so destructive row keys do not shout.
/// Pressed is `bgOverlay`. Every chord is its own cap (`⌃A` `P`).
final class KeyHintButton: NSButton {
    typealias Kind = ChromeButton.Kind

    /// Row and header actions: 20 pt, SF Pro 11, 6 pt padding.
    static let compactHeight: CGFloat = 20
    private static let capHeight = Chrome.keycapHeightSmall
    private static let capGap: CGFloat = 3
    private static let defaultContentGap: CGFloat = 6

    /// Overrides the side padding (nil: 6 when compact, else 10).
    var horizontalPadding: CGFloat? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Overrides the gap between icon, title and caps (nil: 6).
    var contentGap: CGFloat? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var kind: Kind {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Borderless at rest (section headings); `text` buttons always are.
    var isPlain = false {
        didSet { needsDisplay = true }
    }

    /// K1 keycaps drawn after the title, one cap per chord; nil hides them.
    var hint: [String]? {
        didSet {
            guard hint != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// SF Symbol drawn before the title, muted (13 pt; 12 pt when compact).
    var symbolName: String? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var theme: AppTheme
    private let height: CGFloat
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    init(title: String, hint: [String]?, theme: AppTheme, kind: Kind = .standard, height: CGFloat = KeyHintButton.compactHeight) {
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

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    /// Never steals keyboard focus from the list it sits in.
    override var acceptsFirstResponder: Bool { false }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    // MARK: - Metrics

    private var isCompact: Bool { height < Chrome.controlHeight }
    private var padding: CGFloat { horizontalPadding ?? (isCompact ? 6 : ChromeButton.horizontalPadding) }
    private var gap: CGFloat { contentGap ?? Self.defaultContentGap }
    private var isBorderless: Bool { kind == .text || isPlain }

    private var labelFont: NSFont {
        let weight: NSFont.Weight = kind == .ink ? .medium : .regular
        return ChromeFont.sans(size: isCompact ? 11 : 12, weight: weight)
    }

    private func label(color: NSColor) -> NSAttributedString {
        ChromeText.attributed(title, font: labelFont, color: color, lineBreakMode: .byClipping)
    }

    private func symbol(color: NSColor) -> NSImage? {
        guard let symbolName,
              let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: isCompact ? 12 : 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return image.withSymbolConfiguration(configuration)
    }

    private func capWidths(_ caps: [String]) -> [CGFloat] {
        caps.map { ChromeKeycapView.capWidth($0, font: ChromeFont.keycap, height: Self.capHeight, padding: 4) }
    }

    private func capsWidth(_ caps: [String]) -> CGFloat {
        let widths = capWidths(caps)
        return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * Self.capGap
    }

    /// Icon, title and caps with their gaps.
    private func contentWidth(label: NSAttributedString, icon: NSImage?) -> CGFloat {
        var width = title.isEmpty ? 0 : ceil(label.size().width)
        if let icon {
            width += ceil(icon.size.width) + (title.isEmpty ? 0 : gap)
        }
        if let hint, !hint.isEmpty {
            width += (width > 0 ? gap : 0) + capsWidth(hint)
        }
        return width
    }

    override var intrinsicContentSize: NSSize {
        let width = contentWidth(label: label(color: .labelColor), icon: symbol(color: .labelColor))
        return NSSize(width: ceil(width) + padding * 2, height: height)
    }

    // MARK: - Drawing

    private struct Palette {
        var fill: NSColor?
        var edge: NSColor?
        var text: NSColor
        var icon: NSColor
        var capFill: NSColor?
        var capEdge: NSColor
        var capText: NSColor
    }

    private var palette: Palette {
        let colors = theme.colors
        let pressed = isEnabled && isHighlighted
        let hot = isEnabled && isHovered
        switch kind {
        case .ink:
            guard isEnabled else {
                return Palette(fill: colors.bgOverlay, edge: colors.bgOverlay, text: colors.textMuted, icon: colors.textMuted,
                               capFill: nil, capEdge: colors.textMuted.withAlphaComponent(0.35), capText: colors.textMuted)
            }
            let fill = pressed || hot ? colors.inkButtonPressed : colors.inkButtonFill
            let label = colors.inkButtonLabel
            return Palette(fill: fill, edge: fill, text: label, icon: label,
                           capFill: nil, capEdge: label.withAlphaComponent(0.35), capText: label)
        case .danger where pressed || hot:
            let fill = pressed ? colors.dangerButtonHover : colors.dangerButtonFill
            let label = colors.dangerButtonLabel
            return Palette(fill: fill, edge: fill, text: label, icon: label,
                           capFill: nil, capEdge: label.withAlphaComponent(0.40), capText: label)
        case .standard, .text, .danger:
            let plain = isBorderless
            guard isEnabled else {
                return Palette(fill: nil, edge: plain ? nil : colors.borderSubtle, text: colors.textMuted, icon: colors.textMuted,
                               capFill: nil, capEdge: colors.borderSubtle, capText: colors.textMuted)
            }
            let fill: NSColor? = pressed ? colors.bgOverlay : (hot ? colors.hover : (plain ? nil : colors.raised))
            // Plain header buttons (`Copy Y`) read muted until pointed at.
            let text = plain && isCompact && !(hot || pressed) ? colors.textMuted : colors.textPrimary
            return Palette(fill: fill, edge: plain ? nil : colors.borderStrong, text: text,
                           icon: hot || pressed ? colors.textPrimary : colors.textMuted,
                           capFill: colors.keycapFill, capEdge: colors.keycapEdge,
                           capText: plain ? colors.textMuted : colors.textPrimary)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = palette
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        )
        if let fill = palette.fill {
            fill.setFill()
            shape.fill()
        }
        if let edge = palette.edge {
            edge.setStroke()
            shape.lineWidth = Chrome.hairline
            shape.stroke()
        }

        let string = label(color: palette.text)
        let icon = symbol(color: palette.icon)
        var x = floor((bounds.width - contentWidth(label: string, icon: icon)) / 2)
        if let icon {
            let size = icon.size
            icon.draw(in: NSRect(x: x, y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height))
            x += ceil(size.width) + (title.isEmpty ? 0 : gap)
        }
        if !title.isEmpty {
            let size = string.size()
            string.draw(at: NSPoint(x: x, y: floor((bounds.height - size.height) / 2)))
            x += ceil(size.width)
        }
        guard let hint, !hint.isEmpty else { return }
        if icon != nil || !title.isEmpty { x += gap }
        let top = floor((bounds.height - Self.capHeight) / 2)
        for (legend, width) in zip(hint, capWidths(hint)) {
            ChromeKeycapView.drawCap(
                legend,
                in: NSRect(x: x, y: top, width: width, height: Self.capHeight),
                fill: palette.capFill,
                edge: palette.capEdge,
                text: palette.capText,
                font: ChromeFont.keycap,
                radius: Chrome.Radius.cap
            )
            x += width + Self.capGap
        }
    }

    // MARK: - Hover

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
    /// The prefix that stands in for dropped leading path components.
    static let elision = "…/"

    /// A path in SF Mono 12: directory muted, file name Semibold ink; renames
    /// read `old → new` with the old path muted. With `availableWidth`, a path
    /// that does not fit drops whole leading components behind `…/`
    /// (`…/Views/SidebarView.swift`, then `…/SidebarView.swift`); a rename
    /// first shortens its old side to the file name, then drops it.
    static func path(_ path: String, oldPath: String? = nil, colors: ThemeColors, availableWidth: CGFloat? = nil) -> NSAttributedString {
        let rename = oldPath.flatMap { $0 == path ? nil : $0 }
        let (directory, name) = split(path)
        let full = compose(old: rename, directory: directory, name: name, colors: colors)
        guard let availableWidth, !fits(full, availableWidth) else { return full }

        let folders = directory.split(separator: "/").map(String.init)
        // Shorter and shorter directories: all folders, then drop one leading folder at a time.
        let directories = (0...folders.count).map { dropped -> String in
            if dropped == 0 { return directory }
            let kept = folders.dropFirst(dropped)
            return kept.isEmpty ? elision : elision + kept.joined(separator: "/") + "/"
        }
        var olds: [String?] = []
        if let rename {
            olds.append(split(rename).name)
        }
        olds.append(nil)
        for old in olds {
            for candidate in directories {
                let text = compose(old: old, directory: candidate, name: name, colors: colors)
                if fits(text, availableWidth) { return text }
            }
        }
        // Not even the file name fits: the label truncates its head.
        return compose(old: nil, directory: folders.isEmpty ? "" : elision, name: name, colors: colors)
    }

    /// `+a −d` in SF Mono 11: additions success, deletions danger, a zero side
    /// muted; `bin` for binary files; empty when nothing changed.
    static func counts(additions: Int?, deletions: Int?, colors: ThemeColors) -> NSAttributedString {
        let font = ChromeFont.monoSmall
        guard let additions, let deletions else {
            return NSAttributedString(string: "bin", attributes: [.font: font, .foregroundColor: colors.textMuted])
        }
        if additions == 0 && deletions == 0 {
            return NSAttributedString()
        }
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "+\(additions)",
            attributes: [.font: font, .foregroundColor: additions == 0 ? colors.textMuted : colors.success]
        ))
        result.append(NSAttributedString(string: " ", attributes: [.font: font]))
        result.append(NSAttributedString(
            string: "−\(deletions)",
            attributes: [.font: font, .foregroundColor: deletions == 0 ? colors.textMuted : colors.danger]
        ))
        return result
    }

    /// `("Sources/App/", "main.swift")`; the directory keeps its trailing slash.
    private static func split(_ path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }

    private static func fits(_ text: NSAttributedString, _ width: CGFloat) -> Bool {
        ceil(text.size().width) <= width
    }

    private static func compose(old: String?, directory: String, name: String, colors: ThemeColors) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let muted: [NSAttributedString.Key: Any] = [.font: ChromeFont.mono, .foregroundColor: colors.textMuted]
        if let old {
            result.append(NSAttributedString(string: old + " → ", attributes: muted))
        }
        if !directory.isEmpty {
            result.append(NSAttributedString(string: directory, attributes: muted))
        }
        result.append(NSAttributedString(
            string: name,
            attributes: [.font: ChromeFont.monospaced(size: 12, weight: .semibold), .foregroundColor: colors.textPrimary]
        ))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }
}

/// A ref label drawn like the graph's pills: 18 pt, radius 4, a 10 % fill of
/// the commit's lane color with a 1 pt lane edge, SF Pro 11 Medium ink and
/// lane-colored SF Symbols. HEAD's ref is the ink pill.
final class RefPillView: NSView {
    enum Kind: Equatable {
        case localBranch
        case remoteBranch
        case tag
        /// `HEAD` while detached.
        case detachedHead
    }

    /// One pill: its name, kind, and whether HEAD points at it.
    struct Ref: Equatable {
        var name: String
        var kind: Kind
        var isHead: Bool = false
    }

    static let height: CGFloat = 18
    static let maximumWidth: CGFloat = 160

    let ref: Ref
    private let stack = NSStackView()
    private let label = NSTextField(labelWithString: "")
    private var icons: [NSImageView] = []
    /// The pill's fill: the ink pill on HEAD, else the lane at 10 %.
    private(set) var fillColor: NSColor = .clear

    /// `lane` indexes `theme.graphLanes`, the color the graph gives the commit.
    init(ref: Ref, lane: Int, theme: AppTheme) {
        self.ref = ref
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for name in Self.symbolNames(for: ref) {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            icons.append(icon)
            stack.addArrangedSubview(icon)
        }
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(label)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumWidth),
        ])
        apply(theme: theme, lane: lane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The ref icons, as in the graph: a tick on HEAD, then the ref's kind.
    static func symbolNames(for ref: Ref) -> [String] {
        var names = ref.isHead ? ["checkmark"] : []
        switch ref.kind {
        case .localBranch: names.append("laptopcomputer")
        case .remoteBranch: names.append("cloud")
        case .tag: names.append("tag")
        case .detachedHead: break
        }
        return names
    }

    func apply(theme: AppTheme, lane: Int) {
        let colors = theme.colors
        let lanes = theme.graphLanes
        let laneColor = lanes[lane % lanes.count]
        let ink = ref.isHead ? colors.inkButtonLabel : colors.textPrimary
        fillColor = ref.isHead ? colors.inkButtonFill : laneColor.withAlphaComponent(0.10)
        layer?.cornerRadius = Chrome.Radius.cap
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderWidth = ref.isHead ? 0 : Chrome.hairline
        layer?.borderColor = laneColor.cgColor
        for icon in icons {
            icon.contentTintColor = ref.isHead ? colors.inkButtonLabel : laneColor
        }
        label.setChromeText(ref.name, font: ChromeFont.sans(size: 11, weight: .medium), color: ink)
        toolTip = ref.name
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

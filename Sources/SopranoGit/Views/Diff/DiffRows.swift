import AppKit
import SopranoGitCore

/// Fonts, colors and gutter metrics every diff row draws with; rebuilt when
/// the theme or the file changes so rows never build attributes per draw.
@MainActor
struct DiffRowStyle {
    let colors: ThemeColors
    let textAttributes: [NSAttributedString.Key: Any]
    let mutedAttributes: [NSAttributedString.Key: Any]
    let numberAttributes: [NSAttributedString.Key: Any]
    let addedMarker: NSAttributedString
    let removedMarker: NSAttributedString
    /// Width of one line-number column.
    let numberWidth: CGFloat
    let markerWidth: CGFloat = 16
    static let rail: CGFloat = 3
    static let padding: CGFloat = 8
    /// Where the text sits vertically inside an 18 pt line row.
    static let textTop: CGFloat = 2
    /// Lines longer than this are cut before drawing (the row truncates them anyway).
    static let maximumDrawnLength = 2000

    init(theme: AppTheme, maxLineNumber: Int) {
        colors = theme.colors
        let body = RetroFont.body(12)
        let small = RetroFont.body(11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        textAttributes = [.font: body, .foregroundColor: colors.textPrimary, .paragraphStyle: paragraph]
        mutedAttributes = [.font: body, .foregroundColor: colors.textMuted, .paragraphStyle: paragraph]
        numberAttributes = [.font: small, .foregroundColor: colors.textMuted.withAlphaComponent(0.75)]
        addedMarker = NSAttributedString(string: "+", attributes: [.font: body, .foregroundColor: colors.success])
        removedMarker = NSAttributedString(string: "−", attributes: [.font: body, .foregroundColor: colors.danger])
        let digits = max(3, String(max(1, maxLineNumber)).count)
        let digitWidth = NSAttributedString(string: "0", attributes: [.font: small]).size().width
        numberWidth = ceil(CGFloat(digits) * digitWidth) + 12
    }

    /// Unified layout: where the two-number gutter ends and the code starts.
    var gutterWidth: CGFloat { Self.rail + numberWidth * 2 }
    var textX: CGFloat { gutterWidth + markerWidth }
    /// Split layout: each side's one-number gutter.
    var sideGutterWidth: CGFloat { Self.rail + numberWidth }

    func number(_ value: Int?) -> NSAttributedString? {
        value.map { NSAttributedString(string: String($0), attributes: numberAttributes) }
    }

    func marker(for kind: DiffLine.Kind) -> NSAttributedString? {
        switch kind {
        case .added: addedMarker
        case .removed: removedMarker
        case .context, .noNewlineMarker: nil
        }
    }

    /// The line's text in `textPrimary`, colored by its syntax tokens (ranges
    /// relative to the raw line), tabs shown as four spaces.
    func text(of line: DiffLine, tokens: [SyntaxToken]?) -> NSAttributedString {
        if line.kind == .noNewlineMarker {
            return NSAttributedString(string: "No newline at end of file", attributes: mutedAttributes)
        }
        let raw = line.text
        let cut = raw.utf16.count > Self.maximumDrawnLength ? String(raw.prefix(Self.maximumDrawnLength)) : raw
        let text = NSMutableAttributedString(string: cut, attributes: textAttributes)
        let length = text.length
        for token in tokens ?? [] where token.range.location < length {
            let range = NSRange(location: token.range.location, length: min(token.range.length, length - token.range.location))
            text.addAttribute(.foregroundColor, value: token.kind.color(in: colors), range: range)
        }
        if cut.contains("\t") {
            // Each replacement takes the attributes of the tab it replaces.
            text.mutableString.replaceOccurrences(of: "\t", with: "    ", options: [], range: NSRange(location: 0, length: length))
        }
        return text
    }

    /// Added and removed lines are tinted `success`/`danger` α0.14.
    func tint(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: colors.success.withAlphaComponent(0.14)
        case .removed: colors.danger.withAlphaComponent(0.14)
        case .context, .noNewlineMarker: nil
        }
    }
}

/// Drawing shared by the unified and split line rows.
@MainActor
enum DiffRowDrawing {
    /// A line number right-aligned at `right`.
    static func draw(number: NSAttributedString?, right: CGFloat, height: CGFloat) {
        guard let number else { return }
        let size = number.size()
        number.draw(at: NSPoint(x: right - 6 - size.width, y: floor((height - size.height) / 2)))
    }

    /// Code text from `x` to `maxX`, cut with a tail ellipsis when it does not fit.
    static func draw(text: NSAttributedString, x: CGFloat, maxX: CGFloat, height: CGFloat) {
        let width = maxX - x
        guard width > 4 else { return }
        text.draw(
            with: NSRect(x: x, y: DiffRowStyle.textTop, width: width, height: height - DiffRowStyle.textTop),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    /// The faint raised gutter band ending in a hairline.
    static func drawGutter(from x: CGFloat, width: CGFloat, height: CGFloat, colors: ThemeColors) {
        colors.bgRaised.withAlphaComponent(0.45).setFill()
        NSRect(x: x, y: 0, width: width, height: height).fill(using: .sourceOver)
        colors.borderSubtle.setFill()
        NSRect(x: x + width - 1, y: 0, width: 1, height: height).fill()
    }

    /// Soprano's diff filler: `textMuted` α0.06 with thin diagonal stripes in
    /// `borderSubtle`, phased by the row's position in the list (`originY`)
    /// so stacked filler cells join into one hatched block.
    static func drawFiller(in rect: NSRect, originY: CGFloat, colors: ThemeColors) {
        colors.textMuted.withAlphaComponent(0.06).setFill()
        rect.fill(using: .sourceOver)
        let spacing: CGFloat = 8
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let path = NSBezierPath()
        path.lineWidth = 1
        var step = floor((rect.minX - rect.maxY - originY) / spacing)
        let lastStep = ceil((rect.maxX - rect.minY - originY) / spacing)
        while step <= lastStep {
            let offset = step * spacing + originY
            path.move(to: NSPoint(x: offset + rect.minY, y: rect.minY))
            path.line(to: NSPoint(x: offset + rect.maxY, y: rect.maxY))
            step += 1
        }
        colors.borderSubtle.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A diff list row (hunk header, line or notice). Rows of the current hunk
/// draw an accent rail on their leading edge.
@MainActor
protocol DiffRowCell: NSView {
    var isCurrentHunk: Bool { get set }
}

/// One unified diff line: old/new line-number gutters, +/− marker, text;
/// added and removed lines tinted. Drawn directly for speed; `configure`
/// builds the row's attributed strings once.
final class DiffLineCellView: NSView, DiffRowCell {
    static let identifier = NSUserInterfaceItemIdentifier("DiffLineCell")
    static let rowHeight: CGFloat = 18

    private(set) var line: DiffLine?
    private var style: DiffRowStyle?
    private var oldNumber: NSAttributedString?
    private var newNumber: NSAttributedString?
    /// The drawn text, syntax colors applied.
    private(set) var text = NSAttributedString()
    var isCurrentHunk = false {
        didSet { if oldValue != isCurrentHunk { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(line: DiffLine, tokens: [SyntaxToken]?, style: DiffRowStyle, isCurrentHunk: Bool) {
        self.line = line
        self.style = style
        oldNumber = style.number(line.oldNumber)
        newNumber = style.number(line.newNumber)
        text = style.text(of: line, tokens: tokens)
        self.isCurrentHunk = isCurrentHunk
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let line, let style else { return }
        let colors = style.colors
        let height = bounds.height
        if let tint = style.tint(for: line.kind) {
            tint.setFill()
            bounds.fill(using: .sourceOver)
        }
        DiffRowDrawing.drawGutter(from: 0, width: style.gutterWidth, height: height, colors: colors)
        if isCurrentHunk {
            colors.accent.setFill()
            NSRect(x: 0, y: 0, width: DiffRowStyle.rail, height: height).fill()
        }
        DiffRowDrawing.draw(number: oldNumber, right: DiffRowStyle.rail + style.numberWidth, height: height)
        DiffRowDrawing.draw(number: newNumber, right: DiffRowStyle.rail + style.numberWidth * 2, height: height)
        style.marker(for: line.kind)?.draw(at: NSPoint(x: style.gutterWidth + 4, y: DiffRowStyle.textTop))
        DiffRowDrawing.draw(text: text, x: style.textX, maxX: bounds.width - 4, height: height)
    }
}

/// One split diff row: the old line on the left, the new line on the right,
/// each with its own line-number gutter, +/− marker, text and tint, divided
/// by a `borderSubtle` hairline. A missing side is a hatched filler.
final class DiffSplitLineCellView: NSView, DiffRowCell {
    static let identifier = NSUserInterfaceItemIdentifier("DiffSplitLineCell")
    static let rowHeight = DiffLineCellView.rowHeight

    /// What one side of the row shows; a nil `line` is a filler.
    struct Side {
        var line: DiffLine?
        var number: NSAttributedString?
        var text: NSAttributedString?
    }

    private(set) var old = Side()
    private(set) var new = Side()
    private var style: DiffRowStyle?
    var isCurrentHunk = false {
        didSet { if oldValue != isCurrentHunk { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(old oldLine: DiffLine?, oldTokens: [SyntaxToken]?, new newLine: DiffLine?, newTokens: [SyntaxToken]?,
                   style: DiffRowStyle, isCurrentHunk: Bool) {
        self.style = style
        old = Side(line: oldLine, number: style.number(oldLine?.oldNumber), text: oldLine.map { style.text(of: $0, tokens: oldTokens) })
        new = Side(line: newLine, number: style.number(newLine?.newNumber), text: newLine.map { style.text(of: $0, tokens: newTokens) })
        self.isCurrentHunk = isCurrentHunk
        needsDisplay = true
    }

    /// Left edge of the right side; the hairline sits just before it.
    var dividerX: CGFloat { floor(bounds.width / 2) }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let colors = style.colors
        let height = bounds.height
        let divider = dividerX
        // Position in the list, so filler hatching lines up across rows.
        let originY = superview?.frame.minY ?? 0
        draw(old, from: 0, to: divider, style: style, originY: originY)
        draw(new, from: divider + 1, to: bounds.width, style: style, originY: originY)
        colors.borderSubtle.setFill()
        NSRect(x: divider, y: 0, width: 1, height: height).fill()
        if isCurrentHunk {
            colors.accent.setFill()
            NSRect(x: 0, y: 0, width: DiffRowStyle.rail, height: height).fill()
        }
    }

    private func draw(_ side: Side, from minX: CGFloat, to maxX: CGFloat, style: DiffRowStyle, originY: CGFloat) {
        let colors = style.colors
        let height = bounds.height
        let gutter = style.sideGutterWidth
        guard let line = side.line else {
            DiffRowDrawing.drawGutter(from: minX, width: gutter, height: height, colors: colors)
            DiffRowDrawing.drawFiller(
                in: NSRect(x: minX + gutter, y: 0, width: max(0, maxX - minX - gutter), height: height),
                originY: originY, colors: colors
            )
            return
        }
        if let tint = style.tint(for: line.kind) {
            tint.setFill()
            NSRect(x: minX, y: 0, width: maxX - minX, height: height).fill(using: .sourceOver)
        }
        DiffRowDrawing.drawGutter(from: minX, width: gutter, height: height, colors: colors)
        DiffRowDrawing.draw(number: side.number, right: minX + gutter, height: height)
        style.marker(for: line.kind)?.draw(at: NSPoint(x: minX + gutter + 4, y: DiffRowStyle.textTop))
        if let text = side.text {
            DiffRowDrawing.draw(text: text, x: minX + gutter + style.markerWidth, maxX: maxX - 4, height: height)
        }
    }
}

/// Hunk header strip: `@@ -a,b +c,d @@` muted with the section text, and the
/// hunk's action keys (STAGE HUNK / DISCARD, or UNSTAGE HUNK).
final class DiffHunkHeaderCellView: NSView, DiffRowCell {
    static let identifier = NSUserInterfaceItemIdentifier("DiffHunkHeaderCell")
    static let rowHeight: CGFloat = 28

    private let rangeLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private var actions: [PanelRowAction] = []
    private var colors: ThemeColors?
    private var leadingConstraint: NSLayoutConstraint!

    var isCurrentHunk = false {
        didSet { if oldValue != isCurrentHunk { needsDisplay = true } }
    }

    var actionTitles: [String] { actions.map(\.title) }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        rangeLabel.translatesAutoresizingMaskIntoConstraints = false
        rangeLabel.lineBreakMode = .byTruncatingTail
        rangeLabel.maximumNumberOfLines = 1
        rangeLabel.cell?.usesSingleLineMode = true
        rangeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(rangeLabel)
        addSubview(actionStack)
        leadingConstraint = rangeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            leadingConstraint,
            rangeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStack.leadingAnchor.constraint(greaterThanOrEqualTo: rangeLabel.trailingAnchor, constant: 12),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `textInset`: where the range text starts (past the line gutter of the layout).
    func configure(hunk: DiffHunk, actions: [PanelRowAction], style: DiffRowStyle, theme: AppTheme, textInset: CGFloat,
                   isCurrentHunk: Bool) {
        colors = style.colors
        leadingConstraint.constant = textInset + 4
        let range = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        let text = NSMutableAttributedString(string: range, attributes: [
            .font: RetroFont.body(11), .foregroundColor: style.colors.cyan.withAlphaComponent(0.85),
        ])
        if !hunk.section.isEmpty {
            text.append(NSAttributedString(string: "  " + hunk.section, attributes: [
                .font: RetroFont.body(11), .foregroundColor: style.colors.textMuted,
            ]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        rangeLabel.attributedStringValue = text
        self.actions = actions
        for view in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, action) in actions.enumerated() {
            let button = KeyHintButton(title: action.title, hint: PanelText.keycap(action.commandID), theme: theme, kind: action.kind)
            button.tag = index
            button.target = self
            button.action = #selector(runAction(_:))
            actionStack.addArrangedSubview(button)
        }
        self.isCurrentHunk = isCurrentHunk
        needsDisplay = true
    }

    @objc private func runAction(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].perform()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        colors.bgRaised.setFill()
        bounds.fill()
        colors.borderSubtle.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        if isCurrentHunk {
            colors.accent.setFill()
            NSRect(x: 0, y: 0, width: DiffRowStyle.rail, height: bounds.height).fill()
        }
    }
}

/// A muted one-line note inside the diff list (mode change, truncation).
final class DiffNoticeCellView: NSView, DiffRowCell {
    static let identifier = NSUserInterfaceItemIdentifier("DiffNoticeCell")
    static let rowHeight: CGFloat = 28

    private let label = NSTextField(labelWithString: "")
    var isCurrentHunk = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(text: String, style: DiffRowStyle) {
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: RetroFont.body(11), .foregroundColor: style.colors.yellow,
        ])
    }
}

/// The strip above the diff: kind badge, path, `+a −d`, hunk position, the
/// diff side (UNSTAGED / STAGED / commit), the layout toggle (`v` Unified /
/// Split), and the Esc key that closes it.
final class DiffHeaderView: NSView {
    static let height: CGFloat = 32

    private var theme: AppTheme
    private let focusBar = NSView()
    private let bottomRule = NSView()
    private let badge: ChangeKindBadge
    private let pathLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let sideLabel = NSTextField(labelWithString: "")
    private let sideChip = NSView()
    let closeButton: KeyHintButton
    /// Shows the current layout (Unified / Split) with the `diff.toggleLayout` key.
    let layoutButton: KeyHintButton
    private var side: (text: String, color: NSColor?) = ("", nil)

    var isFocused = false {
        didSet { restyle() }
    }

    init(theme: AppTheme) {
        self.theme = theme
        badge = ChangeKindBadge(kind: .modified, theme: theme)
        closeButton = KeyHintButton(title: "Close", hint: nil, theme: theme)
        layoutButton = KeyHintButton(title: DiffLayout.unified.title, hint: nil, theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        for view in [focusBar, bottomRule, sideChip] {
            view.wantsLayer = true
        }
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [countsLabel, positionLabel] {
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        // In a narrow center the hunk position gives way before the path does.
        positionLabel.lineBreakMode = .byTruncatingTail
        positionLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        sideLabel.translatesAutoresizingMaskIntoConstraints = false
        sideChip.addSubview(sideLabel)
        for view in [focusBar, bottomRule, badge, pathLabel, countsLabel, positionLabel, sideChip, layoutButton, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            focusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusBar.topAnchor.constraint(equalTo: topAnchor),
            focusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            focusBar.widthAnchor.constraint(equalToConstant: PanelHeaderView.focusBarWidth),
            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomRule.heightAnchor.constraint(equalToConstant: 1),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countsLabel.leadingAnchor.constraint(equalTo: pathLabel.trailingAnchor, constant: 10),
            countsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            positionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: countsLabel.trailingAnchor, constant: 12),
            positionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            sideChip.leadingAnchor.constraint(equalTo: positionLabel.trailingAnchor, constant: 10),
            sideChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            sideChip.heightAnchor.constraint(equalToConstant: 18),
            sideLabel.leadingAnchor.constraint(equalTo: sideChip.leadingAnchor, constant: 6),
            sideLabel.trailingAnchor.constraint(equalTo: sideChip.trailingAnchor, constant: -6),
            sideLabel.centerYAnchor.constraint(equalTo: sideChip.centerYAnchor),
            layoutButton.leadingAnchor.constraint(equalTo: sideChip.trailingAnchor, constant: 10),
            layoutButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: layoutButton.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var pathText: String { pathLabel.stringValue }
    var sideText: String { side.text }
    var positionText: String { positionLabel.stringValue }
    var layoutText: String { layoutButton.title }

    func show(layout: DiffLayout) {
        layoutButton.title = layout.title
        layoutButton.setAccessibilityLabel("Toggle Split Diff (\(layout.title))")
    }

    func update(path: String, oldPath: String?, kind: ChangeKind?, additions: Int?, deletions: Int?, showCounts: Bool,
                side: String, sideColor: NSColor?, position: String) {
        let colors = theme.colors
        badge.isHidden = kind == nil
        if let kind { badge.kind = kind }
        pathLabel.attributedStringValue = PanelText.path(path, oldPath: oldPath, colors: colors)
        pathLabel.toolTip = path
        countsLabel.attributedStringValue = showCounts
            ? PanelText.counts(additions: additions, deletions: deletions, colors: colors)
            : NSAttributedString()
        positionLabel.setRetroText(position, color: colors.textMuted)
        self.side = (side, sideColor)
        restyle()
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        badge.apply(theme: theme)
        closeButton.apply(theme: theme)
        layoutButton.apply(theme: theme)
        restyle()
    }

    private func restyle() {
        let colors = theme.colors
        layer?.backgroundColor = (isFocused ? colors.bgRaised : colors.bgPanel).cgColor
        focusBar.isHidden = !isFocused
        focusBar.layer?.backgroundColor = colors.accent.cgColor
        bottomRule.layer?.backgroundColor = colors.borderSubtle.cgColor
        let tint = side.color ?? colors.accent
        sideChip.layer?.borderWidth = 1
        sideChip.layer?.borderColor = tint.cgColor
        sideChip.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        sideLabel.setRetroText(side.text, color: tint)
        sideChip.isHidden = side.text.isEmpty
        closeButton.hint = PanelText.keycap("diff.close")
        layoutButton.hint = PanelText.keycap("diff.toggleLayout")
    }
}

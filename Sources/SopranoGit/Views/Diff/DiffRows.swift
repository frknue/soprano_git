import AppKit
import SopranoGitCore

/// Fonts, colors and gutter metrics every diff row draws with; rebuilt when
/// the theme or the file changes so rows never build attributes per draw.
/// Code is SF Mono 12 on an 18 pt line, line numbers SF Mono 11 muted.
@MainActor
struct DiffRowStyle {
    let colors: ThemeColors
    let textAttributes: [NSAttributedString.Key: Any]
    let mutedAttributes: [NSAttributedString.Key: Any]
    let numberAttributes: [NSAttributedString.Key: Any]
    /// Keyword and heading tokens.
    let semiboldFont: NSFont
    /// Comment tokens.
    let italicFont: NSFont
    let addedMarker: NSAttributedString
    let removedMarker: NSAttributedString
    /// Width of one line-number column.
    let numberWidth: CGFloat
    /// Advance of one character of the (monospaced) code font.
    let columnWidth: CGFloat
    let markerWidth: CGFloat = 16
    /// Narrowest line-number column (`.gutter` in the mock).
    static let minimumNumberWidth: CGFloat = 44
    /// Space between a line number and its column's right edge.
    static let numberPadding: CGFloat = 8
    /// Space after the code text.
    static let codePadding: CGFloat = 8
    /// Where the text sits vertically inside an 18 pt line row.
    static let textTop: CGFloat = 2
    /// Lines longer than this are cut before drawing (the row truncates them anyway).
    nonisolated static let maximumDrawnLength = 2000

    init(theme: AppTheme, maxLineNumber: Int) {
        colors = theme.colors
        let code = ChromeFont.mono
        let small = ChromeFont.monoSmall
        semiboldFont = ChromeFont.monospaced(size: code.pointSize, weight: .semibold)
        italicFont = NSFont(descriptor: code.fontDescriptor.withSymbolicTraits(.italic), size: code.pointSize) ?? code
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        textAttributes = [.font: code, .foregroundColor: colors.syntaxPlain, .paragraphStyle: paragraph]
        mutedAttributes = [.font: code, .foregroundColor: colors.textMuted, .paragraphStyle: paragraph]
        numberAttributes = [.font: small, .foregroundColor: colors.textMuted]
        addedMarker = NSAttributedString(string: "+", attributes: [.font: semiboldFont, .foregroundColor: colors.success])
        removedMarker = NSAttributedString(string: "−", attributes: [.font: semiboldFont, .foregroundColor: colors.danger])
        let digits = max(3, String(max(1, maxLineNumber)).count)
        let digitWidth = NSAttributedString(string: "0", attributes: [.font: small]).size().width
        numberWidth = max(Self.minimumNumberWidth, ceil(CGFloat(digits) * digitWidth) + Self.numberPadding * 2)
        columnWidth = NSAttributedString(string: "0", attributes: [.font: code]).size().width
    }

    /// Unified layout: where the two-number gutter ends and the code starts.
    var gutterWidth: CGFloat { numberWidth * 2 }
    /// Split layout: each side's one-number gutter.
    var sideGutterWidth: CGFloat { numberWidth }

    /// Where code text goes in a unified row, or a split side, spanning
    /// `minX..<maxX` with a `gutter`: past the gutter and the +/− marker.
    func textSpan(from minX: CGFloat, to maxX: CGFloat, gutter: CGFloat) -> (minX: CGFloat, maxX: CGFloat) {
        (minX + gutter + markerWidth, maxX - Self.codePadding)
    }

    /// Horizontal scrolling of the code text in rows `rowWidth` wide: `limit`
    /// is how far the widest line overflows its text area (plus one spare
    /// column, so it ends unclipped), `visible` the width of that text area.
    /// Both split sides scroll together; the side that overflows most sets it.
    func textScroll(of document: DiffDocument, layout: DiffLayout, rowWidth: CGFloat) -> (limit: CGFloat, visible: CGFloat) {
        func scroll(columns: Int, span: (minX: CGFloat, maxX: CGFloat)) -> (limit: CGFloat, visible: CGFloat) {
            let visible = max(0, span.maxX - span.minX)
            guard columns > 0 else { return (0, visible) }
            return (max(0, ceil(CGFloat(columns + 1) * columnWidth - visible)), visible)
        }
        switch layout {
        case .unified:
            return scroll(
                columns: max(document.oldColumns, document.newColumns),
                span: textSpan(from: 0, to: rowWidth, gutter: gutterWidth)
            )
        case .split:
            let divider = DiffSplitLineCellView.dividerX(rowWidth: rowWidth)
            let old = scroll(columns: document.oldColumns, span: textSpan(from: 0, to: divider, gutter: sideGutterWidth))
            let new = scroll(
                columns: document.newColumns,
                span: textSpan(from: divider + 1, to: rowWidth, gutter: sideGutterWidth)
            )
            return old.limit >= new.limit ? old : new
        }
    }

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

    /// Where a marker starts inside its column: centred (all markers are one
    /// monospaced column wide).
    var markerInset: CGFloat { floor((markerWidth - columnWidth) / 2) }

    /// The line's text in `syntaxPlain`, colored and weighted by its syntax
    /// tokens, with the changed words of a paired line (`emphasis`, a UTF-16
    /// range of the raw line from `DiffDocument.changedRange`) on a
    /// `diffAddWord` / `diffDeleteWord` background; tabs shown as four spaces.
    func text(of line: DiffLine, tokens: [SyntaxToken]?, emphasis: NSRange?) -> NSAttributedString {
        if line.kind == .noNewlineMarker {
            return NSAttributedString(string: DiffDocument.noNewlineText, attributes: mutedAttributes)
        }
        let raw = line.text
        let cut = raw.utf16.count > Self.maximumDrawnLength ? String(raw.prefix(Self.maximumDrawnLength)) : raw
        let text = NSMutableAttributedString(string: cut, attributes: textAttributes)
        let length = text.length
        for token in tokens ?? [] where token.range.location < length {
            let range = NSRange(location: token.range.location, length: min(token.range.length, length - token.range.location))
            text.addAttribute(.foregroundColor, value: token.kind.color(in: colors), range: range)
            // The vendored kind faces (`isEmphasized`, `isItalic`), with the
            // fonts cached in the style so drawing a row allocates none.
            if token.kind.isEmphasized {
                text.addAttribute(.font, value: semiboldFont, range: range)
            } else if token.kind.isItalic {
                text.addAttribute(.font, value: italicFont, range: range)
            }
        }
        if let emphasis, emphasis.location < length, let background = emphasisColor(for: line.kind) {
            let range = NSRange(location: emphasis.location, length: min(emphasis.length, length - emphasis.location))
            text.addAttribute(.backgroundColor, value: background, range: range)
        }
        if cut.contains("\t") {
            // Each replacement takes the attributes of the tab it replaces.
            text.mutableString.replaceOccurrences(of: "\t", with: "    ", options: [], range: NSRange(location: 0, length: length))
        }
        return text
    }

    /// Changed words: `diffAddWord` on added lines, `diffDeleteWord` on removed ones.
    func emphasisColor(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: colors.diffAddWord
        case .removed: colors.diffDeleteWord
        case .context, .noNewlineMarker: nil
        }
    }

    /// Added and removed lines are tinted `diffAdd` / `diffDelete`.
    func tint(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: colors.diffAdd
        case .removed: colors.diffDelete
        case .context, .noNewlineMarker: nil
        }
    }
}

/// Drawing shared by the unified and split line rows.
@MainActor
enum DiffRowDrawing {
    /// A line number right-aligned in the column ending at `right`.
    static func draw(number: NSAttributedString?, right: CGFloat, height: CGFloat) {
        guard let number else { return }
        let size = number.size()
        number.draw(at: NSPoint(x: right - DiffRowStyle.numberPadding - size.width, y: floor((height - size.height) / 2)))
    }

    /// Code text from `x` to `maxX`, scrolled left by `offset` (clipped at
    /// `x`) and cut with a tail ellipsis when the rest does not fit.
    static func draw(text: NSAttributedString, x: CGFloat, maxX: CGFloat, offset: CGFloat, height: CGFloat) {
        let width = maxX - x
        guard width > 4 else { return }
        if offset > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: x, y: 0, width: width, height: height).clip()
        }
        text.draw(
            with: NSRect(x: x - offset, y: DiffRowStyle.textTop, width: width + offset, height: height - DiffRowStyle.textTop),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
        if offset > 0 {
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// One line-number column: `bgPanel` ending in a `borderSubtle` hairline.
    static func drawGutter(from x: CGFloat, width: CGFloat, height: CGFloat, colors: ThemeColors) {
        colors.bgPanel.setFill()
        NSRect(x: x, y: 0, width: width, height: height).fill()
        colors.borderSubtle.setFill()
        NSRect(x: x + width - Chrome.hairline, y: 0, width: Chrome.hairline, height: height).fill()
    }

    /// The side of a split row without a line: a flat `diffFiller` wash.
    static func drawFiller(in rect: NSRect, colors: ThemeColors) {
        colors.diffFiller.setFill()
        rect.fill(using: .sourceOver)
    }

    /// The current hunk's 2×14 pencil tick, `x` from the row's left edge.
    static func drawTick(x: CGFloat, height: CGFloat, colors: ThemeColors) {
        let tick = NSRect(
            x: x, y: floor((height - Chrome.tickHeight) / 2), width: Chrome.tickWidth, height: Chrome.tickHeight
        )
        colors.pencilTick.setFill()
        NSBezierPath(roundedRect: tick, xRadius: 1, yRadius: 1).fill()
    }
}

/// A unified or split line row. Its code text is scrolled left by
/// `textOffset` (the diff's horizontal scroll); gutters and markers stay put.
/// The first changed row of the current hunk carries the pencil tick.
@MainActor
protocol DiffLineRowCell: NSView {
    var textOffset: CGFloat { get set }
    var isCurrentChange: Bool { get set }
}

/// One unified diff line: old/new line-number columns, +/− marker, text;
/// added and removed lines tinted. Drawn directly for speed; `configure`
/// builds the row's attributed strings once.
final class DiffLineCellView: NSView, DiffLineRowCell {
    static let identifier = NSUserInterfaceItemIdentifier("DiffLineCell")
    static let rowHeight: CGFloat = 18

    private(set) var line: DiffLine?
    private var style: DiffRowStyle?
    private var oldNumber: NSAttributedString?
    private var newNumber: NSAttributedString?
    /// The drawn text, syntax colors and word emphasis applied.
    private(set) var text = NSAttributedString()
    var isCurrentChange = false {
        didSet { if oldValue != isCurrentChange { needsDisplay = true } }
    }
    var textOffset: CGFloat = 0 {
        didSet { if oldValue != textOffset { needsDisplay = true } }
    }

    /// Where the pencil tick is drawn; nil when the row has none.
    var tickX: CGFloat? { isCurrentChange ? Chrome.tickInset : nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(line: DiffLine, tokens: [SyntaxToken]?, emphasis: NSRange?, style: DiffRowStyle, isCurrentChange: Bool) {
        self.line = line
        self.style = style
        oldNumber = style.number(line.oldNumber)
        newNumber = style.number(line.newNumber)
        text = style.text(of: line, tokens: tokens, emphasis: emphasis)
        self.isCurrentChange = isCurrentChange
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
        DiffRowDrawing.drawGutter(from: 0, width: style.numberWidth, height: height, colors: colors)
        DiffRowDrawing.drawGutter(from: style.numberWidth, width: style.numberWidth, height: height, colors: colors)
        DiffRowDrawing.draw(number: oldNumber, right: style.numberWidth, height: height)
        DiffRowDrawing.draw(number: newNumber, right: style.gutterWidth, height: height)
        style.marker(for: line.kind)?.draw(at: NSPoint(x: style.gutterWidth + style.markerInset, y: DiffRowStyle.textTop))
        let span = style.textSpan(from: 0, to: bounds.width, gutter: style.gutterWidth)
        DiffRowDrawing.draw(text: text, x: span.minX, maxX: span.maxX, offset: textOffset, height: height)
        if let tickX {
            DiffRowDrawing.drawTick(x: tickX, height: height, colors: colors)
        }
    }
}

/// One split diff row: the old line on the left, the new line on the right,
/// each with its own line-number column, +/− marker, text and tint, divided
/// by a `borderSubtle` hairline. A missing side is a flat filler.
final class DiffSplitLineCellView: NSView, DiffLineRowCell {
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
    var isCurrentChange = false {
        didSet { if oldValue != isCurrentChange { needsDisplay = true } }
    }
    var textOffset: CGFloat = 0 {
        didSet { if oldValue != textOffset { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(old oldLine: DiffLine?, oldTokens: [SyntaxToken]?, oldEmphasis: NSRange?,
                   new newLine: DiffLine?, newTokens: [SyntaxToken]?, newEmphasis: NSRange?,
                   style: DiffRowStyle, isCurrentChange: Bool) {
        self.style = style
        old = Side(
            line: oldLine, number: style.number(oldLine?.oldNumber),
            text: oldLine.map { style.text(of: $0, tokens: oldTokens, emphasis: oldEmphasis) }
        )
        new = Side(
            line: newLine, number: style.number(newLine?.newNumber),
            text: newLine.map { style.text(of: $0, tokens: newTokens, emphasis: newEmphasis) }
        )
        self.isCurrentChange = isCurrentChange
        needsDisplay = true
    }

    /// Left edge of the right side; the hairline sits just before it.
    var dividerX: CGFloat { Self.dividerX(rowWidth: bounds.width) }

    static func dividerX(rowWidth: CGFloat) -> CGFloat { floor(rowWidth / 2) }

    /// Where the pencil tick is drawn: on the left side when it shows a
    /// removed line, else on the right; nil when the row has none.
    var tickX: CGFloat? {
        guard isCurrentChange else { return nil }
        return (old.line?.kind == .removed ? 0 : dividerX + 1) + Chrome.tickInset
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let colors = style.colors
        let height = bounds.height
        let divider = dividerX
        draw(old, from: 0, to: divider, style: style)
        draw(new, from: divider + 1, to: bounds.width, style: style)
        colors.borderSubtle.setFill()
        NSRect(x: divider, y: 0, width: Chrome.hairline, height: height).fill()
        if let tickX {
            DiffRowDrawing.drawTick(x: tickX, height: height, colors: colors)
        }
    }

    private func draw(_ side: Side, from minX: CGFloat, to maxX: CGFloat, style: DiffRowStyle) {
        let colors = style.colors
        let height = bounds.height
        let gutter = style.sideGutterWidth
        guard let line = side.line else {
            DiffRowDrawing.drawGutter(from: minX, width: gutter, height: height, colors: colors)
            DiffRowDrawing.drawFiller(
                in: NSRect(x: minX + gutter, y: 0, width: max(0, maxX - minX - gutter), height: height), colors: colors
            )
            return
        }
        if let tint = style.tint(for: line.kind) {
            tint.setFill()
            NSRect(x: minX, y: 0, width: maxX - minX, height: height).fill(using: .sourceOver)
        }
        DiffRowDrawing.drawGutter(from: minX, width: gutter, height: height, colors: colors)
        DiffRowDrawing.draw(number: side.number, right: minX + gutter, height: height)
        style.marker(for: line.kind)?.draw(at: NSPoint(x: minX + gutter + style.markerInset, y: DiffRowStyle.textTop))
        if let text = side.text {
            let span = style.textSpan(from: minX, to: maxX, gutter: gutter)
            DiffRowDrawing.draw(text: text, x: span.minX, maxX: span.maxX, offset: textOffset, height: height)
        }
    }
}

/// Hunk header strip (Folio `.diff-row.is-hunk`): `bgPanel` between two
/// `borderSubtle` hairlines, `@@ -a,b +c,d @@` in cyan and the section text
/// in ink (SF Mono 11), and the hunk's actions (Stage hunk / Discard, or
/// Unstage hunk) with their keycaps.
final class DiffHunkHeaderCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffHunkHeaderCell")
    static let rowHeight: CGFloat = 26
    private static let padding = Chrome.Space.bar

    private let rangeLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private var actions: [PanelRowAction] = []
    private var colors: ThemeColors?

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
        NSLayoutConstraint.activate([
            rangeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            rangeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStack.leadingAnchor.constraint(greaterThanOrEqualTo: rangeLabel.trailingAnchor, constant: Self.padding),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(hunk: DiffHunk, actions: [PanelRowAction], style: DiffRowStyle, theme: AppTheme) {
        colors = style.colors
        let font = ChromeFont.monoSmall
        let range = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        let text = NSMutableAttributedString(string: range, attributes: [
            .font: font, .foregroundColor: style.colors.cyan,
        ])
        if !hunk.section.isEmpty {
            text.append(NSAttributedString(string: "  " + hunk.section, attributes: [
                .font: font, .foregroundColor: style.colors.textPrimary,
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
            let button = KeyHintButton(
                title: action.title, hint: SettingsCenter.shared.keycaps(for: action.commandID), theme: theme,
                kind: action.kind
            )
            button.tag = index
            button.target = self
            button.action = #selector(runAction(_:))
            actionStack.addArrangedSubview(button)
        }
        needsDisplay = true
    }

    @objc private func runAction(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].perform()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        colors.bgPanel.setFill()
        bounds.fill()
        colors.borderSubtle.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Chrome.hairline).fill()
        NSRect(x: 0, y: bounds.height - Chrome.hairline, width: bounds.width, height: Chrome.hairline).fill()
    }
}

/// A one-line note inside the diff list (mode change, truncation), in yellow.
final class DiffNoticeCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffNoticeCell")
    static let rowHeight: CGFloat = 28

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.bar),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Chrome.Space.bar),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(text: String, style: DiffRowStyle) {
        label.setChromeText(text, font: ChromeFont.label, color: style.colors.yellow)
    }
}

/// The strip above the diff (Folio `.diff-head`): change letter, path (folder
/// muted, name Semibold) and `+a −d`; then `Hunk 3 of 4`, Previous K / Next J,
/// the side chip (commit SHA, stash, Unstaged / Staged), the Split | Inline
/// control with its `V` cap, and Close esc. `bgBase` over a hairline, with the
/// 2 pt focus rule while the diff holds focus. When the strip is narrow the
/// file name is the last thing to go: first the hunk position hides, then the
/// side chip, then the buttons and segments drop their captions and keep their
/// icons and keycaps, then the `+a −d` counts; the path drops leading folders
/// (`…/Views/`) throughout.
final class DiffHeaderView: NSView {
    static let height: CGFloat = 32

    /// How much the strip gave up to keep the file name readable.
    enum Compaction: Int, Comparable, CaseIterable {
        case full
        case withoutPosition
        case withoutSide
        case keycapsOnly
        case withoutCounts

        static func < (lhs: Compaction, rhs: Compaction) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What the side chip names: a word (Unstaged, Staged) in SF Pro, or an
    /// id (commit SHA, `stash@{0}`) in SF Mono.
    enum Side: Equatable {
        case word(String)
        case identifier(String)

        var text: String {
            switch self {
            case let .word(text), let .identifier(text): text
            }
        }
    }

    private var theme: AppTheme
    private let bottomRule = ChromeRuleView(axis: .horizontal)
    private let focusRule = ChromeRuleView(axis: .horizontal, thickness: Chrome.focusMarkWidth)
    private let badge: ChangeKindBadge
    private let pathLabel = NSTextField(labelWithString: "")
    /// Measures path candidates the way `pathLabel` lays them out; never shown.
    private let measuringLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let sideLabel = NSTextField(labelWithString: "")
    private let sideChip = NSView()
    private let trailingStack = NSStackView()
    /// Previous K: the previous hunk.
    let previousButton: KeyHintButton
    /// Next J: the next hunk.
    let nextButton: KeyHintButton
    /// Split | Inline, followed by the `diff.toggleLayout` cap.
    let layoutControl: DiffLayoutControl
    private let layoutKeycaps: ChromeKeycapGroupView
    let closeButton: KeyHintButton
    private var side = Side.word("")
    private var position = ""
    private var layout = DiffLayout.unified
    private var path = ""
    private var oldPath: String?
    /// The open file's name, kept readable as "…/name" for as long as possible.
    private var fileName = ""
    /// `+a −d`, shown unless the strip is at its narrowest.
    private var counts = NSAttributedString()
    private(set) var compaction = Compaction.full

    var isFocused = false {
        didSet { focusRule.isHidden = !isFocused }
    }

    private static let closeTitle = "Close"
    private static let previousTitle = "Previous"
    private static let nextTitle = "Next"
    private static let leadingInset: CGFloat = 14
    private static let trailingInset: CGFloat = 8
    private static let pathGap: CGFloat = 8
    /// The strip's 8 pt gap plus the diffstat's 4 pt margin.
    private static let countsGap: CGFloat = 12
    private static let trailingGap: CGFloat = 12
    private static let itemSpacing: CGFloat = 8
    /// After the hunk position (its 2 pt margin) and before the segments.
    private static let nearSpacing: CGFloat = 10
    /// Around the 8 pt separators: before the side chip and before Close.
    private static let groupSpacing: CGFloat = 24
    private static let chipPadding: CGFloat = 6
    /// `.diff-head .btn-plain`: padding 0 6, 5 pt between icon, title and caps.
    private static let buttonPadding: CGFloat = 6
    private static let buttonGap: CGFloat = 5

    init(theme: AppTheme) {
        self.theme = theme
        badge = ChangeKindBadge(kind: .modified, theme: theme)
        previousButton = KeyHintButton(
            title: Self.previousTitle, hint: nil, theme: theme, kind: .text, height: Chrome.controlHeight
        )
        nextButton = KeyHintButton(title: Self.nextTitle, hint: nil, theme: theme, kind: .text, height: Chrome.controlHeight)
        closeButton = KeyHintButton(title: Self.closeTitle, hint: nil, theme: theme, kind: .text, height: Chrome.controlHeight)
        layoutControl = DiffLayoutControl(theme: theme)
        layoutKeycaps = ChromeKeycapGroupView(caps: [], theme: theme, style: .small, tone: .muted)
        super.init(frame: .zero)
        wantsLayer = true
        for button in [previousButton, nextButton, closeButton] {
            button.horizontalPadding = Self.buttonPadding
            button.contentGap = Self.buttonGap
        }
        previousButton.symbolName = "chevron.up"
        nextButton.symbolName = "chevron.down"
        previousButton.setAccessibilityLabel("Previous Hunk")
        nextButton.setAccessibilityLabel("Next Hunk")
        closeButton.setAccessibilityLabel("Close Diff")
        sideChip.wantsLayer = true
        sideChip.layer?.cornerRadius = Chrome.Radius.cap
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [countsLabel, positionLabel] {
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        sideLabel.translatesAutoresizingMaskIntoConstraints = false
        sideChip.addSubview(sideLabel)
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = Self.itemSpacing
        trailingStack.detachesHiddenViews = true
        trailingStack.setHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [positionLabel, previousButton, nextButton, sideChip, layoutControl, layoutKeycaps, closeButton] as [NSView] {
            trailingStack.addArrangedSubview(view)
        }
        trailingStack.setCustomSpacing(Self.nearSpacing, after: positionLabel)
        trailingStack.setCustomSpacing(Self.groupSpacing, after: nextButton)
        trailingStack.setCustomSpacing(Self.nearSpacing, after: sideChip)
        trailingStack.setCustomSpacing(Self.groupSpacing, after: layoutKeycaps)
        for view in [badge, pathLabel, countsLabel, trailingStack, bottomRule, focusRule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            focusRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            focusRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: Self.pathGap),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countsLabel.leadingAnchor.constraint(equalTo: pathLabel.trailingAnchor, constant: Self.countsGap),
            countsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: countsLabel.trailingAnchor, constant: Self.trailingGap),
            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            sideChip.heightAnchor.constraint(equalToConstant: Chrome.chipHeight),
            sideLabel.leadingAnchor.constraint(equalTo: sideChip.leadingAnchor, constant: Self.chipPadding),
            sideLabel.trailingAnchor.constraint(equalTo: sideChip.trailingAnchor, constant: -Self.chipPadding),
            sideLabel.centerYAnchor.constraint(equalTo: sideChip.centerYAnchor),
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var pathText: String { path }
    var sideText: String { side.text }
    var positionText: String { position }
    var layoutText: String { layout.title }
    var isPositionShown: Bool { !positionLabel.isHidden }
    var isSideShown: Bool { !sideChip.isHidden }
    var isFocusRuleShown: Bool { !focusRule.isHidden }

    func show(layout: DiffLayout) {
        self.layout = layout
        layoutControl.layout = layout
        updateCompaction()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCompaction()
    }

    /// Picks the least compaction that leaves room for "…/name"; the counts
    /// only go once even "…name" (the bare file name) no longer fits. The
    /// path then drops as many leading folders as the room needs.
    private func updateCompaction() {
        // Measured as the path label lays it out: string plus the label's text insets.
        func width(_ text: String) -> CGFloat {
            measuringLabel.attributedStringValue = PanelText.path(text, colors: theme.colors)
            return measuringLabel.intrinsicContentSize.width
        }
        let withFolder = width("…/" + fileName)
        let labelInsets = withFolder - ceil(measuringLabel.attributedStringValue.size().width)
        let bare = width("…" + fileName)
        var chosen = Compaction.withoutCounts
        for level in Compaction.allCases {
            apply(level)
            let needed = level == .keycapsOnly ? bare : withFolder
            if level == .withoutCounts || pathRoom >= needed {
                chosen = level
                break
            }
        }
        apply(chosen)
        compaction = chosen
        let shown = PanelText.path(
            path, oldPath: oldPath, colors: theme.colors, availableWidth: max(0, pathRoom - labelInsets)
        )
        if pathLabel.attributedStringValue != shown { pathLabel.attributedStringValue = shown }
    }

    /// Width left for the path once everything else in the strip has its size.
    private var pathRoom: CGFloat {
        let visible = trailingStack.arrangedSubviews.filter { !$0.isHidden }
        var trailing: CGFloat = 0
        for (index, view) in visible.enumerated() {
            trailing += width(of: view)
            if index < visible.count - 1 {
                let custom = trailingStack.customSpacing(after: view)
                trailing += custom == NSStackView.useDefaultSpacing ? trailingStack.spacing : custom
            }
        }
        let leading = Self.leadingInset + badge.intrinsicContentSize.width + Self.pathGap
        let counts = Self.countsGap + countsLabel.intrinsicContentSize.width + Self.trailingGap
        return bounds.width - leading - counts - trailing - Self.trailingInset
    }

    private func width(of view: NSView) -> CGFloat {
        if view === sideChip { return ceil(sideLabel.intrinsicContentSize.width) + Self.chipPadding * 2 }
        let intrinsic = view.intrinsicContentSize.width
        return intrinsic == NSView.noIntrinsicMetric ? view.fittingSize.width : intrinsic
    }

    private func apply(_ level: Compaction) {
        positionLabel.isHidden = position.isEmpty || level >= .withoutPosition
        sideChip.isHidden = side.text.isEmpty || level >= .withoutSide
        let captions = level < .keycapsOnly
        for (button, title) in [(previousButton, Self.previousTitle), (nextButton, Self.nextTitle), (closeButton, Self.closeTitle)] {
            let shown = captions ? title : ""
            if button.title != shown { button.title = shown }
        }
        layoutControl.showsTitles = captions
        let shownCounts = level < .withoutCounts ? counts : NSAttributedString()
        if countsLabel.attributedStringValue != shownCounts { countsLabel.attributedStringValue = shownCounts }
    }

    func update(path: String, oldPath: String?, kind: ChangeKind?, additions: Int?, deletions: Int?, showCounts: Bool,
                side: Side, position: String) {
        let colors = theme.colors
        badge.isHidden = kind == nil
        if let kind { badge.kind = kind }
        self.path = path
        self.oldPath = oldPath
        pathLabel.toolTip = path
        fileName = path.split(separator: "/").last.map(String.init) ?? path
        counts = showCounts
            ? PanelText.counts(additions: additions, deletions: deletions, colors: colors)
            : NSAttributedString()
        countsLabel.attributedStringValue = counts
        positionLabel.setChromeText(position, font: ChromeFont.count, color: colors.textMuted)
        previousButton.isEnabled = !position.isEmpty
        nextButton.isEnabled = !position.isEmpty
        self.position = position
        self.side = side
        restyle()
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        badge.apply(theme: theme)
        previousButton.apply(theme: theme)
        nextButton.apply(theme: theme)
        layoutControl.apply(theme: theme)
        layoutKeycaps.apply(theme: theme)
        closeButton.apply(theme: theme)
        restyle()
    }

    private func restyle() {
        let colors = theme.colors
        layer?.backgroundColor = colors.bgBase.cgColor
        bottomRule.color = colors.borderSubtle
        focusRule.color = colors.focusMark
        focusRule.isHidden = !isFocused
        sideChip.layer?.borderWidth = Chrome.hairline
        sideChip.layer?.borderColor = colors.borderStrong.cgColor
        let sideFont = switch side {
        case .word: ChromeFont.sans(size: 11, weight: .medium)
        case .identifier: ChromeFont.monoSmall
        }
        sideLabel.setChromeText(side.text, font: sideFont, color: colors.textMuted)
        let settings = SettingsCenter.shared
        previousButton.hint = settings.keycaps(for: "diff.previousHunk")
        nextButton.hint = settings.keycaps(for: "diff.nextHunk")
        closeButton.hint = settings.keycaps(for: "diff.close")
        let layoutCaps = settings.keycaps(for: "diff.toggleLayout") ?? []
        if layoutKeycaps.caps != layoutCaps { layoutKeycaps.caps = layoutCaps }
        layoutKeycaps.isHidden = layoutCaps.isEmpty
        updateCompaction()
    }
}

/// The diff's Split | Inline control (Folio `.segmented`): a 24 pt
/// `bgOverlay` track holding two 20 pt segments, the active one raised with a
/// `borderSubtle` edge and an ink Medium label, the other muted. Clicking the
/// other segment calls `onSelect`. Without titles (a narrow strip) the
/// segments keep only their icons.
final class DiffLayoutControl: NSView {
    /// Left to right.
    static let segments: [DiffLayout] = [.split, .unified]
    private static let segmentHeight: CGFloat = 20
    private static let trackPadding: CGFloat = 2
    private static let segmentPadding: CGFloat = 8
    private static let iconGap: CGFloat = 5
    private static let iconSize: CGFloat = 13

    var layout = DiffLayout.unified {
        didSet {
            guard oldValue != layout else { return }
            setAccessibilityValue(layout.title)
            needsDisplay = true
        }
    }

    var showsTitles = true {
        didSet {
            guard oldValue != showsTitles else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Called with the clicked segment's layout when it is not the active one.
    var onSelect: ((DiffLayout) -> Void)?

    /// The segment titles drawn now, left to right; empty without titles.
    var visibleTitles: [String] { showsTitles ? Self.segments.map(\.title) : [] }

    private var theme: AppTheme

    /// One segment's icon and label, active (ink, Medium) and inactive
    /// (muted); built once per theme.
    private struct Content {
        var activeIcon: NSImage?
        var inactiveIcon: NSImage?
        var activeTitle: NSAttributedString
        var inactiveTitle: NSAttributedString
        var iconWidth: CGFloat
        /// Of the Medium label, so the segments do not move when the active one changes.
        var titleWidth: CGFloat
    }

    private var content: [DiffLayout: Content] = [:]

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Toggle Split Diff")
        setAccessibilityValue(layout.title)
        rebuildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func apply(theme: AppTheme) {
        self.theme = theme
        rebuildContent()
        needsDisplay = true
    }

    private static func symbolName(of layout: DiffLayout) -> String {
        layout == .split ? "rectangle.split.2x1" : "list.bullet"
    }

    private func rebuildContent() {
        let colors = theme.colors
        let base = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .regular)
        for layout in Self.segments {
            let image = NSImage(systemSymbolName: Self.symbolName(of: layout), accessibilityDescription: nil)
            let activeIcon = image?.withSymbolConfiguration(base.applying(.init(paletteColors: [colors.textPrimary])))
            let activeTitle = ChromeText.attributed(
                layout.title, font: ChromeFont.labelStrong, color: colors.textPrimary, lineBreakMode: .byClipping
            )
            content[layout] = Content(
                activeIcon: activeIcon,
                inactiveIcon: image?.withSymbolConfiguration(base.applying(.init(paletteColors: [colors.textMuted]))),
                activeTitle: activeTitle,
                inactiveTitle: ChromeText.attributed(
                    layout.title, font: ChromeFont.label, color: colors.textMuted, lineBreakMode: .byClipping
                ),
                iconWidth: ceil(activeIcon?.size.width ?? Self.iconSize),
                titleWidth: ceil(activeTitle.size().width)
            )
        }
        invalidateIntrinsicContentSize()
    }

    private func segmentWidth(of layout: DiffLayout) -> CGFloat {
        guard let content = content[layout] else { return 0 }
        var width = Self.segmentPadding * 2 + content.iconWidth
        if showsTitles {
            width += Self.iconGap + content.titleWidth
        }
        return width
    }

    private var segmentRects: [(layout: DiffLayout, rect: NSRect)] {
        var x = Self.trackPadding
        let y = floor((bounds.height - Self.segmentHeight) / 2)
        return Self.segments.map { layout in
            let width = segmentWidth(of: layout)
            defer { x += width + Self.trackPadding }
            return (layout, NSRect(x: x, y: y, width: width, height: Self.segmentHeight))
        }
    }

    override var intrinsicContentSize: NSSize {
        let segments = Self.segments.reduce(0) { $0 + segmentWidth(of: $1) }
        let gaps = Self.trackPadding * CGFloat(Self.segments.count + 1)
        return NSSize(width: segments + gaps, height: Chrome.controlHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        colors.bgOverlay.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Chrome.Radius.control, yRadius: Chrome.Radius.control).fill()
        for (segment, rect) in segmentRects {
            let isActive = segment == layout
            if isActive {
                let shape = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Chrome.Radius.cap, yRadius: Chrome.Radius.cap
                )
                colors.bgRaised.setFill()
                shape.fill()
                colors.borderSubtle.setStroke()
                shape.lineWidth = Chrome.hairline
                shape.stroke()
            }
            guard let content = content[segment] else { continue }
            let x = rect.minX + Self.segmentPadding
            if let icon = isActive ? content.activeIcon : content.inactiveIcon {
                let size = icon.size
                icon.draw(
                    in: NSRect(x: x, y: rect.minY + floor((rect.height - size.height) / 2), width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
                )
            }
            guard showsTitles else { continue }
            let title = isActive ? content.activeTitle : content.inactiveTitle
            let height = title.size().height
            title.draw(at: NSPoint(
                x: x + content.iconWidth + Self.iconGap, y: rect.minY + floor((rect.height - height) / 2)
            ))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = segmentRects.first(where: { $0.rect.insetBy(dx: -1, dy: -2).contains(point) }),
              hit.layout != layout else { return }
        onSelect?(hit.layout)
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(layout.toggled)
        return true
    }
}

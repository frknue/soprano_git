import AppKit
import SopranoGitCore

/// Search state of a row, drawn as a rail in the first column.
enum GraphMatchState {
    case none
    case match
    case current
}

/// The GRAPH cell: every line crossing the row, then the node, per the `GraphLayout`
/// drawing contract. Draws straight into the context; no paths or colors are created.
final class GraphLaneView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("graph.cell.lanes")

    private var style: GraphStyle?
    private var row: GraphLayout.Row?
    private var rowIndex = 0
    private var isHead = false
    private var hasRefs = false
    private var workingCopyLane: Int?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// `workingCopyLane`: the lane of the working copy's dashed edge while it runs
    /// through this row (drawn muted instead of in the lane color), else nil.
    func configure(
        row: GraphLayout.Row, index: Int, isHead: Bool, hasRefs: Bool, workingCopyLane: Int? = nil, style: GraphStyle
    ) {
        self.row = row
        self.rowIndex = index
        self.isHead = isHead
        self.hasRefs = hasRefs
        self.workingCopyLane = workingCopyLane
        self.style = style
        needsDisplay = true
    }

    /// Half the node's footprint; lines stop at it for hollow glyphs.
    private static let nodeExtent = GraphMetrics.nodeSize / 2

    override func draw(_ dirtyRect: NSRect) {
        guard let style, let row, let context = NSGraphicsContext.current?.cgContext else { return }
        let mid = GraphMetrics.rowHeight / 2
        let bottom = GraphMetrics.rowHeight
        let nodeX = GraphMetrics.laneX(row.lane)
        let isHollow = row.kind != .commit
        let extent = Self.nodeExtent

        context.saveGState()
        if isHollow {
            // Lines end at the glyph's edge so hollow nodes stay hollow on any row tint.
            context.addRect(bounds)
            let hole = CGRect(x: nodeX - extent, y: mid - extent, width: extent * 2, height: extent * 2)
            if row.kind == .stash { context.addRect(hole) } else { context.addEllipse(in: hole) }
            context.clip(using: .evenOdd)
        }
        context.setLineWidth(GraphMetrics.lineWidth)
        context.setLineCap(.round)
        let rowTop = CGFloat(rowIndex) * GraphMetrics.rowHeight
        var isDashing = false
        for edge in row.edges {
            let x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat
            switch edge.span {
            case .passThrough:
                (x0, y0, x1, y1) = (GraphMetrics.laneX(edge.from), 0, GraphMetrics.laneX(edge.from), bottom)
            case .intoNode:
                (x0, y0, x1, y1) = (GraphMetrics.laneX(edge.from), 0, nodeX, mid)
            case .outOfNode:
                (x0, y0, x1, y1) = (nodeX, mid, GraphMetrics.laneX(edge.to), bottom)
            }
            if edge.isDashed {
                if !isDashing {
                    context.setLineCap(.butt)
                    isDashing = true
                }
                let phase = (rowTop + y0).truncatingRemainder(dividingBy: GraphMetrics.dashPeriod)
                context.setLineDash(phase: phase, lengths: GraphMetrics.dash)
            } else if isDashing {
                context.setLineDash(phase: 0, lengths: [])
                context.setLineCap(.round)
                isDashing = false
            }
            let isWorkingCopyEdge = edge.isDashed && edge.colorLane == workingCopyLane
            context.setStrokeColor(isWorkingCopyEdge ? style.workingCopyCGColor : style.laneCGColor(edge.colorLane))
            context.move(to: CGPoint(x: x0, y: y0))
            if x0 == x1 {
                context.addLine(to: CGPoint(x: x1, y: y1))
            } else {
                let yMid = (y0 + y1) / 2
                context.addCurve(
                    to: CGPoint(x: x1, y: y1),
                    control1: CGPoint(x: x0, y: yMid),
                    control2: CGPoint(x: x1, y: yMid)
                )
            }
            context.strokePath()
        }
        if isDashing {
            context.setLineDash(phase: 0, lengths: [])
        }
        if hasRefs {
            // Continues the connector the refs column draws from its pills.
            context.setLineWidth(1)
            context.setLineCap(.butt)
            context.setStrokeColor(style.laneCGColor(row.lane))
            context.move(to: CGPoint(x: 0, y: mid + 0.5))
            context.addLine(to: CGPoint(x: nodeX - extent, y: mid + 0.5))
            context.strokePath()
        }
        context.restoreGState()

        drawNode(at: CGPoint(x: nodeX, y: mid), kind: row.kind, lane: row.lane, style: style, in: context)
    }

    /// 8 pt nodes: a filled dot for commits, a ring for merges, a square for stashes,
    /// a dashed muted ring for the working copy; HEAD adds an ink ring around its node.
    private func drawNode(at center: CGPoint, kind: GraphNodeKind, lane: Int, style: GraphStyle, in context: CGContext) {
        let color = style.laneCGColor(lane)
        let radius = GraphMetrics.nodeSize / 2
        // Stroked glyphs keep their outer edge at the 8 pt footprint.
        let strokedRadius = radius - GraphMetrics.lineWidth / 2
        let stroked = CGRect(
            x: center.x - strokedRadius, y: center.y - strokedRadius, width: strokedRadius * 2, height: strokedRadius * 2
        )
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(GraphMetrics.lineWidth)
        switch kind {
        case .commit:
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        case .merge:
            context.setStrokeColor(color)
            context.strokeEllipse(in: stroked)
        case .workingCopy:
            context.setStrokeColor(style.workingCopyCGColor)
            context.setLineDash(phase: 0, lengths: GraphMetrics.workingCopyNodeDash)
            context.strokeEllipse(in: stroked)
            context.setLineDash(phase: 0, lengths: [])
        case .stash:
            context.setStrokeColor(color)
            context.stroke(stroked)
        }
        if isHead, kind == .commit || kind == .merge {
            let ring = GraphMetrics.headRingRadius
            context.setStrokeColor(style.headRingCGColor)
            context.setLineWidth(GraphMetrics.headRingWidth)
            context.strokeEllipse(in: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2))
        }
    }
}

/// The BRANCH / TAG cell: ref pills (overflow as a muted `+N`), the connector line
/// toward the node, and the search rail.
final class GraphRefsView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("graph.cell.refs")
    static let pillHeight: CGFloat = 18
    static let leading: CGFloat = 12
    /// Between pills, and between a pill's icons and its name.
    static let gap: CGFloat = 4
    private static let iconWidth: CGFloat = 13
    private static let iconPointSize: CGFloat = 11
    private static let padding: CGFloat = 6
    private static let overflowPadding: CGFloat = 2
    private static let railWidth: CGFloat = 3

    private var style: GraphStyle?
    private(set) var pills: [RefPill] = []
    private var lane = 0
    private var match: GraphMatchState = .none
    /// Frames of the pills drawn last, in order; overflow pills have none.
    private(set) var pillFrames: [NSRect] = []
    private(set) var overflowFrame: NSRect?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(pills: [RefPill], lane: Int, match: GraphMatchState, style: GraphStyle) {
        if pills != self.pills {
            self.pills = pills
            toolTip = pills.isEmpty ? nil : pills.flatMap(\.refNames).joined(separator: "\n")
        }
        self.lane = lane
        self.match = match
        self.style = style
        needsDisplay = true
    }

    /// The pill under `point` (view coordinates); the `+N` chip counts as the first
    /// hidden pill.
    func pill(at point: NSPoint) -> RefPill? {
        for (index, frame) in pillFrames.enumerated() where frame.insetBy(dx: -1, dy: -3).contains(point) {
            return pills[index]
        }
        if let overflowFrame, overflowFrame.insetBy(dx: -1, dy: -3).contains(point), pillFrames.count < pills.count {
            return pills[pillFrames.count]
        }
        return nil
    }

    private func iconNames(for pill: RefPill) -> [String] {
        var names: [String] = []
        if pill.isHead { names.append("checkmark") }
        if pill.isTag { names.append("tag") }
        if pill.isLocal { names.append("laptopcomputer") }
        if pill.isRemote { names.append("cloud") }
        return names
    }

    private func width(of pill: RefPill, style: GraphStyle) -> CGFloat {
        let icons = CGFloat(iconNames(for: pill).count) * (Self.iconWidth + Self.gap)
        return Self.padding * 2 + icons + style.pillTextWidth(pill.name)
    }

    override func draw(_ dirtyRect: NSRect) {
        pillFrames.removeAll(keepingCapacity: true)
        overflowFrame = nil
        guard let style else { return }
        let mid = bounds.height / 2

        if match != .none {
            (match == .current ? style.matchColor : style.matchMutedColor).setFill()
            NSRect(x: 0, y: 0, width: Self.railWidth, height: bounds.height).fill()
        }
        guard !pills.isEmpty else { return }

        let laneColor = style.laneColor(lane)
        let top = floor(mid - Self.pillHeight / 2)
        let limit = bounds.width - 10
        var x = Self.leading
        for (index, pill) in pills.enumerated() {
            let remaining = pills.count - index - 1
            // Room for the `+N` chip of the pills after this one.
            let reserve = remaining > 0 ? Self.gap + overflowChipWidth(remaining, style: style) : 0
            var width = width(of: pill, style: style)
            if x + width + reserve > limit {
                if index > 0 {
                    // The previous pill reserved exactly this chip's room.
                    drawOverflow(count: pills.count - index, x: x, top: top, style: style)
                    x += overflowChipWidth(pills.count - index, style: style) + Self.gap
                    break
                }
                width = max(Self.padding * 2 + Self.iconWidth + 12, limit - x - reserve)
            }
            let frame = NSRect(x: x, y: top, width: width, height: Self.pillHeight)
            draw(pill, in: frame, laneColor: laneColor, style: style)
            pillFrames.append(frame)
            x = frame.maxX + (remaining > 0 ? Self.gap : 0)
        }

        // Connector from the last pill to the cell edge; the graph cell continues it.
        laneColor.setFill()
        NSRect(x: x, y: floor(mid), width: max(0, bounds.width - x), height: 1).fill()
    }

    /// Lane pill: lane @ 10 % with a 1 pt lane edge, ink name, icons in the lane color.
    /// HEAD: the ink pill (ink fill, label-colored name and icons, no edge).
    private func draw(_ pill: RefPill, in frame: NSRect, laneColor: NSColor, style: GraphStyle) {
        let shape = NSBezierPath(roundedRect: frame, xRadius: Chrome.Radius.cap, yRadius: Chrome.Radius.cap)
        let ink: NSColor
        let iconTint: NSColor
        if pill.isHead {
            style.headPillFill.setFill()
            shape.fill()
            ink = style.headPillInk
            iconTint = style.headPillInk
        } else {
            style.laneTint(lane).setFill()
            shape.fill()
            laneColor.setStroke()
            let border = NSBezierPath(
                roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Chrome.Radius.cap - 0.5,
                yRadius: Chrome.Radius.cap - 0.5
            )
            border.lineWidth = Chrome.hairline
            border.stroke()
            ink = style.colors.textPrimary
            iconTint = laneColor
        }
        var x = frame.minX + Self.padding
        for name in iconNames(for: pill) {
            if let image = style.symbol(name, color: iconTint, pointSize: Self.iconPointSize) {
                let size = image.size
                let scale = min(1, Self.iconWidth / size.width, 11 / size.height)
                let drawn = NSSize(width: size.width * scale, height: size.height * scale)
                image.draw(in: NSRect(
                    x: x + (Self.iconWidth - drawn.width) / 2,
                    y: frame.midY - drawn.height / 2,
                    width: drawn.width,
                    height: drawn.height
                ))
            }
            x += Self.iconWidth + Self.gap
        }
        let textRect = NSRect(
            x: x,
            y: frame.midY - style.pillLineHeight / 2,
            width: max(0, frame.maxX - Self.padding - x + 2),
            height: style.pillLineHeight
        )
        (pill.name as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: style.pillAttributes(ink)
        )
    }

    private func overflowChipWidth(_ count: Int, style: GraphStyle) -> CGFloat {
        style.pillTextWidth("+\(count)") + Self.overflowPadding * 2
    }

    /// `+N`: SF Pro 11 Medium muted, no box.
    private func drawOverflow(count: Int, x: CGFloat, top: CGFloat, style: GraphStyle) {
        let frame = NSRect(x: x, y: top, width: overflowChipWidth(count, style: style), height: Self.pillHeight)
        ("+\(count)" as NSString).draw(
            with: NSRect(x: frame.minX + Self.overflowPadding, y: frame.midY - style.pillLineHeight / 2,
                         width: frame.width - Self.overflowPadding, height: style.pillLineHeight),
            options: [.usesLineFragmentOrigin],
            attributes: style.pillAttributes(style.colors.textMuted)
        )
        overflowFrame = frame
    }
}

/// A one-line text cell (message, author, date, id), vertically centered and truncated.
/// The working-copy row shows `// WIP` plus its file counts in the badge colors.
final class GraphTextView: NSView {
    static let messageIdentifier = NSUserInterfaceItemIdentifier("graph.cell.message")
    static let authorIdentifier = NSUserInterfaceItemIdentifier("graph.cell.author")
    static let dateIdentifier = NSUserInterfaceItemIdentifier("graph.cell.date")
    static let idIdentifier = NSUserInterfaceItemIdentifier("graph.cell.id")
    private static let trailingPadding: CGFloat = 6

    struct WorkingCopyCounts: Equatable {
        var conflicted: Int
        var unstaged: Int
        var staged: Int
    }

    private enum Content {
        case text(String, [NSAttributedString.Key: Any], highlight: NSRange?, isSelected: Bool)
        case workingCopy(WorkingCopyCounts)
    }

    private var content: Content = .text("", [:], highlight: nil, isSelected: false)
    private var style: GraphStyle?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// `highlight`: the search match, drawn on a yellow wash, or in `matchOnSelection`
    /// Semibold when `isSelected`.
    func configure(
        text: String,
        attributes: [NSAttributedString.Key: Any],
        highlight: NSRange? = nil,
        isSelected: Bool = false,
        style: GraphStyle
    ) {
        content = .text(text, attributes, highlight: highlight, isSelected: isSelected)
        self.style = style
        toolTip = nil
        needsDisplay = true
    }

    func configureWorkingCopy(_ counts: WorkingCopyCounts, style: GraphStyle) {
        content = .workingCopy(counts)
        self.style = style
        toolTip = "\(counts.conflicted) conflicted, \(counts.unstaged) unstaged, \(counts.staged) staged"
        needsDisplay = true
    }

    /// The drawn text (tests, accessibility).
    var text: String {
        switch content {
        case let .text(text, _, _, _): text
        case .workingCopy: "// WIP"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let inset = NSRect(
            x: bounds.minX + GraphMetrics.cellPadding,
            y: bounds.minY,
            width: max(0, bounds.width - GraphMetrics.cellPadding - Self.trailingPadding),
            height: bounds.height
        )
        switch content {
        case let .text(text, attributes, highlight, isSelected):
            guard !text.isEmpty else { return }
            let font = attributes[.font] as? NSFont ?? ChromeFont.label
            let lineHeight = ceil(font.ascender - font.descender)
            let rect = NSRect(x: inset.minX, y: floor(bounds.midY - lineHeight / 2), width: inset.width, height: lineHeight)
            if let highlight {
                let string = NSMutableAttributedString(string: text, attributes: attributes)
                if isSelected {
                    string.addAttributes([.foregroundColor: style.matchOnSelection, .font: style.matchFont], range: highlight)
                } else {
                    string.addAttribute(.backgroundColor, value: style.matchTextBackground, range: highlight)
                }
                string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            } else {
                (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            }
        case let .workingCopy(counts):
            drawWorkingCopy(counts, in: inset, style: style)
        }
    }

    private func drawWorkingCopy(_ counts: WorkingCopyCounts, in rect: NSRect, style: GraphStyle) {
        let font = style.wipAttributes[.font] as? NSFont ?? ChromeFont.label
        let lineHeight = ceil(font.ascender - font.descender)
        let label = "// WIP" as NSString
        let labelWidth = ceil(label.size(withAttributes: style.wipAttributes).width)
        label.draw(
            with: NSRect(x: rect.minX, y: floor(bounds.midY - lineHeight / 2), width: min(labelWidth, rect.width), height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: style.wipAttributes
        )
        var x = rect.minX + labelWidth + 12
        let colors = style.colors
        let badges: [(Int, String, NSColor)] = [
            (counts.conflicted, "exclamationmark.triangle.fill", colors.danger),
            (counts.unstaged, "pencil", colors.yellow),
            (counts.staged, "checkmark", colors.success),
        ]
        for (count, symbol, color) in badges where count > 0 {
            guard x + 30 < rect.maxX else { break }
            if let image = style.symbol(symbol, color: color, pointSize: 10) {
                let size = image.size
                image.draw(in: NSRect(x: x, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
                x += size.width + 4
            }
            let number = "\(count)" as NSString
            let attributes = style.countAttributes(color)
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: x, y: floor(bounds.midY - size.height / 2)), withAttributes: attributes)
            x += ceil(size.width) + 12
        }
    }
}

/// Column header row: eyebrow titles (SF Pro 11 Semibold, uppercase, tracked) muted,
/// 1 pt separators between columns and a hairline below; while the graph has focus
/// the titles turn ink and a 2 pt focus rule sits on the bottom edge.
final class GraphHeaderView: NSTableHeaderView {
    var style: GraphStyle? {
        didSet { needsDisplay = true }
    }

    var isFocused = false {
        didSet { if oldValue != isFocused { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let style, let tableView else { return }
        let colors = style.colors
        colors.bgBase.setFill()
        bounds.fill()
        let titleColor = isFocused ? colors.textPrimary : colors.textMuted
        let lineHeight = ceil(ChromeFont.eyebrow.ascender - ChromeFont.eyebrow.descender)
        let visible = tableView.tableColumns.enumerated().filter { !$0.element.isHidden }
        for (position, (index, column)) in visible.enumerated() {
            let rect = headerRect(ofColumn: index)
            ChromeText.eyebrow(column.title, color: titleColor).draw(with: NSRect(
                x: rect.minX + GraphMetrics.cellPadding,
                y: floor(rect.midY - lineHeight / 2),
                width: max(0, rect.width - GraphMetrics.cellPadding - 4),
                height: lineHeight
            ), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if position > 0 {
                colors.borderSubtle.setFill()
                NSRect(x: rect.minX, y: 0, width: Chrome.hairline, height: bounds.height).fill()
            }
        }
        colors.borderSubtle.setFill()
        NSRect(x: 0, y: bounds.height - Chrome.hairline, width: bounds.width, height: Chrome.hairline).fill()
        if isFocused {
            colors.focusMark.setFill()
            NSRect(x: 0, y: bounds.height - Chrome.focusMarkWidth, width: bounds.width, height: Chrome.focusMarkWidth).fill()
        }
    }
}

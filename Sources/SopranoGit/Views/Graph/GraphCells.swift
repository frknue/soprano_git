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

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(row: GraphLayout.Row, index: Int, isHead: Bool, hasRefs: Bool, style: GraphStyle) {
        self.row = row
        self.rowIndex = index
        self.isHead = isHead
        self.hasRefs = hasRefs
        self.style = style
        needsDisplay = true
    }

    /// Half the node's footprint; lines stop at it for hollow glyphs.
    private static func nodeExtent(_ kind: GraphNodeKind) -> CGFloat {
        switch kind {
        case .commit: 5
        case .merge: 4.5
        case .workingCopy: 6.5
        case .stash: 4.75
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style, let row, let context = NSGraphicsContext.current?.cgContext else { return }
        let mid = GraphMetrics.rowHeight / 2
        let bottom = GraphMetrics.rowHeight
        let nodeX = GraphMetrics.laneX(row.lane)
        let isHollow = row.kind != .commit
        let extent = Self.nodeExtent(row.kind)

        context.saveGState()
        if isHollow {
            // Lines end at the glyph's edge so hollow nodes stay hollow on any row tint.
            context.addRect(bounds)
            let hole = CGRect(x: nodeX - extent, y: mid - extent, width: extent * 2, height: extent * 2)
            if row.kind == .stash { context.addRect(hole) } else { context.addEllipse(in: hole) }
            context.clip(using: .evenOdd)
        }
        context.setLineWidth(GraphMetrics.lineWidth)
        context.setLineCap(.butt)
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
                let phase = (rowTop + y0).truncatingRemainder(dividingBy: GraphMetrics.dashPeriod)
                context.setLineDash(phase: phase, lengths: GraphMetrics.dash)
                isDashing = true
            } else if isDashing {
                context.setLineDash(phase: 0, lengths: [])
                isDashing = false
            }
            context.setStrokeColor(style.laneCGColor(edge.colorLane))
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
        if isDashing { context.setLineDash(phase: 0, lengths: []) }
        if hasRefs {
            // Continues the connector the refs column draws from its pills.
            context.setLineWidth(1)
            context.setStrokeColor(style.laneCGColor(row.lane))
            context.move(to: CGPoint(x: 0, y: mid + 0.5))
            context.addLine(to: CGPoint(x: nodeX - extent, y: mid + 0.5))
            context.strokePath()
        }
        context.restoreGState()

        drawNode(at: CGPoint(x: nodeX, y: mid), kind: row.kind, lane: row.lane, style: style, in: context)
    }

    private func drawNode(at center: CGPoint, kind: GraphNodeKind, lane: Int, style: GraphStyle, in context: CGContext) {
        let color = style.laneCGColor(lane)
        context.saveGState()
        defer { context.restoreGState() }
        switch kind {
        case .commit:
            context.setShadow(offset: .zero, blur: 6, color: style.laneGlow(lane))
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            if isHead {
                context.setShadow(offset: .zero, blur: 0, color: nil)
                context.setStrokeColor(color)
                context.setLineWidth(1.5)
                context.strokeEllipse(in: CGRect(x: center.x - 8.25, y: center.y - 8.25, width: 16.5, height: 16.5))
            }
        case .merge:
            context.setStrokeColor(color)
            context.setLineWidth(2)
            context.strokeEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
            if isHead {
                context.setLineWidth(1.5)
                context.strokeEllipse(in: CGRect(x: center.x - 7.25, y: center.y - 7.25, width: 14.5, height: 14.5))
            }
        case .workingCopy:
            context.setShadow(offset: .zero, blur: 5, color: style.laneGlow(lane))
            context.setStrokeColor(color)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [2.4, 2])
            context.strokeEllipse(in: CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11))
        case .stash:
            context.setStrokeColor(color)
            context.setLineWidth(1.5)
            context.stroke(CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        }
    }
}

/// The BRANCH / TAG cell: ref pills (overflow as `+N`), the connector line toward the
/// node, and the search rail.
final class GraphRefsView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("graph.cell.refs")
    static let pillHeight: CGFloat = 18
    static let leading: CGFloat = 8
    static let gap: CGFloat = 4
    private static let iconWidth: CGFloat = 15
    private static let padding: CGFloat = 5
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
        if pill.isTag { names.append("tag.fill") }
        if pill.isLocal { names.append("laptopcomputer") }
        if pill.isRemote { names.append("cloud.fill") }
        return names
    }

    private func width(of pill: RefPill, style: GraphStyle) -> CGFloat {
        let icons = CGFloat(iconNames(for: pill).count) * Self.iconWidth
        return Self.padding * 2 + icons + (icons > 0 ? 3 : 0) + style.pillTextWidth(pill.name)
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
                    drawOverflow(count: pills.count - index, x: x, top: top, laneColor: laneColor, style: style)
                    x += overflowChipWidth(pills.count - index, style: style)
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

    private func draw(_ pill: RefPill, in frame: NSRect, laneColor: NSColor, style: GraphStyle) {
        let ink: NSColor
        if pill.isHead {
            laneColor.setFill()
            frame.fill()
            ink = style.colors.bgPanel
        } else {
            style.laneTints[lane % style.laneTints.count].setFill()
            frame.fill()
            laneColor.setStroke()
            let border = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            ink = style.colors.textPrimary
        }
        var x = frame.minX + Self.padding
        let icons = iconNames(for: pill)
        for name in icons {
            let tint = pill.isHead ? ink : laneColor
            if let image = style.symbol(name, color: tint, pointSize: name == "laptopcomputer" ? 11 : 9) {
                let size = image.size
                let scale = min(1, 14 / size.width, 10 / size.height)
                let drawn = NSSize(width: size.width * scale, height: size.height * scale)
                image.draw(in: NSRect(
                    x: x + (Self.iconWidth - drawn.width) / 2 - 1,
                    y: frame.midY - drawn.height / 2,
                    width: drawn.width,
                    height: drawn.height
                ))
            }
            x += Self.iconWidth
        }
        if !icons.isEmpty { x += 3 }
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
        style.pillTextWidth("+\(count)") + Self.padding * 2
    }

    private func drawOverflow(count: Int, x: CGFloat, top: CGFloat, laneColor: NSColor, style: GraphStyle) {
        let frame = NSRect(x: x, y: top, width: overflowChipWidth(count, style: style), height: Self.pillHeight)
        style.laneTints[lane % style.laneTints.count].setFill()
        frame.fill()
        laneColor.setStroke()
        let border = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        let text = "+\(count)"
        (text as NSString).draw(
            with: NSRect(x: frame.minX + Self.padding, y: frame.midY - style.pillLineHeight / 2,
                         width: frame.width - Self.padding, height: style.pillLineHeight),
            options: [.usesLineFragmentOrigin],
            attributes: style.pillAttributes(style.colors.textPrimary)
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

    struct WorkingCopyCounts: Equatable {
        var conflicted: Int
        var unstaged: Int
        var staged: Int
    }

    private enum Content {
        case text(String, [NSAttributedString.Key: Any], highlight: NSRange?)
        case workingCopy(WorkingCopyCounts)
    }

    private var content: Content = .text("", [:], highlight: nil)
    private var style: GraphStyle?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(text: String, attributes: [NSAttributedString.Key: Any], highlight: NSRange? = nil, style: GraphStyle) {
        content = .text(text, attributes, highlight: highlight)
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
        case let .text(text, _, _): text
        case .workingCopy: "// WIP"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let inset = bounds.insetBy(dx: GraphMetrics.cellPadding, dy: 0)
        switch content {
        case let .text(text, attributes, highlight):
            guard !text.isEmpty else { return }
            let font = attributes[.font] as? NSFont ?? RetroFont.body(12)
            let lineHeight = ceil(font.ascender - font.descender)
            let rect = NSRect(x: inset.minX, y: floor(bounds.midY - lineHeight / 2), width: inset.width, height: lineHeight)
            if let highlight {
                let string = NSMutableAttributedString(string: text, attributes: attributes)
                string.addAttribute(.backgroundColor, value: style.matchTextBackground, range: highlight)
                string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            } else {
                (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            }
        case let .workingCopy(counts):
            drawWorkingCopy(counts, in: inset, style: style)
        }
    }

    private func drawWorkingCopy(_ counts: WorkingCopyCounts, in rect: NSRect, style: GraphStyle) {
        let font = style.wipAttributes[.font] as? NSFont ?? RetroFont.body(12)
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

/// Column header row: display face 11, muted, hairline below and between columns; lit
/// like a focused panel header (raised fill, accent bar) while the graph has focus.
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
        (isFocused ? colors.bgRaised : colors.bgPanel).setFill()
        bounds.fill()
        if isFocused {
            colors.accent.setFill()
            NSRect(x: 0, y: 0, width: PanelHeaderView.focusBarWidth, height: bounds.height).fill()
        }
        let titleColor = isFocused ? colors.textPrimary : colors.textMuted
        let font = RetroFont.display(11)
        let lineHeight = ceil(font.ascender - font.descender)
        let visible = tableView.tableColumns.enumerated().filter { !$0.element.isHidden }
        for (position, (index, column)) in visible.enumerated() {
            let rect = headerRect(ofColumn: index)
            let title = RetroText.display(column.title, color: titleColor, size: 11)
            title.draw(with: NSRect(
                x: rect.minX + GraphMetrics.cellPadding + (index == 0 && isFocused ? 2 : 0),
                y: floor(rect.midY - lineHeight / 2),
                width: max(0, rect.width - GraphMetrics.cellPadding * 2),
                height: lineHeight
            ), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if position < visible.count - 1 {
                colors.borderSubtle.setFill()
                NSRect(x: rect.maxX - 1, y: 7, width: 1, height: bounds.height - 14).fill()
            }
        }
        colors.borderSubtle.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

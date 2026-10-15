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
    /// Width of one line-number column.
    let numberWidth: CGFloat
    let markerWidth: CGFloat = 16
    static let rail: CGFloat = 3
    static let padding: CGFloat = 8

    init(theme: AppTheme, maxLineNumber: Int) {
        colors = theme.colors
        let body = RetroFont.body(12)
        let small = RetroFont.body(11)
        textAttributes = [.font: body, .foregroundColor: colors.textPrimary]
        mutedAttributes = [.font: body, .foregroundColor: colors.textMuted]
        numberAttributes = [.font: small, .foregroundColor: colors.textMuted.withAlphaComponent(0.75)]
        let digits = max(3, String(max(1, maxLineNumber)).count)
        let digitWidth = NSAttributedString(string: "0", attributes: [.font: small]).size().width
        numberWidth = ceil(CGFloat(digits) * digitWidth) + 12
    }

    /// Where the gutter ends and the code starts.
    var gutterWidth: CGFloat { Self.rail + numberWidth * 2 }
    var textX: CGFloat { gutterWidth + markerWidth }
}

/// A diff list row (hunk header, line or notice). Rows of the current hunk
/// draw an accent rail on their leading edge.
@MainActor
protocol DiffRowCell: NSView {
    var isCurrentHunk: Bool { get set }
}

/// One diff line: old/new line-number gutters, +/− marker, text; added and
/// removed lines tinted `success`/`danger` α0.14. Drawn directly for speed.
final class DiffLineCellView: NSView, DiffRowCell {
    static let identifier = NSUserInterfaceItemIdentifier("DiffLineCell")
    static let rowHeight: CGFloat = 18

    var line: DiffLine?
    var style: DiffRowStyle?
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

    func configure(line: DiffLine, style: DiffRowStyle, isCurrentHunk: Bool) {
        self.line = line
        self.style = style
        self.isCurrentHunk = isCurrentHunk
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let line, let style else { return }
        let colors = style.colors
        let tint: NSColor? = switch line.kind {
        case .added: colors.success.withAlphaComponent(0.14)
        case .removed: colors.danger.withAlphaComponent(0.14)
        case .context, .noNewlineMarker: nil
        }
        if let tint {
            tint.setFill()
            bounds.fill(using: .sourceOver)
        }
        // Gutter: a faint raised band and a hairline before the code.
        colors.bgRaised.withAlphaComponent(0.45).setFill()
        NSRect(x: 0, y: 0, width: style.gutterWidth, height: bounds.height).fill(using: .sourceOver)
        colors.borderSubtle.setFill()
        NSRect(x: style.gutterWidth - 1, y: 0, width: 1, height: bounds.height).fill()
        if isCurrentHunk {
            colors.accent.setFill()
            NSRect(x: 0, y: 0, width: DiffRowStyle.rail, height: bounds.height).fill()
        }

        let baseline = floor((bounds.height - 14) / 2)
        func number(_ value: Int?, column: Int) {
            guard let value else { return }
            let text = NSAttributedString(string: String(value), attributes: style.numberAttributes)
            let size = text.size()
            let right = DiffRowStyle.rail + style.numberWidth * CGFloat(column + 1) - 6
            text.draw(at: NSPoint(x: right - size.width, y: floor((bounds.height - size.height) / 2)))
        }
        number(line.oldNumber, column: 0)
        number(line.newNumber, column: 1)

        let marker: String
        let markerColor: NSColor
        switch line.kind {
        case .added: marker = "+"; markerColor = colors.success
        case .removed: marker = "−"; markerColor = colors.danger
        case .context, .noNewlineMarker: marker = ""; markerColor = colors.textMuted
        }
        if !marker.isEmpty {
            var attributes = style.textAttributes
            attributes[.foregroundColor] = markerColor
            NSAttributedString(string: marker, attributes: attributes)
                .draw(at: NSPoint(x: style.gutterWidth + 4, y: baseline))
        }
        let text: NSAttributedString
        if line.kind == .noNewlineMarker {
            text = NSAttributedString(string: "No newline at end of file", attributes: style.mutedAttributes)
        } else {
            text = NSAttributedString(string: Self.displayText(line.text), attributes: style.textAttributes)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: style.textX, y: 0, width: max(0, bounds.width - style.textX), height: bounds.height)).addClip()
        text.draw(at: NSPoint(x: style.textX, y: baseline))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Tabs as four spaces; very long lines cut (the row clips them anyway).
    static func displayText(_ text: String) -> String {
        let cut = text.count > 2000 ? String(text.prefix(2000)) : text
        return cut.contains("\t") ? cut.replacingOccurrences(of: "\t", with: "    ") : cut
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

    func configure(hunk: DiffHunk, actions: [PanelRowAction], style: DiffRowStyle, theme: AppTheme, isCurrentHunk: Bool) {
        colors = style.colors
        leadingConstraint.constant = style.gutterWidth + 4
        let range = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        let text = NSMutableAttributedString(string: range, attributes: [
            .font: RetroFont.body(11), .foregroundColor: style.colors.cyan.withAlphaComponent(0.85),
        ])
        if !hunk.section.isEmpty {
            text.append(NSAttributedString(string: "  " + hunk.section, attributes: [
                .font: RetroFont.body(11), .foregroundColor: style.colors.textMuted,
            ]))
        }
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
/// diff side (UNSTAGED / STAGED / commit), and the Esc key that closes it.
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
    private var side: (text: String, color: NSColor?) = ("", nil)

    var isFocused = false {
        didSet { restyle() }
    }

    init(theme: AppTheme) {
        self.theme = theme
        badge = ChangeKindBadge(kind: .modified, theme: theme)
        closeButton = KeyHintButton(title: "Close", hint: nil, theme: theme)
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
        sideLabel.translatesAutoresizingMaskIntoConstraints = false
        sideChip.addSubview(sideLabel)
        for view in [focusBar, bottomRule, badge, pathLabel, countsLabel, positionLabel, sideChip, closeButton] as [NSView] {
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
            closeButton.leadingAnchor.constraint(equalTo: sideChip.trailingAnchor, constant: 10),
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
    }
}

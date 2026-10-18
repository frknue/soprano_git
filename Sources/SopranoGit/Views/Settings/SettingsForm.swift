import AppKit

/// Building blocks of the settings form, styled from one theme: titled
/// cards, label/control rows, inputs, popups, issue rows. Soprano's settings
/// screen in Soprano Git's tokens.
@MainActor
struct SettingsForm {
    let theme: AppTheme

    /// Horizontal padding inside a card.
    static let cardInset: CGFloat = 14

    /// A page title (display 22) over a wrapping muted subtitle.
    func header(title: String, subtitle: String) -> NSView {
        let colors = theme.colors
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.setRetroText(title, color: colors.textPrimary, size: 22)
        let subtitleLabel = wrappingLabel(subtitle, color: colors.textMuted)
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// A section: heading and optional subtitle above a flat card. Returns the
    /// section and the card's row stack.
    func card(title: String, subtitle: String? = nil) -> (section: NSView, rows: NSStackView) {
        let colors = theme.colors
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false

        let heading = RetroHeadingView(title: title, theme: theme)
        section.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

        if let subtitle {
            let label = wrappingLabel(subtitle, color: colors.textMuted)
            section.addArrangedSubview(label)
            section.setCustomSpacing(4, after: heading)
            label.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = Retro.cornerRadius
        card.layer?.borderWidth = Retro.hairline
        card.layer?.backgroundColor = colors.bgPanel.cgColor
        card.layer?.borderColor = colors.borderStrong.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        section.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.edgeInsets = NSEdgeInsets(top: 6, left: Self.cardInset, bottom: 6, right: Self.cardInset)
        rows.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rows.topAnchor.constraint(equalTo: card.topAnchor),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return (section, rows)
    }

    /// Adds views to a card's row stack at full content width, with inset
    /// hairlines between them.
    func add(_ views: [NSView], to rows: NSStackView) {
        for view in views {
            if !rows.arrangedSubviews.isEmpty {
                let rule = RetroRuleView(axis: .horizontal, style: .single, color: theme.colors.borderSubtle)
                rows.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -2 * Self.cardInset).isActive = true
            }
            rows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -2 * Self.cardInset).isActive = true
        }
    }

    /// A form row: display-face label (and an optional muted explanation
    /// under it) on the left, the control pinned to the trailing edge.
    func row(_ label: String, detail: String? = nil, detailColor: NSColor? = nil, control: NSView) -> NSView {
        let colors = theme.colors
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.setRetroText(label, color: colors.textPrimary)
        var texts: [NSView] = [labelField]
        if let detail {
            texts.append(wrappingLabel(detail, color: detailColor ?? colors.textMuted))
        }
        let textStack = NSStackView(views: texts)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addSubview(textStack)

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -16),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 4),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
        let hug = row.heightAnchor.constraint(equalToConstant: 36)
        hug.priority = .defaultLow
        hug.isActive = true
        return row
    }

    /// A horizontal group of controls (field + buttons) used as one row control.
    func group(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .horizontal)
        return stack
    }

    func textField(_ value: String, placeholder: String? = nil, width: CGFloat) -> NSTextField {
        let colors = theme.colors
        let field = NSTextField(string: value)
        field.cell = SettingsFieldCell(textCell: value)
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        // The layer paints the fill: the cell's own background covers only its
        // padded text rect.
        field.drawsBackground = false
        field.textColor = colors.textPrimary
        field.font = RetroFont.body(12)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        // Fields commit when they lose focus, not only on Return.
        field.cell?.sendsActionOnEndEditing = true
        field.wantsLayer = true
        field.layer?.cornerRadius = Retro.cornerRadius
        field.layer?.borderWidth = Retro.hairline
        field.layer?.borderColor = colors.borderStrong.cgColor
        field.layer?.backgroundColor = colors.bgRaised.cgColor
        if let placeholder {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.font: RetroFont.body(12), .foregroundColor: colors.textMuted]
            )
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: width),
            field.heightAnchor.constraint(equalToConstant: Retro.controlHeight - 4),
        ])
        return field
    }

    /// An integer field; grouping is off so values round-trip on every locale.
    func numberField(_ value: Int, width: CGFloat = 84) -> NSTextField {
        let field = textField(String(value), width: width)
        field.alignment = .right
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.usesGroupingSeparator = false
        formatter.allowsFloats = false
        field.formatter = formatter
        return field
    }

    /// A popup whose items carry `value` as `representedObject`.
    func popup(_ items: [(title: String, value: String)], selected: String, width: CGFloat = 240) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = RetroFont.body(12)
        for item in items {
            popup.addItem(withTitle: item.title)
            popup.lastItem?.representedObject = item.value
        }
        if let index = items.firstIndex(where: { $0.value == selected }) {
            popup.selectItem(at: index)
        }
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
        return popup
    }

    func button(_ title: String, kind: RetroButton.Kind = .standard, target: AnyObject?, action: Selector) -> RetroButton {
        RetroButton(title: title, theme: theme, kind: kind, target: target, action: action)
    }

    func wrappingLabel(_ text: String, color: NSColor, size: CGFloat = 11) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = RetroFont.body(size)
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// One settings.json problem: a tinted box with its line number.
    func issueRow(_ issue: ConfigIssue) -> NSView {
        let colors = theme.colors
        let tint = issue.severity == .error ? colors.danger : colors.yellow
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = Retro.cornerRadius
        box.layer?.borderWidth = Retro.hairline
        box.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        box.layer?.borderColor = tint.withAlphaComponent(0.45).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        let location = issue.line.map { "Line \($0): " } ?? ""
        let label = wrappingLabel(location + issue.message, color: colors.textPrimary)
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
        ])
        return box
    }
}

/// A page key in the settings sidebar: a square strip key, the active page a
/// lit accent block with panel-colored ink (Soprano's settings tabs).
final class SettingsPageButton: NSButton {
    private static let inset: CGFloat = 12
    private static let symbolSlot: CGFloat = 16

    var isActive = false {
        didSet { needsDisplay = true }
    }
    private var theme: AppTheme
    private let symbol: NSImage?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var hoverArea: NSTrackingArea?

    init(page: SettingsPage, theme: AppTheme, target: AnyObject?, action: Selector) {
        self.theme = theme
        self.symbol = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: page.title)
        super.init(frame: .zero)
        title = page.title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        refusesFirstResponder = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let fill: NSColor = isActive ? colors.accent : (isHovered ? colors.bgOverlay : .clear)
        let ink = isActive ? colors.bgPanel : colors.textMuted
        fill.setFill()
        bounds.fill()

        var x = Self.inset
        if let symbol {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
            let tinted = symbol.withSymbolConfiguration(configuration) ?? symbol
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: x + floor((Self.symbolSlot - size.width) / 2),
                    y: floor((bounds.height - size.height) / 2),
                    width: size.width,
                    height: size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            x += Self.symbolSlot + 10
        }
        let label = RetroText.display(title, color: ink, tracking: 0)
        let height = ceil(label.size().height)
        label.draw(in: NSRect(x: x, y: floor((bounds.height - height) / 2), width: max(0, bounds.width - x - Self.inset), height: height))
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
}

/// A field cell that centers its single line vertically and pads it
/// horizontally, so borderless settings inputs read like the search field.
final class SettingsFieldCell: NSTextFieldCell {
    private static let horizontalPadding: CGFloat = 6

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var frame = super.drawingRect(forBounds: rect).insetBy(dx: Self.horizontalPadding, dy: 0)
        let height = cellSize(forBounds: rect).height
        if height < frame.height {
            frame.origin.y += floor((frame.height - height) / 2)
            frame.size.height = height
        }
        return frame
    }
}

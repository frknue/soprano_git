import AppKit

/// Building blocks of the settings form, styled from one theme: eyebrow
/// sections over raised cards, label/control rows, fields, popups and notice
/// rows. Soprano's settings screen in Soprano Git's tokens.
@MainActor
struct SettingsForm {
    let theme: AppTheme

    /// Horizontal padding inside a card (`.form-row` padding 8 12).
    static let cardInset: CGFloat = 12
    /// Minimum height of a form row (`--h-form-row`).
    static let rowHeight: CGFloat = 36

    /// A page title (New York 22) over a wrapping muted subtitle.
    func header(title: String, subtitle: String) -> NSView {
        let colors = theme.colors
        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.setChromeText(title, font: ChromeFont.screen, color: colors.textPrimary, tracking: -0.2)
        let subtitleLabel = wrappingLabel(subtitle, color: colors.textMuted, size: 12)
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// A section (`.settings-section`): eyebrow and optional note above a
    /// raised card with an 8 pt radius and a `borderSubtle` edge. Returns the
    /// section and the card's row stack.
    func card(title: String, subtitle: String? = nil) -> (section: NSView, rows: NSStackView) {
        let colors = theme.colors
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false

        // `.settings-section > .t-eyebrow` and its note sit 2 pt in.
        let heading = ChromeEyebrowView(title: title, theme: theme)
        let intro = NSStackView(views: [heading])
        intro.orientation = .vertical
        intro.alignment = .leading
        intro.spacing = 4
        intro.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
        intro.translatesAutoresizingMaskIntoConstraints = false
        heading.widthAnchor.constraint(equalTo: intro.widthAnchor, constant: -2).isActive = true
        if let subtitle {
            let label = wrappingLabel(subtitle, color: colors.textMuted)
            intro.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: intro.widthAnchor, constant: -2).isActive = true
        }
        section.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = Chrome.Radius.card
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = Chrome.hairline
        card.layer?.backgroundColor = colors.raised.cgColor
        card.layer?.borderColor = colors.borderSubtle.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        section.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.edgeInsets = NSEdgeInsets(top: 0, left: Self.cardInset, bottom: 0, right: Self.cardInset)
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

    /// Adds views to a card's row stack at full content width, with
    /// `borderSubtle` hairlines between them.
    func add(_ views: [NSView], to rows: NSStackView) {
        for view in views {
            if !rows.arrangedSubviews.isEmpty {
                let rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
                rows.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -2 * Self.cardInset).isActive = true
            }
            rows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -2 * Self.cardInset).isActive = true
        }
    }

    /// A form row: SF Pro 13 label (and an optional SF Pro 11 note under it)
    /// on the left, the control pinned to the trailing edge.
    func row(_ label: String, detail: String? = nil, detailColor: NSColor? = nil, control: NSView) -> NSView {
        let colors = theme.colors
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: "")
        labelField.lineBreakMode = .byTruncatingTail
        labelField.setChromeText(label, font: ChromeFont.row, color: colors.textPrimary)
        var texts: [NSView] = [labelField]
        if let detail {
            texts.append(wrappingLabel(detail, color: detailColor ?? colors.textMuted))
        }
        let textStack = NSStackView(views: texts)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
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
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 6),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.rowHeight),
        ])
        let hug = row.heightAnchor.constraint(equalToConstant: Self.rowHeight)
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

    /// A 24 pt field: raised fill, 6 pt radius, `borderStrong` edge. Paths are
    /// SF Mono 12 (`monospaced`), everything else SF Pro 12.
    func textField(_ value: String, placeholder: String? = nil, width: CGFloat, monospaced: Bool = false) -> NSTextField {
        let colors = theme.colors
        let font = monospaced ? ChromeFont.mono : ChromeFont.sans(size: 12, tabular: true)
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
        field.font = font
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        // Fields commit when they lose focus, not only on Return.
        field.cell?.sendsActionOnEndEditing = true
        field.wantsLayer = true
        field.layer?.cornerRadius = Chrome.Radius.control
        field.layer?.borderWidth = Chrome.hairline
        field.layer?.borderColor = colors.borderStrong.cgColor
        field.layer?.backgroundColor = colors.raised.cgColor
        if let placeholder {
            field.placeholderAttributedString = ChromeText.attributed(placeholder, font: font, color: colors.textMuted)
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: width),
            field.heightAnchor.constraint(equalToConstant: Chrome.controlHeight),
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
        popup.font = ChromeFont.label
        popup.controlSize = .regular
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

    func button(_ title: String, kind: ChromeButton.Kind = .standard, target: AnyObject?, action: Selector) -> ChromeButton {
        ChromeButton(title: title, theme: theme, kind: kind, target: target, action: action)
    }

    /// Wrapping SF Pro text: 11 for notes (`.form-note`), 12 for prose.
    func wrappingLabel(_ text: String, color: NSColor, size: CGFloat = 11) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = ChromeFont.sans(size: size)
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// One settings.json problem: a notice box (8 pt radius, status wash) with
    /// its status mark and line number.
    func issueRow(_ issue: ConfigIssue) -> NSView {
        let colors = theme.colors
        let status: ChromeStatus = issue.severity == .error ? .error : .needsInput
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = Chrome.Radius.card
        box.layer?.backgroundColor = (status.headerWash(in: colors) ?? colors.needsInputWash).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        let mark = ChromeStatusMark()
        mark.set(status: status, colors: colors)
        mark.translatesAutoresizingMaskIntoConstraints = false
        let location = issue.line.map { "Line \($0): " } ?? ""
        let label = wrappingLabel(location + issue.message, color: colors.textPrimary, size: 12)
        box.addSubview(mark)
        box.addSubview(label)
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            mark.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        return box
    }
}

/// A page in the settings sidebar (`.nav-item`): a 30 pt row with a 14 pt
/// symbol and an SF Pro 12 title, muted; the active page a raised pill with a
/// `borderSubtle` edge and an ink Medium title; hover a `hover` pill.
final class SettingsPageButton: NSButton {
    static let height: CGFloat = 30
    private static let inset: CGFloat = 10
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

    /// The selection idiom the row draws in its current state.
    var pillStyle: ChromeSelectionPill.Style {
        isActive ? .raisedTab : (isHovered ? .hover : .none)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        ChromeSelectionPill.draw(pillStyle, in: bounds, colors: colors, inset: 0)
        let ink = isActive ? colors.textPrimary : colors.textMuted

        var x = Self.inset
        if let symbol {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
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
            x += Self.symbolSlot + 8
        }
        let label = ChromeText.attributed(title, font: isActive ? ChromeFont.labelStrong : ChromeFont.label, color: ink)
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
/// horizontally (`.field` padding 0 8).
final class SettingsFieldCell: NSTextFieldCell {
    private static let horizontalPadding: CGFloat = 8

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

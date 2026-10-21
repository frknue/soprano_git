import AppKit
import SopranoGitCore

/// A button bound to a command id: an optional SF Symbol (13 pt, muted), the
/// title, then the command's K1 keycaps as 16 pt caps inside the button. The
/// registry decides whether it is enabled.
///
/// - `plain`: the borderless toolbar button; `hover` fill under the pointer,
///   muted caps, the whole button at 45 % while disabled. Made a toggle
///   (`isToggledOn` non-nil), it sits on a raised pill with a `borderStrong`
///   inset and an ink icon while on; off, the icon is at 70 %.
/// - `ink`: the primary action, filled with ink.
/// - `standard`: raised fill with a `borderStrong` edge.
@MainActor
final class CommandButton: NSButton {
    enum Kind {
        case plain
        case ink
        case standard
    }

    private enum Metrics {
        static let iconPointSize: CGFloat = 13
        static let capHeight: CGFloat = Chrome.keycapHeightSmall
        static let capPadding: CGFloat = 4
        /// Caps inside a button sit 2 pt apart.
        static let capGap: CGFloat = 2
        /// Plain buttons push their caps 2 pt further from the title.
        static let plainCapsOffset: CGFloat = 2
    }

    let commandID: String
    let kind: Kind
    var onPerform: ((String) -> Void)?

    /// Panel toggle state; nil for buttons that are not toggles.
    var isToggledOn: Bool? {
        didSet {
            guard isToggledOn != oldValue else { return }
            setAccessibilityValue(isToggledOn.map { $0 ? 1 : 0 })
            needsDisplay = true
        }
    }

    /// The command's K1 keycaps (`["⌃A", "P"]`); empty while unbound.
    private(set) var caps: [String] = [] {
        didSet {
            guard caps != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let label: String
    private let symbol: NSImage?
    private let symbolName: String?
    private var tintedSymbol: (color: NSColor, image: NSImage)?
    private var theme: AppTheme
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    /// `title` may be empty for icon-only buttons; `accessibilityLabel` then
    /// names them.
    init(
        title: String,
        commandID: String,
        theme: AppTheme,
        kind: Kind = .plain,
        symbolName: String? = nil,
        accessibilityLabel: String? = nil,
        isToggle: Bool = false
    ) {
        self.commandID = commandID
        self.kind = kind
        self.theme = theme
        self.label = title
        self.symbolName = symbolName
        symbol = symbolName.flatMap { name in
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Metrics.iconPointSize, weight: .regular))
        }
        isToggledOn = isToggle ? false : nil
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        refusesFirstResponder = true
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(clicked)
        setAccessibilityLabel(accessibilityLabel ?? title)
        if isToggle { setAccessibilityValue(0) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        tintedSymbol = nil
        needsDisplay = true
    }

    /// Updates the keycaps, the enabled state and the tooltip from the registry.
    func refresh(context: CommandContext? = nil) {
        let settings = SettingsCenter.shared
        caps = settings.keycaps(for: commandID) ?? []
        let command = CommandRegistry.shared.command(commandID)
        isEnabled = command.flatMap { command in context.map { command.isEnabled($0) } } ?? false
        toolTip = command.map { command in
            [command.title, settings.shortcutText(for: commandID)].compactMap { $0 }.joined(separator: "  ")
        } ?? "Not available"
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = kind == .plain && !isEnabled ? 0.45 : 1
            needsDisplay = true
        }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    // MARK: Measuring

    /// Gap between icon, title and caps; toggles are a touch tighter.
    private var gap: CGFloat { isToggledOn == nil ? 6 : 5 }

    private var capsLead: CGFloat { gap + (kind == .plain ? Metrics.plainCapsOffset : 0) }

    private var padding: (leading: CGFloat, trailing: CGFloat) {
        switch kind {
        case .plain: (8, 8)
        // `.btn .kbd { margin-right: -4px }`
        case .ink, .standard: (ChromeButton.horizontalPadding, caps.isEmpty ? ChromeButton.horizontalPadding : 6)
        }
    }

    private static func capWidth(_ legend: String) -> CGFloat {
        ChromeKeycapView.capWidth(legend, font: ChromeFont.keycap, height: Metrics.capHeight, padding: Metrics.capPadding)
    }

    private func titleString(color: NSColor) -> NSAttributedString? {
        guard !label.isEmpty else { return nil }
        let font = kind == .ink ? ChromeFont.labelStrong : ChromeFont.label
        return ChromeText.attributed(label, font: font, color: color, lineBreakMode: .byClipping)
    }

    private var contentWidth: CGFloat {
        var width: CGFloat = 0
        var hasItem = false
        if let symbol {
            width += symbol.size.width
            hasItem = true
        }
        if let title = titleString(color: .labelColor) {
            width += (hasItem ? gap : 0) + ceil(title.size().width)
            hasItem = true
        }
        if !caps.isEmpty {
            width += (hasItem ? capsLead : 0)
            width += caps.map(Self.capWidth).reduce(0, +) + CGFloat(caps.count - 1) * Metrics.capGap
        }
        return width
    }

    override var intrinsicContentSize: NSSize {
        let padding = padding
        return NSSize(width: padding.leading + contentWidth + padding.trailing, height: Chrome.controlHeight)
    }

    // MARK: Drawing

    private struct Palette {
        var fill: NSColor?
        var edge: NSColor?
        var text: NSColor
        var icon: NSColor
        var iconAlpha: CGFloat
        var capFill: NSColor?
        var capEdge: NSColor
        var capText: NSColor
    }

    private var palette: Palette {
        let colors = theme.colors
        let isPressed = isEnabled && isHighlighted
        let isHot = isEnabled && isHovered
        switch kind {
        case .plain:
            let isOn = isToggledOn == true
            let fill: NSColor? = isPressed ? colors.bgOverlay : (isOn ? colors.raised : (isHot ? colors.hover : nil))
            return Palette(
                fill: fill,
                edge: isOn ? colors.borderStrong : nil,
                text: isEnabled ? colors.textPrimary : colors.textMuted,
                icon: isOn ? colors.textPrimary : colors.textMuted,
                iconAlpha: isToggledOn == false ? 0.7 : 1,
                capFill: colors.keycapFill,
                capEdge: colors.keycapEdge,
                capText: colors.textMuted
            )
        case .ink:
            guard isEnabled else {
                return Palette(fill: colors.bgOverlay, edge: colors.bgOverlay, text: colors.textMuted,
                               icon: colors.textMuted, iconAlpha: 1, capFill: nil,
                               capEdge: colors.textMuted.withAlphaComponent(0.35), capText: colors.textMuted)
            }
            let fill = isPressed || isHot ? colors.inkButtonPressed : colors.inkButtonFill
            return Palette(fill: fill, edge: fill, text: colors.inkButtonLabel,
                           icon: colors.inkButtonLabel, iconAlpha: 1, capFill: nil,
                           capEdge: colors.inkButtonLabel.withAlphaComponent(0.35), capText: colors.inkButtonLabel)
        case .standard:
            guard isEnabled else {
                return Palette(fill: nil, edge: colors.borderSubtle, text: colors.textMuted,
                               icon: colors.textMuted, iconAlpha: 1, capFill: nil,
                               capEdge: colors.borderSubtle, capText: colors.textMuted)
            }
            let fill = isPressed ? colors.bgOverlay : (isHot ? colors.hover : colors.raised)
            return Palette(fill: fill, edge: colors.borderStrong, text: colors.textPrimary,
                           icon: colors.textMuted, iconAlpha: 1, capFill: colors.keycapFill,
                           capEdge: colors.keycapEdge, capText: colors.textPrimary)
        }
    }

    private func symbolImage(color: NSColor) -> NSImage? {
        guard let symbolName else { return nil }
        if let tintedSymbol, tintedSymbol.color == color { return tintedSymbol.image }
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.iconPointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        tintedSymbol = (color, image)
        return image
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

        let padding = padding
        let width = padding.leading + contentWidth + padding.trailing
        var x = padding.leading + max(0, floor((bounds.width - width) / 2))
        var hasItem = false
        if let image = symbolImage(color: palette.icon) {
            let size = image.size
            image.draw(
                in: NSRect(x: x, y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: palette.iconAlpha,
                respectFlipped: true,
                hints: nil
            )
            x += size.width
            hasItem = true
        }
        if let title = titleString(color: palette.text) {
            if hasItem { x += gap }
            let size = title.size()
            title.draw(at: NSPoint(x: x, y: floor((bounds.height - size.height) / 2)))
            x += ceil(size.width)
            hasItem = true
        }
        guard !caps.isEmpty else { return }
        if hasItem { x += capsLead }
        let y = floor((bounds.height - Metrics.capHeight) / 2)
        for legend in caps {
            let capWidth = Self.capWidth(legend)
            ChromeKeycapView.drawCap(
                legend,
                in: NSRect(x: x, y: y, width: capWidth, height: Metrics.capHeight),
                fill: palette.capFill,
                edge: palette.capEdge,
                text: palette.capText,
                font: ChromeFont.keycap,
                radius: Chrome.Radius.cap
            )
            x += capWidth + Metrics.capGap
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    @objc private func clicked() {
        onPerform?(commandID)
    }
}

/// 38 pt toolbar on `bgPanel`: repo name, the raised branch chip
/// (`main ↑0 ↓0`), Pull Push · Branch · Stash Pop as plain buttons with their
/// keycaps, then the Refs (⌘J) and Commit panel (⌘K) toggles and the palette
/// button. The workspace draws the single hairline under it.
@MainActor
final class WorkspaceToolbarView: NSView {
    static let height: CGFloat = 38

    var onPerform: ((String) -> Void)?

    private let repoLabel = NSTextField(labelWithString: "")
    private let branchChip = NSView()
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let aheadLabel = NSTextField(labelWithString: "")
    private let behindLabel = NSTextField(labelWithString: "")
    /// Pull, Push, Branch, Stash, Pop.
    private(set) var commandButtons: [CommandButton] = []
    /// On while the refs sidebar shows.
    let sidebarToggle: CommandButton
    /// On while the commit panel shows.
    let commitPanelToggle: CommandButton
    private let paletteButton: CommandButton
    private var theme: AppTheme

    private var allButtons: [CommandButton] {
        commandButtons + [sidebarToggle, commitPanelToggle, paletteButton]
    }

    init(theme: AppTheme) {
        self.theme = theme
        sidebarToggle = CommandButton(
            title: "", commandID: "view.toggleSidebar", theme: theme,
            symbolName: "sidebar.left", accessibilityLabel: "Refs", isToggle: true
        )
        commitPanelToggle = CommandButton(
            title: "", commandID: "view.toggleCommitPanel", theme: theme,
            symbolName: "sidebar.right", accessibilityLabel: "Commit Panel", isToggle: true
        )
        paletteButton = CommandButton(
            title: "", commandID: "palette.open", theme: theme,
            symbolName: "command", accessibilityLabel: "Command Palette"
        )
        super.init(frame: .zero)
        wantsLayer = true

        repoLabel.lineBreakMode = .byTruncatingTail
        repoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        branchChip.wantsLayer = true
        let chipStack = NSStackView(views: [branchIcon, branchLabel, aheadLabel, behindLabel])
        chipStack.spacing = 6
        chipStack.alignment = .centerY
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        branchChip.addSubview(chipStack)
        NSLayoutConstraint.activate([
            chipStack.leadingAnchor.constraint(equalTo: branchChip.leadingAnchor, constant: 8),
            chipStack.trailingAnchor.constraint(equalTo: branchChip.trailingAnchor, constant: -8),
            chipStack.centerYAnchor.constraint(equalTo: branchChip.centerYAnchor),
            branchChip.heightAnchor.constraint(equalToConstant: Chrome.controlHeight),
        ])

        let groups: [[(title: String, id: String, symbol: String)]] = [
            [("Pull", "repo.pull", "arrow.down.to.line"), ("Push", "repo.push", "arrow.up.to.line")],
            [("Branch", "branch.create", "arrow.triangle.branch")],
            [("Stash", "stash.save", "archivebox"), ("Pop", "stash.pop", "tray.and.arrow.up")],
        ]
        var arranged: [NSView] = [repoLabel, branchChip]
        for group in groups {
            var views: [NSView] = []
            for item in group {
                let button = CommandButton(title: item.title, commandID: item.id, theme: theme, symbolName: item.symbol)
                commandButtons.append(button)
                views.append(button)
            }
            arranged.append(Self.group(views, spacing: 2))
        }
        let left = NSStackView(views: arranged)
        left.spacing = 16
        left.alignment = .centerY

        let right = NSStackView(views: [Self.group([sidebarToggle, commitPanelToggle], spacing: 4), paletteButton])
        right.spacing = 16
        right.alignment = .centerY

        for button in allButtons {
            button.onPerform = { [weak self] id in self?.onPerform?(id) }
        }
        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.bar),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.bar),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func group(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = spacing
        stack.alignment = .centerY
        return stack
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        branchChip.layer?.backgroundColor = colors.raised.cgColor
        branchChip.layer?.cornerRadius = Chrome.Radius.control
        branchChip.layer?.borderColor = colors.borderSubtle.cgColor
        branchChip.layer?.borderWidth = Chrome.hairline
        branchIcon.contentTintColor = colors.textMuted
        allButtons.forEach { $0.apply(theme: theme) }
    }

    func update(repoName: String, refs: RefSnapshot, context: CommandContext?) {
        let colors = theme.colors
        repoLabel.setChromeText(repoName, font: ChromeFont.labelStrong, color: colors.textPrimary)
        let branchText: String
        var ahead = 0
        var behind = 0
        var hasUpstream = false
        switch refs.head {
        case let .branch(name):
            branchText = name
            if let current = refs.currentBranch {
                ahead = current.ahead
                behind = current.behind
                hasUpstream = current.upstream != nil
            }
        case let .detached(id):
            branchText = "Detached " + String(id.prefix(7))
        case let .unborn(name):
            branchText = name + " (no commits)"
        }
        branchLabel.setChromeText(branchText, font: ChromeFont.labelStrong, color: colors.textPrimary)
        let countFont = ChromeFont.sans(size: 12, tabular: true)
        aheadLabel.setChromeText("↑\(ahead)", font: countFont, color: colors.textMuted)
        behindLabel.setChromeText("↓\(behind)", font: countFont, color: behind > 0 ? colors.yellow : colors.textMuted)
        aheadLabel.isHidden = !hasUpstream
        behindLabel.isHidden = !hasUpstream
        allButtons.forEach { $0.refresh(context: context) }
    }

    /// Mirrors the workspace's panel visibility in the two toggles.
    func setPanelVisibility(sidebar: Bool, commitPanel: Bool) {
        sidebarToggle.isToggledOn = sidebar
        commitPanelToggle.isToggledOn = commitPanel
    }
}

/// 36 pt banner over the center while git has paused an operation: raised,
/// washed in the status colour, the status mark and label (NEEDS INPUT, or
/// ERROR while conflicts remain), "Merge in progress · 2 conflicts", then
/// Continue (ink), Abort and Skip with their keycaps.
@MainActor
final class OperationBannerView: NSView {
    static let height: CGFloat = 36

    var onPerform: ((String) -> Void)?

    private let wash = NSView()
    private let mark = ChromeStatusMark()
    private let statusLabel = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let continueButton: CommandButton
    private let abortButton: CommandButton
    private let skipButton: CommandButton
    private let bottomRule = ChromeRuleView(axis: .horizontal)
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        continueButton = CommandButton(title: "Continue", commandID: "operation.continue", theme: theme, kind: .ink)
        abortButton = CommandButton(title: "Abort", commandID: "operation.abort", theme: theme, kind: .standard)
        skipButton = CommandButton(title: "Skip", commandID: "operation.skip", theme: theme, kind: .standard)
        super.init(frame: .zero)
        wantsLayer = true
        wash.wantsLayer = true
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [continueButton, abortButton, skipButton] {
            button.onPerform = { [weak self] id in self?.onPerform?(id) }
        }
        let buttons = NSStackView(views: [continueButton, abortButton, skipButton])
        buttons.spacing = 6
        buttons.alignment = .centerY
        for view in [wash, mark, statusLabel, label, buttons, bottomRule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor),
            wash.bottomAnchor.constraint(equalTo: bottomAnchor),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.bar),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.bar),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.raised.cgColor
        bottomRule.color = theme.colors.borderSubtle
        [continueButton, abortButton, skipButton].forEach { $0.apply(theme: theme) }
    }

    /// Text for an operation: "Merge in progress · 2 conflicts".
    static func text(for operation: OperationInProgress, conflicts: Int) -> String {
        var parts = ["\(operation.title) in progress"]
        if case let .rebase(_, _, step?, total?) = operation {
            parts.append("step \(step)/\(total)")
        }
        if conflicts > 0 {
            parts.append(conflicts == 1 ? "1 conflict" : "\(conflicts) conflicts")
        } else {
            parts.append("ready to continue")
        }
        return parts.joined(separator: " · ")
    }

    /// ERROR while conflicts remain, NEEDS INPUT once git can continue.
    static func status(conflicts: Int) -> ChromeStatus {
        conflicts > 0 ? .error : .needsInput
    }

    func update(operation: OperationInProgress, conflicts: Int, context: CommandContext?) {
        let colors = theme.colors
        let status = Self.status(conflicts: conflicts)
        mark.set(status: status, colors: colors)
        wash.layer?.backgroundColor = status.headerWash(in: colors)?.cgColor
        statusLabel.setStatusText(status.label, color: status.color(in: colors))
        label.setChromeText(Self.text(for: operation, conflicts: conflicts), font: ChromeFont.labelStrong, color: colors.textPrimary)
        skipButton.isHidden = !operation.canSkip
        [continueButton, abortButton, skipButton].forEach { $0.refresh(context: context) }
    }
}

/// 26 pt status bar on `bgPanel` under one hairline: the mode chip (NORMAL /
/// PREFIX), the activity mark with the latest entry, then the keyboard hints
/// of the focused region and the current branch with its commit count.
@MainActor
final class WorkspaceStatusBarView: NSView {
    static let height: CGFloat = 26

    private let topRule = ChromeRuleView(axis: .horizontal)
    private let modeChip: ChromeModeChip
    private let activityMark = ChromeStatusMark(size: 7)
    private let activityLabel = NSTextField(labelWithString: "")
    /// Hints for the focused region (`hints(for:)`).
    let hintsView: HintsView
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        modeChip = ChromeModeChip(theme: theme)
        hintsView = HintsView(theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        activityLabel.lineBreakMode = .byTruncatingTail
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintsView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(251), for: .horizontal)
        branchLabel.lineBreakMode = .byTruncatingTail
        branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        for view in [topRule, modeChip, activityMark, activityLabel, hintsView, branchIcon, branchLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // Content centres below the 1 pt top rule.
        let middle = centerYAnchor
        let offset = Chrome.hairline / 2
        NSLayoutConstraint.activate([
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: topAnchor),
            modeChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.bar),
            modeChip.centerYAnchor.constraint(equalTo: middle, constant: offset),
            activityMark.leadingAnchor.constraint(equalTo: modeChip.trailingAnchor, constant: 12),
            activityMark.centerYAnchor.constraint(equalTo: middle, constant: offset),
            activityLabel.leadingAnchor.constraint(equalTo: activityMark.trailingAnchor, constant: 6),
            activityLabel.centerYAnchor.constraint(equalTo: middle, constant: offset),
            // Gap 12 on both sides of an 8 pt minimum spacer.
            activityLabel.trailingAnchor.constraint(lessThanOrEqualTo: hintsView.leadingAnchor, constant: -32),
            hintsView.trailingAnchor.constraint(equalTo: branchIcon.leadingAnchor, constant: -12),
            hintsView.centerYAnchor.constraint(equalTo: middle, constant: offset),
            branchIcon.trailingAnchor.constraint(equalTo: branchLabel.leadingAnchor, constant: -5),
            branchIcon.centerYAnchor.constraint(equalTo: middle, constant: offset),
            branchLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.bar),
            branchLabel.centerYAnchor.constraint(equalTo: middle, constant: offset),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        topRule.color = theme.colors.borderSubtle
        branchIcon.contentTintColor = theme.colors.textMuted
        modeChip.apply(theme: theme)
        hintsView.apply(theme: theme)
    }

    /// The line of git's output that says what went wrong: the first
    /// `fatal:`/`error:` line without its prefix, else the first non-empty line.
    static func summaryLine(of message: String) -> String {
        let lines = message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for prefix in ["fatal:", "error:"] {
            if let line = lines.first(where: { $0.lowercased().hasPrefix(prefix) }) {
                return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return lines.first ?? ""
    }

    /// Keyboard hints for the focused region: the diff shows its navigation
    /// keys (`J K change`, `⇧J ⇧K file`, `V split`, `esc close`), every other
    /// region the global ones (`⌘P Commands`, `⌃A Prefix`, `? Shortcuts`).
    /// Caps come from the key bindings; unbound commands drop out.
    static func hints(for region: FocusRegion?, settings: SettingsCenter = .shared) -> [HintsView.Hint] {
        func caps(_ ids: String...) -> [String] {
            ids.flatMap { hintCaps(for: $0, settings: settings) ?? [] }
        }
        let entries: [(caps: [String], label: String)]
        if region == .diff {
            entries = [
                (caps("diff.nextHunk", "diff.previousHunk"), "change"),
                (caps("diff.nextFile", "diff.previousFile"), "file"),
                (caps("diff.toggleLayout"), "split"),
                (caps("diff.close"), "close"),
            ]
        } else {
            let keymap = settings.keymap
            entries = [
                (caps("palette.open"), "Commands"),
                (keymap.prefixChord.keycaps(prefixKey: keymap.prefixKey), "Prefix"),
                (caps("help.shortcuts"), "Shortcuts"),
            ]
        }
        return entries.filter { !$0.caps.isEmpty }.map { HintsView.Hint(caps: $0.caps, label: $0.label) }
    }

    /// The K1 caps of a command's shortest binding (`?` over `⌘/`), so the
    /// hint row stays short; nil when unbound.
    private static func hintCaps(for commandID: String, settings: SettingsCenter) -> [String]? {
        let prefixKey = settings.keymap.prefixKey
        return settings.chords(for: commandID)
            .map { $0.keycaps(prefixKey: prefixKey) }
            .min { ($0.count, $0.joined().count) < ($1.count, $1.joined().count) }
    }

    func setMode(_ mode: KeyboardRouter.State) {
        switch mode {
        case .normal: modeChip.set(mode: .normal, text: "Normal")
        case .prefix: modeChip.set(mode: .prefix, text: "Prefix")
        }
    }

    func update(
        activity: ActivityLog.Entry?,
        refs: RefSnapshot,
        commitCount: Int,
        hasMore: Bool,
        loading: Bool,
        loadError: String?,
        focus: FocusRegion?
    ) {
        let colors = theme.colors
        let text: String
        var isError = false
        if let loadError {
            activityMark.set(status: .error, colors: colors)
            isError = true
            text = loadError
        } else if let entry = activity {
            switch entry.outcome {
            case .running:
                activityMark.set(status: .running, colors: colors)
                text = entry.title + "…" + (entry.progress.map { "  " + $0 } ?? "")
            case .succeeded:
                if let note = entry.note {
                    activityMark.shape = .dot
                    activityMark.color = colors.yellow
                    text = entry.title + " — " + note
                } else {
                    activityMark.set(status: .ready, colors: colors)
                    text = entry.title + " — done"
                }
            case let .failed(message):
                activityMark.set(status: .error, colors: colors)
                isError = true
                text = entry.title + " failed: " + Self.summaryLine(of: message)
            }
        } else if loading {
            activityMark.set(status: .running, colors: colors)
            text = "Loading…"
        } else {
            activityMark.set(status: .ready, colors: colors)
            text = "Ready"
        }
        activityLabel.setChromeText(text, font: ChromeFont.meta, color: isError ? colors.danger : colors.textMuted)

        hintsView.hints = Self.hints(for: focus)

        let name: String
        switch refs.head {
        case let .branch(branch), let .unborn(branch):
            name = branch
        case let .detached(id):
            name = "Detached " + String(id.prefix(7))
        }
        let count = commitCount == 1 ? "1 commit" : "\(commitCount)\(hasMore ? "+" : "") commits"
        let branch = NSMutableAttributedString(attributedString: ChromeText.attributed(
            name, font: ChromeFont.sans(size: 11, weight: .medium), color: colors.textPrimary
        ))
        branch.append(ChromeText.attributed(" · " + count, font: ChromeFont.count, color: colors.textMuted))
        branchLabel.attributedStringValue = branch
    }
}

/// Error toast for `.failed` events: a raised card (radius 10, e2 shadow)
/// with a danger diamond, "Push failed", git's message in SF Mono and the
/// dismiss keycap. Esc (`toast.dismiss`) or a click dismisses it; it hides
/// itself after a while.
@MainActor
final class ErrorToastView: NSView {
    static let width: CGFloat = 440
    static let autoHideAfter: Duration = .seconds(12)

    private enum Metrics {
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 12
        static let gap: CGFloat = 10
        /// Centres the 8 pt mark on the 18 pt title line.
        static let markTop: CGFloat = 5
    }

    var onDismiss: (() -> Void)?

    private let mark = ChromeStatusMark(shape: .diamond)
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// The `toast.dismiss` keycaps; hidden while unbound.
    let keycaps: ChromeKeycapGroupView
    private var title = ""
    private var theme: AppTheme
    private var hideTask: Task<Void, Never>?

    init(theme: AppTheme) {
        self.theme = theme
        keycaps = ChromeKeycapGroupView(caps: [], theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        messageLabel.maximumNumberOfLines = 8
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.cell?.truncatesLastVisibleLine = true
        messageLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [mark, titleLabel, messageLabel, keycaps] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            mark.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalPadding + Metrics.markTop),
            titleLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: Metrics.gap),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalPadding),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: keycaps.leadingAnchor, constant: -Metrics.gap),
            keycaps.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            keycaps.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalPadding),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: keycaps.leadingAnchor, constant: -Metrics.gap),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.verticalPadding),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        if let layer {
            colors.shadowE2.apply(to: layer)
            layer.backgroundColor = colors.bgRaised.cgColor
            layer.cornerRadius = Chrome.Radius.popover
            layer.borderColor = colors.borderSubtle.cgColor
            layer.borderWidth = Chrome.hairline
        }
        mark.color = colors.danger
        messageLabel.font = ChromeFont.monoSmall
        messageLabel.textColor = colors.textMuted
        keycaps.apply(theme: theme)
        renderTitle()
        refreshKeycaps()
    }

    func show(title: String, message: String, theme: AppTheme) {
        self.theme = theme
        self.title = title + " failed"
        renderTitle()
        refreshKeycaps()
        messageLabel.stringValue = message
        isHidden = false
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoHideAfter)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        guard !isHidden else { return }
        isHidden = true
        onDismiss?()
    }

    override func mouseDown(with event: NSEvent) {
        dismiss()
    }

    private func renderTitle() {
        titleLabel.setChromeText(title, font: ChromeFont.sans(size: 13, weight: .semibold), color: theme.colors.danger)
    }

    private func refreshKeycaps() {
        let caps = SettingsCenter.shared.keycaps(for: "toast.dismiss") ?? []
        if keycaps.caps != caps { keycaps.caps = caps }
        keycaps.isHidden = caps.isEmpty
        let capsWidth = keycaps.fittingSize.width
        messageLabel.preferredMaxLayoutWidth = Self.width - 2 * Metrics.horizontalPadding - Chrome.statusMark
            - 2 * Metrics.gap - capsWidth
    }
}

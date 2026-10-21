import AppKit

/// One row of the shortcut sheet.
struct ShortcutEntry: Equatable {
    var id: String
    var title: String
    var category: CommandCategory
    /// Each chord's K1 keycaps (`KeyChord.keycaps(prefixKey:)`).
    var keys: [[String]]

    /// Case-insensitive substring match on title, id, category and key text.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let keyTexts = keys.map { $0.joined(separator: " ") }
        return ([title, id, category.rawValue] + keyTexts).contains { $0.lowercased().contains(needle) }
    }
}

enum ShortcutSheetModel {
    /// Every registered command with its live chords, grouped by category in
    /// `CommandCategory` order, registry order within a category.
    @MainActor
    static func sections(
        registry: CommandRegistry = .shared,
        settings: SettingsCenter = .shared,
        query: String = ""
    ) -> [(category: CommandCategory, entries: [ShortcutEntry])] {
        let keymap = settings.keymap
        let entries = registry.commands.map { command in
            ShortcutEntry(
                id: command.id,
                title: command.title,
                category: command.category,
                keys: keymap.chords(for: command.id).map { $0.keycaps(prefixKey: keymap.prefixKey) }
            )
        }
        .filter { $0.matches(query) }
        return CommandCategory.allCases.compactMap { category in
            let inCategory = entries.filter { $0.category == category }
            return inCategory.isEmpty ? nil : (category, inCategory)
        }
    }
}

/// `help.shortcuts`: a floating panel listing every command and its chords by
/// category, with type-to-filter; Esc closes. A raised 720×560 surface with a
/// 12 pt radius and the e3 shadow, New York screen title, search field,
/// eyebrow sections and one K1 keycap group per chord.
@MainActor
final class ShortcutSheetPanel: NSPanel, NSTextFieldDelegate {
    /// Size of the visible surface; the window adds the shadow margin.
    static let size = NSSize(width: 720, height: 560)

    private let root = FloatingSurfaceView(radius: Chrome.Radius.panel)
    private let titleLabel = NSTextField(labelWithString: "")
    private var search: SearchField!
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()
    private let footerRule = ChromeRuleView(axis: .horizontal, color: .clear)
    private var footerHints: HintsView!
    private let footerNote = NSTextField(labelWithString: "")
    private var theme: AppTheme

    init() {
        theme = ThemeCenter.shared.theme
        super.init(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: Self.size.width + FloatingSurfaceView.horizontalMargin,
                    height: Self.size.height + FloatingSurfaceView.verticalMargin
                )
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        // The surface layer draws the e3 shadow inside the transparent margin.
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow
        contentView = root
        build()
        // A macOS light/dark flip (folio) re-themes an open sheet too.
        ThemeCenter.shared.addObserver(self) { [weak self] theme in
            guard let self, self.isVisible else { return }
            self.apply(theme: theme)
        }
    }

    /// Re-themes the panel and its rows.
    func apply(theme: AppTheme) {
        self.theme = theme
        applyTheme()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var query: String {
        get { search.field.stringValue }
        set {
            search.field.stringValue = newValue
            reload()
        }
    }

    private func build() {
        search = SearchField(placeholder: "Filter commands, ids or keys", theme: theme)
        search.field.delegate = self
        footerHints = HintsView(hints: [HintsView.Hint(caps: [["esc"]], label: "Close")], theme: theme)
        footerNote.lineBreakMode = .byTruncatingTail
        footerNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)

        let surface = root.surface
        for view in [titleLabel, search, scrollView, footerRule, footerHints, footerNote] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalToConstant: Self.size.width),
            surface.heightAnchor.constraint(equalToConstant: Self.size.height),
            titleLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: surface.topAnchor, constant: 18),
            search.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            search.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            search.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            listStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            footerRule.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            footerRule.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -32),
            footerHints.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            footerHints.centerYAnchor.constraint(equalTo: surface.bottomAnchor, constant: -16),
            footerNote.leadingAnchor.constraint(greaterThanOrEqualTo: footerHints.trailingAnchor, constant: 14),
            footerNote.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            footerNote.centerYAnchor.constraint(equalTo: footerHints.centerYAnchor),
        ])
        applyTheme()
    }

    private func applyTheme() {
        let colors = theme.colors
        appearance = theme.appearance.nsAppearance
        root.apply(theme: theme)
        titleLabel.setChromeText("Keyboard Shortcuts", font: ChromeFont.screen, color: colors.textPrimary, tracking: -0.2)
        search.apply(theme: theme)
        footerRule.color = colors.borderSubtle
        footerHints.apply(theme: theme)
        footerNote.setChromeText("Rebind in Settings → Keyboard or settings.json", font: ChromeFont.meta, color: colors.textMuted)
    }

    func show(relativeTo parent: NSWindow) {
        search.field.stringValue = ""
        apply(theme: ThemeCenter.shared.theme)
        let parentFrame = parent.frame
        setFrameOrigin(NSPoint(
            x: parentFrame.midX - frame.width / 2,
            y: max(parentFrame.minY + 12, parentFrame.maxY - frame.height - 72 + FloatingSurfaceView.margins.top)
        ))
        if let current = self.parent, current !== parent {
            current.removeChildWindow(self)
        }
        if self.parent == nil {
            parent.addChildWindow(self, ordered: .above)
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(search.field)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func resignKey() {
        super.resignKey()
        if isVisible, parent?.isKeyWindow == true { dismiss() }
    }

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            scroll(by: commandSelector == #selector(NSResponder.moveDown(_:)) ? 60 : 400)
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            scroll(by: commandSelector == #selector(NSResponder.moveUp(_:)) ? -60 : -400)
            return true
        default:
            return false
        }
    }

    private func scroll(by delta: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, clip.bounds.origin.y + delta), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Number of rows shown (tests).
    private(set) var visibleEntryCount = 0

    private func reload() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let sections = ShortcutSheetModel.sections(query: search.field.stringValue)
        visibleEntryCount = sections.reduce(0) { $0 + $1.entries.count }
        let colors = theme.colors
        if sections.isEmpty {
            let empty = NSTextField(labelWithString: "")
            empty.setChromeText("No matching commands", font: ChromeFont.empty, color: colors.textMuted)
            listStack.addArrangedSubview(empty)
        }
        for (index, section) in sections.enumerated() {
            let heading = ChromeEyebrowView(title: section.category.rawValue, theme: theme)
            listStack.addArrangedSubview(heading)
            heading.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            if index > 0 {
                listStack.setCustomSpacing(16, after: listStack.arrangedSubviews[listStack.arrangedSubviews.count - 2])
            }
            listStack.setCustomSpacing(6, after: heading)
            for entry in section.entries {
                let row = ShortcutRow(entry: entry, theme: theme)
                listStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }
        root.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
    }
}

/// One command: title (SF Pro 12), id (SF Mono 11 muted) and one K1 keycap
/// group per chord.
final class ShortcutRow: NSView {
    /// One group per chord, in order (tests).
    private(set) var keycapGroups: [ChromeKeycapGroupView] = []

    init(entry: ShortcutEntry, theme: AppTheme) {
        super.init(frame: .zero)
        let colors = theme.colors
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.setChromeText(entry.title, font: ChromeFont.label, color: colors.textPrimary)
        let id = NSTextField(labelWithString: "")
        id.lineBreakMode = .byTruncatingTail
        id.setChromeText(entry.id, font: ChromeFont.monoSmall, color: colors.textMuted)
        id.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keys = NSStackView()
        keys.orientation = .horizontal
        keys.alignment = .centerY
        keys.spacing = 6
        if entry.keys.isEmpty {
            let none = NSTextField(labelWithString: "")
            none.setChromeText("—", font: ChromeFont.meta, color: colors.textMuted)
            keys.addArrangedSubview(none)
        } else {
            for caps in entry.keys {
                let group = ChromeKeycapGroupView(caps: caps, theme: theme)
                keycapGroups.append(group)
                keys.addArrangedSubview(group)
            }
        }
        keys.setContentHuggingPriority(.required, for: .horizontal)
        for view in [title, id, keys] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(equalToConstant: 260),
            id.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            id.centerYAnchor.constraint(equalTo: centerYAnchor),
            id.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -8),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Top-left origin document view for scroll views.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

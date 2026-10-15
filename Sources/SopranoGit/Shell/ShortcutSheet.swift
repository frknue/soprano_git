import AppKit

/// One row of the shortcut sheet.
struct ShortcutEntry: Equatable {
    var id: String
    var title: String
    var category: CommandCategory
    var keys: [String]

    /// Case-insensitive substring match on title, id, category and key text.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return ([title, id, category.rawValue] + keys).contains { $0.lowercased().contains(needle) }
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
                keys: keymap.chords(for: command.id).map { $0.compactText(prefixKey: keymap.prefixKey) }
            )
        }
        .filter { $0.matches(query) }
        return CommandCategory.allCases.compactMap { category in
            let inCategory = entries.filter { $0.category == category }
            return inCategory.isEmpty ? nil : (category, inCategory)
        }
    }
}

/// `help.shortcuts`: a Mission Control panel listing every command and its
/// chords by category, with type-to-filter; Esc closes.
@MainActor
final class ShortcutSheetPanel: NSPanel, NSTextFieldDelegate {
    static let size = NSSize(width: 720, height: 560)

    private let root = NSView()
    private let stripe = RetroStripeView(layout: .slanted)
    private let titleLabel = NSTextField(labelWithString: "")
    private let headerRule = RetroRuleView(axis: .horizontal, style: .double)
    private var search: RetroSearchField!
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private var theme: AppTheme

    init() {
        theme = ThemeCenter.shared.theme
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
        contentView = root
        build()
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
        search = RetroSearchField(placeholder: "Filter commands, ids or keys...", theme: theme)
        search.field.delegate = self

        root.wantsLayer = true
        root.layer?.borderWidth = Retro.hairline

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
        listStack.spacing = 4
        listStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)

        for view in [stripe, titleLabel, headerRule, search, scrollView, footerLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stripe.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 22),
            stripe.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            headerRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerRule.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            search.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -8),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            listStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footerLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        applyTheme()
    }

    private func applyTheme() {
        let colors = theme.colors
        root.layer?.backgroundColor = colors.bgPanel.withAlphaComponent(0.985).cgColor
        root.layer?.borderColor = colors.borderStrong.cgColor
        stripe.colors = colors.stripe
        titleLabel.setRetroText("Keyboard Shortcuts", color: colors.accent, glow: true)
        headerRule.color = colors.borderStrong
        search.apply(theme: theme)
        footerLabel.setRetroText(
            "Type  Filter    esc  Close    rebind in settings.json → keybindings.bindings",
            color: colors.textMuted
        )
    }

    func show(relativeTo parent: NSWindow) {
        theme = ThemeCenter.shared.theme
        applyTheme()
        search.field.stringValue = ""
        reload()
        let parentFrame = parent.frame
        setFrameOrigin(NSPoint(
            x: parentFrame.midX - Self.size.width / 2,
            y: max(parentFrame.minY + 12, parentFrame.maxY - Self.size.height - 72)
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
            empty.setRetroText("No matching commands", color: colors.textMuted)
            listStack.addArrangedSubview(empty)
        }
        for (index, section) in sections.enumerated() {
            let heading = RetroHeadingView(title: section.category.rawValue, theme: theme, accented: true)
            listStack.addArrangedSubview(heading)
            heading.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            if index > 0 {
                listStack.setCustomSpacing(14, after: listStack.arrangedSubviews[listStack.arrangedSubviews.count - 2])
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

private final class ShortcutRow: NSView {
    init(entry: ShortcutEntry, theme: AppTheme) {
        super.init(frame: .zero)
        let colors = theme.colors
        let title = NSTextField(labelWithString: entry.title)
        title.font = RetroFont.body(12)
        title.textColor = colors.textPrimary
        title.lineBreakMode = .byTruncatingTail
        let id = NSTextField(labelWithString: entry.id)
        id.font = RetroFont.body(10)
        id.textColor = colors.textMuted
        id.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keys = NSStackView()
        keys.spacing = 4
        if entry.keys.isEmpty {
            let none = NSTextField(labelWithString: "")
            none.setRetroText("—", color: colors.textMuted)
            keys.addArrangedSubview(none)
        } else {
            for key in entry.keys {
                keys.addArrangedSubview(KeycapView(text: key, theme: theme))
            }
        }
        keys.setContentHuggingPriority(.required, for: .horizontal)
        for view in [title, id, keys] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
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

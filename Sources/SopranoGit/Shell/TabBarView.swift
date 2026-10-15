import AppKit

/// Repository tabs in the titlebar area (Soprano's `WindowTabBarView` look):
/// 78 pt inset for the traffic lights, selected tab = accent block with
/// `bgPanel` ink, others muted with hairline separators, `+` at the end.
@MainActor
final class TabBarView: NSView {
    static let height: CGFloat = 34
    static let trafficLightInset: CGFloat = 78

    struct Item: Equatable {
        var title: String
        var detail: String?
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private var buttons: [TabButton] = []
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let bottomRule = RetroRuleView(axis: .horizontal, style: .single)
    private var items: [Item] = []
    private var selectedIndex = 0
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        addButton.isBordered = false
        addButton.refusesFirstResponder = true
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.toolTip = "New Tab (⌘T)"
        addButton.setAccessibilityLabel("New Tab")
        addSubview(addButton)
        addSubview(bottomRule)
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Dragging the empty strip moves the window, like a titlebar.
    override var mouseDownCanMoveWindow: Bool { true }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.bgBase.cgColor
        bottomRule.color = theme.colors.borderSubtle
        addButton.attributedTitle = RetroText.display("+", color: theme.colors.textMuted, size: 22)
        reloadButtons()
    }

    func update(items: [Item], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = selectedIndex
        reloadButtons()
    }

    private func reloadButtons() {
        while buttons.count > items.count {
            buttons.removeLast().removeFromSuperview()
        }
        while buttons.count < items.count {
            let button = TabButton()
            button.target = self
            button.action = #selector(tabClicked(_:))
            button.onMiddleClick = { [weak self, weak button] in
                guard let self, let button, let index = self.buttons.firstIndex(of: button) else { return }
                self.onClose?(index)
            }
            addSubview(button)
            buttons.append(button)
        }
        for (index, item) in items.enumerated() {
            buttons[index].configure(
                number: index + 1,
                item: item,
                isSelected: index == selectedIndex,
                showsSeparator: index != selectedIndex && index + 1 != selectedIndex,
                theme: theme
            )
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x = Self.trafficLightInset
        for button in buttons {
            button.frame = NSRect(x: x, y: 0, width: button.tabWidth, height: bounds.height - Retro.hairline)
            x += button.tabWidth
        }
        addButton.frame = NSRect(x: x + 4, y: 1, width: 28, height: bounds.height - 2)
        bottomRule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Retro.hairline)
    }

    @objc private func tabClicked(_ sender: TabButton) {
        guard let index = buttons.firstIndex(of: sender) else { return }
        onSelect?(index)
    }

    @objc private func addClicked() {
        onAdd?()
    }
}

private final class TabButton: NSButton {
    var onMiddleClick: (() -> Void)?
    private(set) var tabWidth: CGFloat = 120
    private let separator = NSView()

    init() {
        super.init(frame: .zero)
        isBordered = false
        refusesFirstResponder = true
        wantsLayer = true
        setButtonType(.momentaryChange)
        (cell as? NSButtonCell)?.highlightsBy = []
        separator.wantsLayer = true
        addSubview(separator)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(number: Int, item: TabBarView.Item, isSelected: Bool, showsSeparator: Bool, theme: AppTheme) {
        let colors = theme.colors
        let text = "\(number):\(item.title)"
        attributedTitle = RetroText.display(
            text,
            color: isSelected ? colors.bgPanel : colors.textMuted,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        tabWidth = min(220, max(88, ceil(attributedTitle.size().width) + 28))
        layer?.backgroundColor = isSelected ? colors.accent.cgColor : NSColor.clear.cgColor
        separator.isHidden = !showsSeparator
        separator.layer?.backgroundColor = colors.borderSubtle.cgColor
        toolTip = item.detail ?? item.title
        setAccessibilityLabel("Tab \(number): \(item.title)")
        setAccessibilityValue(isSelected)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: bounds.maxX - Retro.hairline, y: 9, width: Retro.hairline, height: bounds.height - 18)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onMiddleClick?()
        } else {
            super.otherMouseDown(with: event)
        }
    }
}

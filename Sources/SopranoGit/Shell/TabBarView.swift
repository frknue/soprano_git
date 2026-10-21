import AppKit

/// Repository tabs in the 36 pt titlebar strip on `bgPanel`: a 78 pt inset for
/// the traffic lights, 24 pt tab pills 4 pt apart (`1  soprano`, index muted),
/// the selected one raised with a `borderSubtle` edge and ink Medium title,
/// a `hover` pill under the pointer, then `+`. One hairline closes it below.
@MainActor
final class TabBarView: NSView {
    static let height: CGFloat = 36
    static let trafficLightInset: CGFloat = 78
    static let tabHeight: CGFloat = Chrome.controlHeight
    static let tabSpacing: CGFloat = 4

    struct Item: Equatable {
        var title: String
        var detail: String?
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private var buttons: [TabButton] = []
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let bottomRule = ChromeRuleView(axis: .horizontal)
    private var items: [Item] = []
    private var selectedIndex = 0
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        addButton.isBordered = false
        addButton.imagePosition = .imageOnly
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
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
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        bottomRule.color = theme.colors.borderSubtle
        addButton.contentTintColor = theme.colors.textMuted
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
            buttons[index].configure(number: index + 1, item: item, isSelected: index == selectedIndex, theme: theme)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Content centres in the strip above the bottom hairline.
        let midY = Chrome.hairline + (bounds.height - Chrome.hairline) / 2
        var x = Self.trafficLightInset
        for button in buttons {
            button.frame = NSRect(x: x, y: floor(midY - Self.tabHeight / 2), width: button.tabWidth, height: Self.tabHeight)
            x += button.tabWidth + Self.tabSpacing
        }
        // `+` sits 4 pt further out than the tab gap.
        let addSize = Chrome.iconButtonSize
        let glyphInset = floor((addSize - 14) / 2)
        addButton.frame = NSRect(x: x + 4 - glyphInset, y: floor(midY - addSize / 2), width: addSize, height: addSize)
        bottomRule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Chrome.hairline)
    }

    @objc private func tabClicked(_ sender: TabButton) {
        guard let index = buttons.firstIndex(of: sender) else { return }
        onSelect?(index)
    }

    @objc private func addClicked() {
        onAdd?()
    }
}

/// One tab pill: `1  soprano` in SF Pro 12, padding 0 12 0 10.
private final class TabButton: NSButton {
    static let leadingPadding: CGFloat = 10
    static let trailingPadding: CGFloat = 12
    static let maxWidth: CGFloat = 240

    var onMiddleClick: (() -> Void)?
    private(set) var tabWidth: CGFloat = 120
    private var isSelectedTab = false
    private var label = NSAttributedString()
    private var colors: ThemeColors?
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        refusesFirstResponder = true
        title = ""
        setButtonType(.momentaryChange)
        (cell as? NSButtonCell)?.highlightsBy = []
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(number: Int, item: TabBarView.Item, isSelected: Bool, theme: AppTheme) {
        let colors = theme.colors
        self.colors = colors
        isSelectedTab = isSelected
        let text = NSMutableAttributedString(attributedString: ChromeText.attributed(
            "\(number)  ",
            font: ChromeFont.sans(size: 12, tabular: true),
            color: colors.textMuted
        ))
        text.append(ChromeText.attributed(
            item.title,
            font: isSelected ? ChromeFont.labelStrong : ChromeFont.label,
            color: isSelected ? colors.textPrimary : colors.textMuted
        ))
        label = text
        let width = ceil(text.size().width) + Self.leadingPadding + Self.trailingPadding
        tabWidth = min(Self.maxWidth, width)
        toolTip = item.detail ?? item.title
        setAccessibilityLabel("Tab \(number): \(item.title)")
        setAccessibilityValue(isSelected)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        let style: ChromeSelectionPill.Style = isSelectedTab ? .raisedTab : (isHovered ? .hover : .none)
        ChromeSelectionPill.draw(style, in: bounds, colors: colors, inset: 0)
        let height = label.size().height
        let rect = NSRect(
            x: Self.leadingPadding,
            y: floor((bounds.height - height) / 2),
            width: bounds.width - Self.leadingPadding - Self.trailingPadding,
            height: height
        )
        label.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

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

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onMiddleClick?()
        } else {
            super.otherMouseDown(with: event)
        }
    }
}

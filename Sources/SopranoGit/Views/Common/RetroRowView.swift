import AppKit

/// A list row with Soprano's selection look. Focused region (emphasized):
/// bgSelectedStrong plus a 2pt accent leading rail; unfocused: bgSelected plus
/// a railMuted rail; hover (not selected): bgOverlay.
final class RetroRowView: NSTableRowView {
    static let railWidth: CGFloat = 2

    var colors: ThemeColors? {
        didSet { needsDisplay = true }
    }

    var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    var showsRail = true {
        didSet { needsDisplay = true }
    }

    override var isEmphasized: Bool {
        didSet { needsDisplay = true }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let colors else { return super.drawBackground(in: dirtyRect) }
        if isHovered && !isSelected {
            colors.bgOverlay.setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let colors else { return super.drawSelection(in: dirtyRect) }
        (isEmphasized ? colors.bgSelectedStrong : colors.bgSelected).setFill()
        bounds.fill()
        if showsRail {
            (isEmphasized ? colors.accent : colors.railMuted).setFill()
            NSRect(x: 0, y: 0, width: Self.railWidth, height: bounds.height).fill()
        }
    }
}

/// Table and outline styling shared by every list.
@MainActor
enum RetroListStyle {
    static func apply(to tableView: NSTableView, theme: AppTheme, rowHeight: CGFloat = 24) {
        tableView.style = .plain
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.rowHeight = rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .regular
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = theme.colors.bgPanel
        if let retro = tableView as? RetroTableView {
            retro.colors = theme.colors
        } else if let retro = tableView as? RetroOutlineView {
            retro.colors = theme.colors
        } else {
            tableView.enumerateAvailableRowViews { rowView, _ in
                (rowView as? RetroRowView)?.colors = theme.colors
            }
        }
        tableView.needsDisplay = true
    }

    static func makeScrollView(documentView: NSView, theme: AppTheme) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        applyScrollView(scrollView, theme: theme)
        return scrollView
    }

    static func applyScrollView(_ scrollView: NSScrollView, theme: AppTheme) {
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.colors.bgPanel
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = theme.colors.bgPanel
    }
}

/// Pointer tracking shared by `RetroTableView` and `RetroOutlineView`.
@MainActor
private final class RowHoverTracker {
    private var area: NSTrackingArea?
    private(set) var row = -1

    func updateTrackingAreas(in view: NSView) {
        if let area { view.removeTrackingArea(area) }
        let newArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: view,
            userInfo: nil
        )
        view.addTrackingArea(newArea)
        area = newArea
    }

    func set(_ newRow: Int, in table: NSTableView) {
        guard newRow != row else { return }
        if row >= 0, row < table.numberOfRows {
            (table.rowView(atRow: row, makeIfNecessary: false) as? RetroRowView)?.isHovered = false
        }
        row = newRow
        if row >= 0 {
            (table.rowView(atRow: row, makeIfNecessary: false) as? RetroRowView)?.isHovered = true
        }
    }

    func update(with event: NSEvent, in table: NSTableView) {
        let point = table.convert(event.locationInWindow, from: nil)
        set(table.row(at: point), in: table)
    }

    func clear(in table: NSTableView) {
        set(-1, in: table)
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView as? RetroRowView)?.isHovered = false
        }
    }
}

/// A table that tracks the hovered row and vends `RetroRowView`s when its
/// delegate does not supply row views.
final class RetroTableView: NSTableView {
    private let tracker = RowHoverTracker()

    var hoveredRow: Int { tracker.row }

    var colors: ThemeColors? {
        didSet {
            enumerateAvailableRowViews { rowView, _ in (rowView as? RetroRowView)?.colors = colors }
        }
    }

    func makeRetroRowView(row: Int) -> RetroRowView {
        let rowView = RetroRowView()
        rowView.colors = colors
        rowView.isHovered = row == hoveredRow
        return rowView
    }

    /// AppKit asks for `rowViewKey` when the delegate supplies no row view;
    /// answer with a `RetroRowView` instead of a plain one.
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        if let view = super.makeView(withIdentifier: identifier, owner: owner) { return view }
        return identifier == NSTableView.rowViewIdentifier ? makeRetroRowView(row: -1) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracker.updateTrackingAreas(in: self)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        tracker.update(with: event, in: self)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        tracker.update(with: event, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        tracker.clear(in: self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        tracker.clear(in: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tracker.clear(in: self) }
    }

    override func reloadData() {
        tracker.clear(in: self)
        super.reloadData()
    }

    override func didAdd(_ rowView: NSTableRowView, forRow row: Int) {
        super.didAdd(rowView, forRow: row)
        if let retro = rowView as? RetroRowView {
            retro.colors = retro.colors ?? colors
            retro.isHovered = row == hoveredRow
        }
    }
}

/// The outline counterpart of `RetroTableView`.
final class RetroOutlineView: NSOutlineView {
    private let tracker = RowHoverTracker()

    var hoveredRow: Int { tracker.row }

    var colors: ThemeColors? {
        didSet {
            enumerateAvailableRowViews { rowView, _ in (rowView as? RetroRowView)?.colors = colors }
        }
    }

    func makeRetroRowView(row: Int) -> RetroRowView {
        let rowView = RetroRowView()
        rowView.colors = colors
        rowView.isHovered = row == hoveredRow
        return rowView
    }

    /// AppKit asks for `rowViewKey` when the delegate supplies no row view;
    /// answer with a `RetroRowView` instead of a plain one.
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        if let view = super.makeView(withIdentifier: identifier, owner: owner) { return view }
        return identifier == NSTableView.rowViewIdentifier ? makeRetroRowView(row: -1) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracker.updateTrackingAreas(in: self)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        tracker.update(with: event, in: self)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        tracker.update(with: event, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        tracker.clear(in: self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        tracker.clear(in: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tracker.clear(in: self) }
    }

    override func reloadData() {
        tracker.clear(in: self)
        super.reloadData()
    }

    override func didAdd(_ rowView: NSTableRowView, forRow row: Int) {
        super.didAdd(rowView, forRow: row)
        if let retro = rowView as? RetroRowView {
            retro.colors = retro.colors ?? colors
            retro.isHovered = row == hoveredRow
        }
    }
}

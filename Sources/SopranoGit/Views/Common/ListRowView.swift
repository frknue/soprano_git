import AppKit

/// A list row with Folio's selection idiom: an inset selection pill, plus the
/// sienna pencil tick while the list's region holds focus (emphasized); the
/// muted pill without a tick otherwise; a hover pill under the pointer.
final class ListRowView: NSTableRowView {
    /// Vertical inset of the pill inside the row (`inset: 2px 4px` in the mock).
    static let pillVerticalInset: CGFloat = 2

    var colors: ThemeColors? {
        didSet { needsDisplay = true }
    }

    var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    override var isEmphasized: Bool {
        didSet { needsDisplay = true }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    /// The pill style the row draws in its current state.
    var pillStyle: ChromeSelectionPill.Style {
        if isSelected { return showsFocus ? .selected : .selectedUnfocused }
        return isHovered ? .hover : .none
    }

    /// AppKit's emphasis, or, in a window that renders as key without being
    /// key (snapshot harness), whether the row's list is first responder.
    private var showsFocus: Bool {
        if isEmphasized { return true }
        guard let window = window as? MainWindow, window.rendersAsKey, let list = superview else { return false }
        return window.firstResponder === list
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let colors else { return super.drawBackground(in: dirtyRect) }
        guard !isSelected, isHovered else { return }
        ChromeSelectionPill.draw(.hover, in: pillRect, colors: colors)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let colors else { return super.drawSelection(in: dirtyRect) }
        ChromeSelectionPill.draw(showsFocus ? .selected : .selectedUnfocused, in: pillRect, colors: colors)
    }

    private var pillRect: NSRect {
        bounds.insetBy(dx: 0, dy: Self.pillVerticalInset)
    }
}

/// Table and outline styling shared by every list.
@MainActor
enum ListStyle {
    /// The surface a list sits on: `panel` (refs, commit panel, welcome,
    /// settings) or `base` (the graph and diff in the center).
    enum Surface {
        case panel
        case base

        func color(in colors: ThemeColors) -> NSColor {
            self == .panel ? colors.bgPanel : colors.bgBase
        }
    }

    static func apply(to tableView: NSTableView, theme: AppTheme, rowHeight: CGFloat = 24, surface: Surface = .panel) {
        tableView.style = .plain
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.rowHeight = rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .regular
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = surface.color(in: theme.colors)
        if let table = tableView as? ListTableView {
            table.colors = theme.colors
        } else if let outline = tableView as? ListOutlineView {
            outline.colors = theme.colors
        } else {
            tableView.enumerateAvailableRowViews { rowView, _ in
                (rowView as? ListRowView)?.colors = theme.colors
            }
        }
        tableView.needsDisplay = true
    }

    static func makeScrollView(documentView: NSView, theme: AppTheme, surface: Surface = .panel) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        applyScrollView(scrollView, theme: theme, surface: surface)
        return scrollView
    }

    static func applyScrollView(_ scrollView: NSScrollView, theme: AppTheme, surface: Surface = .panel) {
        let color = surface.color(in: theme.colors)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = color
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = color
    }
}

/// Pointer tracking shared by `ListTableView` and `ListOutlineView`.
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
            (table.rowView(atRow: row, makeIfNecessary: false) as? ListRowView)?.isHovered = false
        }
        row = newRow
        if row >= 0 {
            (table.rowView(atRow: row, makeIfNecessary: false) as? ListRowView)?.isHovered = true
        }
    }

    func update(with event: NSEvent, in table: NSTableView) {
        let point = table.convert(event.locationInWindow, from: nil)
        set(table.row(at: point), in: table)
    }

    func clear(in table: NSTableView) {
        set(-1, in: table)
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView as? ListRowView)?.isHovered = false
        }
    }
}

/// A table that tracks the hovered row and vends `ListRowView`s when its
/// delegate does not supply row views.
class ListTableView: NSTableView {
    private let tracker = RowHoverTracker()

    var hoveredRow: Int { tracker.row }

    var colors: ThemeColors? {
        didSet {
            enumerateAvailableRowViews { rowView, _ in (rowView as? ListRowView)?.colors = colors }
        }
    }

    func makeListRowView(row: Int) -> ListRowView {
        let rowView = ListRowView()
        rowView.colors = colors
        rowView.isHovered = row == hoveredRow
        return rowView
    }

    /// AppKit asks for `rowViewKey` when the delegate supplies no row view;
    /// answer with a `ListRowView` instead of a plain one.
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        if let view = super.makeView(withIdentifier: identifier, owner: owner) { return view }
        return identifier == NSTableView.rowViewIdentifier ? makeListRowView(row: -1) : nil
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
        if let listRow = rowView as? ListRowView {
            listRow.colors = listRow.colors ?? colors
            listRow.isHovered = row == hoveredRow
        }
    }
}

/// The outline counterpart of `ListTableView`. Its cells draw their own
/// disclosure chevrons and indentation, so the outline column's cell spans
/// the full row and AppKit reserves no triangle space.
final class ListOutlineView: NSOutlineView {
    private let tracker = RowHoverTracker()

    var hoveredRow: Int { tracker.row }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        guard column == 0 else { return frame }
        return NSRect(x: 0, y: frame.minY, width: frame.maxX, height: frame.height)
    }

    var colors: ThemeColors? {
        didSet {
            enumerateAvailableRowViews { rowView, _ in (rowView as? ListRowView)?.colors = colors }
        }
    }

    func makeListRowView(row: Int) -> ListRowView {
        let rowView = ListRowView()
        rowView.colors = colors
        rowView.isHovered = row == hoveredRow
        return rowView
    }

    /// AppKit asks for `rowViewKey` when the delegate supplies no row view;
    /// answer with a `ListRowView` instead of a plain one.
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        if let view = super.makeView(withIdentifier: identifier, owner: owner) { return view }
        return identifier == NSTableView.rowViewIdentifier ? makeListRowView(row: -1) : nil
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
        if let listRow = rowView as? ListRowView {
            listRow.colors = listRow.colors ?? colors
            listRow.isHovered = row == hoveredRow
        }
    }
}

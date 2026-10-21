import AppKit
import Testing
@testable import SopranoGit

@MainActor
struct ListRowViewTests {
    @Test func hoverIsClearedWhenTheRowLeavesItsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
        let row = ListRowView()
        window.contentView?.addSubview(row)
        row.isHovered = true
        #expect(row.isHovered)
        row.removeFromSuperview()
        #expect(!row.isHovered)
    }

    @Test func aSelectedRowDrawsThePillWithTheTickOnlyWhileItsListHasFocus() {
        let row = ListRowView()
        #expect(row.interiorBackgroundStyle == .normal)
        #expect(row.pillStyle == .none)
        row.isHovered = true
        #expect(row.pillStyle == .hover)
        row.isSelected = true
        row.isEmphasized = true
        #expect(row.pillStyle == .selected)
        row.isEmphasized = false
        #expect(row.pillStyle == .selectedUnfocused)
    }

    @Test func tableVendsListRowViewsWhenTheDelegateSuppliesNone() {
        let table = ListTableView()
        table.colors = AppTheme.folioPaper.colors
        let view = table.makeView(withIdentifier: NSTableView.rowViewIdentifier, owner: nil)
        let row = view as? ListRowView
        #expect(row != nil)
        #expect(row?.colors?.accent == AppTheme.folioPaper.colors.accent)
        #expect(table.hoveredRow == -1)
    }

    @Test func aShorterContentHeightAlignsThePillToTheRowsBottomContent() {
        let row = ListRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        #expect(row.pillRect.height == 28)
        row.contentHeight = 24
        #expect(row.pillRect.height == 20)
        let contentTop: CGFloat = row.isFlipped ? 8 : 0
        #expect(row.pillRect.minY == contentTop + ListRowView.pillVerticalInset)
    }

    @Test func listStyleStripsChromeAndUsesTheSurfaceColor() {
        let table = ListTableView()
        ListStyle.apply(to: table, theme: .folioPaper, rowHeight: 22)
        #expect(table.rowHeight == 22)
        #expect(table.headerView == nil)
        #expect(table.intercellSpacing == .zero)
        #expect(table.gridStyleMask.isEmpty)
        #expect(table.backgroundColor == AppTheme.folioPaper.colors.bgPanel)
        #expect(table.colors?.accent == AppTheme.folioPaper.colors.accent)
        ListStyle.apply(to: table, theme: .folioInk, surface: .base)
        #expect(table.backgroundColor == AppTheme.folioInk.colors.bgBase)
    }
}

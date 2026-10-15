import AppKit
import Testing
@testable import SopranoGit

@MainActor
struct RetroRowViewTests {
    @Test func hoverIsClearedWhenTheRowLeavesItsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
        let row = RetroRowView()
        window.contentView?.addSubview(row)
        row.isHovered = true
        #expect(row.isHovered)
        row.removeFromSuperview()
        #expect(!row.isHovered)
    }

    @Test func rowsKeepNormalInteriorBackgroundAndShowTheRailByDefault() {
        let row = RetroRowView()
        row.isSelected = true
        #expect(row.interiorBackgroundStyle == .normal)
        #expect(row.showsRail)
    }

    @Test func tableVendsRetroRowViewsWhenTheDelegateSuppliesNone() {
        let table = RetroTableView()
        table.colors = AppTheme.missionControl.colors
        let view = table.makeView(withIdentifier: NSTableView.rowViewIdentifier, owner: nil)
        let row = view as? RetroRowView
        #expect(row != nil)
        #expect(row?.colors?.accent == AppTheme.missionControl.colors.accent)
        #expect(table.hoveredRow == -1)
    }

    @Test func listStyleStripsChromeAndSetsRowHeight() {
        let table = RetroTableView()
        RetroListStyle.apply(to: table, theme: .missionControl, rowHeight: 22)
        #expect(table.rowHeight == 22)
        #expect(table.headerView == nil)
        #expect(table.intercellSpacing == .zero)
        #expect(table.gridStyleMask.isEmpty)
        #expect(table.backgroundColor == AppTheme.missionControl.colors.bgPanel)
        #expect(table.colors?.accent == AppTheme.missionControl.colors.accent)
    }
}

import AppKit
import Testing
@testable import SopranoGit

@MainActor
struct CommonControlsTests {
    @Test func panelHeaderHoldsAccessoriesAndShowsTheFocusRuleOnlyWhenFocused() {
        let header = PanelHeaderView(title: "Files", theme: .folioPaper)
        header.setAccessoryViews([ChromeKeycapView(legend: "/", theme: .folioPaper)])
        header.setAccessoryViews([NSView(), NSView()])
        #expect(header.accessoryViews.count == 2)
        #expect(!header.showsFocusRule)
        #expect(header.layer?.backgroundColor == AppTheme.folioPaper.colors.bgPanel.cgColor)
        header.isFocused = true
        #expect(header.showsFocusRule)
        #expect(header.layer?.backgroundColor == AppTheme.folioPaper.colors.raised.cgColor)
    }

    @Test func searchFieldShowsPlaceholderAndAnOptionalSmallMutedHint() {
        let search = SearchField(placeholder: "Filter", theme: .folioPaper, hint: "/")
        #expect(search.field.placeholderAttributedString?.string == "Filter")
        #expect(search.hintView?.legend == "/")
        #expect(search.hintView?.style == .small)
        #expect(search.hintView?.tone == .muted)
        #expect(SearchField(placeholder: "x", theme: .folioPaper).hintView == nil)
    }
}

import AppKit
import Testing
@testable import SopranoGit

@MainActor
struct CommonControlsTests {
    final class Sink: NSObject {
        var count = 0
        @objc func toggled(_ sender: Any?) { count += 1 }
    }

    @Test func keycapSwapsFillAndInkWhenLitOrOnAccent() {
        let colors = AppTheme.missionControl.colors
        let keycap = KeycapView(text: "⌘K", theme: .missionControl)
        #expect(keycap.fillColor == colors.bgRaised)
        #expect(keycap.inkColor == colors.textMuted)
        #expect(keycap.intrinsicContentSize.height == 16)
        keycap.isLit = true
        #expect(keycap.fillColor == colors.accent)
        #expect(keycap.inkColor == colors.bgPanel)
        keycap.isOnAccent = true
        #expect(keycap.fillColor == .clear)
        #expect(keycap.edgeColor == colors.bgPanel)
    }

    @Test func checkboxToggleFlipsStateAndSendsAction() {
        let sink = Sink()
        let box = RetroCheckbox(title: "Amend", theme: .missionControl, target: sink, action: #selector(Sink.toggled(_:)))
        #expect(!box.isOn)
        box.toggle()
        #expect(box.isOn)
        #expect(sink.count == 1)
    }

    @Test func panelHeaderHoldsAccessoriesAndFocusState() {
        let header = PanelHeaderView(title: "Files", theme: .missionControl)
        header.setAccessoryViews([KeycapView(text: "/", theme: .missionControl)])
        header.setAccessoryViews([NSView(), NSView()])
        #expect(header.accessoryViews.count == 2)
        header.isFocused = true
        #expect(header.layer?.backgroundColor == AppTheme.missionControl.colors.bgRaised.cgColor)
    }

    @Test func searchFieldShowsPlaceholderAndOptionalHint() {
        let search = RetroSearchField(placeholder: "Filter", theme: .missionControl, hint: "/")
        #expect(search.field.placeholderAttributedString?.string == "Filter")
        #expect(search.hintView?.text == "/")
        #expect(RetroSearchField(placeholder: "x", theme: .missionControl).hintView == nil)
    }
}

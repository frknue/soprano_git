import AppKit
import Testing
@testable import SopranoGit

/// Dialog chrome: ink or danger confirm, K1 hint caps, the option pill with
/// its tick following the selection, and the prompt's invalid state.
@MainActor
struct DialogChromeTests {
    private func panel(_ kind: DialogSpec.Kind, destructive: Bool = false, confirmTitle: String = "OK") -> DialogPanel {
        DialogPanel(
            spec: DialogSpec(title: "Title", message: "Message", confirmTitle: confirmTitle, isDestructive: destructive, kind: kind),
            theme: .folioPaper
        )
    }

    @Test func confirmIsInkAndDestructiveConfirmIsDanger() {
        #expect(panel(.confirm).confirmButton.kind == .ink)
        #expect(panel(.confirm, destructive: true).confirmButton.kind == .danger)
        #expect(panel(.confirm).cancelButton.kind == .standard)
    }

    @Test func hintsUseK1Caps() {
        let confirm = panel(.confirm, confirmTitle: "Delete")
        #expect(confirm.hintsView.hints == [
            HintsView.Hint(caps: [["↵"]], label: "Delete"),
            HintsView.Hint(caps: [["esc"]], label: "Cancel"),
        ])
        let choose = panel(.choose([DialogOption(title: "A"), DialogOption(title: "B")]))
        #expect(choose.hintsView.hints.first == HintsView.Hint(caps: [["J"], ["K"]], label: "Move"))
    }

    @Test func alternativeKeysAreSeparateGroupsReadAsOr() throws {
        let hints = HintsView(hints: [HintsView.Hint(caps: [["J"], ["K"]], label: "Move"), HintsView.Hint(caps: [["⌃A", "P"]], label: "Pull")], theme: .folioPaper)
        let pairs = hints.arrangedSubviews.compactMap { $0 as? NSStackView }
        let move = try #require(pairs.first?.arrangedSubviews.first as? NSStackView)
        #expect(move.arrangedSubviews.compactMap { ($0 as? ChromeKeycapGroupView)?.caps } == [["J"], ["K"]])
        #expect(move.accessibilityLabel() == "J or K")
        let pull = try #require(pairs.last?.arrangedSubviews.first as? NSStackView)
        #expect(pull.accessibilityLabel() == "⌃A then P")
    }

    @Test func theSelectedOptionIsTheFocusedPillWithItsTick() {
        let dialog = panel(.choose([
            DialogOption(title: "Soft", key: "s"),
            DialogOption(title: "Hard", key: "h", isDestructive: true),
        ]))
        #expect(dialog.optionRowStyles == [.selected, .none])
        dialog.selectOption(1)
        #expect(dialog.optionRowStyles == [.none, .selected])
    }

    @Test func anInvalidPromptShowsItsErrorAndDisablesConfirm() {
        let dialog = panel(.prompt(placeholder: "name", initialValue: "", isSecure: false, validate: { $0.contains(" ") ? "No spaces." : nil }))
        #expect(!dialog.showsError)
        dialog.setValue("a b")
        #expect(dialog.showsError)
        #expect(!dialog.confirmButton.isEnabled)
        dialog.setValue("ab")
        #expect(!dialog.showsError)
        #expect(dialog.confirmButton.isEnabled)
    }

    @Test func thePanelTakesItsAppearanceFromTheTheme() {
        let paper = DialogPanel(spec: DialogSpec(title: "T", message: nil, confirmTitle: "OK", isDestructive: false, kind: .confirm), theme: .folioPaper)
        let ink = DialogPanel(spec: DialogSpec(title: "T", message: nil, confirmTitle: "OK", isDestructive: false, kind: .confirm), theme: .folioInk)
        #expect(paper.appearance?.name == AppTheme.Appearance.light.nsAppearance.name)
        #expect(ink.appearance?.name == AppTheme.Appearance.dark.nsAppearance.name)
    }

    @Test func theSurfaceReappliesItsShadowWhenTheLayerUpdates() throws {
        let root = FloatingSurfaceView(radius: Chrome.Radius.popover)
        root.apply(theme: .folioPaper)
        #expect(root.surface.wantsUpdateLayer)
        let layer = try #require(root.surface.layer)
        layer.shadowOpacity = 0
        root.surface.updateLayer()
        #expect(layer.shadowOpacity > 0)
        #expect(layer.backgroundColor == AppTheme.folioPaper.colors.bgRaised.cgColor)
    }
}

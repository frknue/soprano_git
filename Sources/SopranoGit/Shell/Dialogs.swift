import AppKit

struct DialogOption: Equatable {
    var title: String
    var detail: String?
    /// Single-character shortcut shown as a keycap and accepted while the dialog is open.
    var key: String?
    var isDestructive: Bool

    init(title: String, detail: String? = nil, key: String? = nil, isDestructive: Bool = false) {
        self.title = title
        self.detail = detail
        self.key = key
        self.isDestructive = isDestructive
    }
}

/// Keyboard-first modal dialogs in the Mission Control chrome, attached to a
/// window as a sheet (centered panel when `window` is nil). Return confirms,
/// Esc cancels, j/k or arrows move between options, option keys pick directly.
@MainActor
enum Dialogs {
    /// Asks for one line of text. `validate` returns an error message to show
    /// inline (confirm stays disabled) or nil when the value is acceptable.
    static func prompt(
        title: String,
        message: String? = nil,
        placeholder: String? = nil,
        initialValue: String = "",
        confirmTitle: String = "OK",
        validate: ((String) -> String?)? = nil,
        in window: NSWindow?
    ) async -> String? {
        await prompt(
            title: title, message: message, placeholder: placeholder, initialValue: initialValue,
            confirmTitle: confirmTitle, isSecure: false, validate: validate, in: window
        )
    }

    /// `prompt` with an optional secure (password) field; used by askpass.
    static func prompt(
        title: String,
        message: String?,
        placeholder: String?,
        initialValue: String,
        confirmTitle: String,
        isSecure: Bool,
        validate: ((String) -> String?)?,
        in window: NSWindow?
    ) async -> String? {
        let spec = DialogSpec(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            isDestructive: false,
            kind: .prompt(placeholder: placeholder, initialValue: initialValue, isSecure: isSecure, validate: validate)
        )
        let result = await DialogPanel.present(spec, in: window)
        if case let .text(value) = result { return value }
        return nil
    }

    /// Shows a message with a single OK key (Return or Esc closes it).
    static func alert(title: String, message: String, in window: NSWindow?) async {
        var spec = DialogSpec(title: title, message: message, confirmTitle: "OK", isDestructive: false, kind: .confirm)
        spec.showsCancel = false
        _ = await DialogPanel.present(spec, in: window)
    }

    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = false,
        in window: NSWindow?
    ) async -> Bool {
        let spec = DialogSpec(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            isDestructive: isDestructive,
            kind: .confirm
        )
        return await DialogPanel.present(spec, in: window) == .confirmed
    }

    /// Returns the index of the chosen option, nil when cancelled.
    static func choose(
        title: String,
        message: String? = nil,
        options: [DialogOption],
        in window: NSWindow?
    ) async -> Int? {
        guard !options.isEmpty else { return nil }
        let spec = DialogSpec(
            title: title,
            message: message,
            confirmTitle: "Choose",
            isDestructive: false,
            kind: .choose(options)
        )
        if case let .option(index) = await DialogPanel.present(spec, in: window) { return index }
        return nil
    }

    /// The dialog currently on screen (tests and the snapshot harness drive it).
    static var current: DialogPanel? { DialogPanel.current }
}

struct DialogSpec {
    enum Kind {
        case prompt(placeholder: String?, initialValue: String, isSecure: Bool, validate: ((String) -> String?)?)
        case confirm
        case choose([DialogOption])
    }

    var title: String
    var message: String?
    var confirmTitle: String
    var isDestructive: Bool
    var kind: Kind
    /// False for alerts: one key, Esc behaves like Return.
    var showsCancel = true

    init(title: String, message: String?, confirmTitle: String, isDestructive: Bool, kind: Kind) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.kind = kind
    }
}

enum DialogResult: Equatable {
    case cancelled
    case confirmed
    case text(String)
    case option(Int)
}

/// The Mission Control dialog window: stripe + title, double rule, message,
/// an input / option list, inline error, and keyed buttons.
@MainActor
final class DialogPanel: NSPanel, NSTextFieldDelegate {
    static let width: CGFloat = 480
    private(set) static weak var current: DialogPanel?

    let spec: DialogSpec
    private let theme: AppTheme
    private var continuation: CheckedContinuation<DialogResult, Never>?

    private let root = DialogRootView()
    private let stripe = RetroStripeView(layout: .slanted)
    private let titleLabel = NSTextField(labelWithString: "")
    private let headerRule = RetroRuleView(axis: .horizontal, style: .double)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var inputContainer: NSView?
    private(set) var inputField: NSTextField?
    private let errorLabel = NSTextField(labelWithString: "")
    private var optionRows: [DialogOptionRow] = []
    private(set) var selectedOption = 0
    private let hintLabel = NSTextField(labelWithString: "")
    private var cancelButton: RetroButton!
    private var confirmButton: RetroButton!
    private var hasEdited = false

    static func present(_ spec: DialogSpec, in window: NSWindow?) async -> DialogResult {
        let panel = DialogPanel(spec: spec, theme: ThemeCenter.shared.theme)
        return await withCheckedContinuation { continuation in
            panel.continuation = continuation
            panel.show(in: window)
        }
    }

    init(spec: DialogSpec, theme: AppTheme) {
        self.spec = spec
        self.theme = theme
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        animationBehavior = .none
        root.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        contentView = root
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Layout

    private func build() {
        let colors = theme.colors
        let accent = spec.isDestructive ? colors.danger : colors.accent
        root.wantsLayer = true
        root.layer?.backgroundColor = colors.bgPanel.cgColor
        root.layer?.borderColor = colors.borderStrong.cgColor
        root.layer?.borderWidth = Retro.hairline

        stripe.colors = spec.isDestructive ? [colors.danger, colors.danger.withAlphaComponent(0.6), colors.accentStrong] : colors.stripe
        titleLabel.setRetroText(spec.title, color: accent, glow: true)
        titleLabel.lineBreakMode = .byTruncatingTail
        headerRule.color = colors.borderStrong

        var arranged: [NSView] = []
        if let message = spec.message, !message.isEmpty {
            messageLabel.stringValue = message
            messageLabel.font = RetroFont.body(12)
            messageLabel.textColor = colors.textPrimary
            messageLabel.preferredMaxLayoutWidth = Self.width - 40
            messageLabel.isSelectable = false
            arranged.append(messageLabel)
        }

        switch spec.kind {
        case let .prompt(placeholder, initialValue, isSecure, _):
            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = colors.bgRaised.cgColor
            container.layer?.borderColor = colors.borderStrong.cgColor
            container.layer?.borderWidth = Retro.hairline
            let prompt = NSTextField(labelWithString: "")
            prompt.setRetroText("❯", color: colors.accent)
            prompt.translatesAutoresizingMaskIntoConstraints = false
            let field: NSTextField = isSecure ? NSSecureTextField(string: initialValue) : NSTextField(string: initialValue)
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = RetroFont.body(13)
            field.textColor = colors.textPrimary
            field.delegate = self
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            if let placeholder {
                field.placeholderAttributedString = NSAttributedString(
                    string: placeholder,
                    attributes: [.foregroundColor: colors.textMuted, .font: RetroFont.body(13)]
                )
            }
            field.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(prompt)
            container.addSubview(field)
            container.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 34),
                prompt.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                prompt.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                field.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            inputContainer = container
            inputField = field
            arranged.append(container)
            errorLabel.font = RetroFont.body(11)
            errorLabel.textColor = colors.danger
            errorLabel.lineBreakMode = .byTruncatingTail
            errorLabel.isHidden = true
            arranged.append(errorLabel)
        case .confirm:
            break
        case let .choose(options):
            let list = NSStackView()
            list.orientation = .vertical
            list.spacing = 2
            list.alignment = .leading
            for (index, option) in options.enumerated() {
                let row = DialogOptionRow(option: option, theme: theme)
                row.onClick = { [weak self] in
                    self?.finish(.option(index))
                }
                row.onHover = { [weak self] in
                    self?.selectOption(index)
                }
                row.translatesAutoresizingMaskIntoConstraints = false
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                optionRows.append(row)
            }
            list.translatesAutoresizingMaskIntoConstraints = false
            arranged.append(list)
        }

        cancelButton = RetroButton(title: "Cancel", theme: theme, target: self, action: #selector(cancelClicked))
        cancelButton.refusesFirstResponder = true
        let confirmTheme = spec.isDestructive ? theme.withAccent(colors.danger) : theme
        confirmButton = RetroButton(title: spec.confirmTitle, theme: confirmTheme, kind: .prominent, target: self, action: #selector(confirmClicked))
        confirmButton.refusesFirstResponder = true

        var hints: [String] = []
        if case .choose = spec.kind {
            hints.append("j k  Move")
        } else {
            hints.append("↵  \(spec.confirmTitle)")
        }
        hints.append(spec.showsCancel ? "esc  Cancel" : "esc  Close")
        hintLabel.setRetroText(hints.joined(separator: "    "), color: colors.textMuted)

        cancelButton.isHidden = !spec.showsCancel
        let buttons = NSStackView(views: [cancelButton, confirmButton])
        buttons.spacing = 8
        let footer = NSStackView(views: [hintLabel, NSView(), buttons])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: arranged)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in arranged {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        for view in [stripe, titleLabel, headerRule, body, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let hasBody = !arranged.isEmpty
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stripe.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stripe.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 22),
            stripe.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            headerRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerRule.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: hasBody ? 16 : 0),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        if !hasBody {
            body.heightAnchor.constraint(equalToConstant: 0).isActive = true
        }
        selectOption(0)
        validateInput()
        root.layoutSubtreeIfNeeded()
        setContentSize(root.fittingSize)
    }

    // MARK: - Presentation

    /// The snapshot harness turns these off: an off-screen window must not
    /// get a sheet (AppKit drags the parent on screen) or activate the app.
    static var presentsAsSheet = true
    static var activatesApp = true

    private func show(in window: NSWindow?) {
        Self.current = self
        if let window, window.isVisible, Self.presentsAsSheet {
            window.beginSheet(self) { _ in }
        } else if let window, window.isVisible {
            // Sheet position (top center, under the tab bar) as a child panel.
            setFrameOrigin(NSPoint(
                x: window.frame.midX - frame.width / 2,
                y: window.frame.maxY - TabBarView.height - frame.height
            ))
            window.addChildWindow(self, ordered: .above)
            orderFrontRegardless()
        } else {
            let anchor = window?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            setFrameOrigin(NSPoint(x: anchor.midX - frame.width / 2, y: anchor.midY - frame.height / 2 + anchor.height * 0.12))
            level = .modalPanel
            makeKeyAndOrderFront(nil)
            if Self.activatesApp {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        if let inputField {
            makeFirstResponder(inputField)
            inputField.currentEditor()?.selectAll(nil)
        } else {
            makeFirstResponder(root)
        }
    }

    func finish(_ result: DialogResult) {
        guard let continuation else { return }
        self.continuation = nil
        if let sheetParent {
            sheetParent.endSheet(self)
        } else {
            parent?.removeChildWindow(self)
            orderOut(nil)
        }
        if Self.current === self { Self.current = nil }
        continuation.resume(returning: result)
    }

    // MARK: - Input

    var currentValue: String { inputField?.stringValue ?? "" }

    private var validationMessage: String? {
        guard case let .prompt(_, _, _, validate) = spec.kind else { return nil }
        if let validate { return validate(currentValue) }
        return nil
    }

    private func validateInput() {
        guard case .prompt = spec.kind else { return }
        let message = validationMessage
        confirmButton.isEnabled = message == nil
        let showsMessage = message != nil && (hasEdited || !currentValue.isEmpty)
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = !showsMessage
        inputContainer?.layer?.borderColor = (showsMessage ? theme.colors.danger : theme.colors.borderStrong).cgColor
    }

    func controlTextDidChange(_ obj: Notification) {
        hasEdited = true
        validateInput()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            confirm()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(.cancelled)
            return true
        default:
            return false
        }
    }

    /// Keys while no text field has focus (confirm / choose).
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 36, 76:
            confirm()
            return true
        case 53:
            finish(.cancelled)
            return true
        case 125:
            selectOption(selectedOption + 1)
            return true
        case 126:
            selectOption(selectedOption - 1)
            return true
        default:
            break
        }
        guard flags.isEmpty, let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if case let .choose(options) = spec.kind {
            if let index = options.firstIndex(where: { $0.key?.lowercased() == characters }) {
                finish(.option(index))
                return true
            }
            if characters == "j" {
                selectOption(selectedOption + 1)
                return true
            }
            if characters == "k" {
                selectOption(selectedOption - 1)
                return true
            }
        }
        if case .confirm = spec.kind, characters == "y" {
            confirm()
            return true
        }
        if case .confirm = spec.kind, characters == "n" {
            finish(.cancelled)
            return true
        }
        return false
    }

    func selectOption(_ index: Int) {
        guard !optionRows.isEmpty else { return }
        selectedOption = min(max(0, index), optionRows.count - 1)
        for (rowIndex, row) in optionRows.enumerated() {
            row.isHighlighted = rowIndex == selectedOption
        }
    }

    func confirm() {
        switch spec.kind {
        case .prompt:
            hasEdited = true
            validateInput()
            guard validationMessage == nil else { return }
            finish(.text(currentValue))
        case .confirm:
            finish(.confirmed)
        case .choose:
            finish(.option(selectedOption))
        }
    }

    /// Types into the prompt field (snapshot harness / tests).
    func setValue(_ value: String) {
        inputField?.stringValue = value
        hasEdited = true
        validateInput()
    }

    @objc private func cancelClicked() {
        finish(.cancelled)
    }

    @objc private func confirmClicked() {
        confirm()
    }

    override func cancelOperation(_ sender: Any?) {
        finish(.cancelled)
    }
}

/// Dialog content view: first responder while no field is focused.
private final class DialogRootView: NSView {
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// One choice: keycap, title, detail; highlighted = accent block (palette row look).
private final class DialogOptionRow: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var isHighlighted = false {
        didSet { applyColors() }
    }

    private let option: DialogOption
    private let theme: AppTheme
    private let keycap: KeycapView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(option: DialogOption, theme: AppTheme) {
        self.option = option
        self.theme = theme
        keycap = option.key.map { KeycapView(text: $0.uppercased(), theme: theme) }
        super.init(frame: .zero)
        wantsLayer = true
        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        if option.detail != nil {
            textStack.addArrangedSubview(detailLabel)
            detailLabel.lineBreakMode = .byTruncatingTail
        }
        var views: [NSView] = []
        if let keycap { views.append(keycap) }
        views.append(textStack)
        let row = NSStackView(views: views)
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func applyColors() {
        let colors = theme.colors
        let base = option.isDestructive ? colors.danger : colors.textPrimary
        let fill = option.isDestructive ? colors.danger : colors.accent
        layer?.backgroundColor = (isHighlighted ? fill : NSColor.clear).cgColor
        titleLabel.setRetroText(option.title, color: isHighlighted ? colors.bgPanel : base)
        detailLabel.stringValue = option.detail ?? ""
        detailLabel.font = RetroFont.body(11)
        detailLabel.textColor = isHighlighted ? colors.bgPanel : colors.textMuted
        keycap?.isOnAccent = isHighlighted
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

extension AppTheme {
    /// The same theme with another accent (destructive keys light up in `danger`).
    func withAccent(_ accent: NSColor) -> AppTheme {
        let c = colors
        return AppTheme(
            id: id,
            name: name,
            colors: ThemeColors(
                bgBase: c.bgBase, bgPanel: c.bgPanel, bgRaised: c.bgRaised, bgOverlay: c.bgOverlay,
                textPrimary: c.textPrimary, textMuted: c.textMuted,
                accent: accent, accentStrong: accent.blended(withFraction: 0.25, of: .black) ?? accent,
                borderSubtle: c.borderSubtle, borderStrong: c.borderStrong,
                success: c.success, danger: c.danger, blue: c.blue, cyan: c.cyan, yellow: c.yellow, gray: c.gray
            ),
            terminalColors: terminalColors
        )
    }
}

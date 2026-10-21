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

/// Keyboard-first modal dialogs, attached to a window as a sheet (centered
/// panel when `window` is nil). Return confirms, Esc cancels, j/k or arrows
/// move between options, option keys pick directly.
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

/// The dialog window (`.dialog`): a raised 480 pt surface with a 10 pt radius,
/// a `borderSubtle` edge and the e3 shadow; New York headline, muted SF Pro
/// message, an input or option list, an inline error, then key hints and the
/// Cancel / confirm buttons (ink, or danger fill when destructive).
@MainActor
final class DialogPanel: NSPanel, NSTextFieldDelegate {
    /// Width of the visible surface; the window adds the shadow margin.
    static let width: CGFloat = 480
    private(set) static weak var current: DialogPanel?

    let spec: DialogSpec
    private let theme: AppTheme
    private var continuation: CheckedContinuation<DialogResult, Never>?

    private let root = DialogRootView(radius: Chrome.Radius.popover)
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var inputSurface: ChromeFieldView?
    private(set) var inputField: NSTextField?
    private let errorLabel = NSTextField(labelWithString: "")
    private var optionRows: [DialogOptionRow] = []
    private(set) var selectedOption = 0
    private(set) var hintsView: HintsView!
    private(set) var cancelButton: ChromeButton!
    private(set) var confirmButton: ChromeButton!
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
            contentRect: NSRect(x: 0, y: 0, width: Self.width + FloatingSurfaceView.horizontalMargin, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        // The surface layer draws the e3 shadow inside the transparent margin.
        hasShadow = false
        appearance = theme.appearance.nsAppearance
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
        root.apply(theme: theme)
        let surface = root.surface

        titleLabel.setChromeText(spec.title, font: ChromeFont.headline, color: colors.textPrimary)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.preferredMaxLayoutWidth = Self.width - 40
        titleLabel.isSelectable = false

        var arranged: [NSView] = []
        if let message = spec.message, !message.isEmpty {
            messageLabel.attributedStringValue = Self.message(message, colors: colors)
            messageLabel.preferredMaxLayoutWidth = Self.width - 40
            messageLabel.isSelectable = false
            arranged.append(messageLabel)
        }

        switch spec.kind {
        case let .prompt(placeholder, initialValue, isSecure, _):
            let container = ChromeFieldView(theme: theme)
            let field: NSTextField = isSecure ? NSSecureTextField(string: initialValue) : NSTextField(string: initialValue)
            ChromeFieldView.styleEmbedded(field, colors: colors, font: ChromeFont.row)
            field.delegate = self
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            if let placeholder {
                field.placeholderAttributedString = ChromeText.attributed(placeholder, font: ChromeFont.row, color: colors.textMuted)
            }
            field.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(field)
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
                field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            inputSurface = container
            inputField = field
            arranged.append(container)
            errorLabel.font = ChromeFont.meta
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

        cancelButton = ChromeButton(title: "Cancel", theme: theme, kind: .standard, target: self, action: #selector(cancelClicked))
        cancelButton.refusesFirstResponder = true
        confirmButton = ChromeButton(
            title: spec.confirmTitle,
            theme: theme,
            kind: spec.isDestructive ? .danger : .ink,
            target: self,
            action: #selector(confirmClicked)
        )
        confirmButton.refusesFirstResponder = true

        var hints: [HintsView.Hint] = []
        if case .choose = spec.kind {
            hints.append(HintsView.Hint(caps: ["J", "K"], label: "Move"))
        } else {
            hints.append(HintsView.Hint(caps: ["↵"], label: spec.confirmTitle))
        }
        hints.append(HintsView.Hint(caps: ["esc"], label: spec.showsCancel ? "Cancel" : "Close"))
        hintsView = HintsView(hints: hints, theme: theme)
        hintsView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cancelButton.isHidden = !spec.showsCancel
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [hintsView, spacer, cancelButton, confirmButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: arranged)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in arranged {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        // The error sits close under its field.
        if let inputSurface { body.setCustomSpacing(6, after: inputSurface) }

        for view in [titleLabel, body, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }
        let hasBody = !arranged.isEmpty
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalToConstant: Self.width),
            titleLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: surface.topAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: hasBody ? 12 : 0),
            footer.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            // `.dialog` gap 12 plus the actions' 4 pt top margin.
            footer.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -16),
        ])
        if !hasBody {
            body.heightAnchor.constraint(equalToConstant: 0).isActive = true
        }
        selectOption(0)
        validateInput()
        root.layoutSubtreeIfNeeded()
        setContentSize(root.fittingSize)
    }

    /// `.dialog-body`: SF Pro 13 on a 19 pt line, muted.
    private static func message(_ text: String, colors: ThemeColors) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 19
        paragraph.maximumLineHeight = 19
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: ChromeFont.row,
            .foregroundColor: colors.textMuted,
            .paragraphStyle: paragraph,
        ])
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
                y: window.frame.maxY - TabBarView.height - frame.height + FloatingSurfaceView.margins.top
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
            ChromeFieldView.styleEditor(of: inputField, colors: theme.colors)
            inputSurface?.isFocused = true
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

    /// Whether the prompt shows its inline error and danger edge (tests).
    var showsError: Bool { !errorLabel.isHidden }

    private func validateInput() {
        guard case .prompt = spec.kind else { return }
        let message = validationMessage
        confirmButton.isEnabled = message == nil
        let showsMessage = message != nil && (hasEdited || !currentValue.isEmpty)
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = !showsMessage
        inputSurface?.isInvalid = showsMessage
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let inputField else { return }
        ChromeFieldView.styleEditor(of: inputField, colors: theme.colors)
        inputSurface?.isFocused = true
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

    /// The selection pill style of each option row (tests).
    var optionRowStyles: [ChromeSelectionPill.Style] { optionRows.map(\.pillStyle) }

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

/// The content view of a floating panel (dialog, shortcut sheet): a
/// transparent root that leaves room for the e3 shadow around `surface`, a
/// `bgRaised` rounded surface with a `borderSubtle` edge. Lay content out in
/// `surface`; the window is the surface plus `margins`.
class FloatingSurfaceView: NSView {
    /// Room for the e3 shadow (offset 12–14 down, blur 36–40).
    static let margins = NSEdgeInsets(top: 28, left: 40, bottom: 56, right: 40)
    static var horizontalMargin: CGFloat { margins.left + margins.right }
    static var verticalMargin: CGFloat { margins.top + margins.bottom }

    let surface = NSView()
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        surface.wantsLayer = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        let margins = Self.margins
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margins.left),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margins.right),
            surface.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margins.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        guard let layer = surface.layer else { return }
        let colors = theme.colors
        ChromeSurface.applyFloating(to: layer, colors: colors, radius: radius, shadow: colors.shadowE3)
        layer.backgroundColor = colors.bgRaised.cgColor
        layer.borderWidth = Chrome.hairline
        layer.borderColor = colors.borderSubtle.cgColor
    }
}

/// Dialog content view: first responder while no field is focused.
private final class DialogRootView: FloatingSurfaceView {
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// One choice: keycap, title, detail. The highlighted option is the focused
/// selection pill with its pencil tick; destructive titles are danger.
private final class DialogOptionRow: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
        }
    }

    var pillStyle: ChromeSelectionPill.Style { isHighlighted ? .selected : .none }

    private let option: DialogOption
    private let theme: AppTheme
    private let keycap: ChromeKeycapView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(option: DialogOption, theme: AppTheme) {
        self.option = option
        self.theme = theme
        keycap = option.key.map { ChromeKeycapView(legend: $0.uppercased(), theme: theme) }
        super.init(frame: .zero)
        let colors = theme.colors
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setChromeText(option.title, font: ChromeFont.row, color: option.isDestructive ? colors.danger : colors.textPrimary)
        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        if let detail = option.detail {
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.setChromeText(detail, font: ChromeFont.meta, color: colors.textMuted)
            textStack.addArrangedSubview(detailLabel)
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
            // Clears the pencil tick (4 pt in, 2 wide).
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        ChromeSelectionPill.draw(pillStyle, in: bounds, colors: theme.colors, inset: 0)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

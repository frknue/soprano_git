import AppKit
import SopranoGitCore

/// A RetroButton bound to a command id, with its keycap hint.
@MainActor
final class CommandButton: NSStackView {
    let commandID: String
    let button: RetroButton
    private let keycap: KeycapView
    private var theme: AppTheme
    var onPerform: ((String) -> Void)?

    init(title: String, commandID: String, theme: AppTheme, prominent: Bool = false) {
        self.commandID = commandID
        self.theme = theme
        button = RetroButton(title: title, theme: theme, kind: prominent ? .prominent : .standard, target: nil, action: nil)
        keycap = KeycapView(text: "", theme: theme)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 5
        alignment = .centerY
        button.refusesFirstResponder = true
        button.target = self
        button.action = #selector(clicked)
        addArrangedSubview(button)
        addArrangedSubview(keycap)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        button.apply(theme: theme)
        keycap.apply(theme: theme)
    }

    /// Updates the keycap text and the enabled state from the registry.
    func refresh(context: CommandContext? = nil) {
        let text = SettingsCenter.shared.keycapText(for: commandID)
        keycap.text = text ?? ""
        keycap.isHidden = text == nil
        let command = CommandRegistry.shared.command(commandID)
        if let command, let context {
            button.isEnabled = command.isEnabled(context)
        } else {
            button.isEnabled = command != nil && context != nil
        }
        button.toolTip = command.map { cmd in
            [cmd.title, SettingsCenter.shared.shortcutText(for: commandID)].compactMap { $0 }.joined(separator: "  ")
        } ?? "Not available"
    }

    @objc private func clicked() {
        onPerform?(commandID)
    }
}

/// 40 pt bar: repo name, branch chip (↑ahead ↓behind), PULL PUSH │ BRANCH │
/// STASH POP, and the palette key.
@MainActor
final class WorkspaceToolbarView: NSView {
    static let height: CGFloat = 40

    var onPerform: ((String) -> Void)?

    private let repoLabel = NSTextField(labelWithString: "")
    private let branchChip = NSView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let syncLabel = NSTextField(labelWithString: "")
    private(set) var commandButtons: [CommandButton] = []
    private let paletteButton = RetroIconButton(symbolName: "command", accessibilityLabel: "Command Palette", target: nil, action: nil)
    private let paletteKeycap: KeycapView
    private var separators: [NSView] = []
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        paletteKeycap = KeycapView(text: "", theme: theme)
        super.init(frame: .zero)
        wantsLayer = true

        repoLabel.lineBreakMode = .byTruncatingTail
        repoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchChip.wantsLayer = true
        let chipStack = NSStackView(views: [branchLabel, syncLabel])
        chipStack.spacing = 8
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        branchChip.addSubview(chipStack)
        NSLayoutConstraint.activate([
            chipStack.leadingAnchor.constraint(equalTo: branchChip.leadingAnchor, constant: 8),
            chipStack.trailingAnchor.constraint(equalTo: branchChip.trailingAnchor, constant: -8),
            chipStack.centerYAnchor.constraint(equalTo: branchChip.centerYAnchor),
            branchChip.heightAnchor.constraint(equalToConstant: Retro.controlHeight),
        ])

        let groups: [[(String, String, Bool)]] = [
            [("Pull", "repo.pull", false), ("Push", "repo.push", false)],
            [("Branch", "branch.create", false)],
            [("Stash", "stash.save", false), ("Pop", "stash.pop", false)],
        ]
        var arranged: [NSView] = [repoLabel, branchChip]
        for group in groups {
            let separator = makeSeparator()
            arranged.append(separator)
            for (title, id, prominent) in group {
                let button = CommandButton(title: title, commandID: id, theme: theme, prominent: prominent)
                button.onPerform = { [weak self] id in self?.onPerform?(id) }
                commandButtons.append(button)
                arranged.append(button)
            }
        }
        let left = NSStackView(views: arranged)
        left.spacing = 12
        left.alignment = .centerY
        left.setCustomSpacing(10, after: repoLabel)
        for separator in separators {
            left.setCustomSpacing(12, after: separator)
        }

        paletteButton.target = self
        paletteButton.action = #selector(paletteClicked)
        paletteButton.refusesFirstResponder = true
        let right = NSStackView(views: [paletteButton, paletteKeycap])
        right.spacing = 4
        right.alignment = .centerY

        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeSeparator() -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: Retro.hairline).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
        separators.append(separator)
        return separator
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        branchChip.layer?.backgroundColor = colors.bgRaised.cgColor
        branchChip.layer?.borderColor = colors.borderStrong.cgColor
        branchChip.layer?.borderWidth = Retro.hairline
        separators.forEach { $0.layer?.backgroundColor = colors.borderStrong.cgColor }
        commandButtons.forEach { $0.apply(theme: theme) }
        paletteButton.setTints(normal: colors.textMuted, hover: colors.accent)
        paletteKeycap.apply(theme: theme)
    }

    func update(repoName: String, refs: RefSnapshot, context: CommandContext?) {
        let colors = theme.colors
        repoLabel.setRetroText(repoName, color: colors.textPrimary)
        let branchText: String
        var ahead = 0
        var behind = 0
        var hasUpstream = false
        switch refs.head {
        case let .branch(name):
            branchText = "⎇ " + name
            if let current = refs.currentBranch {
                ahead = current.ahead
                behind = current.behind
                hasUpstream = current.upstream != nil
            }
        case let .detached(id):
            branchText = "Detached " + String(id.prefix(7))
        case let .unborn(name):
            branchText = "⎇ " + name + " (no commits)"
        }
        branchLabel.setRetroText(branchText, color: colors.accent)
        if hasUpstream {
            syncLabel.isHidden = false
            let aheadColor = ahead > 0 ? colors.textPrimary : colors.textMuted
            let text = NSMutableAttributedString(attributedString: RetroText.display("↑\(ahead)", color: aheadColor))
            text.append(NSAttributedString(string: " "))
            text.append(RetroText.display("↓\(behind)", color: behind > 0 ? colors.yellow : colors.textMuted))
            syncLabel.attributedStringValue = text
        } else {
            syncLabel.isHidden = true
        }
        commandButtons.forEach { $0.refresh(context: context) }
        let paletteText = SettingsCenter.shared.keycapText(for: "palette.open")
        paletteKeycap.text = paletteText ?? ""
        paletteKeycap.isHidden = paletteText == nil
    }

    @objc private func paletteClicked() {
        onPerform?("palette.open")
    }
}

/// Banner over the center while git has paused an operation: lamp,
/// "MERGE IN PROGRESS · 2 CONFLICTS", CONTINUE / ABORT / SKIP keys.
@MainActor
final class OperationBannerView: NSView {
    static let height: CGFloat = 36

    var onPerform: ((String) -> Void)?

    private let lamp = NSView()
    private let label = NSTextField(labelWithString: "")
    private let continueButton: CommandButton
    private let abortButton: CommandButton
    private let skipButton: CommandButton
    private let bottomRule = RetroRuleView(axis: .horizontal, style: .single)
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        continueButton = CommandButton(title: "Continue", commandID: "operation.continue", theme: theme, prominent: true)
        abortButton = CommandButton(title: "Abort", commandID: "operation.abort", theme: theme)
        skipButton = CommandButton(title: "Skip", commandID: "operation.skip", theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        lamp.wantsLayer = true
        lamp.layer?.cornerRadius = 5
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [continueButton, abortButton, skipButton] {
            button.onPerform = { [weak self] id in self?.onPerform?(id) }
        }
        let buttons = NSStackView(views: [continueButton, abortButton, skipButton])
        buttons.spacing = 12
        for view in [lamp, label, buttons, bottomRule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            lamp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            lamp.centerYAnchor.constraint(equalTo: centerYAnchor),
            lamp.widthAnchor.constraint(equalToConstant: 10),
            lamp.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: lamp.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.bgRaised.cgColor
        bottomRule.color = theme.colors.borderSubtle
        [continueButton, abortButton, skipButton].forEach { $0.apply(theme: theme) }
    }

    /// Text for an operation: "MERGE IN PROGRESS · 2 CONFLICTS".
    static func text(for operation: OperationInProgress, conflicts: Int) -> String {
        var parts = ["\(operation.title) in progress"]
        if case let .rebase(_, _, step?, total?) = operation {
            parts.append("step \(step)/\(total)")
        }
        if conflicts > 0 {
            parts.append(conflicts == 1 ? "1 conflict" : "\(conflicts) conflicts")
        } else {
            parts.append("ready to continue")
        }
        return parts.joined(separator: " · ")
    }

    func update(operation: OperationInProgress, conflicts: Int, context: CommandContext?) {
        let colors = theme.colors
        RetroLamp.light(lamp, color: conflicts > 0 ? colors.danger : colors.yellow)
        label.setRetroText(Self.text(for: operation, conflicts: conflicts), color: conflicts > 0 ? colors.danger : colors.yellow, glow: true)
        skipButton.isHidden = !operation.canSkip
        [continueButton, abortButton, skipButton].forEach { $0.refresh(context: context) }
    }
}

/// 24 pt status bar: mode chip (NORMAL / PREFIX), activity lamp + latest
/// entry with progress, current branch, commit count.
@MainActor
final class WorkspaceStatusBarView: NSView {
    static let height: CGFloat = 24

    private let topRule = RetroRuleView(axis: .horizontal, style: .single)
    private let modeChip = NSView()
    private let modeLabel = NSTextField(labelWithString: "")
    private let activityLamp = NSView()
    private let activityLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var mode: KeyboardRouter.State = .normal
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        modeChip.wantsLayer = true
        activityLamp.wantsLayer = true
        activityLamp.layer?.cornerRadius = 3.5
        activityLabel.lineBreakMode = .byTruncatingTail
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeChip.addSubview(modeLabel)
        for view in [topRule, modeChip, activityLamp, activityLabel, branchLabel, countLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: topAnchor),
            modeChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            modeChip.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            modeChip.heightAnchor.constraint(equalToConstant: 16),
            modeLabel.leadingAnchor.constraint(equalTo: modeChip.leadingAnchor, constant: 6),
            modeLabel.trailingAnchor.constraint(equalTo: modeChip.trailingAnchor, constant: -6),
            modeLabel.centerYAnchor.constraint(equalTo: modeChip.centerYAnchor),
            activityLamp.leadingAnchor.constraint(equalTo: modeChip.trailingAnchor, constant: 14),
            activityLamp.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            activityLamp.widthAnchor.constraint(equalToConstant: 7),
            activityLamp.heightAnchor.constraint(equalToConstant: 7),
            activityLabel.leadingAnchor.constraint(equalTo: activityLamp.trailingAnchor, constant: 8),
            activityLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            activityLabel.trailingAnchor.constraint(lessThanOrEqualTo: branchLabel.leadingAnchor, constant: -16),
            branchLabel.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -16),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        topRule.color = theme.colors.borderStrong
        applyMode()
    }

    func setMode(_ mode: KeyboardRouter.State) {
        self.mode = mode
        applyMode()
    }

    private func applyMode() {
        let colors = theme.colors
        switch mode {
        case .normal:
            modeLabel.setRetroText("Normal", color: colors.textMuted)
            modeChip.layer?.backgroundColor = NSColor.clear.cgColor
            modeChip.layer?.borderWidth = Retro.hairline
            modeChip.layer?.borderColor = colors.borderStrong.cgColor
        case .prefix:
            modeLabel.setRetroText("Prefix", color: colors.bgPanel)
            modeChip.layer?.backgroundColor = colors.accent.cgColor
            modeChip.layer?.borderWidth = 0
        }
    }

    func update(activity: ActivityLog.Entry?, refs: RefSnapshot, commitCount: Int, hasMore: Bool, loading: Bool, loadError: String?) {
        let colors = theme.colors
        let lampColor: NSColor
        let lit: Bool
        let text: String
        if let loadError {
            lampColor = colors.danger
            lit = true
            text = loadError
        } else if let entry = activity {
            switch entry.outcome {
            case .running:
                lampColor = colors.cyan
                lit = true
                text = entry.title + "…" + (entry.progress.map { "  " + $0 } ?? "")
            case .succeeded:
                lampColor = colors.success
                lit = false
                text = entry.title + " — done"
            case let .failed(message):
                lampColor = colors.danger
                lit = true
                text = entry.title + " failed: " + (message.split(separator: "\n").first.map(String.init) ?? "")
            }
        } else if loading {
            lampColor = colors.cyan
            lit = true
            text = "Loading…"
        } else {
            lampColor = colors.success
            lit = false
            text = "Ready"
        }
        RetroLamp.light(activityLamp, color: lampColor, lit: lit)
        activityLabel.stringValue = text
        activityLabel.font = RetroFont.body(11)
        activityLabel.textColor = lit && lampColor == colors.danger ? colors.danger : colors.textMuted

        switch refs.head {
        case let .branch(name), let .unborn(name):
            branchLabel.setRetroText("⎇ " + name, color: colors.textMuted)
        case let .detached(id):
            branchLabel.setRetroText("Detached " + String(id.prefix(7)), color: colors.textMuted)
        }
        let count = commitCount == 1 ? "1 commit" : "\(commitCount)\(hasMore ? "+" : "") commits"
        countLabel.setRetroText(count, color: colors.textMuted)
    }
}

/// Error toast for `.failed` events: danger lamp, title, git's message.
/// Esc (`toast.dismiss`) or a click dismisses it; it hides itself after a while.
@MainActor
final class ErrorToastView: NSView {
    static let width: CGFloat = 440
    static let autoHideAfter: Duration = .seconds(12)

    var onDismiss: (() -> Void)?

    private let lamp = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let keycap: KeycapView
    private var hideTask: Task<Void, Never>?

    init(theme: AppTheme) {
        keycap = KeycapView(text: "Esc", theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        lamp.wantsLayer = true
        lamp.layer?.cornerRadius = 4
        messageLabel.maximumNumberOfLines = 8
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.isSelectable = false
        messageLabel.preferredMaxLayoutWidth = Self.width - 46
        titleLabel.lineBreakMode = .byTruncatingTail
        for view in [lamp, titleLabel, messageLabel, keycap] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            lamp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            lamp.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            lamp.widthAnchor.constraint(equalToConstant: 8),
            lamp.heightAnchor.constraint(equalToConstant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: lamp.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: keycap.leadingAnchor, constant: -8),
            keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            keycap.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        let colors = theme.colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        layer?.borderColor = colors.danger.cgColor
        layer?.borderWidth = Retro.hairline
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        RetroLamp.light(lamp, color: colors.danger)
        messageLabel.font = RetroFont.body(11)
        messageLabel.textColor = colors.textPrimary
        keycap.apply(theme: theme)
        titleLabel.setRetroText(titleLabel.stringValue, color: colors.danger, glow: true)
    }

    func show(title: String, message: String, theme: AppTheme) {
        titleLabel.setRetroText(title + " failed", color: theme.colors.danger, glow: true)
        messageLabel.stringValue = message
        isHidden = false
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoHideAfter)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        guard !isHidden else { return }
        isHidden = true
        onDismiss?()
    }

    override func mouseDown(with event: NSEvent) {
        dismiss()
    }
}

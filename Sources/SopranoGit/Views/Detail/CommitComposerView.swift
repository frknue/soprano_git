import AppKit
import SopranoGitCore

/// The commit composer pinned under the working-copy file list: summary with
/// a character counter, description, AMEND, COMMIT and STAGE ALL & COMMIT.
final class CommitComposerView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    static let inset: CGFloat = 12
    static let minimumDescriptionLines = 4
    static let maximumDescriptionLines = 6

    var onCommit: (() -> Void)?
    var onStageAllAndCommit: (() -> Void)?
    var onAmendToggled: ((Bool) -> Void)?
    var onTextChange: (() -> Void)?

    private var theme: AppTheme
    private let topRule = NSView()
    private let heading: RetroHeadingView
    let amendCheckbox: RetroCheckbox
    private let summaryBox = NSView()
    let summaryField = NSTextField()
    private let counterLabel = NSTextField(labelWithString: "")
    private let descriptionBox = NSView()
    private let descriptionScroll = NSScrollView()
    let descriptionView = PlaceholderTextView()
    private var descriptionHeight: NSLayoutConstraint!
    private var hintCollapsed: NSLayoutConstraint!
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    let commitButton: KeyHintButton
    let stageAllButton: KeyHintButton
    private(set) var state = ComposerState(stagedCount: 0, changeCount: 0, conflictCount: 0, isAmending: false, hasSummary: false, isBusy: false)

    init(theme: AppTheme) {
        self.theme = theme
        heading = RetroHeadingView(title: "Commit message", theme: theme)
        amendCheckbox = RetroCheckbox(title: "Amend", theme: theme, target: nil, action: nil)
        commitButton = KeyHintButton(title: "Commit", hint: nil, theme: theme, kind: .prominent, height: 28)
        stageAllButton = KeyHintButton(title: "Stage all & commit", hint: nil, theme: theme, kind: .standard, height: 24)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Values

    var summary: String {
        get { summaryField.stringValue }
        set {
            summaryField.stringValue = newValue
            textChanged()
        }
    }

    var descriptionText: String {
        get { descriptionView.string }
        set {
            descriptionView.string = newValue
            textChanged()
        }
    }

    var message: String { CommitMessage.join(summary: summary, description: descriptionText) }

    var hasSummary: Bool { !summary.trimmingCharacters(in: .whitespaces).isEmpty }

    var isAmending: Bool {
        get { amendCheckbox.isOn }
        set { amendCheckbox.isOn = newValue }
    }

    var hintText: String? { hintLabel.isHidden ? nil : hintLabel.stringValue }
    var counterText: String { counterLabel.stringValue }

    func setMessage(_ message: String) {
        let parts = CommitMessage.split(message)
        summaryField.stringValue = parts.summary
        descriptionView.string = parts.description
        textChanged()
    }

    func clear() {
        summaryField.stringValue = ""
        descriptionView.string = ""
        amendCheckbox.isOn = false
        textChanged()
    }

    func focusSummary() {
        window?.makeFirstResponder(summaryField)
        summaryField.currentEditor()?.selectedRange = NSRange(location: (summaryField.stringValue as NSString).length, length: 0)
    }

    func update(state: ComposerState) {
        self.state = state
        commitButton.title = state.commitTitle
        commitButton.isEnabled = state.canCommit
        stageAllButton.isEnabled = state.canStageAllAndCommit
        commitButton.hint = PanelText.keycap("wip.commit")
        stageAllButton.hint = PanelText.keycap("wip.stageAllAndCommit")
        if let hint = state.hint {
            hintLabel.attributedStringValue = NSAttributedString(
                string: hint,
                attributes: [
                    .font: RetroFont.body(11),
                    .foregroundColor: state.conflictCount > 0 ? theme.colors.danger : theme.colors.textMuted,
                ]
            )
            hintLabel.isHidden = false
            hintCollapsed.isActive = false
        } else {
            hintLabel.isHidden = true
            hintCollapsed.isActive = true
        }
    }

    // MARK: - Building

    private func build() {
        topRule.wantsLayer = true
        summaryBox.wantsLayer = true
        descriptionBox.wantsLayer = true

        summaryField.isBordered = false
        summaryField.isBezeled = false
        summaryField.drawsBackground = false
        summaryField.focusRingType = .none
        summaryField.font = RetroFont.body(12)
        summaryField.usesSingleLineMode = true
        summaryField.lineBreakMode = .byTruncatingTail
        summaryField.cell?.isScrollable = true
        summaryField.cell?.wraps = false
        summaryField.delegate = self
        summaryField.setAccessibilityLabel("Commit summary")
        counterLabel.alignment = .right
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        descriptionView.isRichText = false
        descriptionView.allowsUndo = true
        descriptionView.font = RetroFont.body(12)
        descriptionView.drawsBackground = false
        descriptionView.textContainerInset = NSSize(width: 4, height: 5)
        descriptionView.isVerticallyResizable = true
        descriptionView.isHorizontallyResizable = false
        descriptionView.autoresizingMask = [.width]
        descriptionView.textContainer?.widthTracksTextView = true
        descriptionView.isAutomaticQuoteSubstitutionEnabled = false
        descriptionView.isAutomaticDashSubstitutionEnabled = false
        descriptionView.isAutomaticTextReplacementEnabled = false
        descriptionView.isAutomaticSpellingCorrectionEnabled = false
        descriptionView.delegate = self
        descriptionView.placeholder = "Description"
        descriptionView.setAccessibilityLabel("Commit description")
        descriptionScroll.documentView = descriptionView
        descriptionScroll.drawsBackground = false
        descriptionScroll.hasVerticalScroller = true
        descriptionScroll.autohidesScrollers = true
        descriptionScroll.scrollerStyle = .overlay
        descriptionScroll.borderType = .noBorder

        amendCheckbox.target = self
        amendCheckbox.action = #selector(amendToggled)
        amendCheckbox.toolTip = "Amend the last commit"
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        stageAllButton.target = self
        stageAllButton.action = #selector(stageAllClicked)

        for view in [topRule, heading, amendCheckbox, summaryBox, descriptionBox, hintLabel, commitButton, stageAllButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [summaryField, counterLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            summaryBox.addSubview(view)
        }
        descriptionScroll.translatesAutoresizingMaskIntoConstraints = false
        descriptionBox.addSubview(descriptionScroll)
        hintLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let inset = Self.inset
        descriptionHeight = descriptionBox.heightAnchor.constraint(equalToConstant: descriptionHeight(lines: Self.minimumDescriptionLines))
        NSLayoutConstraint.activate([
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: topAnchor),
            topRule.heightAnchor.constraint(equalToConstant: Retro.hairline),

            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            heading.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 10),
            amendCheckbox.leadingAnchor.constraint(equalTo: heading.trailingAnchor, constant: 10),
            amendCheckbox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            amendCheckbox.centerYAnchor.constraint(equalTo: heading.centerYAnchor),

            summaryBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            summaryBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            summaryBox.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            summaryBox.heightAnchor.constraint(equalToConstant: 26),
            summaryField.leadingAnchor.constraint(equalTo: summaryBox.leadingAnchor, constant: 8),
            summaryField.centerYAnchor.constraint(equalTo: summaryBox.centerYAnchor),
            counterLabel.leadingAnchor.constraint(equalTo: summaryField.trailingAnchor, constant: 6),
            counterLabel.trailingAnchor.constraint(equalTo: summaryBox.trailingAnchor, constant: -8),
            counterLabel.centerYAnchor.constraint(equalTo: summaryBox.centerYAnchor),

            descriptionBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            descriptionBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            descriptionBox.topAnchor.constraint(equalTo: summaryBox.bottomAnchor, constant: 6),
            descriptionHeight,
            descriptionScroll.leadingAnchor.constraint(equalTo: descriptionBox.leadingAnchor, constant: 1),
            descriptionScroll.trailingAnchor.constraint(equalTo: descriptionBox.trailingAnchor, constant: -1),
            descriptionScroll.topAnchor.constraint(equalTo: descriptionBox.topAnchor, constant: 1),
            descriptionScroll.bottomAnchor.constraint(equalTo: descriptionBox.bottomAnchor, constant: -1),

            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            hintLabel.topAnchor.constraint(equalTo: descriptionBox.bottomAnchor, constant: 6),

            commitButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            commitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stageAllButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stageAllButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stageAllButton.topAnchor.constraint(equalTo: commitButton.bottomAnchor, constant: 6),
            stageAllButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        // The hint collapses to nothing while hidden.
        hintCollapsed = hintLabel.heightAnchor.constraint(equalToConstant: 0)
        hintCollapsed.isActive = true
        hintLabel.isHidden = true
        commitButton.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 8).isActive = true
        commitButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stageAllButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commitButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stageAllButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        summaryField.nextKeyView = descriptionView
        updateCounter()
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        topRule.layer?.backgroundColor = colors.borderSubtle.cgColor
        heading.apply(theme: theme)
        amendCheckbox.apply(theme: theme)
        commitButton.apply(theme: theme)
        stageAllButton.apply(theme: theme)
        for box in [summaryBox, descriptionBox] {
            box.layer?.backgroundColor = colors.bgRaised.cgColor
            box.layer?.borderColor = colors.borderStrong.cgColor
            box.layer?.borderWidth = 1
            box.layer?.cornerRadius = 0
        }
        summaryField.textColor = colors.textPrimary
        summaryField.placeholderAttributedString = NSAttributedString(
            string: "Summary",
            attributes: [.font: RetroFont.body(12), .foregroundColor: colors.textMuted]
        )
        descriptionView.textColor = colors.textPrimary
        descriptionView.insertionPointColor = colors.accent
        descriptionView.placeholderColor = colors.textMuted
        descriptionView.selectedTextAttributes = [.backgroundColor: colors.bgSelectedStrong]
        (summaryField.currentEditor() as? NSTextView)?.insertionPointColor = colors.accent
        updateCounter()
        update(state: state)
    }

    private func descriptionHeight(lines: Int) -> CGFloat {
        let font = RetroFont.body(12)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        return CGFloat(lines) * lineHeight + descriptionView.textContainerInset.height * 2 + 2
    }

    private func updateDescriptionHeight() {
        guard let layoutManager = descriptionView.layoutManager, let container = descriptionView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let lineHeight = ceil(layoutManager.defaultLineHeight(for: RetroFont.body(12)))
        let lines = Int(ceil(layoutManager.usedRect(for: container).height / max(lineHeight, 1)))
        let clamped = min(max(lines, Self.minimumDescriptionLines), Self.maximumDescriptionLines)
        let height = descriptionHeight(lines: clamped)
        if descriptionHeight.constant != height { descriptionHeight.constant = height }
    }

    private func updateCounter() {
        let count = summaryField.stringValue.count
        let colors = theme.colors
        let color: NSColor = count > CommitMessage.summaryLimit ? colors.danger : colors.textMuted
        counterLabel.attributedStringValue = NSAttributedString(
            string: count > CommitMessage.summaryLimit ? "\(count)/\(CommitMessage.summaryLimit)" : "\(count)",
            attributes: [.font: RetroFont.body(11), .foregroundColor: color]
        )
        counterLabel.toolTip = count > CommitMessage.summaryLimit ? "Summaries read best under \(CommitMessage.summaryLimit) characters" : nil
    }

    /// The summary is over the length git tools show in one line.
    var isSummaryTooLong: Bool { summaryField.stringValue.count > CommitMessage.summaryLimit }

    private func textChanged() {
        updateCounter()
        updateDescriptionHeight()
        descriptionView.needsDisplay = true
        onTextChange?()
    }

    // MARK: - Delegates and actions

    func controlTextDidChange(_ obj: Notification) {
        textChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(descriptionView)
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        textChanged()
    }

    @objc private func amendToggled() {
        onAmendToggled?(amendCheckbox.isOn)
    }

    @objc private func commitClicked() {
        onCommit?()
    }

    @objc private func stageAllClicked() {
        onStageAllAndCommit?()
    }
}

/// A plain-text view that draws a muted placeholder while empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    var placeholderColor: NSColor = .placeholderTextColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
        NSAttributedString(
            string: placeholder,
            attributes: [.font: font ?? RetroFont.body(12), .foregroundColor: placeholderColor]
        ).draw(at: origin)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}

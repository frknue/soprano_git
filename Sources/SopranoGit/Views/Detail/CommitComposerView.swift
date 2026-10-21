import AppKit
import SopranoGitCore

/// The commit composer pinned under the working-copy file list: a `COMMIT
/// MESSAGE` eyebrow with the Amend checkbox, the summary with a character
/// counter and the description in raised fields, then the ink Commit button
/// and the standard Stage all & commit button.
final class CommitComposerView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    static let inset: CGFloat = 12
    static let minimumDescriptionLines = 4
    static let maximumDescriptionLines = 6

    var onCommit: (() -> Void)?
    var onStageAllAndCommit: (() -> Void)?
    var onAmendToggled: ((Bool) -> Void)?
    var onTextChange: (() -> Void)?

    private var theme: AppTheme
    private let topRule = ChromeRuleView(axis: .horizontal)
    private let heading: ChromeEyebrowView
    let amendCheckbox: ChromeCheckbox
    let amendLabel = NSTextField(labelWithString: "")
    let summaryBox: ChromeFieldView
    let summaryField = FocusReportingTextField()
    private let counterLabel = NSTextField(labelWithString: "")
    private let descriptionBox: ChromeFieldView
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
        heading = ChromeEyebrowView(title: "Commit message", theme: theme)
        amendCheckbox = ChromeCheckbox(theme: theme)
        summaryBox = ChromeFieldView(theme: theme)
        descriptionBox = ChromeFieldView(theme: theme)
        commitButton = KeyHintButton(title: "Commit", hint: nil, theme: theme, kind: .ink, height: Chrome.controlHeight)
        stageAllButton = KeyHintButton(title: "Stage all & commit", hint: nil, theme: theme, kind: .standard, height: Chrome.controlHeight)
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
        get { amendCheckbox.isChecked }
        set { amendCheckbox.isChecked = newValue }
    }

    /// Amend needs a HEAD commit; the label dims with the checkbox.
    var isAmendEnabled: Bool {
        get { amendCheckbox.isEnabled }
        set {
            amendCheckbox.isEnabled = newValue
            amendLabel.alphaValue = newValue ? 1 : 0.45
        }
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
        amendCheckbox.isChecked = false
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
        commitButton.hint = SettingsCenter.shared.keycaps(for: "wip.commit")
        stageAllButton.hint = SettingsCenter.shared.keycaps(for: "wip.stageAllAndCommit")
        if let hint = state.hint {
            hintLabel.attributedStringValue = NSAttributedString(
                string: hint,
                attributes: [
                    .font: ChromeFont.meta,
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
        summaryField.usesSingleLineMode = true
        summaryField.lineBreakMode = .byTruncatingTail
        summaryField.cell?.isScrollable = true
        summaryField.cell?.wraps = false
        summaryField.delegate = self
        summaryField.onFocusChange = { [weak self] focused in
            guard let self else { return }
            summaryBox.isFocused = focused
            if focused { ChromeFieldView.styleEditor(of: summaryField, colors: theme.colors) }
        }
        summaryField.setAccessibilityLabel("Commit summary")
        counterLabel.alignment = .right
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        descriptionView.isRichText = false
        descriptionView.allowsUndo = true
        descriptionView.font = ChromeFont.label
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
        descriptionView.onFocusChange = { [weak self] focused in self?.descriptionBox.isFocused = focused }
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
        amendCheckbox.setAccessibilityLabel("Amend")
        amendLabel.toolTip = amendCheckbox.toolTip
        amendLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(amendLabelClicked)))
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        stageAllButton.target = self
        stageAllButton.action = #selector(stageAllClicked)

        for view in [topRule, heading, amendCheckbox, amendLabel, summaryBox, descriptionBox, hintLabel, commitButton, stageAllButton] as [NSView] {
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

            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            heading.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 10),
            amendCheckbox.leadingAnchor.constraint(greaterThanOrEqualTo: heading.trailingAnchor, constant: 10),
            amendCheckbox.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            amendLabel.leadingAnchor.constraint(equalTo: amendCheckbox.trailingAnchor, constant: 6),
            amendLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            amendLabel.centerYAnchor.constraint(equalTo: amendCheckbox.centerYAnchor),

            summaryBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            summaryBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            summaryBox.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            summaryBox.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
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
        topRule.color = colors.borderSubtle
        heading.apply(theme: theme)
        amendCheckbox.apply(theme: theme)
        amendLabel.setChromeText("Amend", color: colors.textPrimary)
        commitButton.apply(theme: theme)
        stageAllButton.apply(theme: theme)
        summaryBox.apply(theme: theme)
        descriptionBox.apply(theme: theme)
        ChromeFieldView.styleEmbedded(summaryField, colors: colors)
        summaryField.placeholderAttributedString = NSAttributedString(
            string: "Summary",
            attributes: [.font: ChromeFont.label, .foregroundColor: colors.textMuted]
        )
        descriptionView.textColor = colors.textPrimary
        descriptionView.insertionPointColor = colors.caret
        descriptionView.placeholderColor = colors.textMuted
        descriptionView.selectedTextAttributes = [.backgroundColor: colors.textSelection]
        ChromeFieldView.styleEditor(of: summaryField, colors: colors)
        updateCounter()
        update(state: state)
    }

    private func descriptionHeight(lines: Int) -> CGFloat {
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: ChromeFont.label))
        return CGFloat(lines) * lineHeight + descriptionView.textContainerInset.height * 2 + 2
    }

    private func updateDescriptionHeight() {
        guard let layoutManager = descriptionView.layoutManager, let container = descriptionView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let lineHeight = ceil(layoutManager.defaultLineHeight(for: ChromeFont.label))
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
            attributes: [.font: ChromeFont.count, .foregroundColor: color]
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
        onAmendToggled?(amendCheckbox.isChecked)
    }

    /// The label toggles the checkbox like a native checkbox title.
    @objc private func amendLabelClicked() {
        guard amendCheckbox.isEnabled else { return }
        amendCheckbox.isChecked.toggle()
        amendToggled()
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

    /// Called with true on becoming first responder, false on resigning.
    var onFocusChange: ((Bool) -> Void)?

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
            attributes: [.font: font ?? ChromeFont.label, .foregroundColor: placeholderColor]
        ).draw(at: origin)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

import AppKit
import SopranoGitCore

/// Top of the commit panel in commit and stash mode: the subject as a New
/// York headline, body, ref pills, then a meta grid of author and dates,
/// committer (when someone else) and parents as SHA links. A hairline closes it.
final class CommitInfoView: NSView {
    static let maximumBodyHeight: CGFloat = 132
    /// Width of the sentence-case meta labels (`Author`, `Date`, `Parent`).
    static let labelWidth: CGFloat = 56
    static let inset: CGFloat = 16
    /// Height of one meta row.
    static let metaRowHeight: CGFloat = 18

    /// A parent or base commit link was clicked.
    var onSelectCommit: ((String) -> Void)?

    private var theme: AppTheme
    private let stack = NSStackView()
    private let summaryField = NSTextField(wrappingLabelWithString: "")
    private let bodyScroll = NSScrollView()
    private let bodyView = NSTextView()
    private var bodyHeight: NSLayoutConstraint!
    private let metaStack = NSStackView()
    private let refsFlow = FlowLayoutView()
    private let bottomRule = ChromeRuleView(axis: .horizontal, color: .clear)
    private var content: Content?

    private enum Content {
        case commit(CommitDetail, refs: [RefPillView.Ref], lane: Int)
        case stash(Stash)
    }

    override var isFlipped: Bool { true }

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        summaryField.isSelectable = true
        summaryField.translatesAutoresizingMaskIntoConstraints = false
        summaryField.setContentCompressionResistancePriority(.required, for: .vertical)

        bodyView.isEditable = false
        bodyView.isSelectable = true
        bodyView.drawsBackground = false
        bodyView.textContainerInset = .zero
        bodyView.textContainer?.lineFragmentPadding = 0
        bodyView.textContainer?.widthTracksTextView = true
        bodyView.isVerticallyResizable = true
        bodyView.isHorizontallyResizable = false
        bodyView.autoresizingMask = [.width]
        bodyScroll.documentView = bodyView
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.borderType = .noBorder
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyHeight = bodyScroll.heightAnchor.constraint(equalToConstant: 0)
        bodyHeight.isActive = true

        metaStack.orientation = .vertical
        metaStack.alignment = .leading
        metaStack.spacing = 4
        metaStack.translatesAutoresizingMaskIntoConstraints = false

        refsFlow.spacing = 6
        refsFlow.lineSpacing = 6
        refsFlow.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: Self.inset, bottom: 12, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [summaryField, bodyScroll, refsFlow, metaStack] as [NSView] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.inset * 2).isActive = true
        }
        // The meta grid sits 2 pt lower than the 10 pt gap (`.meta { margin-top: 2px }`).
        stack.setCustomSpacing(12, after: refsFlow)
        addSubview(stack)
        addSubview(bottomRule)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        bottomRule.color = theme.colors.borderSubtle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var summaryText: String { summaryField.stringValue }
    var bodyText: String { bodyView.string }
    /// Meta rows as "Label: value" lines, in display order.
    private(set) var metaLines: [String] = []
    /// Commit ids offered as links (parents or stash base).
    private(set) var linkedCommits: [String] = []

    /// Shows a commit; its ref pills take the color of graph lane `lane`.
    func show(_ detail: CommitDetail, refs: [RefPillView.Ref], lane: Int) {
        content = .commit(detail, refs: refs, lane: lane)
        rebuild()
    }

    func show(_ stash: Stash) {
        content = .stash(stash)
        rebuild()
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        bottomRule.color = theme.colors.borderSubtle
        rebuild()
    }

    // MARK: - Building

    private func rebuild() {
        metaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        metaLines = []
        linkedCommits = []
        guard let content else { return }

        switch content {
        case let .commit(detail, refs, lane):
            let commit = detail.commit
            setSummary(commit.summary)
            setBody(detail.body)
            refsFlow.setViews(refs.map { RefPillView(ref: $0, lane: lane, theme: theme) })
            refsFlow.isHidden = refs.isEmpty
            addMeta("Author", value: signatureText(commit.author), plain: "\(commit.author.name) <\(commit.author.email)>")
            addMeta("Date", value: dateText(commit.author.date), plain: dateString(commit.author.date))
            if commit.committer.name != commit.author.name || commit.committer.email != commit.author.email {
                addMeta("Committer", value: signatureText(commit.committer), plain: "\(commit.committer.name) <\(commit.committer.email)>")
                addMeta("Committed", value: dateText(commit.committer.date), plain: dateString(commit.committer.date))
            }
            if commit.parents.isEmpty {
                addMeta("Parents", value: muted("none (root commit)"), plain: "none")
            } else {
                addLinks(commit.parents.count == 1 ? "Parent" : "Parents", ids: commit.parents)
            }
        case let .stash(stash):
            setSummary(stash.message)
            setBody("")
            refsFlow.setViews([])
            refsFlow.isHidden = true
            addMeta("Date", value: dateText(stash.date), plain: dateString(stash.date))
            addLinks("Base", ids: [stash.base])
        }
        needsLayout = true
    }

    /// The subject: New York 17 Medium on a 22 pt line, wrapping.
    private func setSummary(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 22
        paragraph.maximumLineHeight = 22
        paragraph.lineBreakMode = .byWordWrapping
        summaryField.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: ChromeFont.headline, .foregroundColor: theme.colors.textPrimary, .paragraphStyle: paragraph]
        )
    }

    private func setBody(_ text: String) {
        bodyView.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: ChromeFont.label, .foregroundColor: theme.colors.textPrimary.withAlphaComponent(0.85)]
        ))
        bodyView.selectedTextAttributes = [.backgroundColor: theme.colors.textSelection]
        bodyScroll.isHidden = text.isEmpty
    }

    private func muted(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: ChromeFont.label, .foregroundColor: theme.colors.textMuted])
    }

    private func signatureText(_ signature: Signature) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: signature.name,
            attributes: [.font: ChromeFont.label, .foregroundColor: theme.colors.textPrimary]
        )
        result.append(muted(" <\(signature.email)>"))
        return result
    }

    private func dateString(_ date: Date) -> String {
        let absolute = DateText.format(date, style: .absolute)
        guard let relative = Self.relativePhrase(date) else { return absolute }
        return "\(absolute) · \(relative)"
    }

    /// The absolute date in tabular figures, then ` · 20h ago` muted.
    private func dateText(_ date: Date) -> NSAttributedString {
        let font = ChromeFont.sans(size: 12, tabular: true)
        let result = NSMutableAttributedString(
            string: DateText.format(date, style: .absolute),
            attributes: [.font: font, .foregroundColor: theme.colors.textPrimary]
        )
        if let relative = Self.relativePhrase(date) {
            result.append(NSAttributedString(
                string: " · \(relative)",
                attributes: [.font: font, .foregroundColor: theme.colors.textMuted]
            ))
        }
        return result
    }

    /// "3h ago", "just now"; nil once the relative form is a calendar date.
    static func relativePhrase(_ date: Date, now: Date = Date()) -> String? {
        let relative = DateText.format(date, style: .relative, now: now)
        if relative == "now" { return "just now" }
        guard let unit = relative.last, "mhdw".contains(unit), relative.dropLast().allSatisfy(\.isNumber) else {
            let days = Int(now.timeIntervalSince(date) / 86_400)
            if days >= 365 { return days / 365 == 1 ? "1 year ago" : "\(days / 365) years ago" }
            if days >= 30 { return days / 30 == 1 ? "1 month ago" : "\(days / 30) months ago" }
            return nil
        }
        return "\(relative) ago"
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.setChromeText(title, font: ChromeFont.meta, color: theme.colors.textMuted)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        return label
    }

    private func addRow(_ title: String, _ value: NSView) {
        let row = NSStackView(views: [label(title), value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        metaStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: metaStack.widthAnchor).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.metaRowHeight).isActive = true
    }

    private func addMeta(_ title: String, value: NSAttributedString, plain: String) {
        let field = NSTextField(labelWithAttributedString: value)
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.toolTip = plain
        addRow(title, field)
        metaLines.append("\(title): \(plain)")
    }

    private func addLinks(_ title: String, ids: [String]) {
        let links = NSStackView()
        links.orientation = .horizontal
        links.spacing = 8
        for id in ids {
            let button = CommitLinkButton(commitID: id, theme: theme)
            button.target = self
            button.action = #selector(linkClicked(_:))
            links.addArrangedSubview(button)
        }
        addRow(title, links)
        linkedCommits += ids
        metaLines.append("\(title): \(ids.map { String($0.prefix(7)) }.joined(separator: " "))")
    }

    @objc private func linkClicked(_ sender: CommitLinkButton) {
        onSelectCommit?(sender.commitID)
    }

    // MARK: - Layout

    override func layout() {
        let width = max(0, bounds.width - Self.inset * 2)
        if summaryField.preferredMaxLayoutWidth != width {
            summaryField.preferredMaxLayoutWidth = width
            summaryField.invalidateIntrinsicContentSize()
        }
        if let layoutManager = bodyView.layoutManager, let container = bodyView.textContainer, width > 0 {
            bodyView.frame.size.width = width
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            let height = ceil(layoutManager.usedRect(for: container).height)
            let clamped = min(height, Self.maximumBodyHeight)
            if bodyHeight.constant != clamped { bodyHeight.constant = clamped }
        }
        super.layout()
    }
}

/// A commit short id that selects the commit when clicked: SF Mono 12 ink
/// with a 1 pt blue underline.
final class CommitLinkButton: NSButton {
    let commitID: String

    init(commitID: String, theme: AppTheme) {
        self.commitID = commitID
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        attributedTitle = NSAttributedString(
            string: String(commitID.prefix(7)),
            attributes: [
                .font: ChromeFont.mono,
                .foregroundColor: theme.colors.textPrimary,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.colors.blue,
            ]
        )
        toolTip = "Select \(commitID)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

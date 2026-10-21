import AppKit
import SopranoGitCore

/// Pages of the settings tab, in sidebar order.
enum SettingsPage: String, CaseIterable {
    case general
    case git
    case keyboard
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .git: "Git"
        case .keyboard: "Keyboard"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .git: "arrow.triangle.branch"
        case .keyboard: "keyboard"
        case .about: "info.circle"
        }
    }
}

/// The settings tab (`settings.open`, ⌘,): a page list on the left, a form on
/// the right. Every control edits one key of settings.json through
/// `SettingsCenter` (comments and key order survive); the screen keeps no
/// settings of its own and re-renders whenever the file changes, whoever
/// changed it. Shortcuts are rebound by recording a chord: while recording,
/// the keyboard router hands every key press to this screen.
@MainActor
final class SettingsViewController: NSViewController, FocusRegionController {
    /// Everything the form renders; a settings change that leaves it equal
    /// re-renders nothing, so a field the user just tabbed into survives.
    private struct Snapshot: Equatable {
        var settings: AppSettings
        var keybindings: KeybindingSettings
        var issues: [ConfigIssue]
        var gitPath: String?
        var extraPath: [String]

        @MainActor
        init(_ center: SettingsCenter) {
            settings = center.settings
            keybindings = center.keybindingSettings
            issues = center.issues
            gitPath = center.configuredValue(at: ["git", "path"]) as? String
            let extra = center.configuredValue(at: ["git", "extraPath"])
            extraPath = (extra as? [Any])?.compactMap { $0 as? String } ?? (extra as? String).map { [$0] } ?? []
        }
    }

    static let repositoryURL = URL(string: "https://github.com/frknue/soprano_git")!

    private let center: SettingsCenter
    private weak var router: KeyboardRouter?
    private var theme: AppTheme
    private(set) var page: SettingsPage = .general
    private var rendered: Snapshot?
    private var refreshScheduled = false

    /// The command whose chord is being recorded, nil when not recording.
    private(set) var recordingCommandID: String?
    private var recorder: ShortcutRecorder?
    /// The Keyboard page's filter text.
    private(set) var shortcutQuery = ""

    private let root = SettingsRootView()
    private let sidebar = NSView()
    private let pageStack = NSStackView()
    private var pageButtons: [SettingsPage: SettingsPageButton] = [:]
    private let sidebarRule = ChromeRuleView(axis: .vertical)
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let contentStack = NSStackView()

    private var filterField: SearchField?
    private var shortcutList: NSStackView?
    private var extraPathInput: NSTextField?
    /// The General page's theme popup while that page shows (tests).
    private(set) weak var themePopup: NSPopUpButton?
    /// The Keyboard page's rows by command id while that page shows (tests).
    private(set) var shortcutRows: [String: ShortcutSettingRow] = [:]

    init(center: SettingsCenter = .shared, router: KeyboardRouter?) {
        self.center = center
        self.router = router
        self.theme = ThemeCenter.shared.theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var focusRegion: FocusRegion { .settings }
    var focusRootView: NSView { view }

    func takeFocus() {
        view.window?.makeFirstResponder(root)
    }

    // MARK: - Layout

    override func loadView() {
        root.wantsLayer = true
        sidebar.wantsLayer = true
        for view in [sidebar, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        pageStack.orientation = .vertical
        pageStack.spacing = 2
        pageStack.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        pageStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(pageStack)
        for page in SettingsPage.allCases {
            let button = SettingsPageButton(page: page, theme: theme, target: self, action: #selector(pageClicked(_:)))
            button.tag = SettingsPage.allCases.firstIndex(of: page) ?? 0
            pageButtons[page] = button
            pageStack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: SettingsPageButton.height),
                button.widthAnchor.constraint(equalToConstant: 180),
            ])
        }
        sidebar.addSubview(sidebarRule)
        hintLabel.font = ChromeFont.meta
        hintLabel.maximumNumberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(hintLabel)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        documentView.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 22
        contentStack.edgeInsets = NSEdgeInsets(top: 26, left: 24, bottom: 32, right: 24)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        let fillWidth = contentStack.widthAnchor.constraint(equalTo: documentView.widthAnchor)
        fillWidth.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        let hugContent = documentView.heightAnchor.constraint(equalToConstant: 0)
        hugContent.priority = .defaultLow

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),

            pageStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            pageStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pageStack.topAnchor.constraint(equalTo: sidebar.topAnchor),

            hintLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),

            sidebarRule.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarRule.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarRule.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            // A reading column, not a canvas: labels stay near their controls.
            contentStack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            fillWidth,
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            // The document is the taller of content and viewport; content stays
            // at its natural height at the top.
            documentView.bottomAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor),
            hugContent,
        ])

        view = root
        applyChrome()
        render(resetScroll: true)

        center.addObserver(self) { [weak self] in self?.scheduleRefresh() }
        ThemeCenter.shared.addObserver(self) { [weak self] theme in
            guard let self else { return }
            self.theme = theme
            self.applyChrome()
            self.render(resetScroll: false)
        }
    }

    private func applyChrome() {
        let colors = theme.colors
        root.layer?.backgroundColor = colors.bgBase.cgColor
        sidebar.layer?.backgroundColor = colors.bgPanel.cgColor
        sidebarRule.color = colors.borderSubtle
        hintLabel.textColor = colors.textMuted
        for (page, button) in pageButtons {
            button.apply(theme: theme)
            button.isActive = page == self.page
        }
        hintLabel.stringValue = "J / K switch pages\n/ filter shortcuts\nEsc close settings\n\nEdits save to \(center.displayPath) as you make them."
    }

    // MARK: - Pages

    func show(_ page: SettingsPage) {
        // Commits a field mid-edit before its page goes away.
        view.window?.makeFirstResponder(root)
        stopRecording(rerender: false)
        self.page = page
        for (item, button) in pageButtons {
            button.isActive = item == page
        }
        render(resetScroll: true)
    }

    func movePage(by delta: Int) {
        let pages = SettingsPage.allCases
        let index = pages.firstIndex(of: page) ?? 0
        show(pages[(index + delta + pages.count) % pages.count])
    }

    /// `/`: the Keyboard page with its filter focused.
    func focusShortcutFilter() {
        if page != .keyboard { show(.keyboard) }
        guard let field = filterField?.field else { return }
        view.window?.makeFirstResponder(field)
    }

    /// The tab is leaving the window: stop recording and commit any edit.
    func willDetach() {
        stopRecording(rerender: false)
        if let window = view.window, isFirstResponderInside(window) {
            window.makeFirstResponder(nil)
        }
    }

    @objc private func pageClicked(_ sender: NSButton) {
        let pages = SettingsPage.allCases
        guard pages.indices.contains(sender.tag) else { return }
        show(pages[sender.tag])
    }

    private func scheduleRefresh() {
        guard isViewLoaded, !refreshScheduled else { return }
        refreshScheduled = true
        // Re-rendering tears down the control that fired; let its event finish.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard Snapshot(self.center) != self.rendered else { return }
            self.render(resetScroll: false)
        }
    }

    private func render(resetScroll: Bool) {
        guard isViewLoaded else { return }
        let filterHadFocus = filterField.map { isFirstResponder($0.field) } ?? false
        let origin = scrollView.contentView.bounds.origin

        rendered = Snapshot(center)
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        filterField = nil
        shortcutList = nil
        extraPathInput = nil
        shortcutRows = [:]

        switch page {
        case .general: buildGeneral()
        case .git: buildGit()
        case .keyboard: buildKeyboard()
        case .about: buildAbout()
        }

        root.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let target = resetScroll ? .zero : clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)

        if let window = view.window {
            if filterHadFocus, let field = filterField?.field {
                window.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
            } else if window.firstResponder === window || window.firstResponder == nil {
                window.makeFirstResponder(root)
            }
        }
    }

    private var form: SettingsForm { SettingsForm(theme: theme) }

    private func add(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -48).isActive = true
    }

    private func addHeader(_ title: String, _ subtitle: String) {
        add(form.header(title: title, subtitle: subtitle))
        let issues = center.issues
        guard !issues.isEmpty else { return }
        let (section, rows) = form.card(
            title: "Problems in settings.json",
            subtitle: "Bad values keep their defaults; a syntax error keeps the last good settings."
        )
        rows.spacing = 6
        rows.edgeInsets.top = 10
        rows.edgeInsets.bottom = 10
        for issue in issues {
            let row = form.issueRow(issue)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -2 * SettingsForm.cardInset).isActive = true
        }
        rows.addArrangedSubview(form.button("Open settings.json", target: self, action: #selector(openFile)))
        add(section)
    }

    // MARK: General

    /// The theme popup: follow Soprano, then every id settings.json accepts
    /// (`AppTheme.options`: Folio, Folio Paper, Folio Ink, the 7 themes).
    static let themeChoices: [(title: String, value: String)] =
        [(title: "Follow Soprano", value: "soprano")]
        + AppTheme.options.map { option in
            (title: option.id == AppTheme.folioId ? "Folio (follows macOS)" : option.name, value: option.id)
        }

    private func buildGeneral() {
        let settings = center.settings
        addHeader("General", "Appearance, graph and diff. Changes apply right away and are written to \(center.displayPath), keeping its comments.")

        let (appearance, appearanceRows) = form.card(title: "Appearance")
        let themePopup = form.popup(Self.themeChoices, selected: settings.theme)
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        self.themePopup = themePopup
        let themeDetail = switch settings.theme {
        case "soprano": "Uses Soprano's theme and appearance, now \(ThemeCenter.shared.theme.name)."
        case AppTheme.folioId: "Paper or Ink, following the macOS appearance."
        default: "A fixed theme, independent of Soprano."
        }
        form.add([form.row("Theme", detail: themeDetail, control: themePopup)], to: appearanceRows)
        add(appearance)

        let (graph, graphRows) = form.card(title: "Commit graph")
        let pageSize = form.numberField(settings.graphPageSize)
        pageSize.target = self
        pageSize.action = #selector(pageSizeCommitted(_:))
        let limits = SettingsResolver.Limits.graphPageSize
        let dates = form.popup(
            [(title: "Relative (3h, 2d)", value: AppSettings.DateStyle.relative.rawValue),
             (title: "Absolute (2026-03-04 14:05)", value: AppSettings.DateStyle.absolute.rawValue)],
            selected: settings.dateStyle.rawValue
        )
        dates.target = self
        dates.action = #selector(dateStyleChanged(_:))
        form.add([
            form.row("Commits per page", detail: "Loaded at a time as you scroll, \(limits.lowerBound)–\(limits.upperBound).", control: pageSize),
            form.row("Dates", detail: "Commit dates in the graph and the commit panel.", control: dates),
        ], to: graphRows)
        add(graph)

        let (diff, diffRows) = form.card(title: "Diff")
        let context = form.numberField(settings.diffContextLines, width: 60)
        context.target = self
        context.action = #selector(contextLinesCommitted(_:))
        let contextLimits = SettingsResolver.Limits.diffContextLines
        form.add([
            form.row("Context lines", detail: "Unchanged lines shown around each change, \(contextLimits.lowerBound)–\(contextLimits.upperBound).", control: context),
        ], to: diffRows)
        add(diff)

        let (file, fileRows) = form.card(
            title: "Settings file",
            subtitle: "Everything here is stored in \(center.displayPath). Hand edits apply as soon as you save; this screen follows them."
        )
        form.add([form.group([
            form.button("Open settings.json", target: self, action: #selector(openFile)),
            form.button("Reveal in Finder", target: self, action: #selector(revealFile)),
            form.button("Reload", target: self, action: #selector(reloadFile)),
        ])], to: fileRows)
        fileRows.edgeInsets.top = 10
        fileRows.edgeInsets.bottom = 10
        add(file)
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        center.write(value, at: ["theme"])
    }

    @objc private func pageSizeCommitted(_ sender: NSTextField) {
        commitInteger(sender, current: center.settings.graphPageSize, limits: SettingsResolver.Limits.graphPageSize, path: ["graph", "pageSize"])
    }

    @objc private func dateStyleChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        write(value, at: ["graph", "dateStyle"])
    }

    @objc private func contextLinesCommitted(_ sender: NSTextField) {
        commitInteger(sender, current: center.settings.diffContextLines, limits: SettingsResolver.Limits.diffContextLines, path: ["diff", "contextLines"])
    }

    @objc private func openFile() {
        center.openInEditor()
    }

    @objc private func revealFile() {
        center.revealInFinder()
    }

    @objc private func reloadFile() {
        center.reloadFromDisk()
        render(resetScroll: false)
    }

    // MARK: Git

    private func buildGit() {
        let settings = center.settings
        addHeader("Git", "The git executable, the PATH its hooks see, and how Pull integrates. The executable and PATH apply to repositories opened after the change.")

        let (executable, executableRows) = form.card(title: "Executable")
        let pathField = form.textField(rendered?.gitPath ?? "", placeholder: "Auto-detect", width: 260, monospaced: true)
        pathField.target = self
        pathField.action = #selector(gitPathCommitted(_:))
        let resolved = GitRunner.resolveExecutable(preferredPath: settings.gitPath)
        let detail: String
        var detailColor: NSColor?
        if let configured = settings.gitPath, !FileManager.default.isExecutableFile(atPath: configured) {
            detail = "\(abbreviated(configured)) is not an executable file; using \(resolved.map { abbreviated($0.path) } ?? "no git")."
            detailColor = theme.colors.danger
        } else if let resolved {
            detail = "Using \(abbreviated(resolved.path))."
        } else {
            detail = "No git found. Install the Command Line Tools (xcode-select --install) or Homebrew git."
            detailColor = theme.colors.danger
        }
        let autoButton = form.button("Auto", target: self, action: #selector(gitPathAuto))
        autoButton.isEnabled = rendered?.gitPath != nil
        form.add([form.row(
            "Git",
            detail: detail,
            detailColor: detailColor,
            control: form.group([pathField, form.button("Browse…", target: self, action: #selector(browseGitPath)), autoButton])
        )], to: executableRows)
        add(executable)

        let (extra, extraRows) = form.card(
            title: "Extra PATH",
            subtitle: "Directories put in front of PATH for git and its hooks (node, bun, …). Homebrew, ~/.local/bin, ~/.bun/bin and ~/.cargo/bin are always included."
        )
        let directories = rendered?.extraPath ?? []
        if directories.isEmpty {
            form.add([pathRow(nil, index: -1)], to: extraRows)
        } else {
            form.add(directories.enumerated().map { pathRow($0.element, index: $0.offset) }, to: extraRows)
        }
        let input = form.textField("", placeholder: "Directory path", width: 260, monospaced: true)
        input.target = self
        input.action = #selector(addExtraPath)
        input.cell?.sendsActionOnEndEditing = false
        extraPathInput = input
        form.add([form.row("Add directory", control: form.group([
            input,
            form.button("Browse…", target: self, action: #selector(browseExtraPath)),
            form.button("Add", kind: .ink, target: self, action: #selector(addExtraPath)),
        ]))], to: extraRows)
        add(extra)

        let (pull, pullRows) = form.card(title: "Pull")
        let modes: [(title: String, value: String)] = PullMode.allCases.map { mode in
            switch mode {
            case .fastForwardIfPossible: ("Fast-forward, else merge", mode.rawValue)
            case .fastForwardOnly: ("Fast-forward only", mode.rawValue)
            case .rebase: ("Rebase", mode.rawValue)
            }
        }
        let pullPopup = form.popup(modes, selected: settings.pullMode.rawValue)
        pullPopup.target = self
        pullPopup.action = #selector(pullModeChanged(_:))
        let pullDetail = switch settings.pullMode {
        case .fastForwardIfPossible: "git pull --ff: fast-forward when possible, merge commit otherwise."
        case .fastForwardOnly: "git pull --ff-only: refuse when the branches have diverged."
        case .rebase: "git pull --rebase: replay local commits on top of the upstream."
        }
        form.add([form.row("Mode", detail: pullDetail, control: pullPopup)], to: pullRows)
        add(pull)
    }

    /// One Extra PATH entry, or the empty-list row when `path` is nil.
    private func pathRow(_ path: String?, index: Int) -> NSView {
        guard let path else {
            let row = NSTextField(labelWithString: "No extra directories.")
            row.font = ChromeFont.meta
            row.textColor = theme.colors.textMuted
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 32),
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath, isDirectory: &isDirectory) && isDirectory.boolValue
        let remove = form.button("Remove", target: self, action: #selector(removeExtraPath(_:)))
        remove.tag = index
        let label = NSTextField(labelWithString: exists ? path : "\(path)  ·  not found")
        label.font = ChromeFont.mono
        label.textColor = exists ? theme.colors.textPrimary : theme.colors.textMuted
        label.lineBreakMode = .byTruncatingMiddle
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        for view in [label, remove] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -12),
            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc private func gitPathCommitted(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (rendered?.gitPath ?? "") else { return }
        if text.isEmpty {
            center.remove(at: ["git", "path"])
        } else {
            center.write(abbreviated(NSString(string: text).expandingTildeInPath), at: ["git", "path"])
        }
    }

    @objc private func gitPathAuto() {
        center.remove(at: ["git", "path"])
    }

    @objc private func browseGitPath() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        panel.prompt = "Use"
        panel.message = "Choose the git executable"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.center.write(self.abbreviated(url.path), at: ["git", "path"])
            }
        }
    }

    @objc private func addExtraPath() {
        guard let input = extraPathInput else { return }
        storeExtraPath(input.stringValue)
    }

    @objc private func browseExtraPath() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a directory for git's PATH"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            MainActor.assumeIsolated { self?.storeExtraPath(path) }
        }
    }

    private func storeExtraPath(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            NSSound.beep()
            return
        }
        var directories = rendered?.extraPath ?? []
        extraPathInput?.stringValue = ""
        guard !directories.contains(where: { NSString(string: $0).expandingTildeInPath == path }) else { return }
        directories.append(abbreviated(path))
        center.write(directories, at: ["git", "extraPath"])
    }

    @objc private func removeExtraPath(_ sender: NSButton) {
        var directories = rendered?.extraPath ?? []
        guard directories.indices.contains(sender.tag) else { return }
        directories.remove(at: sender.tag)
        center.write(directories, at: ["git", "extraPath"])
    }

    @objc private func pullModeChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        center.write(value, at: ["pull", "mode"])
    }

    // MARK: Keyboard

    private func buildKeyboard() {
        let bindings = center.keybindingSettings
        addHeader("Keyboard", "The prefix and every command's shortcut. Record a new chord, turn one off, or reset it to the default; overrides go to \"keybindings.bindings\" in settings.json by command id.")

        let (prefix, prefixRows) = form.card(title: "Prefix")
        let keyField = form.textField(bindings.prefixKey, width: 44)
        keyField.alignment = .center
        keyField.target = self
        keyField.action = #selector(prefixKeyCommitted(_:))
        let timeout = form.numberField(bindings.prefixTimeoutMs)
        timeout.target = self
        timeout.action = #selector(prefixTimeoutCommitted(_:))
        let limits = SettingsResolver.Limits.prefixTimeoutMs
        form.add([
            form.row("Prefix key", detail: "⌃ + this key starts a prefix chord: ⌃\(bindings.prefixKey.uppercased()), then the key.", control: keyField),
            form.row("Prefix timeout (ms)", detail: "How long the prefix waits for its key, \(limits.lowerBound)–\(limits.upperBound).", control: timeout),
        ], to: prefixRows)
        add(prefix)

        let filter = SearchField(placeholder: "Filter shortcuts by name, id or key", theme: theme, hint: "/")
        filter.field.stringValue = shortcutQuery
        filter.field.delegate = self
        filter.translatesAutoresizingMaskIntoConstraints = false
        filterField = filter
        add(filter)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 22
        list.translatesAutoresizingMaskIntoConstraints = false
        shortcutList = list
        add(list)
        fillShortcutList()
    }

    /// Re-renders only the shortcut cards, keeping the filter field focused.
    private func rebuildShortcutList() {
        guard let list = shortcutList else {
            render(resetScroll: false)
            return
        }
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        fillShortcutList()
        root.layoutSubtreeIfNeeded()
    }

    private func fillShortcutList() {
        guard let list = shortcutList else { return }
        let keymap = center.keymap
        let overrides = center.keybindingSettings.overrides
        let sections = ShortcutSheetModel.sections(registry: center.registry, settings: center, query: shortcutQuery)
        if sections.isEmpty {
            let empty = NSTextField(labelWithString: "")
            empty.setChromeText("No matching commands", font: ChromeFont.empty, color: theme.colors.textMuted)
            list.addArrangedSubview(empty)
            return
        }
        for section in sections {
            let (card, rows) = form.card(title: section.category.rawValue)
            let views = section.entries.map { entry in
                let row = ShortcutSettingRow(
                    entry: entry,
                    scopes: center.registry.command(entry.id)?.scopes ?? [],
                    isCustomized: keymap.customizedIDs.contains(entry.id),
                    isDisabled: overrides[entry.id] == .disabled,
                    conflict: keymap.conflictingIDs.contains(entry.id) ? conflictMessage(for: entry.id, in: keymap) : nil,
                    recording: recordingCommandID == entry.id ? recordingPrompt : nil,
                    theme: theme,
                    target: self
                )
                shortcutRows[entry.id] = row
                return row
            }
            form.add(views, to: rows)
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    private var recordingPrompt: String {
        guard let recorder else { return "" }
        return recorder.isAwaitingPrefixKey
            ? "⌃\(recorder.prefixKey.uppercased()) … now the key"
            : "Press a shortcut · Esc cancels"
    }

    private func conflictMessage(for id: String, in keymap: Keymap) -> String {
        keymap.issues.filter { $0.message.contains("\"\(id)\"") }.map(\.message).joined(separator: "\n")
    }

    @objc fileprivate func recordClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if recordingCommandID == id {
            stopRecording(rerender: true)
        } else {
            startRecording(id)
        }
    }

    @objc fileprivate func disableClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        stopRecording(rerender: false)
        center.write(NSNull(), at: ["keybindings", "bindings", id])
    }

    @objc fileprivate func resetClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        stopRecording(rerender: false)
        center.remove(at: ["keybindings", "bindings", id])
    }

    /// Starts capturing the next chord for `id`; key presses stop reaching
    /// commands and menus until it is recorded or cancelled.
    func startRecording(_ id: String) {
        view.window?.makeFirstResponder(root)
        recordingCommandID = id
        recorder = ShortcutRecorder(prefixKey: center.keymap.prefixKey)
        router?.capture = { [weak self] stroke in self?.recorderReceived(stroke) }
        rebuildShortcutList()
    }

    func stopRecording(rerender: Bool) {
        guard recordingCommandID != nil else { return }
        router?.capture = nil
        recordingCommandID = nil
        recorder = nil
        if rerender { rebuildShortcutList() }
    }

    private func recorderReceived(_ stroke: KeyStroke) {
        guard var recorder, let id = recordingCommandID else { return }
        let outcome = recorder.feed(stroke)
        self.recorder = recorder
        switch outcome {
        case .awaitingPrefixKey:
            rebuildShortcutList()
        case .rejected:
            NSSound.beep()
        case .cancelled:
            stopRecording(rerender: true)
        case let .recorded(chord):
            stopRecording(rerender: true)
            center.write(chord.canonicalString, at: ["keybindings", "bindings", id])
        }
    }

    @objc private func prefixKeyCommitted(_ sender: NSTextField) {
        let current = center.keybindingSettings.prefixKey
        guard let first = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            sender.stringValue = current
            return
        }
        let value = String(first).lowercased()
        sender.stringValue = value
        guard value != current else { return }
        // The prefix appears in other rows' text; re-render on the change.
        center.write(value, at: ["keybindings", "prefixKey"])
    }

    @objc private func prefixTimeoutCommitted(_ sender: NSTextField) {
        commitInteger(sender, current: center.keybindingSettings.prefixTimeoutMs, limits: SettingsResolver.Limits.prefixTimeoutMs, path: ["keybindings", "prefixTimeoutMs"])
    }

    // MARK: About

    private func buildAbout() {
        addHeader("About", "Soprano Git, a keyboard-first Git client in the Soprano family.")
        let (about, rows) = form.card(title: "Soprano Git")
        let git = GitRunner.resolveExecutable(preferredPath: center.settings.gitPath).map { abbreviated($0.path) } ?? "not found"
        form.add([
            form.row("Version", control: value(AppVersion.current, font: ChromeFont.sans(size: 12, tabular: true))),
            form.row("Git", control: value(git)),
            form.row("Settings", control: value(center.displayPath)),
            form.row("Soprano theme source", control: value(SettingsFile.displayPath(for: ThemeCenter.shared.sopranoSettingsURL))),
            form.row("Source", control: form.button("github.com/frknue/soprano_git", target: self, action: #selector(openRepository))),
        ], to: rows)
        add(about)
    }

    /// A read-only value: SF Mono 12 (paths) unless `font` says otherwise.
    private func value(_ text: String, font: NSFont = ChromeFont.mono) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = theme.colors.textMuted
        label.lineBreakMode = .byTruncatingMiddle
        label.isSelectable = true
        return label
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    // MARK: - Writing

    /// Writes a value a control already shows; when nothing else on the page
    /// changes, the page stays as it is (no re-render under the cursor).
    private func write(_ value: Any, at path: [String]) {
        let issuesBefore = center.issues
        guard center.write(value, at: path), center.issues == issuesBefore else { return }
        rendered = Snapshot(center)
    }

    private func commitInteger(_ field: NSTextField, current: Int, limits: ClosedRange<Int>, path: [String]) {
        let parsed = (field.formatter as? NumberFormatter)?.number(from: field.stringValue)?.intValue ?? Int(field.stringValue)
        guard let parsed else {
            field.stringValue = String(current)
            return
        }
        let clamped = min(max(limits.lowerBound, parsed), limits.upperBound)
        field.stringValue = String(clamped)
        guard clamped != current else { return }
        write(clamped, at: path)
    }

    private func abbreviated(_ path: String) -> String {
        SettingsFile.displayPath(for: URL(fileURLWithPath: path))
    }

    private func isFirstResponder(_ field: NSTextField) -> Bool {
        guard let responder = view.window?.firstResponder else { return false }
        return RepoWorkspaceViewController.responderView(responder) === field
    }

    private func isFirstResponderInside(_ window: NSWindow) -> Bool {
        guard let responderView = RepoWorkspaceViewController.responderView(window.firstResponder) else { return false }
        return responderView.isDescendant(of: view)
    }
}

extension SettingsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === filterField?.field else { return }
        shortcutQuery = field.stringValue
        rebuildShortcutList()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === filterField?.field else { return false }
        // Esc or Return leaves the filter (Esc clears it first).
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !shortcutQuery.isEmpty {
                control.stringValue = ""
                shortcutQuery = ""
                rebuildShortcutList()
            } else {
                takeFocus()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            takeFocus()
            return true
        }
        return false
    }
}

/// The settings view's root: takes first responder so page keys (J/K, /,
/// Esc) route to the settings region when no control is focused.
final class SettingsRootView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// One command on the Keyboard page: SF Pro 12 title over its SF Mono 11
/// `id · scope`, one K1 keycap group per chord (plus an outline `Custom`
/// chip when customized) or the muted recording prompt, and Record / Off /
/// Reset.
@MainActor
final class ShortcutSettingRow: NSView {
    /// One group per chord, in order (tests).
    private(set) var keycapGroups: [ChromeKeycapGroupView] = []
    /// The `Custom` chip shown when the binding is customized (tests).
    private(set) var customChip: ChromeChip?
    /// The recording prompt, while recording (tests).
    private(set) var recordingPrompt: NSTextField?

    init(
        entry: ShortcutEntry,
        scopes: Set<FocusRegion>,
        isCustomized: Bool,
        isDisabled: Bool,
        conflict: String?,
        recording: String?,
        theme: AppTheme,
        target: SettingsViewController
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let colors = theme.colors

        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.setChromeText(entry.title, font: ChromeFont.label, color: isDisabled ? colors.textMuted : colors.textPrimary)
        let scopeText = scopes.isEmpty ? "everywhere" : scopes.map(\.rawValue).sorted().joined(separator: ", ")
        let subtitle = NSTextField(labelWithString: "")
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setChromeText("\(entry.id) · \(scopeText)", font: ChromeFont.monoSmall, color: colors.textMuted)
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let keys = NSStackView()
        keys.orientation = .horizontal
        keys.alignment = .centerY
        keys.spacing = 6
        if let recording {
            let prompt = NSTextField(labelWithString: "")
            prompt.setChromeText(recording, font: ChromeFont.label, color: colors.textMuted)
            keys.addArrangedSubview(prompt)
            recordingPrompt = prompt
        } else if entry.keys.isEmpty {
            let none = NSTextField(labelWithString: "")
            none.setChromeText(isDisabled ? "off" : "unbound", font: ChromeFont.meta, color: colors.textMuted)
            keys.addArrangedSubview(none)
        } else {
            for caps in entry.keys {
                let group = ChromeKeycapGroupView(caps: caps, theme: theme, tone: .primary)
                keycapGroups.append(group)
                keys.addArrangedSubview(group)
            }
        }
        if isCustomized, recording == nil {
            let chip = ChromeChip(text: "Custom", theme: theme, style: .outline)
            keys.addArrangedSubview(chip)
            customChip = chip
        }
        if let conflict {
            let mark = ChromeStatusMark(shape: .dot, color: colors.yellow, size: Chrome.statusMarkSmall)
            let label = NSTextField(labelWithString: "")
            label.setChromeText("conflict", font: ChromeFont.meta, color: colors.yellow)
            let flag = NSStackView(views: [mark, label])
            flag.orientation = .horizontal
            flag.alignment = .centerY
            flag.spacing = 5
            flag.toolTip = conflict
            keys.insertArrangedSubview(flag, at: 0)
        }
        keys.setContentHuggingPriority(.required, for: .horizontal)
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        if isCustomized { keys.toolTip = "Customized in settings.json" }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 4
        let record = ChromeButton(
            title: recording == nil ? "Record" : "Cancel",
            theme: theme,
            kind: recording == nil ? .standard : .ink,
            target: target,
            action: #selector(SettingsViewController.recordClicked(_:))
        )
        record.identifier = NSUserInterfaceItemIdentifier(entry.id)
        buttons.addArrangedSubview(record)
        let off = ChromeButton(title: "Off", theme: theme, target: target, action: #selector(SettingsViewController.disableClicked(_:)))
        off.identifier = NSUserInterfaceItemIdentifier(entry.id)
        off.isEnabled = !entry.keys.isEmpty
        buttons.addArrangedSubview(off)
        let reset = ChromeButton(title: "Reset", theme: theme, target: target, action: #selector(SettingsViewController.resetClicked(_:)))
        reset.identifier = NSUserInterfaceItemIdentifier(entry.id)
        reset.isEnabled = isCustomized
        buttons.addArrangedSubview(reset)
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        for view in [text, keys, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -12),
            keys.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -14),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

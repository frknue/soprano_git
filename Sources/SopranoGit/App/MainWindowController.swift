import AppKit
import SopranoGitCore

/// The main window. The snapshot harness lets it live off-screen.
final class MainWindow: NSWindow {
    /// Skip AppKit's on-screen constraint (snapshot windows sit off-screen).
    var allowsOffscreenFrame = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreenFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// One tab of the main window: the welcome screen or a repository workspace.
@MainActor
final class WorkspaceTab {
    enum Content {
        case welcome(WelcomeViewController)
        case repository(RepoWorkspaceViewController)
    }

    let id = UUID()
    var content: Content

    init(content: Content) {
        self.content = content
    }

    var viewController: NSViewController {
        switch content {
        case let .welcome(welcome): welcome
        case let .repository(workspace): workspace
        }
    }

    var workspace: RepoWorkspaceViewController? {
        if case let .repository(workspace) = content { return workspace }
        return nil
    }

    var welcome: WelcomeViewController? {
        if case let .welcome(welcome) = content { return welcome }
        return nil
    }

    var title: String {
        workspace?.controller.displayName ?? "Welcome"
    }

    var root: URL? {
        workspace?.controller.repository.root
    }
}

/// The single main window: Soprano chrome (full-size content, transparent
/// titlebar, `.darkAqua`), the repository tab bar in the titlebar area, the
/// selected tab's content, the keyboard router, palette and shortcut sheet.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let state: AppStateStore
    /// False for the snapshot harness: no tabs or frames are written.
    let persistsState: Bool
    let router: KeyboardRouter

    private(set) var tabs: [WorkspaceTab] = []
    private(set) var selectedIndex = 0
    private let rootView = NSView()
    private let tabBar: TabBarView
    private let contentContainer = NSView()
    private var theme: AppTheme
    private var keyboardMode: KeyboardRouter.State = .normal
    /// Opens in flight, so restored tabs keep their order.
    private var pendingOpens = 0

    lazy var palette: CommandPalettePanel = CommandPalettePanel(themeManager: ThemeCenter.shared.manager)
    lazy var shortcutSheet = ShortcutSheetPanel()

    init(state: AppStateStore, persistsState: Bool, frame: NSRect? = nil) {
        self.state = state
        self.persistsState = persistsState
        self.theme = ThemeCenter.shared.theme
        self.tabBar = TabBarView(theme: theme)

        var routerContext: (() -> CommandContext?)?
        router = KeyboardRouter(
            keymap: { SettingsCenter.shared.keymap },
            context: { routerContext?() }
        )

        let mainVisibleFrame = NSScreen.main?.visibleFrame ?? MainWindowSizing.fallbackVisibleFrame
        let startupFrame = frame
            ?? (persistsState ? MainWindowFrameStore.load(from: state.defaults, visibleFrames: NSScreen.screens.map(\.visibleFrame)) : nil)
            ?? MainWindowSizing.initialFrame(in: mainVisibleFrame)
        let window = MainWindow(
            contentRect: NSRect(origin: .zero, size: startupFrame.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Soprano Git"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)

        routerContext = { [weak self] in self?.commandContext() }
        router.onStateChange = { [weak self] mode in
            self?.keyboardMode = mode
            self?.currentTab?.workspace?.setKeyboardMode(mode)
        }
        router.onCommandPerformed = { [weak self] _ in
            self?.currentTab?.workspace?.refreshChrome()
        }

        buildContent()
        window.contentView = rootView
        window.setFrame(startupFrame, display: false)
        window.delegate = self
        applyTheme()
        router.startMonitoring(window: window)

        ThemeCenter.shared.addObserver(self) { [weak self] theme in
            self?.theme = theme
            self?.applyTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var mainWindow: MainWindow? { window as? MainWindow }

    private func buildContent() {
        rootView.wantsLayer = true
        tabBar.onSelect = { [weak self] index in self?.selectTab(index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onAdd = { [weak self] in self?.newTab() }
        for view in [tabBar, contentContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: rootView.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            contentContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
    }

    private func applyTheme() {
        window?.backgroundColor = theme.colors.bgBase
        window?.appearance = NSAppearance(named: .darkAqua)
        rootView.layer?.backgroundColor = theme.colors.bgBase.cgColor
        tabBar.apply(theme: theme)
    }

    // MARK: - Tabs

    var currentTab: WorkspaceTab? {
        tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
    }

    var currentWorkspace: RepoWorkspaceViewController? { currentTab?.workspace }

    /// Reopens the tabs of the last session (welcome tab when there were none).
    func restoreSession() {
        let roots = state.openTabs
        let selected = state.selectedTab
        guard !roots.isEmpty else {
            if tabs.isEmpty { newTab() }
            return
        }
        pendingOpens += 1
        Task { @MainActor in
            for root in roots {
                _ = await self.openRepository(at: root, inNewTab: true, reportErrors: false, select: false)
            }
            self.pendingOpens -= 1
            if self.tabs.isEmpty {
                self.newTab()
            } else {
                self.selectTab(min(max(0, selected), self.tabs.count - 1))
            }
        }
    }

    func newTab() {
        let welcome = makeWelcome()
        tabs.append(WorkspaceTab(content: .welcome(welcome)))
        selectTab(tabs.count - 1)
    }

    private func makeWelcome() -> WelcomeViewController {
        let welcome = WelcomeViewController(state: state)
        welcome.onOpen = { [weak self] url in
            Task { @MainActor in
                _ = await self?.openRepository(at: url)
            }
        }
        welcome.onOpenPanel = { [weak self] in self?.showOpenPanel() }
        _ = welcome.view
        if RepositoryOpener.gitExecutable() == nil {
            welcome.errorMessage = GitSetupError.gitNotFound.errorDescription
        }
        return welcome
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        tab.workspace?.close()
        if tab.viewController.view.superview != nil {
            tab.workspace?.willDetach()
            tab.viewController.view.removeFromSuperview()
        }
        if tabs.isEmpty {
            newTab()
            return
        }
        selectedIndex = min(selectedIndex, tabs.count - 1)
        if index < selectedIndex || selectedIndex >= tabs.count {
            selectedIndex = max(0, selectedIndex - 1)
        }
        showSelectedTab()
    }

    func closeCurrentTab() {
        closeTab(at: selectedIndex)
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        showSelectedTab()
    }

    func selectNextTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        selectTab((selectedIndex + delta + tabs.count) % tabs.count)
    }

    private func showSelectedTab() {
        guard let tab = currentTab, let window else { return }
        for other in tabs where other !== tab && other.viewController.view.superview != nil {
            other.workspace?.willDetach()
            other.viewController.view.removeFromSuperview()
        }
        let view = tab.viewController.view
        if view.superview == nil {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }
        rootView.layoutSubtreeIfNeeded()
        switch tab.content {
        case let .welcome(welcome):
            welcome.reloadRecents()
            welcome.takeFocus()
        case let .repository(workspace):
            workspace.didAttach(to: window)
            workspace.setKeyboardMode(keyboardMode)
            workspace.focus(.graph)
            workspace.refreshChrome()
        }
        updateTabBar()
        saveSession()
    }

    private func updateTabBar() {
        tabBar.update(
            items: tabs.map { TabBarView.Item(title: $0.title, detail: $0.root.map { SettingsFile.displayPath(for: $0) }) },
            selectedIndex: selectedIndex
        )
        window?.title = currentTab.map { "Soprano Git — \($0.title)" } ?? "Soprano Git"
    }

    private func saveSession() {
        guard persistsState, pendingOpens == 0 else { return }
        let roots = tabs.compactMap(\.root)
        let selectedRoot = currentTab?.root
        let selected = selectedRoot.flatMap { root in roots.firstIndex(of: root) } ?? 0
        state.saveTabs(roots, selected: selected)
    }

    // MARK: - Opening repositories

    /// Opens `url` as a repository tab: replaces the current welcome tab (or
    /// adds a tab), or selects the tab already showing it. Errors go to a
    /// dialog (git missing: the welcome screen) unless `reportErrors` is false.
    @discardableResult
    func openRepository(at url: URL, inNewTab: Bool = false, reportErrors: Bool = true, select: Bool = true) async -> Bool {
        if let existing = tabs.firstIndex(where: { $0.root?.standardizedFileURL == url.standardizedFileURL }) {
            if select { selectTab(existing) }
            return true
        }
        let repository: Repository
        do {
            repository = try await RepositoryOpener.open(url)
        } catch {
            guard reportErrors else { return false }
            let message = RepositoryController.message(for: error)
            if let error = error as? GitSetupError, error == .gitNotFound, let welcome = currentTab?.welcome {
                welcome.errorMessage = message
            } else {
                await Dialogs.alert(title: "Can't Open Repository", message: message, in: window)
            }
            return false
        }
        if let existing = tabs.firstIndex(where: { $0.root == repository.root }) {
            if select { selectTab(existing) }
            return true
        }
        let controller = RepositoryController(repository: repository)
        let workspace = RepoWorkspaceViewController(controller: controller, state: state)
        workspace.performCommand = { [weak self] id in self?.perform(id) }
        workspace.commandContext = { [weak self] in self?.commandContext() }
        let tab = WorkspaceTab(content: .repository(workspace))
        if !inNewTab, let current = currentTab, current.welcome != nil {
            current.viewController.view.removeFromSuperview()
            current.content = .repository(workspace)
        } else {
            tabs.append(tab)
        }
        state.noteOpened(repository.root)
        if select {
            let index = tabs.firstIndex(where: { $0.workspace === workspace }) ?? tabs.count - 1
            selectTab(index)
        } else {
            updateTabBar()
        }
        return true
    }

    func showOpenPanel() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Git repository"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                _ = await self?.openRepository(at: url)
            }
        }
    }

    // MARK: - Commands

    func commandContext() -> CommandContext {
        let firstResponder = window?.firstResponder
        // Read-only text views (diff text) take single keys; editable ones type them.
        let isTextInput = (firstResponder as? NSTextView)?.isEditable == true
            || (firstResponder as? NSTextField)?.isEditable == true
        var focus: FocusRegion?
        switch currentTab?.content {
        case let .repository(workspace)?:
            focus = workspace.focusedRegion
        case let .welcome(welcome)?:
            if let view = RepoWorkspaceViewController.responderView(firstResponder), view.isDescendant(of: welcome.view) {
                focus = .welcome
            }
        case nil:
            break
        }
        return CommandContext(window: window, workspace: currentWorkspace, focus: focus, isTextInput: isTextInput)
    }

    @discardableResult
    func perform(_ id: String) -> Bool {
        let ran = CommandRegistry.shared.perform(id, in: commandContext())
        currentWorkspace?.refreshChrome()
        return ran
    }

    // MARK: - Palette and sheets

    func showPalette() {
        guard let window else { return }
        let context = commandContext()
        let settings = SettingsCenter.shared
        let items = CommandRegistry.shared.commands
            .filter { $0.inPalette && $0.isEnabled(context) }
            .map { command in
                CommandItem(
                    id: command.id,
                    icon: command.icon,
                    label: command.title,
                    description: command.category.rawValue,
                    shortcut: settings.shortcutText(for: command.id),
                    searchText: command.id,
                    action: { [weak self] in
                        self?.perform(command.id)
                    }
                )
            }
        palette.show(relativeTo: window, commands: items)
    }

    func showRecentPicker() {
        guard let window else { return }
        let open = Set(tabs.compactMap { $0.root?.path })
        let items = state.recentRepositories.map { url in
            CommandItem(
                id: url.path,
                icon: open.contains(url.path) ? "folder.fill" : "folder",
                label: url.lastPathComponent,
                description: SettingsFile.displayPath(for: url),
                shortcut: nil,
                searchText: url.path,
                action: { [weak self] in
                    Task { @MainActor in
                        _ = await self?.openRepository(at: url, inNewTab: self?.currentTab?.welcome == nil)
                    }
                }
            )
        }
        palette.show(relativeTo: window, commands: items, placeholder: "Search recent repositories...")
    }

    func showShortcuts() {
        guard let window else { return }
        shortcutSheet.show(relativeTo: window)
    }

    /// Panels (palette, shortcut sheet) currently shown over the window.
    var visibleChildPanels: [NSWindow] {
        (window?.childWindows ?? []).filter(\.isVisible)
    }

    // MARK: - Window delegate

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        if window?.inLiveResize == false { saveFrame() }
    }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        saveSession()
        router.stopMonitoring()
        tabs.forEach { $0.workspace?.close() }
    }

    private func saveFrame() {
        guard persistsState, let window, !window.styleMask.contains(.fullScreen) else { return }
        MainWindowFrameStore.save(window.frame, to: state.defaults)
    }
}

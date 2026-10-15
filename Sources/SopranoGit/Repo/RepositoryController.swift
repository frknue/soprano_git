import AppKit
import SopranoGitCore

/// What the commit panel shows and the graph highlights.
enum RepoSelection: Hashable, Sendable {
    case workingCopy
    case commit(String)
    case stash(Int)
}

/// The diff that fills the center area in place of the graph until closed.
struct OpenDiff: Hashable, Sendable {
    var target: DiffTarget
    /// Display title, normally the file path.
    var title: String
}

/// Running and finished git operations of one tab, newest last.
@MainActor
final class ActivityLog {
    enum Outcome: Equatable, Sendable {
        case running
        case succeeded
        case failed(String)
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let startedAt: Date
        var finishedAt: Date?
        /// Latest progress line (fetch/pull/push).
        var progress: String?
        var outcome: Outcome
    }

    static let capacity = 200

    private(set) var entries: [Entry] = []

    var running: Entry? { entries.last(where: { $0.outcome == .running }) }
    var latest: Entry? { entries.last }

    func begin(_ title: String) -> UUID {
        let entry = Entry(id: UUID(), title: title, startedAt: Date(), finishedAt: nil, progress: nil, outcome: .running)
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        return entry.id
    }

    func progress(_ id: UUID, _ line: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].progress = line
    }

    func finish(_ id: UUID, _ outcome: Outcome) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].outcome = outcome
        entries[index].finishedAt = Date()
    }
}

/// Per-tab state store: loads and refreshes repository data, owns the shared
/// selection and open diff, and runs git operations with logging and error
/// reporting. Every view of a tab reads from it and observes its events.
///
/// Interface contract (implemented in Wave A, see docs/ARCHITECTURE.md):
/// - `start()` loads refs, stashes, status and the first page of commits, then
///   watches the worktree and git dir (FSEvents). Watch events and app
///   activation trigger a coalesced refresh: one read in flight, at most every
///   ~0.5 s; results that equal the current state emit no event.
/// - Commits are loaded `settings.graphPageSize` at a time with stash bases as
///   extra tips; a refs change that moves any tip reloads from the top
///   (`.commits(reset: true)`), `loadMoreCommits()` appends (`reset: false`).
/// - Selection defaults to `.workingCopy` when the tree is dirty, else HEAD's
///   commit; a selected commit/stash that disappears falls back the same way.
/// - `run` logs to `activity`, emits `.activity`, refreshes `refresh` parts on
///   success AND failure (a failed merge still changes status), and returns
///   whether the operation succeeded. Failures emit `.failed(title:message:)`.
@MainActor
final class RepositoryController {
    enum Event: Equatable, Sendable {
        case refs
        case stashes
        case status
        case commits(reset: Bool)
        case selection
        case openDiff
        case activity
        case failed(title: String, message: String)
    }

    struct RefreshParts: OptionSet, Sendable {
        let rawValue: Int
        static let refs = RefreshParts(rawValue: 1 << 0)
        static let stashes = RefreshParts(rawValue: 1 << 1)
        static let status = RefreshParts(rawValue: 1 << 2)
        static let commits = RefreshParts(rawValue: 1 << 3)
        static let all: RefreshParts = [.refs, .stashes, .status, .commits]
    }

    let repository: Repository
    let activity = ActivityLog()

    private(set) var refs: RefSnapshot = .empty
    private(set) var stashes: [Stash] = []
    private(set) var status: WorkingTreeStatus = .clean
    private(set) var commits: [Commit] = []
    private(set) var hasMoreCommits = false
    private(set) var isLoadingCommits = false
    private(set) var selection: RepoSelection = .workingCopy
    private(set) var openDiff: OpenDiff?

    /// The first full load finished (refs, stashes, status, first page).
    private(set) var hasLoaded = false
    /// Last load error (e.g. git vanished); nil once a refresh succeeds.
    private(set) var loadError: String?

    var displayName: String { repository.root.lastPathComponent }

    /// Commits per page (settings `graph.pageSize`).
    var pageSize: () -> Int = { SettingsCenter.shared.settings.graphPageSize }
    /// Minimum spacing between automatic (watch/activation) refreshes.
    var minimumRefreshInterval: Duration = .milliseconds(500)

    private let observers = ObserverList<Event>()
    private var watcher: FileSystemWatcher?
    private var activationObserver: NSObjectProtocol?
    private var isStarted = false
    /// Refresh cycles run so far (one git read round each); tests observe coalescing.
    private(set) var refreshCycleCount = 0

    // Refresh coalescing: one read in flight; requests made meanwhile merge
    // into the next cycle.
    private var pendingParts: RefreshParts = []
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []
    private var isRefreshing = false
    private var scheduledRefresh: Task<Void, Never>?
    private var lastRefreshStart: ContinuousClock.Instant?
    /// Tips the loaded commits were read from; a change reloads from the top.
    private var loadedTips: [String]?
    /// Bumped on every reset so a stale page never appends.
    private var commitsGeneration = 0
    /// Stash commit id behind `.stash(index)` selection, to detect a shifted list.
    private var selectedStashID: String?
    private var didChooseInitialSelection = false

    init(repository: Repository) {
        self.repository = repository
    }

    func start() {
        start(watching: true)
    }

    /// `watching: false` skips FSEvents and app-activation refreshes (tests).
    func start(watching: Bool) {
        guard !isStarted else { return }
        isStarted = true
        Task { @MainActor [weak self] in
            await self?.refreshNow(.all)
        }
        guard watching else { return }
        startWatching()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(.all)
            }
        }
    }

    func stop() {
        isStarted = false
        watcher?.stop()
        watcher = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
    }

    /// Handlers fire on the main actor until `owner` is deallocated or removed.
    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (Event) -> Void) {
        observers.add(owner, handler)
    }

    func removeObserver(_ owner: AnyObject) {
        observers.remove(owner)
    }

    /// Requests a coalesced refresh: at most one read in flight and at most one
    /// cycle per `minimumRefreshInterval`.
    func refresh(_ parts: RefreshParts = .all) {
        pendingParts.formUnion(parts)
        scheduleRefresh(throttled: true)
    }

    /// Refreshes `parts` now (merged with any pending request) and returns once
    /// a cycle that started after this call has finished.
    func refreshNow(_ parts: RefreshParts = .all) async {
        pendingParts.formUnion(parts)
        await withCheckedContinuation { continuation in
            pendingWaiters.append(continuation)
            scheduleRefresh(throttled: false)
        }
    }

    func loadMoreCommits() {
        guard hasMoreCommits, !isLoadingCommits, loadedTips != nil else { return }
        isLoadingCommits = true
        let generation = commitsGeneration
        let skip = commits.count
        let limit = max(1, pageSize())
        let stashBases = stashBaseTips
        let repository = repository
        Task { @MainActor [weak self] in
            let result = await Self.capture { try await repository.log(limit: limit, skip: skip, extraTips: stashBases) }
            guard let self else { return }
            self.isLoadingCommits = false
            guard generation == self.commitsGeneration else { return }
            switch result {
            case let .success(page):
                let known = Set(self.commits.map(\.id))
                let fresh = page.filter { !known.contains($0.id) }
                self.hasMoreCommits = page.count == limit
                guard !fresh.isEmpty else { return }
                self.commits.append(contentsOf: fresh)
                self.emit(.commits(reset: false))
            case let .failure(error):
                self.hasMoreCommits = false
                self.loadError = Self.message(for: error)
            }
        }
    }

    func select(_ selection: RepoSelection) {
        guard selection != self.selection else { return }
        self.selection = selection
        if case let .stash(index) = selection {
            selectedStashID = stashes.first(where: { $0.index == index })?.id
        } else {
            selectedStashID = nil
        }
        didChooseInitialSelection = true
        emit(.selection)
    }

    func showDiff(_ diff: OpenDiff?) {
        guard diff != openDiff else { return }
        openDiff = diff
        emit(.openDiff)
    }

    @discardableResult
    func run(
        _ title: String,
        refresh: RefreshParts = .all,
        _ operation: @escaping @Sendable (Repository, _ progress: @escaping @Sendable (String) -> Void) async throws -> Void
    ) async -> Bool {
        let id = activity.begin(title)
        emit(.activity)
        let progress: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self, self.activity.entries.contains(where: { $0.id == id && $0.outcome == .running }) else { return }
                self.activity.progress(id, line)
                self.emit(.activity)
            }
        }
        let repository = repository
        let succeeded: Bool
        do {
            try await operation(repository, progress)
            activity.finish(id, .succeeded)
            succeeded = true
            emit(.activity)
        } catch {
            let message = Self.message(for: error)
            activity.finish(id, .failed(message))
            succeeded = false
            emit(.activity)
            emit(.failed(title: title, message: message))
        }
        if !refresh.isEmpty {
            await refreshNow(refresh)
        }
        return succeeded
    }

    // MARK: - Refresh cycle

    private func scheduleRefresh(throttled: Bool) {
        guard !isRefreshing else { return } // the running cycle picks pending work up
        if !throttled {
            scheduledRefresh?.cancel()
            scheduledRefresh = nil
            startCycle()
            return
        }
        guard scheduledRefresh == nil else { return }
        var delay = Duration.zero
        if let lastRefreshStart {
            let elapsed = ContinuousClock.now - lastRefreshStart
            if elapsed < minimumRefreshInterval { delay = minimumRefreshInterval - elapsed }
        }
        scheduledRefresh = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            self.scheduledRefresh = nil
            guard !self.isRefreshing else { return }
            self.startCycle()
        }
    }

    private func startCycle() {
        guard !pendingParts.isEmpty || !pendingWaiters.isEmpty else { return }
        let parts = pendingParts.isEmpty ? RefreshParts.all : pendingParts
        let waiters = pendingWaiters
        pendingParts = []
        pendingWaiters = []
        isRefreshing = true
        lastRefreshStart = .now
        refreshCycleCount += 1
        Task { @MainActor [weak self] in
            guard let self else {
                waiters.forEach { $0.resume() }
                return
            }
            await self.performRefresh(parts)
            self.isRefreshing = false
            waiters.forEach { $0.resume() }
            if !self.pendingWaiters.isEmpty {
                self.startCycle()
            } else if !self.pendingParts.isEmpty {
                self.scheduleRefresh(throttled: true)
            }
        }
    }

    private struct Snapshot: Sendable {
        var refs: RefSnapshot?
        var stashes: [Stash]?
        var status: WorkingTreeStatus?
        var error: String?
    }

    private func performRefresh(_ parts: RefreshParts) async {
        let repository = repository
        // Commits depend on tips, so a commits check needs fresh refs and stashes.
        let needsRefs = parts.contains(.refs) || parts.contains(.commits) || !hasLoaded
        let needsStashes = parts.contains(.stashes) || parts.contains(.commits) || !hasLoaded
        let needsStatus = parts.contains(.status) || !hasLoaded

        async let refsResult = needsRefs ? Self.capture { try await repository.refs() } : nil
        async let stashesResult = needsStashes ? Self.capture { try await repository.stashes() } : nil
        async let statusResult = needsStatus ? Self.capture { try await repository.status() } : nil
        let (newRefs, newStashes, newStatus) = await (refsResult, stashesResult, statusResult)

        var errors: [String] = []
        var events: [Event] = []

        if let newRefs {
            switch newRefs {
            case let .success(value):
                if value != refs {
                    refs = value
                    events.append(.refs)
                }
            case let .failure(error): errors.append(Self.message(for: error))
            }
        }
        if let newStashes {
            switch newStashes {
            case let .success(value):
                if value != stashes {
                    stashes = value
                    events.append(.stashes)
                }
            case let .failure(error): errors.append(Self.message(for: error))
            }
        }
        if let newStatus {
            switch newStatus {
            case let .success(value):
                if value != status {
                    status = value
                    events.append(.status)
                }
            case let .failure(error): errors.append(Self.message(for: error))
            }
        }

        // Reload commits from the top when any tip moved (or on first load).
        let tips = currentTips
        if errors.isEmpty, loadedTips != tips || !hasLoaded {
            let limit = max(1, pageSize())
            let stashBases = stashBaseTips
            commitsGeneration += 1
            let generation = commitsGeneration
            isLoadingCommits = true
            let result = await Self.capture { try await repository.log(limit: limit, skip: 0, extraTips: stashBases) }
            if generation == commitsGeneration {
                isLoadingCommits = false
                switch result {
                case let .success(page):
                    loadedTips = tips
                    hasMoreCommits = page.count == limit
                    if page != commits || !hasLoaded {
                        commits = page
                        events.append(.commits(reset: true))
                    }
                case let .failure(error):
                    errors.append(Self.message(for: error))
                }
            }
        }

        loadError = errors.first
        let firstLoad = !hasLoaded && errors.isEmpty
        if firstLoad { hasLoaded = true }
        if updateSelectionAfterRefresh(firstLoad: firstLoad) {
            events.append(.selection)
        }
        for event in events {
            emit(event)
        }
        if let error = errors.first, !hasLoaded {
            emit(.failed(title: "Load \(displayName)", message: error))
        }
    }

    /// Every commit the graph starts from; ordering is stable for comparison.
    private var currentTips: [String] {
        var tips = Set<String>()
        if let head = refs.headCommit { tips.insert(head) }
        refs.localBranches.forEach { tips.insert($0.target) }
        refs.remoteBranches.forEach { tips.insert($0.target) }
        refs.tags.forEach { tips.insert($0.target) }
        stashes.forEach { tips.insert($0.base) }
        return tips.sorted()
    }

    private var stashBaseTips: [String] {
        var seen = Set<String>()
        return stashes.map(\.base).filter { seen.insert($0).inserted }
    }

    /// Applies the default selection on first load and the fallback when the
    /// selected commit or stash disappeared. Returns whether it changed.
    private func updateSelectionAfterRefresh(firstLoad: Bool) -> Bool {
        let fallback: RepoSelection = {
            if !status.isClean { return .workingCopy }
            if let head = refs.headCommit { return .commit(head) }
            return .workingCopy
        }()

        var next = selection
        if firstLoad && !didChooseInitialSelection {
            next = fallback
        } else {
            switch selection {
            case .workingCopy:
                break
            case let .commit(id):
                if hasLoaded, !commits.contains(where: { $0.id == id }), !isLoadingCommits {
                    next = fallback
                }
            case let .stash(index):
                let stash = stashes.first(where: { $0.index == index })
                if stash == nil || (selectedStashID != nil && stash?.id != selectedStashID) {
                    if let selectedStashID, let moved = stashes.first(where: { $0.id == selectedStashID }) {
                        next = .stash(moved.index)
                    } else {
                        next = fallback
                    }
                }
            }
        }
        if firstLoad { didChooseInitialSelection = true }
        guard next != selection else { return false }
        selection = next
        if case let .stash(index) = next {
            selectedStashID = stashes.first(where: { $0.index == index })?.id
        } else {
            selectedStashID = nil
        }
        return true
    }

    private func emit(_ event: Event) {
        observers.notify(event)
    }

    static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    // MARK: - Watching

    private func startWatching() {
        var paths = [repository.root.path]
        for directory in [repository.gitDirectory, repository.commonDirectory] {
            let path = directory.path
            if !paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                paths.append(path)
            }
        }
        let objectDirectories = [repository.gitDirectory, repository.commonDirectory]
            .map { Self.realPath($0.appendingPathComponent("objects").path) }
        watcher = FileSystemWatcher(paths: paths) { [weak self] changed, needsRescan in
            guard let self else { return }
            if needsRescan || changed.contains(where: { !Self.isIgnoredChange($0, objectDirectories: objectDirectories) }) {
                self.refresh([.refs, .stashes, .status, .commits])
            }
        }
    }

    /// Churn that never changes what the app shows: object writes, lock files,
    /// and build/dependency output. `objectDirectories` are the real paths of
    /// the git dirs' `objects` folders (linked worktrees keep them outside `.git`).
    nonisolated static func isIgnoredChange(_ path: String, objectDirectories: [String] = []) -> Bool {
        if path.hasSuffix(".lock") { return true }
        if objectDirectories.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for index in components.indices.dropLast() where components[index] == ".git" && components[index + 1] == "objects" {
            return true
        }
        return components.contains(".build") || components.contains("node_modules")
    }

    nonisolated static func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

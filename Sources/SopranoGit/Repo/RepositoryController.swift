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

    var displayName: String { repository.root.lastPathComponent }

    init(repository: Repository) {
        self.repository = repository
    }

    func start() {}

    func stop() {}

    /// Handlers fire on the main actor until `owner` is deallocated or removed.
    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (Event) -> Void) {}

    func removeObserver(_ owner: AnyObject) {}

    func refresh(_ parts: RefreshParts = .all) {}

    func loadMoreCommits() {}

    func select(_ selection: RepoSelection) {}

    func showDiff(_ diff: OpenDiff?) {}

    @discardableResult
    func run(
        _ title: String,
        refresh: RefreshParts = .all,
        _ operation: @escaping @Sendable (Repository, _ progress: @escaping @Sendable (String) -> Void) async throws -> Void
    ) async -> Bool {
        false
    }
}

import Foundation
import SopranoGitCore

/// One graph row: what it shows plus how its lanes are drawn.
struct GraphEntry: Sendable {
    let node: GraphNode
    let layout: GraphLayout.Row
}

/// The graph's rows, built page by page from the controller's commits, stashes and
/// working copy with `GraphSequence` + `GraphLayout`. Rows never change once appended;
/// a different working copy or stash list means a new model.
struct GraphRowModel: Sendable {
    /// Where the working-copy row goes.
    enum WorkingCopy: Sendable, Hashable {
        /// Clean tree: no row.
        case none
        /// Dirty tree on top of a commit.
        case onHead(String)
        /// Dirty tree on an unborn branch: a lone row with no line.
        case unborn
    }

    private(set) var entries: [GraphEntry] = []
    /// Row by node id (commit id, stash commit id, `GraphNode.workingCopyID`).
    private var indexByID: [String: Int] = [:]
    /// Row by stash index (`stash@{N}`).
    private var stashRows: [Int: Int] = [:]
    private var sequence: GraphSequence
    private var layout = GraphLayout()

    let workingCopy: WorkingCopy
    let stashes: [Stash]
    /// Controller commits consumed so far (duplicates included); the next append starts here.
    private(set) var commitCount = 0
    private var finished = false

    init(stashes: [Stash], workingCopy: WorkingCopy) {
        self.stashes = stashes
        self.workingCopy = workingCopy
        if case let .onHead(head) = workingCopy {
            sequence = GraphSequence(stashes: stashes, workingCopyParent: head)
        } else {
            sequence = GraphSequence(stashes: stashes, workingCopyParent: nil)
        }
        if workingCopy == .unborn {
            let row = GraphLayout.Row(
                id: GraphNode.workingCopyID, kind: .workingCopy, lane: 0, edges: [], laneCount: 1, maxLaneCount: 1
            )
            add(GraphEntry(node: .workingCopy(head: ""), layout: row))
        }
    }

    /// A model holding `commits` as its first page.
    init(commits: [Commit], stashes: [Stash], workingCopy: WorkingCopy, isComplete: Bool) {
        self.init(stashes: stashes, workingCopy: workingCopy)
        append(commits, isComplete: isComplete)
    }

    var count: Int { entries.count }
    /// The last page was appended; stashes left over sit at the bottom.
    var isComplete: Bool { finished }
    /// Lanes the widest row so far needs.
    var maxLaneCount: Int { entries.last?.layout.maxLaneCount ?? 0 }
    var hasWorkingCopyRow: Bool { indexByID[GraphNode.workingCopyID] != nil }

    /// Appends the next page of commits (consecutive slice of the same log). Returns the
    /// new rows' range; earlier rows are untouched.
    @discardableResult
    mutating func append(_ commits: [Commit], isComplete: Bool) -> Range<Int> {
        let start = entries.count
        guard !finished else { return start ..< start }
        commitCount += commits.count
        let nodes = sequence.append(commits, isComplete: isComplete)
        if isComplete { finished = true }
        let rows = layout.append(nodes)
        entries.reserveCapacity(start + nodes.count)
        indexByID.reserveCapacity(start + nodes.count)
        for (node, row) in zip(nodes, rows) {
            add(GraphEntry(node: node, layout: row))
        }
        return start ..< entries.count
    }

    private mutating func add(_ entry: GraphEntry) {
        let index = entries.count
        entries.append(entry)
        indexByID[entry.node.id] = index
        if case let .stash(stash) = entry.node.content {
            stashRows[stash.index] = index
        }
    }

    // MARK: - Lookup

    func row(forID id: String) -> Int? { indexByID[id] }

    func row(for selection: RepoSelection) -> Int? {
        switch selection {
        case .workingCopy: indexByID[GraphNode.workingCopyID]
        case let .commit(id): indexByID[id]
        case let .stash(index): stashRows[index]
        }
    }

    func selection(at row: Int) -> RepoSelection? {
        guard entries.indices.contains(row) else { return nil }
        switch entries[row].node.content {
        case .workingCopy: return .workingCopy
        case let .commit(commit): return .commit(commit.id)
        case let .stash(stash): return .stash(stash.index)
        }
    }

    // MARK: - Branch navigation

    /// Row of the first parent (working copy → HEAD, stash → its base), when loaded.
    func firstParentRow(of row: Int) -> Int? {
        guard entries.indices.contains(row), let parent = entries[row].node.parents.first else { return nil }
        return indexByID[parent]
    }

    /// Nearest row above `row` that has it as a parent, preferring one on the same lane
    /// (the line that continues straight up); else the nearest child on any lane.
    func childRow(of row: Int) -> Int? {
        guard entries.indices.contains(row) else { return nil }
        let id = entries[row].node.id
        let lane = entries[row].layout.lane
        var nearest: Int?
        var index = row - 1
        while index >= 0 {
            let entry = entries[index]
            if entry.node.parents.contains(id) {
                if entry.layout.lane == lane { return index }
                if nearest == nil { nearest = index }
            }
            index -= 1
        }
        return nearest
    }
}

/// Case-insensitive commit search over graph rows: summary, author name and email, and
/// object id prefix (stash rows match on their message and id).
enum GraphSearch {
    /// The query as matched; nil when it has nothing to look for.
    static func normalized(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func matches(_ entry: GraphEntry, query: String) -> Bool {
        switch entry.node.content {
        case .workingCopy:
            return false
        case let .commit(commit):
            return idMatches(commit.id, query)
                || commit.summary.range(of: query, options: .caseInsensitive) != nil
                || commit.author.name.range(of: query, options: .caseInsensitive) != nil
                || commit.author.email.range(of: query, options: .caseInsensitive) != nil
        case let .stash(stash):
            return idMatches(stash.id, query) || stash.message.range(of: query, options: .caseInsensitive) != nil
        }
    }

    /// Rows in `range` whose entry matches, ascending.
    static func matchingRows(in entries: [GraphEntry], range: Range<Int>, query: String) -> [Int] {
        var rows: [Int] = []
        for index in range where matches(entries[index], query: query) {
            rows.append(index)
        }
        return rows
    }

    private static func idMatches(_ id: String, _ query: String) -> Bool {
        guard query.count <= id.count else { return false }
        return id.range(of: query, options: [.caseInsensitive, .anchored]) != nil
    }
}

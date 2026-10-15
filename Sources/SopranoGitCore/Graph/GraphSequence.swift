import Foundation

/// Turns pages of commits (in `git log --date-order`, as loaded) plus the stash list and
/// the working copy into the graph's ordered node list, one page at a time.
///
/// Order rules:
/// - The working-copy row comes first (parent = HEAD) when `workingCopyParent` is set.
/// - Each stash comes right before the first commit whose committer date is older than
///   the stash's date, and always before its base commit (so clock skew can't put a stash
///   below the commit it was made on). Several stashes due at the same commit come newest
///   first.
/// - Stashes still pending when a page is appended with `isComplete: true` (base never
///   loaded, or older than every commit) come after the last commit.
///
/// Pages are consecutive slices of the same log: every call returns only the new nodes,
/// so `GraphLayout.append` can take them as they are. A commit id seen on an earlier
/// page is skipped.
///
/// ```swift
/// var sequence = GraphSequence(stashes: stashes, workingCopyParent: isDirty ? headID : nil)
/// var layout = GraphLayout()
/// let nodes = sequence.append(page, isComplete: !hasMore)
/// let rows = layout.append(nodes)   // rows[i] draws nodes[i]
/// ```
public struct GraphSequence: Sendable {
    /// Stashes not emitted yet, newest first.
    private var pending: [Stash]
    /// Base commit ids of `pending`, for the before-its-base rule.
    private var pendingBases: Set<String>
    private var workingCopyParent: String?
    private var seen: Set<String> = []
    public private(set) var isComplete = false

    /// - Parameters:
    ///   - stashes: every stash (`git stash list`), any order.
    ///   - workingCopyParent: HEAD's commit id when the worktree is dirty; nil = no
    ///     working-copy row.
    public init(stashes: [Stash], workingCopyParent: String?) {
        pending = stashes.sorted { $0.date != $1.date ? $0.date > $1.date : $0.index < $1.index }
        pendingBases = Set(stashes.map(\.base))
        self.workingCopyParent = workingCopyParent
    }

    /// The nodes for the next page of commits. `isComplete` = this is the last page; the
    /// remaining stashes are appended after it. Calls after completion return `[]`.
    public mutating func append(_ commits: [Commit], isComplete: Bool) -> [GraphNode] {
        guard !self.isComplete else { return [] }
        var nodes: [GraphNode] = []
        nodes.reserveCapacity(commits.count + pending.count + 1)
        if let head = workingCopyParent {
            nodes.append(.workingCopy(head: head))
            workingCopyParent = nil
        }
        seen.reserveCapacity(seen.count + commits.count)
        for commit in commits {
            guard seen.insert(commit.id).inserted else { continue }
            if !pending.isEmpty, pending[0].date > commit.committer.date || pendingBases.contains(commit.id) {
                emitStashes(before: commit, into: &nodes)
            }
            nodes.append(.commit(commit))
        }
        if isComplete {
            nodes.append(contentsOf: pending.map(GraphNode.stash))
            pending = []
            pendingBases = []
            self.isComplete = true
        }
        return nodes
    }

    /// Emits, newest first, every pending stash newer than `commit` or based on it.
    private mutating func emitStashes(before commit: Commit, into nodes: inout [GraphNode]) {
        var kept: [Stash] = []
        for stash in pending {
            if stash.date > commit.committer.date || stash.base == commit.id {
                nodes.append(.stash(stash))
            } else {
                kept.append(stash)
            }
        }
        pending = kept
        pendingBases = Set(kept.map(\.base))
    }
}

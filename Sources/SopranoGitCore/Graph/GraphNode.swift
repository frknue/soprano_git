import Foundation

/// What a graph row shows; decides the node glyph.
public enum GraphNodeKind: Sendable, Hashable {
    /// A commit with zero or one parent.
    case commit
    /// A commit with two or more parents.
    case merge
    /// The uncommitted changes row on top of the graph.
    case workingCopy
    /// A stash entry, drawn next to the commit it was made on.
    case stash
}

/// One row of the commit graph in display order, produced by `GraphSequence` and laid out
/// by `GraphLayout`. `id`, `parents` and `kind` are derived from `content`.
public struct GraphNode: Sendable, Hashable, Identifiable {
    public enum Content: Sendable, Hashable {
        /// Uncommitted changes on top of `head` (the HEAD commit id).
        case workingCopy(head: String)
        case commit(Commit)
        case stash(Stash)
    }

    /// Node id of the working-copy row. Never collides with an object id (not hex).
    public static let workingCopyID = "working-copy"

    public let content: Content
    /// The commit or stash commit id, or `workingCopyID`.
    public let id: String
    /// Ids of the nodes this node's lines lead to, first parent first. The working copy's
    /// only parent is HEAD; a stash's only parent is its base commit (its index and
    /// untracked-files commits are not part of the graph).
    public let parents: [String]
    public let kind: GraphNodeKind

    public init(_ content: Content) {
        self.content = content
        switch content {
        case let .workingCopy(head):
            id = Self.workingCopyID
            parents = [head]
            kind = .workingCopy
        case let .commit(commit):
            id = commit.id
            parents = commit.parents
            kind = commit.parents.count > 1 ? .merge : .commit
        case let .stash(stash):
            id = stash.id
            parents = [stash.base]
            kind = .stash
        }
    }

    public static func workingCopy(head: String) -> GraphNode { GraphNode(.workingCopy(head: head)) }
    public static func commit(_ commit: Commit) -> GraphNode { GraphNode(.commit(commit)) }
    public static func stash(_ stash: Stash) -> GraphNode { GraphNode(.stash(stash)) }

    /// Working-copy and stash rows: their lines are drawn dashed.
    public var isVirtual: Bool { kind == .workingCopy || kind == .stash }
}

import Foundation

/// GitKraken-style lane layout for the commit graph. Feed it the nodes from
/// `GraphSequence` page by page; each `append` returns one `Row` per node, in order, and
/// never changes rows it returned before.
///
/// # Drawing a row
///
/// Every row is self-contained: it lists all lines crossing it, so a table can draw
/// each row on its own. Coordinates, with `laneSpacing` (14 pt) and `rowHeight` (28 pt):
///
/// - Lane `i` is the vertical line at `x(i) = leadingInset + (Double(i) + 0.5) * laneSpacing`.
/// - Row-local `y`: `top = 0`, `mid = rowHeight / 2` (node center), `bottom = rowHeight`.
/// - The node sits at `(x(row.lane), mid)`.
/// - `.passThrough`: `(x(from), top) → (x(to), bottom)`; always `from == to`, a vertical line.
/// - `.intoNode`: `(x(from), top) → (x(row.lane), mid)`; `to == row.lane`.
/// - `.outOfNode`: `(x(row.lane), mid) → (x(to), bottom)`; `from == row.lane`.
///
/// When `from != to`, draw a cubic Bézier with vertical tangents at both ends:
/// control points `(x(from), yMid)` and `(x(to), yMid)` with `yMid = (y0 + y1) / 2`.
/// Lines cross row boundaries only vertically and only at lane centers: whatever leaves a
/// row's bottom at lane `i` enters the next row's top at lane `i`, so rows join seamlessly.
/// Draw edges first, then the node on top.
///
/// Color: `palette[colorLane % palette.count]`. Dashed edges belong to the working copy or
/// a stash; keep the dash phase tied to absolute `y` (row index × row height) so dashes
/// continue across rows.
///
/// Size: `row.laneCount` lanes are used in that row (trailing free lanes dropped);
/// `row.maxLaneCount` is the running maximum through that row, for sizing the column.
///
/// # Rules
///
/// - Lanes are fixed columns; a lane's color is its index. Lanes never move sideways;
///   freed lanes are reused by the next allocation (leftmost free first).
/// - A node takes the leftmost lane expecting it as a first parent (a commit's first
///   parent, or the working copy's HEAD); else the leftmost lane expecting it as a merge
///   parent; else the leftmost lane a stash is waiting in; else a new lane (a branch tip).
///   Every other lane expecting it converges into it (an `.intoNode` edge in the ending
///   lane's color) and ends. Branches sharing a parent therefore stay straight in their
///   own lanes until the parent's row.
/// - A node's first parent always continues straight down the node's own lane. Every
///   further parent (merges) bends into the solid lane already expecting it (in that
///   lane's color), else into a newly allocated lane.
/// - The working copy and stashes (virtual nodes) are side lines: the lane each opens is
///   dashed down to its parent. Merge lines never join a dashed lane.
/// - Parents not loaded yet keep their lane open past the last row; the next `append`
///   continues it.
public struct GraphLayout: Sendable {
    /// One line segment inside a row. See `GraphLayout` for the coordinates.
    /// Stored in 16 bytes: a row carries one edge per open lane.
    public struct Edge: Sendable, Hashable {
        public enum Span: UInt8, Sendable, Hashable {
            /// Top edge → bottom edge, straight down lane `from` (`from == to`).
            case passThrough
            /// Top edge at lane `from` → the node (`to` = node lane).
            case intoNode
            /// The node (`from` = node lane) → bottom edge at lane `to`.
            case outOfNode
        }

        public let span: Span
        public let isDashed: Bool
        private let storedFrom: Int32
        private let storedTo: Int32
        private let storedColorLane: Int32

        public var from: Int { Int(storedFrom) }
        public var to: Int { Int(storedTo) }
        /// Lane whose palette color the edge uses.
        public var colorLane: Int { Int(storedColorLane) }

        public init(_ span: Span, from: Int, to: Int, colorLane: Int, isDashed: Bool = false) {
            self.span = span
            self.isDashed = isDashed
            storedFrom = Int32(from)
            storedTo = Int32(to)
            storedColorLane = Int32(colorLane)
        }
    }

    /// Everything needed to draw one node's row.
    public struct Row: Sendable, Hashable {
        /// The node's id (`GraphNode.id`).
        public var id: String
        public var kind: GraphNodeKind
        /// Lane of the node; also its color lane.
        public var lane: Int
        /// Lines entering at the top (`.passThrough` / `.intoNode`) in ascending `from`
        /// order, then `.outOfNode` edges, one per parent in parent order.
        public var edges: [Edge]
        /// Lanes this row uses: 1 + the highest lane touched by the node or any edge.
        public var laneCount: Int
        /// Maximum `laneCount` of this and every earlier row.
        public var maxLaneCount: Int

        public init(id: String, kind: GraphNodeKind, lane: Int, edges: [Edge], laneCount: Int, maxLaneCount: Int) {
            self.id = id
            self.kind = kind
            self.lane = lane
            self.edges = edges
            self.laneCount = laneCount
            self.maxLaneCount = maxLaneCount
        }
    }

    /// Why a lane is waiting for its commit. Lower raw value = stronger claim on the node.
    private enum Claim: UInt8 {
        /// A commit's first parent: the branch continues here.
        case firstParent
        /// The working copy's HEAD (dashed; the working copy's branch continues here).
        case workingCopy
        /// A merge's second or later parent.
        case mergeParent
        /// A stash's base (dashed side line).
        case stash

        var isDashed: Bool { self == .workingCopy || self == .stash }

        /// Placement precedence: first-parent lines beat merge lines beat stash lines.
        var rank: Int {
            switch self {
            case .firstParent, .workingCopy: 0
            case .mergeParent: 1
            case .stash: 2
            }
        }
    }

    private struct Lane: Sendable {
        /// Id of the node this lane runs down to.
        var expected: String
        var claim: Claim
        /// Next lane waiting for the same id, or -1: the lanes waiting for one id form a
        /// chain starting at `waiting[id]`.
        var nextWaiting = -1
        /// Set while the node it waits for is being placed.
        var converges = false

        init(expected: String, claim: Claim) {
            self.expected = expected
            self.claim = claim
        }
    }

    /// Open lanes after the last row; nil = free slot. No trailing nils.
    private var lanes: [Lane?] = []
    /// First lane of the chain waiting for each id. Several lanes can wait for the same
    /// commit (branches sharing a parent); they converge at its row.
    private var waiting: [String: Int] = [:]

    /// Maximum `laneCount` over every row so far; size the graph column with it.
    public private(set) var maxLaneCount = 0
    /// Lanes still open below the last row (lines to parents not loaded yet).
    public var openLaneCount: Int { lanes.count }

    public init() {}

    /// Lays out the next nodes below the ones appended before. `rows[i]` belongs to
    /// `nodes[i]`; earlier rows stay valid.
    public mutating func append(_ nodes: [GraphNode]) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(nodes.count)
        for node in nodes {
            rows.append(place(node))
        }
        return rows
    }

    private mutating func place(_ node: GraphNode) -> Row {
        let topCount = lanes.count
        let nodeLane: Int
        if let first = waiting.removeValue(forKey: node.id) {
            nodeLane = bestLane(from: first, solidOnly: false)!
            var index = first
            while index >= 0 {
                lanes[index]!.converges = true
                index = lanes[index]!.nextWaiting
            }
        } else {
            nodeLane = freeSlot()
        }

        var edges: [Edge] = []
        edges.reserveCapacity(topCount + node.parents.count)

        // Lines entering at the top: pass through, or converge into the node.
        for index in 0 ..< topCount {
            guard let lane = lanes[index] else { continue }
            let dashed = lane.claim.isDashed
            if lane.converges {
                edges.append(Edge(.intoNode, from: index, to: nodeLane, colorLane: index, isDashed: dashed))
                lanes[index] = nil
            } else {
                edges.append(Edge(.passThrough, from: index, to: index, colorLane: index, isDashed: dashed))
            }
        }

        // Lines leaving at the bottom, one per parent. The first parent always continues
        // in the node's lane; further parents join a solid lane already waiting for them.
        for (position, parent) in node.parents.enumerated() {
            if position == 0 {
                let claim: Claim = switch node.kind {
                case .workingCopy: .workingCopy
                case .stash: .stash
                case .commit, .merge: .firstParent
                }
                open(nodeLane, Lane(expected: parent, claim: claim))
                edges.append(Edge(.outOfNode, from: nodeLane, to: nodeLane, colorLane: nodeLane, isDashed: claim.isDashed))
            } else if let first = waiting[parent], let target = bestLane(from: first, solidOnly: true) {
                edges.append(Edge(.outOfNode, from: nodeLane, to: target, colorLane: target))
            } else {
                let lane = freeSlot()
                open(lane, Lane(expected: parent, claim: .mergeParent))
                edges.append(Edge(.outOfNode, from: nodeLane, to: lane, colorLane: lane))
            }
        }

        while let last = lanes.last, last == nil {
            lanes.removeLast()
        }
        let laneCount = max(topCount, lanes.count, nodeLane + 1)
        maxLaneCount = max(maxLaneCount, laneCount)
        return Row(id: node.id, kind: node.kind, lane: nodeLane, edges: edges, laneCount: laneCount, maxLaneCount: maxLaneCount)
    }

    /// The strongest claim in the chain of lanes starting at `first`, leftmost on ties.
    /// `solidOnly` skips dashed lanes, so a merge line never continues as a working-copy or
    /// stash line.
    private func bestLane(from first: Int, solidOnly: Bool) -> Int? {
        var best: Int?
        var bestRank = Int.max
        var index = first
        while index >= 0 {
            let lane = lanes[index]!
            if !(solidOnly && lane.claim.isDashed),
               lane.claim.rank < bestRank || (lane.claim.rank == bestRank && index < best!) {
                best = index
                bestRank = lane.claim.rank
            }
            index = lane.nextWaiting
        }
        return best
    }

    /// Leftmost free lane index; may be `lanes.count` (a new lane on the right).
    private mutating func freeSlot() -> Int {
        var index = 0
        while index < lanes.count {
            if lanes[index] == nil { return index }
            index += 1
        }
        lanes.append(nil)
        return index
    }

    private mutating func open(_ index: Int, _ lane: Lane) {
        if index == lanes.count { lanes.append(nil) }
        var lane = lane
        lane.nextWaiting = waiting.updateValue(index, forKey: lane.expected) ?? -1
        lanes[index] = lane
    }
}

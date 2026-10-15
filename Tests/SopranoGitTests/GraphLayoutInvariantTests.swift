import AppKit
import Testing
@testable import SopranoGitCore

/// Seeded random commit histories for the graph invariant and performance tests.
struct RandomHistory {
    /// SplitMix64: small, fast, identical on every run for the same seed.
    struct Generator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }

        mutating func objectID() -> String {
            let digits = Array("0123456789abcdef")
            var id = ""
            id.reserveCapacity(40)
            for _ in 0 ..< 40 { id.append(digits[below(16)]) }
            return id
        }
    }

    /// Newest first (date order).
    var commits: [Commit]
    var stashes: [Stash]
    var head: String

    /// - Parameters:
    ///   - mergePercent: share of commits that merge another branch head (a few are octopus merges).
    ///   - branchPercent: share of commits that start a new branch off a recent commit.
    ///   - rootPercent: share of commits starting a new root; half of them point to a parent
    ///     that is never loaded (shallow history).
    init(seed: UInt64, count: Int, mergePercent: Int, branchPercent: Int, rootPercent: Int, stashCount: Int) {
        var random = Generator(seed: seed)
        var oldestFirst: [Commit] = []
        oldestFirst.reserveCapacity(count)
        var heads: [Int] = []
        for index in 0 ..< count {
            let id = random.objectID()
            let roll = random.below(100)
            var parents: [String] = []
            if heads.isEmpty || roll < rootPercent {
                if random.below(2) == 0 { parents = ["missing-\(index)"] }
                heads.append(index)
            } else if roll < rootPercent + branchPercent {
                let base = max(0, index - 1 - random.below(60))
                parents = [oldestFirst[base].id]
                heads.append(index)
            } else {
                let slot = random.below(heads.count)
                parents = [oldestFirst[heads[slot]].id]
                heads[slot] = index
                if roll < rootPercent + branchPercent + mergePercent, heads.count > 1 {
                    let extra = heads.count > 3 && random.below(10) == 0 ? 2 : 1
                    var others: [Int] = []
                    while others.count < extra {
                        let other = (slot + 1 + random.below(heads.count - 1)) % heads.count
                        if !others.contains(other) { others.append(other) }
                    }
                    parents += others.map { oldestFirst[heads[$0]].id }
                    let ended = others.filter { _ in random.below(3) > 0 }
                    heads = heads.indices.filter { !ended.contains($0) }.map { heads[$0] }
                }
                if heads.count > 40 { heads.removeFirst() }
            }
            let date = Date(timeIntervalSince1970: TimeInterval(1_600_000_000 + index * 60))
            let signature = Signature(name: "Random", email: "random@example.com", date: date)
            oldestFirst.append(Commit(id: id, parents: parents, author: signature, committer: signature, summary: "c\(index)"))
        }
        commits = oldestFirst.reversed()
        stashes = (0 ..< stashCount).map { index in
            let base = oldestFirst[random.below(oldestFirst.count)]
            let offset = TimeInterval(random.below(6000)) - 600
            return Stash(index: index, id: random.objectID(), base: base.id, message: "stash \(index)",
                         date: base.committer.date.addingTimeInterval(offset))
        }
        stashes.append(Stash(index: stashCount, id: random.objectID(), base: "never-loaded", message: "orphan",
                             date: Date(timeIntervalSince1970: 1_600_000_000 + TimeInterval(count * 30))))
        head = oldestFirst[heads[heads.count / 2]].id
    }

    /// Sequences the history in pages of `pageSize` commits.
    func nodes(pageSize: Int) -> [[GraphNode]] {
        var sequence = GraphSequence(stashes: stashes, workingCopyParent: head)
        var pages: [[GraphNode]] = []
        var start = 0
        repeat {
            let end = min(start + pageSize, commits.count)
            pages.append(sequence.append(Array(commits[start ..< end]), isComplete: end == commits.count))
            start = end
        } while start < commits.count
        return pages
    }
}

struct GraphLayoutInvariantTests {
    private typealias Edge = GraphLayout.Edge

    @Test(arguments: [UInt64(1), 7, 42, 2024])
    func randomHistoriesKeepEveryLineContinuousAndReachItsParent(seed: UInt64) {
        let history = RandomHistory(
            seed: seed, count: 2000, mergePercent: 12, branchPercent: 10, rootPercent: 1, stashCount: 6
        )
        var layout = GraphLayout()
        let pages = history.nodes(pageSize: 300)
        let nodes = pages.flatMap { $0 }
        let rows = pages.flatMap { layout.append($0) }

        // Every commit, every stash and the working copy appear exactly once.
        #expect(nodes.count == history.commits.count + history.stashes.count + 1)
        #expect(Set(nodes.map(\.id)).count == nodes.count)
        #expect(rows.map(\.id) == nodes.map(\.id))
        #expect(rows.first?.kind == .workingCopy)
        #expect(rows.contains { $0.laneCount > 3 })
        // The history really contains the hard cases.
        let ids = Set(nodes.map(\.id))
        #expect(nodes.filter { $0.kind == .stash }.count == history.stashes.count)
        #expect(nodes.contains { $0.parents.count > 2 })
        #expect(nodes.filter { $0.kind == .commit && $0.parents.isEmpty }.count > 1)
        #expect(nodes.contains { $0.parents.contains { !ids.contains($0) } })

        // Row shape: edges attach to the node's lane, nothing passes under the node.
        var runningMax = 0
        for row in rows {
            let touched = row.edges.flatMap { [$0.from, $0.to] } + [row.lane]
            runningMax = max(runningMax, row.laneCount)
            #expect(row.laneCount == touched.max()! + 1)
            #expect(row.maxLaneCount == runningMax)
            for edge in row.edges {
                switch edge.span {
                case .passThrough: #expect(edge.from == edge.to && edge.from != row.lane)
                case .intoNode: #expect(edge.to == row.lane)
                case .outOfNode: #expect(edge.from == row.lane)
                }
            }
        }

        // Continuity: what leaves a row's bottom at lane i enters the next row's top at lane i.
        let tops = rows.map(Self.topEdges)
        #expect(tops[0].allSatisfy { $0 == nil })
        for index in rows.indices.dropLast() {
            let bottomLanes = Set(rows[index].edges.filter { $0.span != .intoNode }.map(\.to))
            let topLanes = Set(tops[index + 1].indices.filter { tops[index + 1][$0] != nil })
            #expect(bottomLanes == topLanes, "row \(index)")
            for edge in rows[index].edges where edge.span == .passThrough {
                #expect(tops[index + 1][edge.from]?.isDashed == edge.isDashed, "row \(index) lane \(edge.from)")
            }
        }

        // Reachability: each parent's line runs down its lane into that parent's row, or
        // to the bottom of the last row when the parent was never loaded.
        let rowOf = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        for (index, node) in nodes.enumerated() {
            let outgoing = rows[index].edges.filter { $0.span == .outOfNode }
            #expect(outgoing.count == node.parents.count)
            // The first parent always continues straight down the node's own lane.
            #expect(outgoing.first.map { $0.to == rows[index].lane } ?? true, "\(node.id) first parent")
            for (parent, edge) in zip(node.parents, outgoing) {
                #expect(edge.isDashed == node.isVirtual)
                var lane = edge.to
                var reached: Int?
                var below = index + 1
                while below < rows.count, reached == nil {
                    guard let top = tops[below][safe: lane] ?? nil else { break }
                    if top.span == .intoNode { reached = below } else { lane = top.to }
                    below += 1
                }
                if let reached {
                    #expect(rows[reached].id == parent, "\(node.id) → \(parent)")
                } else {
                    #expect(below == rows.count && rowOf[parent] == nil, "\(node.id) → \(parent) lost at row \(below)")
                }
            }
        }
    }

    /// The row's top-edge edges indexed by lane.
    private static func topEdges(_ row: GraphLayout.Row) -> [Edge?] {
        var byLane = [Edge?](repeating: nil, count: row.laneCount)
        for edge in row.edges where edge.span != .outOfNode {
            byLane[edge.from] = edge
        }
        return byLane
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

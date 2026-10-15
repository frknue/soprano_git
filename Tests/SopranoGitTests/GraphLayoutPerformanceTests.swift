import AppKit
import Testing
@testable import SopranoGitCore

struct GraphLayoutPerformanceTests {
    /// About 0.25 s alone; the bound leaves room for the parallel test run while
    /// still failing on accidental quadratic work (minutes at this size).
    @Test func layingOutOneHundredThousandCommitsStaysLinear() {
        let history = RandomHistory(
            seed: 99, count: 100_000, mergePercent: 10, branchPercent: 8, rootPercent: 0, stashCount: 20
        )
        let merges = history.commits.filter(\.isMerge).count
        #expect(merges > 9_000 && merges < 11_000)

        let clock = ContinuousClock()
        var pages: [[GraphNode]] = []
        let sequencing = clock.measure { pages = history.nodes(pageSize: 2000) }
        var rows: [GraphLayout.Row] = []
        var layout = GraphLayout()
        let layingOut = clock.measure {
            for page in pages { rows += layout.append(page) }
        }

        print("GraphLayout 100k: layout \(layingOut), sequence \(sequencing), merges \(merges), max lanes \(layout.maxLaneCount)")
        #expect(rows.count == history.commits.count + history.stashes.count + 1)
        #expect(layingOut < .seconds(5))
    }
}

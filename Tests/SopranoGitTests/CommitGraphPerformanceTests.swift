import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct CommitGraphPerformanceTests {
    private func microseconds(_ duration: Duration, per count: Int) -> Double {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return seconds / Double(max(1, count)) * 1_000_000
    }

    @Test func oneHundredThousandRowsBuildQuicklyAndScrollCheaply() async throws {
        let history = RandomHistory(seed: 11, count: 100_000, mergePercent: 10, branchPercent: 8, rootPercent: 0, stashCount: 20)
        let clock = ContinuousClock()

        var model = GraphRowModel(stashes: history.stashes, workingCopy: .onHead(history.head))
        let building = clock.measure {
            var start = 0
            while start < history.commits.count {
                let end = min(start + 2000, history.commits.count)
                model.append(Array(history.commits[start ..< end]), isComplete: end == history.commits.count)
                start = end
            }
        }
        #expect(model.count == history.commits.count + history.stashes.count + 1)

        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        let graph = CommitGraphViewController(controller: RepositoryController(repository: repository))
        graph.defaults = UserDefaults(suiteName: "com.soprano.git.tests.\(UUID().uuidString)")!
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 1100, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = graph.view
        graph.view.layoutSubtreeIfNeeded()
        graph.replaceRows(with: model)
        graph.view.layoutSubtreeIfNeeded()
        #expect(graph.tableView.numberOfRows == model.count)

        // Our part of showing a row: configuring all six cells (fresh views, so this is
        // the upper bound; scrolling reuses them), for rows spread over the history.
        let sample = Array(stride(from: 0, to: model.count, by: 50))
        let allColumns = CommitGraphViewController.Column.allCases
        var cells: [[NSView]] = []
        cells.reserveCapacity(sample.count)
        let configuring = clock.measure {
            for row in sample {
                cells.append(allColumns.compactMap { graph.configuredCell(column: $0, row: row) })
            }
        }

        // Drawing the lane, refs and message cells into one reused bitmap.
        let widths: [CGFloat] = [170, 200, 400]
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 28, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let drawing = clock.measure {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for row in cells {
                for (index, cell) in row.prefix(3).enumerated() {
                    cell.frame = NSRect(x: 0, y: 0, width: widths[index], height: GraphMetrics.rowHeight)
                    cell.draw(cell.bounds)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // End to end through AppKit: jump a screen and a bit at a time across the whole
        // history, so every step replaces every visible row (cells reused).
        let visibleRows = graph.tableView.rows(in: graph.tableView.visibleRect).length
        #expect(visibleRows > 20)
        let targets = Array(stride(from: visibleRows + 10, to: model.count, by: 300))
        let scrolling = clock.measure {
            for row in targets {
                graph.tableView.scroll(NSPoint(x: 0, y: graph.tableView.rect(ofRow: row).minY))
                graph.tableView.layoutSubtreeIfNeeded()
            }
        }
        let shown = graph.tableView.rows(in: graph.tableView.visibleRect)
        #expect(graph.tableView.view(atColumn: 2, row: shown.location + 1, makeIfNecessary: false) != nil)

        let configureCost = microseconds(configuring, per: sample.count)
        let drawCost = microseconds(drawing, per: sample.count)
        let scrollCost = microseconds(scrolling, per: targets.count * visibleRows)
        print(String(
            format: "CommitGraph 100k: build %@ (max lanes %d); %d rows: configure %.1f µs/row (6 cells), draw %.1f µs/row (lanes+refs+message); scroll %d screens: %.1f µs/row incl. AppKit tiling",
            "\(building)", model.maxLaneCount, sample.count, configureCost, drawCost, targets.count, scrollCost
        ))
        #expect(building < .milliseconds(2500))
        #expect(configureCost < 80)
        #expect(drawCost < 400)
        #expect(scrollCost < 1000)
    }
}

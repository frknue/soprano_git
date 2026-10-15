import AppKit
import SopranoGitCore

/// How the diff list shows a hunk's lines: one column of old and new lines
/// (`unified`), or the old file on the left and the new one on the right
/// (`split`). App-wide, persisted in `AppStateStore.diffLayout`.
enum DiffLayout: String, Sendable {
    case unified
    case split

    var toggled: DiffLayout { self == .unified ? .split : .unified }
    var title: String { self == .unified ? "Unified" : "Split" }
}

/// One file's diff flattened into list rows: a header row per hunk followed
/// by its lines, capped at `lineLimit` lines. Files without text hunks
/// (binary, rename only, mode change, empty) carry a one-line `notice`.
/// Both layouts' rows are built once per load, off the main thread.
struct DiffDocument: Equatable, Sendable {
    enum Row: Hashable, Sendable {
        /// Header of `file.hunks[index]`.
        case hunk(Int)
        /// `file.hunks[hunk].lines[line]` (unified layout).
        case line(hunk: Int, line: Int)
        /// Split layout: `file.hunks[hunk].lines[old]` on the left and
        /// `…lines[new]` on the right; nil is a filler cell on that side.
        case pair(hunk: Int, old: Int?, new: Int?)
        /// A muted note inside the list (mode change, truncation).
        case notice(String)
    }

    static let lineLimit = 20_000

    var file: FileDiff?
    /// Unified layout rows.
    var rows: [Row]
    /// Row index of each listed hunk's header; hunks past the cap are absent.
    var hunkRows: [Int]
    /// Split layout rows: the same hunks and notices, lines paired side by side.
    var splitRows: [Row]
    var splitHunkRows: [Int]
    /// Replaces the list when the file has nothing to show line by line.
    var notice: String?
    var totalLines: Int
    var isTruncated: Bool
    var additions: Int
    var deletions: Int

    static let empty = DiffDocument(
        file: nil, rows: [], hunkRows: [], splitRows: [], splitHunkRows: [], notice: nil, totalLines: 0,
        isTruncated: false, additions: 0, deletions: 0
    )

    /// Number of hunks the list shows (and j/k visits).
    var hunkCount: Int { hunkRows.count }

    func rows(in layout: DiffLayout) -> [Row] {
        layout == .unified ? rows : splitRows
    }

    func hunkRows(in layout: DiffLayout) -> [Int] {
        layout == .unified ? hunkRows : splitHunkRows
    }

    /// The file titled `title` (new or old path), else the only/first file.
    static func pick(_ files: [FileDiff], title: String) -> FileDiff? {
        files.first(where: { $0.newPath == title || $0.oldPath == title }) ?? files.first
    }

    /// Picks the file titled `title` (new or old path), else the only/first file.
    static func build(files: [FileDiff], title: String, lineLimit: Int = DiffDocument.lineLimit) -> DiffDocument {
        guard let file = pick(files, title: title) else {
            var document = DiffDocument.empty
            document.notice = "No changes."
            return document
        }
        var additions = 0
        var deletions = 0
        var totalLines = 0
        for hunk in file.hunks {
            totalLines += hunk.lines.count
            for line in hunk.lines {
                switch line.kind {
                case .added: additions += 1
                case .removed: deletions += 1
                case .context, .noNewlineMarker: break
                }
            }
        }
        var document = DiffDocument(
            file: file, rows: [], hunkRows: [], splitRows: [], splitHunkRows: [], notice: nil, totalLines: totalLines,
            isTruncated: false, additions: additions, deletions: deletions
        )
        if file.isBinary {
            document.notice = "Binary file. There is no text diff to show."
            return document
        }
        let modeChange = modeChangeText(file)
        if file.hunks.isEmpty {
            document.notice = emptyNotice(for: file, modeChange: modeChange)
            return document
        }
        var rows: [Row] = []
        rows.reserveCapacity(min(totalLines, lineLimit) + file.hunks.count + 2)
        if let modeChange {
            rows.append(.notice(modeChange))
        }
        var hunkRows: [Int] = []
        var shown = 0
        hunks: for (hunkIndex, hunk) in file.hunks.enumerated() {
            guard shown < lineLimit else {
                document.isTruncated = true
                break
            }
            hunkRows.append(rows.count)
            rows.append(.hunk(hunkIndex))
            for lineIndex in hunk.lines.indices {
                guard shown < lineLimit else {
                    document.isTruncated = true
                    break hunks
                }
                rows.append(.line(hunk: hunkIndex, line: lineIndex))
                shown += 1
            }
        }
        if document.isTruncated {
            rows.append(.notice(
                "Large diff: showing the first \(lineLimit.formatted()) of \(totalLines.formatted()) lines."
            ))
        }
        document.rows = rows
        document.hunkRows = hunkRows
        (document.splitRows, document.splitHunkRows) = splitRows(from: rows, file: file)
        return document
    }

    /// Soprano's side-by-side pairing over the unified rows (so the line cap
    /// applies identically): context lines face themselves; in each change
    /// block (removed lines, then added lines) the n-th removed line faces the
    /// n-th added one and the shorter side gets fillers. A "no newline" marker
    /// stays on the side of the line it follows (both sides after context).
    static func splitRows(from rows: [Row], file: FileDiff) -> (rows: [Row], hunkRows: [Int]) {
        var result: [Row] = []
        result.reserveCapacity(rows.count)
        var hunkRows: [Int] = []
        var removed: [Int] = []
        var added: [Int] = []
        var blockHunk = 0
        var previous: DiffLine.Kind?
        func flush() {
            for pair in 0..<max(removed.count, added.count) {
                result.append(.pair(
                    hunk: blockHunk,
                    old: pair < removed.count ? removed[pair] : nil,
                    new: pair < added.count ? added[pair] : nil
                ))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        for row in rows {
            switch row {
            case .hunk:
                flush()
                previous = nil
                hunkRows.append(result.count)
                result.append(row)
            case .notice:
                flush()
                result.append(row)
            case .pair:
                result.append(row)
            case let .line(hunk, index):
                let kind = file.hunks[hunk].lines[index].kind
                switch kind {
                case .context:
                    flush()
                    result.append(.pair(hunk: hunk, old: index, new: index))
                case .removed:
                    // A removed line after added ones starts the next block.
                    if !added.isEmpty { flush() }
                    blockHunk = hunk
                    removed.append(index)
                case .added:
                    blockHunk = hunk
                    added.append(index)
                case .noNewlineMarker:
                    switch previous {
                    case .removed: removed.append(index)
                    case .added: added.append(index)
                    case .context, .noNewlineMarker, nil:
                        flush()
                        result.append(.pair(hunk: hunk, old: index, new: index))
                    }
                    continue
                }
                previous = kind
            }
        }
        flush()
        return (result, hunkRows)
    }

    private static func modeChangeText(_ file: FileDiff) -> String? {
        guard let old = file.oldMode, let new = file.newMode, old != new else { return nil }
        return "File mode changed from \(old) to \(new)."
    }

    private static func emptyNotice(for file: FileDiff, modeChange: String?) -> String {
        switch file.kind {
        case .renamed, .copied:
            let verb = file.kind == .renamed ? "Renamed" : "Copied"
            let move = "\(file.oldPath ?? "?") → \(file.newPath ?? "?")"
            if let modeChange { return "\(verb) \(move). \(modeChange)" }
            return "\(verb) without content changes: \(move)."
        case .added where modeChange == nil:
            return "Empty file added."
        case .deleted where modeChange == nil:
            return "Empty file deleted."
        default:
            return modeChange ?? "No content changes."
        }
    }

    /// The hunk a row belongs to.
    func hunk(ofRow row: Int, in layout: DiffLayout = .unified) -> Int? {
        let rows = rows(in: layout)
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case let .hunk(index): return index
        case let .line(hunk, _), let .pair(hunk, _, _): return hunk
        case .notice: return nil
        }
    }

    /// The hunk as unified-diff text (header line plus prefixed lines), for copying.
    func text(ofHunk index: Int) -> String? {
        guard let file, file.hunks.indices.contains(index) else { return nil }
        let hunk = file.hunks[index]
        var lines = [Self.header(of: hunk)]
        for line in hunk.lines {
            switch line.kind {
            case .context: lines.append(" " + line.text)
            case .added: lines.append("+" + line.text)
            case .removed: lines.append("-" + line.text)
            case .noNewlineMarker: lines.append("\\ No newline at end of file")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func header(of hunk: DiffHunk) -> String {
        let range = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        return hunk.section.isEmpty ? range : range + " " + hunk.section
    }
}

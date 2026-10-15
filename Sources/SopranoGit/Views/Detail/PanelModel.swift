import AppKit
import SopranoGitCore

/// A group of files in the commit panel's list.
enum PanelSection: Hashable, Sendable {
    case conflicts
    case unstaged
    case staged
    /// The files of a commit or stash.
    case files

    var title: String {
        switch self {
        case .conflicts: "Conflicts"
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        case .files: "Files"
        }
    }
}

/// One file row of the commit panel.
struct PanelFile: Hashable, Sendable {
    var section: PanelSection
    var path: String
    /// Rename/copy source.
    var oldPath: String?
    var kind: ChangeKind
    var additions: Int?
    var deletions: Int?
    var conflict: ConflictKind?

    var isUntracked: Bool { kind == .untracked }

    /// Selection identity that survives a status refresh.
    var key: Key { Key(section: section, path: path) }

    struct Key: Hashable, Sendable {
        var section: PanelSection
        var path: String
    }
}

enum PanelRow: Hashable, Sendable {
    case section(PanelSection, count: Int)
    case file(PanelFile)

    var file: PanelFile? {
        if case let .file(file) = self { return file }
        return nil
    }
}

/// What the commit panel shows.
enum PanelMode: Equatable {
    case workingCopy
    case commit(String)
    case stash(Stash)

    var selectionTarget: SelectionTarget {
        switch self {
        case .workingCopy: .workingCopy
        case let .commit(id): .commit(id)
        case let .stash(stash): .stash(stash)
        }
    }
}

enum PanelRows {
    /// CONFLICTS (only when present), UNSTAGED, STAGED.
    static func workingCopy(_ status: WorkingTreeStatus) -> [PanelRow] {
        var conflicts: [PanelRow] = []
        var unstaged: [PanelRow] = []
        var staged: [PanelRow] = []
        for entry in status.entries {
            if let conflict = entry.conflict {
                conflicts.append(.file(PanelFile(section: .conflicts, path: entry.path, kind: .unmerged, conflict: conflict)))
                continue
            }
            if let kind = entry.unstaged {
                unstaged.append(.file(PanelFile(section: .unstaged, path: entry.path, kind: kind)))
            }
            if let kind = entry.staged {
                staged.append(.file(PanelFile(section: .staged, path: entry.path, oldPath: entry.oldPath, kind: kind)))
            }
        }
        var rows: [PanelRow] = []
        if !conflicts.isEmpty {
            rows.append(.section(.conflicts, count: conflicts.count))
            rows += conflicts
        }
        rows.append(.section(.unstaged, count: unstaged.count))
        rows += unstaged
        rows.append(.section(.staged, count: staged.count))
        rows += staged
        return rows
    }

    /// FILES (n) followed by the files of a commit or stash.
    static func files(_ files: [ChangedFile]) -> [PanelRow] {
        [.section(.files, count: files.count)] + files.map { file in
            .file(PanelFile(
                section: .files, path: file.path, oldPath: file.oldPath, kind: file.kind,
                additions: file.additions, deletions: file.deletions
            ))
        }
    }

    /// The diff a file row opens in `mode`. Renames and copies of commits and
    /// stashes load the whole change set so git can pair both paths; the diff
    /// view picks the file by its title.
    static func diffTarget(for file: PanelFile, in mode: PanelMode) -> DiffTarget {
        switch file.section {
        case .conflicts, .unstaged:
            return .unstaged(path: file.path)
        case .staged:
            return .staged(path: file.path)
        case .files:
            let path: String? = file.oldPath == nil ? file.path : nil
            switch mode {
            case let .commit(id): return .commit(id: id, path: path)
            case let .stash(stash): return .stash(index: stash.index, path: path)
            case .workingCopy: return .unstaged(path: file.path)
            }
        }
    }

    /// Row of the next (`delta` > 0) or previous file from `row`, skipping
    /// section rows; nil at either end. From no selection, the first/last file.
    static func adjacentFileRow(in rows: [PanelRow], from row: Int?, delta: Int) -> Int? {
        let step = delta >= 0 ? 1 : -1
        var index: Int
        if let row, rows.indices.contains(row) {
            index = row + step
        } else {
            index = step > 0 ? 0 : rows.count - 1
        }
        while rows.indices.contains(index) {
            if rows[index].file != nil { return index }
            index += step
        }
        return nil
    }
}

/// Loads one value per key off the main actor, newest request wins: a result
/// arriving after a newer `load`/`cancel` is dropped. Results are cached
/// (least recently used out) so revisiting a commit is instant.
@MainActor
final class LatestRequestLoader<Key: Hashable & Sendable, Value: Sendable> {
    let capacity: Int
    private(set) var generation = 0
    private var cache: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    func cached(_ key: Key) -> Value? {
        cache[key]
    }

    /// Drops any request in flight.
    func cancel() {
        generation += 1
    }

    /// Calls `apply` with the value for `key` (synchronously when cached),
    /// unless a newer request started before the fetch finished.
    func load(
        _ key: Key,
        fetch: @escaping @Sendable () async throws -> Value,
        apply: @escaping @MainActor (Result<Value, Error>) -> Void
    ) {
        generation += 1
        if let value = cache[key] {
            touch(key)
            apply(.success(value))
            return
        }
        let requested = generation
        Task { @MainActor [weak self] in
            let result = await RepositoryController.capture(fetch)
            guard let self, requested == self.generation else { return }
            if case let .success(value) = result {
                self.store(value, for: key)
            }
            apply(result)
        }
    }

    private func store(_ value: Value, for key: Key) {
        cache[key] = value
        touch(key)
        while order.count > capacity {
            cache[order.removeFirst()] = nil
        }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// The composer's enabled states and labels, derived from the working copy.
struct ComposerState: Equatable {
    var stagedCount: Int
    var changeCount: Int
    var conflictCount: Int
    var isAmending: Bool
    var hasSummary: Bool
    var isBusy: Bool
    /// A merge is paused: its commit needs no staged changes.
    var isMerging = false

    var canCommit: Bool {
        hasSummary && conflictCount == 0 && !isBusy && (stagedCount > 0 || isAmending || isMerging)
    }

    var canStageAllAndCommit: Bool {
        hasSummary && conflictCount == 0 && !isBusy && (changeCount > 0 || isAmending || isMerging)
    }

    var commitTitle: String {
        let files = stagedCount == 1 ? "1 file" : "\(stagedCount) files"
        if isAmending {
            return stagedCount == 0 ? "Amend commit" : "Amend with \(files)"
        }
        if isMerging && stagedCount == 0 { return "Commit merge" }
        return stagedCount == 0 ? "Commit" : "Commit \(files)"
    }

    /// Why committing is off, shown under the message.
    var hint: String? {
        if isBusy { return nil }
        if conflictCount > 0 { return "Resolve conflicts before committing." }
        if stagedCount == 0 && !isAmending && !isMerging {
            return changeCount == 0 ? "Nothing to commit. Turn on Amend to reword HEAD." : "Stage files, or turn on Amend, to commit."
        }
        if !hasSummary { return "Write a summary to commit." }
        return nil
    }
}

/// Splits and joins commit messages for the composer.
enum CommitMessage {
    static let summaryLimit = 72

    /// `summary` + blank line + `description` (trimmed); summary only when the description is empty.
    static func join(summary: String, description: String) -> String {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? summary : summary + "\n\n" + description
    }

    /// First line → summary; the rest without leading/trailing blank lines → description.
    static func split(_ message: String) -> (summary: String, description: String) {
        let lines = message.components(separatedBy: "\n")
        let summary = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let description = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary, description)
    }

    /// git's prepared MERGE_MSG without comment lines ("#…") and surrounding blank lines.
    static func preparedMessage(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

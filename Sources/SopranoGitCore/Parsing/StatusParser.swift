import Foundation

/// Parses `git status --porcelain=v2 -z` and the files git leaves in the
/// git directory while an operation is paused.
enum StatusParser {
    /// Entries in git's order. Header (`#`) and ignored (`!`) records are skipped.
    static func parseEntries(_ data: Data) -> [StatusEntry] {
        var records = data.split(separator: 0, omittingEmptySubsequences: false)
        if records.last?.isEmpty == true { records.removeLast() }
        var entries: [StatusEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            switch record.first {
            case UInt8(ascii: "1"):
                // 1 XY sub mH mI mW hH hI path
                guard let fields = GitOutput.fields(record, separator: 0x20, count: 9) else { continue }
                let (staged, unstaged) = sides(fields[1])
                entries.append(StatusEntry(path: fields[8], staged: staged, unstaged: unstaged))
            case UInt8(ascii: "2"):
                // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
                guard let fields = GitOutput.fields(record, separator: 0x20, count: 10) else { continue }
                let oldPath = index < records.count ? String(decoding: records[index], as: UTF8.self) : nil
                index += 1
                let (staged, unstaged) = sides(fields[1])
                entries.append(StatusEntry(path: fields[9], oldPath: oldPath, staged: staged, unstaged: unstaged))
            case UInt8(ascii: "u"):
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                guard let fields = GitOutput.fields(record, separator: 0x20, count: 11) else { continue }
                entries.append(StatusEntry(path: fields[10], conflict: ConflictKind(rawValue: fields[1]) ?? .bothModified))
            case UInt8(ascii: "?"):
                entries.append(StatusEntry(path: String(decoding: record.dropFirst(2), as: UTF8.self), unstaged: .untracked))
            default:
                continue
            }
        }
        return entries
    }

    private static func sides(_ xy: String) -> (ChangeKind?, ChangeKind?) {
        let characters = Array(xy)
        guard characters.count == 2 else { return (nil, nil) }
        return (kind(characters[0]), kind(characters[1]))
    }

    private static func kind(_ character: Character) -> ChangeKind? {
        character == "." ? nil : ChangeKind(rawValue: String(character)) ?? .modified
    }

    /// The operation git has paused in `gitDirectory` (a worktree's own git dir).
    static func operation(in gitDirectory: URL) -> OperationInProgress? {
        let fileManager = FileManager.default
        func text(_ name: String) -> String? {
            let url = gitDirectory.appendingPathComponent(name)
            guard let data = fileManager.contents(atPath: url.path) else { return nil }
            let line = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return line?.isEmpty == false ? line : nil
        }
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: gitDirectory.appendingPathComponent(name).path)
        }
        func branchName(_ headName: String?) -> String? {
            guard let headName, headName != "detached HEAD" else { return nil }
            return headName.hasPrefix("refs/heads/") ? String(headName.dropFirst("refs/heads/".count)) : headName
        }

        if exists("rebase-merge") {
            return .rebase(
                headName: branchName(text("rebase-merge/head-name")),
                onto: text("rebase-merge/onto"),
                step: text("rebase-merge/msgnum").flatMap { Int($0) },
                total: text("rebase-merge/end").flatMap { Int($0) }
            )
        }
        // rebase-apply is shared with `git am`, which leaves an `applying` marker.
        if exists("rebase-apply"), !exists("rebase-apply/applying") {
            return .rebase(
                headName: branchName(text("rebase-apply/head-name")),
                onto: text("rebase-apply/onto"),
                step: text("rebase-apply/next").flatMap { Int($0) },
                total: text("rebase-apply/last").flatMap { Int($0) }
            )
        }
        if exists("MERGE_HEAD") {
            return .merge(mergingHead: text("MERGE_HEAD"))
        }
        if exists("CHERRY_PICK_HEAD") {
            return .cherryPick(commit: text("CHERRY_PICK_HEAD"))
        }
        if exists("REVERT_HEAD") {
            return .revert(commit: text("REVERT_HEAD"))
        }
        return nil
    }
}

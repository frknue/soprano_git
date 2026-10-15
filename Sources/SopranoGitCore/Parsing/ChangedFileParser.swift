import Foundation

/// Parses `git diff-tree -r -z --raw --numstat` output: raw records
/// (":<modes> <ids> <status>\0path\0[newPath\0]") followed by numstat records
/// ("<added>\t<deleted>\tpath\0", or "<added>\t<deleted>\t\0old\0new\0" for
/// renames and copies). Binary files have "-" counts.
enum ChangedFileParser {
    static func parse(_ data: Data, kindOverride: ChangeKind? = nil) -> [ChangedFile] {
        let fields = GitOutput.nulFields(data)
        var files: [ChangedFile] = []
        var indexByPath: [String: Int] = [:]
        var counts: [String: (Int?, Int?)] = [:]
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            if field.hasPrefix(":") {
                let status = field.split(separator: " ").last.map(String.init) ?? "M"
                let letter = status.first.map(String.init) ?? "M"
                let kind = ChangeKind(rawValue: letter) ?? .modified
                guard index < fields.count else { break }
                var path = fields[index]
                var oldPath: String?
                index += 1
                if kind == .renamed || kind == .copied, index < fields.count {
                    oldPath = path
                    path = fields[index]
                    index += 1
                }
                indexByPath[path] = files.count
                files.append(ChangedFile(path: path, oldPath: oldPath, kind: kindOverride ?? kind))
            } else {
                let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                let added = Int(parts[0])
                let deleted = Int(parts[1])
                var path = String(parts[2])
                if path.isEmpty {
                    // Rename/copy: old and new path follow as separate fields.
                    guard index + 1 < fields.count else { break }
                    path = fields[index + 1]
                    index += 2
                }
                counts[path] = (added, deleted)
            }
        }
        for (path, (added, deleted)) in counts {
            guard let position = indexByPath[path] else { continue }
            files[position].additions = added
            files[position].deletions = deleted
        }
        return files
    }
}

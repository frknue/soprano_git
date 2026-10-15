import Foundation

/// Parses `git log -z`, `git show -s` and `git stash list -z` output in the
/// `%x1f`-separated formats below.
enum LogParser {
    /// id, parents, author name/email/time, committer name/email/time, subject.
    static let commitFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%s"
    /// `commitFormat` plus the raw message.
    static let detailFormat = commitFormat + "%x1f%B"
    static let stashFormat = "%H%x1f%P%x1f%ct%x1f%gs"

    static func parseCommits(_ data: Data) -> [Commit] {
        GitOutput.records(data).compactMap { record in
            GitOutput.fields(record, count: 9).map(commit)
        }
    }

    /// `git show -s -z --format=<detailFormat>`: the commit and its full message.
    static func parseDetail(_ data: Data) -> (commit: Commit, message: String)? {
        guard let record = GitOutput.records(data).first,
              let fields = GitOutput.fields(record, count: 10) else { return nil }
        return (commit(Array(fields.prefix(9))), fields[9])
    }

    /// The message without its first paragraph (what `%s` shows), trimmed.
    static func body(ofMessage message: String) -> String {
        let normalized = message.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var index = lines.startIndex
        // Leading blank lines, then the subject paragraph.
        while index < lines.endIndex, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        while index < lines.endIndex, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        return lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseStashes(_ data: Data) -> [Stash] {
        GitOutput.records(data)
            .compactMap { GitOutput.fields($0, count: 4) }
            .enumerated()
            .map { index, fields in
                Stash(
                    index: index,
                    id: fields[0],
                    base: fields[1].split(separator: " ").first.map(String.init) ?? "",
                    message: fields[3],
                    date: GitOutput.date(fields[2])
                )
            }
    }

    private static func commit(_ fields: [String]) -> Commit {
        Commit(
            id: fields[0],
            parents: fields[1].split(separator: " ").map(String.init),
            author: Signature(name: fields[2], email: fields[3], date: GitOutput.date(fields[4])),
            committer: Signature(name: fields[5], email: fields[6], date: GitOutput.date(fields[7])),
            summary: fields[8]
        )
    }
}

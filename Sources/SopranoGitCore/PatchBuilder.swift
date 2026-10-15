import Foundation

/// Turns parsed hunks back into a patch `git apply` accepts. Header lines and
/// line texts are emitted verbatim (including any "\r"), so the patch matches
/// the file byte for byte; callers apply with `--recount`, which tolerates
/// hunk headers whose counts no longer match.
public enum PatchBuilder {
    /// A patch containing only `hunk` of `file`.
    public static func patch(for hunk: DiffHunk, of file: FileDiff) -> Data {
        patch(for: [hunk], of: file)
    }

    /// A patch containing `hunks` of `file`, in the order given.
    public static func patch(for hunks: [DiffHunk], of file: FileDiff) -> Data {
        var text = ""
        for line in file.headerLines {
            text += line + "\n"
        }
        for hunk in hunks {
            text += header(of: hunk) + "\n"
            for line in hunk.lines {
                switch line.kind {
                case .context: text += " " + line.text + "\n"
                case .added: text += "+" + line.text + "\n"
                case .removed: text += "-" + line.text + "\n"
                case .noNewlineMarker: text += line.text + "\n"
                }
            }
        }
        return Data(text.utf8)
    }

    /// "@@ -a,b +c,d @@ section", omitting counts of 1 like git does.
    public static func header(of hunk: DiffHunk) -> String {
        func range(_ start: Int, _ count: Int) -> String {
            count == 1 ? "\(start)" : "\(start),\(count)"
        }
        var header = "@@ -\(range(hunk.oldStart, hunk.oldCount)) +\(range(hunk.newStart, hunk.newCount)) @@"
        if !hunk.section.isEmpty { header += " " + hunk.section }
        return header
    }
}

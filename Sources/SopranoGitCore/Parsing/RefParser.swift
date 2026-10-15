import Foundation

/// Parses `git for-each-ref` and `git remote -v` output.
enum RefParser {
    static let forEachRefFormat = [
        "%(refname)", "%(objectname)", "%(*objectname)", "%(objecttype)",
        "%(upstream:short)", "%(upstream:track,nobracket)", "%(HEAD)", "%(contents:subject)",
    ].joined(separator: "%1f") + "%00"

    struct Refs: Sendable, Hashable {
        var localBranches: [Branch] = []
        var remoteBranches: [Branch] = []
        var tags: [Tag] = []
    }

    /// `remoteNames` assigns remote-tracking branches to their remote (names
    /// may contain "/"; the longest matching name wins).
    static func parseRefs(_ data: Data, remoteNames: [String]) -> Refs {
        var refs = Refs()
        let remotesByLength = remoteNames.sorted { $0.count > $1.count }
        for record in GitOutput.records(data) {
            guard let fields = GitOutput.fields(record, count: 8) else { continue }
            let fullName = fields[0]
            let object = fields[1]
            let peeled = fields[2]
            let type = fields[3]
            let upstream = fields[4].isEmpty ? nil : fields[4]
            let track = parseTrack(fields[5])
            let isHead = fields[6] == "*"
            let subject = fields[7]

            if fullName.hasPrefix("refs/heads/") {
                refs.localBranches.append(Branch(
                    name: String(fullName.dropFirst("refs/heads/".count)), fullName: fullName, target: object,
                    isRemote: false, upstream: upstream, ahead: track.ahead, behind: track.behind,
                    upstreamGone: track.gone, isHead: isHead
                ))
            } else if fullName.hasPrefix("refs/remotes/") {
                let name = String(fullName.dropFirst("refs/remotes/".count))
                if name.hasSuffix("/HEAD") { continue }
                let remote = remotesByLength.first { name.hasPrefix($0 + "/") }
                    ?? name.split(separator: "/", maxSplits: 1).first.map(String.init)
                refs.remoteBranches.append(Branch(
                    name: name, fullName: fullName, target: object, isRemote: true, remoteName: remote
                ))
            } else if fullName.hasPrefix("refs/tags/") {
                let isAnnotated = type == "tag"
                refs.tags.append(Tag(
                    name: String(fullName.dropFirst("refs/tags/".count)), fullName: fullName,
                    target: peeled.isEmpty ? object : peeled, isAnnotated: isAnnotated,
                    message: isAnnotated ? subject : nil
                ))
            }
        }
        return refs
    }

    /// `%(upstream:track,nobracket)`: "ahead 2, behind 1", "behind 3", "gone", "".
    static func parseTrack(_ text: String) -> (ahead: Int, behind: Int, gone: Bool) {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if trimmed == "gone" { return (0, 0, true) }
        var ahead = 0
        var behind = 0
        for part in trimmed.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = count } else if words[0] == "behind" { behind = count }
        }
        return (ahead, behind, false)
    }

    /// `git remote -v`: "origin\t<url> (fetch)" / "(push)" lines, in config order.
    static func parseRemotes(_ data: Data) -> [Remote] {
        var remotes: [Remote] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            var url = String(parts[1])
            var isPush = false
            if url.hasSuffix(" (push)") {
                isPush = true
                url.removeLast(" (push)".count)
            } else if url.hasSuffix(" (fetch)") {
                url.removeLast(" (fetch)".count)
            }
            let index = remotes.firstIndex { $0.name == name } ?? {
                remotes.append(Remote(name: name, fetchURL: nil, pushURL: nil))
                return remotes.count - 1
            }()
            if isPush {
                if remotes[index].pushURL == nil { remotes[index].pushURL = url }
            } else if remotes[index].fetchURL == nil {
                remotes[index].fetchURL = url
            }
        }
        return remotes
    }
}

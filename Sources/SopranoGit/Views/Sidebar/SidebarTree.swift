import Foundation
import SopranoGitCore

/// The four groups of the left panel, in display order.
enum SidebarSection: String, CaseIterable, Sendable {
    case local
    case remote
    case tags
    case stashes

    var title: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        case .tags: "Tags"
        case .stashes: "Stashes"
        }
    }
}

/// One row of the ref tree. A class so `NSOutlineView` can use it as an item;
/// `id` is stable across refreshes and is what expansion and selection key on.
final class SidebarNode {
    enum Kind {
        case section(SidebarSection, count: Int)
        case remote(String)
        case folder(String)
        case branch(Branch)
        case tag(Tag)
        case stash(Stash)
    }

    let id: String
    let kind: Kind
    /// Display name: the last path component for branches in folders.
    let title: String
    let children: [SidebarNode]

    init(id: String, kind: Kind, title: String, children: [SidebarNode] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.children = children
    }

    /// Sections, remotes and folders.
    var isGroup: Bool {
        switch kind {
        case .section, .remote, .folder: true
        case .branch, .tag, .stash: false
        }
    }

    /// What commands act on when this row is selected.
    var selectionTarget: SelectionTarget? {
        switch kind {
        case let .branch(branch): .branch(branch)
        case let .tag(tag): .tag(tag)
        case let .stash(stash): .stash(stash)
        case .section, .remote, .folder: nil
        }
    }

    static func id(for target: SelectionTarget) -> String? {
        switch target {
        case let .branch(branch): "ref:\(branch.fullName)"
        case let .tag(tag): "ref:\(tag.fullName)"
        case let .stash(stash): "stash:\(stash.id)"
        case .commit, .workingCopy: nil
        }
    }
}

/// What Enter / double-click does on a row.
enum SidebarActivation: Equatable {
    /// Local branch: switch to it; remote branch: create/switch to its tracking branch.
    case checkout(Branch)
    /// Tag: select its commit and move focus to the graph.
    case revealCommit(String)
    /// Stash: select it and move focus to the commit panel.
    case revealStash(Int)
    /// Group rows expand or collapse.
    case toggle

    static func of(_ node: SidebarNode) -> SidebarActivation {
        switch node.kind {
        case let .branch(branch): .checkout(branch)
        case let .tag(tag): .revealCommit(tag.target)
        case let .stash(stash): .revealStash(stash.index)
        case .section, .remote, .folder: .toggle
        }
    }
}

/// Builds the ref tree from a refs snapshot: sections, remote groups and
/// `/`-folders, natural-sorted, optionally filtered by a case-insensitive
/// substring of the ref name.
enum SidebarTree {
    static func sectionID(_ section: SidebarSection) -> String { "section:\(section.rawValue)" }
    static func remoteID(_ remote: String) -> String { "remote:\(remote)" }
    static func localFolderID(_ path: String) -> String { "folder:local:\(path)" }
    static func remoteFolderID(remote: String, path: String) -> String { "folder:remote:\(remote):\(path)" }

    static func build(refs: RefSnapshot, stashes: [Stash], filter: String = "") -> [SidebarNode] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let matches: (String) -> Bool = { name in
            query.isEmpty || name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let filtering = !query.isEmpty
        var sections: [SidebarNode] = []

        // Local
        let locals = refs.localBranches.filter { matches($0.name) }
        let localChildren = folderTree(
            locals.map { ($0.name, $0) },
            folderID: localFolderID
        )
        sections.append(section(.local, count: locals.count, children: localChildren))

        // Remote
        var remoteNames = refs.remotes.map(\.name)
        for branch in refs.remoteBranches {
            if let remote = branch.remoteName, !remoteNames.contains(remote) { remoteNames.append(remote) }
        }
        var remoteCount = 0
        var remoteGroups: [SidebarNode] = []
        for remote in remoteNames.sorted(by: naturalOrder) {
            let branches = refs.remoteBranches.filter { $0.remoteName == remote && matches($0.name) }
            if filtering, branches.isEmpty { continue }
            remoteCount += branches.count
            let prefix = remote + "/"
            let children = folderTree(
                branches.map { (($0.name.hasPrefix(prefix) ? String($0.name.dropFirst(prefix.count)) : $0.name), $0) },
                folderID: { remoteFolderID(remote: remote, path: $0) }
            )
            remoteGroups.append(SidebarNode(id: remoteID(remote), kind: .remote(remote), title: remote, children: children))
        }
        sections.append(section(.remote, count: remoteCount, children: remoteGroups))

        // Tags
        let tags = refs.tags.filter { matches($0.name) }.sorted { naturalOrder($0.name, $1.name) }
        sections.append(section(.tags, count: tags.count, children: tags.map {
            SidebarNode(id: "ref:\($0.fullName)", kind: .tag($0), title: $0.name)
        }))

        // Stashes (git order, newest first)
        let stashRows = stashes.filter { matches($0.message) || matches($0.reference) }.sorted { $0.index < $1.index }
        sections.append(section(.stashes, count: stashRows.count, children: stashRows.map {
            SidebarNode(id: "stash:\($0.id)", kind: .stash($0), title: $0.message)
        }))

        return filtering ? sections.filter { !$0.children.isEmpty } : sections
    }

    /// Folder ids that contain the branch, outermost first (to reveal it).
    static func ancestorIDs(of branch: Branch) -> [String] {
        var ids: [String]
        let path: String
        if branch.isRemote, let remote = branch.remoteName {
            ids = [sectionID(.remote), remoteID(remote)]
            path = branch.name.hasPrefix(remote + "/") ? String(branch.name.dropFirst(remote.count + 1)) : branch.name
        } else {
            ids = [sectionID(.local)]
            path = branch.name
        }
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return ids }
        for depth in 1..<components.count {
            let folder = components[0..<depth].joined(separator: "/")
            ids.append(branch.isRemote ? remoteFolderID(remote: branch.remoteName ?? "", path: folder) : localFolderID(folder))
        }
        return ids
    }

    /// Natural, case-insensitive order ("v2" < "v10").
    static func naturalOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func section(_ section: SidebarSection, count: Int, children: [SidebarNode]) -> SidebarNode {
        SidebarNode(id: sectionID(section), kind: .section(section, count: count), title: section.title, children: children)
    }

    /// Groups `(path, branch)` pairs into folders by `/`; folders first, then
    /// branches, each in natural order.
    private static func folderTree(_ entries: [(String, Branch)], folderID: (String) -> String) -> [SidebarNode] {
        final class Trie {
            var folders: [String: Trie] = [:]
            var leaves: [(String, Branch)] = []
        }
        let root = Trie()
        for (path, branch) in entries {
            var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let leaf = components.removeLast()
            var node = root
            for component in components {
                if let next = node.folders[component] {
                    node = next
                } else {
                    let next = Trie()
                    node.folders[component] = next
                    node = next
                }
            }
            node.leaves.append((leaf, branch))
        }
        func nodes(_ trie: Trie, prefix: String) -> [SidebarNode] {
            let folders = trie.folders.keys.sorted(by: naturalOrder).map { name -> SidebarNode in
                let path = prefix.isEmpty ? name : prefix + "/" + name
                return SidebarNode(id: folderID(path), kind: .folder(path), title: name, children: nodes(trie.folders[name]!, prefix: path))
            }
            let leaves = trie.leaves.sorted { naturalOrder($0.0, $1.0) }.map { leaf, branch in
                SidebarNode(id: "ref:\(branch.fullName)", kind: .branch(branch), title: leaf)
            }
            return folders + leaves
        }
        return nodes(root, prefix: "")
    }
}

/// Expanded/collapsed state of sections, remotes and folders, persisted per
/// repository in an injectable `UserDefaults`. Sections and remotes default to
/// expanded, folders to collapsed.
@MainActor
final class SidebarExpansionStore {
    let defaults: UserDefaults
    let key: String
    private var overrides: [String: Bool]

    init(defaults: UserDefaults, repositoryRoot: URL) {
        self.defaults = defaults
        self.key = "sidebar.expanded.\(repositoryRoot.standardizedFileURL.path)"
        self.overrides = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
    }

    func isExpanded(_ node: SidebarNode) -> Bool {
        if let value = overrides[node.id] { return value }
        switch node.kind {
        case .section, .remote: return true
        default: return false
        }
    }

    func set(_ id: String, expanded: Bool) {
        guard overrides[id] != expanded else { return }
        overrides[id] = expanded
        defaults.set(overrides, forKey: key)
    }
}

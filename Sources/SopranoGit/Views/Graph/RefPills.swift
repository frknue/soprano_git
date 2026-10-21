import Foundation
import SopranoGitCore

/// One label in the graph's BRANCH / TAG column. A local branch and its upstream (or a
/// same-named remote branch) at the same commit share one pill, like GitKraken.
struct RefPill: Hashable {
    enum Kind: Hashable {
        /// A local branch, with the remote branches merged into it.
        case branch(Branch, remotes: [Branch])
        /// A remote-tracking branch with no local partner at this commit.
        case remoteBranch(Branch)
        case tag(Tag)
        /// HEAD detached at this commit.
        case detachedHead(String)
    }

    let kind: Kind
    /// The checked-out branch (or detached HEAD): drawn as the ink pill.
    let isHead: Bool

    var name: String {
        switch kind {
        case let .branch(branch, _): branch.name
        case let .remoteBranch(branch): branch.name
        case let .tag(tag): tag.name
        case .detachedHead: "HEAD"
        }
    }

    /// Shows the laptop icon (exists locally).
    var isLocal: Bool {
        switch kind {
        case .branch, .detachedHead: true
        case .remoteBranch, .tag: false
        }
    }

    /// Shows the cloud icon (exists on a remote).
    var isRemote: Bool {
        switch kind {
        case let .branch(_, remotes): !remotes.isEmpty
        case .remoteBranch: true
        case .tag, .detachedHead: false
        }
    }

    var isTag: Bool {
        if case .tag = kind { return true }
        return false
    }

    /// What context menus and checkout act on.
    var target: SelectionTarget {
        switch kind {
        case let .branch(branch, _): .branch(branch)
        case let .remoteBranch(branch): .branch(branch)
        case let .tag(tag): .tag(tag)
        case let .detachedHead(id): .commit(id)
        }
    }

    /// Every ref name the pill stands for (tooltips).
    var refNames: [String] {
        switch kind {
        case let .branch(branch, remotes): [branch.name] + remotes.map(\.name)
        case let .remoteBranch(branch): [branch.name]
        case let .tag(tag): [tag.name]
        case .detachedHead: ["HEAD (detached)"]
        }
    }

    /// Pills per commit id, in display order: HEAD's pill first, then local branches,
    /// remote-only branches, tags (each by name).
    static func index(_ refs: RefSnapshot) -> [String: [RefPill]] {
        var byCommit: [String: [RefPill]] = [:]
        var remotesByCommit: [String: [Branch]] = [:]
        for remote in refs.remoteBranches where !remote.name.hasSuffix("/HEAD") {
            remotesByCommit[remote.target, default: []].append(remote)
        }
        var mergedRemotes = Set<String>()
        for branch in refs.localBranches.sorted(by: { $0.name < $1.name }) {
            let partners = (remotesByCommit[branch.target] ?? []).filter { remote in
                remote.name == branch.upstream || shortName(of: remote) == branch.name
            }
            partners.forEach { mergedRemotes.insert($0.fullName) }
            byCommit[branch.target, default: []].append(
                RefPill(kind: .branch(branch, remotes: partners.sorted { $0.name < $1.name }), isHead: branch.isHead)
            )
        }
        for remote in refs.remoteBranches.sorted(by: { $0.name < $1.name })
        where !remote.name.hasSuffix("/HEAD") && !mergedRemotes.contains(remote.fullName) {
            byCommit[remote.target, default: []].append(RefPill(kind: .remoteBranch(remote), isHead: false))
        }
        for tag in refs.tags.sorted(by: { $0.name < $1.name }) {
            byCommit[tag.target, default: []].append(RefPill(kind: .tag(tag), isHead: false))
        }
        if case let .detached(id) = refs.head {
            let commit = refs.headCommit ?? id
            byCommit[commit, default: []].insert(RefPill(kind: .detachedHead(commit), isHead: true), at: 0)
        }
        for (commit, pills) in byCommit where pills.contains(where: \.isHead) {
            byCommit[commit] = pills.filter(\.isHead) + pills.filter { !$0.isHead }
        }
        return byCommit
    }

    /// "main" for "origin/main".
    private static func shortName(of remote: Branch) -> String {
        guard let remoteName = remote.remoteName, remote.name.hasPrefix(remoteName + "/") else { return remote.name }
        return String(remote.name.dropFirst(remoteName.count + 1))
    }
}

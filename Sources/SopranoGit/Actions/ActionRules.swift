import AppKit
import SopranoGitCore

/// Branch and tag name checks, mirroring `git check-ref-format --branch`, with
/// one inline message per rule for the name prompts.
enum RefNameRules {
    enum Kind {
        case branch
        case tag

        var noun: String { self == .branch ? "branch" : "tag" }
        var plural: String { self == .branch ? "Branch names" : "Tag names" }
    }

    /// The message to show for `name`, or nil when git accepts it and no ref
    /// in `existing` (short names of the same kind) collides with it.
    static func validate(_ name: String, kind: Kind, existing: [String] = []) -> String? {
        let plural = kind.plural
        if name.isEmpty { return "Enter a \(kind.noun) name." }
        if name == "@" || (kind == .branch && name == "HEAD") { return "“\(name)” isn't a valid \(kind.noun) name." }
        if name.unicodeScalars.contains(where: { $0.properties.isWhitespace }) { return "\(plural) can't contain spaces." }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "\(plural) can't contain control characters."
        }
        if name.hasPrefix("-") { return "\(plural) can't start with “-”." }
        if name.contains("..") { return "\(plural) can't contain “..”." }
        if name.contains("@{") { return "\(plural) can't contain “@{”." }
        if name.contains(where: { "~^:?*[\\".contains($0) }) { return "\(plural) can't contain ~ ^ : ? * [ or \\." }
        if name.hasSuffix("/") { return "\(plural) can't end with “/”." }
        if name.hasPrefix("/") || name.contains("//") { return "\(plural) can't start with “/” or contain “//”." }
        if name.hasSuffix(".lock") { return "\(plural) can't end with “.lock”." }
        if name.hasSuffix(".") { return "\(plural) can't end with “.”." }
        let components = name.split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") }) { return "Parts of a \(kind.noun) name can't start with “.”." }
        if components.contains(where: { $0.hasSuffix(".lock") }) { return "Parts of a \(kind.noun) name can't end with “.lock”." }
        if existing.contains(name) { return "A \(kind.noun) named “\(name)” already exists." }
        if let clash = existing.first(where: { name.hasPrefix($0 + "/") || $0.hasPrefix(name + "/") }) {
            return "“\(name)” clashes with the existing \(kind.noun) “\(clash)”."
        }
        return nil
    }
}

/// A target turned into the ref a flow should act on.
enum ResolvedRef: Equatable {
    case local(Branch)
    case remote(Branch)
    case tag(Tag)
    case commit(String)

    /// Unambiguous revision for git (full ref names, so a tag and a branch of
    /// the same name never mix up).
    var revision: String {
        switch self {
        case let .local(branch), let .remote(branch): branch.fullName
        case let .tag(tag): tag.fullName
        case let .commit(id): id
        }
    }

    var displayName: String {
        switch self {
        case let .local(branch), let .remote(branch): branch.name
        case let .tag(tag): tag.name
        case let .commit(id): String(id.prefix(7))
        }
    }

    var commitID: String {
        switch self {
        case let .local(branch), let .remote(branch): branch.target
        case let .tag(tag): tag.target
        case let .commit(id): id
        }
    }

    /// Branches and tags resolve to themselves. A commit prefers the ref at it:
    /// exactly one local branch other than HEAD's, else exactly one remote
    /// branch, else the commit id itself.
    static func resolve(_ target: SelectionTarget, refs: RefSnapshot) -> ResolvedRef? {
        switch target {
        case let .branch(branch): return branch.isRemote ? .remote(branch) : .local(branch)
        case let .tag(tag): return .tag(tag)
        case let .commit(id):
            let locals = refs.localBranches.filter { $0.target == id && !$0.isHead }
            if locals.count == 1 { return .local(locals[0]) }
            let remotes = refs.remoteBranches.filter { $0.target == id }
            if remotes.count == 1 { return .remote(remotes[0]) }
            return .commit(id)
        case .workingCopy, .stash:
            return nil
        }
    }
}

/// What a checkout of a target does.
enum CheckoutPlan: Equatable {
    /// Switch to an existing local branch.
    case switchTo(String)
    /// Create a local branch tracking a remote branch.
    case track(remoteBranch: String, localName: String)
    /// Detach HEAD at a commit; `label` names it in the confirmation.
    case detach(id: String, label: String)

    /// Nil when the checkout would change nothing or the target can't be checked out.
    static func plan(for target: SelectionTarget, refs: RefSnapshot) -> CheckoutPlan? {
        switch target {
        case let .branch(branch) where !branch.isRemote:
            return branch.isHead ? nil : .switchTo(branch.name)
        case let .branch(branch):
            return remotePlan(branch, refs: refs)
        case let .tag(tag):
            let locals = refs.localBranches.filter { $0.target == tag.target && !$0.isHead }
            if locals.count == 1 { return .switchTo(locals[0].name) }
            if case .detached = refs.head, refs.headCommit == tag.target { return nil }
            return .detach(id: tag.target, label: tag.name)
        case let .commit(id):
            switch ResolvedRef.resolve(target, refs: refs) {
            case let .local(branch)?: return .switchTo(branch.name)
            case let .remote(branch)?: return remotePlan(branch, refs: refs)
            default: return id == refs.headCommit ? nil : .detach(id: id, label: String(id.prefix(7)))
            }
        case .workingCopy, .stash:
            return nil
        }
    }

    private static func remotePlan(_ branch: Branch, refs: RefSnapshot) -> CheckoutPlan? {
        let localName = RefNames.localName(of: branch)
        if let local = refs.localBranches.first(where: { $0.name == localName }) {
            return local.isHead ? nil : .switchTo(localName)
        }
        return .track(remoteBranch: branch.name, localName: localName)
    }
}

enum RefNames {
    /// "origin/feature/x" → "feature/x".
    static func localName(of remoteBranch: Branch) -> String {
        if let remote = remoteBranch.remoteName, remoteBranch.name.hasPrefix(remote + "/") {
            return String(remoteBranch.name.dropFirst(remote.count + 1))
        }
        guard let slash = remoteBranch.name.firstIndex(of: "/") else { return remoteBranch.name }
        return String(remoteBranch.name[remoteBranch.name.index(after: slash)...])
    }

    /// The checked-out branch's name, or "HEAD" when detached.
    static func current(_ refs: RefSnapshot) -> String {
        switch refs.head {
        case let .branch(name), let .unborn(name): name
        case .detached: "HEAD"
        }
    }

    /// Remote names with "origin" first, otherwise in config order.
    static func remotes(_ refs: RefSnapshot) -> [String] {
        let names = refs.remotes.map(\.name)
        guard let origin = names.firstIndex(of: "origin") else { return names }
        var ordered = names
        ordered.remove(at: origin)
        return ["origin"] + ordered
    }

    /// The remote an upstream like "origin/main" lives on.
    static func remote(ofUpstream upstream: String, refs: RefSnapshot) -> String? {
        if let remote = refs.remoteBranches.first(where: { $0.name == upstream })?.remoteName { return remote }
        return refs.remotes.map(\.name).sorted { $0.count > $1.count }.first { upstream.hasPrefix($0 + "/") }
    }
}

/// When each action applies; shared by the commands and the context menus so
/// a key and a menu item are enabled for exactly the same targets.
@MainActor
enum ActionRules {
    static func isIdle(_ controller: RepositoryController) -> Bool { controller.status.operation == nil }
    static func hasHead(_ controller: RepositoryController) -> Bool { controller.refs.headCommit != nil }
    static func hasRemotes(_ controller: RepositoryController) -> Bool { !controller.refs.remotes.isEmpty }

    static func canCheckout(_ target: SelectionTarget, _ controller: RepositoryController) -> Bool {
        isIdle(controller) && CheckoutPlan.plan(for: target, refs: controller.refs) != nil
    }

    static func canCreateBranch(_ controller: RepositoryController) -> Bool {
        isIdle(controller) && hasHead(controller)
    }

    /// Merge and rebase: a ref or commit other than HEAD's own commit.
    static func canIntegrate(_ target: SelectionTarget, _ controller: RepositoryController) -> Bool {
        guard isIdle(controller), let head = controller.refs.headCommit,
              let resolved = ResolvedRef.resolve(target, refs: controller.refs) else { return false }
        return resolved.commitID != head
    }

    static func canCherryPick(_ target: SelectionTarget, _ controller: RepositoryController) -> Bool {
        guard case let .commit(id) = target, isIdle(controller), let head = controller.refs.headCommit else { return false }
        return id != head
    }

    /// Revert and reset.
    static func canRewrite(_ target: SelectionTarget, _ controller: RepositoryController) -> Bool {
        guard case .commit = target else { return false }
        return isIdle(controller) && hasHead(controller)
    }

    /// The commit a new tag goes on: the target's commit, HEAD for the working copy.
    static func tagCommit(for target: SelectionTarget, _ controller: RepositoryController) -> String? {
        switch target {
        case .workingCopy: controller.refs.headCommit
        case .stash: nil
        case .commit, .branch, .tag: target.commitID
        }
    }

    static func canDelete(_ target: SelectionTarget) -> Bool {
        switch target {
        case let .branch(branch): branch.isRemote ? branch.remoteName != nil : !branch.isHead
        case .tag, .stash: true
        case .commit, .workingCopy: false
        }
    }

    static func localBranch(_ target: SelectionTarget?) -> Branch? {
        guard case let .branch(branch)? = target, !branch.isRemote else { return nil }
        return branch
    }

    static func canPush(_ branch: Branch, _ controller: RepositoryController) -> Bool {
        !branch.isRemote && hasRemotes(controller)
    }

    static func canSetUpstream(_ branch: Branch, _ controller: RepositoryController) -> Bool {
        !branch.isRemote && !controller.refs.remoteBranches.isEmpty
    }

    static func canPull(_ controller: RepositoryController) -> Bool {
        isIdle(controller) && controller.refs.currentBranch != nil && hasRemotes(controller)
    }

    static func canStash(_ controller: RepositoryController) -> Bool {
        isIdle(controller) && hasHead(controller) && !controller.status.isClean
    }

    static func canApplyStash(_ controller: RepositoryController) -> Bool {
        isIdle(controller) && !controller.stashes.isEmpty
    }

    static func copyText(for target: SelectionTarget) -> String? {
        switch target {
        case .workingCopy: nil
        case let .commit(id): id
        case let .stash(stash): stash.id
        case let .branch(branch): branch.name
        case let .tag(tag): tag.name
        }
    }

    /// The command target: the focused area's selection, else the shared
    /// selection (the graph's selection when the graph doesn't provide one).
    static func target(_ context: CommandContext) -> SelectionTarget? {
        if let target = context.target { return target }
        guard let controller = context.controller else { return nil }
        switch controller.selection {
        case .workingCopy: return .workingCopy
        case let .commit(id): return .commit(id)
        case let .stash(index): return controller.stashes.first(where: { $0.index == index }).map { .stash($0) }
        }
    }
}

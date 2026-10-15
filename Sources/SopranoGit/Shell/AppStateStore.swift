import Foundation

/// UI state that survives relaunch: recent repositories, open tabs,
/// workspace panel sizes, and the diff layout. Backed by an injectable
/// `UserDefaults` (the snapshot harness and tests pass a volatile suite).
@MainActor
final class AppStateStore {
    static let maxRecentRepositories = 20

    enum Key {
        static let recentRepositories = "recentRepositories"
        static let openTabs = "openTabs"
        static let selectedTab = "selectedTab"
        static let sidebarWidth = "workspace.sidebarWidth"
        static let commitPanelWidth = "workspace.commitPanelWidth"
        static let sidebarVisible = "workspace.sidebarVisible"
        static let commitPanelVisible = "workspace.commitPanelVisible"
        static let diffLayout = "diff.layout"
    }

    let defaults: UserDefaults
    private let diffLayoutObservers = ObserverList<DiffLayout>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A store on a throwaway suite (snapshot harness, tests).
    static func volatile() -> AppStateStore {
        let name = "com.soprano.git.volatile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return AppStateStore(defaults: defaults)
    }

    // MARK: - Recent repositories

    /// Most recent first, at most `maxRecentRepositories`.
    var recentRepositories: [URL] {
        (defaults.stringArray(forKey: Key.recentRepositories) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func noteOpened(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: Key.recentRepositories) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.maxRecentRepositories {
            paths.removeLast(paths.count - Self.maxRecentRepositories)
        }
        defaults.set(paths, forKey: Key.recentRepositories)
    }

    func removeRecent(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: Key.recentRepositories) ?? []
        paths.removeAll { $0 == path }
        defaults.set(paths, forKey: Key.recentRepositories)
    }

    // MARK: - Tabs

    /// Repository roots of the open tabs, in order.
    var openTabs: [URL] {
        (defaults.stringArray(forKey: Key.openTabs) ?? []).map { URL(fileURLWithPath: $0) }
    }

    var selectedTab: Int {
        defaults.integer(forKey: Key.selectedTab)
    }

    func saveTabs(_ roots: [URL], selected: Int) {
        defaults.set(roots.map { $0.standardizedFileURL.path }, forKey: Key.openTabs)
        defaults.set(max(0, selected), forKey: Key.selectedTab)
    }

    // MARK: - Workspace layout

    func width(forKey key: String, default fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(max(range.lowerBound, CGFloat(defaults.double(forKey: key))), range.upperBound)
    }

    func setWidth(_ width: CGFloat, forKey key: String) {
        defaults.set(Double(width), forKey: key)
    }

    func bool(forKey key: String, default fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: - Diff layout

    /// Unified or split, for every diff in every tab; unified by default.
    var diffLayout: DiffLayout {
        get { defaults.string(forKey: Key.diffLayout).flatMap(DiffLayout.init(rawValue:)) ?? .unified }
        set {
            guard newValue != diffLayout else { return }
            defaults.set(newValue.rawValue, forKey: Key.diffLayout)
            diffLayoutObservers.notify(newValue)
        }
    }

    /// Handlers fire after `diffLayout` changes, until `owner` is deallocated.
    func addDiffLayoutObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (DiffLayout) -> Void) {
        diffLayoutObservers.add(owner, handler)
    }
}

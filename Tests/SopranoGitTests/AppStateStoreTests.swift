import AppKit
import Testing
@testable import SopranoGit

@MainActor
struct AppStateStoreTests {
    @Test func recentRepositoriesAreNewestFirstWithoutDuplicates() {
        let store = AppStateStore.volatile()
        store.noteOpened(URL(fileURLWithPath: "/tmp/a"))
        store.noteOpened(URL(fileURLWithPath: "/tmp/b"))
        store.noteOpened(URL(fileURLWithPath: "/tmp/a/"))

        #expect(store.recentRepositories.map(\.path) == ["/tmp/a", "/tmp/b"])

        store.removeRecent(URL(fileURLWithPath: "/tmp/a"))
        #expect(store.recentRepositories.map(\.path) == ["/tmp/b"])
    }

    @Test func recentRepositoriesKeepTheTwentyNewest() {
        let store = AppStateStore.volatile()
        for index in 0..<25 {
            store.noteOpened(URL(fileURLWithPath: "/tmp/repo\(index)"))
        }

        #expect(store.recentRepositories.count == AppStateStore.maxRecentRepositories)
        #expect(store.recentRepositories.first?.path == "/tmp/repo24")
        #expect(store.recentRepositories.last?.path == "/tmp/repo5")
    }

    @Test func openTabsAndSelectionSurviveInTheInjectedDefaults() throws {
        let name = "sg-state-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        AppStateStore(defaults: defaults).saveTabs(
            [URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two")],
            selected: 1
        )
        let reloaded = AppStateStore(defaults: defaults)

        #expect(reloaded.openTabs.map(\.path) == ["/tmp/one", "/tmp/two"])
        #expect(reloaded.selectedTab == 1)
    }

    @Test func panelWidthsAreClampedToTheirRange() {
        let store = AppStateStore.volatile()
        #expect(store.width(forKey: AppStateStore.Key.sidebarWidth, default: 240, range: 180...420) == 240)
        store.setWidth(900, forKey: AppStateStore.Key.sidebarWidth)
        #expect(store.width(forKey: AppStateStore.Key.sidebarWidth, default: 240, range: 180...420) == 420)
        #expect(store.bool(forKey: AppStateStore.Key.sidebarVisible, default: true))
        store.setBool(false, forKey: AppStateStore.Key.sidebarVisible)
        #expect(!store.bool(forKey: AppStateStore.Key.sidebarVisible, default: true))
    }
}

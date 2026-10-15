import AppKit
@testable import SopranoGit
@testable import SopranoGitCore

/// Hand-written histories for graph tests, newest first like `git log --date-order`.
enum GraphHistory {
    static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func commit(
        _ id: String,
        _ parents: [String] = [],
        hour: Int,
        summary: String? = nil,
        author: String = "Ada Lovelace",
        email: String = "ada@example.com"
    ) -> Commit {
        let signature = Signature(name: author, email: email, date: baseDate.addingTimeInterval(TimeInterval(hour * 3600)))
        return Commit(id: id, parents: parents, author: signature, committer: signature, summary: summary ?? "commit \(id)")
    }

    static func stash(_ index: Int, id: String, base: String, hour: Int, message: String = "WIP on main") -> Stash {
        Stash(index: index, id: id, base: base, message: message, date: baseDate.addingTimeInterval(TimeInterval(hour * 3600)))
    }

    /// A fork and its merge:
    ///
    ///     m   merge of c and f2   (lane 0)
    ///     f2  feature             (lane 1)
    ///     c   main                (lane 0)
    ///     f1  feature             (lane 1)
    ///     b   fork point          (lane 0)
    ///     a   root
    static let forkAndMerge: [Commit] = [
        commit("m", ["c", "f2"], hour: 6, summary: "Merge branch 'feature'"),
        commit("f2", ["f1"], hour: 5, summary: "Feature: second step"),
        commit("c", ["b"], hour: 4, summary: "Main: fix crash"),
        commit("f1", ["b"], hour: 3, summary: "Feature: first step", author: "Grace Hopper", email: "grace@navy.mil"),
        commit("b", ["a"], hour: 2, summary: "Add parser"),
        commit("a", [], hour: 1, summary: "Initial commit"),
    ]
}

/// Waits on the main actor until `condition` holds (or fails the test after `timeout`).
@MainActor
func waitForGraph(_ timeout: Double = 10, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            struct Timeout: Error {}
            throw Timeout()
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

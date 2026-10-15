import AppKit
@testable import SopranoGit

/// Dialogs are app-wide (`Dialogs.current`) and suites run in parallel, so
/// every test that shows a dialog takes its turn through here.
@MainActor
enum DialogTurn {
    private static var busy = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func exclusive(_ body: @MainActor () async throws -> Void) async throws {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        try await body()
    }
}

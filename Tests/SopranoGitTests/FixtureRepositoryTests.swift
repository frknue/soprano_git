import AppKit
import Testing
@testable import SopranoGitCore

/// Reads the repository `scripts/make-fixture-repo.sh` builds.
struct FixtureRepositoryTests {
    private func makeFixture(_ sandbox: GitSandbox, conflict: Bool) async throws -> Repository {
        let directory = sandbox.url("fixture")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [RepositoryPaths.fixtureScript.path, directory.path] + (conflict ? ["--conflict"] : [])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(path == directory.appendingPathComponent("work").path)
        return try await Repository.open(at: URL(fileURLWithPath: path), runner: sandbox.runner)
    }

    @Test func theFixtureHasBranchesTagsStashesAndAWorkingCopy() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await makeFixture(sandbox, conflict: false)

        let refs = try await repository.refs()
        #expect(refs.head == .branch("main"))
        let main = try #require(refs.currentBranch)
        #expect(main.upstream == "origin/main" && main.ahead == 2 && main.behind == 1)
        #expect(Set(refs.localBranches.map(\.name)).isSuperset(of: ["main", "feature/merged", "feature/rebased"]))
        #expect(refs.remoteBranches.contains { $0.name == "origin/feature/remote-only" })
        #expect(!refs.localBranches.contains { $0.name == "feature/remote-only" })
        #expect(refs.tags.contains { $0.name == "v0.1" && !$0.isAnnotated })
        #expect(refs.tags.contains { $0.name == "v1.0" && $0.isAnnotated && $0.message == "Release 1.0" })

        let stashes = try await repository.stashes()
        #expect(stashes.count == 2)
        #expect(try await repository.stashFiles(0).contains { $0.kind == .untracked })

        let commits = try await repository.log(limit: 500, skip: 0, extraTips: stashes.map(\.base))
        #expect(commits.count >= 60)
        #expect(commits.contains { $0.isMerge })
        #expect(Set(commits.map(\.id)).count == commits.count)

        let status = try await repository.status()
        #expect(status.operation == nil)
        #expect(!status.staged.isEmpty)
        #expect(status.unstaged.contains { $0.unstaged == .modified })
        #expect(status.unstaged.contains { $0.unstaged == .untracked })

        for entry in status.entries {
            if entry.staged != nil {
                #expect(try await !repository.diff(.staged(path: entry.path)).isEmpty)
            }
            if entry.unstaged != nil {
                #expect(try await !repository.diff(.unstaged(path: entry.path)).isEmpty)
            }
        }
        for commit in commits.prefix(70) {
            let detail = try await repository.commitDetail(commit.id)
            #expect(detail.commit == commit)
        }
    }

    @Test func theConflictFixtureIsAPausedMergeWithTwoConflicts() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await makeFixture(sandbox, conflict: true)
        let status = try await repository.status()
        guard case .merge(let mergingHead)? = status.operation else {
            Issue.record("expected a paused merge, got \(String(describing: status.operation))")
            return
        }
        #expect(mergingHead != nil)
        #expect(status.conflicted.map(\.conflict) == [.bothModified, .deletedByThem])
    }

    /// Set `SOPRANO_GIT_LOG_BENCH_REPO` to a repository path to time a
    /// 2000-commit page (read-only).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOPRANO_GIT_LOG_BENCH_REPO"] != nil))
    func aLargeLogPageParsesQuickly() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SOPRANO_GIT_LOG_BENCH_REPO"])
        let runner = GitRunner(executable: try #require(GitRunner.resolveExecutable(preferredPath: nil)))
        let repository = try await Repository.open(at: URL(fileURLWithPath: path), runner: runner)
        let start = Date()
        let commits = try await repository.log(limit: 2000, skip: 0, extraTips: [])
        let elapsed = Date().timeIntervalSince(start)
        print("log(limit: 2000) on \(path): \(commits.count) commits in \(String(format: "%.3f", elapsed)) s")
        #expect(!commits.isEmpty)
        #expect(commits.allSatisfy { !$0.id.isEmpty && !$0.author.email.isEmpty && $0.committer.date.timeIntervalSince1970 > 0 })
        #expect(elapsed < 5)
    }
}

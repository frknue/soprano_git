import AppKit
@testable import SopranoGitCore

/// A temporary directory with an isolated git configuration, for tests that
/// run real git. Never reads the user's config or repositories.
struct GitSandbox: Sendable {
    let directory: URL
    let runner: GitRunner

    /// Base for fixed commit dates; `at(_:)` offsets from it.
    static let baseDate = 1_700_000_000

    init() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("sg-core-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // /var → /private/var, so paths compare equal to git's realpath output.
        let resolved = URL(fileURLWithPath: realpath(directory.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? directory.path, isDirectory: true)
        let config = """
        [user]
        \tname = Test Author
        \temail = test@example.com
        [init]
        \tdefaultBranch = main
        [commit]
        \tgpgsign = false
        [tag]
        \tgpgsign = false
        [core]
        \tautocrlf = false
        [advice]
        \tdetachedHead = false
        [pull]
        \trebase = false
        [protocol "file"]
        \tallow = always

        """
        try config.write(to: resolved.appendingPathComponent("gitconfig"), atomically: true, encoding: .utf8)
        self.directory = resolved
        self.runner = GitRunner(
            executable: GitRunner.resolveExecutable(preferredPath: nil)!,
            environmentOverrides: Self.environment(home: resolved, date: Self.baseDate)
        )
    }

    static func environment(home: URL, date: Int) -> [String: String] {
        [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": home.appendingPathComponent("gitconfig").path,
            "GIT_AUTHOR_DATE": "@\(date) +0000",
            "GIT_COMMITTER_DATE": "@\(date) +0000",
            "LC_ALL": "C",
        ]
    }

    /// The runner with commit dates `offset` hours after `baseDate`.
    func runner(hour offset: Int) -> GitRunner {
        var runner = runner
        runner.environmentOverrides = Self.environment(home: directory, date: Self.baseDate + offset * 3600)
        return runner
    }

    func url(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: true)
    }

    /// `git init` of `name` inside the sandbox, opened as a `Repository`.
    func makeRepository(_ name: String = "repo") async throws -> Repository {
        let url = url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try await runner.run(["init", "-q"], in: url)
        return try await Repository.open(at: url, runner: runner)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Small helpers for setting up history in a sandbox repository.
struct GitScript: Sendable {
    let repository: Repository
    let sandbox: GitSandbox
    /// Hours after `GitSandbox.baseDate` of the next commit.
    private let clock = Clock()

    init(_ repository: Repository, sandbox: GitSandbox) {
        self.repository = repository
        self.sandbox = sandbox
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var hour = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            hour += 1
            return hour
        }
    }

    var root: URL { repository.root }

    @discardableResult
    func git(_ arguments: String..., stdin: String? = nil, accepting codes: Set<Int32> = [0]) async throws -> GitResult {
        try await sandbox.runner(hour: clock.next()).run(
            arguments, in: root, stdin: stdin.map { Data($0.utf8) }, acceptedExitCodes: codes
        )
    }

    /// Trimmed stdout of a git command.
    func output(_ arguments: String...) async throws -> String {
        try await sandbox.runner.run(arguments, in: root)
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ contents: String) throws {
        try write(path, Data(contents.utf8))
    }

    func write(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    /// Writes `files`, stages everything and commits with a fixed, increasing date.
    @discardableResult
    func commit(_ message: String, _ files: [String: String] = [:]) async throws -> String {
        for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
            try write(path, contents)
        }
        try await git("add", "-A")
        try await git("commit", "-q", "--allow-empty", "-m", message)
        return try await output("rev-parse", "HEAD")
    }

    /// Contents of `path` in the index.
    func indexContents(_ path: String) async throws -> String {
        try await sandbox.runner.run(["show", ":\(path)"], in: root).stdoutString
    }
}

/// The repository's own scripts directory.
enum RepositoryPaths {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtureScript = packageRoot.appendingPathComponent("scripts/make-fixture-repo.sh")
}

import AppKit
import Testing
@testable import SopranoGitCore

struct GitRunnerTests {
    /// A fake "git" that runs `body` regardless of the git options it gets.
    private func fakeGit(in sandbox: GitSandbox, _ body: String) throws -> GitRunner {
        let url = sandbox.directory.appendingPathComponent("fake-git-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        var runner = sandbox.runner
        runner.executable = url
        return runner
    }

    @Test func resolvesAnExecutablePreferredPathFirst() throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let fake = try fakeGit(in: sandbox, "exit 0")
        #expect(GitRunner.resolveExecutable(preferredPath: fake.executable.path) == fake.executable)
        let fallback = GitRunner.resolveExecutable(preferredPath: "/nonexistent/git")
        #expect(fallback != nil)
        #expect(fallback == GitRunner.resolveExecutable(preferredPath: nil))
        #expect(fallback.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true)
    }

    @Test func commandLineStartsWithTheFixedOptionsAndAddsReadFlags() {
        let runner = GitRunner(executable: URL(fileURLWithPath: "/usr/bin/git"))
        let directory = URL(fileURLWithPath: "/tmp/repo")
        #expect(runner.commandLine(["status"], in: directory, isRead: false) == [
            "--no-pager", "-c", "core.quotepath=false", "-c", "color.ui=never", "-c", "log.showSignature=false",
            "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false", "-C", "/tmp/repo", "status",
        ])
        let read = runner.commandLine(["status"], in: directory, isRead: true)
        #expect(read.contains("--no-optional-locks"))
        #expect(read.suffix(3) == ["-C", "/tmp/repo", "status"])
    }

    @Test func environmentAddsPromptsEditorAskpassAndPath() {
        var runner = GitRunner(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            environmentOverrides: ["HOME": "/tmp/home", "GIT_DIR": "/explicit"],
            extraPath: ["/custom/bin"]
        )
        let inherited = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "GIT_DIR": "/stray", "GIT_WORK_TREE": "/stray", "KEEP": "1"]
        var environment = runner.environment(isRead: true, inherited: inherited, home: "/Users/me")
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["GIT_EDITOR"] == "true")
        #expect(environment["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(environment["HOME"] == "/tmp/home")
        #expect(environment["KEEP"] == "1")
        #expect(environment["GIT_WORK_TREE"] == nil)
        #expect(environment["GIT_DIR"] == "/explicit")
        #expect(environment["GIT_ASKPASS"] == nil)
        #expect(environment["PATH"] == [
            "/custom/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "/Users/me/.local/bin", "/Users/me/.bun/bin", "/Users/me/.cargo/bin", "/usr/bin", "/bin",
        ].joined(separator: ":"))

        runner.askpassExecutable = URL(fileURLWithPath: "/Applications/Soprano Git.app/Contents/MacOS/SopranoGit")
        environment = runner.environment(isRead: false, inherited: inherited, home: "/Users/me")
        #expect(environment["GIT_OPTIONAL_LOCKS"] == nil)
        #expect(environment["GIT_ASKPASS"] == "/Applications/Soprano Git.app/Contents/MacOS/SopranoGit")
        #expect(environment["SSH_ASKPASS"] == environment["GIT_ASKPASS"])
        #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(environment["SOPRANO_GIT_ASKPASS"] == "1")
    }

    @Test func runsGitAndThrowsGitErrorOutsideTheAcceptedCodes() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let version = try await sandbox.runner.run(["--version"], in: sandbox.directory)
        #expect(version.stdoutString.hasPrefix("git version"))

        await #expect(throws: GitError.self) {
            try await sandbox.runner.run(["rev-parse", "--show-toplevel"], in: sandbox.directory)
        }
        do {
            try await sandbox.runner.run(["rev-parse", "--show-toplevel"], in: sandbox.directory)
        } catch let error as GitError {
            #expect(error.arguments == ["rev-parse", "--show-toplevel"])
            #expect(error.exitCode == 128)
            #expect(error.stderr.contains("not a git repository"))
            #expect(error.errorDescription?.contains("not a git repository") == true)
        }
        let accepted = try await sandbox.runner.run(
            ["rev-parse", "--show-toplevel"], in: sandbox.directory, acceptedExitCodes: [0, 128]
        )
        #expect(accepted.exitCode == 128)
    }

    @Test func environmentOverridesReachGit() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let name = try await sandbox.runner.run(["config", "user.name"], in: sandbox.directory)
        #expect(name.stdoutString == "Test Author\n")
    }

    @Test func largeStdinAndStdoutDoNotDeadlock() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repository = try await sandbox.makeRepository()
        // 50 MB in through stdin, then 50 MB back out through stdout.
        let line = Data("0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz\n".utf8)
        var payload = Data(capacity: 50 * 1024 * 1024 + line.count)
        while payload.count < 50 * 1024 * 1024 { payload.append(line) }
        let stored = try await sandbox.runner.run(["hash-object", "-w", "--stdin"], in: repository.root, stdin: payload)
        let id = stored.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = try await sandbox.runner.run(["cat-file", "blob", id], in: repository.root, isRead: true)
        #expect(output.stdout.count == payload.count)
        #expect(output.stdout == payload)
    }

    @Test func streamReportsProgressLinesSplitOnCarriageReturnsAndNewlines() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let runner = try fakeGit(in: sandbox, "printf 'Counting: 1%%\\rCounting: 50%%\\rCounting: 100%%, done.\\nDone\\n\\nlast' >&2; printf out")
        let collector = LineCollector()
        let result = try await runner.stream(["fetch"], in: sandbox.directory) { collector.append($0) }
        #expect(collector.lines == ["Counting: 1%", "Counting: 50%", "Counting: 100%, done.", "Done", "last"])
        #expect(result.stdoutString == "out")
        #expect(result.stderr == "Counting: 1%\rCounting: 50%\rCounting: 100%, done.\nDone\n\nlast")
    }

    @Test func takeLinesKeepsAnUnfinishedLineBuffered() {
        var buffer = Data("one\r\ntwo\rthr".utf8)
        #expect(GitProcess.takeLines(from: &buffer) == ["one", "two"])
        #expect(buffer == Data("thr".utf8))
    }

    @Test func cancellingTheTaskTerminatesGit() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let marker = sandbox.directory.appendingPathComponent("finished")
        let runner = try fakeGit(in: sandbox, "sleep 20; touch '\(marker.path)'")
        let start = Date()
        let task = Task { try await runner.run(["status"], in: sandbox.directory) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func aMissingExecutableThrowsLaunchFailed() async throws {
        let runner = GitRunner(executable: URL(fileURLWithPath: "/nonexistent/git"))
        await #expect(throws: GitSetupError.self) {
            try await runner.run(["status"], in: URL(fileURLWithPath: "/tmp"))
        }
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

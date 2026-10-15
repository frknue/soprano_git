import Foundation

/// Output of one git invocation.
public struct GitResult: Sendable, Hashable {
    public var stdout: Data
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: Data, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs the git CLI. The one place that builds git command lines, process
/// environments and pipes; everything else goes through `run` or `stream`.
///
/// Interface contract (implemented in Wave A, see docs/ARCHITECTURE.md):
/// - Every invocation is `git --no-pager -c core.quotepath=false -c color.ui=never
///   -c log.showSignature=false -c diff.noprefix=false -c diff.mnemonicPrefix=false
///   -C <directory> <arguments…>`; reads (`isRead: true`) add `--no-optional-locks`
///   and `GIT_OPTIONAL_LOCKS=0` so a refresh never contends with the user's own git.
/// - The environment is the app's environment plus `environmentOverrides`, plus
///   `GIT_TERMINAL_PROMPT=0` (never wait on a TTY), `GIT_EDITOR=true` (no editor
///   prompts; message-taking commands pass messages explicitly), and the askpass
///   variables from `askpassExecutable` when set (`GIT_ASKPASS`, `SSH_ASKPASS`,
///   `SSH_ASKPASS_REQUIRE=force`, `SOPRANO_GIT_ASKPASS=1`).
/// - `PATH` = `extraPath` + Homebrew/user tool directories + the inherited PATH, so
///   hooks find node, bun, etc. even though GUI apps start with a minimal PATH.
/// - stdout and stderr are drained concurrently (no pipe-buffer deadlock on large
///   output); cancellation of the calling Task terminates the process.
/// - Exit codes outside `acceptedExitCodes` throw `GitError` with both streams.
public struct GitRunner: Sendable {
    public var executable: URL
    public var environmentOverrides: [String: String]
    public var extraPath: [String]
    /// Executable git calls back for passwords/passphrases (the app binary in
    /// askpass mode). nil disables askpass (tests).
    public var askpassExecutable: URL?

    public init(
        executable: URL,
        environmentOverrides: [String: String] = [:],
        extraPath: [String] = [],
        askpassExecutable: URL? = nil
    ) {
        self.executable = executable
        self.environmentOverrides = environmentOverrides
        self.extraPath = extraPath
        self.askpassExecutable = askpassExecutable
    }

    /// `preferredPath` (settings `git.path`) if executable, else
    /// /opt/homebrew/bin/git, /usr/local/bin/git, then /usr/bin/git only when the
    /// Command Line Tools or Xcode provide a real git (avoids the install-dialog shim).
    public static func resolveExecutable(preferredPath: String?) -> URL? {
        unimplementedResolve()
    }

    /// Runs git to completion and returns its output.
    @discardableResult
    public func run(
        _ arguments: [String],
        in directory: URL,
        stdin: Data? = nil,
        isRead: Bool = false,
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> GitResult {
        throw GitSetupError.launchFailed("GitRunner.run is not implemented yet")
    }

    /// Like `run`, reporting each stderr progress line as it arrives (git's
    /// `--progress` output splits on both "\r" and "\n"). For fetch/pull/push/clone.
    @discardableResult
    public func stream(
        _ arguments: [String],
        in directory: URL,
        acceptedExitCodes: Set<Int32> = [0],
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> GitResult {
        throw GitSetupError.launchFailed("GitRunner.stream is not implemented yet")
    }
}

private func unimplementedResolve() -> URL? { nil }

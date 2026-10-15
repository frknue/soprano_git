import AppKit
import SopranoGitCore

/// Builds the `GitRunner` from settings and opens repositories with it.
@MainActor
enum RepositoryOpener {
    /// The git executable settings resolve to, nil when none is usable.
    static func gitExecutable(settings: AppSettings = SettingsCenter.shared.settings) -> URL? {
        GitRunner.resolveExecutable(preferredPath: settings.gitPath)
    }

    /// The runner for the current settings: `git.path`, `git.extraPath`, and
    /// this executable as askpass helper.
    static func makeRunner(settings: AppSettings = SettingsCenter.shared.settings) throws -> GitRunner {
        guard let executable = gitExecutable(settings: settings) else {
            throw GitSetupError.gitNotFound
        }
        return GitRunner(
            executable: executable,
            extraPath: settings.extraPath,
            askpassExecutable: Bundle.main.executableURL
        )
    }

    static func open(_ url: URL, settings: AppSettings = SettingsCenter.shared.settings) async throws -> Repository {
        let runner = try makeRunner(settings: settings)
        return try await Repository.open(at: url, runner: runner)
    }
}

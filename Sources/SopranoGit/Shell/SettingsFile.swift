import Foundation

/// Location, creation, and reading/writing of Soprano Git's `settings.json`
/// (adapted from Soprano's `ConfigFile`).
///
/// The file lives at `~/.config/soprano-git/settings.json` (honoring
/// `XDG_CONFIG_HOME`), so it can be symlinked out of a dotfiles repo.
/// `SOPRANO_GIT_CONFIG` overrides the full path.
enum SettingsFile {
    static let pathEnvironmentKey = "SOPRANO_GIT_CONFIG"

    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[pathEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath).standardizedFileURL
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: NSString(string: xdg).expandingTildeInPath)
                .standardizedFileURL
                .appendingPathComponent("soprano-git/settings.json", isDirectory: false)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/soprano-git/settings.json", isDirectory: false)
    }

    /// Soprano's own settings file, whose `theme` and `appearance` Soprano Git
    /// follows when its `theme` is "soprano". Same resolution as Soprano's `ConfigFile.url`.
    static func sopranoURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["SOPRANO_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath).standardizedFileURL
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: NSString(string: xdg).expandingTildeInPath)
                .standardizedFileURL
                .appendingPathComponent("soprano/settings.json", isDirectory: false)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/soprano/settings.json", isDirectory: false)
    }

    /// Returns the file's text, or nil when it does not exist yet.
    static func read(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Writes atomically through symlinks, so a dotfiles link survives.
    static func write(_ text: String, to url: URL) throws {
        let target = resolvingSymlink(url)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: target, atomically: true, encoding: .utf8)
    }

    /// Creates the file from the commented template when missing; returns its text.
    @discardableResult
    static func createIfMissing(at url: URL) throws -> String {
        if let existing = try read(at: url) {
            return existing
        }
        let text = template
        try write(text, to: url)
        return text
    }

    static func displayPath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func resolvingSymlink(_ url: URL) -> URL {
        var resolved = url
        var hops = 0
        while hops < 8,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path) {
            resolved = URL(fileURLWithPath: destination, relativeTo: resolved.deletingLastPathComponent())
                .standardizedFileURL
            hops += 1
        }
        return resolved
    }

    /// A commented starter document: the schema is the documentation.
    static var template: String {
        let themes = AppTheme.options.map { "\"\($0.id)\"" }.joined(separator: ", ")
        return """
        // Soprano Git settings. JSON with comments; saved changes apply immediately.
        // Unknown keys and bad values are ignored with a warning, never a crash.
        {
          // "soprano" follows the theme and appearance of Soprano (~/.config/soprano/settings.json).
          // "folio" is Folio Paper or Folio Ink, following the macOS appearance.
          // Or pick one: \(themes)
          "theme": "soprano",

          "git": {
            // Explicit git executable. Default: Homebrew git, then the Command Line Tools.
            // "path": "/opt/homebrew/bin/git",
            // Directories prepended to PATH for git and its hooks (node, bun, …).
            "extraPath": []
          },

          "graph": {
            // Commits loaded per page.
            "pageSize": 2000,
            // "relative" (3h, 2d) or "absolute" (2026-03-04 14:05).
            "dateStyle": "relative"
          },

          "pull": {
            // "ff" (fast-forward if possible, else merge), "ff-only", or "rebase".
            "mode": "ff"
          },

          "diff": {
            // Context lines around each change.
            "contextLines": 3
          },

          "keybindings": {
            // Ctrl + this key starts a prefix chord (default Ctrl+A).
            "prefixKey": "a",
            // How long the prefix waits for the next key (300–5000 ms).
            "prefixTimeoutMs": 1500,
            // "<command id>": "chord" | ["chord", …] | null (unbind).
            // Chords: "cmd+shift+p", "ctrl+tab", "j", "shift+r", "prefix+p", "enter", "escape".
            // Command ids are listed in Help → Keyboard Shortcuts (⌘/).
            "bindings": {
              // "repo.fetch": "cmd+shift+l",
              // "graph.search": ["cmd+f", "/"],
              // "branch.create": null
            }
          }
        }

        """
    }
}

// MARK: - Watching

/// Watches a settings file for edits made outside the app (Soprano's
/// `ConfigFileWatcher`): the file and its directory, re-armed after atomic
/// saves, debounced. Every mutable property is touched only on `queue`.
final class ConfigFileWatcher: @unchecked Sendable {
    private let url: URL
    private let debounceInterval: DispatchTimeInterval
    private let rearmInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "com.soprano.git.config-watcher")
    private let onChange: @Sendable () -> Void

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingWork: DispatchWorkItem?
    private var pendingRearm: DispatchWorkItem?
    private var isStopped = false

    init(
        url: URL,
        debounceInterval: DispatchTimeInterval = .milliseconds(120),
        rearmInterval: DispatchTimeInterval = .seconds(2),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.debounceInterval = debounceInterval
        self.rearmInterval = rearmInterval
        self.onChange = onChange
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
        pendingWork?.cancel()
        pendingRearm?.cancel()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = false
            self.armDirectorySource()
            self.armFileSource()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.pendingRearm?.cancel()
            self.pendingRearm = nil
            self.pendingWork?.cancel()
            self.pendingWork = nil
            self.fileSource?.cancel()
            self.fileSource = nil
            self.directorySource?.cancel()
            self.directorySource = nil
        }
    }

    private func armFileSource() {
        fileSource?.cancel()
        fileSource = nil
        guard !isStopped else { return }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                self.armFileSource()
            }
            self.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        fileSource = source
    }

    private func armDirectorySource() {
        directorySource?.cancel()
        directorySource = nil
        guard !isStopped else { return }

        let directory = url.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRearm()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                self.armDirectorySource()
                self.armFileSource()
            } else if self.fileSource == nil {
                self.armFileSource()
            }
            self.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }

    private func scheduleRearm() {
        guard !isStopped, pendingRearm == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.pendingRearm = nil
            self.armDirectorySource()
            if self.directorySource != nil {
                self.armFileSource()
                self.scheduleChange()
            }
        }
        pendingRearm = work
        queue.asyncAfter(deadline: .now() + rearmInterval, execute: work)
    }

    private func scheduleChange() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.onChange()
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}

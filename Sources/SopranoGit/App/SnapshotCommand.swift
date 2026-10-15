import AppKit
import SopranoGitCore

/// `SopranoGit snapshot --repo <path> --out <png> [--size 1500x940] [--theme <id>]
/// [--keys "<chord> <chord> …"] [--wait <seconds>] [--recent <path>,…]
/// [--dialog prompt|confirm|choose|alert]`
///
/// Builds the real main window off-screen (no Dock icon, no visible window,
/// volatile state), loads the repository, replays `--keys` through the
/// keyboard router, waits for async work to settle, and writes a PNG of the
/// window with its sheets and child panels (palette, dialogs, toasts).
@MainActor
enum SnapshotCommand {
    struct Options: Equatable {
        var repo: URL?
        var out: URL
        var size = NSSize(width: 1500, height: 940)
        var theme: String?
        var keys: [String] = []
        var wait: Double = 0.6
        var recent: [URL] = []
        var dialog: String?
    }

    enum OptionError: Error, CustomStringConvertible {
        case missingValue(String)
        case unknownOption(String)
        case badSize(String)
        case missingOut

        var description: String {
            switch self {
            case let .missingValue(option): "\(option) needs a value"
            case let .unknownOption(option): "unknown option \(option)"
            case let .badSize(value): "--size must be WIDTHxHEIGHT, got \(value)"
            case .missingOut: "--out <png> is required"
            }
        }
    }

    static let usage = """
    usage: SopranoGit snapshot --out <png> [--repo <path>] [--size 1500x940] [--theme <id>]
                               [--keys "<chord> …"] [--wait <seconds>] [--recent <path>,…]
                               [--dialog prompt|confirm|choose|alert]
    """

    nonisolated static func parse(_ arguments: [String]) throws -> Options {
        var repo: URL?
        var out: URL?
        var options = Options(out: URL(fileURLWithPath: "/dev/null"))
        var index = 0
        func value(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw OptionError.missingValue(option) }
            return arguments[index]
        }
        func fileURL(_ path: String) -> URL {
            URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
        }
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--repo": repo = fileURL(try value(option))
            case "--out": out = fileURL(try value(option))
            case "--theme": options.theme = try value(option)
            case "--keys": options.keys = try value(option).split(separator: " ").map(String.init)
            case "--wait": options.wait = Double(try value(option)) ?? options.wait
            case "--dialog": options.dialog = try value(option)
            case "--recent":
                options.recent = try value(option).split(separator: ",").map { fileURL(String($0)) }
            case "--size":
                let text = try value(option)
                let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { throw OptionError.badSize(text) }
                options.size = NSSize(width: parts[0], height: parts[1])
            default:
                throw OptionError.unknownOption(option)
            }
            index += 1
        }
        guard let out else { throw OptionError.missingOut }
        options.out = out
        options.repo = repo
        return options
    }

    static func run(arguments: [String]) -> Never {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n\(usage)\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        // No Dock icon and never activated: nothing appears on the user's screen.
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            do {
                try await capture(options)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
        exit(1)
    }

    struct CaptureError: Error, CustomStringConvertible {
        var description: String
    }

    static func capture(_ options: Options) async throws {
        _ = RetroFont.registerBundledFont()
        let settings = SettingsCenter.shared
        settings.start(createIfMissing: false, watching: false)
        ThemeCenter.shared.apply(setting: settings.settings.theme, watch: false)
        if let theme = options.theme {
            ThemeCenter.shared.forcedThemeID = theme
        }
        if CommandRegistry.shared.commands.isEmpty {
            AllCommands.registerAll()
        }
        settings.reloadKeymap()

        let state = AppStateStore.volatile()
        for url in options.recent.reversed() {
            state.noteOpened(url)
        }
        // Far outside every display: real window server backing, never seen.
        let frame = NSRect(x: -30000, y: -30000, width: options.size.width, height: options.size.height)
        let controller = MainWindowController(state: state, persistsState: false, frame: frame)
        guard let window = controller.mainWindow else { throw CaptureError(description: "no window") }
        window.allowsOffscreenFrame = true
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        DialogPanel.presentsAsSheet = false
        DialogPanel.activatesApp = false
        controller.palette.hidesOnDeactivate = false
        controller.shortcutSheet.hidesOnDeactivate = false

        if let repo = options.repo {
            controller.newTab()
            await controller.openRepository(at: repo)
            await waitUntil(timeout: 20) {
                guard let workspace = controller.currentWorkspace else { return true }
                return workspace.controller.hasLoaded || workspace.controller.loadError != nil
            }
        } else {
            controller.newTab()
        }
        await settle(0.3)

        if let dialog = options.dialog {
            presentDemoDialog(dialog, in: window)
            await settle(0.3)
        }

        for token in options.keys {
            for event in try events(for: token, in: window) {
                deliver(event, controller: controller, window: window)
                await settle(0.15)
            }
        }

        await settle(options.wait)
        await waitUntil(timeout: 20) {
            controller.currentWorkspace?.controller.activity.running == nil
        }
        await settle(0.2)

        let image = try render(controller: controller, window: window)
        try writePNG(image, to: options.out)
        print(options.out.path)
    }

    // MARK: - Keys

    /// Events for one `--keys` token ("cmd+p", "?", "prefix+p", "j", "enter").
    static func events(for token: String, in window: NSWindow) throws -> [NSEvent] {
        guard let chord = KeyChord.parse(token) else {
            throw CaptureError(description: "--keys: \"\(token)\" is not a chord")
        }
        var events: [NSEvent] = []
        if chord.mode == .prefix {
            let prefixKey = SettingsCenter.shared.keymap.prefixKey
            events.append(makeEvent(key: prefixKey, ctrl: true, meta: false, shift: false, window: window))
        }
        events.append(makeEvent(key: chord.key, ctrl: chord.ctrl, meta: chord.meta, shift: chord.shift, window: window))
        return events
    }

    static func makeEvent(key: String, ctrl: Bool, meta: Bool, shift: Bool, window: NSWindow) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if ctrl { flags.insert(.control) }
        if meta { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        let characters = shift && key.count == 1 && key.first?.isLetter == true ? key.uppercased() : key
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: ctrl && key.count == 1 && key.first?.isLetter == true
                ? String(UnicodeScalar(UInt8(key.unicodeScalars.first!.value & 0x1F)))
                : characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode(for: key)
        ) ?? NSEvent()
    }

    static func keyCode(for key: String) -> UInt16 {
        let named: [String: UInt16] = [
            "\r": 36, "\t": 48, " ": 49, "\u{7F}": 51, "\u{1B}": 53,
            "\u{F702}": 123, "\u{F703}": 124, "\u{F701}": 125, "\u{F700}": 126,
        ]
        if let code = named[key] { return code }
        let letters: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
            "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "?": 44,
        ]
        return key.first.flatMap { letters[$0] } ?? 0
    }

    /// Dialogs and panels take keys while shown (the router stays out); else the router.
    static func deliver(_ event: NSEvent, controller: MainWindowController, window: NSWindow) {
        if let dialog = Dialogs.current, dialog.isVisible {
            dialog.sendEvent(event)
            return
        }
        if let panel = controller.visibleChildPanels.last {
            panel.sendEvent(event)
            return
        }
        guard let passed = controller.router.dispatch(event) else { return }
        window.sendEvent(passed)
    }

    static func presentDemoDialog(_ kind: String, in window: NSWindow) {
        Task { @MainActor in
            switch kind {
            case "confirm":
                _ = await Dialogs.confirm(
                    title: "Delete Branch",
                    message: "Delete the local branch \"feature/login\"? Its commits stay reachable from origin/feature/login.",
                    confirmTitle: "Delete",
                    isDestructive: true,
                    in: window
                )
            case "choose":
                _ = await Dialogs.choose(
                    title: "Reset main to 3f2a1c9",
                    message: "How should the working tree be treated?",
                    options: [
                        DialogOption(title: "Soft", detail: "Keep changes staged", key: "s"),
                        DialogOption(title: "Mixed", detail: "Keep changes unstaged", key: "m"),
                        DialogOption(title: "Hard", detail: "Discard all changes", key: "h", isDestructive: true),
                    ],
                    in: window
                )
            case "alert":
                await Dialogs.alert(title: "Can't Open Repository", message: "/tmp is not a git repository.", in: window)
            default:
                _ = await Dialogs.prompt(
                    title: "Create Branch",
                    message: "New branch at 3f2a1c9 \"Add login screen\".",
                    placeholder: "branch-name",
                    initialValue: "feature/login screen",
                    confirmTitle: "Create",
                    validate: { $0.contains(" ") ? "Branch names cannot contain spaces." : nil },
                    in: window
                )
            }
        }
    }

    // MARK: - Waiting

    static func settle(_ seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    static func waitUntil(timeout: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Rendering

    /// Renders the window and everything above it (sheet, dialog, child
    /// panels) through Core Animation, so layer-backed content (lamp glows,
    /// accent fills, borders) appears exactly as on screen.
    static func render(controller: MainWindowController, window: NSWindow) throws -> CGImage {
        let scale = max(1, window.backingScaleFactor)
        let size = window.frame.size
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CaptureError(description: "no bitmap context") }
        context.scaleBy(x: scale, y: scale)

        var layers: [NSWindow] = [window]
        if let sheet = window.attachedSheet { layers.append(sheet) }
        for child in controller.visibleChildPanels where !layers.contains(child) { layers.append(child) }
        if let dialog = Dialogs.current, dialog.isVisible, !layers.contains(dialog) { layers.append(dialog) }

        for (index, layerWindow) in layers.enumerated() {
            let origin = NSPoint(
                x: layerWindow.frame.minX - window.frame.minX,
                y: layerWindow.frame.minY - window.frame.minY
            )
            if index > 0 {
                drawShadow(for: NSRect(origin: origin, size: layerWindow.frame.size), in: context)
            }
            try draw(layerWindow, at: origin, in: context)
        }
        guard let image = context.makeImage() else { throw CaptureError(description: "no image") }
        return image
    }

    private static func draw(_ window: NSWindow, at origin: NSPoint, in context: CGContext) throws {
        guard let view = window.contentView else { return }
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.display()
        CATransaction.flush()
        guard let layer = view.layer else { throw CaptureError(description: "content view has no layer") }
        context.saveGState()
        if window.isOpaque, window.backgroundColor.alphaComponent > 0 {
            context.setFillColor(window.backgroundColor.cgColor)
            context.fill(CGRect(origin: origin, size: window.frame.size))
        }
        context.translateBy(x: origin.x, y: origin.y)
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        context.restoreGState()
    }

    private static func drawShadow(for rect: NSRect, in context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError(description: "PNG encoding failed")
        }
        try data.write(to: url)
    }
}

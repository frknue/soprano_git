import AppKit
import SopranoGitCore

/// Keyboard focus areas. Single-key bindings fire only while their area has
/// focus, and chords without ⌘/⌃ never fire while a text field is editing.
enum FocusRegion: String, CaseIterable, Sendable {
    case welcome
    case sidebar
    case graph
    case detail
    case diff
}

/// A view controller that owns a focus area. The workspace calls `takeFocus()`
/// to move keyboard focus into it; the router finds the focused area by walking
/// up from the first responder to a view whose controller adopts this.
@MainActor
protocol FocusRegionController: AnyObject {
    var focusRegion: FocusRegion { get }
    /// The view that must contain the first responder for this area to count as focused.
    var focusRootView: NSView { get }
    func takeFocus()
}

/// What commands act on: the selection of the focused area, falling back to
/// the graph selection.
enum SelectionTarget: Hashable {
    case workingCopy
    case commit(String)
    case branch(Branch)
    case tag(Tag)
    case stash(Stash)

    /// The commit the target resolves to, when it has one.
    var commitID: String? {
        switch self {
        case .workingCopy: nil
        case let .commit(id): id
        case let .branch(branch): branch.target
        case let .tag(tag): tag.target
        case let .stash(stash): stash.id
        }
    }
}

@MainActor
protocol SelectionTargetProvider: AnyObject {
    var selectionTarget: SelectionTarget? { get }
}

enum CommandCategory: String, CaseIterable, Sendable {
    case app = "App"
    case tabs = "Tabs"
    case view = "View"
    case navigation = "Navigation"
    case graph = "Graph"
    case branch = "Branch"
    case commit = "Commit"
    case staging = "Staging"
    case stash = "Stash"
    case tag = "Tag"
    case remote = "Remote"
    case operation = "Merge & Rebase"
}

/// Everything a command needs to know about where it was invoked.
@MainActor
struct CommandContext {
    weak var window: NSWindow?
    /// The active repository tab; nil on the welcome screen.
    var workspace: (any RepoWorkspace)?
    /// The focused area, nil when focus is elsewhere (toolbar, dialogs).
    var focus: FocusRegion?
    /// A text field or text view is the first responder.
    var isTextInput: Bool

    var controller: RepositoryController? { workspace?.controller }

    /// Selection of the focused area, else the graph's selection.
    var target: SelectionTarget? {
        guard let workspace else { return nil }
        if let focus, let provider = workspace.selectionProvider(for: focus), let target = provider.selectionTarget {
            return target
        }
        return workspace.graph.selectionTarget
    }
}

/// One user-invocable action. Commands are the single source for the palette,
/// key bindings, menus, toolbar buttons and the shortcut sheet.
@MainActor
struct AppCommand {
    /// Stable id; also the key in settings.json `keybindings.bindings`.
    let id: String
    let title: String
    let category: CommandCategory
    /// Areas where its keys fire. Empty = everywhere.
    let scopes: Set<FocusRegion>
    /// Default chords in Soprano's KeyChord syntax ("cmd+b", "j", "shift+j",
    /// "prefix+p"); the first is the one menus and the palette show.
    let defaultKeys: [String]
    /// SF Symbol for the palette.
    let icon: String
    /// Listed in the command palette (false for pure navigation like j/k).
    let inPalette: Bool
    let isEnabled: @MainActor (CommandContext) -> Bool
    let perform: @MainActor (CommandContext) -> Void

    init(
        id: String,
        title: String,
        category: CommandCategory,
        scopes: Set<FocusRegion> = [],
        defaultKeys: [String] = [],
        icon: String = "command",
        inPalette: Bool = true,
        isEnabled: @escaping @MainActor (CommandContext) -> Bool = { _ in true },
        perform: @escaping @MainActor (CommandContext) -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.scopes = scopes
        self.defaultKeys = defaultKeys
        self.icon = icon
        self.inPalette = inPalette
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

@MainActor
final class CommandRegistry {
    static let shared = CommandRegistry()

    private(set) var commands: [AppCommand] = []
    private var indexByID: [String: Int] = [:]

    func register(_ newCommands: [AppCommand]) {
        for command in newCommands {
            precondition(indexByID[command.id] == nil, "Duplicate command id \(command.id)")
            indexByID[command.id] = commands.count
            commands.append(command)
        }
    }

    func command(_ id: String) -> AppCommand? {
        indexByID[id].map { commands[$0] }
    }

    /// Runs the command when it exists and is enabled. Returns whether it ran.
    @discardableResult
    func perform(_ id: String, in context: CommandContext) -> Bool {
        guard let command = command(id), command.isEnabled(context) else { return false }
        command.perform(context)
        return true
    }
}

/// Registers every module's commands once at launch. Each module owns its
/// `…Commands` enum; this file only lists them.
@MainActor
enum AllCommands {
    static func registerAll(in registry: CommandRegistry = .shared) {
        registry.register(ShellCommands.all)
        registry.register(GitActionCommands.all)
        registry.register(GraphCommands.all)
        registry.register(SidebarCommands.all)
        registry.register(CommitPanelCommands.all)
        registry.register(DiffCommands.all)
    }
}

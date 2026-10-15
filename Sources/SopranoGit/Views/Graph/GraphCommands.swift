import AppKit

/// The Graph rows of the binding table (ARCHITECTURE.md "Default bindings").
@MainActor
enum GraphCommands {
    static var all: [AppCommand] {
        [
            navigation("graph.next", "Next Commit", keys: ["j"], icon: "arrow.down") { $0.moveSelection(by: 1) },
            navigation("graph.previous", "Previous Commit", keys: ["k"], icon: "arrow.up") { $0.moveSelection(by: -1) },
            navigation("graph.nextInBranch", "Follow First Parent", keys: ["shift+j"], icon: "arrow.down.to.line") {
                $0.followFirstParent()
            },
            navigation("graph.previousInBranch", "Follow Child", keys: ["shift+k"], icon: "arrow.up.to.line") {
                $0.followChild()
            },
            navigation("graph.first", "First Commit", keys: ["cmd+up", "g"], icon: "arrow.up.to.line.compact") {
                $0.selectFirstRow()
            },
            navigation("graph.last", "Last Commit", keys: ["cmd+down", "shift+g"], icon: "arrow.down.to.line.compact") {
                $0.selectLastRow()
            },
            AppCommand(
                id: "graph.head", title: "Jump to HEAD", category: .navigation,
                scopes: [.graph], defaultKeys: ["."], icon: "scope",
                isEnabled: { graph($0)?.headRow != nil },
                perform: { graph($0)?.selectHead() }
            ),
            AppCommand(
                id: "graph.workingCopy", title: "Jump to Working Copy", category: .navigation,
                scopes: [.graph], defaultKeys: ["w"], icon: "pencil.line",
                isEnabled: { graph($0)?.workingCopyRow != nil },
                perform: { graph($0)?.selectWorkingCopy() }
            ),
            AppCommand(
                id: "graph.search", title: "Search Commits", category: .graph,
                defaultKeys: ["cmd+f", "/"], icon: "magnifyingglass",
                // `/` in the sidebar is its filter (sidebar.filter, also global).
                isEnabled: { $0.workspace != nil && $0.focus != .sidebar },
                perform: { context in
                    guard let workspace = context.workspace else { return }
                    workspace.focus(.graph)
                    workspace.graph.openSearch()
                }
            ),
            AppCommand(
                id: "graph.searchNext", title: "Next Match", category: .graph,
                scopes: [.graph], defaultKeys: ["cmd+g", "n"], icon: "chevron.down", inPalette: false,
                isEnabled: { graph($0)?.hasSearchMatches == true },
                perform: { graph($0)?.stepSearch(by: 1) }
            ),
            AppCommand(
                id: "graph.searchPrevious", title: "Previous Match", category: .graph,
                scopes: [.graph], defaultKeys: ["cmd+shift+g", "shift+n"], icon: "chevron.up", inPalette: false,
                isEnabled: { graph($0)?.hasSearchMatches == true },
                perform: { graph($0)?.stepSearch(by: -1) }
            ),
            AppCommand(
                id: "graph.openDetails", title: "Focus Commit Panel", category: .graph,
                scopes: [.graph], defaultKeys: ["enter"], icon: "sidebar.right",
                isEnabled: { graph($0)?.selectedRow != nil },
                perform: { $0.workspace?.focus(.detail) }
            ),
        ]
    }

    private static func graph(_ context: CommandContext) -> CommitGraphViewController? {
        context.workspace?.graph
    }

    /// Pure navigation: graph-scoped, not in the palette, enabled once rows exist.
    private static func navigation(
        _ id: String,
        _ title: String,
        keys: [String],
        icon: String,
        perform: @escaping @MainActor (CommitGraphViewController) -> Void
    ) -> AppCommand {
        AppCommand(
            id: id, title: title, category: .navigation,
            scopes: [.graph], defaultKeys: keys, icon: icon, inPalette: false,
            isEnabled: { graph($0)?.hasRows == true },
            perform: { context in
                guard let graph = graph(context) else { return }
                perform(graph)
            }
        )
    }
}

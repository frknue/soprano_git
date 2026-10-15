import AppKit
import SopranoGitCore

/// The Sidebar rows of the default binding table.
@MainActor
enum SidebarCommands {
    static var all: [AppCommand] {
        [
            AppCommand(
                id: "sidebar.filter",
                title: "Filter Left Panel",
                category: .navigation,
                defaultKeys: ["cmd+shift+f", "/"],
                icon: "line.3.horizontal.decrease",
                isEnabled: { $0.workspace != nil },
                perform: { $0.workspace?.sidebar.beginFilter() }
            ),
            AppCommand(
                id: "sidebar.next",
                title: "Next Ref",
                category: .navigation,
                scopes: [.sidebar],
                defaultKeys: ["j"],
                icon: "chevron.down",
                inPalette: false,
                isEnabled: { $0.workspace != nil },
                perform: { $0.workspace?.sidebar.moveSelection(by: 1) }
            ),
            AppCommand(
                id: "sidebar.previous",
                title: "Previous Ref",
                category: .navigation,
                scopes: [.sidebar],
                defaultKeys: ["k"],
                icon: "chevron.up",
                inPalette: false,
                isEnabled: { $0.workspace != nil },
                perform: { $0.workspace?.sidebar.moveSelection(by: -1) }
            ),
            AppCommand(
                id: "sidebar.activate",
                title: "Checkout / Reveal",
                category: .branch,
                scopes: [.sidebar],
                defaultKeys: ["enter"],
                icon: "arrow.right.circle",
                isEnabled: { $0.workspace?.sidebar.selectedNode != nil },
                perform: { $0.workspace?.sidebar.activateSelected() }
            ),
            AppCommand(
                id: "sidebar.toggle",
                title: "Expand / Collapse",
                category: .navigation,
                scopes: [.sidebar],
                defaultKeys: ["space"],
                icon: "chevron.right",
                isEnabled: { $0.workspace?.sidebar.selectedNode?.isGroup == true },
                perform: { $0.workspace?.sidebar.toggleSelected() }
            ),
        ]
    }
}

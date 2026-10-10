import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

struct ShellTabBarCommandPresentation: Equatable {
    let command: AppCommand
    let controlToolTip: String
    let isEnabled: Bool

    private let dispatcher: any AppCommandDispatching

    @MainActor
    init?(
        command: AppCommand,
        surface: AppCommandSurface,
        commandContext: CommandContext,
        dispatcher: any AppCommandDispatching
    ) {
        self.init(
            definition: command.definition,
            surface: surface,
            commandContext: commandContext,
            dispatcher: dispatcher
        )
    }

    @MainActor
    init?(
        definition: AppCommandSpec,
        surface: AppCommandSurface,
        commandContext: CommandContext,
        dispatcher: any AppCommandDispatching
    ) {
        guard
            definition.shouldPresent(
                AppCommandPresentationQuery(
                    surface: surface,
                    subject: .contextual(commandContext)
                )
            )
        else {
            return nil
        }

        self.command = definition.command
        self.controlToolTip = definition.controlToolTip
        self.isEnabled = dispatcher.canDispatch(definition.command)
        self.dispatcher = dispatcher
    }

    @MainActor
    func perform() {
        guard dispatcher.canDispatch(command) else { return }
        dispatcher.dispatch(command)
    }

    static func == (
        lhs: Self,
        rhs: Self
    ) -> Bool {
        lhs.command == rhs.command
            && lhs.controlToolTip == rhs.controlToolTip
            && lhs.isEnabled == rhs.isEnabled
    }
}

@MainActor
enum ShellTabBarCommandContext {
    static func current() -> CommandContext {
        let workspaceTab = atom(\.workspaceTab)
        let workspacePane = atom(\.workspacePane)
        let focusedPane = atom(\.workspaceFocusedPane).resolve(
            workspaceTab: workspaceTab,
            workspacePane: workspacePane,
            requestedOwner: atom(\.workspaceFocusOwner).owner
        )
        return atom(\.commandContext).currentContext(
            workspaceTab: workspaceTab,
            workspacePane: workspacePane,
            focusedPane: focusedPane,
            workspacePanePresentation: atom(\.workspacePanePresentation)
        )
    }
}

struct WatchFolderTabBarMenu: View {
    let commandDispatcher: any AppCommandDispatching
    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if let presentation = ShellTabBarCommandPresentation(
            command: .watchFolder,
            surface: .toolbar(.app),
            commandContext: ShellTabBarCommandContext.current(),
            dispatcher: commandDispatcher
        ) {
            Button {
                presentation.perform()
            } label: {
                ChromeToolbarButtonLabel(
                    symbolName: "folder.badge.plus",
                    isHovered: isHovered,
                    showsBackground: true
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .disabled(!presentation.isEnabled)
            .help(presentation.controlToolTip)
        }
    }
}

/// Management layer toggle in the tab bar. Blue accent when active, standard hover otherwise.
struct TabBarManagementLayerButton: View {
    let commandDispatcher: any AppCommandDispatching
    private var isManagementLayerActive: Bool {
        atom(\.managementLayer).isActive
    }
    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if let presentation = ShellTabBarCommandPresentation(
            command: .toggleManagementLayer,
            surface: .toolbar(.app),
            commandContext: ShellTabBarCommandContext.current(),
            dispatcher: commandDispatcher
        ) {
            Button(action: presentation.perform) {
                ChromeToolbarButtonLabel(
                    symbolName: "rectangle.split.2x2",
                    selectedSymbolName: "rectangle.split.2x2.fill",
                    isSelected: isManagementLayerActive,
                    isHovered: isHovered,
                    showsBackground: true
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .disabled(!presentation.isEnabled)
            .help(presentation.controlToolTip)
        }
    }
}

struct TabSelectionToolbarMenu: View {
    @Bindable var adapter: TabBarAdapter
    let onSelect: (UUID) -> Void

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(Array(adapter.tabs.enumerated()), id: \.element.id) { index, tab in
                Button {
                    onSelect(tab.id)
                } label: {
                    HStack {
                        if tab.id == adapter.activeTabId {
                            Image(systemName: "checkmark")
                        }
                        Text(tab.displayTitle)
                        if index < 9 {
                            Text("  \u{2318}\(index + 1)")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: AppStyles.General.Spacing.tight) {
                ChromeToolbarButtonLabel(
                    symbolName: "rectangle.stack",
                    isHovered: isHovered,
                    showsBackground: false
                )
                Text("\(adapter.tabs.count)")
                    .font(.system(size: AppStyles.General.Typography.textSm, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .tint(AppStyles.Shell.Chrome.ToolbarButton.iconForegroundColor)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("Select Tab")
    }
}

/// "+" button for creating a new tab.
/// Click = empty terminal (existing behavior). Right-click = menu with options.
struct NewTabButton: View {
    let commandDispatcher: any AppCommandDispatching
    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        let commandContext = ShellTabBarCommandContext.current()
        let newTabToolbarPresentation = ShellTabBarCommandPresentation(
            command: .newTab,
            surface: .toolbar(.app),
            commandContext: commandContext,
            dispatcher: commandDispatcher
        )
        let emptyTerminalPresentation = ShellTabBarCommandPresentation(
            command: .newTab,
            surface: .contextMenu,
            commandContext: commandContext,
            dispatcher: commandDispatcher
        )
        let repositoriesPresentation = ShellTabBarCommandPresentation(
            command: .showCommandBarRepos,
            surface: .contextMenu,
            commandContext: commandContext,
            dispatcher: commandDispatcher
        )

        if let newTabToolbarPresentation {
            ZStack {
                Button(action: newTabToolbarPresentation.perform) {
                    ChromeToolbarButtonLabel(
                        symbolName: "plus",
                        isHovered: isHovered,
                        showsBackground: true
                    )
                }
                .buttonStyle(.plain)
                .disabled(!newTabToolbarPresentation.isEnabled)
            }
            .contextMenu {
                if let emptyTerminalPresentation {
                    Button(LocalActionSpec.emptyTerminal.actionSpec.label) {
                        emptyTerminalPresentation.perform()
                    }
                    .disabled(!emptyTerminalPresentation.isEnabled)
                }
                if emptyTerminalPresentation != nil, repositoriesPresentation != nil {
                    Divider()
                }
                if let repositoriesPresentation {
                    Button(LocalActionSpec.openRepoWorktree.actionSpec.label) {
                        repositoriesPresentation.perform()
                    }
                    .disabled(!repositoriesPresentation.isEnabled)
                }
            }
            .onHover { isHovered = $0 }
            .help(newTabToolbarPresentation.controlToolTip)
        }
    }
}

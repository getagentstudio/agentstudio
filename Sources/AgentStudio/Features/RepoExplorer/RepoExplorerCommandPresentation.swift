import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

package enum RepoExplorerCommandPresentationArguments: Hashable, Sendable {
    case noArguments
}

package struct RepoExplorerCommandPresentationRequest: Hashable, Sendable {
    package let command: AppCommand
    package let surface: AppCommandSurface
    package let target: UUID?
    package let targetType: SearchItemType?
    package let arguments: RepoExplorerCommandPresentationArguments

    package init(
        command: AppCommand,
        surface: AppCommandSurface,
        target: UUID?,
        targetType: SearchItemType?,
        arguments: RepoExplorerCommandPresentationArguments
    ) {
        self.command = command
        self.surface = surface
        self.target = target
        self.targetType = targetType
        self.arguments = arguments
    }
}

package struct RepoExplorerCommandPresentationSnapshot: Equatable, Sendable {
    package static let empty = Self(
        generation: 0,
        results: [:],
        pinnedStateByRepositoryID: [:]
    )

    package let generation: UInt64
    package let results: [RepoExplorerCommandPresentationRequest: Bool]
    package let pinnedStateByRepositoryID: [UUID: Bool]

    package init(
        generation: UInt64,
        results: [RepoExplorerCommandPresentationRequest: Bool],
        pinnedStateByRepositoryID: [UUID: Bool] = [:]
    ) {
        self.generation = generation
        self.results = results
        self.pinnedStateByRepositoryID = pinnedStateByRepositoryID
    }
}

package struct RepoExplorerCommandPresentationTarget: Equatable, Sendable {
    let materializationHostLifetimeID: RepoExplorerMaterializationHostLifetimeID
    let materializationGeneration: UInt64
    let visibleRevision: UInt64
}

package struct RepoExplorerVisibleWorktreeSnapshot: Equatable, Sendable {
    package let target: RepoExplorerCommandPresentationTarget
    package let worktreeIDs: Set<UUID>
    package let repositoryIDs: Set<UUID>
    package let paneIDs: Set<UUID>
    package let settledUpdateAttemptByRepositoryID: [UUID: UUID]

    package init(
        target: RepoExplorerCommandPresentationTarget,
        worktreeIDs: Set<UUID>,
        repositoryIDs: Set<UUID> = [],
        paneIDs: Set<UUID> = [],
        settledUpdateAttemptByRepositoryID: [UUID: UUID] = [:]
    ) {
        self.target = target
        self.worktreeIDs = worktreeIDs
        self.repositoryIDs = repositoryIDs
        self.paneIDs = paneIDs
        self.settledUpdateAttemptByRepositoryID = settledUpdateAttemptByRepositoryID
    }
}

package struct RepoExplorerCommandPresentationDelta: Equatable, Sendable {
    package let commandGeneration: UInt64
    package let target: RepoExplorerCommandPresentationTarget
    package let snapshot: RepoExplorerCommandPresentationSnapshot
    package let affectedWorktreeIDs: Set<UUID>
    package let affectedRepositoryIDs: Set<UUID>
    package let affectedPaneIDs: Set<UUID>
    package let affectedRequestIdentities: Set<RepoExplorerCommandPresentationRequest>
    package let toolbarChanged: Bool

    package init(
        commandGeneration: UInt64,
        target: RepoExplorerCommandPresentationTarget,
        snapshot: RepoExplorerCommandPresentationSnapshot,
        affectedWorktreeIDs: Set<UUID>,
        affectedRepositoryIDs: Set<UUID>,
        affectedPaneIDs: Set<UUID> = [],
        affectedRequestIdentities: Set<RepoExplorerCommandPresentationRequest>,
        toolbarChanged: Bool
    ) {
        precondition(commandGeneration == snapshot.generation)
        self.commandGeneration = commandGeneration
        self.target = target
        self.snapshot = snapshot
        self.affectedWorktreeIDs = affectedWorktreeIDs
        self.affectedRepositoryIDs = affectedRepositoryIDs
        self.affectedPaneIDs = affectedPaneIDs
        self.affectedRequestIdentities = affectedRequestIdentities
        self.toolbarChanged = toolbarChanged
    }
}

enum RepoExplorerCommandPresentationDeltaDisposition: Equatable {
    case accepted(reboundRowCount: Int)
    case stale(currentVisibleSnapshot: RepoExplorerVisibleWorktreeSnapshot)
    case duplicateOrOlderCommandGeneration
}

@MainActor
struct RepoExplorerTableInteractions {
    static let inert = Self(
        onCommandRequest: { _ in },
        onToggleGroup: { _ in },
        onFocusPane: { _ in }
    )

    let onCommandRequest: (RepoExplorerCommandPresentationRequest) -> Void
    let onToggleGroup: (String) -> Void
    let onFocusPane: (UUID) -> Void
    var paneContextControl: RepoExplorerPaneContextControlFactory = { _, _ in nil }
    var onSetGroupExpanded: (String, Bool) -> Void = { _, _ in }
    var onOpenPaneInEditor: (UUID, EditorTargetId) -> Void = { _, _ in }
}

package struct RepoExplorerPresentedCommand {
    package let request: RepoExplorerCommandPresentationRequest
    package let commandSpec: AppCommandSpec
    package let isEnabled: Bool

    var command: AppCommand {
        commandSpec.command
    }
}

enum RepoExplorerCommandPresentation {
    static func presentedCommand(
        for request: RepoExplorerCommandPresentationRequest,
        snapshot: RepoExplorerCommandPresentationSnapshot
    ) -> RepoExplorerPresentedCommand? {
        guard let isEnabled = snapshot.results[request] else { return nil }
        return RepoExplorerPresentedCommand(
            request: request,
            commandSpec: request.command.definition,
            isEnabled: isEnabled
        )
    }
}

package struct RepoExplorerRepositoryCommandPresentation {
    package static func request(repoID: UUID) -> RepoExplorerCommandPresentationRequest {
        RepoExplorerCommandPresentationRequest(
            command: .updateRepositoryFacts,
            surface: .inlineControl,
            target: repoID,
            targetType: .repo,
            arguments: .noArguments
        )
    }

    package static func resolve(
        repoID: UUID,
        snapshot: RepoExplorerCommandPresentationSnapshot
    ) -> RepoExplorerPresentedCommand? {
        RepoExplorerCommandPresentation.presentedCommand(
            for: request(repoID: repoID),
            snapshot: snapshot
        )
    }
}

package struct RepoExplorerWorktreeCommandPresentation {
    package static let notPresented = Self(
        contextMenuCommandsByIdentity: [:],
        inlineCommandsByIdentity: [:]
    )

    private static let contextMenuWorktreeCommands: [AppCommand] = [
        .openWorktree,
        .openWorktreeInPane,
        .showBridgeReview,
        .showBridgeFiles,
        .openNewTerminalInTab,
        .openBridgeReviewInNewTab,
        .openBridgeFilesInNewTab,
    ]

    private let contextMenuCommandsByIdentity: [AppCommand: RepoExplorerPresentedCommand]
    private let inlineCommandsByIdentity: [AppCommand: RepoExplorerPresentedCommand]

    package static func requests(
        worktreeId: UUID,
        repoId: UUID,
        isPinned: Bool,
        showsPinnedControl: Bool
    ) -> Set<RepoExplorerCommandPresentationRequest> {
        let pinCommand: AppCommand = isPinned ? .unpinRepo : .pinRepo
        var requests = Set(
            contextMenuWorktreeCommands.map { command in
                RepoExplorerCommandPresentationRequest(
                    command: command,
                    surface: .contextMenu,
                    target: worktreeId,
                    targetType: .worktree,
                    arguments: .noArguments
                )
            }
        )
        requests.insert(
            RepoExplorerCommandPresentationRequest(
                command: .openWorktree,
                surface: .inlineControl,
                target: worktreeId,
                targetType: .worktree,
                arguments: .noArguments
            )
        )
        if showsPinnedControl {
            for surface in [AppCommandSurface.contextMenu, .inlineControl] {
                requests.insert(
                    RepoExplorerCommandPresentationRequest(
                        command: pinCommand,
                        surface: surface,
                        target: repoId,
                        targetType: .repo,
                        arguments: .noArguments
                    )
                )
            }
        }
        return requests
    }

    static func resolve(
        worktreeId: UUID,
        repoId: UUID,
        isPinned: Bool,
        showsPinnedControl: Bool,
        snapshot: RepoExplorerCommandPresentationSnapshot
    ) -> Self {
        let presentedCommands = requests(
            worktreeId: worktreeId,
            repoId: repoId,
            isPinned: isPinned,
            showsPinnedControl: showsPinnedControl
        ).compactMap { request -> (RepoExplorerCommandPresentationRequest, RepoExplorerPresentedCommand)? in
            RepoExplorerCommandPresentation.presentedCommand(for: request, snapshot: snapshot)
                .map { (request, $0) }
        }

        return Self(
            contextMenuCommandsByIdentity: Self.index(
                presentedCommands.compactMap { request, command in
                    request.surface == .contextMenu ? command : nil
                }
            ),
            inlineCommandsByIdentity: Self.index(
                presentedCommands.compactMap { request, command in
                    request.surface == .inlineControl ? command : nil
                }
            )
        )
    }

    func contextMenuCommand(_ command: AppCommand) -> RepoExplorerPresentedCommand? {
        contextMenuCommandsByIdentity[command]
    }

    static func contextMenuLabel(for command: AppCommand) -> String? {
        switch command {
        case .openPaneLocationInFinder: return LocalActionSpec.revealInFinder.actionSpec.label
        case .copyCurrentPanePath: return LocalActionSpec.copyPath.actionSpec.label
        case .openPaneLocationInEditorMenu: return LocalActionSpec.openInEditorMenu.actionSpec.label
        case .openNewTerminalInTab, .openWorktreeInPane:
            return "Terminal"
        case .openBridgeReviewInNewTab, .showBridgeReview:
            return "Review"
        case .openBridgeFilesInNewTab, .showBridgeFiles:
            return "Files"
        default:
            return nil
        }
    }

    func inlineCommand(_ command: AppCommand) -> RepoExplorerPresentedCommand? {
        inlineCommandsByIdentity[command]
    }

    private static func index(
        _ presentedCommands: [RepoExplorerPresentedCommand]
    ) -> [AppCommand: RepoExplorerPresentedCommand] {
        Dictionary(
            uniqueKeysWithValues: presentedCommands.map { presentedCommand in
                (presentedCommand.command, presentedCommand)
            }
        )
    }
}

package struct RepoExplorerPaneCommandPresentation {
    package static func requests(
        paneId: UUID,
        isPinned: Bool,
        worktreeId: UUID? = nil
    ) -> Set<RepoExplorerCommandPresentationRequest> {
        let commands: [AppCommand] = [
            isPinned ? .unpinPane : .pinPane, .zoomPane, .editPaneNote,
            .openNewTerminalInTab, .openWorktreeInPane,
            .openPaneLocationInFinder, .copyCurrentPanePath,
        ]
        var requests = Set(
            commands.map { command in
                RepoExplorerCommandPresentationRequest(
                    command: command, surface: .contextMenu,
                    target: paneId, targetType: .pane, arguments: .noArguments
                )
            })
        if let worktreeId {
            for command: AppCommand in [
                .showBridgeReview, .showBridgeFiles,
                .openBridgeReviewInNewTab, .openBridgeFilesInNewTab,
            ] {
                requests.insert(
                    RepoExplorerCommandPresentationRequest(
                        command: command, surface: .contextMenu,
                        target: worktreeId, targetType: .worktree, arguments: .noArguments
                    ))
            }
        }
        return requests
    }

}

package struct RepoExplorerToolbarCommandPresentation {
    private static let toolbarCommands: [AppCommand] = [
        .showReposSidebar,
        .showPanesSidebar,
        .setReposGroupingRepo,
        .setReposGroupingActivity,
        .setReposSortFieldName,
        .setReposSortFieldActivity,
        .toggleReposSortDirection,
        .toggleReposShowsPinned,
        .togglePanesShowsPinned,
        .togglePanesShowsDrawers,
    ]

    private let commandsByIdentity: [AppCommand: RepoExplorerPresentedCommand]

    package static func requests() -> Set<RepoExplorerCommandPresentationRequest> {
        Set(
            toolbarCommands.map { command in
                RepoExplorerCommandPresentationRequest(
                    command: command,
                    surface: .inlineControl,
                    target: nil,
                    targetType: nil,
                    arguments: .noArguments
                )
            }
        )
    }

    static func resolve(
        snapshot: RepoExplorerCommandPresentationSnapshot
    ) -> Self {
        let presentedCommands = toolbarCommands.compactMap { command in
            let request = RepoExplorerCommandPresentationRequest(
                command: command,
                surface: .inlineControl,
                target: nil,
                targetType: nil,
                arguments: .noArguments
            )
            return RepoExplorerCommandPresentation.presentedCommand(for: request, snapshot: snapshot)
        }
        return Self(
            commandsByIdentity: Dictionary(
                uniqueKeysWithValues: presentedCommands.map { presentedCommand in
                    (presentedCommand.command, presentedCommand)
                }
            )
        )
    }

    func command(_ command: AppCommand) -> RepoExplorerPresentedCommand? {
        commandsByIdentity[command]
    }
}

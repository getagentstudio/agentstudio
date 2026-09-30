import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

/// One resolved typed command request: canonical arguments plus the durable
/// handle and permission scope the wire named.
struct AgentStudioIPCResolvedCommandTargets: Sendable {
    let arguments: IPCCommandArguments
    let handle: IPCHandle?
    let target: IPCTargetScope
    /// Every pane identity the arguments name, so pane-agent admission checks
    /// each one rather than only the permission target.
    let paneIds: [UUID]
}

/// Turns friendly typed command arguments into canonical stored identities.
///
/// It never falls back to focus or active selection: a selector that does not
/// name a live durable identity fails with the existing typed target error, and
/// every window-bearing variant validates the one current workspace window.
@MainActor
struct AgentStudioIPCCommandTargetResolver {
    private let workspaceId: UUID
    private let targetAuthorizer: any WorkspaceDurableTargetAuthorizing
    private let ownsWorkspaceWindow: @MainActor (UUID) -> Bool

    init(
        workspaceId: UUID,
        targetAuthorizer: any WorkspaceDurableTargetAuthorizing,
        ownsWorkspaceWindow: @escaping @MainActor (UUID) -> Bool
    ) {
        self.workspaceId = workspaceId
        self.targetAuthorizer = targetAuthorizer
        self.ownsWorkspaceWindow = ownsWorkspaceWindow
    }

    /// Canonicalize during preparation, resolving friendly pane selectors.
    func resolve(
        _ arguments: IPCCommandArguments,
        tools: AppIPCTargetResolutionTools
    ) async throws -> AgentStudioIPCResolvedCommandTargets {
        try validateWindow(in: arguments)
        let canonical = try await canonicalize(arguments, tools: tools)
        try validateDurableIdentities(in: canonical)
        return AgentStudioIPCResolvedCommandTargets(
            arguments: canonical,
            handle: handle(for: canonical),
            target: targetScope(for: canonical),
            paneIds: paneIdentities(in: canonical)
        )
    }

    /// Re-validate immediately before execution. The one current window and
    /// every named identity must still exist; preparation authority is not a
    /// standing grant.
    func validateForExecution(_ arguments: IPCCommandArguments) throws {
        try validateWindow(in: arguments)
        try validateDurableIdentities(in: arguments)
    }

    private func validateWindow(in arguments: IPCCommandArguments) throws {
        guard let workspaceWindowId = arguments.workspaceWindowId else { return }
        guard ownsWorkspaceWindow(workspaceWindowId) else {
            throw AppIPCCommandError(reason: .targetNotFound)
        }
    }

    // MARK: - Canonicalization

    private func canonicalize(
        _ arguments: IPCCommandArguments,
        tools: AppIPCTargetResolutionTools
    ) async throws -> IPCCommandArguments {
        switch arguments {
        case .noArguments, .workspaceWindow, .tab, .renamedTab, .newTab, .tabAnchor,
            .arrangement, .newArrangement, .renamedArrangement, .directory, .repository,
            .worktree, .terminalFromWorktree, .floatingTerminal, .webview:
            return arguments
        case .pane(let value):
            return .pane(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    paneSelector: try await canonicalPane(value.paneSelector, tools: tools)
                ))
        case .sourcePane(let value):
            return .sourcePane(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    sourcePaneSelector: try await canonicalPane(value.sourcePaneSelector, tools: tools)
                ))
        case .standalonePane(let value):
            return .standalonePane(
                .init(paneSelector: try await canonicalPane(value.paneSelector, tools: tools)))
        case .movePaneToTab(let value):
            return .movePaneToTab(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    sourcePaneSelector: try await canonicalPane(value.sourcePaneSelector, tools: tools),
                    destinationTabId: value.destinationTabId
                ))
        case .drawerParent(let value):
            return .drawerParent(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    parentPaneSelector: try await canonicalPane(value.parentPaneSelector, tools: tools)
                ))
        case .drawerSourcePane(let value):
            return .drawerSourcePane(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    parentPaneSelector: try await canonicalPane(value.parentPaneSelector, tools: tools),
                    sourceDrawerPaneSelector: try await canonicalPane(
                        value.sourceDrawerPaneSelector, tools: tools)
                ))
        case .drawerPane(let value):
            return .drawerPane(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    parentPaneSelector: try await canonicalPane(value.parentPaneSelector, tools: tools),
                    drawerPaneSelector: try await canonicalPane(value.drawerPaneSelector, tools: tools)
                ))
        case .detachedDrawerPane(let value):
            return .detachedDrawerPane(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    drawerPaneSelector: try await canonicalPane(value.drawerPaneSelector, tools: tools)
                ))
        case .worktreeInPane(let value):
            return .worktreeInPane(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    worktreeId: value.worktreeId,
                    targetPaneSelector: try await canonicalPane(value.targetPaneSelector, tools: tools)
                ))
        case .terminalFromPane(let value):
            return .terminalFromPane(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    sourcePaneSelector: try await canonicalPane(value.sourcePaneSelector, tools: tools),
                    launchDirectory: value.launchDirectory,
                    title: value.title
                ))
        case .managementFromMainPane(let value):
            return .managementFromMainPane(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    mainPaneSelector: try await canonicalPane(value.mainPaneSelector, tools: tools)
                ))
        case .managementFromDrawerPane(let value):
            return .managementFromDrawerPane(
                .init(
                    workspaceWindowId: value.workspaceWindowId,
                    parentPaneSelector: try await canonicalPane(value.parentPaneSelector, tools: tools),
                    drawerPaneSelector: try await canonicalPane(value.drawerPaneSelector, tools: tools)
                ))
        }
    }

    private func canonicalPane(
        _ selector: IPCPaneSelector,
        tools: AppIPCTargetResolutionTools
    ) async throws -> IPCPaneSelector {
        let handle = try await tools.canonicalizePaneHandle(selector.rawValue)
        guard case (.pane, .canonicalUUID(let paneId)) = (handle.kind, handle.reference),
            targetAuthorizer.containsPane(id: paneId)
        else { throw AppIPCCommandError(reason: .targetNotFound) }
        return try .init(rawValue: paneId.uuidString)
    }

    // MARK: - Durable identity validation

    private func validateDurableIdentities(in arguments: IPCCommandArguments) throws {
        for pane in paneIdentities(in: arguments) {
            guard targetAuthorizer.containsPane(id: pane) else {
                throw AppIPCCommandError(reason: .targetNotFound)
            }
        }
        for tab in tabIdentities(in: arguments) {
            guard targetAuthorizer.containsTab(id: tab) else {
                throw AppIPCCommandError(reason: .targetNotFound)
            }
        }
        switch arguments {
        case .repository(let value):
            guard targetAuthorizer.containsRepository(id: value.repoId) else {
                throw AppIPCCommandError(reason: .targetNotFound)
            }
        case .worktree(let value):
            try validateWorktree(value.worktreeId)
        case .terminalFromWorktree(let value):
            try validateWorktree(value.worktreeId)
        case .worktreeInPane(let value):
            try validateWorktree(value.worktreeId)
        case .arrangement(let value):
            guard targetAuthorizer.containsArrangement(tabId: value.tabId, arrangementId: value.arrangementId)
            else { throw AppIPCCommandError(reason: .targetNotFound) }
        case .renamedArrangement(let value):
            guard targetAuthorizer.containsArrangement(tabId: value.tabId, arrangementId: value.arrangementId)
            else { throw AppIPCCommandError(reason: .targetNotFound) }
        default:
            break
        }
    }

    private func validateWorktree(_ worktreeId: UUID) throws {
        guard targetAuthorizer.containsWorktree(id: worktreeId) else {
            throw AppIPCCommandError(reason: .targetNotFound)
        }
    }

    private func paneIdentities(in arguments: IPCCommandArguments) -> [UUID] {
        let selectors: [IPCPaneSelector] =
            switch arguments {
            case .pane(let value): [value.paneSelector]
            case .sourcePane(let value): [value.sourcePaneSelector]
            case .standalonePane(let value): [value.paneSelector]
            case .movePaneToTab(let value): [value.sourcePaneSelector]
            case .drawerParent(let value): [value.parentPaneSelector]
            case .drawerSourcePane(let value): [value.parentPaneSelector, value.sourceDrawerPaneSelector]
            case .drawerPane(let value): [value.parentPaneSelector, value.drawerPaneSelector]
            case .detachedDrawerPane(let value): [value.drawerPaneSelector]
            case .worktreeInPane(let value): [value.targetPaneSelector]
            case .terminalFromPane(let value): [value.sourcePaneSelector]
            case .managementFromMainPane(let value): [value.mainPaneSelector]
            case .managementFromDrawerPane(let value): [value.parentPaneSelector, value.drawerPaneSelector]
            default: []
            }
        return selectors.compactMap(AppCommandTypedIPCPane.canonicalId)
    }

    private func tabIdentities(in arguments: IPCCommandArguments) -> [UUID] {
        switch arguments {
        case .tab(let value): [value.tabId]
        case .renamedTab(let value): [value.tabId]
        case .tabAnchor(let value): [value.anchorTabId]
        case .arrangement(let value): [value.tabId]
        case .newArrangement(let value): [value.tabId]
        case .renamedArrangement(let value): [value.tabId]
        case .movePaneToTab(let value): [value.destinationTabId]
        default: []
        }
    }

    // MARK: - Handle and scope projection

    private func handle(for arguments: IPCCommandArguments) -> IPCHandle? {
        if let paneId = paneIdentities(in: arguments).first {
            return IPCHandle(kind: .pane, reference: .canonicalUUID(paneId))
        }
        if let tabId = tabIdentities(in: arguments).first {
            return IPCHandle(kind: .tab, reference: .canonicalUUID(tabId))
        }
        if case .repository(let value) = arguments {
            return IPCHandle(kind: .repo, reference: .canonicalUUID(value.repoId))
        }
        guard let workspaceWindowId = arguments.workspaceWindowId else { return nil }
        return IPCHandle(kind: .window, reference: .canonicalUUID(workspaceWindowId))
    }

    private func targetScope(for arguments: IPCCommandArguments) -> IPCTargetScope {
        if let paneId = paneIdentities(in: arguments).first {
            return .pane(paneId.uuidString)
        }
        return .workspace(workspaceId)
    }
}

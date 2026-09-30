import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

@MainActor
struct AgentStudioIPCQueryAdapter: AppIPCQueryPort, @unchecked Sendable {
    private let runtimeId: UUID
    private let accessMode: IPCAccessMode
    private let appVersion: String
    private let workspaceStore: WorkspaceStore
    private let windowLifecycleReader: any WorkspaceWindowLifecycleReading

    init(
        runtimeId: UUID,
        accessMode: IPCAccessMode,
        appVersion: String,
        workspaceStore: WorkspaceStore,
        windowLifecycleReader: any WorkspaceWindowLifecycleReading
    ) {
        self.runtimeId = runtimeId
        self.accessMode = accessMode
        self.appVersion = appVersion
        self.workspaceStore = workspaceStore
        self.windowLifecycleReader = windowLifecycleReader
    }

    func systemIdentify() throws -> IPCSystemIdentifyResult {
        IPCSystemIdentifyResult(runtimeId: runtimeId, accessMode: accessMode, appVersion: appVersion)
    }

    func systemVersion() throws -> IPCSystemVersionResult {
        IPCSystemVersionResult(appVersion: appVersion)
    }

    func listWindows() throws -> IPCWindowListResult {
        let workspace = workspaceStore.programmaticControlSnapshot()
        let lifecycle = windowLifecycleReader.snapshot()
        let windows = lifecycle.registeredWindowIds.enumerated().map { index, windowId in
            IPCWindowSummary(
                id: windowId,
                ordinal: index + 1,
                isKey: windowId == lifecycle.keyWindowId,
                isFocused: windowId == lifecycle.focusedWindowId,
                isCurrent: windowId == lifecycle.preferredWorkspaceWindowId,
                workspaceId: workspace.id
            )
        }
        return IPCWindowListResult(windows: windows)
    }

    func currentWindow() throws -> IPCCurrentWindowResult {
        let lifecycle = windowLifecycleReader.snapshot()
        guard let currentWindowId = lifecycle.preferredWorkspaceWindowId else {
            throw AppIPCQueryError(reason: .noActiveWindow)
        }

        guard let window = try listWindows().windows.first(where: { $0.id == currentWindowId }) else {
            throw AppIPCQueryError(reason: .noActiveWindow)
        }

        return IPCCurrentWindowResult(window: window)
    }

    func listWorkspaces() throws -> IPCWorkspaceListResult {
        IPCWorkspaceListResult(workspaces: [workspaceSummary(isCurrent: true)])
    }

    func currentWorkspace() throws -> IPCCurrentWorkspaceResult {
        _ = try currentWindow()
        return IPCCurrentWorkspaceResult(workspace: workspaceSummary(isCurrent: true))
    }

    func listPanes() throws -> IPCPaneListResult {
        let workspace = workspaceStore.programmaticControlSnapshot()
        return IPCPaneListResult(panes: paneSummaries(in: workspace))
    }

    func currentPane() throws -> IPCPaneSnapshotResult {
        _ = try currentWindow()
        let workspace = workspaceStore.programmaticControlSnapshot()
        guard let activePaneId = workspace.activeTab?.activePaneId else {
            throw AppIPCQueryError(reason: .targetNotFound)
        }
        return try snapshotPane(activePaneId, in: workspace)
    }

    func snapshotPane(_ paneId: UUID, ownPaneAssertion: AppIPCOwnPaneAssertion?) throws -> IPCPaneSnapshotResult {
        _ = try currentWindow()
        let workspace = workspaceStore.programmaticControlSnapshot()
        // Existence first, then membership, in the same main-actor step as the
        // read: a pane that disappeared is not found, and a pane that left a
        // pane agent's own pane since authorization is not described to it.
        guard workspace.panes.contains(where: { $0.id == paneId }) else {
            throw AppIPCQueryError(reason: .targetNotFound)
        }
        if let ownPaneAssertion,
            !workspaceStore.ownPaneAssertionHolds(
                WorkspaceOwnPaneAssertion(boundPaneId: ownPaneAssertion.boundPaneId), for: paneId)
        {
            throw AuthorizationError.notYetAllowed("pane.snapshot")
        }
        return try snapshotPane(paneId, in: workspace)
    }

    private func snapshotPane(
        _ paneId: UUID,
        in workspace: ProgrammaticControlWorkspaceSnapshot
    ) throws -> IPCPaneSnapshotResult {
        let panes = paneSummaries(in: workspace)
        guard let pane = panes.first(where: { $0.id == paneId }) else {
            throw AppIPCQueryError(reason: .targetNotFound)
        }

        let tab = workspace.tabs.first { $0.id == pane.tabId }.map { tabSummary($0, in: workspace) }
        return IPCPaneSnapshotResult(pane: pane, tab: tab, workspace: workspaceSummary(workspace, isCurrent: true))
    }

    private func paneSummaries(in workspace: ProgrammaticControlWorkspaceSnapshot) -> [IPCPaneSummary] {
        workspace.panes.enumerated().map { index, pane in
            IPCPaneSummary(
                id: pane.id,
                ordinal: index + 1,
                contentKind: IPCPaneContentKind(pane.contentKind),
                residency: IPCPaneResidency(pane.residency),
                tabId: pane.tabId,
                repoId: pane.repoId,
                worktreeId: pane.worktreeId,
                isActive: pane.isActive,
                isDrawerChild: pane.isDrawerChild
            )
        }
    }

    private func workspaceSummary(isCurrent: Bool) -> IPCWorkspaceSummary {
        workspaceSummary(workspaceStore.programmaticControlSnapshot(), isCurrent: isCurrent)
    }

    private func workspaceSummary(
        _ workspace: ProgrammaticControlWorkspaceSnapshot,
        isCurrent: Bool
    ) -> IPCWorkspaceSummary {
        IPCWorkspaceSummary(
            id: workspace.id,
            ordinal: 1,
            name: workspace.name,
            tabCount: workspace.tabs.count,
            paneCount: workspace.panes.count,
            repositories: repositorySummaries(in: workspace),
            isCurrent: isCurrent
        )
    }

    private func repositorySummaries(
        in workspace: ProgrammaticControlWorkspaceSnapshot
    ) -> [IPCWorkspaceRepositorySummary] {
        workspace.repositories.map { repo in
            IPCWorkspaceRepositorySummary(
                id: repo.id,
                name: repo.name,
                path: repo.path,
                worktrees: repo.worktrees.map { worktree in
                    IPCWorkspaceWorktreeSummary(
                        id: worktree.id,
                        repoId: worktree.repoId,
                        name: worktree.name,
                        path: worktree.path,
                        isMainWorktree: worktree.isMainWorktree
                    )
                }
            )
        }
    }

    private func tabSummary(
        _ tab: ProgrammaticControlTabSnapshot,
        in workspace: ProgrammaticControlWorkspaceSnapshot
    ) -> IPCTabSummary {
        let ordinal = (workspace.tabs.firstIndex { $0.id == tab.id } ?? 0) + 1
        return IPCTabSummary(
            id: tab.id,
            ordinal: ordinal,
            name: "",
            paneIds: tab.paneIds,
            activePaneId: tab.activePaneId,
            isActive: tab.isActive
        )
    }
}

extension IPCPaneContentKind {
    fileprivate init(_ contentKind: ProgrammaticControlPaneContentKind) {
        switch contentKind {
        case .terminal:
            self = .terminal
        case .webview:
            self = .webview
        case .bridgePanel:
            self = .bridgePanel
        case .codeViewer:
            self = .codeViewer
        case .unsupported:
            self = .unsupported
        }
    }
}

extension IPCPaneResidency {
    fileprivate init(_ residency: ProgrammaticControlPaneResidency) {
        switch residency {
        case .active:
            self = .active
        case .pendingUndo:
            self = .pendingUndo
        case .backgrounded:
            self = .backgrounded
        case .orphaned:
            self = .orphaned
        }
    }
}

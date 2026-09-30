import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

@MainActor
protocol AgentStudioIPCLayoutActionExecuting: AnyObject {
    func execute(_ action: WorkspaceActionCommand) async -> Bool
    func execute(
        _ action: WorkspaceActionCommand,
        ownPaneAssertion: WorkspaceOwnPaneAssertion
    ) async -> WorkspaceScopedActionOutcome
}

extension WorkspaceActionExecutor: AgentStudioIPCLayoutActionExecuting {}

@MainActor
struct AgentStudioIPCLayoutAdapter: AppIPCLayoutPort, @unchecked Sendable {
    private let workspaceStore: WorkspaceStore
    private let windowLifecycleReader: any WorkspaceWindowLifecycleReading
    private weak var paneFocusControl: (any PaneFocusAppControlling & AnyObject)?
    private let workspaceActionExecutor: any AgentStudioIPCLayoutActionExecuting

    init(
        workspaceStore: WorkspaceStore,
        windowLifecycleReader: any WorkspaceWindowLifecycleReading,
        paneFocusControl: any PaneFocusAppControlling & AnyObject,
        workspaceActionExecutor: any AgentStudioIPCLayoutActionExecuting
    ) {
        self.workspaceStore = workspaceStore
        self.windowLifecycleReader = windowLifecycleReader
        self.paneFocusControl = paneFocusControl
        self.workspaceActionExecutor = workspaceActionExecutor
    }

    func focusPane(_ handle: IPCHandle) async throws -> IPCPaneFocusResult {
        guard hasActiveWindow() else {
            throw AppIPCLayoutError(reason: .noActiveWindow)
        }
        guard handle.kind == .pane else {
            throw AppIPCLayoutError(reason: .validationRejected)
        }

        let snapshot = workspaceStore.programmaticControlSnapshot()
        let paneId = try resolvePaneId(handle, in: snapshot)
        guard let paneFocusControl else {
            throw AppIPCLayoutError(reason: .noActiveWindow)
        }

        do {
            try await paneFocusControl.focusPane(paneId)
        } catch PaneFocusAppControlError.targetNotFound {
            throw AppIPCLayoutError(reason: .targetNotFound)
        } catch PaneFocusAppControlError.validationRejected {
            throw AppIPCLayoutError(reason: .validationRejected)
        }

        return IPCPaneFocusResult(paneId: paneId, focused: true)
    }

    func splitPane(_ params: IPCPaneSplitParams) async throws -> IPCPaneSplitResult {
        guard hasActiveWindow() else {
            throw AppIPCLayoutError(reason: .noActiveWindow)
        }
        let snapshot = workspaceStore.programmaticControlSnapshot()
        let paneId = try resolvePaneId(try IPCHandle.parse(params.handle), in: snapshot)
        let tabId = try resolveTabId(forPaneId: paneId, in: snapshot)
        try await executeLayoutAction(
            .insertPane(
                source: .newTerminal,
                targetTabId: tabId,
                targetPaneId: paneId,
                direction: SplitNewDirection(params.direction),
                sizingMode: .halveTarget
            )
        )
        return IPCPaneSplitResult(
            targetPaneId: paneId, direction: params.direction, correlationId: params.correlationId)
    }

    func closePane(
        _ params: IPCPaneCloseParams,
        ownPaneAssertion: AppIPCOwnPaneAssertion?
    ) async throws -> IPCPaneCloseResult {
        guard hasActiveWindow() else {
            throw AppIPCLayoutError(reason: .noActiveWindow)
        }
        let snapshot = workspaceStore.programmaticControlSnapshot()
        let paneId = try resolvePaneId(try IPCHandle.parse(params.handle), in: snapshot)
        let tabId = try resolveTabId(forPaneId: paneId, in: snapshot)
        try await executeLayoutAction(
            closeAction(tabId: tabId, paneId: paneId, in: snapshot, ownPaneAssertion: ownPaneAssertion),
            ownPaneAssertion: ownPaneAssertion,
            refusedName: "pane.close"
        )
        return IPCPaneCloseResult(paneId: paneId, correlationId: params.correlationId)
    }

    /// A pane agent may close only its own drawer child, whose parent is the
    /// agent's bound pane. That close takes the drawer-close semantics the
    /// catalog's `closeDrawerPane` uses, which re-select an unminimized sibling;
    /// the validator re-checks the parent relationship when the gesture runs.
    private func closeAction(
        tabId: UUID,
        paneId: UUID,
        in snapshot: ProgrammaticControlWorkspaceSnapshot,
        ownPaneAssertion: AppIPCOwnPaneAssertion?
    ) -> WorkspaceActionCommand {
        guard let ownPaneAssertion,
            snapshot.panes.contains(where: { $0.id == paneId && $0.isDrawerChild })
        else {
            return .closePane(tabId: tabId, paneId: paneId)
        }
        return .removeDrawerPane(parentPaneId: ownPaneAssertion.boundPaneId, drawerPaneId: paneId)
    }

    func addDrawerPane(
        _ params: IPCDrawerAddPaneParams,
        ownPaneAssertion: AppIPCOwnPaneAssertion?
    ) async throws -> IPCDrawerAddPaneResult {
        guard hasActiveWindow() else {
            throw AppIPCLayoutError(reason: .noActiveWindow)
        }
        let snapshot = workspaceStore.programmaticControlSnapshot()
        let paneId = try resolvePaneId(try IPCHandle.parse(params.parentPaneHandle), in: snapshot)
        try validateDrawerParent(paneId, in: snapshot)
        let content = try Self.backgroundDrawerChildContent(params.content ?? .terminal)
        // IPC creates drawer children in the background: the drawer's
        // expansion, selection and keyboard focus stay as they were. The child
        // is named up front so the caller can target it.
        let childPaneId = UUIDv7.generate()
        try await executeLayoutAction(
            .addDrawerChildInBackground(parentPaneId: paneId, childPaneId: childPaneId, content: content),
            ownPaneAssertion: ownPaneAssertion,
            refusedName: "drawer.addPane"
        )
        guard
            workspaceStore.programmaticControlSnapshot().panes.contains(where: {
                $0.id == childPaneId && $0.isDrawerChild
            })
        else {
            throw AppIPCLayoutError(reason: .validationRejected)
        }
        return IPCDrawerAddPaneResult(
            parentPaneId: paneId, childPaneId: childPaneId, correlationId: params.correlationId)
    }

    /// Drawers hold terminals and browsers only; Bridge, code-viewer and
    /// non-http(s) browser requests are refused before any pane is created.
    private static func backgroundDrawerChildContent(
        _ content: IPCDrawerChildContent
    ) throws -> BackgroundDrawerChildContent {
        switch content {
        case .terminal:
            return .terminal
        case .browser:
            guard let url = content.admissibleBrowserURL else {
                throw AppIPCLayoutError(reason: .validationRejected)
            }
            return .webview(WebviewState(url: url))
        case .bridge, .codeViewer:
            throw AppIPCLayoutError(reason: .validationRejected)
        }
    }

    func toggleDrawer(_ params: IPCDrawerToggleParams) async throws -> IPCDrawerToggleResult {
        guard hasActiveWindow() else {
            throw AppIPCLayoutError(reason: .noActiveWindow)
        }
        let snapshot = workspaceStore.programmaticControlSnapshot()
        let paneId = try resolvePaneId(try IPCHandle.parse(params.parentPaneHandle), in: snapshot)
        try validateDrawerParent(paneId, in: snapshot)
        try await executeLayoutAction(.toggleDrawer(paneId: paneId))
        return IPCDrawerToggleResult(parentPaneId: paneId, correlationId: params.correlationId)
    }

    private func hasActiveWindow() -> Bool {
        let lifecycle = windowLifecycleReader.snapshot()
        guard let currentWindowId = lifecycle.preferredWorkspaceWindowId else {
            return false
        }
        return lifecycle.registeredWindowIds.contains(currentWindowId)
    }

    private func resolvePaneId(
        _ handle: IPCHandle,
        in snapshot: ProgrammaticControlWorkspaceSnapshot
    ) throws -> UUID {
        guard handle.kind == .pane else {
            throw AppIPCLayoutError(reason: .validationRejected)
        }
        switch handle.reference {
        case .canonicalUUID(let paneId):
            guard snapshot.panes.contains(where: { $0.id == paneId }) else {
                throw AppIPCLayoutError(reason: .targetNotFound)
            }
            return paneId

        case .friendlyOrdinal(let ordinal):
            guard let pane = snapshot.panes[safe: ordinal - 1] else {
                throw AppIPCLayoutError(reason: .targetNotFound)
            }
            return pane.id
        }
    }

    private func resolveTabId(
        forPaneId paneId: UUID,
        in snapshot: ProgrammaticControlWorkspaceSnapshot
    ) throws -> UUID {
        guard let pane = snapshot.panes.first(where: { $0.id == paneId }),
            let tabId = pane.tabId
        else {
            throw AppIPCLayoutError(reason: .targetNotFound)
        }
        return tabId
    }

    private func validateDrawerParent(
        _ paneId: UUID,
        in snapshot: ProgrammaticControlWorkspaceSnapshot
    ) throws {
        guard let pane = snapshot.panes.first(where: { $0.id == paneId }) else {
            throw AppIPCLayoutError(reason: .targetNotFound)
        }
        guard !pane.isDrawerChild else {
            throw AppIPCLayoutError(reason: .validationRejected)
        }
    }

    private func executeLayoutAction(_ action: WorkspaceActionCommand) async throws {
        guard await workspaceActionExecutor.execute(action) else {
            throw AppIPCLayoutError(reason: .validationRejected)
        }
    }

    /// A pane agent's layout effect re-checks its own-pane assertion inside
    /// the executor's validation, after every queued gesture ahead of it.
    private func executeLayoutAction(
        _ action: WorkspaceActionCommand,
        ownPaneAssertion: AppIPCOwnPaneAssertion?,
        refusedName: String
    ) async throws {
        guard let ownPaneAssertion else {
            try await executeLayoutAction(action)
            return
        }
        switch await workspaceActionExecutor.execute(
            action, ownPaneAssertion: WorkspaceOwnPaneAssertion(boundPaneId: ownPaneAssertion.boundPaneId))
        {
        case .applied:
            return
        case .outsideOwnPane:
            throw AuthorizationError.notYetAllowed(refusedName)
        case .rejected:
            throw AppIPCLayoutError(reason: .validationRejected)
        }
    }
}

extension SplitNewDirection {
    fileprivate init(_ direction: IPCPaneSplitDirection) {
        switch direction {
        case .left:
            self = .left
        case .right:
            self = .right
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

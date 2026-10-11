import AgentStudioAppIPC
import AgentStudioBridge
import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

@MainActor
protocol AgentStudioIPCBridgeActionExecuting: AnyObject {
    func openBridgeReviewInNewTab(worktreeId: UUID?) -> Pane?
    func openBridgeFilesInNewTab(worktreeId: UUID?) -> Pane?
}

extension WorkspaceActionExecutor: AgentStudioIPCBridgeActionExecuting {}

@MainActor
struct AgentStudioIPCBridgeAdapter: AppIPCBridgePort, @unchecked Sendable {
    private let workspaceStore: WorkspaceStore
    private let viewRegistry: ViewRegistry
    private let actionExecutor: any AgentStudioIPCBridgeActionExecuting

    init(
        workspaceStore: WorkspaceStore,
        viewRegistry: ViewRegistry,
        actionExecutor: any AgentStudioIPCBridgeActionExecuting
    ) {
        self.workspaceStore = workspaceStore
        self.viewRegistry = viewRegistry
        self.actionExecutor = actionExecutor
    }

    func openReview(_ params: IPCBridgeReviewOpenParams) throws -> IPCBridgeReviewOpenResult {
        guard let pane = actionExecutor.openBridgeReviewInNewTab(worktreeId: params.worktreeId) else {
            throw AppIPCBridgeError(reason: .targetNotFound)
        }
        return IPCBridgeReviewOpenResult(
            paneId: pane.id,
            handle: pane.id.uuidString,
            correlationId: params.correlationId
        )
    }

    func openFileView(_ params: IPCBridgeFileViewOpenParams) throws -> IPCBridgeFileViewOpenResult {
        guard let pane = actionExecutor.openBridgeFilesInNewTab(worktreeId: params.worktreeId) else {
            throw AppIPCBridgeError(reason: .targetNotFound)
        }
        return IPCBridgeFileViewOpenResult(
            paneId: pane.id,
            handle: pane.id.uuidString,
            correlationId: params.correlationId
        )
    }

    func refreshReview(_ params: IPCBridgeReviewRefreshParams) async throws -> IPCBridgeReviewRefreshResult {
        let controller = try bridgeController(for: try IPCHandle.parse(params.handle))
        return try await translateAsyncBridgeProjectionError {
            try await controller.refreshReviewForIPC(correlationId: params.correlationId)
        }
    }

    func getPackage(_ handle: IPCHandle) throws -> IPCBridgeReviewPackageResult {
        try translateBridgeProjectionError {
            try bridgeController(for: handle).ipcReviewPackageSnapshot()
        }
    }

    func renderState(_ handle: IPCHandle) async throws -> IPCBridgeRenderStateResult {
        try await bridgeController(for: handle).renderStateForIPC()
    }

    func selectFile(_ params: IPCBridgeReviewSelectFileParams) async throws -> IPCBridgeReviewSelectFileResult {
        let controller = try bridgeController(for: try IPCHandle.parse(params.handle))
        return try await translateAsyncBridgeProjectionError {
            try await controller.selectReviewItemForIPC(
                itemId: params.itemId,
                correlationId: params.correlationId
            )
        }
    }

    func scrollToFile(_ params: IPCBridgeDiffScrollToFileParams) async throws -> IPCBridgePageControlResult {
        let controller = try bridgeController(for: try IPCHandle.parse(params.handle))
        return try await translateAsyncBridgeProjectionError {
            try await controller.applyPageControlForIPC(
                .scrollToFile(itemId: params.itemId),
                correlationId: params.correlationId
            )
        }
    }

    func expandFile(_ params: IPCBridgeDiffExpandFileParams) async throws -> IPCBridgePageControlResult {
        let controller = try bridgeController(for: try IPCHandle.parse(params.handle))
        return try await translateAsyncBridgeProjectionError {
            try await controller.applyPageControlForIPC(
                .expandFile(itemId: params.itemId),
                correlationId: params.correlationId
            )
        }
    }

    func collapseFile(_ params: IPCBridgeDiffCollapseFileParams) async throws -> IPCBridgePageControlResult {
        let controller = try bridgeController(for: try IPCHandle.parse(params.handle))
        return try await translateAsyncBridgeProjectionError {
            try await controller.applyPageControlForIPC(
                .collapseFile(itemId: params.itemId),
                correlationId: params.correlationId
            )
        }
    }

    func searchFileTree(_ params: IPCBridgeFileTreeSearchParams) async throws -> IPCBridgePageControlResult {
        let controller = try bridgeController(for: try IPCHandle.parse(params.handle))
        return try await translateAsyncBridgeProjectionError {
            try await controller.applyPageControlForIPC(
                .fileTreeSearch(searchText: params.searchText, searchMode: params.searchMode),
                correlationId: params.correlationId
            )
        }
    }

    func setFileTreeFilter(_ params: IPCBridgeFileTreeSetFilterParams) async throws -> IPCBridgePageControlResult {
        let controller = try bridgeController(for: try IPCHandle.parse(params.handle))
        return try await translateAsyncBridgeProjectionError {
            try await controller.applyPageControlForIPC(
                .fileTreeSetFilter(candidate: params.candidate),
                correlationId: params.correlationId
            )
        }
    }

    func revealFileTreePath(_ params: IPCBridgeFileTreeRevealPathParams) async throws -> IPCBridgePageControlResult {
        let controller = try bridgeController(for: try IPCHandle.parse(params.handle))
        return try await translateAsyncBridgeProjectionError {
            try await controller.applyPageControlForIPC(
                .fileTreeRevealPath(path: params.path),
                correlationId: params.correlationId
            )
        }
    }

    func showMarkdownPreview(
        _ params: IPCBridgeFileViewShowMarkdownPreviewParams
    ) async throws -> IPCBridgePageControlResult {
        let controller = try bridgeController(for: try IPCHandle.parse(params.handle))
        return try await translateAsyncBridgeProjectionError {
            try await controller.applyPageControlForIPC(
                .fileViewShowMarkdownPreview(itemId: params.itemId),
                correlationId: params.correlationId
            )
        }
    }

    func getContent(_ params: IPCBridgeContentGetParams) async throws -> IPCBridgeContentGetResult {
        let controller = try bridgeController(for: try IPCHandle.parse(params.handle))
        return try await translateAsyncBridgeProjectionError {
            try await controller.loadContentForIPC(
                contentHandleId: params.contentHandleId,
                reviewGeneration: params.reviewGeneration
            )
        }
    }

    func telemetrySnapshot(_ handle: IPCHandle) async throws -> IPCBridgeTelemetrySnapshotResult {
        try await bridgeController(for: handle).telemetrySnapshotForIPC()
    }

    func flushTelemetry(_ handle: IPCHandle) async throws -> IPCBridgeTelemetryFlushResult {
        try await bridgeController(for: handle).flushTelemetryForIPC()
    }

    private func bridgeController(for handle: IPCHandle) throws -> BridgePaneController {
        let paneId = try resolvePaneId(handle)
        guard
            let pane = workspaceStore.programmaticControlSnapshot().panes.first(where: { $0.id == paneId })
        else {
            throw AppIPCBridgeError(reason: .targetNotFound)
        }
        guard pane.contentKind == .bridgePanel else {
            throw AppIPCBridgeError(reason: .unsupportedTarget)
        }
        guard
            let bridgeView = viewRegistry.view(for: paneId)?
                .mountedContent(as: BridgePaneMountView.self)
        else {
            throw AppIPCBridgeError(reason: .targetNotFound)
        }
        return bridgeView.controller
    }

    private func resolvePaneId(_ handle: IPCHandle) throws -> UUID {
        guard handle.kind == .pane else {
            throw AppIPCBridgeError(reason: .validationRejected)
        }
        let snapshot = workspaceStore.programmaticControlSnapshot()
        switch handle.reference {
        case .canonicalUUID(let paneId):
            guard snapshot.panes.contains(where: { $0.id == paneId }) else {
                throw AppIPCBridgeError(reason: .targetNotFound)
            }
            return paneId

        case .friendlyOrdinal(let ordinal):
            guard let pane = snapshot.panes[safe: ordinal - 1] else {
                throw AppIPCBridgeError(reason: .targetNotFound)
            }
            return pane.id
        }
    }

    private func translateBridgeProjectionError<T>(
        _ operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch let error as BridgeIPCProjectionError {
            throw AppIPCBridgeError(error)
        }
    }

    private func translateAsyncBridgeProjectionError<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as BridgeIPCProjectionError {
            throw AppIPCBridgeError(error)
        }
    }
}

extension AppIPCBridgeError {
    fileprivate init(_ error: BridgeIPCProjectionError) {
        switch error.reason {
        case .packageUnavailable:
            self.init(reason: .packageUnavailable)
        case .itemNotFound:
            self.init(reason: .itemNotFound)
        case .contentUnavailable:
            self.init(reason: .contentUnavailable)
        case .payloadTooLarge:
            self.init(reason: .payloadTooLarge)
        case .validationRejected:
            self.init(reason: .validationRejected)
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}

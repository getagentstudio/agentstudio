import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#endif

struct FakeLayoutPort: AppIPCLayoutPort {
    func focusPane(_: IPCHandle) throws -> IPCPaneFocusResult {
        throw AppIPCLayoutError(reason: .targetNotFound)
    }

    func splitPane(_ params: IPCPaneSplitParams) throws -> IPCPaneSplitResult {
        let handle = try IPCHandle.parse(params.handle)
        guard case .canonicalUUID(let paneId) = handle.reference else {
            throw AppIPCLayoutError(reason: .targetNotFound)
        }
        return IPCPaneSplitResult(
            targetPaneId: paneId, direction: params.direction, correlationId: params.correlationId)
    }

    func closePane(_ params: IPCPaneCloseParams, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws
        -> IPCPaneCloseResult
    {
        let handle = try IPCHandle.parse(params.handle)
        guard case .canonicalUUID(let paneId) = handle.reference else {
            throw AppIPCLayoutError(reason: .targetNotFound)
        }
        return IPCPaneCloseResult(paneId: paneId, correlationId: params.correlationId)
    }

    func addDrawerPane(_ params: IPCDrawerAddPaneParams, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws
        -> IPCDrawerAddPaneResult
    {
        let handle = try IPCHandle.parse(params.parentPaneHandle)
        guard case .canonicalUUID(let paneId) = handle.reference else {
            throw AppIPCLayoutError(reason: .targetNotFound)
        }
        return IPCDrawerAddPaneResult(
            parentPaneId: paneId, childPaneId: UUIDv7.generate(), correlationId: params.correlationId)
    }

    func toggleDrawer(_ params: IPCDrawerToggleParams) throws -> IPCDrawerToggleResult {
        let handle = try IPCHandle.parse(params.parentPaneHandle)
        guard case .canonicalUUID(let paneId) = handle.reference else {
            throw AppIPCLayoutError(reason: .targetNotFound)
        }
        return IPCDrawerToggleResult(parentPaneId: paneId, correlationId: params.correlationId)
    }
}

final class FakeSidebarPort: AppIPCSidebarPort {
    let repoGrouping: IPCSidebarGroupingMode
    let inboxGrouping: IPCSidebarGroupingMode
    let surface: IPCSidebarSurface

    nonisolated init(
        repoGrouping: IPCSidebarGroupingMode = .repo,
        inboxGrouping: IPCSidebarGroupingMode = .tab,
        surface: IPCSidebarSurface = .repo
    ) {
        self.repoGrouping = repoGrouping
        self.inboxGrouping = inboxGrouping
        self.surface = surface
    }

    func getGrouping(_ params: IPCSidebarGroupingGetParams) throws -> IPCSidebarGroupingResult {
        switch params.surface {
        case .repo:
            return IPCSidebarGroupingResult(surface: .repo, mode: repoGrouping)
        case .panes:
            return IPCSidebarGroupingResult(surface: .panes, mode: repoGrouping)
        case .inbox:
            return IPCSidebarGroupingResult(surface: .inbox, mode: inboxGrouping)
        }
    }

    func getSurface(_: IPCSidebarSurfaceGetParams) throws -> IPCSidebarSurfaceResult {
        IPCSidebarSurfaceResult(surface: surface)
    }
}

struct FakeRuntimePort: AppIPCRuntimePort {
    let successfulPaneId: UUID?

    nonisolated init(successfulPaneId: UUID? = nil) {
        self.successfulPaneId = successfulPaneId
    }

    func terminalStatus(_: IPCHandle, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws -> IPCTerminalStatusResult {
        guard let successfulPaneId else {
            throw AppIPCRuntimeError(reason: .noRuntime)
        }
        return IPCTerminalStatusResult(
            paneId: successfulPaneId,
            lifecycle: .ready,
            isReady: true,
            backend: .local,
            capabilities: []
        )
    }

    func terminalSnapshot(_: IPCHandle, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws -> IPCTerminalSnapshotResult
    {
        guard let successfulPaneId else {
            throw AppIPCRuntimeError(reason: .noRuntime)
        }
        return IPCTerminalSnapshotResult(
            paneId: successfulPaneId,
            lifecycle: .ready,
            backend: .local,
            capabilities: [],
            lastSequence: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            rendererHealthy: true,
            readOnly: false,
            secureInput: false
        )
    }

    func sendTerminalInput(
        to _: IPCHandle,
        input _: String,
        correlationId: UUID?,
        ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalSendInputResult {
        guard let successfulPaneId else {
            throw AppIPCRuntimeError(reason: .noRuntime)
        }
        return IPCTerminalSendInputResult(
            paneId: successfulPaneId,
            commandId: UUID(),
            correlationId: correlationId,
            disposition: .accepted,
            queuePosition: nil
        )
    }

    func waitForTerminal(
        _: IPCHandle,
        condition _: IPCTerminalWaitCondition,
        timeout _: Duration,
        afterSequence _: UInt64?,
        ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalWaitResult {
        throw AppIPCRuntimeError(reason: .timeout)
    }
}

@MainActor
final class BridgePageControlInvocationRecorder {
    private(set) var filterCandidates: [IPCBridgeFileTreeFilterCandidate] = []

    func recordFilterCandidate(_ candidate: IPCBridgeFileTreeFilterCandidate) {
        filterCandidates.append(candidate)
    }

}

final class BridgeSearchModeInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedModes: [IPCBridgeReviewSearchMode] = []

    func record(_ mode: IPCBridgeReviewSearchMode) {
        lock.withLock {
            recordedModes.append(mode)
        }
    }

    func snapshot() -> [IPCBridgeReviewSearchMode] {
        lock.withLock { recordedModes }
    }
}

struct FakeBridgePort: AppIPCBridgePort {
    let paneId: UUID
    let itemId: String
    let contentHandleId: String
    let pageControlStatus: String
    let pageControlReason: String?
    let renderStateResult: IPCBridgeRenderStateResult?
    let pageControlInvocationRecorder: BridgePageControlInvocationRecorder?
    let searchModeInvocationRecorder: BridgeSearchModeInvocationRecorder?

    nonisolated init(
        paneId: UUID = UUID(),
        itemId: String = "item-source",
        contentHandleId: String = "handle-head",
        pageControlStatus: String = "accepted",
        pageControlReason: String? = nil,
        renderStateResult: IPCBridgeRenderStateResult? = nil,
        pageControlInvocationRecorder: BridgePageControlInvocationRecorder? = nil,
        searchModeInvocationRecorder: BridgeSearchModeInvocationRecorder? = nil
    ) {
        self.paneId = paneId
        self.itemId = itemId
        self.contentHandleId = contentHandleId
        self.pageControlStatus = pageControlStatus
        self.pageControlReason = pageControlReason
        self.renderStateResult = renderStateResult
        self.pageControlInvocationRecorder = pageControlInvocationRecorder
        self.searchModeInvocationRecorder = searchModeInvocationRecorder
    }

    func openReview(_ params: IPCBridgeReviewOpenParams) throws -> IPCBridgeReviewOpenResult {
        IPCBridgeReviewOpenResult(
            paneId: paneId,
            handle: "pane:\(paneId.uuidString)",
            correlationId: params.correlationId
        )
    }

    func openFileView(_ params: IPCBridgeFileViewOpenParams) throws -> IPCBridgeFileViewOpenResult {
        IPCBridgeFileViewOpenResult(
            paneId: paneId,
            handle: "pane:\(paneId.uuidString)",
            correlationId: params.correlationId
        )
    }

    func refreshReview(_ params: IPCBridgeReviewRefreshParams) async throws -> IPCBridgeReviewRefreshResult {
        IPCBridgeReviewRefreshResult(
            paneId: paneId,
            refreshed: true,
            status: "ready",
            packageId: "package-test",
            reviewGeneration: 1,
            correlationId: params.correlationId
        )
    }

    func getPackage(_: IPCHandle) throws -> IPCBridgeReviewPackageResult {
        IPCBridgeReviewPackageResult(
            paneId: paneId,
            status: "ready",
            selectedItemId: nil,
            packageId: "package-test",
            reviewGeneration: 1,
            revision: 1,
            summary: IPCBridgeReviewPackageSummary(
                filesChanged: 1,
                additions: 2,
                deletions: 1,
                visibleFileCount: 1,
                hiddenFileCount: 0
            )
        )
    }

    func renderState(_: IPCHandle) async throws -> IPCBridgeRenderStateResult {
        if let renderStateResult {
            return renderStateResult
        }
        return IPCBridgeRenderStateResult(
            paneId: paneId,
            summary: IPCBridgeRenderSummary(
                pageTitle: "AgentStudio Bridge",
                hasAppRoot: true,
                hasEmptyShell: false,
                hasReviewShell: true,
                sidebarPosition: "right"
            ),
            diagnostics: IPCBridgeRenderDiagnostics(
                evaluateSucceeded: true,
                pageErrorCount: 0,
                pageErrorKinds: [],
                pageErrorMessages: [],
                nativeActivity: .foreground,
                foregroundWorkEpoch: 0,
                dirtyFactPresent: false,
                activeRefreshPassPresent: false,
                refreshPassCount: 0,
                productSession: IPCBridgeProductSessionDiagnostic(
                    activeProducerCount: 2,
                    activeProducerTaskCount: 2,
                    activeContentLeaseCount: 1,
                    queuedFrameCount: 3,
                    queuedByteCount: 4096,
                    pendingFrameWaiterCount: 0,
                    inFlightFrameReceiptCount: 1,
                    pendingLifecycleAcknowledgementCount: 0,
                    nextMetadataStreamSequence: 5
                )
            )
        )
    }

    func selectFile(_ params: IPCBridgeReviewSelectFileParams) async throws -> IPCBridgeReviewSelectFileResult {
        IPCBridgeReviewSelectFileResult(
            paneId: paneId,
            itemId: params.itemId,
            selected: true,
            correlationId: params.correlationId
        )
    }

    func scrollToFile(_ params: IPCBridgeDiffScrollToFileParams) async throws -> IPCBridgePageControlResult {
        bridgePageControlResult(
            method: "bridge.diff.scrollToFile",
            itemId: params.itemId,
            path: nil,
            correlationId: params.correlationId
        )
    }

    func expandFile(_ params: IPCBridgeDiffExpandFileParams) async throws -> IPCBridgePageControlResult {
        bridgePageControlResult(
            method: "bridge.diff.expandFile",
            itemId: params.itemId,
            path: nil,
            correlationId: params.correlationId
        )
    }

    func collapseFile(_ params: IPCBridgeDiffCollapseFileParams) async throws -> IPCBridgePageControlResult {
        bridgePageControlResult(
            method: "bridge.diff.collapseFile",
            itemId: params.itemId,
            path: nil,
            correlationId: params.correlationId
        )
    }

    func searchFileTree(_ params: IPCBridgeFileTreeSearchParams) async throws -> IPCBridgePageControlResult {
        searchModeInvocationRecorder?.record(params.searchMode)
        return bridgePageControlResult(
            method: "bridge.fileTree.search",
            itemId: nil,
            path: nil,
            treeSearchText: params.searchText,
            correlationId: params.correlationId
        )
    }

    func setFileTreeFilter(_ params: IPCBridgeFileTreeSetFilterParams) async throws -> IPCBridgePageControlResult {
        pageControlInvocationRecorder?.recordFilterCandidate(params.candidate)
        return switch params.candidate {
        case .files(let categoryFilter):
            bridgePageControlResult(
                method: "bridge.fileTree.setFilter",
                itemId: nil,
                path: nil,
                filterSurface: .files,
                categoryFilter: categoryFilter,
                correlationId: params.correlationId
            )
        case .review(let gitStatusFilter, let categoryFilter, let showBinary, let showLarge):
            bridgePageControlResult(
                method: "bridge.fileTree.setFilter",
                itemId: nil,
                path: nil,
                filterSurface: .review,
                gitStatusFilter: gitStatusFilter,
                categoryFilter: categoryFilter,
                showBinary: showBinary,
                showLarge: showLarge,
                correlationId: params.correlationId
            )
        }
    }

    func revealFileTreePath(_ params: IPCBridgeFileTreeRevealPathParams) async throws -> IPCBridgePageControlResult {
        bridgePageControlResult(
            method: "bridge.fileTree.revealPath",
            itemId: itemId,
            path: params.path,
            correlationId: params.correlationId
        )
    }

    func showMarkdownPreview(
        _ params: IPCBridgeFileViewShowMarkdownPreviewParams
    ) async throws -> IPCBridgePageControlResult {
        bridgePageControlResult(
            method: "bridge.fileView.showMarkdownPreview",
            itemId: params.itemId ?? itemId,
            path: nil,
            renderMode: "markdownPreview",
            correlationId: params.correlationId
        )
    }

    func getContent(_: IPCBridgeContentGetParams) async throws -> IPCBridgeContentGetResult {
        IPCBridgeContentGetResult(
            paneId: paneId,
            handle: bridgeContentHandleSummary,
            mimeType: "text/x-swift"
        )
    }

    func telemetrySnapshot(_: IPCHandle) async throws -> IPCBridgeTelemetrySnapshotResult {
        IPCBridgeTelemetrySnapshotResult(
            paneId: paneId,
            kind: .report,
            unavailableReason: nil,
            report: IPCBridgeTelemetryReport(
                telemetrySessionId: "telemetry-session-test",
                proofEligible: true,
                lossy: false,
                requiredLossCount: 0,
                optionalLossCount: 0,
                workerSequenceGapCount: 0,
                nativeBatchSequenceGapCount: 0,
                acceptedBatchSequence: 1,
                mainProducerHighWatermark: 4,
                commProducerHighWatermark: 3,
                drainSettlementDisposition: nil,
                workerDiagnostics: IPCBridgeTelemetryWorkerDiagnostics(
                    state: .active,
                    bufferedSampleCount: 0,
                    bufferedSampleByteCount: 0,
                    bufferedLossSummaryCount: 1,
                    bufferedLossSummaryByteCount: 64,
                    outboxCount: 1,
                    outboxByteCount: 256,
                    nextBatchSequence: 2,
                    isPostInFlight: false,
                    mainProducer: IPCBridgeTelemetryProducerDiagnostics(
                        generation: 1,
                        nextSampleSequence: 5,
                        nextControlSequence: 3,
                        sampleCredits: 4,
                        controlCredits: 2
                    ),
                    commProducer: nil,
                    headOutbox: IPCBridgeTelemetryHeadOutboxDiagnostics(
                        batchSequence: 1,
                        retryAttemptCount: 2,
                        retryScheduled: true
                    ),
                    lastBatchDeliveryFailure: nil,
                    lossDiagnostics: [
                        IPCBridgeTelemetryLossDiagnostic(
                            origin: .producer,
                            producerId: .main,
                            lostSequenceStart: 4,
                            lostSequenceEnd: 4,
                            requiredCount: 1,
                            optionalCount: 0,
                            reason: .queueSaturated
                        )
                    ]
                )
            )
        )
    }

    func flushTelemetry(_: IPCHandle) async throws -> IPCBridgeTelemetryFlushResult {
        IPCBridgeTelemetryFlushResult(
            paneId: paneId,
            kind: .report,
            unavailableReason: nil,
            report: IPCBridgeTelemetryReport(
                telemetrySessionId: "telemetry-session-test",
                proofEligible: true,
                lossy: false,
                requiredLossCount: 0,
                optionalLossCount: 0,
                workerSequenceGapCount: 0,
                nativeBatchSequenceGapCount: 0,
                acceptedBatchSequence: 1,
                mainProducerHighWatermark: 4,
                commProducerHighWatermark: 3,
                drainSettlementDisposition: .reopened,
                workerDiagnostics: nil
            ),
            drained: true
        )
    }

    private func bridgePageControlResult(
        method: String,
        itemId: String?,
        path: String?,
        treeSearchText: String = "",
        filterSurface: IPCBridgeFileTreeFilterSurface = .review,
        gitStatusFilter: IPCBridgeGitStatusFilter = .all,
        categoryFilter: IPCBridgeFilterCategory = .all,
        showBinary: Bool = false,
        showLarge: Bool = false,
        renderMode: String = "codeView",
        correlationId: UUID?
    ) -> IPCBridgePageControlResult {
        IPCBridgePageControlResult(
            paneId: paneId,
            method: method,
            status: pageControlStatus,
            itemId: itemId,
            path: path,
            treeSearchText: treeSearchText,
            filterSurface: filterSurface,
            gitStatusFilter: gitStatusFilter,
            categoryFilter: categoryFilter,
            showBinary: showBinary,
            showLarge: showLarge,
            renderMode: renderMode,
            reason: pageControlReason,
            correlationId: correlationId
        )
    }

    private var bridgeContentHandleSummary: IPCBridgeContentHandleSummary {
        IPCBridgeContentHandleSummary(
            identity: IPCBridgeContentHandleIdentity(
                handleId: contentHandleId,
                itemId: itemId,
                role: "head",
                reviewGeneration: 1
            ),
            presentation: IPCBridgeContentHandlePresentation(
                mimeType: "text/x-swift",
                language: "swift"
            ),
            size: IPCBridgeContentHandleSize(sizeBytes: 14, isBinary: false)
        )
    }
}

final class FakeCommandPort: AppIPCCommandPort, @unchecked Sendable {
    let commands: [IPCCommandDescriptor]
    let executionResultsByCommandId: [String: IPCCommandExecutionResult]
    let requiredPermissionTargetByPrivilege: [IPCPrivilegeClass: IPCTargetScope]
    private let lock = NSLock()
    nonisolated(unsafe) private var receivedExecutionRequestsStorage: [IPCCommandExecutionRequest] = []

    nonisolated init(
        commands: [IPCCommandDescriptor] = [],
        executionResultsByCommandId: [String: IPCCommandExecutionResult] = [:],
        requiredPermissionTargetByPrivilege: [IPCPrivilegeClass: IPCTargetScope] = [:]
    ) {
        self.commands = commands
        self.executionResultsByCommandId = executionResultsByCommandId
        self.requiredPermissionTargetByPrivilege = requiredPermissionTargetByPrivilege
    }

    nonisolated var receivedExecutionRequests: [IPCCommandExecutionRequest] {
        lock.withLock {
            receivedExecutionRequestsStorage
        }
    }

    func prepareCommand(
        _ request: IPCCommandExecutionRequest,
        principal _: IPCPrincipal,
        tools: AppIPCTargetResolutionTools
    ) async throws -> AppIPCPreparedCommand {
        guard let command = commands.first(where: { $0.id == request.commandId }) else {
            throw AppIPCCommandError(reason: .unknownCommand)
        }
        guard command.argumentVariants.contains(request.arguments.variant) else {
            throw IPCSchemaValidationError(
                fieldPath: "$.arguments.kind",
                reason: .invalidValue,
                expected: "one argument variant declared by the selected command"
            )
        }
        let requiredScopes = command.requiredPrivileges.map { privilege in
            IPCPermissionScope(
                privilege: privilege,
                target: requiredPermissionTargetByPrivilege[privilege] ?? .app,
                dataScope: command.dataScope
            )
        }
        let preparedRequest: IPCCommandExecutionRequest
        let canonicalHandle: IPCHandle?
        switch request.arguments {
        case .pane(let arguments):
            let handle = try await tools.canonicalizePaneHandle(arguments.paneSelector.rawValue)
            guard case (.pane, .canonicalUUID(let paneId)) = (handle.kind, handle.reference) else {
                throw AppIPCCommandError(reason: .targetNotFound)
            }
            preparedRequest = IPCCommandExecutionRequest(
                commandId: request.commandId,
                correlationId: request.correlationId,
                arguments: .pane(
                    IPCPaneCommandArguments(
                        workspaceWindowId: arguments.workspaceWindowId,
                        paneSelector: try IPCPaneSelector(rawValue: paneId.uuidString)
                    )
                )
            )
            canonicalHandle = handle
        default:
            preparedRequest = request
            canonicalHandle = nil
        }
        return AppIPCPreparedCommand(
            request: preparedRequest,
            canonicalHandle: canonicalHandle,
            target: requiredScopes.first?.target ?? .app,
            requiredScopes: requiredScopes,
            resolvedPaneIds: canonicalHandle.flatMap { handle -> UUID? in
                guard case .canonicalUUID(let paneId) = handle.reference else { return nil }
                return paneId
            }.map { [$0] } ?? [],
            agentArgumentRule: .targetOnly
        )
    }

    func executeCommand(
        _ request: IPCCommandExecutionRequest, ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCCommandExecutionResult {
        lock.withLock {
            receivedExecutionRequestsStorage.append(request)
        }
        guard let result = executionResultsByCommandId[request.commandId.rawValue] else {
            throw AppIPCCommandError(reason: .stateUnavailable)
        }
        return result
    }
}

struct FakeCommandDescriptorInput {
    let id: IPCCommandIdentifier
    let executionMode: IPCCommandExecutionMode
    let arguments: IPCCommandArguments
    let requiredPrivileges: Set<IPCPrivilegeClass>
    let dataScope: IPCDataScope
    let allowedTargetKinds: Set<IPCHandleKind>
    let result: IPCCommandExecutionResult
    var exposure: IPCMethodExposure = .debugTesting
    var agentEligibility: IPCAgentEligibility = .notYetAllowed
}

func makeFakeCommandDescriptor(_ input: FakeCommandDescriptorInput) throws -> IPCCommandDescriptor {
    try IPCCommandDescriptorFactory.make(
        IPCCommandDescriptorInput(
            id: input.id,
            title: "Fixture \(input.id.rawValue)",
            description: "Exercise one typed command fixture.",
            exposure: input.exposure,
            executionMode: input.executionMode,
            argumentVariants: [input.arguments.variant],
            requiredPrivileges: input.requiredPrivileges,
            dataScope: input.dataScope,
            allowedTargetKinds: input.allowedTargetKinds,
            resultVariants: [input.result.variant],
            examples: [
                IPCCommandExample(
                    description: "Typed command fixture",
                    request: IPCCommandExecutionRequest(
                        commandId: input.id,
                        correlationId: input.result.correlationId,
                        arguments: input.arguments
                    ),
                    result: input.result
                )
            ],
            agentEligibility: input.agentEligibility
        )
    )
}

struct FakeUIPresentationPort: AppIPCUIPresentationPort {
    let workspaceWindowId: UUID?
    let arrangementTabId: UUID
    let arrangementContextPaneId: UUID?

    nonisolated init(
        workspaceWindowId: UUID? = UUID(),
        arrangementTabId: UUID = UUID(),
        arrangementContextPaneId: UUID? = nil
    ) {
        self.workspaceWindowId = workspaceWindowId
        self.arrangementTabId = arrangementTabId
        self.arrangementContextPaneId = arrangementContextPaneId
    }

    func openCommandBar(_ params: IPCCommandBarOpenParams) throws -> IPCCommandBarOpenResult {
        guard let workspaceWindowId else {
            throw AppIPCUIPresentationError(reason: .noActiveWindow)
        }
        return IPCCommandBarOpenResult(
            workspaceWindowId: workspaceWindowId,
            scope: params.scope,
            correlationId: params.correlationId
        )
    }

    func openArrangements(_ params: IPCArrangementsOpenParams) throws -> IPCArrangementsOpenResult {
        guard let workspaceWindowId else {
            throw AppIPCUIPresentationError(reason: .noActiveWindow)
        }
        return IPCArrangementsOpenResult(
            workspaceWindowId: workspaceWindowId,
            tabId: arrangementTabId,
            contextPaneId: arrangementContextPaneId,
            correlationId: params.correlationId
        )
    }
}

struct FakePermissionApprovalPort: AppIPCPermissionApprovalPort {
    func decision(for _: PermissionRecord, requester _: IPCPrincipal) -> ApprovalPolicyDecision {
        .ask
    }
}

final class RecordingWaitRuntimePort: AppIPCRuntimePort, @unchecked Sendable {
    private let successfulPaneId: UUID
    private let lock = NSLock()
    nonisolated(unsafe) private var recordedAfterSequence: UInt64?
    nonisolated(unsafe) private var recordedHandle: IPCHandle?

    nonisolated init(successfulPaneId: UUID) {
        self.successfulPaneId = successfulPaneId
    }

    nonisolated var lastAfterSequence: UInt64? {
        lock.withLock {
            recordedAfterSequence
        }
    }

    nonisolated var lastHandle: IPCHandle? {
        lock.withLock {
            recordedHandle
        }
    }

    func terminalStatus(_: IPCHandle, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws -> IPCTerminalStatusResult {
        throw AppIPCRuntimeError(reason: .noRuntime)
    }

    func terminalSnapshot(_: IPCHandle, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws -> IPCTerminalSnapshotResult
    {
        throw AppIPCRuntimeError(reason: .noRuntime)
    }

    func sendTerminalInput(
        to _: IPCHandle,
        input _: String,
        correlationId _: UUID?,
        ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalSendInputResult {
        throw AppIPCRuntimeError(reason: .noRuntime)
    }

    func waitForTerminal(
        _ handle: IPCHandle,
        condition: IPCTerminalWaitCondition,
        timeout _: Duration,
        afterSequence: UInt64?,
        ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalWaitResult {
        lock.withLock {
            recordedHandle = handle
            recordedAfterSequence = afterSequence
        }
        return IPCTerminalWaitResult(
            paneId: successfulPaneId,
            condition: condition,
            eventName: .terminalCommandFinished,
            commandId: nil,
            correlationId: nil,
            exitCode: 0,
            duration: 1,
            healthy: nil
        )
    }
}

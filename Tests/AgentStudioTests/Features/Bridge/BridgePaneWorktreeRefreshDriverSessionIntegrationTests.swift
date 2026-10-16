import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane worktree refresh driver session integration")
@MainActor
struct BridgeWorktreeRefreshSessionTests {
    @Test("E4 resnapshot replays retained File refresh on the same subscription")
    func resnapshotReplaysRetainedRefresh() async throws {
        let (emissionWaiters, emissionWaiterContinuation) = AsyncStream<BridgeProductViewDomainKey>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        defer { emissionWaiterContinuation.finish() }
        var emissionWaiterIterator = emissionWaiters.makeAsyncIterator()
        let (firstSealResults, firstSealResultContinuation) = AsyncStream<RefreshSessionFirstSealResult>
            .makeStream(bufferingPolicy: .bufferingOldest(1))
        defer { firstSealResultContinuation.finish() }
        var firstSealResultIterator = firstSealResults.makeAsyncIterator()
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            viewEmissionWaiterRegistrationObserver: { viewDomain in
                _ = emissionWaiterContinuation.yield(viewDomain)
            }
        )
        let metadataLease = try await harness.admitMetadataFrames(through: 0)
        let pump = makeSessionIntegrationPump(harness, lease: metadataLease)
        try await openSessionIntegrationFileSubscription(
            harness,
            pump: pump,
            requestSequence: 2,
            workerDerivationEpoch: 1
        )
        let viewScope = try sessionIntegrationFileViewScopeRequest()
        #expect(
            await harness.session.acceptViewScope(
                viewScope,
                productAdmission: harness.productAdmission.context
            ) == nil
        )
        let viewDomain = BridgeProductViewDomainKey(
            viewId: viewScope.subscriptionId,
            domain: .singleDomain,
            incarnation: viewScope.incarnation
        )
        let publisher = BridgeRefreshDriverSessionPublisher(
            session: harness.session,
            subscriptionId: viewScope.subscriptionId,
            viewDomain: viewDomain,
            handle: viewScope.handle,
            firstSealResultContinuation: firstSealResultContinuation
        )
        let (terminalEvents, terminalContinuation) = AsyncStream<BridgeOperationLifecycleTraceEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        defer { terminalContinuation.finish() }
        var terminalIterator = terminalEvents.makeAsyncIterator()
        let (driver, coordinator) = makeSessionIntegrationDriver(
            publisher: publisher,
            harness: harness,
            terminalContinuation: terminalContinuation
        )
        driver.recordFileSourceAccepted(try sessionIntegrationFileSource(generation: 1))

        let affectedLanes = driver.recordInvalidation(
            fileChangeset: sessionIntegrationChangeset(batchSequence: 1),
            latestFileStatus: nil,
            requiresReviewRefresh: false
        )
        #expect(affectedLanes == [.file])
        #expect(driver.hasActiveFileOperation)
        let firstSealResult = try #require(await firstSealResultIterator.next())
        guard case .sealed = firstSealResult else {
            Issue.record("Expected the first File refresh to seal a certified batch, got \(firstSealResult)")
            await driver.closeAndDrain()
            try await harness.closeProducer(metadataLease)
            return
        }
        let firstFrame = try await pullMetadataFrame(from: pump)
        guard case .batch(.begin(let firstBegin)) = firstFrame else {
            Issue.record("Expected first certified File batch begin")
            return
        }
        #expect(firstBegin.identity.handle == viewScope.handle)
        #expect(await publisher.attemptCount == 1)
        #expect(await emissionWaiterIterator.next() == viewDomain)

        let resnapshot = try sessionIntegrationFileResnapshotRequest(viewScope)
        #expect(
            await harness.session.acceptViewResnapshot(
                resnapshot,
                productAdmission: harness.productAdmission.context
            ) == nil
        )
        let resetTerminal = try #require(await terminalIterator.next())
        #expect(resetTerminal.result == .stale)
        assertFileStreamRecoveryIsPending(driver: driver, coordinator: coordinator)

        driver.recordFileSourceAccepted(try sessionIntegrationFileSource(generation: 2))
        await publisher.waitForSealCount(2)
        let replayTerminal = try #require(await terminalIterator.next())
        #expect(replayTerminal.result == .success)
        let replay = try await pullSessionIntegrationFileBatch(from: pump)
        assertSessionIntegrationFileReplay(replay, handle: viewScope.handle)
        await assertRetainedRefreshOperationLineage(
            publisher: publisher,
            driver: driver,
            coordinator: coordinator
        )
        await driver.closeAndDrain()
        try await harness.closeProducer(metadataLease)
    }
}

@MainActor
private func makeSessionIntegrationDriver(
    publisher: BridgeRefreshDriverSessionPublisher,
    harness: BridgeProductSessionLifecycleHarness,
    terminalContinuation: AsyncStream<BridgeOperationLifecycleTraceEvent>.Continuation
) -> (BridgePaneWorktreeRefreshDriver, BridgePaneRefreshAdmissionCoordinator) {
    let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
    let driver = BridgePaneWorktreeRefreshDriver(
        coordinator: coordinator,
        acquireProductAdmission: { harness.productAdmission.context },
        publishFileChangeset: { changeset, admission, work, correlationID, attempt in
            await publisher.publish(
                changeset,
                productAdmission: admission,
                foregroundWorkAdmission: work,
                operationCorrelationID: correlationID,
                operationStageAttempt: attempt
            )
        },
        publishFileStatus: { _, _, _, _, _ in .notRequired },
        publishPresentation: { _, _ in },
        publishOperationLifecycle: { event in
            if event.stage == .refreshOperationTerminal {
                await publisher.recordTerminalBeforeSeal(event.result)
                _ = terminalContinuation.yield(event)
            }
        }
    )
    return (driver, coordinator)
}

private enum RefreshSessionFirstSealResult: Equatable, Sendable {
    case sealed
    case rejected(BridgePaneProductFileRefreshPublicationDisposition)
    case terminal(BridgeOperationLifecycleTraceEvent.Result)
}

@MainActor
private func assertFileStreamRecoveryIsPending(
    driver: BridgePaneWorktreeRefreshDriver,
    coordinator: BridgePaneRefreshAdmissionCoordinator
) {
    #expect(driver.hasPendingFileStreamRecovery)
    #expect(coordinator.productPresentationSnapshot.fileRefreshFailure == nil)
}

private func assertSessionIntegrationFileReplay(
    _ replay: SessionIntegrationFileBatch,
    handle: String
) {
    #expect(replay.begin.identity.handle == handle)
    #expect(replay.complete.identity.batchId == replay.begin.identity.batchId)
    #expect(replay.rows.map(\.displayKey) == ["Sources", "Sources/App.swift"])
    #expect(replay.memberStatus.source.subscriptionGeneration == 2)
}

@MainActor
private func assertRetainedRefreshOperationLineage(
    publisher: BridgeRefreshDriverSessionPublisher,
    driver: BridgePaneWorktreeRefreshDriver,
    coordinator: BridgePaneRefreshAdmissionCoordinator
) async {
    #expect(!driver.hasPendingFileStreamRecovery)
    #expect(await publisher.attemptCount == 2)
    let operationCorrelationIDs = await publisher.operationCorrelationIDs
    #expect(operationCorrelationIDs.count == 2)
    #expect(operationCorrelationIDs[0] == operationCorrelationIDs[1])
    #expect(await publisher.operationStageAttempts == [0, 2])
    #expect(coordinator.diagnosticSnapshot.dirtyFact == nil)
}

private actor BridgeRefreshDriverSessionPublisher {
    private let session: BridgeProductSession
    private let subscriptionId: String
    private let viewDomain: BridgeProductViewDomainKey
    private let handle: String
    private let firstSealResultContinuation: AsyncStream<RefreshSessionFirstSealResult>.Continuation
    private var sealWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var attemptCount = 0
    private(set) var sealCount = 0
    private(set) var operationCorrelationIDs: [String] = []
    private(set) var operationStageAttempts: [Int] = []

    init(
        session: BridgeProductSession,
        subscriptionId: String,
        viewDomain: BridgeProductViewDomainKey,
        handle: String,
        firstSealResultContinuation: AsyncStream<RefreshSessionFirstSealResult>.Continuation
    ) {
        self.session = session
        self.subscriptionId = subscriptionId
        self.viewDomain = viewDomain
        self.handle = handle
        self.firstSealResultContinuation = firstSealResultContinuation
    }

    func publish(
        _: FileChangeset,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        operationCorrelationID: String,
        operationStageAttempt: Int
    ) async -> BridgePaneProductFileRefreshPublicationDisposition {
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
            _ = firstSealResultContinuation.yield(.rejected(.stale))
            return .stale
        }
        attemptCount += 1
        operationCorrelationIDs.append(operationCorrelationID)
        operationStageAttempts.append(operationStageAttempt)
        do {
            let sealed = try await session.sealFileCapture(
                subscriptionId: subscriptionId,
                snapshot: try sessionIntegrationFileSnapshot(generation: attemptCount),
                scope: try #require(await session.acceptedViewScope(subscriptionId: subscriptionId)),
                productAdmission: productAdmission
            )
            guard sealed else {
                _ = firstSealResultContinuation.yield(.rejected(.stale))
                return .stale
            }
            sealCount += 1
            resumeSealWaiters()
            if sealCount == 1 { _ = firstSealResultContinuation.yield(.sealed) }
            if attemptCount > 1 { return .applied }
            let outcome = await session.awaitViewEmissionCompletion(for: viewDomain, handle: handle)
            switch outcome {
            case .resnapshotRequired: return .streamResetRequired
            case .completed: return .applied
            case .retired: return .stale
            }
        } catch {
            let disposition = BridgePaneProductMetadataCoordinator.fileRefreshDisposition(for: error)
            _ = firstSealResultContinuation.yield(.rejected(disposition))
            return disposition
        }
    }

    func waitForSealCount(_ expectedCount: Int) async {
        guard sealCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            sealWaiters.append((expectedCount, continuation))
        }
    }

    func recordTerminalBeforeSeal(_ result: BridgeOperationLifecycleTraceEvent.Result) {
        guard sealCount == 0 else { return }
        _ = firstSealResultContinuation.yield(.terminal(result))
    }

    private func resumeSealWaiters() {
        var pendingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in sealWaiters {
            if sealCount >= expectedCount {
                continuation.resume()
            } else {
                pendingWaiters.append((expectedCount, continuation))
            }
        }
        sealWaiters = pendingWaiters
    }
}

private func makeSessionIntegrationPump(
    _ harness: BridgeProductSessionLifecycleHarness,
    lease: BridgeProductProducerLease
) -> BridgeProductSchemeFramePump {
    BridgeProductSchemeFramePump(
        session: harness.session,
        producerLease: lease,
        productAdmission: harness.productAdmission.context,
        acknowledgeLifecycle: { _ in true }
    )
}

private func openSessionIntegrationFileSubscription(
    _ harness: BridgeProductSessionLifecycleHarness,
    pump: BridgeProductSchemeFramePump,
    requestSequence: Int,
    workerDerivationEpoch: Int
) async throws {
    let request = try bridgeProductLifecycleControlRequest(
        bridgeProductLifecycleFileSubscriptionOpenObject(
            requestSequence: requestSequence,
            epoch: workerDerivationEpoch
        )
    )
    let token = try #require(controlExecutionToken(try await harness.begin(request)))
    #expect(await harness.session.admitControlProviderExecution(token: token))
    let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
        correlating: request,
        worktreeId: nil
    )
    _ = try await harness.session.completeAdmittedControl(
        token: token,
        exactResponseBytes: try JSONEncoder().encode(response)
    )
    guard case .subscriptionAccepted = try await pullMetadataFrame(from: pump) else {
        throw BridgeRefreshDriverSessionIntegrationError.expectedSubscriptionAcceptance
    }
    await harness.session.settleControlProviderDispatch(token: token)
}

private func sessionIntegrationFileViewScopeRequest() throws -> BridgeProductViewScopeRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductViewScopeRequest.self,
        from: Data(
            """
            {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
            "workerInstanceId":"worker-instance-1","requestId":"integration-file-scope-3",\
            "requestSequence":3,"subscriptionId":"file-subscription-1",\
            "subscriptionKind":"file.metadata","domain":"default",\
            "handle":"integration-file-handle-1","incarnation":"integration-file-incarnation-1",\
            "scopeRevision":1,"scope":{"kind":"file","changeFilter":{"kind":"none"},\
            "interests":[],"pathScope":[]}}
            """.utf8
        )
    )
}

private func sessionIntegrationFileResnapshotRequest(
    _ viewScope: BridgeProductViewScopeRequest
) throws -> BridgeProductViewResnapshotRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductViewResnapshotRequest.self,
        from: Data(
            """
            {"kind":"subscription.resnapshot","wireVersion":2,"paneSessionId":"pane-session-1",\
            "workerInstanceId":"worker-instance-1","requestId":"integration-file-resnapshot-4",\
            "requestSequence":4,"subscriptionId":"\(viewScope.subscriptionId)",\
            "subscriptionKind":"file.metadata","domain":"default",\
            "handle":"\(viewScope.handle)","incarnation":"\(viewScope.incarnation)",\
            "scopeRevision":\(viewScope.scopeRevision)}
            """.utf8
        )
    )
}

private func sessionIntegrationFileSnapshot(
    generation: Int
) throws -> BridgeWorktreeFileKeyedSnapshot {
    let source = try sessionIntegrationFileSource(generation: generation)
    let directory = BridgeWorktreeTreeRowMetadata(
        rowId: "row-sources",
        path: "Sources",
        name: "Sources",
        parentPath: nil,
        depth: 0,
        isDirectory: true,
        fileId: nil,
        fileClass: nil,
        sizeBytes: nil,
        lineCount: nil,
        changeStatus: nil
    )
    let file = BridgeWorktreeTreeRowMetadata(
        rowId: "row-app-swift",
        path: "Sources/App.swift",
        name: "App.swift",
        parentPath: "Sources",
        depth: 1,
        isDirectory: false,
        fileId: "file-app-swift",
        fileClass: .source,
        sizeBytes: 8,
        lineCount: 1,
        changeStatus: "modified"
    )
    return BridgeWorktreeFileKeyedSnapshot(
        isEnumerationComplete: true,
        memberStatus: .init(record: .init(source: source), revision: generation),
        records: [
            .init(key: "/workspace/Sources", revision: generation, row: directory, descriptorOutcome: nil),
            .init(
                key: "/workspace/Sources/App.swift",
                revision: generation,
                row: file,
                descriptorOutcome: nil
            ),
        ],
        targetRevision: generation,
        tombstoneRevisionByKey: [:],
        absenceFloorRevisionByRange: [:]
    )
}

private struct SessionIntegrationFileBatch {
    let begin: BridgeProductBatchBeginFrame
    let complete: BridgeProductBatchCompleteFrame
    let rows: [BridgeProductFileBatchRow]
    let memberStatus: BridgeProductFileMemberStatusRecord
}

private func pullSessionIntegrationFileBatch(
    from pump: BridgeProductSchemeFramePump
) async throws -> SessionIntegrationFileBatch {
    var begin: BridgeProductBatchBeginFrame?
    var rows: [BridgeProductFileBatchRow] = []
    var memberStatus: BridgeProductFileMemberStatusRecord?
    while true {
        let frame = try await pullMetadataFrame(from: pump)
        guard case .batch(let batch) = frame else { continue }
        switch batch {
        case .begin(let receivedBegin):
            guard receivedBegin.targetRevision == 2 else { continue }
            begin = receivedBegin
            rows = []
            memberStatus = nil
        case .part(let receivedPart):
            guard let begin, receivedPart.identity.batchId == begin.identity.batchId,
                case .put(let key, _, let value) = receivedPart.part
            else { continue }
            let encodedValue = try JSONEncoder().encode(value)
            if key == BridgeProductFileMemberStatusRecord.recordKey {
                memberStatus = try JSONDecoder().decode(
                    BridgeProductFileMemberStatusRecord.self,
                    from: encodedValue
                )
            } else {
                rows.append(try JSONDecoder().decode(BridgeProductFileBatchRow.self, from: encodedValue))
            }
        case .complete(let complete):
            guard let begin, complete.identity.batchId == begin.identity.batchId else { continue }
            return SessionIntegrationFileBatch(
                begin: begin,
                complete: complete,
                rows: rows,
                memberStatus: try #require(memberStatus)
            )
        }
    }
}

private func sessionIntegrationChangeset(batchSequence: UInt64) -> FileChangeset {
    FileChangeset(
        worktreeId: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
        repoId: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        rootPath: URL(fileURLWithPath: "/tmp/bridge-refresh-driver-session"),
        paths: ["Sources/App.swift"],
        timestamp: .now,
        batchSeq: batchSequence
    )
}

private func sessionIntegrationFileSource(
    generation: Int
) throws -> BridgeProductFileSourceIdentity {
    try .init(
        repoId: "00000000-0000-4000-8000-000000000001",
        rootRevisionToken: "root-token-1",
        sourceCursor: "generation-\(generation)",
        sourceId: "file-source-\(generation)",
        subscriptionGeneration: generation,
        worktreeId: "00000000-0000-4000-8000-000000000002"
    )
}

private enum BridgeRefreshDriverSessionIntegrationError: Error {
    case expectedSubscriptionAcceptance
}

import AgentStudioCore
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

struct ReconnectSubscriptionContext {
    let dispatcher: BridgeProductSchemeControlDispatcher
    let fileSource: ReconnectFileMetadataSource
    let firstStream: ReconnectMetadataStream
    let refreshWorkAdmission: BridgePaneRefreshWorkAdmission
    let harness: BridgeProductSessionLifecycleHarness
    let initialBatch: BridgeProductBatchCompleteFrame
    let provider: BridgePaneProductSchemeProvider
    let retainedSubscription: BridgeProductSubscriptionSnapshot
}

struct ReconnectMetadataStream {
    let pump: BridgeProductSchemeFramePump
}

struct ReconnectFileSourceDiagnostics: Sendable {
    let cancellationCount: Int
    let viewHandle: String?
    let scopeRevision: Int?
    let openCallCount: Int
    let publicationCallCount: Int
    let updateCallCount: Int
}

actor ReconnectFileMetadataSource: BridgePaneProductFileMetadataProducing {
    private var activeSubscriptionIds: Set<String> = []
    private var cancellationCount = 0
    private var acceptedViewHandle: String?
    private var acceptedScopeRevision: Int?
    private var openCallCount = 0
    private var publicationCallCount = 0
    private var updateCallCount = 0
    private var activeSubscriptionWaiters: [CheckedContinuation<Void, Never>] = []
    private var updateCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var openCompletionStepByOrdinal: [Int: HeldStep<Void>] = [:]

    func holdOpenCompletion(ordinal: Int, at step: HeldStep<Void>) {
        openCompletionStepByOrdinal[ordinal] = step
    }

    func waitForUpdateCallCount(_ count: Int) async {
        if updateCallCount >= count { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            updateCallWaiters.append((count, continuation))
        }
    }

    var hasActiveSubscription: Bool { !activeSubscriptionIds.isEmpty }

    /// Returns once this source has an open subscription. The source itself owns that
    /// fact and resumes waiters from `open(_:)`, so there is no turn budget: a 2000-turn
    /// loop drains fastest exactly when the machine is slowest, which is when the
    /// subscription is most likely to still be in flight.
    func waitForActiveSubscription() async {
        if activeSubscriptionIds.isEmpty == false {
            return
        }
        await withCheckedContinuation { continuation in
            activeSubscriptionWaiters.append(continuation)
        }
    }

    private func resumeActiveSubscriptionWaiters() {
        let waiters = activeSubscriptionWaiters
        activeSubscriptionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeUpdateCallWaiters() {
        let readyWaiters = updateCallWaiters.filter { $0.0 <= updateCallCount }
        updateCallWaiters.removeAll { $0.0 <= updateCallCount }
        for (_, waiter) in readyWaiters {
            waiter.resume()
        }
    }

    var diagnostics: ReconnectFileSourceDiagnostics {
        .init(
            cancellationCount: cancellationCount,
            viewHandle: acceptedViewHandle,
            scopeRevision: acceptedScopeRevision,
            openCallCount: openCallCount,
            publicationCallCount: publicationCallCount,
            updateCallCount: updateCallCount
        )
    }

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func captureKeyedSnapshot(
        subscriptionId: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? {
        guard activeSubscriptionIds.contains(subscriptionId),
            let source = try? BridgeProductFileSourceIdentity(
                repoId: "00000000-0000-4000-8000-000000000001",
                rootRevisionToken: "root-token-reconnect",
                sourceCursor: publicationCallCount == 0 ? "source-cursor-initial" : "source-cursor-post-reconnect",
                sourceId: "file-source-reconnect",
                subscriptionGeneration: 1,
                worktreeId: "00000000-0000-4000-8000-000000000002"
            )
        else { return nil }
        return .init(
            isEnumerationComplete: true,
            memberStatus: .init(record: .init(source: source), revision: publicationCallCount + 1),
            records: [],
            targetRevision: publicationCallCount + 1,
            tombstoneRevisionByKey: [:],
            absenceFloorRevisionByRange: [:]
        )
    }

    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        openCallCount += 1
        activeSubscriptionIds.insert(subscription.subscriptionId)
        // Released before the emit suspends: the subscription is already open here, so a
        // waiter should not be held behind the first event's delivery.
        resumeActiveSubscriptionWaiters()
        try await emit(try reconnectFileSourceAcceptedEvent(cursor: "initial"))
        if let openCompletionStep = openCompletionStepByOrdinal.removeValue(forKey: openCallCount) {
            try await openCompletionStep.arrive(())
            try Task.checkCancellation()
        }
    }

    func applyViewDemand(
        subscriptionId: String,
        demand: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        guard activeSubscriptionIds.contains(subscriptionId) else { return }
        acceptedViewHandle = demand.handle
        acceptedScopeRevision = demand.scopeRevision
        updateCallCount += 1
        resumeUpdateCallWaiters()
    }

    func cancel(subscriptionId: String) {
        activeSubscriptionIds.remove(subscriptionId)
        acceptedViewHandle = nil
        acceptedScopeRevision = nil
        cancellationCount += 1
    }

    func publish(
        status _: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] { [] }

    func publish(
        changeset _: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] {
        publicationCallCount += 1
        return try activeSubscriptionIds.sorted().map { subscriptionId in
            BridgePaneProductFileMetadataEmission(
                fact: try reconnectFileSourceAcceptedEvent(cursor: "post-reconnect"),
                subscriptionId: subscriptionId
            )
        }
    }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? { nil }
}

func makeReconnectSubscriptionContext() async throws -> ReconnectSubscriptionContext {
    let harness = try await BridgeProductSessionLifecycleHarness.opened()
    let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
    let fileSource = ReconnectFileMetadataSource()
    let provider = BridgePaneProductSchemeProvider(
        fileMetadataSource: fileSource,
        reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
        reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
        markReviewItemViewed: { _, _ in },
        refreshWorkAdmissionSource: refreshWorkAdmission.source
    )
    let dispatcher = makeBridgeProductSchemeControlDispatcher(
        session: harness.session,
        provider: provider,
        productAdmission: harness.productAdmission.context
    )
    let firstStream = try await installReconnectMetadataStream(
        request: bridgeProductMetadataStreamRequest(
            metadataStreamId: "metadata-before-reconnect",
            resumeFromStreamSequence: nil
        ),
        provider: provider,
        harness: harness
    )
    let established = try await establishReconnectFileSubscription(
        dispatcher: dispatcher,
        fileSource: fileSource,
        harness: harness,
        stream: firstStream
    )
    return ReconnectSubscriptionContext(
        dispatcher: dispatcher,
        fileSource: fileSource,
        firstStream: firstStream,
        refreshWorkAdmission: refreshWorkAdmission.admission,
        harness: harness,
        initialBatch: established.initialBatch,
        provider: provider,
        retainedSubscription: established.retainedSubscription
    )
}

func establishReconnectFileSubscription(
    dispatcher: BridgeProductSchemeControlDispatcher,
    fileSource: ReconnectFileMetadataSource,
    harness: BridgeProductSessionLifecycleHarness,
    stream: ReconnectMetadataStream
) async throws -> (
    initialBatch: BridgeProductBatchCompleteFrame,
    retainedSubscription: BridgeProductSubscriptionSnapshot
) {
    let openRequest = try bridgeProductLifecycleControlRequest(
        bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
    )
    _ = try await dispatchReconnectControl(
        openRequest,
        dispatcher: dispatcher,
        capabilityHeader: harness.capabilityHeader
    )
    guard case .subscriptionAccepted = try await pullMetadataFrame(from: stream.pump) else {
        throw ReconnectSubscriptionTestError.expectedSubscriptionAcceptance
    }
    await fileSource.waitForActiveSubscription()
    let scopeRequest = try reconnectFileScopeRequest()
    let scopeResponse = try await dispatchReconnectControl(
        scopeRequest,
        dispatcher: dispatcher,
        capabilityHeader: harness.capabilityHeader
    )
    guard case .viewAccepted = scopeResponse else {
        throw ReconnectSubscriptionTestError.expectedScopeAcceptance
    }
    await waitForReconnectSourceUpdate(fileSource)
    guard case .batch(.begin) = try await pullMetadataFrame(from: stream.pump),
        case .batch(.part(let initialPart)) = try await pullMetadataFrame(from: stream.pump),
        case .batch(.complete(let initialBatch)) = try await pullMetadataFrame(from: stream.pump)
    else { throw ReconnectSubscriptionTestError.expectedBatch }
    try await acknowledgeReconnectPart(initialPart, harness: harness)
    let retainedSubscription = try #require(
        await harness.session.subscriptionSnapshot(subscriptionId: "file-subscription-1")
    )
    return (initialBatch, retainedSubscription)
}

func acknowledgeReconnectPart(
    _ part: BridgeProductBatchPartFrame,
    harness: BridgeProductSessionLifecycleHarness
) async throws {
    let requestBytes = try JSONSerialization.data(withJSONObject: [
        "kind": "subscription.acknowledge",
        "wireVersion": BridgeProductWireContract.version,
        "paneSessionId": bridgeProductTestPaneSessionId,
        "workerInstanceId": bridgeProductTestWorkerInstanceId,
        "subscriptionId": part.identity.subscriptionId,
        "domain": part.identity.domain,
        "handle": part.identity.handle,
        "incarnation": part.identity.incarnation,
        "receivedThroughDeliverySequence": part.deliverySequence,
    ])
    let request = try BridgeProductStrictJSON.decode(
        BridgeProductViewAcknowledgementRequest.self,
        from: requestBytes
    )
    #expect(
        await harness.session.acknowledgeViewReceipt(
            request,
            exactRequestBytes: requestBytes,
            productAdmission: harness.productAdmission.context
        ) != nil
    )
}

func reconnectFileScopeRequest() throws -> BridgeProductControlRequest {
    try bridgeProductLifecycleControlRequest([
        "domain": "default",
        "handle": "file-reconnect-view-handle",
        "incarnation": "file-reconnect-view-incarnation",
        "kind": "subscription.setScope",
        "paneSessionId": bridgeProductTestPaneSessionId,
        "requestId": "request-reconnect-file-scope-3",
        "requestSequence": 3,
        "scope": [
            "kind": "file",
            "changeFilter": ["kind": "none"],
            "interests": [["lane": "foreground", "paths": ["Sources/App.swift"]]],
            "pathScope": [],
        ],
        "scopeRevision": 1,
        "subscriptionId": "file-subscription-1",
        "subscriptionKind": "file.metadata",
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": bridgeProductTestWorkerInstanceId,
    ])
}

func reconnectFileResnapshotRequest() throws -> BridgeProductControlRequest {
    try bridgeProductLifecycleControlRequest([
        "domain": "default",
        "handle": "file-reconnect-view-handle",
        "incarnation": "file-reconnect-view-incarnation",
        "kind": "subscription.resnapshot",
        "paneSessionId": bridgeProductTestPaneSessionId,
        "requestId": "request-reconnect-file-resnapshot-5",
        "requestSequence": 5,
        "scopeRevision": 1,
        "subscriptionId": "file-subscription-1",
        "subscriptionKind": "file.metadata",
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": bridgeProductTestWorkerInstanceId,
    ])
}

func installReconnectMetadataStream(
    request: BridgeProductMetadataStreamRequest,
    provider: BridgePaneProductSchemeProvider,
    harness: BridgeProductSessionLifecycleHarness
) async throws -> ReconnectMetadataStream {
    let session = harness.session
    let productAdmission = harness.productAdmission.context
    let registration = await session.registerMetadataProducer(
        request: request,
        productAdmission: productAdmission
    ) { lease in
        await provider.runMetadataProducer(
            request: request,
            lease: lease,
            productAdmission: productAdmission,
            session: session
        )
    }
    let lease = try bridgeProductAcceptedLease(registration)
    let pump = BridgeProductSchemeFramePump(
        session: session,
        producerLease: lease,
        productAdmission: productAdmission,
        acknowledgeLifecycle: provider.acknowledgeLifecycle
    )
    guard case .metadataStreamAccepted = try await pullMetadataFrame(from: pump) else {
        throw ReconnectSubscriptionTestError.expectedMetadataStreamAcceptance
    }
    return ReconnectMetadataStream(pump: pump)
}

func dispatchReconnectControl(
    _ request: BridgeProductControlRequest,
    dispatcher: BridgeProductSchemeControlDispatcher,
    capabilityHeader: String
) async throws -> BridgeProductControlResponse {
    let encoder = JSONEncoder()
    // Exact control retries compare wire bytes, not decoded object equality.
    encoder.outputFormatting = [.sortedKeys]
    let result = try await dispatcher.dispatch(
        exactRequestBytes: try encoder.encode(request),
        presentedCapability: capabilityHeader
    )
    guard case .response(let responseData) = result else {
        throw ReconnectSubscriptionTestError.expectedControlResponse
    }
    let admitted = try BridgeProductStrictJSON.decode(
        BridgeProductOperationAdmittedResponse.self,
        from: responseData
    )
    await dispatcher.session.waitForOperationExecution(operationId: admitted.operationId)
    guard
        let settlement = await dispatcher.session.operationTable.entriesById[admitted.operationId]?.settlement,
        settlement.outcome == .succeeded,
        let responseValue = settlement.result
    else { throw ReconnectSubscriptionTestError.expectedControlResponse }
    return try BridgeProductStrictJSON.decode(
        BridgeProductControlResponse.self,
        from: JSONEncoder().encode(responseValue)
    )
}

/// Pulls the complete certified File bank after reconnect.
///
/// The pump's `nextFrame()` already suspends until a frame exists, so the old
/// `queuedFrameCount` guard was a test-side re-implementation of the pump's own waiting,
/// and the 2 s cap around it only decided the verdict by machine speed. A non-`.frame`
/// pull result (cancelled or finished) throws out of `pullMetadataFrame`, which is the
/// real terminal outcome here — not a deadline.
func pullPostReconnectPublication(
    from pump: BridgeProductSchemeFramePump
) async throws -> BridgeProductBatchCompleteFrame {
    while true {
        let frame = try await pullMetadataFrame(from: pump)
        if case .batch(.complete(let completed)) = frame { return completed }
    }
}

func reconnectResyncRequest(
    subscription: BridgeProductSubscriptionSnapshot,
    lastAcceptedStreamSequence: Int
) throws -> BridgeProductControlRequest {
    try bridgeProductLifecycleControlRequest([
        "activeSubscriptions": [
            [
                "subscriptionId": subscription.subscriptionId,
                "subscriptionKind": subscription.subscriptionKind.rawValue,
                "workerDerivationEpoch": subscription.workerDerivationEpoch,
            ]
        ],
        "kind": "workerSession.resync",
        "lastAcceptedRequestSequence": 3,
        "lastAcceptedStreamSequence": lastAcceptedStreamSequence,
        "paneSessionId": bridgeProductTestPaneSessionId,
        "requestId": "request-reconnect-resync-4",
        "requestSequence": 4,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": bridgeProductTestWorkerInstanceId,
    ])
}

func reconnectFileSourceAcceptedEvent(
    cursor: String
) throws -> BridgePaneProductFileSourceFact {
    .sourceAccepted(
        try .init(
            repoId: "00000000-0000-4000-8000-000000000001",
            rootRevisionToken: "root-token-reconnect",
            sourceCursor: "source-cursor-\(cursor)",
            sourceId: "file-source-reconnect",
            subscriptionGeneration: 1,
            worktreeId: "00000000-0000-4000-8000-000000000002"
        ))
}

func reconnectFileChangeset() throws -> FileChangeset {
    let worktreeIdentifier = "00000000-0000-4000-8000-000000000002"
    let repositoryIdentifier = "00000000-0000-4000-8000-000000000001"
    let repositoryUUID: UUID = try #require(UUID(uuidString: repositoryIdentifier))
    return FileChangeset(
        worktreeId: try #require(UUID(uuidString: worktreeIdentifier)),
        repoId: repositoryUUID,
        rootPath: URL(fileURLWithPath: "/tmp/bridge-metadata-reconnect"),
        paths: ["Sources/App.swift"],
        timestamp: .now,
        batchSeq: 1
    )
}

/// Barriers on the source's own signals. They cannot report failure, so callers no longer
/// assert on them: reaching the next line IS the proof that the subscription opened, and a
/// source that never opens hangs the test under the lane watchdog with its name attached,
/// instead of returning false after an arbitrary number of turns.
func waitForReconnectSourceActivity(_ source: ReconnectFileMetadataSource) async {
    await source.waitForActiveSubscription()
}

func waitForReconnectSourceUpdate(_ source: ReconnectFileMetadataSource) async {
    await source.waitForUpdateCallCount(1)
}

enum ReconnectSubscriptionTestError: Error {
    case expectedControlResponse
    case expectedMetadataStreamAcceptance
    case expectedSubscriptionAcceptance
    case expectedBatch
    case expectedScopeAcceptance
}

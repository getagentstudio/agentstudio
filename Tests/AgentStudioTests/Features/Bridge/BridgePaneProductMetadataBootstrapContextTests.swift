import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product metadata bootstrap context ownership")
struct BridgePaneProductMetadataBootstrapContextTests {
    @Test("unperturbed real File bootstrap emits its final tree")
    func unperturbedRealFileBootstrapEmitsFinalTree() async throws {
        let result = try await runRealFileBootstrapScenario(induceReplayCommitOverlap: false)

        #expect(result.resetCount == 0)
        #expect(result.finalTreeSources == [result.currentSource])
    }

    /// The overlap this models — a replay-driven bootstrap racing the commit-driven
    /// bootstrap of the same subscription — can only occur on a RESUME stream. On a
    /// fresh stream, D10 retires the subscriptions captured at install instead of
    /// replaying them, so the replay opens nothing and no bootstrap ever starts.
    @Test("resumed-stream replay bootstrap cannot lose the current File final tree")
    func resumedStreamReplayBootstrapPreservesCurrentFileFinalTree() async throws {
        let result = try await runRealFileBootstrapScenario(induceReplayCommitOverlap: true)

        #expect(result.resetCount == 0)
        #expect(result.finalTreeSources == [result.currentSource])
    }

    /// The D10 negative for this fixture, and S16b's capture-at-install guarantee.
    ///
    /// A fresh stream captures its stale set at install, when the File subscription does
    /// not exist yet, so the set is empty. The subscription committed AFTER install
    /// therefore belongs to the new client: the replay must start no bootstrap for it and
    /// must not retire it.
    @Test("fresh-stream replay starts no bootstrap for a subscription committed after install")
    func freshStreamReplayStartsNoBootstrapForSubscriptionCommittedAfterInstall() async throws {
        let observation = try await runFreshStreamReplayScenario()

        #expect(observation.bootstrapStartedCountAfterReplay == 0)
        #expect(observation.subscriptionIdsAfterReplay == ["file-subscription-1"])
        #expect(observation.resetCount == 0)
        #expect(observation.finalTreeSources == [observation.currentSource])
    }
}

private struct BootstrapContextScenarioResult {
    let currentSource: BridgeProductFileSourceIdentity
    let finalTreeSources: [BridgeProductFileSourceIdentity]
    let resetCount: Int
}

private struct BootstrapContextScenarioResources {
    let coordinator: BridgePaneProductMetadataCoordinator
    let fixture: ProductFileSourceFixture
    let frameCollector: BootstrapContextMetadataFrameCollector
    let frameDrain: Task<Void, any Error>
    let harness: BridgeProductSessionLifecycleHarness
    let lifecycleRecorder: BootstrapContextLifecycleRecorder
    let producerLease: BridgeProductProducerLease
    let pump: BridgeProductSchemeFramePump
    let sourceObserver: BootstrapContextSourceAcceptedObserver
}

private struct BootstrapContextOpenedControl {
    let effect: BridgeProductSessionCompletionEffect
    let token: BridgeProductControlAdmissionToken
}

private struct FreshStreamReplayObservation {
    let bootstrapStartedCountAfterReplay: Int
    let currentSource: BridgeProductFileSourceIdentity
    let finalTreeSources: [BridgeProductFileSourceIdentity]
    let resetCount: Int
    let subscriptionIdsAfterReplay: [String]
}

/// Installs a FRESH stream, commits the File subscription after that install, and runs
/// the replay to completion.
///
/// `replaySubscriptionsForInstalledStream()` is awaited directly rather than spawned:
/// its return IS the owner's completion barrier, so the two facts are read once,
/// immediately after it, with no wait of any kind. The scenario then finishes through
/// the ordinary non-overlap path so the fixture tears down clean.
private func runFreshStreamReplayScenario() async throws -> FreshStreamReplayObservation {
    let resources = try await makeBootstrapContextScenarioResources(
        induceReplayCommitOverlap: false
    )
    defer { resources.fixture.remove() }
    var pendingControlToken: BridgeProductControlAdmissionToken?
    var didCancelSubscription = false

    do {
        await resources.coordinator.install(
            request: try bootstrapContextMetadataStreamRequest(resumeFromStreamSequence: nil),
            lease: resources.producerLease,
            productAdmission: resources.harness.productAdmission.context,
            session: resources.harness.session
        )
        let openedControl = try await commitBootstrapContextFileSubscription(
            resources: resources
        )
        pendingControlToken = openedControl.token

        await resources.coordinator.replaySubscriptionsForInstalledStream()
        let bootstrapStartedCountAfterReplay = await resources.lifecycleRecorder.bootstrapStartedCount
        let subscriptionIdsAfterReplay = await resources.harness.session.subscriptionSnapshots()
            .map(\.subscriptionId)

        await runBootstrapContextSchedule(
            resources: resources,
            openEffect: openedControl.effect,
            induceReplayCommitOverlap: false
        )
        try await acceptBootstrapContextFileViewScope(resources)
        let fileComplete = await resources.frameCollector.waitUntilFileBatchComplete()
        #expect(fileComplete.identity.subscriptionId == "file-subscription-1")
        await resources.harness.session.settleControlProviderDispatch(token: openedControl.token)
        pendingControlToken = nil
        try await cancelBootstrapContextFileSubscription(
            harness: resources.harness,
            coordinator: resources.coordinator
        )
        didCancelSubscription = true
        let cancellation = await resources.frameCollector.waitUntilCurrentSubscriptionCancellation()
        #expect(cancellation.identity.subscriptionIdentity.subscriptionId == "file-subscription-1")
        let result = try await bootstrapContextScenarioResult(resources: resources)
        try await finishBootstrapContextScenario(resources)
        return FreshStreamReplayObservation(
            bootstrapStartedCountAfterReplay: bootstrapStartedCountAfterReplay,
            currentSource: result.currentSource,
            finalTreeSources: result.finalTreeSources,
            resetCount: result.resetCount,
            subscriptionIdsAfterReplay: subscriptionIdsAfterReplay
        )
    } catch {
        await cleanupFailedBootstrapContextScenario(
            resources: resources,
            pendingControlToken: pendingControlToken,
            didCancelSubscription: didCancelSubscription
        )
        throw error
    }
}

private func runRealFileBootstrapScenario(
    induceReplayCommitOverlap: Bool
) async throws -> BootstrapContextScenarioResult {
    let resources = try await makeBootstrapContextScenarioResources(
        induceReplayCommitOverlap: induceReplayCommitOverlap
    )
    defer { resources.fixture.remove() }
    var pendingControlToken: BridgeProductControlAdmissionToken?
    var didCancelSubscription = false

    do {
        // The overlap scenario needs the replay to OPEN a subscription that already
        // exists, which only the resume branch does. On a fresh stream D10 retires the
        // set captured at install instead, so no bootstrap would ever start.
        await resources.coordinator.install(
            request: try bootstrapContextMetadataStreamRequest(
                resumeFromStreamSequence: induceReplayCommitOverlap ? 0 : nil
            ),
            lease: resources.producerLease,
            productAdmission: resources.harness.productAdmission.context,
            session: resources.harness.session
        )
        let openedControl = try await commitBootstrapContextFileSubscription(
            resources: resources
        )
        pendingControlToken = openedControl.token
        await runBootstrapContextSchedule(
            resources: resources,
            openEffect: openedControl.effect,
            induceReplayCommitOverlap: induceReplayCommitOverlap
        )
        try await acceptBootstrapContextFileViewScope(resources)
        let fileComplete = await resources.frameCollector.waitUntilFileBatchComplete()
        #expect(fileComplete.identity.subscriptionId == "file-subscription-1")
        await resources.harness.session.settleControlProviderDispatch(token: openedControl.token)
        pendingControlToken = nil
        try await cancelBootstrapContextFileSubscription(
            harness: resources.harness,
            coordinator: resources.coordinator
        )
        didCancelSubscription = true
        let cancellation = await resources.frameCollector.waitUntilCurrentSubscriptionCancellation()
        #expect(cancellation.identity.subscriptionIdentity.subscriptionId == "file-subscription-1")
        let result = try await bootstrapContextScenarioResult(resources: resources)
        try await finishBootstrapContextScenario(resources)
        return result
    } catch {
        await cleanupFailedBootstrapContextScenario(
            resources: resources,
            pendingControlToken: pendingControlToken,
            didCancelSubscription: didCancelSubscription
        )
        throw error
    }
}

private func makeBootstrapContextScenarioResources(
    induceReplayCommitOverlap: Bool
) async throws -> BootstrapContextScenarioResources {
    let harness = try await BridgeProductSessionLifecycleHarness.opened()
    let fixture = try ProductFileSourceFixture(fileCount: 2, productAdmission: harness.productAdmission)
    do {
        let producerLease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: producerLease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let frameCollector = BootstrapContextMetadataFrameCollector()
        let lifecycleRecorder = BootstrapContextLifecycleRecorder(
            holdFirstBootstrapStart: induceReplayCommitOverlap
        )
        let sourceObserver = BootstrapContextSourceAcceptedObserver(
            holdFirstAcceptance: induceReplayCommitOverlap
        )
        let source = fixture.makeSource(sourceAcceptedObserver: { acceptedSource in
            await sourceObserver.record(acceptedSource)
        })
        let foregroundAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: source,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: foregroundAdmission.source,
            lifecycleTraceRecorder: lifecycleRecorder
        )
        let frameDrain = Task {
            try await drainBootstrapContextMetadataFrames(from: pump, into: frameCollector)
        }
        return .init(
            coordinator: coordinator,
            fixture: fixture,
            frameCollector: frameCollector,
            frameDrain: frameDrain,
            harness: harness,
            lifecycleRecorder: lifecycleRecorder,
            producerLease: producerLease,
            pump: pump,
            sourceObserver: sourceObserver
        )
    } catch {
        fixture.remove()
        throw error
    }
}

private func commitBootstrapContextFileSubscription(
    resources: BootstrapContextScenarioResources
) async throws -> BootstrapContextOpenedControl {
    let request = try bootstrapContextFileSubscriptionOpenRequest(fixture: resources.fixture)
    let token = try #require(
        bootstrapContextControlExecutionToken(try await resources.harness.begin(request))
    )
    #expect(await resources.harness.session.admitControlProviderExecution(token: token))
    let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
        correlating: request,
        worktreeId: nil
    )
    let effect = try await resources.harness.session.completeAdmittedControl(
        token: token,
        exactResponseBytes: try JSONEncoder().encode(response)
    )
    return .init(effect: effect, token: token)
}

private func acceptBootstrapContextFileViewScope(
    _ resources: BootstrapContextScenarioResources
) async throws {
    let request = try BridgeProductStrictJSON.decode(
        BridgeProductViewScopeRequest.self,
        from: Data(
            """
            {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
            "workerInstanceId":"worker-instance-1","requestId":"bootstrap-context-file-scope",\
            "requestSequence":3,"subscriptionId":"file-subscription-1",\
            "subscriptionKind":"file.metadata","domain":"default",\
            "handle":"bootstrap-context-file-handle","incarnation":"bootstrap-context-file-incarnation",\
            "scopeRevision":1,"scope":{"kind":"file","changeFilter":{"kind":"none"},\
            "interests":[],"pathScope":[]}}
            """.utf8
        )
    )
    #expect(
        await resources.coordinator.acceptViewScope(
            request,
            productAdmission: resources.harness.productAdmission.context
        ) == nil
    )
}

private func runBootstrapContextSchedule(
    resources: BootstrapContextScenarioResources,
    openEffect: BridgeProductSessionCompletionEffect,
    induceReplayCommitOverlap: Bool
) async {
    guard induceReplayCommitOverlap else {
        await resources.coordinator.apply(
            openEffect,
            productAdmission: resources.harness.productAdmission.context
        )
        #expect(await resources.lifecycleRecorder.waitUntilBootstrapFinished(count: 1) >= 1)
        return
    }
    let replay = Task {
        await resources.coordinator.replaySubscriptionsForInstalledStream()
    }
    #expect(await resources.lifecycleRecorder.waitUntilFirstBootstrapStartIsHeld() == 1)
    await resources.coordinator.apply(
        openEffect,
        productAdmission: resources.harness.productAdmission.context
    )
    #expect(await resources.lifecycleRecorder.bootstrapStartedCount == 1)
    await resources.lifecycleRecorder.releaseFirstBootstrapStart()
    let firstAcceptedSource = await resources.sourceObserver.waitUntilFirstAcceptanceIsHeld()
    #expect(firstAcceptedSource.subscriptionGeneration == 1)
    let acceptedSources = await resources.sourceObserver.acceptedSources
    #expect(acceptedSources.count == 1)
    await resources.sourceObserver.releaseFirstAcceptance()
    #expect(await resources.lifecycleRecorder.waitUntilBootstrapFinished(count: 1) >= 1)
    await replay.value
}

private func bootstrapContextScenarioResult(
    resources: BootstrapContextScenarioResources
) async throws -> BootstrapContextScenarioResult {
    let collectedFrames = await resources.frameCollector.frames
    let currentSource = try #require(await resources.sourceObserver.acceptedSources.last)
    var sourceByBatchID: [String: BridgeProductFileSourceIdentity] = [:]
    var finalTreeSources: [BridgeProductFileSourceIdentity] = []
    for frame in collectedFrames {
        guard case .batch(let batch) = frame else { continue }
        switch batch {
        case .part(let part):
            guard case .put(let key, _, let value) = part.part,
                key == BridgeProductFileMemberStatusRecord.recordKey
            else { continue }
            let status = try JSONDecoder().decode(
                BridgeProductFileMemberStatusRecord.self,
                from: JSONEncoder().encode(value)
            )
            sourceByBatchID[part.identity.batchId] = status.source
        case .complete(let complete):
            if let source = sourceByBatchID[complete.identity.batchId] {
                finalTreeSources.append(source)
            }
        case .begin:
            continue
        }
    }
    let resetCount = collectedFrames.count { frame in
        guard case .subscriptionReset(let reset) = frame else { return false }
        return reset.identity.subscriptionIdentity.subscriptionId == "file-subscription-1"
    }
    return .init(
        currentSource: currentSource,
        finalTreeSources: finalTreeSources,
        resetCount: resetCount
    )
}

private func finishBootstrapContextScenario(
    _ resources: BootstrapContextScenarioResources
) async throws {
    await resources.coordinator.uninstall(lease: resources.producerLease)
    #expect(await resources.pump.cancel())
    try await resources.frameDrain.value
}

private func cleanupFailedBootstrapContextScenario(
    resources: BootstrapContextScenarioResources,
    pendingControlToken: BridgeProductControlAdmissionToken?,
    didCancelSubscription: Bool
) async {
    await resources.lifecycleRecorder.releaseFirstBootstrapStart()
    await resources.sourceObserver.releaseFirstAcceptance()
    if let pendingControlToken {
        await resources.harness.session.settleControlProviderDispatch(token: pendingControlToken)
    }
    if !didCancelSubscription {
        _ = try? await cancelBootstrapContextFileSubscription(
            harness: resources.harness,
            coordinator: resources.coordinator
        )
    }
    await resources.coordinator.uninstall(lease: resources.producerLease)
    _ = await resources.pump.cancel()
    _ = await resources.frameDrain.result
}

private actor BootstrapContextLifecycleRecorder: BridgeProductMetadataLifecycleTraceRecording {
    private(set) var bootstrapStartedCount = 0
    private var bootstrapFinishedCount = 0
    private var bootstrapFinishedWaiters: [(Int, CheckedContinuation<Int, Never>)] = []
    private let holdFirstBootstrapStart: Bool
    private var firstBootstrapStartHeld = false
    private var firstBootstrapStartHeldWaiters: [CheckedContinuation<Int, Never>] = []
    private let firstBootstrapStartStep = HeldStep<Void>(
        "first bootstrap start", cancellation: .holdThroughCancellation)

    init(holdFirstBootstrapStart: Bool) {
        self.holdFirstBootstrapStart = holdFirstBootstrapStart
    }

    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) async {
        // Counted before the hold, so a held start is still counted.
        if event.stage == .bootstrapStarted { bootstrapStartedCount += 1 }
        if event.stage == .bootstrapStarted, holdFirstBootstrapStart, !firstBootstrapStartHeld {
            firstBootstrapStartHeld = true
            let waiters = firstBootstrapStartHeldWaiters
            firstBootstrapStartHeldWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume(returning: bootstrapStartedCount) }
            try? await firstBootstrapStartStep.arrive(())
        }
        guard event.stage == .bootstrapFinished else { return }
        bootstrapFinishedCount += 1
        let readyWaiters = bootstrapFinishedWaiters.filter { bootstrapFinishedCount >= $0.0 }
        bootstrapFinishedWaiters.removeAll { bootstrapFinishedCount >= $0.0 }
        for (_, waiter) in readyWaiters { waiter.resume(returning: bootstrapFinishedCount) }
    }

    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) async {}

    func waitUntilFirstBootstrapStartIsHeld() async -> Int {
        guard !firstBootstrapStartHeld else { return bootstrapStartedCount }
        return await withCheckedContinuation { continuation in
            firstBootstrapStartHeldWaiters.append(continuation)
        }
    }

    func releaseFirstBootstrapStart() {
        firstBootstrapStartStep.release()
    }

    func waitUntilBootstrapFinished(count: Int) async -> Int {
        guard bootstrapFinishedCount < count else { return bootstrapFinishedCount }
        return await withCheckedContinuation { continuation in
            bootstrapFinishedWaiters.append((count, continuation))
        }
    }
}

private actor BootstrapContextSourceAcceptedObserver {
    private(set) var acceptedSources: [BridgeProductFileSourceIdentity] = []
    private let holdFirstAcceptance: Bool
    private var firstAcceptanceHeldWaiters: [CheckedContinuation<BridgeProductFileSourceIdentity, Never>] = []
    private var firstAcceptanceRelease: CheckedContinuation<Void, Never>?

    init(holdFirstAcceptance: Bool) {
        self.holdFirstAcceptance = holdFirstAcceptance
    }

    var firstAcceptedSource: BridgeProductFileSourceIdentity? {
        acceptedSources.first
    }

    func record(_ source: BridgeProductFileSourceIdentity) async {
        acceptedSources.append(source)
        guard holdFirstAcceptance, acceptedSources.count == 1 else { return }
        let waiters = firstAcceptanceHeldWaiters
        firstAcceptanceHeldWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: source) }
        await withCheckedContinuation { continuation in
            firstAcceptanceRelease = continuation
        }
    }

    func waitUntilFirstAcceptanceIsHeld() async -> BridgeProductFileSourceIdentity {
        if let first = acceptedSources.first { return first }
        return await withCheckedContinuation { continuation in
            firstAcceptanceHeldWaiters.append(continuation)
        }
    }

    func releaseFirstAcceptance() {
        firstAcceptanceRelease?.resume()
        firstAcceptanceRelease = nil
    }
}

private actor BootstrapContextMetadataFrameCollector {
    private(set) var frames: [BridgeProductMetadataFrame] = []
    private var fileBatchComplete: BridgeProductBatchCompleteFrame?
    private var fileBatchCompleteWaiters: [CheckedContinuation<BridgeProductBatchCompleteFrame, Never>] = []
    private var cancellation: BridgeProductSubscriptionCancelledFrame?
    private var cancellationWaiters: [CheckedContinuation<BridgeProductSubscriptionCancelledFrame, Never>] = []

    func append(_ frame: BridgeProductMetadataFrame) {
        frames.append(frame)
        if case .batch(.complete(let complete)) = frame,
            complete.identity.subscriptionId == "file-subscription-1"
        {
            fileBatchComplete = complete
            let waiters = fileBatchCompleteWaiters
            fileBatchCompleteWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume(returning: complete) }
        }
        guard case .subscriptionCancelled(let cancelled) = frame,
            cancelled.identity.subscriptionIdentity.subscriptionId == "file-subscription-1"
        else { return }
        cancellation = cancelled
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: cancelled) }
    }

    func waitUntilFileBatchComplete() async -> BridgeProductBatchCompleteFrame {
        if let fileBatchComplete { return fileBatchComplete }
        return await withCheckedContinuation { continuation in
            fileBatchCompleteWaiters.append(continuation)
        }
    }

    func waitUntilCurrentSubscriptionCancellation() async -> BridgeProductSubscriptionCancelledFrame {
        if let cancellation { return cancellation }
        return await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }
}

private func drainBootstrapContextMetadataFrames(
    from pump: BridgeProductSchemeFramePump,
    into collector: BootstrapContextMetadataFrameCollector
) async throws {
    while true {
        switch await pump.nextFrame() {
        case .frame(let delivery):
            let decoder = try BridgeProductMetadataFrameDecoder()
            let frame = try decoder.append(delivery.frame.data).first
            guard await pump.acknowledgeFrameConsumed(delivery.receipt) else {
                throw BootstrapContextTestError.frameAcknowledgementRejected
            }
            if let frame {
                await collector.append(frame)
            }
        case .cancelled, .finished:
            return
        case .rejected:
            throw BootstrapContextTestError.framePullRejected
        }
    }
}

private enum BootstrapContextTestError: Error {
    case frameAcknowledgementRejected
    case framePullRejected
}

private func bootstrapContextControlExecutionToken(
    _ admission: BridgeProductSessionControlAdmission
) -> BridgeProductControlAdmissionToken? {
    guard case .execute(let token, _) = admission else { return nil }
    return token
}

private func bootstrapContextFileSubscriptionOpenRequest(
    fixture: ProductFileSourceFixture
) throws -> BridgeProductControlRequest {
    try bridgeProductLifecycleControlRequest(
        bootstrapContextControlIdentity(
            kind: "subscription.open",
            requestId: "bootstrap-context-file-open",
            requestSequence: 2,
            workerDerivationEpoch: 0
        ).merging([
            "subscription": [
                "source": [
                    "cwdScope": NSNull(),
                    "freshness": "live",
                    "includeStatuses": true,
                    "repoId": fixture.repoId.uuidString,
                    "rootPathToken": StableKey.fromPath(fixture.rootURL),
                    "worktreeId": fixture.worktreeId.uuidString,
                ],
                "subscriptionKind": "file.metadata",
            ],
            "subscriptionId": "file-subscription-1",
        ]) { _, new in new }
    )
}

private func bootstrapContextFileSubscriptionCancelRequest(
    requestSequence: Int
) throws -> BridgeProductControlRequest {
    try bridgeProductLifecycleControlRequest(
        bootstrapContextControlIdentity(
            kind: "subscription.cancel",
            requestId: "bootstrap-context-file-cancel",
            requestSequence: requestSequence,
            workerDerivationEpoch: 0
        ).merging([
            "subscriptionId": "file-subscription-1",
            "subscriptionKind": "file.metadata",
        ]) { _, new in new }
    )
}

private func bootstrapContextControlIdentity(
    kind: String,
    requestId: String,
    requestSequence: Int,
    workerDerivationEpoch: Int
) -> [String: Any] {
    [
        "kind": kind,
        "paneSessionId": "pane-session-1",
        "requestId": requestId,
        "requestSequence": requestSequence,
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": workerDerivationEpoch,
        "workerInstanceId": "worker-instance-1",
    ]
}

/// Builds the stream request this fixture installs.
///
/// `resumeFromStreamSequence` decides which replay branch the coordinator takes, so
/// each scenario states it explicitly: `nil` is a fresh open (D10 retires the captured
/// stale set), an integer is a resume (the replay snapshots and defers as before).
private func bootstrapContextMetadataStreamRequest(
    resumeFromStreamSequence: Int?
) throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": "metadata-stream-1",
            "paneSessionId": "pane-session-1",
            "resumeFromStreamSequence": resumeFromStreamSequence.map { $0 as Any } ?? NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(BridgeProductMetadataStreamRequest.self, from: data)
}

private func cancelBootstrapContextFileSubscription(
    harness: BridgeProductSessionLifecycleHarness,
    coordinator: BridgePaneProductMetadataCoordinator
) async throws {
    let request = try bootstrapContextFileSubscriptionCancelRequest(requestSequence: 3)
    guard
        let token = bootstrapContextControlExecutionToken(
            try await harness.begin(request)
        )
    else { return }
    guard await harness.session.admitControlProviderExecution(token: token) else { return }
    let response = try BridgeProductControlResponse.subscriptionCancelAccepted(correlating: request)
    let effect = try await harness.session.completeAdmittedControl(
        token: token,
        exactResponseBytes: try JSONEncoder().encode(response)
    )
    await coordinator.apply(effect, productAdmission: harness.productAdmission.context)
    await harness.session.settleControlProviderDispatch(token: token)
}

import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
struct PanePublicationFixture {
    let paneAdmission: BridgeProductAdmissionContext
    let installationGate: BridgeProductAdmissionGate
    let harness: BridgeProductSessionLifecycleHarness
    let lease: BridgeProductProducerLease
    let pump: BridgeProductSchemeFramePump
    let fileRefreshDriver: BridgePaneWorktreeRefreshDriver
    let schemeProvider: BridgePaneProductSchemeProvider
    let coordinator: BridgePaneProductMetadataCoordinator
    let refresh: BridgePaneRefreshAdmissionCoordinator
    let fileFixture: ProductFileSourceFixture
    let fileSource: PanePublicationFileSource
    let reviewSource: PanePublicationReviewSource
    let replay: AvailabilityReviewPublicationProvider
    let trace: PanePublicationBootstrapTrace

    static func make() async throws -> Self {
        let original = try await BridgeProductSessionLifecycleHarness.opened()
        let installationGate = BridgeProductAdmissionGate()
        let composed = try #require(original.productAdmission.context.withInstallation(installationGate))
        let harness = BridgeProductSessionLifecycleHarness(
            capabilityHeader: original.capabilityHeader,
            productAdmission: .init(gate: original.productAdmission.gate, context: composed), session: original.session)
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session, producerLease: lease, productAdmission: composed,
            acknowledgeLifecycle: { _ in true })
        let fileFixture = try ProductFileSourceFixture(fileCount: 1, productAdmission: harness.productAdmission)
        let fileSource = PanePublicationFileSource(source: fileFixture.makeSource())
        let reviewSource = PanePublicationReviewSource()
        let replay = AvailabilityReviewPublicationProvider()
        let trace = PanePublicationBootstrapTrace()
        let refresh = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let fileRefreshDriver = BridgePaneWorktreeRefreshDriver(
            coordinator: refresh,
            acquireProductAdmission: { harness.productAdmission.context },
            publishFileChangeset: { _, _, _, _, _ in .notRequired },
            publishFileStatus: { _, _, _, _, _ in .notRequired },
            publishPresentation: { _, _ in }
        )
        let schemeProvider = BridgePaneProductSchemeProvider(
            fileMetadataSource: fileSource,
            reviewMetadataSource: reviewSource,
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            reviewPublicationReplay: { _ in replay.publication },
            markReviewItemViewed: { _, _ in },
            applyFileRefreshRetry: { admission in
                await fileRefreshDriver.retryUnavailableFileRefreshAndWait(ifAdmittedBy: admission)
            },
            recordCurrentFileRefreshFailure: { failure in
                refresh.recordCurrentFileRefreshFailure(failure)
            },
            refreshWorkAdmissionSource: refresh.workAdmissionSource,
            lifecycleTraceRecorder: trace)
        let coordinator = await schemeProvider.metadataCoordinator
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(), lease: lease, productAdmission: composed,
            session: harness.session)
        return Self(
            paneAdmission: original.productAdmission.context, installationGate: installationGate,
            harness: harness, lease: lease, pump: pump, fileRefreshDriver: fileRefreshDriver,
            schemeProvider: schemeProvider,
            coordinator: coordinator, refresh: refresh,
            fileFixture: fileFixture, fileSource: fileSource, reviewSource: reviewSource, replay: replay, trace: trace)
    }

    func openFile() async throws {
        let completion = try await openFileSubscription()
        #expect(completion.result == .success)
        try await acceptFileViewScope()
        _ = try await nextBatch()
    }

    func openFileSubscription() async throws -> BridgeProductMetadataLifecycleTraceEvent {
        var object = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        object["subscription"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fileFixture.openSnapshot().subscription))
        return try await openSubscription(object)
    }

    func beginFileSubscription() async throws -> (bootstrapCount: Int, token: BridgeProductControlAdmissionToken) {
        var object = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        object["subscription"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fileFixture.openSnapshot().subscription))
        let request = try bridgeProductLifecycleControlRequest(object)
        guard case .subscriptionOpen(let opening) = request else {
            throw ProductFileSourceFixtureError.invalidControlRequest
        }
        let bootstrapCount = await trace.count(for: opening.subscription.subscriptionKind) + 1
        let token = try #require(controlExecutionToken(try await harness.begin(request)))
        #expect(await harness.session.admitControlProviderExecution(token: token))
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: request,
            worktreeId: nil
        )
        let effect = try await harness.session.completeAdmittedControl(
            token: token,
            exactResponseBytes: JSONEncoder().encode(response)
        )
        _ = try await pullMetadataFrame(from: pump)
        await coordinator.apply(effect, productAdmission: harness.productAdmission.context)
        return (bootstrapCount, token)
    }

    func acceptFileViewScope(requestSequence: Int = 3) async throws {
        let scope = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: JSONSerialization.data(withJSONObject: [
                "kind": "subscription.setScope", "wireVersion": BridgeProductWireContract.version,
                "paneSessionId": "pane-session-1", "workerInstanceId": "worker-instance-1",
                "requestId": "pane-file-scope",
                "requestSequence": requestSequence, "subscriptionId": "file-subscription-1",
                "subscriptionKind": "file.metadata",
                "domain": "default", "handle": "pane-file-handle", "incarnation": "pane-file-incarnation",
                "scopeRevision": 1,
                "scope": ["kind": "file", "changeFilter": ["kind": "none"], "interests": [], "pathScope": []],
            ]))
        #expect(await coordinator.acceptViewScope(scope, productAdmission: harness.productAdmission.context) == nil)
    }

    func retryFileSurfaceWithCommittedControlCall() async throws {
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: harness.session,
            provider: schemeProvider,
            productAdmission: harness.productAdmission.context
        )
        let sessionSnapshot = await harness.session.snapshot
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: fileRefreshRetryControlBody(
                requestSequence: sessionSnapshot.controlReplay.nextExpectedRequestSequence,
                workerDerivationEpoch: sessionSnapshot.workerDerivationEpochBySurface[.file] ?? 0
            )
        )
        let admission = try await dispatcher.dispatch(
            exactRequestBytes: try JSONEncoder().encode(request),
            presentedCapability: harness.capabilityHeader
        )
        let result = try await awaitBridgeProductAdmittedControlResult(
            admission,
            session: harness.session,
            productAdmission: harness.productAdmission.context
        )
        #expect(result.outcome == .succeeded)
    }

    func openReview(subscriptionID: String = "review-subscription-1", sequence: Int = 2) async throws {
        var object = bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: sequence, epoch: 1)
        object["subscriptionId"] = subscriptionID
        let completion = try await openSubscription(object)
        #expect(completion.result == .success)
        // The real source's open completion is the subscription bootstrap's causal seam.
        #expect(try await reviewSource.opened.firstArrival() == harness.productAdmission.context)
    }

    private func openSubscription(_ object: [String: Any]) async throws
        -> BridgeProductMetadataLifecycleTraceEvent
    {
        let request = try bridgeProductLifecycleControlRequest(object)
        guard case .subscriptionOpen(let opening) = request else {
            throw ProductFileSourceFixtureError.invalidControlRequest
        }
        let bootstrapCount = await trace.count(for: opening.subscription.subscriptionKind) + 1
        let token = try #require(controlExecutionToken(try await harness.begin(request)))
        #expect(await harness.session.admitControlProviderExecution(token: token))
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(correlating: request, worktreeId: nil)
        let effect = try await harness.session.completeAdmittedControl(
            token: token, exactResponseBytes: JSONEncoder().encode(response))
        _ = try await pullMetadataFrame(from: pump)
        await coordinator.apply(effect, productAdmission: harness.productAdmission.context)
        let completion = try await trace.finished(
            opening.subscription.subscriptionKind,
            count: bootstrapCount
        )
        await harness.session.settleControlProviderDispatch(token: token)
        return completion
    }

    func nextBatch() async throws -> [BridgeProductMetadataFrame] {
        let first = try await pullMetadataFrame(from: pump)
        guard case .batch(.begin(let begin)) = first else {
            Issue.record("Expected a File or Review snapshot batch begin, received \(first.kind)")
            return []
        }
        var frames = [first]
        for _ in 0..<begin.partCount { frames.append(try await pullMetadataFrame(from: pump)) }
        let last = try await pullMetadataFrame(from: pump)
        #expect(last.kind == "subscription.batchComplete")
        frames.append(last)
        return frames
    }

    func changeset() -> FileChangeset {
        FileChangeset(
            worktreeId: fileFixture.worktreeId, repoId: fileFixture.repoId, rootPath: fileFixture.rootURL,
            paths: [fileFixture.demandedPath], containsGitInternalChanges: false,
            timestamp: ContinuousClock().now, batchSeq: 1)
    }

    func publishFile(statusOnly: Bool, admission: BridgeProductAdmissionContext? = nil) async
        -> BridgePaneProductFileRefreshPublicationDisposition
    {
        guard let work = refresh.acquireForegroundWork() else { return .stale }
        if statusOnly {
            return await coordinator.publish(
                status: panePublicationStatus(), productAdmission: admission ?? paneAdmission,
                foregroundWorkAdmission: work)
        }
        return await coordinator.publish(
            changeset: changeset(), productAdmission: admission ?? paneAdmission, foregroundWorkAdmission: work)
    }

    func close() async {
        await fileRefreshDriver.closeAndDrain()
        await coordinator.closeAndDrain()
        _ = await pump.cancel()
        fileFixture.remove()
        refresh.close()
    }
}

private func fileRefreshRetryControlBody(
    requestSequence: Int,
    workerDerivationEpoch: Int
) -> Data {
    Data(
        """
        {
          "call": { "method": "file.refresh.retry", "request": {} },
          "kind": "product.call",
          "paneSessionId": "\(bridgeProductTestPaneSessionId)",
          "requestId": "file-refresh-retry",
          "requestSequence": \(requestSequence),
          "wireVersion": 2,
          "workerDerivationEpoch": \(workerDerivationEpoch),
          "workerInstanceId": "\(bridgeProductTestWorkerInstanceId)"
        }
        """.utf8
    )
}

func panePublicationStatus() -> GitWorkingTreeStatus {
    GitWorkingTreeStatus(summary: .init(changed: 9, staged: 4, untracked: 2), branch: "refresh-branch", origin: nil)
}

actor PanePublicationFileSource: BridgePaneProductFileMetadataProducing {
    let source: BridgePaneProductFileMetadataSource
    private var heldPublication: HeldStep<BridgeProductAdmissionContext>?
    private var openCallCount = 0
    private var openFailureByOrdinal: [Int: any Error] = [:]
    private var openStepByOrdinal: [Int: HeldStep<BridgeProductAdmissionContext>] = [:]

    init(source: BridgePaneProductFileMetadataSource) { self.source = source }
    func holdPublication(_ step: HeldStep<BridgeProductAdmissionContext>) { heldPublication = step }
    func holdNextOpen(_ step: HeldStep<BridgeProductAdmissionContext>) {
        openStepByOrdinal[openCallCount + 1] = step
    }
    func holdOpen(ordinal: Int, at step: HeldStep<BridgeProductAdmissionContext>) {
        openStepByOrdinal[ordinal] = step
    }
    func failOpen(ordinal: Int, with error: any Error) {
        openFailureByOrdinal[ordinal] = error
    }
    func numberOfOpenCalls() -> Int { openCallCount }
    func sourceDiagnostics() async -> BridgeFileMetadataSourceDiagnostics {
        await source.diagnosticSnapshot()
    }
    func currentSource() async throws(BridgeWorktreeFileRootAccessError) -> BridgeProductFileSourceCurrentResult {
        try await source.currentSource()
    }
    func open(
        subscription: BridgeProductSubscriptionSnapshot, productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission, emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        openCallCount += 1
        let ordinal = openCallCount
        if let openStep = openStepByOrdinal.removeValue(forKey: ordinal) {
            try await openStep.arrive(productAdmission)
            try Task.checkCancellation()
        }
        if let error = openFailureByOrdinal.removeValue(forKey: ordinal) { throw error }
        try await source.open(
            subscription: subscription, productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission, emit: emit)
    }
    func applyViewDemand(
        subscriptionId: String, demand: BridgePaneProductFileViewDemand,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission, forceRecapture: Bool,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        try await source.applyViewDemand(
            subscriptionId: subscriptionId, demand: demand, productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission, forceRecapture: forceRecapture, emit: emit)
    }
    func captureKeyedSnapshot(
        subscriptionId: String, demand: BridgePaneProductFileViewDemand, productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? {
        await source.captureKeyedSnapshot(
            subscriptionId: subscriptionId, demand: demand, productAdmission: productAdmission)
    }
    func cancel(subscriptionId: String) async { await source.cancel(subscriptionId: subscriptionId) }
    func publish(
        status: GitWorkingTreeStatus, productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> [BridgePaneProductFileMetadataEmission] {
        if let heldPublication { try? await heldPublication.arrive(productAdmission) }
        return await source.publish(
            status: status, productAdmission: productAdmission, foregroundWorkAdmission: foregroundWorkAdmission)
    }
    func publish(
        changeset: FileChangeset, productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] {
        if let heldPublication { try await heldPublication.arrive(productAdmission) }
        return try await source.publish(
            changeset: changeset, productAdmission: productAdmission, foregroundWorkAdmission: foregroundWorkAdmission)
    }
    func contentReadPlan(for request: BridgeProductFileContentRequest, productAdmission: BridgeProductAdmissionContext)
        async -> BridgePaneProductFileContentReadPlan?
    {
        await source.contentReadPlan(for: request, productAdmission: productAdmission)
    }
}

actor PanePublicationReviewSource: BridgePaneProductReviewMetadataProducing {
    private let source = BridgePaneProductReviewMetadataSource()
    let opened = HeldStep<BridgeProductAdmissionContext>("Review source open complete")
    private var heldDelivery: HeldStep<BridgeProductAdmissionContext>?
    private var heldCancel: HeldStep<String>?
    init() { opened.release() }
    func holdDelivery(_ step: HeldStep<BridgeProductAdmissionContext>) { heldDelivery = step }
    func holdCancel(_ step: HeldStep<String>) { heldCancel = step }
    func open(subscription: BridgeProductSubscriptionSnapshot, productAdmission: BridgeProductAdmissionContext)
        async throws
    {
        try await source.open(subscription: subscription, productAdmission: productAdmission)
        try await opened.arrive(productAdmission)
    }
    func reserve(package: BridgeReviewPackage, publicationId: UUID, productAdmission: BridgeProductAdmissionContext)
        async throws -> BridgeReviewMetadataPublicationReservation
    {
        try await source.reserve(package: package, publicationId: publicationId, productAdmission: productAdmission)
    }
    func deliver(
        publication: BridgeReviewCommittedPublication, reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        if let heldDelivery { try await heldDelivery.arrive(productAdmission) }
        return try await source.deliver(
            publication: publication, reservation: reservation, productAdmission: productAdmission)
    }
    func applyViewDemand(_ request: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    {
        try await source.applyViewDemand(request)
    }
    func cancel(subscriptionId: String) async {
        if let heldCancel { try? await heldCancel.arrive(subscriptionId) }
        await source.cancel(subscriptionId: subscriptionId)
    }
}

actor PanePublicationBootstrapTrace: BridgeProductMetadataLifecycleTraceRecording {
    private var events: [BridgeProductSubscriptionKind: [BridgeProductMetadataLifecycleTraceEvent]] = [:]
    private let finishes = FactRecorder<String, BridgeProductMetadataLifecycleTraceEvent>(
        vocabulary: .init(describeScope: { $0 }, describeFact: { String(describing: $0) }, isClosing: { _, _ in false })
    )

    func count(for kind: BridgeProductSubscriptionKind) -> Int { events[kind, default: []].count }
    func record(_ event: BridgeProductReviewMetadataPublicationTraceEvent) {}
    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) {
        guard event.stage == .bootstrapFinished else { return }
        events[event.subscriptionKind, default: []].append(event)
        finishes.append(
            scope: "\(event.subscriptionKind)-\(events[event.subscriptionKind, default: []].count)", fact: event)
    }
    func finished(_ kind: BridgeProductSubscriptionKind, count: Int) async throws
        -> BridgeProductMetadataLifecycleTraceEvent
    {
        if events[kind, default: []].count >= count { return events[kind]![count - 1] }
        return try await finishes.expectNext(
            in: "\(kind)-\(count)", where: { _ in true }, "bootstrap finished for \(kind), count \(count)")
    }
}

enum PanePublicationSourceObservation<TArrival: Sendable>: Sendable {
    case entered(TArrival)
    case completed
}

struct PanePublicationSourceObserver<TArrival: Sendable>: Sendable {
    private let events: AsyncStream<PanePublicationSourceObservation<TArrival>>
    private let signal: AsyncStream<PanePublicationSourceObservation<TArrival>>.Continuation
    private let arrivalTask: Task<Void, Never>

    init(at step: HeldStep<TArrival>) {
        let (events, signal) = AsyncStream<PanePublicationSourceObservation<TArrival>>.makeStream(
            bufferingPolicy: .bufferingOldest(2))
        self.events = events
        self.signal = signal
        arrivalTask = Task {
            do { signal.yield(.entered(try await step.firstArrival())) } catch {}
        }
    }
    func recordCompletion() { signal.yield(.completed) }
    func firstObservation() async -> PanePublicationSourceObservation<TArrival>? {
        var iterator = events.makeAsyncIterator()
        return await iterator.next()
    }
    func closeAndDrain() async {
        arrivalTask.cancel()
        await arrivalTask.value
        signal.finish()
    }
}

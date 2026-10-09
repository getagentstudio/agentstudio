import AgentStudioCore
import AgentStudioTestHarness
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

@Suite("Bridge metadata retirement ownership")
struct BridgeMetadataRetirementOwnershipTests {
    @Test("a retained resync survives a predecessor producer's current File failure")
    func retainedResyncSurvivesPredecessorFailure() async throws {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let firstLease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: firstLease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let probe = MetadataRetirementOwnershipProbe(holdPredecessorFailure: true)
        let publishedFileFailures = Mutex<[BridgePaneProductFileRefreshFailure?]>([])
        var observations = probe.observations.makeAsyncIterator()
        let registry = try BridgePaneProductMetadataNativeApplicationRegistry(applications: [
            .init(
                registration: AnyBridgeProductMetadataApplicationProtocol(
                    BridgeProductFileMetadataApplication.self
                ),
                adapter: .init(
                    open: { _, _, _, _, _, _, _ in try await probe.open() },
                    cancel: { _, _ in await probe.cancel() }
                )
            )
        ])
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            recordCurrentFileRefreshFailure: { failure in
                failure.apply { appliedFailure in
                    publishedFileFailures.withLock { $0.append(appliedFailure) }
                }
            },
            lifecycleTraceRecorder: probe,
            nativeApplicationRegistry: registry
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: firstLease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )
        let openToken = try #require(controlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: openToken))
        let openResponse = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest,
            worktreeId: nil
        )
        let openEffect = try await harness.session.completeAdmittedControl(
            token: openToken,
            exactResponseBytes: try JSONEncoder().encode(openResponse)
        )
        guard case .subscriptionOpened(let subscription) = openEffect else {
            Issue.record("Expected File subscription to open")
            return
        }
        _ = try await pullMetadataFrame(from: pump)
        await coordinator.apply(openEffect, productAdmission: harness.productAdmission.context)
        await harness.session.settleControlProviderDispatch(token: openToken)
        #expect(await observations.next() == .predecessorFailureHeld)

        #expect(try await reconcileRetainedFileSubscription(harness, subscription) == ["retained"])

        #expect(await pump.cancel())
        let successorLease = try await harness.admitMetadataFrames(through: 0)
        await probe.releaseProducerFailure()
        #expect(await probe.waitForFailedProducerReason() == nil)
        #expect(await probe.didEnqueueReset == false)
        let currentFailure = publishedFileFailures.withLock { $0.compactMap { $0 }.last }
        #expect(currentFailure == .init(failureKind: .fileSourceUnavailable))
        #expect(currentFailure?.retryable == true)

        let resnapshotRequest = try reconnectFileResnapshotRequest()
        let resnapshotAdmission = try await harness.begin(resnapshotRequest)
        if let resnapshotToken = controlExecutionToken(resnapshotAdmission) {
            #expect(await harness.session.admitControlProviderExecution(token: resnapshotToken))
            let resnapshotResponse = try BridgeProductControlResponse.viewAccepted(
                correlating: resnapshotRequest
            )
            _ = try await harness.session.completeAdmittedControl(
                token: resnapshotToken,
                exactResponseBytes: try JSONEncoder().encode(resnapshotResponse)
            )
            await harness.session.settleControlProviderDispatch(token: resnapshotToken)
        } else {
            Issue.record("The retained subscription was refused at resnapshot")
        }
        #expect(
            await harness.session.subscriptionSnapshot(subscriptionId: subscription.subscriptionId) != nil
        )
        await coordinator.uninstall(lease: firstLease)
        try await harness.closeProducer(successorLease)
        await probe.finish()
    }

    @Test("a stale File failure cannot retire its same-E3 replacement", .timeLimit(.minutes(1)))
    func failedPredecessorCannotRetireReplacement() async throws {
        // Arrange
        let scenario = try await RetirementOwnershipReplacementScenario.make()
        defer { scenario.fixture.remove() }

        do {
            var observations = scenario.probe.observations.makeAsyncIterator()

            var openObject = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
            openObject["subscription"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(scenario.fixture.openSnapshot().subscription)
            )
            let openRequest = try bridgeProductLifecycleControlRequest(openObject)
            let token = try #require(controlExecutionToken(try await scenario.harness.begin(openRequest)))
            #expect(await scenario.harness.session.admitControlProviderExecution(token: token))
            let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
                correlating: openRequest,
                worktreeId: nil
            )
            let effect = try await scenario.harness.session.completeAdmittedControl(
                token: token,
                exactResponseBytes: try JSONEncoder().encode(response)
            )
            guard case .subscriptionOpened(let subscription) = effect else {
                Issue.record("Opening File subscription did not produce a lifecycle effect")
                await scenario.close()
                return
            }
            let acceptedFrame = try await pullMetadataFrame(from: scenario.pump)
            guard case .subscriptionAccepted(let accepted) = acceptedFrame else {
                Issue.record("Expected the File subscription to retain its metadata stream")
                await scenario.close()
                return
            }
            await scenario.coordinator.apply(effect, productAdmission: scenario.harness.productAdmission.context)
            await scenario.harness.session.settleControlProviderDispatch(token: token)
            #expect(await observations.next() == .predecessorFailureHeld)

            // Act: a material view-scope change supersedes the held predecessor on this same E3.
            let changedScope = try retirementOwnershipFileScopeRequest(path: scenario.fixture.demandedPath)
            #expect(
                await scenario.coordinator.acceptViewScope(
                    changedScope,
                    productAdmission: scenario.harness.productAdmission.context
                ) == nil
            )
            #expect(await observations.next() == .replacementOpened)
            let delivered = try await waitForRetirementOwnershipDescriptor(
                from: scenario.pump,
                demandedPath: scenario.fixture.demandedPath
            )
            let expectedBytes = try Data(contentsOf: scenario.fixture.demandedFileURL)
            let expectedSHA = SHA256.hash(data: expectedBytes).map { String(format: "%02x", $0) }.joined()
            #expect(delivered.descriptor.expectedSha256 == expectedSHA)
            #expect(delivered.complete.identity.subscriptionId == subscription.subscriptionId)
            #expect(delivered.complete.identity.frame.streamSequence > accepted.frameIdentity.streamSequence)
            let callbackCountBeforePredecessorCompletion = scenario.publishedFileFailures.snapshot().count

            // Finish the stale predecessor only after the successor's certificate is delivered.
            await scenario.probe.releaseProducerFailure()
            #expect(await observations.next() == .failedProducerFinished)

            // Assert
            #expect(await scenario.probe.cancellationCount == 0)
            #expect(await scenario.probe.didEnqueueReset == false)
            #expect(
                scenario.publishedFileFailures.snapshot().count == callbackCountBeforePredecessorCompletion,
                "The stale predecessor must not publish or clear the successor's current failure"
            )
            #expect(
                scenario.publishedFileFailures.snapshot().compactMap { $0 }.isEmpty,
                "The superseded predecessor must not publish a current File failure"
            )
            #expect(await scenario.coordinator.activeStream?.lease == scenario.lease)
            #expect(await scenario.coordinator.fileSurfaceReconciler.activeAttempt == nil)
            #expect(await scenario.coordinator.fileSurfaceReconciler.currentFailure == nil)
            #expect(await scenario.coordinator.subscriptionKindById[subscription.subscriptionId] == .fileMetadata)
            #expect(
                await scenario.harness.session.subscriptionSnapshot(subscriptionId: subscription.subscriptionId)
                    == subscription
            )

            // Prove the successor still publishes File changes after the predecessor finishes.
            try await scenario.publishSuccessorChange(after: delivered.descriptor)
            await scenario.close()
        } catch {
            await scenario.close()
            throw error
        }
    }
}

private final class MetadataFileRefreshFailureRecorder: @unchecked Sendable {
    private let failures = Mutex<[BridgePaneProductFileRefreshFailure?]>([])

    func append(_ failure: BridgePaneProductFileRefreshFailure?) {
        failures.withLock { $0.append(failure) }
    }

    func snapshot() -> [BridgePaneProductFileRefreshFailure?] {
        failures.withLock { $0 }
    }
}

private struct RetirementOwnershipReplacementScenario {
    let refreshWorkAdmission: BridgePaneRefreshWorkAdmissionTestContext
    let harness: BridgeProductSessionLifecycleHarness
    let lease: BridgeProductProducerLease
    let fixture: ProductFileSourceFixture
    let constructionCoordinator: BridgeWorktreeProductConstructionCoordinator
    let pump: BridgeProductSchemeFramePump
    let probe: MetadataRetirementOwnershipProbe
    let publishedFileFailures: MetadataFileRefreshFailureRecorder
    let coordinator: BridgePaneProductMetadataCoordinator

    static func make() async throws -> Self {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let fixture = try ProductFileSourceFixture(
            fileCount: 1,
            productAdmission: harness.productAdmission
        )
        let constructionCoordinator = BridgeWorktreeProductConstructionCoordinator()
        let fileSource = fixture.makeSource(constructionCoordinator: constructionCoordinator)
        let probe = MetadataRetirementOwnershipProbe(holdPredecessorFailure: true)
        let publishedFileFailures = MetadataFileRefreshFailureRecorder()
        let registry = try BridgePaneProductMetadataNativeApplicationRegistry(applications: [
            .init(
                registration: AnyBridgeProductMetadataApplicationProtocol(
                    BridgeProductFileMetadataApplication.self
                ),
                adapter: .init(
                    open: { _, subscription, _, productAdmission, foregroundWorkAdmission, _, _ in
                        try await probe.openReplacement(
                            using: fileSource,
                            subscription: subscription,
                            productAdmission: productAdmission,
                            foregroundWorkAdmission: foregroundWorkAdmission
                        )
                    },
                    cancel: { _, subscriptionId in
                        await probe.cancel()
                        await fileSource.cancel(subscriptionId: subscriptionId)
                    }
                )
            )
        ])
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: fileSource,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            recordCurrentFileRefreshFailure: { failure in
                failure.apply { publishedFileFailures.append($0) }
            },
            lifecycleTraceRecorder: probe,
            nativeApplicationRegistry: registry
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        return .init(
            refreshWorkAdmission: refreshWorkAdmission,
            harness: harness,
            lease: lease,
            fixture: fixture,
            constructionCoordinator: constructionCoordinator,
            pump: pump,
            probe: probe,
            publishedFileFailures: publishedFileFailures,
            coordinator: coordinator
        )
    }

    func publishSuccessorChange(after priorDescriptor: BridgeProductFileContentDescriptor) async throws {
        let successorContent = Data("successor remains live after predecessor failure\n".utf8)
        try successorContent.write(to: fixture.demandedFileURL)
        let successorWorkAdmission = try #require(refreshWorkAdmission.source.acquire())
        let disposition = await coordinator.publish(
            changeset: FileChangeset(
                worktreeId: fixture.worktreeId,
                repoId: fixture.repoId,
                rootPath: fixture.rootURL,
                paths: [fixture.demandedPath],
                timestamp: ContinuousClock().now,
                batchSeq: 1
            ),
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: successorWorkAdmission
        )
        #expect(disposition == .applied)
        let followup = try await waitForRetirementOwnershipDescriptor(
            from: pump,
            demandedPath: fixture.demandedPath
        )
        let successorSHA = SHA256.hash(data: successorContent).map { String(format: "%02x", $0) }.joined()
        #expect(followup.descriptor.expectedSha256 == successorSHA)
        #expect(followup.descriptor.expectedSha256 != priorDescriptor.expectedSha256)
        #expect(followup.complete.identity.subscriptionId == "file-subscription-1")
    }

    func close() async {
        await probe.releaseProducerFailure()
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
        await constructionCoordinator.shutdown()
        await probe.finish()
    }
}

private func retirementOwnershipFileScopeRequest(path: String) throws -> BridgeProductViewScopeRequest {
    let encoded = try JSONSerialization.data(
        withJSONObject: [
            "domain": "default",
            "handle": "file-handle-1",
            "incarnation": "file-incarnation-1",
            "kind": "subscription.setScope",
            "paneSessionId": "pane-session-1",
            "requestId": "retirement-file-scope",
            "requestSequence": 3,
            "scope": [
                "changeFilter": ["kind": "none"],
                "interests": [["lane": "foreground", "paths": [path]]],
                "kind": "file",
                "pathScope": [path],
            ],
            "scopeRevision": 1,
            "subscriptionId": "file-subscription-1",
            "subscriptionKind": "file.metadata",
            "workerInstanceId": "worker-instance-1",
            "wireVersion": 2,
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(BridgeProductViewScopeRequest.self, from: encoded)
}

private func waitForRetirementOwnershipDescriptor(
    from pump: BridgeProductSchemeFramePump,
    demandedPath: String
) async throws -> (descriptor: BridgeProductFileContentDescriptor, complete: BridgeProductBatchCompleteFrame) {
    var descriptorByBatchId: [String: BridgeProductFileContentDescriptor] = [:]
    while true {
        let frame = try await pullMetadataFrame(from: pump)
        guard case .batch(let batchFrame) = frame else { continue }
        switch batchFrame {
        case .part(let part):
            guard case .put(_, _, .object(let fields)) = part.part,
                case .string(let displayKey)? = fields["displayKey"],
                displayKey == demandedPath,
                let encodedDescriptor = fields["readDescriptor"], encodedDescriptor != .null
            else { continue }
            descriptorByBatchId[part.identity.batchId] = try JSONDecoder().decode(
                BridgeProductFileContentDescriptor.self,
                from: JSONEncoder().encode(encodedDescriptor)
            )
        case .complete(let complete):
            if let descriptor = descriptorByBatchId.removeValue(forKey: complete.identity.batchId) {
                return (descriptor, complete)
            }
        default:
            continue
        }
    }
}

private func reconcileRetainedFileSubscription(
    _ harness: BridgeProductSessionLifecycleHarness,
    _ subscription: BridgeProductSubscriptionSnapshot
) async throws -> [String] {
    let scopeRequest = try reconnectFileScopeRequest()
    let scopeToken = try #require(controlExecutionToken(try await harness.begin(scopeRequest)))
    #expect(await harness.session.admitControlProviderExecution(token: scopeToken))
    let scopeResponse = try BridgeProductControlResponse.viewAccepted(correlating: scopeRequest)
    _ = try await harness.session.completeAdmittedControl(
        token: scopeToken,
        exactResponseBytes: try JSONEncoder().encode(scopeResponse)
    )
    await harness.session.settleControlProviderDispatch(token: scopeToken)

    let resyncRequest = try reconnectResyncRequest(
        subscription: subscription,
        lastAcceptedStreamSequence: 1
    )
    let resyncToken = try #require(controlExecutionToken(try await harness.begin(resyncRequest)))
    #expect(await harness.session.admitControlProviderExecution(token: resyncToken))
    let resyncResponse = try await harness.authoritativeResyncResponse(
        request: resyncRequest,
        token: resyncToken
    )
    _ = try await harness.session.completeAdmittedControl(
        token: resyncToken,
        exactResponseBytes: try JSONEncoder().encode(resyncResponse)
    )
    await harness.session.settleControlProviderDispatch(token: resyncToken)
    guard case .resyncAccepted(let accepted) = resyncResponse else {
        Issue.record("Expected typed resync acceptance")
        return []
    }
    return accepted.reconciliation.map(\.dispositionName)
}

private actor MetadataRetirementOwnershipProbe: BridgeProductMetadataLifecycleTraceRecording {
    enum Observation: Equatable, Sendable {
        case predecessorFailureHeld
        case resetEnqueued
        case replacementOpened
        case failedProducerFinished
    }

    nonisolated let observations: AsyncStream<Observation>
    private let continuation: AsyncStream<Observation>.Continuation
    private let producerFailureRelease = HeldStep<Void>(
        "predecessor producer failure completion", cancellation: .holdThroughCancellation)
    private var failedProducerFinishedWaiters:
        [CheckedContinuation<BridgeProductMetadataProducerFailureReason?, Never>] = []
    private var failedProducerFinished = false
    private var failedProducerReason: BridgeProductMetadataProducerFailureReason?
    private let holdPredecessorFailure: Bool
    private var producerFailureReleased = false
    private var replacementRelease: CheckedContinuation<Void, Never>?
    private var operationCount = 0
    private(set) var cancellationCount = 0
    private(set) var didEnqueueReset = false

    init(holdPredecessorFailure: Bool = false) {
        self.holdPredecessorFailure = holdPredecessorFailure
        let stream = AsyncStream.makeStream(of: Observation.self, bufferingPolicy: .bufferingNewest(8))
        observations = stream.stream
        continuation = stream.continuation
    }

    func open() async throws {
        try await runProducer()
    }

    func openReplacement(
        using fileMetadataSource: any BridgePaneProductFileMetadataProducing,
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws {
        operationCount += 1
        guard operationCount > 1 else {
            throw BridgePaneProductFileMetadataSourceError.unavailableAuthority
        }
        try await fileMetadataSource.open(
            subscription: subscription,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            emit: { _ in }
        )
        continuation.yield(.replacementOpened)
    }

    private func runProducer() async throws {
        operationCount += 1
        if operationCount == 1 {
            throw BridgePaneProductFileMetadataSourceError.unavailableAuthority
        }
        await withCheckedContinuation { pending in
            replacementRelease = pending
            continuation.yield(.replacementOpened)
        }
    }

    func cancel() {
        cancellationCount += 1
        replacementRelease?.resume()
        replacementRelease = nil
    }

    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) async {
        if event.stage == .subscriptionResetEnqueued {
            didEnqueueReset = true
            continuation.yield(.resetEnqueued)
        } else if holdPredecessorFailure, event.stage == .producerFailed {
            continuation.yield(.predecessorFailureHeld)
            try? await producerFailureRelease.arrive(())
        } else if event.stage == .bootstrapFinished, event.result == .failure {
            failedProducerReason = event.failureReason
            failedProducerFinished = true
            let waiters = failedProducerFinishedWaiters
            failedProducerFinishedWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: event.failureReason) }
            continuation.yield(.failedProducerFinished)
        }
    }

    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) {}

    func releaseProducerFailure() {
        guard !producerFailureReleased else { return }
        producerFailureReleased = true
        producerFailureRelease.release()
    }

    func waitForFailedProducerReason() async -> BridgeProductMetadataProducerFailureReason? {
        if failedProducerFinished { return failedProducerReason }
        return await withCheckedContinuation { pending in
            failedProducerFinishedWaiters.append(pending)
        }
    }

    func finish() {
        continuation.finish()
    }
}

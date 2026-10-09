import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

@Suite("Comment snapshot cause at native seal")
struct BridgeProductCommentSnapshotCauseTests {
    @Test("an obligation created during dirty I/O refuses the delta and fully recaptures", arguments: [false, true])
    func owedSnapshotDuringDirtyCapture(expireAcknowledgement: Bool) async throws {
        let context = try await CommentSnapshotCauseContext.open()
        var deliveries = context.deliveries.makeAsyncIterator()
        let initial = try #require(await deliveries.next())
        #expect(initial.mode == .snapshot)
        _ = try await context.consumeBatch(initial.batch, acknowledge: !expireAcknowledgement)
        let heldRead = HeldStep<Void>("Comment dirty catalog I/O before seal", cancellation: .holdThroughCancellation)
        context.armedRead.step.withLock { $0 = heldRead }
        do {
            _ = try await context.service.saveDraft(
                .init(
                    sessionID: context.draft.session.id, messageID: context.message.id, editToken: "editor-1",
                    expectedMessageRevision: context.message.semanticRevision,
                    expectedDraftRevision: try #require(context.message.draft?.draftRevision),
                    now: Date(timeIntervalSince1970: 3)
                ))
            _ = try await heldRead.firstArrival()
            if expireAcknowledgement {
                await context.clock.waitForPendingSleepCount(atLeast: 1)
                context.clock.advance(by: AppPolicies.Bridge.productViewAcknowledgementDeadline)
                var recovery = context.recoverySignals.makeAsyncIterator()
                #expect(await recovery.next()?.viewDomain == context.view.viewDomain)
            } else {
                #expect(
                    await context.session.acceptViewResnapshot(
                        try context.resnapshotRequest(), productAdmission: context.harness.productAdmission.context
                    ) == nil)
            }
            heldRead.release()
            let rejectedDelta = try #require(await deliveries.next())
            #expect(rejectedDelta.mode == .change)
            #expect(rejectedDelta.outcome == .resnapshotRequired)
            // On the red, join cleanup without awaiting an absent recapture.
            if rejectedDelta.outcome == .resnapshotRequired {
                let recaptured = try #require(await deliveries.next())
                #expect(recaptured.mode == .snapshot)
                #expect(recaptured.outcome == .completed)
                let allKeys = Set(initial.batch.puts.map(\.recordKey))
                #expect(Set(recaptured.batch.puts.map(\.recordKey)) == allKeys)
                let frames = try await context.consumeBatch(recaptured.batch, acknowledge: true)
                let begins = frames.compactMap { frame -> BridgeProductBatchBeginFrame? in
                    if case .batch(.begin(let begin)) = frame { return begin }
                    return nil
                }
                #expect(begins.count == 1)
                #expect(begins.first?.mode == .snapshot)
                #expect(begins.first?.snapshotCause == (expireAcknowledgement ? .recovery : .requested))
                #expect(await context.session.viewSnapshotRequired(subscriptionId: context.subscriptionId) == false)
            }
            await context.close()
            #expect(await deliveries.next() == nil)
        } catch {
            heldRead.release()
            await context.close()
            throw error
        }
    }
}

private struct CommentCauseDelivery: Sendable {
    let batch: BridgeProductCommentCatalogBatch
    let mode: BridgeProductBatchMode
    let outcome: BridgeProductViewEmissionOutcome
}

private final class CommentCatalogReadHold: Sendable {
    let step = Mutex<HeldStep<Void>?>(nil)
}

private struct CommentSnapshotCauseContext: Sendable {
    let harness: BridgeProductSessionLifecycleHarness
    let lease: BridgeProductProducerLease
    let view: BridgeProductNativeCommentView
    let source: BridgePaneAnnotationNotificationSource
    let service: WorktreeAnnotationServiceActor
    let draft: WorktreeAnnotationSessionDetail
    let message: WorktreeAnnotationMessage
    let armedRead: CommentCatalogReadHold
    let clock: TestPushClock
    let deliveries: AsyncStream<CommentCauseDelivery>
    let recoverySignals: AsyncStream<BridgeProductViewResnapshotSignal>
    let producer: Task<Void, any Error>
    let subscriptionId = "comment-cause-view"
    var session: BridgeProductSession { harness.session }

    static func open() async throws -> Self {
        let clock = TestPushClock()
        let harness = try await BridgeProductSessionLifecycleHarness.opened(deadlineClock: clock)
        let lease = try await harness.admitMetadataFrames(through: 0)
        var request = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        request["subscription"] = ["subscriptionKind": "file.annotations"]
        request["subscriptionId"] = "comment-cause-view"
        try await harness.openSubscription(request)
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session, productAdmission: harness.productAdmission.context))
        let view = try #require(
            try await harness.session.openNativeCommentView(
                subscriptionId: "comment-cause-view", worktreeID: "worktree-1",
                productAdmission: harness.productAdmission.context))
        let scopeRequest = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: JSONSerialization.data(withJSONObject: [
                "kind": "subscription.setScope", "wireVersion": 2, "paneSessionId": "pane-session-1",
                "workerInstanceId": "worker-instance-1", "requestId": "comment-scope", "requestSequence": 3,
                "subscriptionId": "comment-cause-view", "subscriptionKind": "file.annotations", "domain": "default",
                "handle": view.handle, "incarnation": view.viewDomain.incarnation, "scopeRevision": 1,
                "scope": ["kind": "comment", "sessionIds": [], "worktreeId": "worktree-1"],
            ]))
        #expect(
            await harness.session.acceptViewScope(scopeRequest, productAdmission: harness.productAdmission.context)
                == nil)
        let repository = try makeAnnotationRepository()
        let armedRead = CommentCatalogReadHold()
        let service = WorktreeAnnotationServiceActor(
            repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(
                repository: repository,
                beforeCatalogRangeRead: {
                    let held = armedRead.step.withLock { step in
                        let held = step
                        step = nil
                        return held
                    }
                    try await held?.arrive(())
                }))
        let draft = try await service.createRootDraft(makeCreateRootDraftProps())
        let siblingProps = makeCreateRootDraftProps()
        _ = try await service.createRootDraft(
            .init(
                admission: .newSession, repositoryID: siblingProps.repositoryID, worktreeID: siblingProps.worktreeID,
                sourceFingerprint: siblingProps.sourceFingerprint, origin: siblingProps.origin,
                body: siblingProps.body, editToken: siblingProps.editToken, now: siblingProps.now
            ))
        let source = BridgePaneAnnotationNotificationSource(service: service, worktreeID: "worktree-1")
        try await source.acceptBatchScope(handle: view.handle, worktreeID: "worktree-1", scopeRevision: 1)
        let (deliveries, continuation) = AsyncStream.makeStream(
            of: CommentCauseDelivery.self, bufferingPolicy: .bufferingOldest(4))
        let (signals, signalContinuation) = AsyncStream.makeStream(
            of: BridgeProductViewResnapshotSignal.self, bufferingPolicy: .bufferingOldest(1))
        await harness.session.setViewResnapshotNeededObserver { signal in signalContinuation.yield(signal) }
        let producerID = UUIDv7.generate()
        let producer = Task {
            defer { continuation.finish() }
            try await source.openBatch(
                handle: view.handle, producerID: producerID,
                snapshotRequired: { await harness.session.viewSnapshotRequired(subscriptionId: "comment-cause-view") },
                deliver: { batch, mode in
                    let outcome = try await harness.session.sealCommentCatalogBatch(
                        subscriptionId: "comment-cause-view", catalogBatch: batch, mode: mode,
                        productAdmission: harness.productAdmission.context)
                    if outcome == .completed {
                        await source.recordSealedCommentCatalogBatch(
                            handle: view.handle, producerID: producerID, batch: batch)
                    }
                    continuation.yield(.init(batch: batch, mode: mode, outcome: outcome))
                    return outcome
                })
        }
        return .init(
            harness: harness, lease: lease, view: view, source: source, service: service, draft: draft,
            message: try #require(draft.threads.first?.messages.first), armedRead: armedRead, clock: clock,
            deliveries: deliveries, recoverySignals: signals, producer: producer)
    }

    func resnapshotRequest() throws -> BridgeProductViewResnapshotRequest {
        try BridgeProductStrictJSON.decode(
            BridgeProductViewResnapshotRequest.self,
            from: JSONSerialization.data(withJSONObject: [
                "kind": "subscription.resnapshot", "wireVersion": 2, "paneSessionId": "pane-session-1",
                "workerInstanceId": "worker-instance-1", "requestId": "comment-resnapshot", "requestSequence": 4,
                "subscriptionId": subscriptionId, "subscriptionKind": "file.annotations", "domain": "default",
                "handle": view.handle, "incarnation": view.viewDomain.incarnation, "scopeRevision": 1,
            ]))
    }

    func consumeBatch(_ batch: BridgeProductCommentCatalogBatch, acknowledge: Bool) async throws
        -> [BridgeProductMetadataFrame]
    {
        var frames: [BridgeProductMetadataFrame] = []
        for _ in 0..<(batch.puts.count + batch.deletes.count + 2) {
            let queued = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease, from: session, productAdmission: harness.productAdmission.context))
            let frame = try #require(BridgeProductMetadataFrameDecoder().append(queued.data).first)
            frames.append(frame)
            if acknowledge, case .batch(.part(let part)) = frame {
                let bytes = try JSONSerialization.data(withJSONObject: [
                    "kind": "subscription.acknowledge", "wireVersion": 2, "paneSessionId": "pane-session-1",
                    "workerInstanceId": "worker-instance-1", "subscriptionId": subscriptionId, "domain": "default",
                    "handle": view.handle, "incarnation": view.viewDomain.incarnation,
                    "receivedThroughDeliverySequence": part.deliverySequence,
                ])
                let acknowledgement = try BridgeProductStrictJSON.decode(
                    BridgeProductViewAcknowledgementRequest.self, from: bytes)
                _ = try #require(
                    await session.acknowledgeViewReceipt(
                        acknowledgement, exactRequestBytes: bytes, productAdmission: harness.productAdmission.context))
            }
        }
        return frames
    }

    func close() async {
        producer.cancel()
        _ = try? await producer.value
        await session.setViewResnapshotNeededObserver(nil)
        await source.retireBatchView(handle: view.handle)
        await session.closeViewDomains(subscriptionId: subscriptionId)
        await clock.waitForPendingSleepCount(exactly: 0)
        try? await harness.closeProducer(lease)
    }
}

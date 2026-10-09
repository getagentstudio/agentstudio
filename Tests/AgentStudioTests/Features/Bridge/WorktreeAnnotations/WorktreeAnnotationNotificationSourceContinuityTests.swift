import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

@Suite("Worktree annotation notification source continuity")
struct WorktreeAnnotationCommentContinuityTests {
    @Test("a restarted Comment producer continues revisions and deletion tombstones")
    func retainedViewContinuesRevisionsAndTombstonesAfterProducerRestart() async throws {
        let harness = try makeNotificationSourceHarness()
        let changedDraft = try await harness.service.createRootDraft(makeCreateRootDraftProps())
        let deletedDraft = try await harness.service.createRootDraft(
            .init(
                admission: .selected(changedDraft.session.id),
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                sourceFingerprint: makeSourceFingerprint(identity: "source-1"),
                origin: .session,
                body: "Draft to delete",
                editToken: "editor-2",
                now: Date(timeIntervalSince1970: 2)
            )
        )
        #expect(deletedDraft.session.id == changedDraft.session.id)
        let handle = "retained-comment-view-with-catalog"
        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let firstProducerID = UUIDv7.generate()
        let (batches, continuation) = AsyncStream.makeStream(
            of: RecordedCommentBatchDelivery.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        let firstProducer = startRecordedCommentProducer(
            source: harness.source, handle: handle, producerID: firstProducerID, deliveries: continuation
        )
        var iterator = batches.makeAsyncIterator()
        let installed = try #require(await iterator.next())
        #expect(installed.mode == .snapshot)
        let previousCursor = installed.batch.targetRevision
        #expect(previousCursor > 0)
        let changedSessionKey = WorktreeAnnotationCatalogKey.session(changedDraft.session.id)
        let previousSessionRevision = try sessionSemanticRevision(
            in: installed.batch,
            for: changedSessionKey
        )

        firstProducer.cancel()
        _ = try? await firstProducer.value
        await harness.source.releaseProducerBatchScope(handle: handle, producerID: firstProducerID)

        let changedMessage = try #require(changedDraft.threads.first?.messages.first)
        let detailAfterSave = try await harness.service.saveDraft(
            .init(
                sessionID: changedDraft.session.id,
                messageID: changedMessage.id,
                editToken: "editor-1",
                expectedMessageRevision: changedMessage.semanticRevision,
                expectedDraftRevision: try #require(changedMessage.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 3)
            )
        )
        let originalThreadIDs = Set(changedDraft.threads.map(\.thread.id))
        let deletedThreadDetail = try #require(
            detailAfterSave.threads.first { !originalThreadIDs.contains($0.thread.id) }
        )
        let deletedMessage = try #require(deletedThreadDetail.messages.first)
        _ = try await harness.service.revertDraft(
            .init(
                sessionID: detailAfterSave.session.id,
                messageID: deletedMessage.id,
                editToken: "editor-2",
                expectedMessageRevision: deletedMessage.semanticRevision,
                expectedDraftRevision: try #require(deletedMessage.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 4)
            )
        )

        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let successorProducerID = UUIDv7.generate()
        let successor = startRecordedCommentProducer(
            source: harness.source, handle: handle, producerID: successorProducerID, deliveries: continuation
        )
        let resumed = try #require(await iterator.next())
        try expectResumedBatchContinuesView(
            resumed,
            handle: handle,
            previousCursor: previousCursor,
            previousSessionRevision: previousSessionRevision,
            changedSessionKey: changedSessionKey,
            deletedKeys: [.thread(deletedThreadDetail.thread.id), .message(deletedMessage.id)]
        )

        successor.cancel()
        _ = try? await successor.value
        await harness.source.retireBatchView(handle: handle)
        continuation.finish()
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }

    @Test("a replayed Comment producer waits for suspended producer continuity before sealing")
    // Keep the suspension, replay, and late-cleanup interleaving in one ordered proof body.
    // swiftlint:disable:next function_body_length
    func replayedProducerWaitsForSuspendedProducerContinuity() async throws {
        let repository = try makeAnnotationRepository()
        let armedCatalogRead = Mutex<HeldStep<Void>?>(nil)
        let service = WorktreeAnnotationServiceActor(
            repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(
                repository: repository,
                beforeCatalogRangeRead: {
                    let step = armedCatalogRead.withLock { armedStep in
                        let step = armedStep
                        armedStep = nil
                        return step
                    }
                    try await step?.arrive(())
                }
            )
        )
        let source = BridgePaneAnnotationNotificationSource(service: service, worktreeID: "worktree-1")
        let changedDraft = try await service.createRootDraft(makeCreateRootDraftProps())
        let deletedDraft = try await service.createRootDraft(
            .init(
                admission: .selected(changedDraft.session.id),
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                sourceFingerprint: makeSourceFingerprint(identity: "source-1"),
                origin: .session,
                body: "Draft to delete",
                editToken: "editor-2",
                now: Date(timeIntervalSince1970: 2)
            )
        )
        #expect(deletedDraft.session.id == changedDraft.session.id)
        let handle = "retained-comment-view-with-overlapping-replay"
        try await source.acceptBatchScope(handle: handle, worktreeID: "worktree-1", scopeRevision: 1)

        let (batches, continuation) = AsyncStream.makeStream(
            of: RecordedCommentBatchDelivery.self,
            bufferingPolicy: .bufferingOldest(3)
        )
        let firstProducerID = UUIDv7.generate()
        let firstProducer = Task {
            try await source.openBatch(
                handle: handle, producerID: firstProducerID, snapshotRequired: { false },
                deliver: { batch, mode in
                    try await recordCommentBatchSeal(batch, in: source, producerID: firstProducerID)
                    continuation.yield(.init(batch: batch, mode: mode))
                    return .completed
                })
        }
        var iterator = batches.makeAsyncIterator()
        let installed = try #require(await iterator.next())
        #expect(installed.mode == .snapshot)
        let previousCursor = installed.batch.targetRevision
        #expect(previousCursor > 0)
        let changedMessage = try #require(changedDraft.threads.first?.messages.first)
        let previousSessionRevision = try sessionSemanticRevision(
            in: installed.batch,
            for: .session(changedDraft.session.id)
        )

        let heldCatalogRead = HeldStep<Void>(
            "suspended producer catalog range read",
            cancellation: .holdThroughCancellation
        )
        armedCatalogRead.withLock { $0 = heldCatalogRead }
        let detailAfterSave = try await service.saveDraft(
            .init(
                sessionID: changedDraft.session.id,
                messageID: changedMessage.id,
                editToken: "editor-1",
                expectedMessageRevision: changedMessage.semanticRevision,
                expectedDraftRevision: try #require(changedMessage.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 3)
            )
        )
        let originalThreadIDs = Set(changedDraft.threads.map(\.thread.id))
        let deletedThreadDetail = try #require(
            detailAfterSave.threads.first { !originalThreadIDs.contains($0.thread.id) }
        )
        let deletedMessage = try #require(deletedThreadDetail.messages.first)
        _ = try await service.revertDraft(
            .init(
                sessionID: detailAfterSave.session.id,
                messageID: deletedMessage.id,
                editToken: "editor-2",
                expectedMessageRevision: deletedMessage.semanticRevision,
                expectedDraftRevision: try #require(deletedMessage.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 4)
            )
        )
        _ = try await heldCatalogRead.firstArrival()

        firstProducer.cancel()
        try await heldCatalogRead.cancellationObserved()
        try await source.acceptBatchScope(handle: handle, worktreeID: "worktree-1", scopeRevision: 1)
        let successorProducerID = UUIDv7.generate()
        let producerObservations = await source.observeProducerEvents()
        var producerObservationIterator = producerObservations.events.makeAsyncIterator()
        let deliveryFactSource = LocalFactSource<UUID, CommentProducerDeliveryFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString },
                describeFact: { fact in
                    switch fact {
                    case .delivered(let delivery): "delivered(targetRevision: \(delivery.batch.targetRevision))"
                    case .finished: "finished"
                    }
                },
                isClosing: { _, fact in
                    if case .finished = fact { return true }
                    return false
                }
            )
        )
        let deliveryFactRecorder = try deliveryFactSource.attach()
        let recordDeliveryFact = deliveryFactSource.sink
        let successor = Task {
            do {
                try await source.openBatch(
                    handle: handle, producerID: successorProducerID, snapshotRequired: { false },
                    deliver: { batch, mode in
                        try await recordCommentBatchSeal(batch, in: source, producerID: successorProducerID)
                        let delivery = RecordedCommentBatchDelivery(
                            batch: batch,
                            mode: mode,
                            producerID: successorProducerID
                        )
                        recordDeliveryFact(successorProducerID, .delivered(delivery))
                        return .completed
                    })
            } catch {
                recordDeliveryFact(successorProducerID, .finished)
                throw error
            }
            recordDeliveryFact(successorProducerID, .finished)
        }
        var observedSuccessorOpen = false
        while let observation = await producerObservationIterator.next() {
            guard case .opened(let observedHandle, let observedProducerID) = observation,
                observedHandle == handle,
                observedProducerID == successorProducerID
            else { continue }
            observedSuccessorOpen = true
            break
        }
        #expect(observedSuccessorOpen)
        var successorWaitedForPredecessor = false
        var successorInstalledBeforeP0Retired = false
        while let observation = await producerObservationIterator.next() {
            switch observation {
            case .waitingForRetirement(let observedHandle, let observedProducerID, let predecessorID)
            where observedHandle == handle && observedProducerID == successorProducerID:
                successorWaitedForPredecessor = predecessorID == firstProducerID
            case .publisherInstalled(let observedHandle, let observedProducerID)
            where observedHandle == handle && observedProducerID == successorProducerID:
                successorInstalledBeforeP0Retired = true
                #expect(Bool(false), "P1 installed while P0 still owned the handle")
            default:
                continue
            }
            break
        }
        #expect(successorWaitedForPredecessor)
        var preRetirementDelivery: RecordedCommentBatchDelivery?
        var successorFinishedBeforeP0Retired = false
        if successorInstalledBeforeP0Retired || !successorWaitedForPredecessor {
            let firstSuccessorFact = try await deliveryFactRecorder.expectNext(
                in: successorProducerID,
                where: { _ in true },
                "P1's first delivery or finish"
            )
            switch firstSuccessorFact {
            case .delivered(let overlappingDelivery):
                preRetirementDelivery = overlappingDelivery
                #expect(
                    overlappingDelivery.batch.targetRevision <= previousCursor,
                    "Overlapping P1 unexpectedly advanced the installed view cursor"
                )
            case .finished:
                successorFinishedBeforeP0Retired = true
                #expect(Bool(false), "Overlapping P1 ended before publishing its snapshot")
            }
        }

        heldCatalogRead.release()
        _ = try? await firstProducer.value
        var resumedDelivery = preRetirementDelivery
        if resumedDelivery == nil && !successorFinishedBeforeP0Retired {
            let postRetirementFact = try await deliveryFactRecorder.expectNext(
                in: successorProducerID,
                where: { _ in true },
                "P1's first post-retirement delivery or finish"
            )
            switch postRetirementFact {
            case .delivered(let delivery):
                resumedDelivery = delivery
            case .finished:
                #expect(Bool(false), "P0 cleanup retired P1 before it sealed its first batch")
            }
        }
        guard let resumedDelivery else {
            #expect(Bool(false), "P1 finished before publishing a post-retirement batch")
            successor.cancel()
            _ = try? await successor.value
            await source.retireBatchView(handle: handle)
            continuation.finish()
            deliveryFactSource.end()
            try await deliveryFactRecorder.finish()
            #expect(await service.catalogInvalidationObserverCount() == 0)
            await source.stopObservingProducerEvents(id: producerObservations.id)
            return
        }
        let deletedKeys: Set<WorktreeAnnotationCatalogKey> = [
            .thread(deletedThreadDetail.thread.id),
            .message(deletedMessage.id),
        ]
        try expectResumedBatchContinuesView(
            resumedDelivery,
            handle: handle,
            previousCursor: previousCursor,
            previousSessionRevision: previousSessionRevision,
            changedSessionKey: .session(changedDraft.session.id),
            deletedKeys: deletedKeys
        )

        // Models P0's outer producer cleanup arriving after P1 sealed its snapshot.
        await source.releaseProducerBatchScope(handle: handle, producerID: firstProducerID)
        let threadsBeforePostRestartDraft = Set(detailAfterSave.threads.map(\.thread.id))
        let postRestartDraft = try await service.createRootDraft(
            .init(
                admission: .selected(changedDraft.session.id),
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                sourceFingerprint: makeSourceFingerprint(identity: "source-1"),
                origin: .session,
                body: "P1 survives P0 cleanup",
                editToken: "editor-3",
                now: Date(timeIntervalSince1970: 5)
            )
        )
        let postRestartThread = try #require(
            postRestartDraft.threads.first { !threadsBeforePostRestartDraft.contains($0.thread.id) }
        )
        let postRestartMessage = try #require(postRestartThread.messages.first)
        _ = try await service.saveDraft(
            .init(
                sessionID: postRestartDraft.session.id,
                messageID: postRestartMessage.id,
                editToken: "editor-3",
                expectedMessageRevision: postRestartMessage.semanticRevision,
                expectedDraftRevision: try #require(postRestartMessage.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 6)
            )
        )

        if successorFinishedBeforeP0Retired {
            #expect(Bool(false), "P0 cleanup removed P1's route before the next invalidation")
        } else {
            let routingFact = try await deliveryFactRecorder.expectNext(
                in: successorProducerID,
                where: { _ in true },
                "P1's post-cleanup delivery or finish"
            )
            switch routingFact {
            case .delivered(let routedBatch):
                #expect(
                    routedBatch.batch.puts.contains {
                        $0.recordKey == WorktreeAnnotationCatalogKey.message(postRestartMessage.id).recordKey
                    },
                    "P1 did not publish the post-cleanup message through its retained route"
                )
            case .finished:
                #expect(Bool(false), "P0 cleanup removed P1's route before the next invalidation")
            }
        }

        successor.cancel()
        _ = try? await successor.value
        await source.retireBatchView(handle: handle)
        continuation.finish()
        await source.stopObservingProducerEvents(id: producerObservations.id)
        deliveryFactSource.end()
        try await deliveryFactRecorder.finish()
        #expect(await service.catalogInvalidationObserverCount() == 0)
    }

    @Test("a new Comment incarnation starts clean after the prior view retires")
    func newIncarnationStartsCleanAfterViewRetirement() async throws {
        let harness = try makeNotificationSourceHarness()
        _ = try await harness.service.createRootDraft(makeCreateRootDraftProps())
        let handle = "ended-comment-view"
        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let endedProducerID = UUIDv7.generate()
        let (batches, continuation) = AsyncStream.makeStream(
            of: RecordedCommentBatchDelivery.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        let endedProducer = Task {
            try await harness.source.openBatch(
                handle: handle, producerID: endedProducerID, snapshotRequired: { false },
                deliver: { batch, mode in
                    try await recordCommentBatchSeal(batch, in: harness.source, producerID: endedProducerID)
                    continuation.yield(.init(batch: batch, mode: mode))
                    return .completed
                })
        }
        var iterator = batches.makeAsyncIterator()
        let priorIncarnation = try #require(await iterator.next())
        #expect(priorIncarnation.batch.targetRevision == 1)
        endedProducer.cancel()
        _ = try? await endedProducer.value
        await harness.source.retireBatchView(handle: handle)
        await #expect(throws: WorktreeAnnotationServiceError.unavailable) {
            try await harness.source.acceptBatchScope(
                handle: handle,
                worktreeID: "worktree-1",
                scopeRevision: 2
            )
        }

        let newHandle = "replacement-comment-view"
        try await harness.source.acceptBatchScope(
            handle: newHandle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let replacementProducer = Task {
            try await harness.source.openBatch(
                handle: newHandle, producerID: UUIDv7.generate(), snapshotRequired: { false },
                deliver: { batch, mode in
                    continuation.yield(.init(batch: batch, mode: mode))
                    return .completed
                })
        }
        let newIncarnation = try #require(await iterator.next())
        #expect(newIncarnation.batch.handle == newHandle)
        #expect(newIncarnation.batch.baseRevision == 0)
        #expect(newIncarnation.batch.targetRevision == 1)
        #expect(newIncarnation.batch.deletes.isEmpty)
        replacementProducer.cancel()
        _ = try? await replacementProducer.value
        await harness.source.retireBatchView(handle: newHandle)
        continuation.finish()
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }
}

private enum CommentProducerDeliveryFact: Sendable {
    case delivered(RecordedCommentBatchDelivery)
    case finished
}

private func sessionSemanticRevision(
    in batch: BridgeProductCommentCatalogBatch,
    for key: WorktreeAnnotationCatalogKey
) throws -> Int {
    let put = try #require(
        batch.puts.first { WorktreeAnnotationCatalogKey(entry: $0.entry) == key }
    )
    if case .session(let session) = put.entry {
        return session.semanticRevision
    }
    Issue.record("The catalog batch omitted the expected session entry")
    return -1
}

private func expectResumedBatchContinuesView(
    _ delivery: RecordedCommentBatchDelivery,
    handle: String,
    previousCursor: Int,
    previousSessionRevision: Int,
    changedSessionKey: WorktreeAnnotationCatalogKey,
    deletedKeys: Set<WorktreeAnnotationCatalogKey>
) throws {
    #expect(delivery.mode == .snapshot)
    #expect(delivery.batch.handle == handle)
    #expect(delivery.batch.baseRevision == previousCursor)
    #expect(delivery.batch.targetRevision > previousCursor)
    #expect(delivery.batch.puts.allSatisfy { $0.revision > previousCursor })

    let changedSessionPut = try #require(
        delivery.batch.puts.first {
            WorktreeAnnotationCatalogKey(entry: $0.entry) == changedSessionKey
        }
    )
    if case .session(let session) = changedSessionPut.entry {
        #expect(session.semanticRevision > previousSessionRevision)
    } else {
        Issue.record("The resumed catalog batch omitted the changed session")
    }

    #expect(Set(delivery.batch.deletes.map(\.key)) == deletedKeys)
    #expect(delivery.batch.deletes.allSatisfy { $0.revision > previousCursor })
}

private func recordCommentBatchSeal(
    _ batch: BridgeProductCommentCatalogBatch,
    in source: BridgePaneAnnotationNotificationSource,
    producerID: UUID
) async throws {
    try Task.checkCancellation()
    await source.recordSealedCommentCatalogBatch(
        handle: batch.handle, producerID: producerID, batch: batch
    )
}

private func startRecordedCommentProducer(
    source: BridgePaneAnnotationNotificationSource, handle: String, producerID: UUID,
    deliveries: AsyncStream<RecordedCommentBatchDelivery>.Continuation
) -> Task<Void, any Error> {
    Task {
        try await source.openBatch(
            handle: handle, producerID: producerID, snapshotRequired: { false },
            deliver: { batch, mode in
                try await recordCommentBatchSeal(batch, in: source, producerID: producerID)
                deliveries.yield(.init(batch: batch, mode: mode))
                return .completed
            }
        )
    }
}

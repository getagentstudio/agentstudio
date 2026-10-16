import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Worktree annotation notification source")
struct WorktreeAnnotationNotificationSourceTests {
    @Test("E3 Comment opening waits for accepted E4 scope before the first capture")
    func batchOpeningWaitsForFirstAcceptedScope() async throws {
        let harness = try makeNotificationSourceHarness()
        let handle = "comment-view-awaiting-scope"
        let producerID = UUIDv7.generate()
        let (batches, continuation) = AsyncStream.makeStream(
            of: RecordedCommentBatchDelivery.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let openTask = Task {
            defer { continuation.finish() }
            try await harness.source.openBatch(
                handle: handle, producerID: producerID, snapshotRequired: { false },
                deliver: { batch, mode in
                    continuation.yield(.init(batch: batch, mode: mode))
                    return .completed
                })
        }
        await harness.source.waitUntilFirstBatchScopeIsNeeded(handle: handle)
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)

        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        var iterator = batches.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.mode == .snapshot)
        #expect(initial.batch.scopeRevision == 1)
        #expect(initial.batch.puts.isEmpty)
        openTask.cancel()
        _ = try? await openTask.value
        continuation.finish()
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }

    @Test("retiring a Comment handle releases E3 waiting on first E4 scope")
    func retiringHandleReleasesFirstScopeWaiter() async throws {
        let harness = try makeNotificationSourceHarness()
        let handle = "comment-view-retired-before-scope"
        let producerID = UUIDv7.generate()
        let openTask = Task {
            try await harness.source.openBatch(
                handle: handle, producerID: producerID, snapshotRequired: { false },
                deliver: { _, _ in
                    Issue.record("A retired Comment handle must not capture a catalog")
                    return .completed
                })
        }
        await harness.source.waitUntilFirstBatchScopeIsNeeded(handle: handle)
        await harness.source.retireBatchView(handle: handle)
        await #expect(throws: CancellationError.self) {
            try await openTask.value
        }
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }

    @Test("cancelling E3 releases its first-scope waiter")
    func cancelledOpeningReleasesFirstScopeWaiter() async throws {
        let harness = try makeNotificationSourceHarness()
        let handle = "comment-view-cancelled-before-scope"
        let producerID = UUIDv7.generate()
        let openTask = Task {
            try await harness.source.openBatch(
                handle: handle, producerID: producerID, snapshotRequired: { false },
                deliver: { _, _ in
                    Issue.record("A cancelled Comment opening must not capture a catalog")
                    return .completed
                })
        }
        await harness.source.waitUntilFirstBatchScopeIsNeeded(handle: handle)
        openTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await openTask.value
        }
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }

    @Test("a retained Comment view accepts its scope after producer restart")
    func retainedViewAcceptsScopeAfterProducerRestart() async throws {
        let harness = try makeNotificationSourceHarness()
        let handle = "retained-comment-view"
        let firstProducerID = UUIDv7.generate()
        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let (batches, continuation) = AsyncStream.makeStream(
            of: RecordedCommentBatchDelivery.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        let firstProducer = Task {
            try await harness.source.openBatch(
                handle: handle, producerID: firstProducerID, snapshotRequired: { false },
                deliver: { batch, mode in
                    continuation.yield(.init(batch: batch, mode: mode))
                    return .completed
                })
        }
        var iterator = batches.makeAsyncIterator()
        #expect(try #require(await iterator.next()).mode == .snapshot)

        firstProducer.cancel()
        _ = try? await firstProducer.value
        await harness.source.releaseProducerBatchScope(handle: handle, producerID: firstProducerID)

        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let successorProducerID = UUIDv7.generate()
        let successor = Task {
            try await harness.source.openBatch(
                handle: handle, producerID: successorProducerID, snapshotRequired: { false },
                deliver: { batch, mode in
                    continuation.yield(.init(batch: batch, mode: mode))
                    return .completed
                })
        }
        #expect(try #require(await iterator.next()).mode == .snapshot)
        successor.cancel()
        _ = try? await successor.value
        continuation.finish()
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }

    @Test("an ended Comment view rejects late scope admission")
    func endedViewRejectsLateScopeAdmission() async throws {
        let harness = try makeNotificationSourceHarness()
        let handle = "ended-comment-view"
        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        await harness.source.retireBatchView(handle: handle)
        await #expect(throws: WorktreeAnnotationServiceError.unavailable) {
            try await harness.source.acceptBatchScope(
                handle: handle,
                worktreeID: "worktree-1",
                scopeRevision: 2
            )
        }
    }

    @Test("batch source observes committed ranges after its initial current-row snapshot")
    func batchSourceObservesCommittedRanges() async throws {
        let harness = try makeNotificationSourceHarness()
        let draft = try await harness.service.createRootDraft(makeCreateRootDraftProps())
        try await harness.source.acceptBatchScope(
            handle: "comment-view-1",
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let (batches, continuation) = AsyncStream.makeStream(
            of: RecordedCommentBatchDelivery.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        let openTask = Task {
            defer { continuation.finish() }
            try await harness.source.openBatch(
                handle: "comment-view-1", producerID: UUIDv7.generate(), snapshotRequired: { false },
                deliver: { batch, mode in
                    continuation.yield(.init(batch: batch, mode: mode))
                    return .completed
                })
        }
        var iterator = batches.makeAsyncIterator()
        guard let initial = await iterator.next() else {
            try await openTask.value
            Issue.record("The initial comment batch did not arrive")
            return
        }
        #expect(initial.mode == .snapshot)
        #expect(initial.batch.baseRevision == 0)
        #expect(initial.batch.targetRevision == 1)
        #expect(initial.batch.puts.count == 3)
        #expect(initial.batch.deletes.isEmpty)

        let message = try #require(draft.threads.first?.messages.first)
        _ = try await harness.service.saveDraft(
            .init(
                sessionID: draft.session.id,
                messageID: message.id,
                editToken: "editor-1",
                expectedMessageRevision: message.semanticRevision,
                expectedDraftRevision: try #require(message.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 3)
            )
        )
        let committed = try #require(await iterator.next())
        #expect(committed.mode == .change)
        #expect(committed.batch.baseRevision == 1)
        #expect(committed.batch.targetRevision == 2)
        #expect(committed.batch.puts.count == 3)
        #expect(committed.batch.deletes.isEmpty)

        await harness.source.requestBatchResnapshot(handle: "comment-view-1")
        let replacement = try #require(await iterator.next())
        #expect(replacement.mode == .snapshot)
        #expect(replacement.batch.baseRevision == 2)
        #expect(replacement.batch.targetRevision == 3)
        #expect(replacement.batch.puts.count == 3)

        openTask.cancel()
        _ = try? await openTask.value
        continuation.finish()
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }

    @Test("same-handle Comment demand changes keep catalog membership")
    func sameHandleDemandChangeKeepsCatalogMembership() async throws {
        let harness = try makeNotificationSourceHarness()
        let draft = try await harness.service.createRootDraft(makeCreateRootDraftProps())
        let handle = "comment-view-changing-subjects"
        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let (batches, continuation) = AsyncStream.makeStream(
            of: RecordedCommentBatchDelivery.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        let openTask = Task {
            defer { continuation.finish() }
            try await harness.source.openBatch(
                handle: handle, producerID: UUIDv7.generate(), snapshotRequired: { false },
                deliver: { batch, mode in
                    continuation.yield(.init(batch: batch, mode: mode))
                    return .completed
                })
        }
        var iterator = batches.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.mode == .snapshot)
        #expect(initial.batch.scopeRevision == 1)
        #expect(initial.batch.puts.count == 3)

        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 2
        )
        let message = try #require(draft.threads.first?.messages.first)
        _ = try await harness.service.saveDraft(
            .init(
                sessionID: draft.session.id,
                messageID: message.id,
                editToken: "editor-1",
                expectedMessageRevision: message.semanticRevision,
                expectedDraftRevision: try #require(message.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 3)
            )
        )
        let committed = try #require(await iterator.next())
        #expect(committed.mode == .change)
        #expect(committed.batch.handle == handle)
        #expect(committed.batch.scopeRevision == 2)
        #expect(committed.batch.baseRevision == 1)
        #expect(committed.batch.puts.count == 3)
        #expect(committed.batch.deletes.isEmpty)
        openTask.cancel()
        _ = try? await openTask.value
        continuation.finish()
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }

    @Test("a resnapshot requested during held delivery recaptures current admitted rows")
    func heldDeliveryResnapshotRecapturesCurrentRows() async throws {
        let harness = try makeNotificationSourceHarness()
        let draft = try await harness.service.createRootDraft(makeCreateRootDraftProps())
        let handle = "comment-view-lost-ack"
        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let initialDelivery = HeldStep<Void>("commentInitialDelivery")
        let (batches, continuation) = AsyncStream.makeStream(
            of: RecordedCommentBatchDelivery.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        let openTask = Task {
            defer { continuation.finish() }
            try await harness.source.openBatch(
                handle: handle, producerID: UUIDv7.generate(), snapshotRequired: { false },
                deliver: { batch, mode in
                    continuation.yield(.init(batch: batch, mode: mode))
                    if batch.baseRevision == 0 { try await initialDelivery.arrive(()) }
                    return .completed
                })
        }
        var iterator = batches.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.mode == .snapshot)
        _ = try await initialDelivery.firstArrival()

        let message = try #require(draft.threads.first?.messages.first)
        _ = try await harness.service.saveDraft(
            .init(
                sessionID: draft.session.id,
                messageID: message.id,
                editToken: "editor-1",
                expectedMessageRevision: message.semanticRevision,
                expectedDraftRevision: try #require(message.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 3)
            )
        )
        await harness.source.requestBatchResnapshot(handle: handle)
        initialDelivery.release()

        let recaptured = try #require(await iterator.next())
        #expect(recaptured.mode == .snapshot)
        #expect(recaptured.batch.baseRevision == 1)
        #expect(recaptured.batch.targetRevision == 2)
        let currentRows = try await harness.service.captureCurrentCatalogRange(
            worktreeID: "worktree-1",
            range: .worktree
        )
        let recapturedRows = Dictionary(
            uniqueKeysWithValues: recaptured.batch.puts.map { record in
                (WorktreeAnnotationCatalogKey(entry: record.entry), record.entry)
            }
        )
        #expect(recapturedRows == currentRows)
        openTask.cancel()
        _ = try? await openTask.value
        continuation.finish()
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }

    @Test("recovery control invalidation recaptures one current Comment range")
    func recoveryControlRecapturesCurrentRange() async throws {
        let harness = try makeNotificationSourceHarness()
        _ = try await harness.service.createRootDraft(makeCreateRootDraftProps())
        let handle = "comment-view-recovery-control"
        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let (deliveries, continuation) = AsyncStream.makeStream(
            of: RecordedCommentBatchDelivery.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        let openTask = Task {
            defer { continuation.finish() }
            try await harness.source.openBatch(
                handle: handle, producerID: UUIDv7.generate(), snapshotRequired: { false },
                deliver: { batch, mode in
                    continuation.yield(.init(batch: batch, mode: mode))
                    return .completed
                })
        }
        var iterator = deliveries.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.mode == .snapshot)

        let recoveryChange: WorktreeAnnotationCommittedChange = .control(
            worktreeIDs: ["worktree-1"], reason: .recovery, sessionChanges: []
        )
        await harness.service.emitCommittedCatalogInvalidation(recoveryChange)
        await harness.service.applyCommittedChange(
            recoveryChange,
            operationCorrelationID: String(repeating: "c", count: 64)
        )
        let recovered = try #require(await iterator.next())
        #expect(recovered.mode == .change)
        #expect(recovered.batch.baseRevision == initial.batch.targetRevision)
        #expect(recovered.batch.targetRevision == initial.batch.targetRevision + 1)
        let currentRows = try await harness.service.captureCurrentCatalogRange(
            worktreeID: "worktree-1",
            range: .worktree
        )
        #expect(
            Set(recovered.batch.puts.map(\.recordKey))
                == Set(currentRows.keys.map(\.recordKey))
        )
        openTask.cancel()
        _ = try? await openTask.value
        continuation.finish()
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }

    @Test("failed Comment batch delivery terminates the source and removes its observer")
    func batchDeliveryFailureRemovesObserver() async throws {
        let harness = try makeNotificationSourceHarness()
        let draft = try await harness.service.createRootDraft(makeCreateRootDraftProps())
        let handle = "comment-view-failed-delivery"
        try await harness.source.acceptBatchScope(
            handle: handle,
            worktreeID: "worktree-1",
            scopeRevision: 1
        )
        let (initialDeliveries, continuation) = AsyncStream.makeStream(
            of: BridgeProductCommentCatalogBatch.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let openTask = Task {
            defer { continuation.finish() }
            try await harness.source.openBatch(
                handle: handle, producerID: UUIDv7.generate(), snapshotRequired: { false },
                deliver: { batch, _ in
                    if batch.baseRevision > 0 { throw NotificationDeliveryFailure.injected }
                    continuation.yield(batch)
                    return .completed
                })
        }
        var iterator = initialDeliveries.makeAsyncIterator()
        _ = try #require(await iterator.next())
        let message = try #require(draft.threads.first?.messages.first)
        _ = try await harness.service.saveDraft(
            .init(
                sessionID: draft.session.id,
                messageID: message.id,
                editToken: "editor-1",
                expectedMessageRevision: message.semanticRevision,
                expectedDraftRevision: try #require(message.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 3)
            )
        )
        await #expect(throws: NotificationDeliveryFailure.injected) {
            try await openTask.value
        }
        continuation.finish()
        #expect(await harness.service.catalogInvalidationObserverCount() == 0)
    }
}

struct NotificationSourceHarness {
    let service: WorktreeAnnotationServiceActor
    let source: BridgePaneAnnotationNotificationSource
}

func makeNotificationSourceHarness() throws -> NotificationSourceHarness {
    let repository = try makeAnnotationRepository()
    let service = WorktreeAnnotationServiceActor(
        repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(repository: repository)
    )
    return .init(
        service: service,
        source: BridgePaneAnnotationNotificationSource(
            service: service,
            worktreeID: "worktree-1"
        )
    )
}

struct RecordedCommentBatchDelivery: Sendable {
    let batch: BridgeProductCommentCatalogBatch
    let mode: BridgeProductBatchMode
    let producerID: UUID?

    init(batch: BridgeProductCommentCatalogBatch, mode: BridgeProductBatchMode, producerID: UUID? = nil) {
        self.batch = batch
        self.mode = mode
        self.producerID = producerID
    }
}

private enum NotificationDeliveryFailure: Error {
    case injected
}

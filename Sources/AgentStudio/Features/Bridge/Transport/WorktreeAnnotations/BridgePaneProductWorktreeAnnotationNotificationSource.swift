import AgentStudioInfrastructure
import Foundation

private enum BridgePaneCommentBatchNotification: Sendable {
    case invalidation(Set<WorktreeAnnotationCatalogRange>)
    case resnapshot
    case unavailable

    func merging(displaced: Self) -> Self {
        switch (self, displaced) {
        case (.unavailable, _), (_, .unavailable): .unavailable
        case (.resnapshot, _), (_, .resnapshot): .resnapshot
        case (.invalidation(let newest), .invalidation(let older)):
            .invalidation(newest.union(older))
        }
    }
}

enum BridgePaneAnnotationProducerObservation: Sendable {
    case opened(handle: String, producerID: UUID)
    case waitingForRetirement(handle: String, producerID: UUID, predecessorID: UUID)
    case publisherInstalled(handle: String, producerID: UUID)
    case sealed(handle: String, producerID: UUID, batch: BridgeProductCommentCatalogBatch)
    case finished(
        handle: String,
        producerID: UUID,
        reason: BridgePaneAnnotationProducerFinishReason
    )
}

enum BridgePaneAnnotationProducerFinishReason: Sendable, CustomStringConvertible {
    case completed
    case failed(BridgePaneAnnotationProducerFailure)
    case cancelled

    var description: String {
        switch self {
        case .completed: "completed"
        case .failed(let failure): "failed(\(failure))"
        case .cancelled: "cancelled"
        }
    }
}

struct BridgePaneAnnotationProducerFailure: Sendable, CustomStringConvertible {
    let typeName: String
    let message: String

    init(_ error: any Error) {
        typeName = String(reflecting: type(of: error))
        message = String(describing: error)
    }

    var description: String { "\(typeName): \(message)" }
}

actor BridgePaneAnnotationNotificationSource {
    private struct BatchNotificationOwner {
        let producerID: UUID
        let continuation: AsyncStream<BridgePaneCommentBatchNotification>.Continuation
    }

    private struct BatchPublisherOwner {
        let producerID: UUID
        let publisher: BridgeProductCommentCatalogPublisher
    }

    private struct AdmittedBatchScope: Sendable {
        let revision: Int
    }

    private let service: WorktreeAnnotationServiceActor?
    private let worktreeID: String
    private var batchNotificationByHandle: [String: BatchNotificationOwner] = [:]
    private var batchPublisherByHandle: [String: BatchPublisherOwner] = [:]
    private var pendingProducerIDByHandle: [String: UUID] = [:]
    private var publisherRetirementWaitersByHandle: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var catalogContinuityByHandle: [String: BridgeProductCommentCatalogPublisherContinuity] = [:]
    private var admittedBatchScopeByHandle: [String: AdmittedBatchScope] = [:]
    private var firstScopeWaiterByHandle: [String: AsyncStream<Void>.Continuation] = [:]
    private var firstScopeWaiterObserversByHandle: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var retiredBatchHandles: Set<String> = []
    private var pendingResnapshotHandles: Set<String> = []
    private var producerObservationContinuations:
        [UUID: AsyncStream<BridgePaneAnnotationProducerObservation>.Continuation] = [:]

    static let unavailable = BridgePaneAnnotationNotificationSource(
        service: nil,
        worktreeID: ""
    )

    init(
        service: WorktreeAnnotationServiceActor?,
        worktreeID: String
    ) {
        self.service = service
        self.worktreeID = worktreeID
    }

    func admittedWorktreeID() -> String? {
        service == nil ? nil : worktreeID
    }

    /// Mirrors one accepted E4 scope. The view handle remains the lifetime;
    /// the subject set is the interest captured by N10 behind the W4 barrier.
    func acceptBatchScope(
        handle: String,
        worktreeID scopedWorktreeID: String,
        scopeRevision: Int
    ) async throws {
        guard service != nil, scopedWorktreeID == worktreeID, !handle.isEmpty, scopeRevision > 0,
            !retiredBatchHandles.contains(handle)
        else {
            throw WorktreeAnnotationServiceError.unavailable
        }
        if let current = admittedBatchScopeByHandle[handle], scopeRevision <= current.revision {
            return
        }
        admittedBatchScopeByHandle[handle] = .init(revision: scopeRevision)
        firstScopeWaiterByHandle[handle]?.yield(())
        if let owner = batchPublisherByHandle[handle] {
            _ = await owner.publisher.acceptScope(revision: scopeRevision)
        }
    }

    func releaseProducerBatchScope(handle: String, producerID: UUID) async {
        if let owner = batchNotificationByHandle[handle], owner.producerID == producerID {
            batchNotificationByHandle.removeValue(forKey: handle)?.continuation.finish()
        }
        guard let owner = batchPublisherByHandle[handle], owner.producerID == producerID else { return }
        await retireBatchPublisher(owner, handle: handle)
    }

    func retireBatchView(handle: String) async {
        retiredBatchHandles.insert(handle)
        catalogContinuityByHandle.removeValue(forKey: handle)
        admittedBatchScopeByHandle.removeValue(forKey: handle)
        pendingResnapshotHandles.remove(handle)
        pendingProducerIDByHandle.removeValue(forKey: handle)
        firstScopeWaiterByHandle.removeValue(forKey: handle)?.finish()
        for observer in firstScopeWaiterObserversByHandle.removeValue(forKey: handle) ?? [] {
            observer.resume()
        }
        batchNotificationByHandle.removeValue(forKey: handle)?.continuation.finish()
        if let owner = batchPublisherByHandle[handle] {
            await retireBatchPublisher(owner, handle: handle)
        }
    }

    /// Observation seam for callers that need to know E3 is waiting on E4.
    func waitUntilFirstBatchScopeIsNeeded(handle: String) async {
        if firstScopeWaiterByHandle[handle] != nil || retiredBatchHandles.contains(handle) { return }
        await withCheckedContinuation { continuation in
            firstScopeWaiterObserversByHandle[handle, default: []].append(continuation)
        }
    }

    func requestBatchResnapshot(handle: String) {
        guard admittedBatchScopeByHandle[handle] != nil else { return }
        guard let owner = batchNotificationByHandle[handle] else {
            pendingResnapshotHandles.insert(handle)
            return
        }
        enqueueBatchNotification(.resnapshot, into: owner.continuation)
    }

    /// Observation seam for tests that must pair source overlap with native sealing.
    func observeProducerEvents() -> (id: UUID, events: AsyncStream<BridgePaneAnnotationProducerObservation>) {
        let observerID = UUIDv7.generate()
        let (stream, continuation) = AsyncStream.makeStream(
            of: BridgePaneAnnotationProducerObservation.self,
            bufferingPolicy: .bufferingOldest(32)
        )
        producerObservationContinuations[observerID] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeProducerObservation(observerID) }
        }
        return (observerID, stream)
    }

    func stopObservingProducerEvents(id observerID: UUID) {
        producerObservationContinuations.removeValue(forKey: observerID)?.finish()
    }

    func recordSealedCommentCatalogBatch(
        handle: String,
        producerID: UUID,
        batch: BridgeProductCommentCatalogBatch
    ) async {
        guard batch.handle == handle, let owner = batchPublisherByHandle[handle],
            owner.producerID == producerID,
            await owner.publisher.recordSealedBatch(batch)
        else { return }
        publishProducerObservation(.sealed(handle: handle, producerID: producerID, batch: batch))
    }

    /// N10 observes invalidations before its first current-row capture. Each
    /// complete range read installs through one publisher before the next read.
    func openBatch(
        handle: String,
        producerID: UUID,
        snapshotRequired: @escaping @Sendable () async -> Bool,
        deliver:
            @Sendable (BridgeProductCommentCatalogBatch, BridgeProductBatchMode) async throws ->
            BridgeProductViewEmissionOutcome
    ) async throws {
        guard let service else {
            throw WorktreeAnnotationServiceError.unavailable
        }
        guard !retiredBatchHandles.contains(handle) else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        pendingProducerIDByHandle[handle] = producerID
        publishProducerObservation(.opened(handle: handle, producerID: producerID))
        var finishReason: BridgePaneAnnotationProducerFinishReason = .completed
        defer {
            if pendingProducerIDByHandle[handle] == producerID {
                pendingProducerIDByHandle.removeValue(forKey: handle)
            }
            publishProducerObservation(
                .finished(handle: handle, producerID: producerID, reason: finishReason)
            )
        }
        do {
            _ = try await waitForFirstAdmittedBatchScope(handle: handle)
            try await waitForCurrentPublisherRetirement(handle: handle, producerID: producerID)
            try Task.checkCancellation()
            guard !retiredBatchHandles.contains(handle), pendingProducerIDByHandle[handle] == producerID else {
                throw WorktreeAnnotationServiceError.staleSourceEpoch
            }
            let capturedWorktreeID = worktreeID
            let observer = await service.registerCatalogInvalidationObserver(worktreeID: capturedWorktreeID)
            if Task.isCancelled || retiredBatchHandles.contains(handle)
                || pendingProducerIDByHandle[handle] != producerID
            {
                await service.removeCatalogInvalidationObserver(token: observer.token)
                if Task.isCancelled { throw CancellationError() }
                throw WorktreeAnnotationServiceError.staleSourceEpoch
            }
            guard let admittedScope = admittedBatchScopeByHandle[handle] else {
                await service.removeCatalogInvalidationObserver(token: observer.token)
                throw WorktreeAnnotationServiceError.staleSourceEpoch
            }
            let (notifications, notificationContinuation) = AsyncStream.makeStream(
                of: BridgePaneCommentBatchNotification.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            batchNotificationByHandle[handle] = .init(
                producerID: producerID,
                continuation: notificationContinuation
            )
            if pendingResnapshotHandles.remove(handle) != nil {
                enqueueBatchNotification(.resnapshot, into: notificationContinuation)
            }
            let forwarder = Task {
                for await invalidation in observer.stream {
                    guard invalidation.worktreeID == capturedWorktreeID else {
                        enqueueBatchNotification(.unavailable, into: notificationContinuation)
                        break
                    }
                    enqueueBatchNotification(.invalidation(invalidation.ranges), into: notificationContinuation)
                }
            }
            let publisher = BridgeProductCommentCatalogPublisher(
                handle: handle,
                scopeRevision: admittedScope.revision,
                continuity: catalogContinuityByHandle[handle] ?? .init(),
                readCurrent: { range in
                    try await service.captureCurrentCatalogRange(
                        worktreeID: capturedWorktreeID,
                        range: range
                    )
                }
            )
            batchPublisherByHandle[handle] = .init(producerID: producerID, publisher: publisher)
            publishProducerObservation(.publisherInstalled(handle: handle, producerID: producerID))
            pendingProducerIDByHandle.removeValue(forKey: handle)
            do {
                try await deliverSnapshotAndInvalidationBatches(
                    notifications,
                    publisher: publisher,
                    snapshotRequired: snapshotRequired,
                    deliver: deliver
                )
                finishBatchNotification(handle: handle, producerID: producerID)
                await service.removeCatalogInvalidationObserver(token: observer.token)
                forwarder.cancel()
                await forwarder.value
                await retireBatchPublisher(.init(producerID: producerID, publisher: publisher), handle: handle)
            } catch {
                finishBatchNotification(handle: handle, producerID: producerID)
                await service.removeCatalogInvalidationObserver(token: observer.token)
                forwarder.cancel()
                await forwarder.value
                await retireBatchPublisher(.init(producerID: producerID, publisher: publisher), handle: handle)
                throw error
            }
        } catch {
            finishReason =
                Task.isCancelled || error is CancellationError
                ? .cancelled
                : .failed(BridgePaneAnnotationProducerFailure(error))
            throw error
        }
        if Task.isCancelled { finishReason = .cancelled }
    }

    private func deliverSnapshotAndInvalidationBatches(
        _ notifications: AsyncStream<BridgePaneCommentBatchNotification>,
        publisher: BridgeProductCommentCatalogPublisher,
        snapshotRequired: @Sendable () async -> Bool,
        deliver:
            @Sendable (BridgeProductCommentCatalogBatch, BridgeProductBatchMode) async throws ->
            BridgeProductViewEmissionOutcome
    ) async throws {
        if let snapshot = try await publisher.captureSnapshot() {
            try await deliverCurrentBatch(snapshot, mode: .snapshot, publisher: publisher, deliver: deliver)
        }
        for await notification in notifications {
            try Task.checkCancellation()
            switch notification {
            case .resnapshot:
                guard let snapshot = try await publisher.captureSnapshot() else { continue }
                try await deliverCurrentBatch(snapshot, mode: .snapshot, publisher: publisher, deliver: deliver)
            case .invalidation(let ranges):
                for range in ranges { await publisher.invalidate(range) }
                while await publisher.pendingDirtyRangeCount() > 0 {
                    if await snapshotRequired() {
                        guard let snapshot = try await publisher.captureSnapshot() else {
                            throw WorktreeAnnotationServiceError.staleSourceEpoch
                        }
                        try await deliverCurrentBatch(snapshot, mode: .snapshot, publisher: publisher, deliver: deliver)
                        continue
                    }
                    guard let batch = try await publisher.captureDirty() else {
                        throw WorktreeAnnotationServiceError.staleSourceEpoch
                    }
                    try await deliverCurrentBatch(batch, mode: .change, publisher: publisher, deliver: deliver)
                }
            case .unavailable:
                throw WorktreeAnnotationServiceError.unavailable
            }
        }
    }

    private func deliverCurrentBatch(
        _ capturedBatch: BridgeProductCommentCatalogBatch,
        mode capturedMode: BridgeProductBatchMode,
        publisher: BridgeProductCommentCatalogPublisher,
        deliver:
            @Sendable (BridgeProductCommentCatalogBatch, BridgeProductBatchMode) async throws ->
            BridgeProductViewEmissionOutcome
    ) async throws {
        var batch = capturedBatch
        var mode = capturedMode
        while true {
            try Task.checkCancellation()
            switch try await deliver(batch, mode) {
            case .completed: return
            case .retired: throw WorktreeAnnotationServiceError.staleSourceEpoch
            case .resnapshotRequired:
                guard let snapshot = try await publisher.captureSnapshot() else {
                    throw WorktreeAnnotationServiceError.staleSourceEpoch
                }
                batch = snapshot
                mode = .snapshot
            }
        }
    }

    private func retireBatchPublisher(
        _ owner: BatchPublisherOwner,
        handle: String
    ) async {
        let continuity = await owner.publisher.retireAndCaptureContinuity()
        guard let currentOwner = batchPublisherByHandle[handle],
            currentOwner.producerID == owner.producerID,
            currentOwner.publisher === owner.publisher
        else { return }
        batchPublisherByHandle.removeValue(forKey: handle)
        if !retiredBatchHandles.contains(handle) {
            catalogContinuityByHandle[handle] = continuity
        }
        for waiter in publisherRetirementWaitersByHandle.removeValue(forKey: handle) ?? [] {
            waiter.resume()
        }
    }

    private func waitForCurrentPublisherRetirement(handle: String, producerID: UUID) async throws {
        guard let predecessor = batchPublisherByHandle[handle] else { return }
        publishProducerObservation(
            .waitingForRetirement(
                handle: handle,
                producerID: producerID,
                predecessorID: predecessor.producerID
            )
        )
        await withCheckedContinuation { continuation in
            publisherRetirementWaitersByHandle[handle, default: []].append(continuation)
        }
        try Task.checkCancellation()
        guard !retiredBatchHandles.contains(handle) else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
    }

    private func finishBatchNotification(handle: String, producerID: UUID) {
        guard let owner = batchNotificationByHandle[handle], owner.producerID == producerID else { return }
        batchNotificationByHandle.removeValue(forKey: handle)?.continuation.finish()
    }

    private func publishProducerObservation(_ observation: BridgePaneAnnotationProducerObservation) {
        for continuation in producerObservationContinuations.values {
            _ = continuation.yield(observation)
        }
    }

    private func removeProducerObservation(_ observerID: UUID) {
        producerObservationContinuations.removeValue(forKey: observerID)
    }

    private func waitForFirstAdmittedBatchScope(handle: String) async throws -> AdmittedBatchScope {
        try Task.checkCancellation()
        guard !retiredBatchHandles.contains(handle) else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        if let admittedScope = admittedBatchScopeByHandle[handle] { return admittedScope }
        guard firstScopeWaiterByHandle[handle] == nil else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        firstScopeWaiterByHandle[handle] = continuation
        for observer in firstScopeWaiterObserversByHandle.removeValue(forKey: handle) ?? [] {
            observer.resume()
        }
        defer {
            firstScopeWaiterByHandle.removeValue(forKey: handle)
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        while await iterator.next() != nil {
            try Task.checkCancellation()
            if let admittedScope = admittedBatchScopeByHandle[handle] { return admittedScope }
        }
        throw CancellationError()
    }

    private func enqueueBatchNotification(
        _ notification: BridgePaneCommentBatchNotification,
        into continuation: AsyncStream<BridgePaneCommentBatchNotification>.Continuation
    ) {
        if case .dropped(let displaced) = continuation.yield(notification) {
            _ = continuation.yield(notification.merging(displaced: displaced))
        }
    }
}

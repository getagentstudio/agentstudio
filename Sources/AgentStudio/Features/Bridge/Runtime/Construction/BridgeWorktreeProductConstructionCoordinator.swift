import Foundation

package actor BridgeWorktreeProductConstructionCoordinator {
    private let eventSink: BridgeWorktreeProductConstructionEventSink?
    var currentEpochByWorktree: [BridgeWorktreeIdentityKey: BridgeWorktreeFreshnessEpoch] = [:]
    var currentEntryNonceByIdentity: [BridgeConstructionBuildIdentity: UInt64] = [:]
    var entriesByNonce: [UInt64: BridgeConstructionEntry] = [:]
    private var entryNonceByWaiterNonce: [UInt64: UInt64] = [:]
    var isClosed = false
    private var nextEntryNonce: UInt64 = 1
    private var nextLeaseNonce: UInt64 = 1
    var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    package init(eventSink: BridgeWorktreeProductConstructionEventSink? = nil) {
        self.eventSink = eventSink
    }

    func acquire(
        key: BridgeWorktreeProductConstructionKey,
        expectedEpoch: BridgeWorktreeFreshnessEpoch? = nil,
        reviewProgress: BridgeReviewConstructionProgressSink? = nil,
        build:
            @escaping @Sendable (BridgeWorktreeProductConstructionContext) async throws
            -> BridgeWorktreeProductConstructionArtifact
    ) async throws -> BridgeWorktreeProductConstructionLease {
        try ensureOpen()
        try Task.checkCancellation()
        let epoch = currentEpoch(for: key.worktree)
        guard expectedEpoch == nil || expectedEpoch == epoch else {
            throw BridgeWorktreeProductConstructionError.freshnessEpochMismatch
        }
        let identity = BridgeConstructionBuildIdentity(key: key, epoch: epoch)
        let leaseNonce = takeNextLeaseNonce()
        let cancellationState = BridgeConstructionCancellationState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    identity: identity,
                    leaseNonce: leaseNonce,
                    cancellationState: cancellationState,
                    continuation: continuation,
                    reviewProgress: reviewProgress,
                    build: build
                )
            }
        } onCancel: {
            cancellationState.cancel()
            Task {
                await self.cancelWaiter(leaseNonce: leaseNonce)
            }
        }
    }

    @discardableResult
    package func invalidate(worktree: BridgeWorktreeIdentityKey) -> BridgeWorktreeFreshnessEpoch {
        guard !isClosed else {
            return currentEpochByWorktree[worktree] ?? BridgeWorktreeFreshnessEpoch(rawValue: 1)
        }
        let previousEpoch = currentEpoch(for: worktree)
        let advancedEpoch = BridgeWorktreeFreshnessEpoch(rawValue: previousEpoch.rawValue &+ 1)
        currentEpochByWorktree[worktree] = advancedEpoch

        let affectedEntryNonces = entriesByNonce.values
            .filter { $0.identity.key.worktree == worktree && $0.identity.epoch != advancedEpoch }
            .map(\.nonce)
        for entryNonce in affectedEntryNonces {
            guard var entry = entriesByNonce[entryNonce] else { continue }
            if currentEntryNonceByIdentity[entry.identity] == entryNonce {
                currentEntryNonceByIdentity.removeValue(forKey: entry.identity)
            }
            emit(.invalidated, entry: entry)
            switch entry.phase {
            case .building:
                if entry.mode == .progressiveFile, !entry.activeLeaseNonces.isEmpty {
                    // New acquisitions use the advanced epoch; admitted consumers finish this scan.
                    entriesByNonce[entryNonce] = entry
                    continue
                }
                failWaiters(in: &entry, with: BridgeWorktreeProductConstructionError.invalidated)
                failFileReadWaiters(
                    in: &entry,
                    with: BridgeWorktreeProductConstructionError.invalidated
                )
                if entry.mode == .progressiveFile {
                    entry.progressiveBuildTask?.cancel()
                    entry.activeLeaseNonces.removeAll(keepingCapacity: false)
                    entry.progressiveFileState = nil
                }
                if entry.isInFlight {
                    entry.phase = .tombstone
                    entriesByNonce[entryNonce] = entry
                    emit(.tombstoneCreated, entry: entry)
                } else {
                    removeEntry(entry)
                }
            case .ready:
                if entry.activeLeaseNonces.isEmpty {
                    removeEntry(entry)
                } else {
                    entriesByNonce[entryNonce] = entry
                }
            case .tombstone:
                entriesByNonce[entryNonce] = entry
            }
        }
        return advancedEpoch
    }

    @discardableResult
    func release(
        _ lease: BridgeWorktreeProductConstructionLease
    ) -> BridgeWorktreeProductConstructionLeaseRelease {
        guard var entry = entriesByNonce[lease.entryNonce],
            entry.identity.key == lease.key,
            entry.identity.epoch == lease.epoch,
            entry.activeLeaseNonces.remove(lease.leaseNonce) != nil
        else { return .noMatchingLease }

        emit(.leaseReleased, entry: entry, leaseNonce: lease.leaseNonce)
        guard entry.activeLeaseNonces.isEmpty else {
            entriesByNonce[entry.nonce] = entry
            return .retainedByOtherLeases
        }
        removeEntry(entry)
        return .artifactInvalidated
    }

    func beginShutdown() {
        isClosed = true
        currentEpochByWorktree.removeAll(keepingCapacity: false)
        currentEntryNonceByIdentity.removeAll(keepingCapacity: false)
        let entryNonces = Array(entriesByNonce.keys)
        for entryNonce in entryNonces {
            guard var entry = entriesByNonce[entryNonce] else { continue }
            failWaiters(
                in: &entry,
                with: BridgeWorktreeProductConstructionError.coordinatorClosed
            )
            failFileReadWaiters(
                in: &entry,
                with: BridgeWorktreeProductConstructionError.coordinatorClosed
            )
            entry.activeLeaseNonces.removeAll(keepingCapacity: false)
            entry.preparedFileLeaseNonces.removeAll(keepingCapacity: false)
            entry.progressiveBuildTask?.cancel()
            entry.progressiveFileState = nil

            guard entry.isInFlight else {
                removeEntry(entry)
                continue
            }
            let wasTombstone: Bool
            if case .tombstone = entry.phase {
                wasTombstone = true
            } else {
                wasTombstone = false
            }
            entry.phase = .tombstone
            entriesByNonce[entryNonce] = entry
            if !wasTombstone {
                emit(.tombstoneCreated, entry: entry)
            }
        }
        resumeShutdownWaitersIfDrained()
    }

    private func enqueue(
        identity: BridgeConstructionBuildIdentity,
        leaseNonce: UInt64,
        cancellationState: BridgeConstructionCancellationState,
        continuation: CheckedContinuation<BridgeWorktreeProductConstructionLease, any Error>,
        reviewProgress: BridgeReviewConstructionProgressSink?,
        build:
            @escaping @Sendable (BridgeWorktreeProductConstructionContext) async throws
            -> BridgeWorktreeProductConstructionArtifact
    ) {
        if let entryNonce = currentEntryNonceByIdentity[identity],
            var entry = entriesByNonce[entryNonce]
        {
            guard entry.mode == .completionOnly else {
                continuation.resume(
                    throwing: BridgeWorktreeProductConstructionError.acquisitionModeMismatch
                )
                return
            }
            switch entry.phase {
            case .building:
                let waiter = BridgeConstructionWaiter(
                    leaseNonce: leaseNonce,
                    cancellationState: cancellationState,
                    continuation: continuation,
                    reviewProgress: reviewProgress
                )
                entry.waiters[leaseNonce] = waiter
                entryNonceByWaiterNonce[leaseNonce] = entryNonce
                entriesByNonce[entryNonce] = entry
                emit(.consumerJoined, entry: entry, leaseNonce: leaseNonce)
                return
            case .ready(let artifact):
                guard !cancellationState.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    emit(.consumerCancelled, entry: entry, leaseNonce: leaseNonce)
                    return
                }
                entry.activeLeaseNonces.insert(leaseNonce)
                entriesByNonce[entryNonce] = entry
                emit(.consumerJoined, entry: entry, leaseNonce: leaseNonce)
                continuation.resume(
                    returning: makeLease(
                        entry: entry,
                        leaseNonce: leaseNonce,
                        artifact: artifact
                    )
                )
                return
            case .tombstone:
                currentEntryNonceByIdentity.removeValue(forKey: identity)
            }
        }

        let entryNonce = takeNextEntryNonce()
        let waiter = BridgeConstructionWaiter(
            leaseNonce: leaseNonce,
            cancellationState: cancellationState,
            continuation: continuation,
            reviewProgress: reviewProgress
        )
        let entry = BridgeConstructionEntry(
            identity: identity,
            nonce: entryNonce,
            mode: .completionOnly,
            phase: .building,
            isInFlight: true,
            waiters: [leaseNonce: waiter],
            activeLeaseNonces: [],
            preparedFileLeaseNonces: [],
            progressiveFileState: nil,
            progressiveBuildTask: nil
        )
        entriesByNonce[entryNonce] = entry
        currentEntryNonceByIdentity[identity] = entryNonce
        entryNonceByWaiterNonce[leaseNonce] = entryNonce
        emit(.buildStarted, entry: entry, leaseNonce: leaseNonce)

        let context = BridgeWorktreeProductConstructionContext(
            key: identity.key,
            epoch: identity.epoch,
            entryNonce: entryNonce,
            reviewProgress: { [weak self] phase in
                await self?.reportReviewProgress(phase, entryNonce: entryNonce, epoch: identity.epoch)
            }
        )
        // Construction must not inherit this coordinator's actor isolation.
        // swiftlint:disable:next no_task_detached
        Task.detached { [weak self] in
            let result: Result<BridgeWorktreeProductConstructionArtifact, any Error>
            do {
                result = .success(try await build(context))
            } catch {
                result = .failure(error)
            }
            await self?.complete(entryNonce: entryNonce, result: result)
        }
    }

    private func complete(
        entryNonce: UInt64,
        result: Result<BridgeWorktreeProductConstructionArtifact, any Error>
    ) {
        switch result {
        case .failure(let error):
            completeFailure(entryNonce: entryNonce, error: error)
        case .success(let artifact):
            switch artifact {
            case .fileSnapshot(let snapshot):
                completeFileSuccess(entryNonce: entryNonce, snapshot: snapshot)
            case .reviewTemplate(let template):
                completeReviewSuccess(entryNonce: entryNonce, template: template)
            }
        }
    }

    private func completeFailure(
        entryNonce: UInt64,
        error: any Error
    ) {
        guard var entry = entriesByNonce[entryNonce] else { return }
        entry.isInFlight = false

        guard case .building = entry.phase else {
            emit(.staleCompletionDropped, entry: entry)
            removeEntry(entry)
            return
        }
        guard currentEpoch(for: entry.identity.key.worktree) == entry.identity.epoch,
            currentEntryNonceByIdentity[entry.identity] == entryNonce
        else {
            failWaiters(in: &entry, with: BridgeWorktreeProductConstructionError.invalidated)
            emit(.staleCompletionDropped, entry: entry)
            removeEntry(entry)
            return
        }

        failWaiters(in: &entry, with: error)
        emit(.buildFailed, entry: entry)
        removeEntry(entry)
    }

    private func cancelWaiter(leaseNonce: UInt64) {
        guard let entryNonce = entryNonceByWaiterNonce.removeValue(forKey: leaseNonce),
            var entry = entriesByNonce[entryNonce],
            let waiter = entry.waiters.removeValue(forKey: leaseNonce)
        else { return }

        waiter.continuation.resume(throwing: CancellationError())
        emit(.consumerCancelled, entry: entry, leaseNonce: leaseNonce)
        guard entry.waiters.isEmpty else {
            entriesByNonce[entryNonce] = entry
            return
        }
        if currentEntryNonceByIdentity[entry.identity] == entryNonce {
            currentEntryNonceByIdentity.removeValue(forKey: entry.identity)
        }
        if entry.isInFlight {
            entry.phase = .tombstone
            entriesByNonce[entryNonce] = entry
            emit(.tombstoneCreated, entry: entry)
        } else {
            removeEntry(entry)
        }
    }

    private func failWaiters(in entry: inout BridgeConstructionEntry, with error: any Error) {
        let waiters = entry.waiters.values
        entry.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            entryNonceByWaiterNonce.removeValue(forKey: waiter.leaseNonce)
            waiter.continuation.resume(throwing: error)
        }
    }

    private func makeLease(
        entry: BridgeConstructionEntry,
        leaseNonce: UInt64,
        artifact: BridgeWorktreeProductConstructionArtifact
    ) -> BridgeWorktreeProductConstructionLease {
        BridgeWorktreeProductConstructionLease(
            key: entry.identity.key,
            epoch: entry.identity.epoch,
            entryNonce: entry.nonce,
            leaseNonce: leaseNonce,
            artifact: artifact
        )
    }

    func removeEntry(_ entry: BridgeConstructionEntry) {
        if case .ready(let artifact) = entry.phase {
            artifact.invalidateBacking()
        }
        if currentEntryNonceByIdentity[entry.identity] == entry.nonce {
            currentEntryNonceByIdentity.removeValue(forKey: entry.identity)
        }
        for waiterNonce in entry.waiters.keys {
            entryNonceByWaiterNonce.removeValue(forKey: waiterNonce)
        }
        entriesByNonce.removeValue(forKey: entry.nonce)
        emit(.entryRemoved, entry: entry)
        resumeShutdownWaitersIfDrained()
    }

    private func resumeShutdownWaitersIfDrained() {
        guard isClosed, entriesByNonce.isEmpty, !shutdownWaiters.isEmpty else { return }
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func currentEpoch(for worktree: BridgeWorktreeIdentityKey) -> BridgeWorktreeFreshnessEpoch {
        if let epoch = currentEpochByWorktree[worktree] { return epoch }
        let initialEpoch = BridgeWorktreeFreshnessEpoch(rawValue: 1)
        currentEpochByWorktree[worktree] = initialEpoch
        return initialEpoch
    }

    func takeNextEntryNonce() -> UInt64 {
        let nonce = nextEntryNonce
        nextEntryNonce &+= 1
        return nonce
    }

    func takeNextLeaseNonce() -> UInt64 {
        let nonce = nextLeaseNonce
        nextLeaseNonce &+= 1
        return nonce
    }

    func emit(
        _ kind: BridgeWorktreeProductConstructionEventKind,
        entry: BridgeConstructionEntry,
        leaseNonce: UInt64? = nil
    ) {
        guard let eventSink else { return }
        eventSink(
            BridgeWorktreeProductConstructionEvent(
                kind: kind,
                productKind: entry.identity.key.productKind,
                epoch: entry.identity.epoch,
                entryNonce: entry.nonce,
                leaseNonce: leaseNonce,
                worktreeHash: entry.identity.key.worktree.stableRootIdentity,
                snapshot: kind == .entryRemoved ? snapshot() : snapshot(replacing: entry)
            )
        )
    }
}

extension BridgeWorktreeProductConstructionCoordinator {
    fileprivate func completeFileSuccess(
        entryNonce: UInt64,
        snapshot: BridgeSharedFileSnapshotBuild
    ) {
        guard
            var entry = takeSuccessfulCompletionEntry(
                entryNonce: entryNonce,
                expectedProductKind: .file,
                discardedReviewBacking: nil
            )
        else { return }
        let activeWaiters = activateCompletionWaiters(in: &entry)
        guard !entry.activeLeaseNonces.isEmpty else {
            removeEntry(entry)
            return
        }

        entry.phase = .ready(.fileSnapshot(snapshot))
        entriesByNonce[entryNonce] = entry
        emit(.buildReady, entry: entry)
        for waiter in activeWaiters {
            waiter.continuation.resume(
                returning: makeLease(
                    entry: entry,
                    leaseNonce: waiter.leaseNonce,
                    artifact: .fileSnapshot(snapshot)
                )
            )
        }
    }

    fileprivate func completeReviewSuccess(
        entryNonce: UInt64,
        template: BridgeSharedReviewPackageTemplate
    ) {
        guard
            var entry = takeSuccessfulCompletionEntry(
                entryNonce: entryNonce,
                expectedProductKind: .review,
                discardedReviewBacking: template.backing
            )
        else { return }
        let activeWaiters = activateCompletionWaiters(in: &entry)
        guard !entry.activeLeaseNonces.isEmpty else {
            template.invalidateBacking()
            removeEntry(entry)
            return
        }

        entry.phase = .ready(.reviewTemplate(template))
        entriesByNonce[entryNonce] = entry
        emit(.buildReady, entry: entry)
        for waiter in activeWaiters {
            waiter.continuation.resume(
                returning: makeLease(
                    entry: entry,
                    leaseNonce: waiter.leaseNonce,
                    artifact: .reviewTemplate(template)
                )
            )
        }
    }

    fileprivate func takeSuccessfulCompletionEntry(
        entryNonce: UInt64,
        expectedProductKind: BridgeWorktreeProductKind,
        discardedReviewBacking: BridgeSharedReviewContentBacking?
    ) -> BridgeConstructionEntry? {
        guard var entry = entriesByNonce[entryNonce] else {
            discardedReviewBacking?.invalidate()
            return nil
        }
        entry.isInFlight = false

        guard case .building = entry.phase else {
            discardedReviewBacking?.invalidate()
            emit(.staleCompletionDropped, entry: entry)
            removeEntry(entry)
            return nil
        }

        let identity = entry.identity
        let worktree: BridgeWorktreeIdentityKey
        let productKind: BridgeWorktreeProductKind
        switch identity.key {
        case .file(let key):
            worktree = key.owner.worktree
            productKind = .file
        case .review(let key):
            worktree = key.owner.worktree
            productKind = .review
        }
        guard currentEpoch(for: worktree) == identity.epoch,
            currentEntryNonceByIdentity[identity] == entryNonce
        else {
            discardedReviewBacking?.invalidate()
            failWaiters(in: &entry, with: BridgeWorktreeProductConstructionError.invalidated)
            emit(.staleCompletionDropped, entry: entry)
            removeEntry(entry)
            return nil
        }
        guard productKind == expectedProductKind else {
            discardedReviewBacking?.invalidate()
            failWaiters(in: &entry, with: BridgeWorktreeProductConstructionError.artifactKindMismatch)
            emit(.buildFailed, entry: entry)
            removeEntry(entry)
            return nil
        }

        return entry
    }

    fileprivate func activateCompletionWaiters(
        in entry: inout BridgeConstructionEntry
    ) -> [BridgeConstructionWaiter] {
        let waiters = Array(entry.waiters.values)
        let activeWaiters = waiters.filter { !$0.cancellationState.isCancelled }
        let cancelledWaiters = waiters.filter { $0.cancellationState.isCancelled }
        entry.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            entryNonceByWaiterNonce.removeValue(forKey: waiter.leaseNonce)
        }
        for waiter in cancelledWaiters {
            waiter.continuation.resume(throwing: CancellationError())
            emit(.consumerCancelled, entry: entry, leaseNonce: waiter.leaseNonce)
        }
        for waiter in activeWaiters {
            entry.activeLeaseNonces.insert(waiter.leaseNonce)
        }
        return activeWaiters
    }
}

extension BridgeWorktreeProductConstructionCoordinator {
    func freshnessContext(
        for worktree: BridgeWorktreeIdentityKey
    ) throws -> BridgeWorktreeProductConstructionFreshnessContext {
        try ensureOpen()
        return BridgeWorktreeProductConstructionFreshnessContext(
            worktree: worktree,
            epoch: currentEpoch(for: worktree)
        )
    }
}

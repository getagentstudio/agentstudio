import Foundation

extension BridgeWorktreeProductConstructionCoordinator {
    func acquireProgressiveFile(
        key: BridgeFileConstructionKey,
        build: @escaping BridgeSharedFileSnapshotBuildOperation
    ) async throws -> BridgeSharedFileSnapshotConsumerLease {
        try ensureOpen()
        try Task.checkCancellation()
        let constructionKey = BridgeWorktreeProductConstructionKey.file(key)
        let epoch = currentEpoch(for: key.owner.worktree)
        let identity = BridgeConstructionBuildIdentity(key: constructionKey, epoch: epoch)
        let leaseNonce = takeNextLeaseNonce()

        if let entryNonce = currentEntryNonceByIdentity[identity],
            var entry = entriesByNonce[entryNonce]
        {
            guard entry.mode == .progressiveFile else {
                throw BridgeWorktreeProductConstructionError.acquisitionModeMismatch
            }
            switch entry.phase {
            case .building, .ready:
                entry.activeLeaseNonces.insert(leaseNonce)
                entriesByNonce[entryNonce] = entry
                emit(.consumerJoined, entry: entry, leaseNonce: leaseNonce)
                return makeFileLease(entry: entry, leaseNonce: leaseNonce)
            case .tombstone:
                currentEntryNonceByIdentity.removeValue(forKey: identity)
            }
        }

        let entryNonce = takeNextEntryNonce()
        let entry = BridgeConstructionEntry(
            identity: identity,
            nonce: entryNonce,
            mode: .progressiveFile,
            phase: .building,
            isInFlight: true,
            waiters: [:],
            activeLeaseNonces: [leaseNonce],
            preparedFileLeaseNonces: [],
            progressiveFileState: BridgeProgressiveFileConstructionState(),
            progressiveBuildTask: nil
        )
        entriesByNonce[entryNonce] = entry
        currentEntryNonceByIdentity[identity] = entryNonce
        emit(.buildStarted, entry: entry, leaseNonce: leaseNonce)
        startProgressiveFileBuild(entry: entry, build: build)
        return makeFileLease(entry: entry, leaseNonce: leaseNonce)
    }

    func release(_ lease: BridgeSharedFileSnapshotConsumerLease) {
        guard var entry = entriesByNonce[lease.entryNonce],
            entry.mode == .progressiveFile,
            entry.identity.key == .file(lease.key),
            entry.identity.epoch == lease.epoch,
            entry.activeLeaseNonces.remove(lease.leaseNonce) != nil
        else { return }

        entry.progressiveFileState?.cancelPendingRead(leaseNonce: lease.leaseNonce)
        entry.progressiveFileState?.cancelPendingPreparationRead(leaseNonce: lease.leaseNonce)
        entry.preparedFileLeaseNonces.remove(lease.leaseNonce)
        emit(.leaseReleased, entry: entry, leaseNonce: lease.leaseNonce)
        guard entry.activeLeaseNonces.isEmpty else {
            entriesByNonce[entry.nonce] = entry
            return
        }
        guard case .building = entry.phase, entry.isInFlight else {
            removeEntry(entry)
            return
        }
        if currentEntryNonceByIdentity[entry.identity] == entry.nonce {
            currentEntryNonceByIdentity.removeValue(forKey: entry.identity)
        }
        failFileReadWaiters(in: &entry, with: CancellationError())
        entry.progressiveBuildTask?.cancel()
        entry.progressiveFileState = nil
        entry.phase = .tombstone
        entriesByNonce[entry.nonce] = entry
        emit(.tombstoneCreated, entry: entry)
    }

    func startProgressiveFileBuild(
        entry: BridgeConstructionEntry,
        build: @escaping BridgeSharedFileSnapshotBuildOperation
    ) {
        let context = BridgeWorktreeProductConstructionContext(
            key: entry.identity.key,
            epoch: entry.identity.epoch,
            entryNonce: entry.nonce
        )
        let publisher = BridgeSharedFileSnapshotPublisher(
            preparationSink: { [weak self] preparation in
                guard let self else {
                    throw BridgeWorktreeProductConstructionError.invalidated
                }
                try await self.publishFilePreparation(
                    preparation,
                    entryNonce: entry.nonce
                )
            },
            windowSink: { [weak self] window in
                guard let self else {
                    throw BridgeWorktreeProductConstructionError.invalidated
                }
                try await self.appendFileWindow(window, entryNonce: entry.nonce)
            }
        )
        // Construction must not inherit this coordinator's actor isolation.
        // swiftlint:disable:next no_task_detached
        let task = Task.detached { [weak self] in
            let result: Result<BridgeSharedFileSnapshotCompletion, any Error>
            do {
                result = .success(try await build(context, publisher))
            } catch {
                result = .failure(error)
            }
            await self?.completeProgressiveFile(entryNonce: entry.nonce, result: result)
        }
        guard var currentEntry = entriesByNonce[entry.nonce],
            currentEntry.mode == .progressiveFile
        else {
            task.cancel()
            return
        }
        currentEntry.progressiveBuildTask = task
        entriesByNonce[entry.nonce] = currentEntry
    }

    func publishFilePreparation(
        _ preparation: BridgeSharedFileSnapshotPreparation,
        entryNonce: UInt64
    ) throws {
        guard var entry = currentProgressiveFileBuildingEntry(entryNonce: entryNonce),
            var state = entry.progressiveFileState
        else {
            throw BridgeWorktreeProductConstructionError.invalidated
        }
        let preparedLeaseNonces = try state.publishPreparation(preparation)
        entry.preparedFileLeaseNonces.formUnion(preparedLeaseNonces)
        entry.progressiveFileState = state
        entriesByNonce[entryNonce] = entry
        emit(.filePreparationPublished, entry: entry)
    }

    func appendFileWindow(
        _ window: BridgeSharedFileSnapshotWindow,
        entryNonce: UInt64
    ) throws {
        guard var entry = currentProgressiveFileBuildingEntry(entryNonce: entryNonce),
            var state = entry.progressiveFileState
        else {
            throw BridgeWorktreeProductConstructionError.invalidated
        }
        try state.append(window)
        entry.progressiveFileState = state
        entriesByNonce[entryNonce] = entry
        emit(.fileWindowAppended, entry: entry)
    }

    func enqueueFileSnapshotRead(
        for lease: BridgeSharedFileSnapshotConsumerLease,
        cursor: BridgeSharedFileSnapshotCursor,
        cancellationState: BridgeProgressiveFileConstructionState.ReadCancellationState,
        continuation: CheckedContinuation<BridgeSharedFileSnapshotRead, any Error>
    ) {
        guard var entry = entryForFileLease(lease) else {
            if isInvalidatedFileLease(lease) {
                continuation.resume(
                    throwing: BridgeWorktreeProductConstructionError.invalidated
                )
                return
            }
            continuation.resume(
                throwing: BridgeWorktreeProductConstructionError.invalidFileConsumerLease
            )
            return
        }
        if let error = entry.terminalFileBuildError {
            continuation.resume(throwing: error)
            return
        }
        guard entry.preparedFileLeaseNonces.contains(lease.leaseNonce) else {
            continuation.resume(
                throwing: BridgeWorktreeProductConstructionError.filePreparationReadRequired
            )
            return
        }
        switch entry.phase {
        case .building:
            guard var state = entry.progressiveFileState else {
                continuation.resume(throwing: BridgeWorktreeProductConstructionError.invalidated)
                return
            }
            state.enqueueRead(
                leaseNonce: lease.leaseNonce,
                cursor: cursor,
                cancellationState: cancellationState,
                continuation: continuation
            )
            entry.progressiveFileState = state
            entriesByNonce[entry.nonce] = entry
        case .ready(let artifact):
            guard case .fileSnapshot(let snapshot) = artifact else {
                continuation.resume(
                    throwing: BridgeWorktreeProductConstructionError.artifactKindMismatch
                )
                return
            }
            BridgeProgressiveFileConstructionState.resumeReadyRead(
                snapshot: snapshot,
                cursor: cursor,
                cancellationState: cancellationState,
                continuation: continuation
            )
        case .tombstone:
            continuation.resume(throwing: BridgeWorktreeProductConstructionError.invalidated)
        }
    }

    func enqueueFileSnapshotPreparationRead(
        for lease: BridgeSharedFileSnapshotConsumerLease,
        cancellationState: BridgeProgressiveFileConstructionState.ReadCancellationState,
        continuation: CheckedContinuation<BridgeSharedFileSnapshotPreparation, any Error>
    ) {
        guard var entry = entryForFileLease(lease) else {
            if isInvalidatedFileLease(lease) {
                continuation.resume(throwing: BridgeWorktreeProductConstructionError.invalidated)
            } else {
                continuation.resume(
                    throwing: BridgeWorktreeProductConstructionError.invalidFileConsumerLease
                )
            }
            return
        }
        if let error = entry.terminalFileBuildError {
            continuation.resume(throwing: error)
            return
        }
        switch entry.phase {
        case .building:
            guard var state = entry.progressiveFileState else {
                continuation.resume(throwing: BridgeWorktreeProductConstructionError.invalidated)
                return
            }
            let didReadPreparation = state.enqueuePreparationRead(
                leaseNonce: lease.leaseNonce,
                cancellationState: cancellationState,
                continuation: continuation
            )
            if didReadPreparation {
                entry.preparedFileLeaseNonces.insert(lease.leaseNonce)
            }
            entry.progressiveFileState = state
            entriesByNonce[entry.nonce] = entry
        case .ready(let artifact):
            guard case .fileSnapshot(let snapshot) = artifact else {
                continuation.resume(
                    throwing: BridgeWorktreeProductConstructionError.artifactKindMismatch
                )
                return
            }
            guard !cancellationState.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            entry.preparedFileLeaseNonces.insert(lease.leaseNonce)
            entriesByNonce[entry.nonce] = entry
            continuation.resume(returning: snapshot.preparation)
        case .tombstone:
            continuation.resume(throwing: BridgeWorktreeProductConstructionError.invalidated)
        }
    }

    func completeProgressiveFile(
        entryNonce: UInt64,
        result: Result<BridgeSharedFileSnapshotCompletion, any Error>
    ) {
        guard var entry = entriesByNonce[entryNonce] else { return }
        entry.isInFlight = false
        guard entry.mode == .progressiveFile, case .building = entry.phase else {
            emit(.staleCompletionDropped, entry: entry)
            removeEntry(entry)
            return
        }
        guard !isClosed, !entry.activeLeaseNonces.isEmpty
        else {
            failFileReadWaiters(
                in: &entry,
                with: BridgeWorktreeProductConstructionError.invalidated
            )
            emit(.staleCompletionDropped, entry: entry)
            removeEntry(entry)
            return
        }

        switch result {
        case .failure(let error):
            retainFileBuildFailure(error, in: &entry)
        case .success(let completion):
            guard var state = entry.progressiveFileState else {
                failFileReadWaiters(
                    in: &entry,
                    with: BridgeWorktreeProductConstructionError.invalidated
                )
                removeEntry(entry)
                return
            }
            let snapshot: BridgeSharedFileSnapshotBuild
            do {
                snapshot = try state.makeCompletedSnapshot(completion: completion)
            } catch {
                retainFileBuildFailure(error, in: &entry)
                return
            }
            entry.progressiveFileState = nil
            guard !entry.activeLeaseNonces.isEmpty else {
                state.failPendingReads(with: CancellationError())
                removeEntry(entry)
                return
            }
            entry.phase = .ready(.fileSnapshot(snapshot))
            entriesByNonce[entryNonce] = entry
            emit(.buildReady, entry: entry)
            state.finishPendingReads(with: snapshot)
        }
    }

    private func retainFileBuildFailure(_ error: any Error, in entry: inout BridgeConstructionEntry) {
        failFileReadWaiters(in: &entry, with: error)
        if currentEntryNonceByIdentity[entry.identity] == entry.nonce {
            currentEntryNonceByIdentity.removeValue(forKey: entry.identity)
        }
        // An issued lease retains its build outcome, even between reads. New
        // acquisitions rebuild; release and shutdown retire this existing record.
        entry.progressiveFileState = nil
        entry.preparedFileLeaseNonces.removeAll(keepingCapacity: false)
        entry.progressiveBuildTask = nil
        entry.terminalFileBuildError = error
        entry.phase = .tombstone
        entriesByNonce[entry.nonce] = entry
        emit(.buildFailed, entry: entry)
    }

    func cancelFileReadWaiter(leaseNonce: UInt64) {
        guard
            let entryNonce = entriesByNonce.values.first(where: {
                $0.progressiveFileState?.hasPendingRead(leaseNonce: leaseNonce) == true
            })?.nonce,
            var entry = entriesByNonce[entryNonce],
            var state = entry.progressiveFileState
        else { return }
        state.cancelPendingRead(leaseNonce: leaseNonce)
        entry.progressiveFileState = state
        entriesByNonce[entryNonce] = entry
    }

    func cancelFilePreparationReadWaiter(leaseNonce: UInt64) {
        guard
            let entryNonce = entriesByNonce.values.first(where: {
                $0.progressiveFileState?.hasPendingPreparationRead(leaseNonce: leaseNonce) == true
            })?.nonce,
            var entry = entriesByNonce[entryNonce],
            var state = entry.progressiveFileState
        else { return }
        state.cancelPendingPreparationRead(leaseNonce: leaseNonce)
        entry.progressiveFileState = state
        entriesByNonce[entryNonce] = entry
    }

    func failFileReadWaiters(in entry: inout BridgeConstructionEntry, with error: any Error) {
        guard var state = entry.progressiveFileState else { return }
        state.failPendingReads(with: error)
        entry.progressiveFileState = state
    }

    func currentProgressiveFileBuildingEntry(
        entryNonce: UInt64
    ) -> BridgeConstructionEntry? {
        guard let entry = entriesByNonce[entryNonce],
            entry.mode == .progressiveFile,
            case .building = entry.phase,
            !isClosed,
            !entry.activeLeaseNonces.isEmpty
        else { return nil }
        return entry
    }

    func entryForFileLease(
        _ lease: BridgeSharedFileSnapshotConsumerLease
    ) -> BridgeConstructionEntry? {
        guard let entry = entriesByNonce[lease.entryNonce],
            entry.mode == .progressiveFile,
            entry.identity.key == .file(lease.key),
            entry.identity.epoch == lease.epoch,
            entry.activeLeaseNonces.contains(lease.leaseNonce)
        else { return nil }
        return entry
    }

    func isInvalidatedFileLease(_ lease: BridgeSharedFileSnapshotConsumerLease) -> Bool {
        if lease.epoch != currentEpoch(for: lease.key.owner.worktree) {
            return true
        }
        guard let entry = entriesByNonce[lease.entryNonce],
            entry.mode == .progressiveFile,
            entry.identity.key == .file(lease.key),
            entry.identity.epoch == lease.epoch,
            case .tombstone = entry.phase
        else { return false }
        return true
    }

    func makeFileLease(
        entry: BridgeConstructionEntry,
        leaseNonce: UInt64
    ) -> BridgeSharedFileSnapshotConsumerLease {
        guard case .file(let key) = entry.identity.key else {
            preconditionFailure("Progressive File entry has a non-File construction key")
        }
        return BridgeSharedFileSnapshotConsumerLease(
            key: key,
            epoch: entry.identity.epoch,
            entryNonce: entry.nonce,
            leaseNonce: leaseNonce
        )
    }

}

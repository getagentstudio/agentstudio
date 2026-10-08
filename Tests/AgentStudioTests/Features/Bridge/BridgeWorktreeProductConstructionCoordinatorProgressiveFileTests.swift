import Testing

@testable import AgentStudioBridge

@Suite("Bridge progressive File construction coordinator")
struct BridgeProgressiveFileConstructionCoordinatorTests {
    @Test("a failed File build is retained only by issued leases and new acquisitions rebuild")
    func failedBuildIsNotReusedByNewAcquisition() async throws {
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeProgressiveFileConstructionGate()
        let key = makeBridgeProgressiveFileConstructionKey()
        let firstLease = try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        await gate.waitUntilStarted()
        let secondLease = try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        await gate.fail(BridgeWorktreeFileRootAccessError.missingRoot)
        _ = await eventProbe.waitFor(.buildFailed)
        let failedSnapshot = await coordinator.snapshot()
        #expect(failedSnapshot.entryCount == 1)
        #expect(failedSnapshot.leaseCount == 2)
        #expect(failedSnapshot.inFlightCount == 0)
        #expect(failedSnapshot.retainedArtifactByteCount == 0)

        let rebuiltLease = try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        await gate.waitUntilStarted(count: 2)
        #expect(rebuiltLease.entryNonce != firstLease.entryNonce)
        try await gate.publishPreparation(invocation: 2)
        try await gate.append(makeBridgeSharedFileSnapshotWindow(ordinal: 0, isFinalWindow: true), invocation: 2)
        await gate.succeed(invocation: 2)
        _ = await eventProbe.waitFor(.buildReady)
        _ = try await coordinator.readFileSnapshotPreparation(for: rebuiltLease)
        _ = try await coordinator.nextFileSnapshotRead(for: rebuiltLease, cursor: .init(nextWindowOrdinal: 0))
        await #expect(throws: BridgeWorktreeFileRootAccessError.missingRoot) {
            try await coordinator.readFileSnapshotPreparation(for: firstLease)
        }
        await coordinator.release(firstLease)
        await #expect(throws: BridgeWorktreeProductConstructionError.invalidated) {
            try await coordinator.readFileSnapshotPreparation(for: firstLease)
        }
        await #expect(throws: BridgeWorktreeFileRootAccessError.missingRoot) {
            try await coordinator.readFileSnapshotPreparation(for: secondLease)
        }
        await coordinator.release(secondLease)
        let rebuiltSnapshot = await coordinator.snapshot()
        #expect(rebuiltSnapshot.entryCount == 1)
        #expect(rebuiltSnapshot.leaseCount == 1)
        #expect(rebuiltSnapshot.drainingTombstoneCount == 0)
        await coordinator.release(rebuiltLease)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
        await coordinator.shutdown()
    }

    @Test("late File reads preserve the failed builder's missing-root cause", arguments: [false, true])
    func lateReadsPreserveBuilderFailure(preparationWasRead: Bool) async throws {
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeProgressiveFileConstructionGate()
        let lease = try await coordinator.acquireProgressiveFile(
            key: makeBridgeProgressiveFileConstructionKey(), build: gate.run)
        await gate.waitUntilStarted()
        try await gate.publishPreparation()
        if preparationWasRead {
            _ = try await coordinator.readFileSnapshotPreparation(for: lease)
        }

        await gate.fail(BridgeWorktreeFileRootAccessError.missingRoot)
        _ = await eventProbe.waitFor(.buildFailed)
        do {
            if preparationWasRead {
                _ = try await coordinator.nextFileSnapshotRead(for: lease, cursor: .init(nextWindowOrdinal: 0))
            } else {
                _ = try await coordinator.readFileSnapshotPreparation(for: lease)
            }
            Issue.record("Expected the original missing-root builder failure")
        } catch {
            let failure = BridgeFileSurfaceReconciler.failure(for: error, phase: .build)
            #expect(failure.cause == .missingRoot, "Observed late-read error: \(String(reflecting: error))")
            #expect(failure.refreshFailure.failureKind == .missingRoot)
        }
        await coordinator.release(lease)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
        await #expect(throws: BridgeWorktreeProductConstructionError.invalidFileConsumerLease) {
            try await coordinator.readFileSnapshotPreparation(for: lease)
        }
        await coordinator.shutdown()
    }

    @Test("each lease awaits one shared preparation before reading windows")
    func preparationIsReadOncePerLease() async throws {
        // Arrange
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeProgressiveFileConstructionGate()
        let key = makeBridgeProgressiveFileConstructionKey()
        let firstLeaseTask = Task {
            try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        }
        await gate.waitUntilStarted()
        let firstLease = try await firstLeaseTask.value
        let secondLease = try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        await #expect(throws: BridgeWorktreeProductConstructionError.filePreparationReadRequired) {
            try await coordinator.nextFileSnapshotRead(
                for: firstLease,
                cursor: .init(nextWindowOrdinal: 0)
            )
        }
        let firstPreparationTask = Task {
            try await coordinator.readFileSnapshotPreparation(for: firstLease)
        }
        let secondPreparationTask = Task {
            try await coordinator.readFileSnapshotPreparation(for: secondLease)
        }

        // Act
        try await gate.publishPreparation(retainedByteCount: 48)
        let firstPreparation = try await firstPreparationTask.value
        let secondPreparation = try await secondPreparationTask.value
        let finalWindow = makeBridgeSharedFileSnapshotWindow(ordinal: 0, isFinalWindow: true)
        try await gate.append(finalWindow)
        await gate.succeed()

        // Assert
        #expect(firstPreparation.retainedByteCount == 48)
        #expect(secondPreparation.retainedByteCount == 48)
        let retriedPreparation = try await coordinator.readFileSnapshotPreparation(for: firstLease)
        #expect(retriedPreparation.retainedByteCount == firstPreparation.retainedByteCount)
        let firstWindow = try await coordinator.nextFileSnapshotRead(
            for: firstLease,
            cursor: .init(nextWindowOrdinal: 0)
        )
        #expect(firstWindow.window == finalWindow)
        await coordinator.release(firstLease)
        await coordinator.release(secondLease)
        _ = await eventProbe.waitFor(.entryRemoved)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("late consumer replays retained windows and tails one shared build")
    func lateConsumerReplaysAndTails() async throws {
        // Arrange
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeProgressiveFileConstructionGate()
        let key = makeBridgeProgressiveFileConstructionKey()
        let firstLeaseTask = Task {
            try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        }
        await gate.waitUntilStarted()
        let firstLease = try await firstLeaseTask.value
        try await gate.publishPreparation()
        _ = try await coordinator.readFileSnapshotPreparation(for: firstLease)
        let firstWindow = makeBridgeSharedFileSnapshotWindow(ordinal: 0, isFinalWindow: false)
        try await gate.append(firstWindow)
        let firstRead = try await coordinator.nextFileSnapshotRead(
            for: firstLease,
            cursor: .init(nextWindowOrdinal: 0)
        )

        // Act
        let secondLease = try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        _ = try await coordinator.readFileSnapshotPreparation(for: secondLease)
        let replayedRead = try await coordinator.nextFileSnapshotRead(
            for: secondLease,
            cursor: .init(nextWindowOrdinal: 0)
        )
        let firstTail = Task {
            try await coordinator.nextFileSnapshotRead(
                for: firstLease,
                cursor: .init(nextWindowOrdinal: 1)
            )
        }
        let secondTail = Task {
            try await coordinator.nextFileSnapshotRead(
                for: secondLease,
                cursor: .init(nextWindowOrdinal: 1)
            )
        }
        let finalWindow = makeBridgeSharedFileSnapshotWindow(ordinal: 1, isFinalWindow: true)
        try await gate.append(finalWindow)
        let firstTailRead = try await firstTail.value
        let secondTailRead = try await secondTail.value
        await gate.succeed(retainedNonwindowByteCount: 16)
        _ = await eventProbe.waitFor(.buildReady)
        let lateLease = try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        _ = try await coordinator.readFileSnapshotPreparation(for: lateLease)
        let lateFirstRead = try await coordinator.nextFileSnapshotRead(
            for: lateLease,
            cursor: .init(nextWindowOrdinal: 0)
        )
        let completionRead = try await coordinator.nextFileSnapshotRead(
            for: lateLease,
            cursor: .init(nextWindowOrdinal: 2)
        )

        // Assert
        #expect(firstLease.entryNonce == secondLease.entryNonce)
        #expect(firstLease.leaseNonce != secondLease.leaseNonce)
        #expect(await gate.recordedInvocationCount() == 1)
        #expect(firstRead.window == firstWindow)
        #expect(replayedRead.window == firstWindow)
        #expect(firstTailRead.window == finalWindow)
        #expect(secondTailRead.window == finalWindow)
        #expect(lateFirstRead.window == firstWindow)
        guard case .completed(let snapshot) = completionRead else {
            Issue.record("Expected completed progressive File snapshot")
            return
        }
        #expect(snapshot.orderedWindows == [firstWindow, finalWindow])
        #expect(snapshot.retainedByteCount == 144)
        await coordinator.release(firstLease)
        await coordinator.release(secondLease)
        await coordinator.release(lateLease)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("slow consumer pull does not delay peer or construction")
    func slowConsumerDoesNotDelayPeerOrConstruction() async throws {
        // Arrange
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeProgressiveFileConstructionGate()
        let key = makeBridgeProgressiveFileConstructionKey()
        let slowLeaseTask = Task {
            try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        }
        await gate.waitUntilStarted()
        let slowLease = try await slowLeaseTask.value
        let peerLease = try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        try await gate.publishPreparation()
        _ = try await coordinator.readFileSnapshotPreparation(for: slowLease)
        _ = try await coordinator.readFileSnapshotPreparation(for: peerLease)
        let firstWindow = makeBridgeSharedFileSnapshotWindow(ordinal: 0, isFinalWindow: false)
        let finalWindow = makeBridgeSharedFileSnapshotWindow(ordinal: 1, isFinalWindow: true)
        try await gate.append(firstWindow)
        _ = try await coordinator.nextFileSnapshotRead(
            for: slowLease,
            cursor: .init(nextWindowOrdinal: 0)
        )

        // Act
        try await gate.append(finalWindow)
        await gate.succeed()
        _ = await eventProbe.waitFor(.buildReady)
        let peerFirst = try await coordinator.nextFileSnapshotRead(
            for: peerLease,
            cursor: .init(nextWindowOrdinal: 0)
        )
        let peerFinal = try await coordinator.nextFileSnapshotRead(
            for: peerLease,
            cursor: .init(nextWindowOrdinal: 1)
        )
        let readySnapshot = await coordinator.snapshot()

        // Assert
        #expect(peerFirst.window == firstWindow)
        #expect(peerFinal.window == finalWindow)
        #expect(readySnapshot.leaseCount == 2)
        #expect(readySnapshot.retainedArtifactByteCount == 128)
        await coordinator.release(slowLease)
        await coordinator.release(peerLease)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("progressive publisher enforces preparation contiguous ordinals and one final window")
    func publisherInvariants() async throws {
        // Arrange
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let gate = BridgeProgressiveFileConstructionGate()
        let leaseTask = Task {
            try await coordinator.acquireProgressiveFile(
                key: makeBridgeProgressiveFileConstructionKey(),
                build: gate.run
            )
        }
        await gate.waitUntilStarted()
        let lease = try await leaseTask.value
        let firstWindow = makeBridgeSharedFileSnapshotWindow(ordinal: 0, isFinalWindow: false)

        // Act / Assert
        await #expect(throws: BridgeWorktreeProductConstructionError.preparationRequired) {
            try await gate.append(firstWindow)
        }
        try await gate.publishPreparation()
        _ = try await coordinator.readFileSnapshotPreparation(for: lease)
        await #expect(throws: BridgeWorktreeProductConstructionError.noncontiguousFileWindow) {
            try await gate.append(
                makeBridgeSharedFileSnapshotWindow(ordinal: 1, isFinalWindow: false)
            )
        }
        try await gate.append(firstWindow)
        try await gate.append(makeBridgeSharedFileSnapshotWindow(ordinal: 1, isFinalWindow: true))
        await #expect(throws: BridgeWorktreeProductConstructionError.fileWindowAfterFinal) {
            try await gate.append(
                makeBridgeSharedFileSnapshotWindow(ordinal: 2, isFinalWindow: true)
            )
        }
        await gate.succeed()
        _ = try await coordinator.nextFileSnapshotRead(
            for: lease,
            cursor: .init(nextWindowOrdinal: 2)
        )
        await coordinator.release(lease)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("cancelling one tail read preserves its lease peer and build")
    func tailReadCancellationIsPerConsumer() async throws {
        // Arrange
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeProgressiveFileConstructionGate()
        let key = makeBridgeProgressiveFileConstructionKey()
        let firstLeaseTask = Task {
            try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        }
        await gate.waitUntilStarted()
        let firstLease = try await firstLeaseTask.value
        let peerLease = try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        try await gate.publishPreparation()
        _ = try await coordinator.readFileSnapshotPreparation(for: firstLease)
        _ = try await coordinator.readFileSnapshotPreparation(for: peerLease)
        let cancelledRead = Task {
            try await coordinator.nextFileSnapshotRead(
                for: firstLease,
                cursor: .init(nextWindowOrdinal: 0)
            )
        }
        let peerRead = Task {
            try await coordinator.nextFileSnapshotRead(
                for: peerLease,
                cursor: .init(nextWindowOrdinal: 0)
            )
        }

        // Act
        cancelledRead.cancel()
        let cancelledResult = await cancelledRead.result
        let finalWindow = makeBridgeSharedFileSnapshotWindow(ordinal: 0, isFinalWindow: true)
        try await gate.append(finalWindow)
        let peerResult = try await peerRead.value
        await gate.succeed()

        // Assert
        guard case .failure(let error) = cancelledResult else {
            Issue.record("Cancelled File tail read unexpectedly succeeded")
            return
        }
        #expect(error is CancellationError)
        #expect(peerResult.window == finalWindow)
        let snapshot = await coordinator.snapshot()
        #expect(snapshot.leaseCount == 2)
        await coordinator.release(firstLease)
        await coordinator.release(peerLease)
        _ = await eventProbe.waitFor(.entryRemoved)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("already-observed cancellation wins when an appended window resumes pending reads")
    func observedCancellationWinsAtAppendResume() async throws {
        // Arrange
        let stateHarness = BridgeProgressiveFileConstructionStateHarness()
        try await stateHarness.publishPreparation()
        let cancelledReadState = BridgeProgressiveFileConstructionState.ReadCancellationState()
        let peerReadState = BridgeProgressiveFileConstructionState.ReadCancellationState()
        let cancelledRead = Task {
            try await stateHarness.read(
                leaseNonce: 1,
                cursor: .init(nextWindowOrdinal: 0),
                cancellationState: cancelledReadState
            )
        }
        let peerRead = Task {
            try await stateHarness.read(
                leaseNonce: 2,
                cursor: .init(nextWindowOrdinal: 0),
                cancellationState: peerReadState
            )
        }
        await stateHarness.waitUntilPendingReadCount(2)
        cancelledReadState.cancel()
        let finalWindow = makeBridgeSharedFileSnapshotWindow(ordinal: 0, isFinalWindow: true)

        // Act
        try await stateHarness.append(finalWindow)
        let cancelledResult = await cancelledRead.result
        let peerResult = try await peerRead.value

        // Assert
        guard case .failure(let error) = cancelledResult else {
            Issue.record("Already-cancelled File read unexpectedly received an appended window")
            return
        }
        #expect(error is CancellationError)
        #expect(peerResult.window == finalWindow)
    }

    @Test("already-observed cancellation wins when reading a ready snapshot")
    func observedCancellationWinsAtReadyResume() async {
        // Arrange
        guard case .fileSnapshot(let snapshot) = makeBridgeFileConstructionArtifact() else {
            Issue.record("Expected File snapshot fixture")
            return
        }
        let cancellationState = BridgeProgressiveFileConstructionState.ReadCancellationState()
        cancellationState.cancel()

        // Act / Assert
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                BridgeProgressiveFileConstructionState.resumeReadyRead(
                    snapshot: snapshot,
                    cursor: .init(nextWindowOrdinal: 0),
                    cancellationState: cancellationState,
                    continuation: continuation
                )
            }
        }
    }

    @Test("building and ready accounting include preparation bytes exactly once")
    func preparationByteAccounting() async throws {
        // Arrange
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeProgressiveFileConstructionGate()
        let leaseTask = Task {
            try await coordinator.acquireProgressiveFile(
                key: makeBridgeProgressiveFileConstructionKey(),
                build: gate.run
            )
        }
        await gate.waitUntilStarted()
        let lease = try await leaseTask.value

        // Act
        try await gate.publishPreparation(retainedByteCount: 48)
        let preparationSnapshot = await coordinator.snapshot()
        try await gate.append(
            makeBridgeSharedFileSnapshotWindow(
                ordinal: 0,
                isFinalWindow: true,
                retainedByteCount: 64
            )
        )
        let windowSnapshot = await coordinator.snapshot()
        await gate.succeed(retainedNonwindowByteCount: 16)
        _ = await eventProbe.waitFor(.buildReady)
        let readySnapshot = await coordinator.snapshot()

        // Assert
        #expect(preparationSnapshot.retainedArtifactByteCount == 48)
        #expect(windowSnapshot.retainedArtifactByteCount == 112)
        #expect(readySnapshot.retainedArtifactByteCount == 128)
        await coordinator.release(lease)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("lease retirement after invalidation drops partial windows and stale producer output")
    func invalidationDropsPartialWindowsAndStaleOutput() async throws {
        // Arrange
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeProgressiveFileConstructionGate()
        let key = makeBridgeProgressiveFileConstructionKey()
        let leaseTask = Task {
            try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        }
        await gate.waitUntilStarted()
        let lease = try await leaseTask.value
        try await gate.publishPreparation()
        _ = try await coordinator.readFileSnapshotPreparation(for: lease)
        try await gate.append(
            makeBridgeSharedFileSnapshotWindow(
                ordinal: 0,
                isFinalWindow: false,
                retainedByteCount: 96
            )
        )
        let pendingRead = Task {
            try await coordinator.nextFileSnapshotRead(
                for: lease,
                cursor: .init(nextWindowOrdinal: 1)
            )
        }

        // Act
        let newEpoch = await coordinator.invalidate(worktree: key.owner.worktree)
        // A basis change retires the admitted consumer; ordinary newer input only advances acquisition.
        await coordinator.release(lease)
        let pendingResult = await pendingRead.result
        let invalidatedSnapshot = await coordinator.snapshot()
        await #expect(throws: BridgeWorktreeProductConstructionError.invalidated) {
            try await gate.append(
                makeBridgeSharedFileSnapshotWindow(ordinal: 1, isFinalWindow: true)
            )
        }
        await gate.succeed()
        _ = await eventProbe.waitFor(.staleCompletionDropped)
        await #expect(throws: BridgeWorktreeProductConstructionError.invalidated) {
            try await coordinator.nextFileSnapshotRead(
                for: lease,
                cursor: .init(nextWindowOrdinal: 1)
            )
        }

        // Assert
        guard case .failure(let error) = pendingResult else {
            Issue.record("Invalidated File tail read unexpectedly succeeded")
            return
        }
        #expect(error is CancellationError || error as? BridgeWorktreeProductConstructionError == .invalidated)
        #expect(newEpoch.rawValue == 2)
        #expect(invalidatedSnapshot.retainedArtifactByteCount == 0)
        #expect(invalidatedSnapshot.drainingTombstoneCount == 1)
        await coordinator.release(lease)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("last close drops partial payload and reopen is nonce fenced")
    func lastCloseDropsPayloadAndReopenIsNonceFenced() async throws {
        // Arrange
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeProgressiveFileConstructionGate()
        let key = makeBridgeProgressiveFileConstructionKey()
        let firstLeaseTask = Task {
            try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        }
        await gate.waitUntilStarted()
        let firstLease = try await firstLeaseTask.value
        let peerLease = try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        try await gate.publishPreparation()
        try await gate.append(
            makeBridgeSharedFileSnapshotWindow(
                ordinal: 0,
                isFinalWindow: false,
                retainedByteCount: 80
            )
        )
        let partialSnapshot = await coordinator.snapshot()

        // Act
        await coordinator.release(firstLease)
        let peerSnapshot = await coordinator.snapshot()
        await coordinator.release(peerLease)
        await gate.waitUntilCancelled(invocation: 1)
        let tombstoneSnapshot = await coordinator.snapshot()
        let reopenedLeaseTask = Task {
            try await coordinator.acquireProgressiveFile(key: key, build: gate.run)
        }
        await gate.waitUntilStarted(count: 2)
        let reopenedLease = try await reopenedLeaseTask.value
        try await gate.publishPreparation(invocation: 2)
        _ = try await coordinator.readFileSnapshotPreparation(for: reopenedLease)
        try await gate.append(
            makeBridgeSharedFileSnapshotWindow(ordinal: 0, isFinalWindow: true),
            invocation: 2
        )
        await gate.succeed(invocation: 1)
        _ = await eventProbe.waitFor(.staleCompletionDropped)
        await gate.succeed(invocation: 2)
        _ = try await coordinator.nextFileSnapshotRead(
            for: reopenedLease,
            cursor: .init(nextWindowOrdinal: 1)
        )

        // Assert
        #expect(partialSnapshot.retainedArtifactByteCount == 80)
        #expect(peerSnapshot.leaseCount == 1)
        #expect(peerSnapshot.retainedArtifactByteCount == 80)
        #expect(tombstoneSnapshot.retainedArtifactByteCount == 0)
        #expect(tombstoneSnapshot.drainingTombstoneCount == 1)
        #expect(reopenedLease.entryNonce != firstLease.entryNonce)
        await coordinator.release(reopenedLease)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }
}

extension BridgeSharedFileSnapshotRead {
    fileprivate var window: BridgeSharedFileSnapshotWindow? {
        guard case .window(let window) = self else { return nil }
        return window
    }
}

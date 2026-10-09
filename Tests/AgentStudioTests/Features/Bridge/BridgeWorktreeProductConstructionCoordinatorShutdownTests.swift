import Testing

@testable import AgentStudioBridge

@Suite("Bridge worktree product construction coordinator shutdown")
struct BridgeConstructionShutdownTests {
    @Test("shutdown releases the failed build error even when issued leases remain")
    func shutdownReleasesFailedFileBuild() async throws {
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeProgressiveFileConstructionGate()
        let lease = try await coordinator.acquireProgressiveFile(
            key: makeBridgeProgressiveFileConstructionKey(), build: gate.run)
        await gate.waitUntilStarted()
        await gate.fail(BridgeWorktreeFileRootAccessError.missingRoot)
        _ = await eventProbe.waitFor(.buildFailed)
        #expect(await coordinator.snapshot().leaseCount == 1)
        await coordinator.shutdown()
        await assertBridgeConstructionCoordinatorDrained(coordinator)
        await #expect(throws: BridgeWorktreeProductConstructionError.coordinatorClosed) {
            try await coordinator.readFileSnapshotPreparation(for: lease)
        }
    }

    @Test("closed coordinator rejects completion and progressive acquisitions")
    func closedCoordinatorRejectsAcquisitions() async {
        // Arrange
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        await coordinator.shutdown()

        // Act / Assert
        await #expect(throws: BridgeWorktreeProductConstructionError.coordinatorClosed) {
            try await coordinator.acquire(key: makeBridgeFileConstructionKey()) { _ in
                makeBridgeFileConstructionArtifact()
            }
        }
        await #expect(throws: BridgeWorktreeProductConstructionError.coordinatorClosed) {
            try await coordinator.acquireProgressiveFile(
                key: makeBridgeProgressiveFileConstructionKey()
            ) { _, _ in
                BridgeSharedFileSnapshotCompletion(retainedNonwindowByteCount: 0)
            }
        }
    }

    @Test("shutdown fails pending progressive preparation and window reads")
    func shutdownFailsPendingProgressiveReads() async throws {
        // Arrange
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let preparationGate = BridgeProgressiveFileConstructionGate()
        let windowGate = BridgeProgressiveFileConstructionGate()
        let preparationLease = try await coordinator.acquireProgressiveFile(
            key: makeBridgeProgressiveFileConstructionKey(pathScope: ["Preparation"]),
            build: preparationGate.run
        )
        await preparationGate.waitUntilStarted()
        let pendingPreparation = Task {
            try await coordinator.readFileSnapshotPreparation(for: preparationLease)
        }
        let windowLease = try await coordinator.acquireProgressiveFile(
            key: makeBridgeProgressiveFileConstructionKey(pathScope: ["Window"]),
            build: windowGate.run
        )
        await windowGate.waitUntilStarted()
        try await windowGate.publishPreparation()
        _ = try await coordinator.readFileSnapshotPreparation(for: windowLease)
        let pendingWindow = Task {
            try await coordinator.nextFileSnapshotRead(
                for: windowLease,
                cursor: BridgeSharedFileSnapshotCursor(nextWindowOrdinal: 0)
            )
        }

        // Act
        let shutdown = Task { await coordinator.shutdown() }
        let preparationResult = await pendingPreparation.result
        let windowResult = await pendingWindow.result
        await preparationGate.waitUntilCancelled()
        await windowGate.waitUntilCancelled()

        // Assert
        guard case .failure(let preparationError) = preparationResult,
            case .failure(let windowError) = windowResult
        else {
            Issue.record("Shutdown unexpectedly completed pending progressive reads")
            return
        }
        #expect(
            preparationError as? BridgeWorktreeProductConstructionError == .coordinatorClosed
        )
        #expect(windowError as? BridgeWorktreeProductConstructionError == .coordinatorClosed)
        let drainingSnapshot = await coordinator.snapshot()
        #expect(drainingSnapshot.entryCount == 2)
        #expect(drainingSnapshot.inFlightCount == 2)
        #expect(drainingSnapshot.drainingTombstoneCount == 2)
        #expect(drainingSnapshot.waiterCount == 0)
        #expect(drainingSnapshot.leaseCount == 0)
        #expect(drainingSnapshot.retainedArtifactByteCount == 0)

        await preparationGate.fail(BridgeWorktreeProductConstructionError.coordinatorClosed)
        await windowGate.fail(BridgeWorktreeProductConstructionError.coordinatorClosed)
        await shutdown.value
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("shutdown waits for completion-only physical return before reporting zero residue")
    func shutdownWaitsForCompletionOnlyPhysicalReturn() async throws {
        // Arrange
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let gate = BridgeWorktreeProductConstructionGate(
            artifact: makeBridgeReviewConstructionArtifact()
        )
        let acquisition = Task {
            try await coordinator.acquire(key: makeBridgeReviewConstructionKey(), build: gate.run)
        }
        await gate.waitUntilStarted()

        // Act
        let shutdown = Task { await coordinator.shutdown() }
        let acquisitionResult = await acquisition.result

        // Assert
        guard case .failure(let error) = acquisitionResult else {
            Issue.record("Shutdown unexpectedly published an in-flight completion-only artifact")
            return
        }
        #expect(error as? BridgeWorktreeProductConstructionError == .coordinatorClosed)
        let drainingSnapshot = await coordinator.snapshot()
        #expect(drainingSnapshot.entryCount == 1)
        #expect(drainingSnapshot.inFlightCount == 1)
        #expect(drainingSnapshot.drainingTombstoneCount == 1)
        #expect(drainingSnapshot.waiterCount == 0)
        #expect(drainingSnapshot.payloadCount == 0)
        #expect(drainingSnapshot.retainedArtifactByteCount == 0)

        await gate.release()
        await shutdown.value
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }
}

import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge native capacity trace recorder")
struct BridgeNativeCapacityTraceRecorderTests {
    @Test("construction lifecycle events carry post-transition snapshots")
    func constructionLifecycleEventsCarryPostTransitionSnapshots() async throws {
        // Arrange
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let gate = BridgeWorktreeProductConstructionGate(
            artifact: makeBridgeReviewConstructionArtifact()
        )
        let leaseTask = Task {
            try await coordinator.acquire(
                key: makeBridgeReviewConstructionKey(),
                build: gate.run
            )
        }
        await gate.waitUntilStarted()

        // Act
        await gate.release()
        let lease = try await leaseTask.value
        let readyEvent = await eventProbe.waitFor(.buildReady)
        await coordinator.release(lease)
        let releaseEvent = await eventProbe.waitFor(.leaseReleased)
        let removedEvent = await eventProbe.waitFor(.entryRemoved)

        // Assert
        #expect(readyEvent.snapshot.inFlightCount == 0)
        #expect(readyEvent.snapshot.leaseCount == 1)
        #expect(readyEvent.snapshot.payloadCount == 1)
        #expect(releaseEvent.snapshot.entryCount == 1)
        #expect(releaseEvent.snapshot.leaseCount == 0)
        #expect(releaseEvent.snapshot.payloadCount == 1)
        #expect(removedEvent.snapshot.entryCount == 0)
        #expect(removedEvent.snapshot.leaseCount == 0)
        #expect(removedEvent.snapshot.payloadCount == 0)
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("scheduler events map to bounded taxonomy and capacity facts")
    func schedulerEventsMapToBoundedCapacityFacts() throws {
        // Arrange
        let snapshot = BridgeGitReadSchedulerSnapshot(
            lifecycle: .active,
            queuedCountByOperationClass: [.reviewMetadata: 3],
            runningCountByOperationClass: [.reviewMetadata: 1],
            drainingCountByOperationClass: [.reviewMetadata: 1],
            activeOperationIds: [7, 8],
            occupiedSlotIds: [BridgeGitReadSlotID(token: "review-metadata-interactive")],
            logicalWaiterCount: 4,
            coalescedLogicalWaiterCount: 2,
            scheduledDeadlineCount: 4,
            admittedWorktreeKeys: [BridgeGitReadWorktreeKey(token: "0123456789abcdef")],
            paneActivityCount: 2,
            fairnessHistoryCount: 3
        )
        let event = BridgeGitReadSchedulerEvent(
            kind: .started,
            operationId: 7,
            slotId: BridgeGitReadSlotID(token: "review-metadata-interactive"),
            operationClass: .reviewMetadata,
            worktreeKey: BridgeGitReadWorktreeKey(token: "0123456789abcdef"),
            activityRank: .foreground,
            queueWait: .milliseconds(12),
            snapshot: snapshot
        )

        // Act
        let sample = BridgeNativeCapacityTraceRecorder.schedulerSample(for: event)

        // Assert
        #expect(sample.event == .bridgeGitReadScheduler)
        #expect(sample.duration == .milliseconds(12))
        #expect(sample.attributes["agentstudio.bridge.phase"] == .string("git_read_scheduler"))
        #expect(sample.attributes["agentstudio.bridge.plane"] == .string("data"))
        #expect(sample.attributes["agentstudio.bridge.priority"] == .string("hot"))
        #expect(sample.attributes["agentstudio.bridge.slice"] == .string("review_metadata"))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.event"] == .string("started"))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.operation_class"] == .string("review_metadata"))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.activity_rank"] == .string("foreground"))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.worktree_hash"] == .string("0123456789abcdef"))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.queued.count"] == .int(3))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.running.count"] == .int(1))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.draining.count"] == .int(1))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.occupied_slot.count"] == .int(1))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.logical_waiter.count"] == .int(4))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.coalesced_waiter.count"] == .int(2))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.operation_id"] == nil)
        #expect(sample.attributes["agentstudio.bridge.native_capacity.slot"] == nil)
    }

    @Test("construction events map to attributable bounded accounting")
    func constructionEventsMapToBoundedAccounting() {
        // Arrange
        let event = BridgeWorktreeProductConstructionEvent(
            kind: .buildReady,
            productKind: .review,
            epoch: BridgeWorktreeFreshnessEpoch(rawValue: 4),
            entryNonce: 9,
            leaseNonce: 10,
            worktreeHash: "fedcba9876543210",
            snapshot: BridgeWorktreeProductConstructionSnapshot(
                entryCount: 2,
                waiterCount: 1,
                leaseCount: 2,
                payloadCount: 1,
                inFlightCount: 0,
                locatorCount: 6,
                drainingTombstoneCount: 0,
                retainedArtifactByteCount: 4096
            )
        )

        // Act
        let sample = BridgeNativeCapacityTraceRecorder.constructionSample(for: event)

        // Assert
        #expect(sample.event == .bridgeWorktreeProductConstruction)
        #expect(sample.duration == nil)
        #expect(sample.attributes["agentstudio.bridge.phase"] == .string("worktree_product_construction"))
        #expect(sample.attributes["agentstudio.bridge.plane"] == .string("data"))
        #expect(sample.attributes["agentstudio.bridge.priority"] == .string("best_effort"))
        #expect(sample.attributes["agentstudio.bridge.slice"] == .string("review_metadata"))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.event"] == .string("build_ready"))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.product_kind"] == .string("review"))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.worktree_hash"] == .string("fedcba9876543210"))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.entry.count"] == .int(2))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.waiter.count"] == .int(1))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.lease.count"] == .int(2))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.payload.count"] == .int(1))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.in_flight.count"] == .int(0))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.locator.count"] == .int(6))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.tombstone.count"] == .int(0))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.retained_artifact_byte.count"] == .int(4096))
        #expect(sample.attributes["agentstudio.bridge.native_capacity.entry_nonce"] == nil)
        #expect(sample.attributes["agentstudio.bridge.native_capacity.lease_nonce"] == nil)
    }

    @Test("OTLP projection retains every recorded attribute and keeps bounded capacity facts")
    func projectionRetainsEveryRecordedAttributeAndBoundedCapacityFacts() {
        // Arrange
        let record = AgentStudioTraceRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.bridge.git_read_scheduler",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [:],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("git_read_scheduler"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.slice": .string("review_metadata"),
                "agentstudio.bridge.native_capacity.event": .string("started"),
                "agentstudio.bridge.native_capacity.operation_class": .string("review_metadata"),
                "agentstudio.bridge.native_capacity.activity_rank": .string("foreground"),
                "agentstudio.bridge.native_capacity.worktree_hash": .string("0123456789abcdef"),
                "agentstudio.bridge.native_capacity.running.count": .int(1),
                "agentstudio.bridge.native_capacity.operation_id": .int(42),
                "agentstudio.bridge.native_capacity.repository_path": .string("/private/repository"),
            ]
        )

        // Act
        let projected = AgentStudioOTLPTraceProjection.project(record)
        let metricEvent = AgentStudioOTLPPerformanceMetricEvent(record: projected)

        // Assert
        #expect(projected.attributes["agentstudio.bridge.native_capacity.event"] == .string("started"))
        #expect(
            projected.attributes["agentstudio.bridge.native_capacity.operation_class"]
                == .string("review_metadata")
        )
        #expect(projected.attributes["agentstudio.bridge.native_capacity.activity_rank"] == .string("foreground"))
        #expect(projected.attributes["agentstudio.bridge.native_capacity.worktree_hash"] == .string("0123456789abcdef"))
        #expect(projected.attributes["agentstudio.bridge.native_capacity.running.count"] == .int(1))
        #expect(projected.attributes["agentstudio.bridge.native_capacity.operation_id"] == .int(42))
        #expect(
            projected.attributes["agentstudio.bridge.native_capacity.repository_path"] == .string("/private/repository")
        )
        #expect(metricEvent?.eventName == "performance.bridge.git_read_scheduler")
        #expect(metricEvent?.elapsedMilliseconds == nil)
    }
}

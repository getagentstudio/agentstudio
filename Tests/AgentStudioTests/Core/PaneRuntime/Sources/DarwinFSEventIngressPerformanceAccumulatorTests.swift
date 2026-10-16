import Testing

@testable import AgentStudioCore

@Suite("Darwin FSEvent ingress performance attribution")
struct DarwinFSEventIngressPerformanceAccumulatorTests {
    @Test("snapshot atomically returns and resets every fixed attribution counter")
    func snapshotReturnsAndResetsFixedCounters() {
        let accumulator = DarwinFSEventIngressPerformanceAccumulator()

        accumulator.recordLocalRawCallback(eventCount: 3)
        accumulator.recordSharedRawCallback(eventCount: 5)
        accumulator.recordSharedFanout(
            exactSubscriberCount: 7,
            uncertaintySubscriberCount: 11,
            fullRefreshEmissionCount: 13
        )
        accumulator.recordSharedAncestorCandidate(count: 41)
        accumulator.recordSharedAncestorRecheck(
            disposition: .equalResolved,
            count: 43,
            itemReadCount: 47,
            byteReadCount: 53
        )
        accumulator.recordSharedAncestorRecheck(disposition: .changed, count: 59)
        accumulator.recordSharedAncestorRecheck(disposition: .missingBaseline, count: 61)
        accumulator.recordSharedAncestorRecheck(disposition: .unsupported, count: 67)
        accumulator.recordSharedAncestorRecheck(disposition: .policyBoundExhausted, count: 71)
        accumulator.recordSharedAncestorRecheck(disposition: .unstable, count: 73)
        accumulator.recordSharedAncestorRecheck(disposition: .raced, count: 79)
        accumulator.recordSharedAncestorRecheck(disposition: .staleGeneration, count: 83)
        accumulator.recordSharedAncestorRecheck(disposition: .failClosed, count: 89)
        accumulator.updateSharedAncestorOccupancy(
            activeRecheckCount: 1,
            unresolvedRegistrationCount: 97,
            unresolvedItemCount: 101,
            latestPendingEpoch: 103
        )
        accumulator.recordIngress(source: .local, disposition: .accepted, pathCount: 17)
        accumulator.recordIngress(source: .sharedExact, disposition: .dropped, pathCount: 19)
        accumulator.recordIngress(source: .sharedUncertainty, disposition: .terminated, pathCount: 23)
        accumulator.recordOverflowDrain(
            recoveryCount: 29,
            retainedPathCount: 31,
            coarseRecoveryCount: 37
        )

        let snapshot = accumulator.snapshotAndReset()

        #expect(snapshot.localRawCallbackBatchCount == 1)
        #expect(snapshot.localRawCallbackEventCount == 3)
        #expect(snapshot.sharedRawCallbackBatchCount == 1)
        #expect(snapshot.sharedRawCallbackEventCount == 5)
        #expect(snapshot.sharedExactSubscriberCount == 7)
        #expect(snapshot.sharedUncertaintySubscriberCount == 11)
        #expect(snapshot.sharedFullRefreshEmissionCount == 13)
        #expect(snapshot.sharedAncestorCandidateCount == 41)
        #expect(snapshot.sharedAncestorEqualResolvedCount == 43)
        #expect(snapshot.sharedAncestorChangedCount == 59)
        #expect(snapshot.sharedAncestorMissingBaselineCount == 61)
        #expect(snapshot.sharedAncestorUnsupportedCount == 67)
        #expect(snapshot.sharedAncestorPolicyBoundExhaustedCount == 71)
        #expect(snapshot.sharedAncestorUnstableCount == 73)
        #expect(snapshot.sharedAncestorRacedCount == 79)
        #expect(snapshot.sharedAncestorStaleGenerationCount == 83)
        #expect(snapshot.sharedAncestorFailClosedCount == 89)
        #expect(snapshot.sharedAncestorActiveRecheckCount == 1)
        #expect(snapshot.sharedAncestorUnresolvedRegistrationCount == 97)
        #expect(snapshot.sharedAncestorUnresolvedItemCount == 101)
        #expect(snapshot.sharedAncestorLatestPendingEpoch == 103)
        #expect(snapshot.sharedAncestorItemReadCount == 47)
        #expect(snapshot.sharedAncestorByteReadCount == 53)
        #expect(snapshot.localIngress.acceptedBatchCount == 1)
        #expect(snapshot.localIngress.acceptedPathCount == 17)
        #expect(snapshot.sharedExactIngress.droppedBatchCount == 1)
        #expect(snapshot.sharedExactIngress.droppedPathCount == 19)
        #expect(snapshot.sharedUncertaintyIngress.terminatedBatchCount == 1)
        #expect(snapshot.sharedUncertaintyIngress.terminatedPathCount == 23)
        #expect(snapshot.overflowDrainCount == 1)
        #expect(snapshot.overflowRecoveryCount == 29)
        #expect(snapshot.overflowRetainedPathCount == 31)
        #expect(snapshot.overflowCoarseRecoveryCount == 37)
        #expect(accumulator.snapshotAndReset() == .zero)
    }

    @Test("trace projection contains only the fixed numeric attribution allowlist")
    func traceProjectionContainsOnlyFixedNumericAttributes() {
        let accumulator = DarwinFSEventIngressPerformanceAccumulator()
        accumulator.recordLocalRawCallback(eventCount: 2)
        accumulator.recordIngress(source: .local, disposition: .accepted, pathCount: 2)

        let attributes = accumulator.snapshotAndReset().traceAttributes

        #expect(attributes["agentstudio.performance.filesystem.ingress.local_raw_callback.batch.count"] == .int(1))
        #expect(attributes["agentstudio.performance.filesystem.ingress.local_raw_callback.event.count"] == .int(2))
        #expect(attributes["agentstudio.performance.filesystem.ingress.local.accepted.batch.count"] == .int(1))
        #expect(attributes["agentstudio.performance.filesystem.ingress.local.accepted.path.count"] == .int(2))
        #expect(
            attributes[
                "agentstudio.performance.filesystem.ingress.shared_ancestor.equal_resolved.count"
            ] == .int(0)
        )
        let expectedKeys: Set<String> = [
            "agentstudio.performance.filesystem.ingress.local_raw_callback.batch.count",
            "agentstudio.performance.filesystem.ingress.local_raw_callback.event.count",
            "agentstudio.performance.filesystem.ingress.shared_raw_callback.batch.count",
            "agentstudio.performance.filesystem.ingress.shared_raw_callback.event.count",
            "agentstudio.performance.filesystem.ingress.shared_exact_subscriber.count",
            "agentstudio.performance.filesystem.ingress.shared_uncertainty_subscriber.count",
            "agentstudio.performance.filesystem.ingress.shared_full_refresh_emission.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.candidate.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.equal_resolved.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.changed.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.missing_baseline.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.unsupported.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.policy_bound_exhausted.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.unstable.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.raced.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.stale_generation.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.fail_closed.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.active_recheck.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.unresolved_registration.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.unresolved_item.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.latest_pending_epoch",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.item_read.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.byte_read.count",
            "agentstudio.performance.filesystem.ingress.overflow.drain.count",
            "agentstudio.performance.filesystem.ingress.overflow.recovery.count",
            "agentstudio.performance.filesystem.ingress.overflow.retained_path.count",
            "agentstudio.performance.filesystem.ingress.overflow.coarse_recovery.count",
            "agentstudio.performance.filesystem.ingress.local.accepted.batch.count",
            "agentstudio.performance.filesystem.ingress.local.accepted.path.count",
            "agentstudio.performance.filesystem.ingress.local.dropped.batch.count",
            "agentstudio.performance.filesystem.ingress.local.dropped.path.count",
            "agentstudio.performance.filesystem.ingress.local.terminated.batch.count",
            "agentstudio.performance.filesystem.ingress.local.terminated.path.count",
            "agentstudio.performance.filesystem.ingress.shared_exact.accepted.batch.count",
            "agentstudio.performance.filesystem.ingress.shared_exact.accepted.path.count",
            "agentstudio.performance.filesystem.ingress.shared_exact.dropped.batch.count",
            "agentstudio.performance.filesystem.ingress.shared_exact.dropped.path.count",
            "agentstudio.performance.filesystem.ingress.shared_exact.terminated.batch.count",
            "agentstudio.performance.filesystem.ingress.shared_exact.terminated.path.count",
            "agentstudio.performance.filesystem.ingress.shared_uncertainty.accepted.batch.count",
            "agentstudio.performance.filesystem.ingress.shared_uncertainty.accepted.path.count",
            "agentstudio.performance.filesystem.ingress.shared_uncertainty.dropped.batch.count",
            "agentstudio.performance.filesystem.ingress.shared_uncertainty.dropped.path.count",
            "agentstudio.performance.filesystem.ingress.shared_uncertainty.terminated.batch.count",
            "agentstudio.performance.filesystem.ingress.shared_uncertainty.terminated.path.count",
        ]
        #expect(Set(attributes.keys) == expectedKeys)
        #expect(attributes.keys.allSatisfy { $0.hasPrefix("agentstudio.performance.filesystem.ingress.") })
        #expect(
            attributes.values.allSatisfy { value in
                if case .int = value { return true }
                return false
            })
    }
}

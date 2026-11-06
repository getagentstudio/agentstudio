import AgentStudioInfrastructure
import Foundation

package enum DarwinFSEventIngressSource: Sendable {
    case local
    case sharedExact
    case sharedUncertainty
}

package enum DarwinFSEventIngressDisposition: Sendable {
    case accepted
    case dropped
    case terminated
}

package enum DarwinSharedAncestorRecheckDisposition: Sendable {
    case equalResolved
    case changed
    case missingBaseline
    case unsupported
    case policyBoundExhausted
    case unstable
    case raced
    case staleGeneration
    case failClosed
}

package struct DarwinFSEventIngressDispositionSnapshot: Equatable, Sendable {
    package let acceptedBatchCount: Int
    package let acceptedPathCount: Int
    package let droppedBatchCount: Int
    package let droppedPathCount: Int
    package let terminatedBatchCount: Int
    package let terminatedPathCount: Int

    package static let zero = Self(
        acceptedBatchCount: 0,
        acceptedPathCount: 0,
        droppedBatchCount: 0,
        droppedPathCount: 0,
        terminatedBatchCount: 0,
        terminatedPathCount: 0
    )
}

package struct DarwinFSEventIngressPerformanceSnapshot: Equatable, Sendable {
    package let localRawCallbackBatchCount: Int
    package let localRawCallbackEventCount: Int
    package let sharedRawCallbackBatchCount: Int
    package let sharedRawCallbackEventCount: Int
    package let sharedExactSubscriberCount: Int
    package let sharedUncertaintySubscriberCount: Int
    package let sharedFullRefreshEmissionCount: Int
    package let sharedAncestorCandidateCount: Int
    package let sharedAncestorEqualResolvedCount: Int
    package let sharedAncestorChangedCount: Int
    package let sharedAncestorMissingBaselineCount: Int
    package let sharedAncestorUnsupportedCount: Int
    package let sharedAncestorPolicyBoundExhaustedCount: Int
    package let sharedAncestorUnstableCount: Int
    package let sharedAncestorRacedCount: Int
    package let sharedAncestorStaleGenerationCount: Int
    package let sharedAncestorFailClosedCount: Int
    package let sharedAncestorActiveRecheckCount: Int
    package let sharedAncestorUnresolvedRegistrationCount: Int
    package let sharedAncestorUnresolvedItemCount: Int
    package let sharedAncestorLatestPendingEpoch: Int
    package let sharedAncestorItemReadCount: Int
    package let sharedAncestorByteReadCount: Int
    package let localIngress: DarwinFSEventIngressDispositionSnapshot
    package let sharedExactIngress: DarwinFSEventIngressDispositionSnapshot
    package let sharedUncertaintyIngress: DarwinFSEventIngressDispositionSnapshot
    package let overflowDrainCount: Int
    package let overflowRecoveryCount: Int
    package let overflowRetainedPathCount: Int
    package let overflowCoarseRecoveryCount: Int
    package let watchedFolderFilterSeenPathCount: Int
    package let watchedFolderFilterDroppedPathCount: Int
    package let watchedFolderFilterKeptPathCount: Int
    package let watchedFolderFilterDroppedBatchCount: Int

    package static let zero = Self(
        localRawCallbackBatchCount: 0,
        localRawCallbackEventCount: 0,
        sharedRawCallbackBatchCount: 0,
        sharedRawCallbackEventCount: 0,
        sharedExactSubscriberCount: 0,
        sharedUncertaintySubscriberCount: 0,
        sharedFullRefreshEmissionCount: 0,
        sharedAncestorCandidateCount: 0,
        sharedAncestorEqualResolvedCount: 0,
        sharedAncestorChangedCount: 0,
        sharedAncestorMissingBaselineCount: 0,
        sharedAncestorUnsupportedCount: 0,
        sharedAncestorPolicyBoundExhaustedCount: 0,
        sharedAncestorUnstableCount: 0,
        sharedAncestorRacedCount: 0,
        sharedAncestorStaleGenerationCount: 0,
        sharedAncestorFailClosedCount: 0,
        sharedAncestorActiveRecheckCount: 0,
        sharedAncestorUnresolvedRegistrationCount: 0,
        sharedAncestorUnresolvedItemCount: 0,
        sharedAncestorLatestPendingEpoch: 0,
        sharedAncestorItemReadCount: 0,
        sharedAncestorByteReadCount: 0,
        localIngress: .zero,
        sharedExactIngress: .zero,
        sharedUncertaintyIngress: .zero,
        overflowDrainCount: 0,
        overflowRecoveryCount: 0,
        overflowRetainedPathCount: 0,
        overflowCoarseRecoveryCount: 0,
        watchedFolderFilterSeenPathCount: 0,
        watchedFolderFilterDroppedPathCount: 0,
        watchedFolderFilterKeptPathCount: 0,
        watchedFolderFilterDroppedBatchCount: 0
    )

    package var traceAttributes: [String: AgentStudioTraceValue] {
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.filesystem.ingress.watched_folder_filter.seen.path.count": .int(
                watchedFolderFilterSeenPathCount),
            "agentstudio.performance.filesystem.ingress.watched_folder_filter.dropped.path.count": .int(
                watchedFolderFilterDroppedPathCount),
            "agentstudio.performance.filesystem.ingress.watched_folder_filter.kept.path.count": .int(
                watchedFolderFilterKeptPathCount),
            "agentstudio.performance.filesystem.ingress.watched_folder_filter.dropped.batch.count": .int(
                watchedFolderFilterDroppedBatchCount),
            "agentstudio.performance.filesystem.ingress.watched_folder_filter.registration_kind": .string(
                "watched_folder"),
            "agentstudio.performance.filesystem.ingress.local_raw_callback.batch.count": .int(
                localRawCallbackBatchCount
            ),
            "agentstudio.performance.filesystem.ingress.local_raw_callback.event.count": .int(
                localRawCallbackEventCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_raw_callback.batch.count": .int(
                sharedRawCallbackBatchCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_raw_callback.event.count": .int(
                sharedRawCallbackEventCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_exact_subscriber.count": .int(
                sharedExactSubscriberCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_uncertainty_subscriber.count": .int(
                sharedUncertaintySubscriberCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_full_refresh_emission.count": .int(
                sharedFullRefreshEmissionCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.candidate.count": .int(
                sharedAncestorCandidateCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.equal_resolved.count": .int(
                sharedAncestorEqualResolvedCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.changed.count": .int(
                sharedAncestorChangedCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.missing_baseline.count": .int(
                sharedAncestorMissingBaselineCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.unsupported.count": .int(
                sharedAncestorUnsupportedCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.policy_bound_exhausted.count": .int(
                sharedAncestorPolicyBoundExhaustedCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.unstable.count": .int(
                sharedAncestorUnstableCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.raced.count": .int(
                sharedAncestorRacedCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.stale_generation.count": .int(
                sharedAncestorStaleGenerationCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.fail_closed.count": .int(
                sharedAncestorFailClosedCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.active_recheck.count": .int(
                sharedAncestorActiveRecheckCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.unresolved_registration.count": .int(
                sharedAncestorUnresolvedRegistrationCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.unresolved_item.count": .int(
                sharedAncestorUnresolvedItemCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.latest_pending_epoch": .int(
                sharedAncestorLatestPendingEpoch
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.item_read.count": .int(
                sharedAncestorItemReadCount
            ),
            "agentstudio.performance.filesystem.ingress.shared_ancestor.byte_read.count": .int(
                sharedAncestorByteReadCount
            ),
            "agentstudio.performance.filesystem.ingress.overflow.drain.count": .int(overflowDrainCount),
            "agentstudio.performance.filesystem.ingress.overflow.recovery.count": .int(
                overflowRecoveryCount
            ),
            "agentstudio.performance.filesystem.ingress.overflow.retained_path.count": .int(
                overflowRetainedPathCount
            ),
            "agentstudio.performance.filesystem.ingress.overflow.coarse_recovery.count": .int(
                overflowCoarseRecoveryCount
            ),
        ]
        Self.appendIngressAttributes(localIngress, source: "local", to: &attributes)
        Self.appendIngressAttributes(sharedExactIngress, source: "shared_exact", to: &attributes)
        Self.appendIngressAttributes(
            sharedUncertaintyIngress,
            source: "shared_uncertainty",
            to: &attributes
        )
        return attributes
    }

    private static func appendIngressAttributes(
        _ snapshot: DarwinFSEventIngressDispositionSnapshot,
        source: String,
        to attributes: inout [String: AgentStudioTraceValue]
    ) {
        let prefix = "agentstudio.performance.filesystem.ingress.\(source)"
        attributes["\(prefix).accepted.batch.count"] = .int(snapshot.acceptedBatchCount)
        attributes["\(prefix).accepted.path.count"] = .int(snapshot.acceptedPathCount)
        attributes["\(prefix).dropped.batch.count"] = .int(snapshot.droppedBatchCount)
        attributes["\(prefix).dropped.path.count"] = .int(snapshot.droppedPathCount)
        attributes["\(prefix).terminated.batch.count"] = .int(snapshot.terminatedBatchCount)
        attributes["\(prefix).terminated.path.count"] = .int(snapshot.terminatedPathCount)
    }
}

package final class DarwinFSEventIngressPerformanceAccumulator: @unchecked Sendable {
    private struct MutableDispositionCounters {
        var acceptedBatchCount = 0
        var acceptedPathCount = 0
        var droppedBatchCount = 0
        var droppedPathCount = 0
        var terminatedBatchCount = 0
        var terminatedPathCount = 0

        mutating func record(_ disposition: DarwinFSEventIngressDisposition, pathCount: Int) {
            switch disposition {
            case .accepted:
                acceptedBatchCount += 1
                acceptedPathCount += pathCount
            case .dropped:
                droppedBatchCount += 1
                droppedPathCount += pathCount
            case .terminated:
                terminatedBatchCount += 1
                terminatedPathCount += pathCount
            }
        }

        var snapshot: DarwinFSEventIngressDispositionSnapshot {
            DarwinFSEventIngressDispositionSnapshot(
                acceptedBatchCount: acceptedBatchCount,
                acceptedPathCount: acceptedPathCount,
                droppedBatchCount: droppedBatchCount,
                droppedPathCount: droppedPathCount,
                terminatedBatchCount: terminatedBatchCount,
                terminatedPathCount: terminatedPathCount
            )
        }
    }

    private struct MutableCounters {
        var localRawCallbackBatchCount = 0
        var localRawCallbackEventCount = 0
        var sharedRawCallbackBatchCount = 0
        var sharedRawCallbackEventCount = 0
        var sharedExactSubscriberCount = 0
        var sharedUncertaintySubscriberCount = 0
        var sharedFullRefreshEmissionCount = 0
        var sharedAncestorCandidateCount = 0
        var sharedAncestorEqualResolvedCount = 0
        var sharedAncestorChangedCount = 0
        var sharedAncestorMissingBaselineCount = 0
        var sharedAncestorUnsupportedCount = 0
        var sharedAncestorPolicyBoundExhaustedCount = 0
        var sharedAncestorUnstableCount = 0
        var sharedAncestorRacedCount = 0
        var sharedAncestorStaleGenerationCount = 0
        var sharedAncestorFailClosedCount = 0
        var sharedAncestorActiveRecheckCount = 0
        var sharedAncestorUnresolvedRegistrationCount = 0
        var sharedAncestorUnresolvedItemCount = 0
        var sharedAncestorLatestPendingEpoch = 0
        var sharedAncestorItemReadCount = 0
        var sharedAncestorByteReadCount = 0
        var localIngress = MutableDispositionCounters()
        var sharedExactIngress = MutableDispositionCounters()
        var sharedUncertaintyIngress = MutableDispositionCounters()
        var overflowDrainCount = 0
        var overflowRecoveryCount = 0
        var overflowRetainedPathCount = 0
        var overflowCoarseRecoveryCount = 0
        var watchedFolderFilterSeenPathCount = 0
        var watchedFolderFilterDroppedPathCount = 0
        var watchedFolderFilterKeptPathCount = 0
        var watchedFolderFilterDroppedBatchCount = 0

        var snapshot: DarwinFSEventIngressPerformanceSnapshot {
            DarwinFSEventIngressPerformanceSnapshot(
                localRawCallbackBatchCount: localRawCallbackBatchCount,
                localRawCallbackEventCount: localRawCallbackEventCount,
                sharedRawCallbackBatchCount: sharedRawCallbackBatchCount,
                sharedRawCallbackEventCount: sharedRawCallbackEventCount,
                sharedExactSubscriberCount: sharedExactSubscriberCount,
                sharedUncertaintySubscriberCount: sharedUncertaintySubscriberCount,
                sharedFullRefreshEmissionCount: sharedFullRefreshEmissionCount,
                sharedAncestorCandidateCount: sharedAncestorCandidateCount,
                sharedAncestorEqualResolvedCount: sharedAncestorEqualResolvedCount,
                sharedAncestorChangedCount: sharedAncestorChangedCount,
                sharedAncestorMissingBaselineCount: sharedAncestorMissingBaselineCount,
                sharedAncestorUnsupportedCount: sharedAncestorUnsupportedCount,
                sharedAncestorPolicyBoundExhaustedCount: sharedAncestorPolicyBoundExhaustedCount,
                sharedAncestorUnstableCount: sharedAncestorUnstableCount,
                sharedAncestorRacedCount: sharedAncestorRacedCount,
                sharedAncestorStaleGenerationCount: sharedAncestorStaleGenerationCount,
                sharedAncestorFailClosedCount: sharedAncestorFailClosedCount,
                sharedAncestorActiveRecheckCount: sharedAncestorActiveRecheckCount,
                sharedAncestorUnresolvedRegistrationCount:
                    sharedAncestorUnresolvedRegistrationCount,
                sharedAncestorUnresolvedItemCount: sharedAncestorUnresolvedItemCount,
                sharedAncestorLatestPendingEpoch: sharedAncestorLatestPendingEpoch,
                sharedAncestorItemReadCount: sharedAncestorItemReadCount,
                sharedAncestorByteReadCount: sharedAncestorByteReadCount,
                localIngress: localIngress.snapshot,
                sharedExactIngress: sharedExactIngress.snapshot,
                sharedUncertaintyIngress: sharedUncertaintyIngress.snapshot,
                overflowDrainCount: overflowDrainCount,
                overflowRecoveryCount: overflowRecoveryCount,
                overflowRetainedPathCount: overflowRetainedPathCount,
                overflowCoarseRecoveryCount: overflowCoarseRecoveryCount,
                watchedFolderFilterSeenPathCount: watchedFolderFilterSeenPathCount,
                watchedFolderFilterDroppedPathCount: watchedFolderFilterDroppedPathCount,
                watchedFolderFilterKeptPathCount: watchedFolderFilterKeptPathCount,
                watchedFolderFilterDroppedBatchCount: watchedFolderFilterDroppedBatchCount
            )
        }
    }

    private let lock = NSLock()
    private var counters = MutableCounters()

    package func recordWatchedFolderFilter(_ batch: FSEventBatch, admittedBatch: FSEventBatch?) {
        lock.withLock {
            let keptPathCount = admittedBatch?.paths.count ?? 0
            counters.watchedFolderFilterSeenPathCount += batch.paths.count
            counters.watchedFolderFilterDroppedPathCount += batch.paths.count - keptPathCount
            counters.watchedFolderFilterKeptPathCount += keptPathCount
            if admittedBatch == nil { counters.watchedFolderFilterDroppedBatchCount += 1 }
        }
    }

    package func recordLocalRawCallback(eventCount: Int) {
        lock.withLock {
            counters.localRawCallbackBatchCount += 1
            counters.localRawCallbackEventCount += eventCount
        }
    }

    package func recordSharedRawCallback(eventCount: Int) {
        lock.withLock {
            counters.sharedRawCallbackBatchCount += 1
            counters.sharedRawCallbackEventCount += eventCount
        }
    }

    package func recordSharedFanout(
        exactSubscriberCount: Int,
        uncertaintySubscriberCount: Int,
        fullRefreshEmissionCount: Int
    ) {
        lock.withLock {
            counters.sharedExactSubscriberCount += exactSubscriberCount
            counters.sharedUncertaintySubscriberCount += uncertaintySubscriberCount
            counters.sharedFullRefreshEmissionCount += fullRefreshEmissionCount
        }
    }

    package func recordSharedAncestorCandidate(count: Int) {
        lock.withLock {
            counters.sharedAncestorCandidateCount += count
        }
    }

    package func recordSharedAncestorRecheck(
        disposition: DarwinSharedAncestorRecheckDisposition,
        count: Int = 1,
        itemReadCount: Int = 0,
        byteReadCount: Int = 0
    ) {
        lock.withLock {
            switch disposition {
            case .equalResolved: counters.sharedAncestorEqualResolvedCount += count
            case .changed: counters.sharedAncestorChangedCount += count
            case .missingBaseline: counters.sharedAncestorMissingBaselineCount += count
            case .unsupported: counters.sharedAncestorUnsupportedCount += count
            case .policyBoundExhausted:
                counters.sharedAncestorPolicyBoundExhaustedCount += count
            case .unstable: counters.sharedAncestorUnstableCount += count
            case .raced: counters.sharedAncestorRacedCount += count
            case .staleGeneration: counters.sharedAncestorStaleGenerationCount += count
            case .failClosed: counters.sharedAncestorFailClosedCount += count
            }
            counters.sharedAncestorItemReadCount += itemReadCount
            counters.sharedAncestorByteReadCount += byteReadCount
        }
    }

    package func updateSharedAncestorOccupancy(
        activeRecheckCount: Int,
        unresolvedRegistrationCount: Int,
        unresolvedItemCount: Int,
        latestPendingEpoch: UInt64
    ) {
        lock.withLock {
            counters.sharedAncestorActiveRecheckCount = activeRecheckCount
            counters.sharedAncestorUnresolvedRegistrationCount = unresolvedRegistrationCount
            counters.sharedAncestorUnresolvedItemCount = unresolvedItemCount
            counters.sharedAncestorLatestPendingEpoch = Int(
                min(latestPendingEpoch, UInt64(Int.max))
            )
        }
    }

    package func recordIngress(
        source: DarwinFSEventIngressSource,
        disposition: DarwinFSEventIngressDisposition,
        pathCount: Int
    ) {
        lock.withLock {
            switch source {
            case .local: counters.localIngress.record(disposition, pathCount: pathCount)
            case .sharedExact: counters.sharedExactIngress.record(disposition, pathCount: pathCount)
            case .sharedUncertainty:
                counters.sharedUncertaintyIngress.record(disposition, pathCount: pathCount)
            }
        }
    }

    package func recordOverflowDrain(
        recoveryCount: Int,
        retainedPathCount: Int,
        coarseRecoveryCount: Int
    ) {
        lock.withLock {
            counters.overflowDrainCount += 1
            counters.overflowRecoveryCount += recoveryCount
            counters.overflowRetainedPathCount += retainedPathCount
            counters.overflowCoarseRecoveryCount += coarseRecoveryCount
        }
    }

    package func snapshotAndReset() -> DarwinFSEventIngressPerformanceSnapshot {
        lock.withLock {
            let snapshot = counters.snapshot
            counters = MutableCounters()
            return snapshot
        }
    }
}

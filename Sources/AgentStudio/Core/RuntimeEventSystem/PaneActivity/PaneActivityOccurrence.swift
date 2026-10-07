import Foundation

package enum PaneActivitySource: String, Sendable, Equatable {
    case terminal
    case hook
}

package struct PaneActivityOccurrence: Sendable, Equatable {
    package let paneId: UUID
    package let source: PaneActivitySource
    package let orderingInstant: ContinuousClock.Instant
    package let wallTime: Date

    package init(
        paneId: UUID,
        source: PaneActivitySource,
        orderingInstant: ContinuousClock.Instant,
        wallTime: Date
    ) {
        self.paneId = paneId
        self.source = source
        self.orderingInstant = orderingInstant
        self.wallTime = wallTime
    }

    package var activityTime: PaneActivityTime {
        PaneActivityTime(
            orderingInstant: orderingInstant,
            wallTime: wallTime,
            source: source
        )
    }
}

package struct PaneActivityTime: Sendable, Equatable {
    package let orderingInstant: ContinuousClock.Instant
    package let wallTime: Date
    package let source: PaneActivitySource

    package init(
        orderingInstant: ContinuousClock.Instant,
        wallTime: Date,
        source: PaneActivitySource
    ) {
        self.orderingInstant = orderingInstant
        self.wallTime = wallTime
        self.source = source
    }
}

package enum PaneActivityTimeMutation: Sendable, Equatable {
    case set(UUID, PaneActivityTime)
    case remove(UUID)
}

/// Durable wall-time projection; the process-local ordering instant is never stored.
package struct PaneActivityRecord: Sendable, Equatable {
    package let paneId: UUID
    package let wallTime: Date
    package let source: PaneActivitySource

    package init(paneId: UUID, wallTime: Date, source: PaneActivitySource) {
        self.paneId = paneId
        self.wallTime = wallTime
        self.source = source
    }

    package func restoredActivityTime(
        referenceInstant: ContinuousClock.Instant,
        wallNow: Date
    ) -> PaneActivityTime? {
        guard canRestore(relativeTo: wallNow) else { return nil }
        let age = max(0, wallNow.timeIntervalSince(wallTime))
        return PaneActivityTime(
            orderingInstant: referenceInstant.advanced(by: .seconds(-age)),
            wallTime: wallTime,
            source: source
        )
    }

    package func canRestore(relativeTo wallNow: Date) -> Bool {
        let timestamp = wallTime.timeIntervalSince1970
        let elapsedSeconds = wallNow.timeIntervalSince(wallTime)
        guard timestamp.isFinite, elapsedSeconds.isFinite else { return false }
        // This is a representability margin, not an activity horizon policy:
        // leave half the Int64-seconds component range for later monotonic aging.
        // Direct Double conversion rounds Int64.max / 2 upward, so nextDown is
        // the greatest representable value within that integer bound. This also
        // keeps Duration.seconds' Int128 attosecond scaling safely in range.
        let maximumMagnitudeSeconds = Double(Int64.max / 2).nextDown
        return abs(timestamp) <= maximumMagnitudeSeconds
            && abs(elapsedSeconds) <= maximumMagnitudeSeconds
    }
}

package struct PaneActivityCommit: Sendable, Equatable {
    package let mutations: [PaneActivityTimeMutation]

    package init(mutations: [PaneActivityTimeMutation]) {
        self.mutations = mutations
    }
}

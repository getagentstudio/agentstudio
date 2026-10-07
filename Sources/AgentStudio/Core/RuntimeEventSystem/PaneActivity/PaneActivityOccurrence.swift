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
        // Duration.seconds(Double) scales whole seconds into signed 128-bit
        // attoseconds; the sidebar's Duration.components converts back to Int64
        // seconds. Exact Int64 conversion is the narrower representable bound
        // and also guarantees that scaling by 1e18 cannot overflow Int128.
        return Int64(exactly: timestamp.rounded(.towardZero)) != nil
            && Int64(exactly: max(0, elapsedSeconds).rounded(.towardZero)) != nil
    }
}

package struct PaneActivityCommit: Sendable, Equatable {
    package let mutations: [PaneActivityTimeMutation]

    package init(mutations: [PaneActivityTimeMutation]) {
        self.mutations = mutations
    }
}

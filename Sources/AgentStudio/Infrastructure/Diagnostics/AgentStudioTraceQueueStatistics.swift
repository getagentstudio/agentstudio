import Foundation
import Metrics
import Synchronization

// One owner per trace runtime, shared by its value copies. Queues report current
// occupancy and cumulative loss; retired queues leave their loss in the total.
final class AgentStudioTraceQueueStatistics: Sendable {
    struct QueueID: Hashable, Sendable {
        fileprivate let rawValue: UUID
    }

    struct QueueSnapshot: Sendable {
        var droppedRecordCount = 0
        var pendingRequestCount = 0
        var backlog = 0
    }

    struct Snapshot: Equatable, Sendable {
        var droppedRecordCount = 0
        var pendingRequestCount = 0
        var highWaterMark = 0
    }

    struct Gauges: Sendable {
        let droppedRecords: Gauge
        let pendingRequests: Gauge
        let highWaterMark: Gauge

        init(factory: any MetricsFactory) {
            droppedRecords = Gauge(label: "agentstudio_performance_trace_queue_dropped_record_count", factory: factory)
            pendingRequests = Gauge(
                label: "agentstudio_performance_trace_queue_pending_request_count", factory: factory)
            highWaterMark = Gauge(label: "agentstudio_performance_trace_queue_high_watermark", factory: factory)
        }

        func record(_ snapshot: Snapshot) {
            droppedRecords.record(snapshot.droppedRecordCount)
            pendingRequests.record(snapshot.pendingRequestCount)
            highWaterMark.record(snapshot.highWaterMark)
        }
    }

    private struct State: Sendable {
        var queues: [QueueID: QueueSnapshot] = [:]
        var totals = Snapshot()
        var combinedBacklog = 0
        var gauges: Gauges?

        mutating func publish() {
            totals.highWaterMark = max(totals.highWaterMark, combinedBacklog)
            // Record under the same lock as the totals so concurrent reports can
            // never publish an older value after a newer one.
            gauges?.record(totals)
        }
    }

    private let state = Mutex(State())

    func register() -> QueueID {
        let queueID = QueueID(rawValue: UUIDv7.generate())
        state.withLock { state in
            state.queues[queueID] = QueueSnapshot()
        }
        return queueID
    }

    func report(_ queueID: QueueID, snapshot: QueueSnapshot) {
        state.withLock { state in
            guard let previous = state.queues[queueID] else { return }
            precondition(snapshot.droppedRecordCount >= previous.droppedRecordCount)
            precondition(snapshot.pendingRequestCount >= 0 && snapshot.backlog >= 0)
            state.totals.droppedRecordCount += snapshot.droppedRecordCount - previous.droppedRecordCount
            state.totals.pendingRequestCount += snapshot.pendingRequestCount - previous.pendingRequestCount
            state.combinedBacklog += snapshot.backlog - previous.backlog
            state.queues[queueID] = snapshot
            state.publish()
        }
    }

    func retire(_ queueID: QueueID) {
        state.withLock { state in
            guard let previous = state.queues.removeValue(forKey: queueID) else { return }
            state.totals.pendingRequestCount -= previous.pendingRequestCount
            state.combinedBacklog -= previous.backlog
            state.publish()
        }
    }

    func attach(gauges: Gauges) {
        state.withLock { state in
            precondition(state.gauges == nil)
            state.gauges = gauges
            state.publish()
        }
    }

    func detach() {
        state.withLock { state in
            // The provider retains the instruments for its final shutdown export.
            // Only our reporting attachment ends; cumulative totals stay alive.
            state.gauges = nil
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { $0.totals }
    }

    var hasAttachedGauges: Bool {
        state.withLock { $0.gauges != nil }
    }
}

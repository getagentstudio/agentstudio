import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPCommonQuiescenceProjectionTests {
    @Test
    func commonQuiescenceProjectionKeepsAggregateDebtAndRetainsUnsafeContext() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/RuntimeDeliveryPerformanceReporter.swift:38: delivery snapshot emits only counts, never payload text.
        let privateWorktreeID = UUID(uuidString: "6DE2BC87-AD1F-4271-96DD-7922D58612D5")!
        let record = AgentStudioTraceRecord(
            timeUnixNano: 602,
            severityText: .info,
            body: "performance.runtime_delivery.snapshot",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.filesystem.pending_worktree.count": .int(9),
                "agentstudio.performance.filesystem.drain_task.count": .int(8),
                "agentstudio.performance.filesystem.watched_folder.ready.count": .int(7),
                "agentstudio.performance.filesystem.watched_folder.active.count": .int(6),
                "agentstudio.performance.filesystem.watched_folder.dirty_follow_up.count": .int(2),
                "agentstudio.performance.filesystem.logical_debt.count": .int(1),
                "agentstudio.performance.git.logical_pending.count": .int(4),
                "agentstudio.performance.git.retry_pending.count": .int(3),
                "agentstudio.performance.git.logical_running.count": .int(2),
                "agentstudio.performance.git.logical_debt.count": .int(1),
                "agentstudio.performance.git.future_automatic.count": .int(86),
                "agentstudio.performance.git.future_failure.count": .int(1),
                "agentstudio.performance.git.ready_pending.count": .int(0),
                "agentstudio.performance.git.capacity_pending.count": .int(0),
                "agentstudio.performance.git.active_follow_up.count": .int(1),
                "agentstudio.performance.git.unclassified_pending.count": .int(0),
                "agentstudio.performance.git.overdue_deadline.count": .int(0),
                "agentstudio.performance.git.oldest_preparation_ms": .double(120),
                "agentstudio.performance.git.next_deadline_ms": .double(1000),
                "agentstudio.performance.runtime_delivery.runtime_channel_outbound_pending.count": .int(8),
                "agentstudio.performance.runtime_delivery.eventbus_active_delivery_debt.count": .int(7),
                "agentstudio.performance.runtime_delivery.total_pending.count": .int(6),
                "agentstudio.performance.runtime_delivery.runtime_channel_outbound_dropped.count": .int(5),
                "agentstudio.performance.runtime_delivery.runtime_channel_retired_undelivered.count": .int(4),
                "agentstudio.performance.runtime_delivery.eventbus_live_dropped.count": .int(3),
                "agentstudio.performance.runtime_delivery.eventbus_replay_dropped.count": .int(2),
                "agentstudio.performance.runtime_delivery.eventbus_retired_undelivered.count": .int(1),
                "agentstudio.performance.runtime_delivery.eventbus_active_subscriber.count": .int(4),
                "agentstudio.performance.filesystem.root_path": .string("/Users/private/watched-root"),
                "agentstudio.performance.git.worktree_id": .string(privateWorktreeID.uuidString),
                "agentstudio.performance.runtime_delivery.subscriber_name": .string("private-subscriber"),
                "agentstudio.performance.runtime_delivery.payload": .string("private-payload"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.body == "performance.runtime_delivery.snapshot")
        #expect(projection.attributes["agentstudio.performance.filesystem.pending_worktree.count"] == .int(9))
        #expect(projection.attributes["agentstudio.performance.filesystem.drain_task.count"] == .int(8))
        #expect(projection.attributes["agentstudio.performance.filesystem.watched_folder.ready.count"] == .int(7))
        #expect(projection.attributes["agentstudio.performance.filesystem.watched_folder.active.count"] == .int(6))
        #expect(
            projection.attributes["agentstudio.performance.filesystem.watched_folder.dirty_follow_up.count"] == .int(2))
        #expect(projection.attributes["agentstudio.performance.filesystem.logical_debt.count"] == .int(1))
        #expect(projection.attributes["agentstudio.performance.git.logical_pending.count"] == .int(4))
        #expect(projection.attributes["agentstudio.performance.git.retry_pending.count"] == .int(3))
        #expect(projection.attributes["agentstudio.performance.git.logical_running.count"] == .int(2))
        #expect(projection.attributes["agentstudio.performance.git.logical_debt.count"] == .int(1))
        #expect(projection.attributes["agentstudio.performance.git.future_automatic.count"] == .int(86))
        #expect(projection.attributes["agentstudio.performance.git.future_failure.count"] == .int(1))
        #expect(projection.attributes["agentstudio.performance.git.ready_pending.count"] == .int(0))
        #expect(projection.attributes["agentstudio.performance.git.capacity_pending.count"] == .int(0))
        #expect(projection.attributes["agentstudio.performance.git.active_follow_up.count"] == .int(1))
        #expect(projection.attributes["agentstudio.performance.git.unclassified_pending.count"] == .int(0))
        #expect(projection.attributes["agentstudio.performance.git.overdue_deadline.count"] == .int(0))
        #expect(projection.attributes["agentstudio.performance.git.oldest_preparation_ms"] == .double(120))
        #expect(projection.attributes["agentstudio.performance.git.next_deadline_ms"] == .double(1000))
        #expect(
            projection.attributes["agentstudio.performance.runtime_delivery.runtime_channel_outbound_pending.count"]
                == .int(8))
        #expect(
            projection.attributes["agentstudio.performance.runtime_delivery.eventbus_active_delivery_debt.count"]
                == .int(7))
        #expect(projection.attributes["agentstudio.performance.runtime_delivery.total_pending.count"] == .int(6))
        #expect(
            projection.attributes["agentstudio.performance.runtime_delivery.runtime_channel_outbound_dropped.count"]
                == .int(5))
        #expect(
            projection.attributes[
                "agentstudio.performance.runtime_delivery.runtime_channel_retired_undelivered.count"] == .int(4))
        #expect(
            projection.attributes["agentstudio.performance.runtime_delivery.eventbus_live_dropped.count"] == .int(3))
        #expect(
            projection.attributes["agentstudio.performance.runtime_delivery.eventbus_replay_dropped.count"] == .int(2))
        #expect(
            projection.attributes["agentstudio.performance.runtime_delivery.eventbus_retired_undelivered.count"]
                == .int(1))
        #expect(
            projection.attributes["agentstudio.performance.runtime_delivery.eventbus_active_subscriber.count"]
                == .int(4))
        #expect(projection.attributes["agentstudio.performance.filesystem.root_path"] != nil)
        #expect(projection.attributes["agentstudio.performance.git.worktree_id"] != nil)
        #expect(projection.attributes["agentstudio.performance.runtime_delivery.subscriber_name"] != nil)
        #expect(projection.attributes["agentstudio.performance.runtime_delivery.payload"] != nil)
    }
}

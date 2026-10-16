import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPApplyProbeProjectionTests {
    @Test("Sessions status apply exports every numeric probe field and scrubs private fields")
    func sessionsStatusApplyKeepsOnlyAllowlistedProbeAttributes() {
        let projection = AgentStudioOTLPTraceProjection.project(
            AgentStudioTraceRecord(
                timeUnixNano: 123,
                severityText: .info,
                body: AgentStudioPerformanceTraceRecorder.Event.sessionsStatusApply.rawValue,
                traceID: nil, spanID: nil, parentSpanID: nil, resource: [:],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.performance.elapsed_ms": .double(0.2),
                    "agentstudio.sessions.computed_count": .int(11),
                    "agentstudio.sessions.equal_suppressed_count": .int(5),
                    "agentstudio.sessions.coalesced_count": .int(3),
                    "agentstudio.sessions.batch_size": .int(2),
                    "agentstudio.sessions.main_actor_total_ms": .double(0.6),
                    "agentstudio.sessions.main_actor_max_ms": .double(0.3),
                    "agentstudio.sessions.unregistered_count": .int(17),
                    "agentstudio.sessions.pane_id": .string("PRIVATE-PANE"),
                    "agentstudio.sessions.path": .string("/private/probe"),
                    "agentstudio.sessions.text": .string("PRIVATE-SESSION"),
                ]))

        #expect(projection.body == "sessions.status_apply")
        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(0.2))
        #expect(projection.attributes["agentstudio.sessions.computed_count"] == .int(11))
        #expect(projection.attributes["agentstudio.sessions.equal_suppressed_count"] == .int(5))
        #expect(projection.attributes["agentstudio.sessions.coalesced_count"] == .int(3))
        #expect(projection.attributes["agentstudio.sessions.batch_size"] == .int(2))
        #expect(projection.attributes["agentstudio.sessions.main_actor_total_ms"] == .double(0.6))
        #expect(projection.attributes["agentstudio.sessions.main_actor_max_ms"] == .double(0.3))
        #expect(projection.attributes["agentstudio.sessions.unregistered_count"] == nil)
        #expect(projection.attributes["agentstudio.sessions.pane_id"] == nil)
        #expect(projection.attributes["agentstudio.sessions.path"] == nil)
        #expect(projection.attributes["agentstudio.sessions.text"] == nil)
    }

    @Test("PaneContext presentation apply exports every numeric probe field and scrubs private fields")
    func paneContextPresentationApplyKeepsOnlyAllowlistedProbeAttributes() {
        let projection = AgentStudioOTLPTraceProjection.project(
            AgentStudioTraceRecord(
                timeUnixNano: 124,
                severityText: .info,
                body: AgentStudioPerformanceTraceRecorder.Event.paneContextPresentationApply.rawValue,
                traceID: nil, spanID: nil, parentSpanID: nil, resource: [:],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.performance.elapsed_ms": .double(0.4),
                    "agentstudio.pane_context.computed_count": .int(19),
                    "agentstudio.pane_context.equal_suppressed_count": .int(7),
                    "agentstudio.pane_context.coalesced_count": .int(5),
                    "agentstudio.pane_context.batch_size": .int(4),
                    "agentstudio.pane_context.main_actor_total_ms": .double(0.9),
                    "agentstudio.pane_context.main_actor_max_ms": .double(0.5),
                    "agentstudio.pane_context.unregistered_count": .int(23),
                    "agentstudio.pane_context.pane_id": .string("PRIVATE-PANE"),
                    "agentstudio.pane_context.path": .string("/private/probe"),
                    "agentstudio.pane_context.text": .string("PRIVATE-PRESENTATION"),
                ]))

        #expect(projection.body == "pane_context.presentation_apply")
        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(0.4))
        #expect(projection.attributes["agentstudio.pane_context.computed_count"] == .int(19))
        #expect(projection.attributes["agentstudio.pane_context.equal_suppressed_count"] == .int(7))
        #expect(projection.attributes["agentstudio.pane_context.coalesced_count"] == .int(5))
        #expect(projection.attributes["agentstudio.pane_context.batch_size"] == .int(4))
        #expect(projection.attributes["agentstudio.pane_context.main_actor_total_ms"] == .double(0.9))
        #expect(projection.attributes["agentstudio.pane_context.main_actor_max_ms"] == .double(0.5))
        #expect(projection.attributes["agentstudio.pane_context.unregistered_count"] == nil)
        #expect(projection.attributes["agentstudio.pane_context.pane_id"] == nil)
        #expect(projection.attributes["agentstudio.pane_context.path"] == nil)
        #expect(projection.attributes["agentstudio.pane_context.text"] == nil)
    }
}

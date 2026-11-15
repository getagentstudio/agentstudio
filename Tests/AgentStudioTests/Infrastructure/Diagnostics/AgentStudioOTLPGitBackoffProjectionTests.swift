import Foundation
import Testing

@testable import AgentStudioInfrastructure

/// Git status-backoff telemetry projection, split from the main OTLP
/// projection suite to keep that struct under the type-body cap.
@Suite
struct AgentStudioOTLPGitBackoffProjectionTests {
    @Test
    func gitBackoffTelemetryProjectsThroughAllowlist() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+TraceAttributes.swift:7: git status emits attribution/counts, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 200,
            severityText: .info,
            body: "performance.git.backoff",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.git.backoff_open": .bool(true),
                "agentstudio.performance.git.backoff_ms": .double(500),
                "agentstudio.performance.git.backoff_attempt.count": .int(3),
                "agentstudio.performance.git.backoff.reason": .string("timeout"),
                "agentstudio.performance.git.root_path": .string("/Users/shravan/private/repo"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.body == "performance.git.backoff")
        #expect(projection.attributes["agentstudio.performance.git.backoff_open"] == .bool(true))
        #expect(projection.attributes["agentstudio.performance.git.backoff_ms"] == .double(500))
        #expect(projection.attributes["agentstudio.performance.git.backoff_attempt.count"] == .int(3))
        #expect(projection.attributes["agentstudio.performance.git.backoff.reason"] == .string("timeout"))
        #expect(projection.attributes["agentstudio.performance.git.root_path"] != nil)
    }

    @Test
    func gitStatusScopeTelemetryProjectsThroughAllowlist() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+TraceAttributes.swift:7: git status emits attribution/counts, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 300,
            severityText: .info,
            body: "performance.git.status",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.git.status_scope": .string("pathspec"),
                "agentstudio.performance.git.pathspec.count": .int(3),
                "agentstudio.performance.git.root_path": .string("/Users/shravan/private/repo"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.body == "performance.git.status")
        #expect(projection.attributes["agentstudio.performance.git.status_scope"] == .string("pathspec"))
        #expect(projection.attributes["agentstudio.performance.git.pathspec.count"] == .int(3))
        #expect(projection.attributes["agentstudio.performance.git.root_path"] != nil)
    }
}

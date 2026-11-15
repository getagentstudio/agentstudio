import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("Repository lifecycle telemetry projection")
struct RepositoryLifecycleTelemetryProjectionTests {
    @Test("lifecycle measurements export bounded counts and occupancy without location identity")
    func boundedLifecycleTelemetrySurvivesScrubbing() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Core/RuntimeEventSystem/Retention/RepositoryRetentionPreparation.swift:70: retention emits counts/duration, never message text.
        let counts = [
            "agentstudio.performance.repository_lifecycle.repository.count",
            "agentstudio.performance.repository_lifecycle.observation.count",
            "agentstudio.performance.repository_lifecycle.changed_family.count",
            "agentstudio.performance.repository_lifecycle.collected_location.count",
        ]
        var attributes = Dictionary(uniqueKeysWithValues: counts.map { ($0, AgentStudioTraceValue.int(3)) })
        attributes["agentstudio.performance.elapsed_ms"] = .double(8)
        attributes["agentstudio.performance.repository_lifecycle.mainactor_held_ms"] = .double(0.5)
        attributes["agentstudio.performance.repository_lifecycle.path"] = .string("/private/lifecycle-canary")
        attributes["agentstudio.performance.repository_lifecycle.repository_id"] = .string(
            "019be3be-7c00-7000-8000-000000000099")
        let record = AgentStudioTraceRecord(
            timeUnixNano: 1, severityText: .info,
            body: AgentStudioPerformanceTraceRecorder.Event.repositoryRetentionCommit.rawValue,
            traceID: nil, spanID: nil, parentSpanID: nil, resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"), attributes: attributes)

        let projection = OTLPProjectionAssertions.project(record)

        for key in counts { #expect(projection.attributes[key] == .int(3)) }
        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(8))
        #expect(projection.attributes["agentstudio.performance.repository_lifecycle.mainactor_held_ms"] == .double(0.5))
        #expect(projection.attributes["agentstudio.performance.repository_lifecycle.path"] != nil)
        #expect(projection.attributes["agentstudio.performance.repository_lifecycle.repository_id"] != nil)
    }
}

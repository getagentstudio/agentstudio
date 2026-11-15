import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("Pane association OTLP projection")
struct AgentStudioPaneAssociationOTLPTests {
    @Test("pane association boot reconciliation exports recorded aggregate counts")
    func paneAssociationBootReconciliationExportsRecordedCounts() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:565: association emits typed outcome/counts, never message text.
        let countAttributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.pane.association_boot.pane.count": .int(5),
            "agentstudio.performance.pane.association_boot.retained_known.count": .int(2),
            "agentstudio.performance.pane.association_boot.backfilled.count": .int(1),
            "agentstudio.performance.pane.association_boot.dangling_cleared.count": .int(1),
            "agentstudio.performance.pane.association_boot.free_nil.count": .int(1),
            "agentstudio.performance.pane.association_boot.changed.count": .int(2),
        ]
        var inputAttributes = countAttributes
        inputAttributes["agentstudio.pane.id"] = .string("019be3be-7c00-7000-8000-000000000099")
        inputAttributes["agentstudio.performance.pane.cwd_path"] = .string("/private/worktree")
        let record = AgentStudioTraceRecord(
            timeUnixNano: 87,
            severityText: .info,
            body: "performance.pane.association_boot_reconciliation",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: inputAttributes
        )

        let projection = OTLPProjectionAssertions.project(record)

        for (attributeName, expectedValue) in countAttributes {
            #expect(projection.attributes[attributeName] == expectedValue)
        }
        #expect(projection.attributes["agentstudio.pane.id"] != nil)
        #expect(projection.attributes["agentstudio.performance.pane.cwd_path"] != nil)
    }

    @Test("pane association runtime proof exports its recorded boolean verdicts")
    func paneAssociationRuntimeProofExportsRecordedBooleans() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:565: association emits typed outcome/counts, never message text.
        let proofKeys = [
            "agentstudio.startup_diagnostic.association.initial_succeeded",
            "agentstudio.startup_diagnostic.association.cwd_move_succeeded",
            "agentstudio.startup_diagnostic.association.topology_clear_succeeded",
            "agentstudio.startup_diagnostic.association.topology_residency_preserved",
            "agentstudio.startup_diagnostic.association.topology_adopt_succeeded",
            "agentstudio.startup_diagnostic.association.free_pane_remained_nil",
            "agentstudio.startup_diagnostic.association_proof.succeeded",
        ]
        let record = AgentStudioTraceRecord(
            timeUnixNano: 88,
            severityText: .info,
            body: "app.startup_diagnostic_action.completed",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: Dictionary(uniqueKeysWithValues: proofKeys.map { ($0, .bool(true)) })
        )

        let projection = OTLPProjectionAssertions.project(record)

        var expectedAttributes: [String: AgentStudioTraceValue] = Dictionary(
            uniqueKeysWithValues: proofKeys.map { ($0, AgentStudioTraceValue.bool(true)) }
        )
        expectedAttributes["agentstudio.event.time_unix_nano"] = .int(88)
        #expect(projection.attributes == expectedAttributes)
    }

    @Test("pane association outcome becomes an exact controlled metric dimension")
    func paneAssociationOutcomeBecomesControlledMetricDimension() throws {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:565: association emits typed outcome/counts, never message text.
        let validRecord = projectedRecord(outcome: "topology_removed", timeUnixNano: 119)
        let invalidRecord = projectedRecord(outcome: "retry_scheduled", timeUnixNano: 120)

        let validMetricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: validRecord))
        let invalidMetricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: invalidRecord))

        #expect(
            validMetricEvent.dimensions == [
                .init(name: "event", value: "performance.pane.association"),
                .init(name: "association_outcome", value: "topology_removed"),
            ]
        )
        #expect(
            invalidMetricEvent.dimensions == [
                .init(name: "event", value: "performance.pane.association")
            ]
        )
    }

    @Test("pane association projection and metrics keep only exact controlled outcomes")
    func paneAssociationProjectionKeepsControlledOutcomeOnly() throws {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:565: association emits typed outcome/counts, never message text.
        let controlledOutcomes = [
            "stamped_known", "resolved_changed", "resolved_equal", "cleared_no_match",
            "topology_removed", "deferred_uncertain", "free_nil",
        ]

        for outcome in controlledOutcomes {
            let projection = OTLPProjectionAssertions.project(traceRecord(outcome: outcome))
            let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))

            #expect(
                projection.attributes["agentstudio.performance.pane.association_outcome"]
                    == .string(outcome)
            )
            #expect(projection.attributes["agentstudio.pane.id"] != nil)
            #expect(projection.attributes["agentstudio.performance.pane.cwd_path"] != nil)
            #expect(metricEvent.dimensionTuples.contains { $0 == ("association_outcome", outcome) })
        }

        for rejectedOutcome in ["retry_scheduled", "private_outcome"] {
            let projection = OTLPProjectionAssertions.project(traceRecord(outcome: rejectedOutcome))
            let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))

            #expect(projection.attributes["agentstudio.performance.pane.association_outcome"] != nil)
            #expect(!metricEvent.dimensionTuples.contains { $0.0 == "association_outcome" })
        }
    }

    private func projectedRecord(outcome: String, timeUnixNano: UInt64) -> AgentStudioOTLPProjectedLogRecord {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:565: association emits typed outcome/counts, never message text.
        AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: timeUnixNano,
            severityText: .info,
            body: "performance.pane.association",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: ["agentstudio.performance.pane.association_outcome": .string(outcome)]
        )
    }

    private func traceRecord(outcome: String) -> AgentStudioTraceRecord {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:565: association emits typed outcome/counts, never message text.
        AgentStudioTraceRecord(
            timeUnixNano: 89,
            severityText: .info,
            body: "performance.pane.association",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.pane.association_outcome": .string(outcome),
                "agentstudio.pane.id": .string("019be3be-7c00-7000-8000-000000000099"),
                "agentstudio.performance.pane.cwd_path": .string("/private/worktree"),
            ]
        )
    }
}

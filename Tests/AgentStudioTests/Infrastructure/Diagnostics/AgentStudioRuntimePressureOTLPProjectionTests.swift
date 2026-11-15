import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioRuntimePressureOTLPProjectionTests {
    @Test
    func aggregateProjectionKeepsRecordedNumericVocabulary() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:660: terminal performance emits counts/durations, never terminal output text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 602,
            severityText: .info,
            body: "performance.terminal.accumulator_drain",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(3.5),
                "agentstudio.performance.terminal.accumulator.drain.class": .string("title_deadline"),
                "agentstudio.performance.terminal.accumulator.offered.count": .int(100),
                "agentstudio.performance.terminal.accumulator.replaced.count": .int(80),
                "agentstudio.performance.terminal.accumulator.retained_entry.count": .int(4),
                "agentstudio.performance.terminal.accumulator.retained_size_bytes": .int(256),
                "agentstudio.performance.terminal.accumulator.pane_id": .string("private-pane"),
                "agentstudio.performance.terminal.accumulator.path": .string("/private/path"),
                "agentstudio.performance.terminal.accumulator.payload": .string("terminal output"),
                "agentstudio.performance.terminal.accumulator.error": .string("private error"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(3.5))
        #expect(
            projection.attributes["agentstudio.performance.terminal.accumulator.drain.class"]
                == .string("title_deadline"))
        #expect(
            projection.attributes["agentstudio.performance.terminal.accumulator.offered.count"]
                == .int(100))
        #expect(
            projection.attributes["agentstudio.performance.terminal.accumulator.replaced.count"]
                == .int(80))
        #expect(
            projection.attributes["agentstudio.performance.terminal.accumulator.retained_entry.count"]
                == .int(4))
        #expect(
            projection.attributes["agentstudio.performance.terminal.accumulator.retained_size_bytes"]
                == .int(256))
    }

    @Test
    func terminalCompactApplyProjectionKeepsTypedActivityRoundTripFields() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:660: terminal performance emits counts/durations, never terminal output text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 603,
            severityText: .info,
            body: "performance.terminal.compact_apply",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.terminal.activity_projection.submitted": .bool(true),
                "agentstudio.performance.terminal.activity_projection.round_trip_ms": .double(4.5),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes["agentstudio.performance.terminal.activity_projection.submitted"]
                == .bool(true))
        #expect(
            projection.attributes["agentstudio.performance.terminal.activity_projection.round_trip_ms"]
                == .double(4.5))
    }

    @Test("terminal close read projection keeps only its numeric duration")
    func terminalCloseReadProjectionRetainsOtherFields() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:660: terminal performance emits counts/durations, never terminal output text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 604,
            severityText: .info,
            body: "performance.terminal.activity_projection.close_read",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.terminal.activity_projection.close_read_ms": .double(3.5),
                "terminal.output.line": .string("private output"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes["agentstudio.performance.terminal.activity_projection.close_read_ms"]
                == .double(3.5)
        )
        #expect(projection.attributes["terminal.output.line"] != nil)
    }
}

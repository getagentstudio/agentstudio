import Foundation
import Testing

@testable import AgentStudioInfrastructure

extension AgentStudioOTLPPerformanceTraceProjectionTests {
    @Test(
        "app IPC call spans retain only numeric durations and counts through OTLP projection",
        arguments: [AgentStudioPerformanceTraceRecorder.Event.ipcPaneContextRead, .ipcSessionEvent])
    func ipcCallDurationProjectionIsScrubbed(event: AgentStudioPerformanceTraceRecorder.Event) throws {
        let elapsedKey = "agentstudio.performance.elapsed_ms"
        let detailKey = "agentstudio.performance.ipc.pane_context_read.detail_elapsed_ms"
        let sizeKey = "agentstudio.performance.ipc.pane_context_read.reply_bytes"
        var numeric: [String: AgentStudioTraceValue] = [elapsedKey: .double(125)]
        if event == .ipcPaneContextRead {
            numeric[detailKey] = .double(80)
            numeric[sizeKey] = .int(4096)
        }
        var attributes = numeric
        let identifyingKeys = [
            "pane_id", "session_id", "agentstudio.performance.ipc.raw_path",
            "agentstudio.performance.ipc.payload", "agentstudio.performance.ipc.method_arguments",
        ]
        for key in identifyingKeys { attributes[key] = .string("PRIVATE-IDENTIFYING-CANARY") }
        let projection = AgentStudioOTLPTraceProjection.project(
            AgentStudioTraceRecord(
                timeUnixNano: 123, severityText: .info, body: event.rawValue,
                traceID: nil, spanID: nil, parentSpanID: nil, resource: [:],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"), attributes: attributes))
        var expected = numeric
        expected["agentstudio.event.time_unix_nano"] = .int(123)
        #expect(projection.body == event.rawValue)
        #expect(projection.attributes == expected)
        let metric = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))
        #expect(metric.eventName == event.rawValue)
        #expect(metric.elapsedMilliseconds == 125)

        let stringsInNumericKeys = AgentStudioOTLPTraceProjection.project(
            AgentStudioTraceRecord(
                timeUnixNano: 123, severityText: .info, body: event.rawValue,
                traceID: nil, spanID: nil, parentSpanID: nil, resource: [:],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    elapsedKey: .string("PRIVATE"), detailKey: .string("PRIVATE"), sizeKey: .string("PRIVATE"),
                ]))
        #expect(stringsInNumericKeys.attributes[elapsedKey] == nil)
        #expect(stringsInNumericKeys.attributes[detailKey] == nil)
        #expect(stringsInNumericKeys.attributes[sizeKey] == nil)
    }
}

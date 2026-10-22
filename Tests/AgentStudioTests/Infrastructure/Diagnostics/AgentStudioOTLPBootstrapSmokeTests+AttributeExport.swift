import Foundation
import Testing

@testable import AgentStudioInfrastructure

extension AgentStudioOTLPBootstrapSmokeTests {
    @Test
    func encodedLogsRetainEveryRecordedAttributeAcrossFamilies() async throws {
        let collector = try LoopbackOTLPHTTPCollector()
        defer { collector.cancel() }
        try await collector.start()
        let sink = try AgentStudioOTLPTraceSink(
            context: .init(
                endpoint: collector.endpoint(), otlpProtocol: .httpProtobuf,
                queueStatistics: AgentStudioTraceQueueStatistics()
            ),
            bootstrapper: AgentStudioOTLPBootstrapper()
        )
        let fixtures: [(String, [String: AgentStudioTraceValue])] = [
            (
                "performance.sidebar.projection",
                [
                    "agentstudio.performance.sidebar.surface": .string("panes"),
                    "agentstudio.performance.sidebar.sort_order": .string("descending"),
                    "agentstudio.performance.sidebar.group_mode": .string("activity"),
                    "agentstudio.performance.sidebar.phase": .string("projection_worker"),
                    "agentstudio.performance.elapsed_ms": .double(0.25),
                    "fixture.array": .stringArray(["first value", "/fixture/second", ""]),
                    "fixture.integer": .int(7),
                    "fixture.double": .double(0.25),
                    "fixture.boolean": .bool(true),
                    "fixture.string": .string("exact value with spaces\nand newline"),
                ]
            ),
            (
                "performance.git.status",
                [
                    "agentstudio.performance.git.admission_to_status.elapsed_ms": .double(1.25),
                    "agentstudio.performance.git.backoff_attempt.count": .int(2),
                ]
            ),
            (
                "performance.bridge.webkit.push_envelope",
                [
                    "agentstudio.bridge.phase": .string("transport"),
                    "agentstudio.bridge.plane": .string("data"),
                    "agentstudio.bridge.priority": .string("cold"),
                    "agentstudio.bridge.slice": .string("review_metadata"),
                    "agentstudio.bridge.fixture_values": .stringArray(["alpha", "beta"]),
                    "agentstudio.bridge.fixture_integer": .int(8),
                ]
            ),
        ]
        for (body, attributes) in fixtures {
            try await sink.record(
                .init(
                    timeUnixNano: 123, severityText: .info, body: body,
                    traceID: nil, spanID: nil, parentSpanID: nil,
                    resource: ["service.name": "attribute-export-test"],
                    scope: .init(name: "agentstudio.performance", version: "test"), attributes: attributes
                )
            )
        }
        try await sink.shutdown()
        collector.cancel()
        let requests = await collector.receivedRequests()
        let logs = try requests.filter { $0.path.hasSuffix("/v1/logs") }.flatMap {
            try OTLPProtobufTestDecoder.logRecords(in: $0.body)
        }
        for (body, attributes) in fixtures {
            let log = try #require(logs.first { $0.body == body })
            for (key, value) in attributes {
                let expected: OTLPProtobufTestDecoder.LogValue
                switch value {
                case .string(let string): expected = .string(string)
                case .stringArray(let strings): expected = .stringArray(strings)
                case .int(let number): expected = .string(String(number))
                case .double(let number): expected = .string(String(number))
                case .bool(let flag): expected = .string(String(flag))
                }
                #expect(log.attributes[key] == expected, "\(body): \(key)")
            }
        }
    }
}

import Foundation
import Testing

@testable import AgentStudioInfrastructure

extension AgentStudioOTLPBootstrapSmokeTests {
    @Test
    func firstRealProviderExportContainsQueueTotalsRetainedBeforeBootstrap() async throws {
        let collector = try LoopbackOTLPHTTPCollector()
        defer { collector.cancel() }
        try await collector.start()
        let runtime = try Self.queueRuntime(collector: collector)
        let statistics = runtime.queueStatistics
        let queueID = statistics.register()
        statistics.report(queueID, snapshot: .init(droppedRecordCount: 5, pendingRequestCount: 3, backlog: 3))
        #expect(!statistics.hasAttachedGauges)
        await runtime.record(tag: .runtime, body: "runtime.queue_statistics.bootstrap")
        #expect(statistics.hasAttachedGauges)
        try await runtime.shutdown()
        #expect(!statistics.hasAttachedGauges)
        collector.cancel()
        let requests = await collector.receivedRequests()
        let request = try #require(requests.first { $0.path.hasSuffix("/v1/metrics") })
        try Self.expectQueueGauges(in: request, dropped: 5, pending: 3, peak: 3)
        statistics.retire(queueID)
    }

    @Test
    func realProviderExportsLatestDrainAndRetirementWithoutAnotherLog() async throws {
        let collector = try LoopbackOTLPHTTPCollector()
        defer { collector.cancel() }
        try await collector.start()
        let runtime = try Self.queueRuntime(collector: collector)
        let statistics = runtime.queueStatistics
        let first = statistics.register()
        let second = statistics.register()
        statistics.report(first, snapshot: .init(droppedRecordCount: 1, pendingRequestCount: 2, backlog: 2))
        statistics.report(second, snapshot: .init(droppedRecordCount: 3, pendingRequestCount: 4, backlog: 4))
        await runtime.record(tag: .runtime, body: "runtime.queue_statistics.bootstrap")
        #expect(statistics.hasAttachedGauges)
        statistics.report(first, snapshot: .init(droppedRecordCount: 1))
        statistics.retire(second)
        // No later log: the aggregate must update the actual provider directly.
        try await runtime.shutdown()
        #expect(!statistics.hasAttachedGauges)
        #expect(statistics.snapshot() == .init(droppedRecordCount: 4, pendingRequestCount: 0, highWaterMark: 6))
        statistics.report(first, snapshot: .init(droppedRecordCount: 2, pendingRequestCount: 1, backlog: 1))
        #expect(statistics.snapshot() == .init(droppedRecordCount: 5, pendingRequestCount: 1, highWaterMark: 6))
        collector.cancel()
        let requests = await collector.receivedRequests()
        let request = try #require(requests.last { $0.path.hasSuffix("/v1/metrics") })
        try Self.expectQueueGauges(in: request, dropped: 4, pending: 0, peak: 6)
        statistics.retire(first)
    }

    @Test
    func disabledAndRefusedOTLPNeverAttachQueueGauges() async throws {
        for environment in [
            ["AGENTSTUDIO_TRACE_TAGS": "off", "AGENTSTUDIO_TRACE_BACKEND": "otlp"],
            [
                "AGENTSTUDIO_TRACE_TAGS": "runtime", "AGENTSTUDIO_TRACE_BACKEND": "otlp",
                "OTEL_EXPORTER_OTLP_ENDPOINT": "https://example.com",
            ],
        ] {
            let bootstrapper = AgentStudioOTLPBootstrapper()
            let runtime = AgentStudioTraceRuntime(
                configuration: .from(environment: environment),
                sinkFactory: .init(
                    makeJSONLSink: { _ in UnusedQueueJSONLSink() },
                    makeOTLPSink: { context in AgentStudioOTLPTraceSink(context: context, bootstrapper: bootstrapper) }
                )
            )
            #expect(!runtime.queueStatistics.hasAttachedGauges)
            await runtime.record(tag: .runtime, body: "runtime.queue_statistics.disabled")
            #expect(!runtime.queueStatistics.hasAttachedGauges)
            try await runtime.shutdown()
            #expect(!runtime.queueStatistics.hasAttachedGauges)
        }
    }

    private static func queueRuntime(collector: LoopbackOTLPHTTPCollector) throws -> AgentStudioTraceRuntime {
        AgentStudioTraceRuntime(
            configuration: .from(environment: [
                "AGENTSTUDIO_TRACE_TAGS": "runtime", "AGENTSTUDIO_TRACE_BACKEND": "otlp",
                "OTEL_EXPORTER_OTLP_ENDPOINT": try collector.endpoint().absoluteString,
            ]),
            serviceName: "queue-gauge-test",
            sinkFactory: isolatedOTLPSinkFactory()
        )
    }

    private static func expectQueueGauges(
        in request: LoopbackOTLPHTTPRequest, dropped: Double, pending: Double, peak: Double
    ) throws {
        let points = try OTLPProtobufTestDecoder.gaugePoints(in: request.body)
        let expected = [
            "agentstudio_performance_trace_queue_dropped_record_count": dropped,
            "agentstudio_performance_trace_queue_pending_request_count": pending,
            "agentstudio_performance_trace_queue_high_watermark": peak,
        ]
        let queuePoints = points.filter { $0.name.hasPrefix("agentstudio_performance_trace_queue_") }
        #expect(queuePoints.count == 3)
        for (name, value) in expected {
            let point = try #require(queuePoints.first { $0.name == name })
            #expect(point.value == value, "\(name)")
            #expect(point.attributes.isEmpty, "Queue gauge must carry resource labels only: \(name)")
            #expect(point.resourceAttributes["service.name"] == "queue-gauge-test")
        }
    }
}

// JSONL is outside the disabled/refused provider-attachment behavior under test.
private struct UnusedQueueJSONLSink: AgentStudioTraceSink {
    func record(_ record: AgentStudioTraceRecord) async throws {}
    func flush() async throws {}
    func shutdown() async throws {}
    func diagnostics() async -> AgentStudioTraceWriterDiagnostics { .empty }
}

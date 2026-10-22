import Foundation
import Testing

@testable import AgentStudioInfrastructure

@MainActor
@Suite(.serialized)
struct AgentStudioOTLPBootstrapSmokeTests {
    @Test
    func perSignalEnvironmentEndpointWinsOverConfiguredEndpoint() async throws {
        let sharedCollector = try LoopbackOTLPHTTPCollector()
        let logsCollector = try LoopbackOTLPHTTPCollector()
        defer {
            sharedCollector.cancel()
            logsCollector.cancel()
        }
        try await sharedCollector.start()
        try await logsCollector.start()
        let endpointKeys = [
            "OTEL_EXPORTER_OTLP_ENDPOINT",
            "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
            "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
        ]
        let originalEnvironment = ProcessInfo.processInfo.environment
        defer {
            for key in endpointKeys {
                if let value = originalEnvironment[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        for key in endpointKeys { unsetenv(key) }
        let sharedEndpoint = try sharedCollector.endpoint().absoluteString
        let logsEndpoint = try logsCollector.endpoint().appendingPathComponent("v1/logs").absoluteString
        setenv("OTEL_EXPORTER_OTLP_ENDPOINT", sharedEndpoint, 1)
        setenv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", logsEndpoint, 1)

        var environment = ProcessInfo.processInfo.environment
        environment["AGENTSTUDIO_TRACE_TAGS"] = "runtime"
        environment["AGENTSTUDIO_TRACE_BACKEND"] = "otlp"
        let configuration = AgentStudioTraceConfiguration.from(environment: environment)
        #expect(configuration.backend.includesOTLP)
        #expect(configuration.otlpEndpoint?.absoluteString == sharedEndpoint)
        let configuredEndpoint = try #require(configuration.otlpEndpoint)
        let bootstrapper = AgentStudioOTLPBootstrapper()
        let sink = AgentStudioOTLPTraceSink(
            context: AgentStudioOTLPTraceSinkContext(
                endpoint: configuredEndpoint, otlpProtocol: .httpProtobuf,
                queueStatistics: AgentStudioTraceQueueStatistics()
            ),
            bootstrapper: bootstrapper
        )
        let runtime = AgentStudioTraceRuntime(
            configuration: configuration,
            processIdentifier: 952,
            serviceVersion: "endpoint-precedence-version",
            sessionID: "endpoint-precedence-session",
            sinkFactory: AgentStudioTraceSinkFactory(
                makeJSONLSink: { _ in fatalError("JSONL is not used by this OTLP-only test") },
                makeOTLPSink: { _ in sink }
            )
        )
        await runtime.record(tag: .runtime, body: "runtime.endpoint.precedence")
        try await runtime.shutdown()
        // Shutdown is the producer's closing outcome. Closing the receiver streams
        // makes a missing request fail immediately rather than waiting for success only.
        sharedCollector.cancel()
        logsCollector.cancel()
        let logsRequest = try #require(
            await logsCollector.waitForRequest(pathSuffix: "/v1/logs", containing: "runtime.endpoint.precedence")
        )
        #expect(logsRequest.method == "POST")
        #expect(
            await sharedCollector.waitForRequest(pathSuffix: "/v1/logs", containing: "runtime.endpoint.precedence")
                == nil
        )
    }

    @Test
    func otelConfigurationAppliesExplicitLogBatchBackpressurePolicy() throws {
        let configuration = try AgentStudioOTLPBootstrapper.otelConfiguration(
            record: AgentStudioOTLPProjectedLogRecord(
                timeUnixNano: 123,
                severityText: .info,
                body: "runtime.otlp.configuration",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "agentstudio-test"],
                scope: .init(name: "agentstudio-test", version: "test-version"),
                attributes: [:]
            ),
            context: AgentStudioOTLPTraceSinkContext(
                endpoint: #require(URL(string: "http://127.0.0.1:4318")),
                otlpProtocol: .httpProtobuf,
                queueStatistics: AgentStudioTraceQueueStatistics()
            )
        )

        #expect(configuration.logs.batchLogRecordProcessor.maxQueueSize == AppPolicies.Diagnostics.otlpLogMaxQueueSize)
        #expect(configuration.logs.batchLogRecordProcessor.maxQueueSize == 8192)
        #expect(
            configuration.logs.batchLogRecordProcessor.maxExportBatchSize
                == AppPolicies.Diagnostics.otlpLogMaxExportBatchSize
        )
        #expect(configuration.logs.batchLogRecordProcessor.maxExportBatchSize == 1024)
        #expect(
            configuration.logs.batchLogRecordProcessor.scheduleDelay == AppPolicies.Diagnostics.otlpLogScheduleDelay
        )
        #expect(configuration.logs.batchLogRecordProcessor.scheduleDelay == .seconds(1))
        #expect(configuration.logs.batchLogRecordProcessor.exportTimeout == AppPolicies.Diagnostics.otlpExportTimeout)
        #expect(configuration.traces.batchSpanProcessor.scheduleDelay == AppPolicies.Diagnostics.otlpTraceScheduleDelay)
        #expect(configuration.traces.batchSpanProcessor.exportTimeout == AppPolicies.Diagnostics.otlpExportTimeout)
        #expect(configuration.metrics.exportInterval == AppPolicies.Diagnostics.otlpMetricsExportInterval)
        #expect(configuration.metrics.exportTimeout == AppPolicies.Diagnostics.otlpExportTimeout)
    }

    @Test
    func liveOTLPSinkPostsLogRecordToLoopbackHTTPCollector() async throws {
        let collector = try LoopbackOTLPHTTPCollector()
        defer { collector.cancel() }
        try await collector.start()
        let worktreeId = UUID()
        let identityStore = AgentStudioTraceIdentityStore()
        await identityStore.update(
            AgentStudioTraceIdentitySnapshot(
                worktreeIdentitiesByWorktreeId: [
                    worktreeId: AgentStudioTraceWorktreeIdentity(
                        repoHash: "repo-hash-live",
                        worktreeHash: "worktree-hash-live",
                        branch: "feature/otel-live"
                    )
                ]
            )
        )

        let runtime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "otlp",
                "AGENTSTUDIO_TRACE_NAME": "live-otlp-smoke",
                "AGENTSTUDIO_TRACE_TAGS": "app.startup,runtime,performance,bridge.performance.webkit",
                "OTEL_EXPORTER_OTLP_ENDPOINT": try collector.endpoint().absoluteString,
            ]),
            processIdentifier: 951,
            serviceVersion: "smoke-version",
            sessionID: "smoke-session",
            sinkFactory: Self.isolatedOTLPSinkFactory(),
            identityStore: identityStore,
            timeUnixNano: { 123_456_789 }
        )

        await runtime.record(
            tag: .appStartup,
            body: "app.process.start"
        )
        await runtime.record(
            tag: .runtime,
            body: "runtime.otlp.smoke",
            attributes: [
                "agentstudio.runtime.event": .string("otlp-smoke"),
                "agentstudio.worktree.id": .string(worktreeId.uuidString),
            ]
        )
        await runtime.record(
            tag: .performance,
            body: "performance.git.status",
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(12.5),
                "agentstudio.performance.git.pending.count": .int(7),
                "agentstudio.performance.git.running.count": .int(3),
            ]
        )
        await runtime.record(
            tag: .bridgePerformanceWebKit,
            body: "performance.bridge.webkit.push_envelope",
            traceID: "11111111111111111111111111111111",
            spanID: "2222222222222222",
            attributes: [
                "agentstudio.bridge.content.byte_size_bucket": .int(100_000),
                "agentstudio.bridge.content.line_count_bucket": .int(500),
                "agentstudio.bridge.phase": .string("transport"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("cold"),
                "agentstudio.bridge.slice": .string("review_metadata"),
                "agentstudio.bridge.transport": .string("push"),
                "agentstudio.performance.elapsed_ms": .double(8.5),
            ]
        )
        try await runtime.shutdown()

        let request = try #require(
            await collector.waitForRequest(containing: "worktree-hash-live")
        )
        #expect(request.method == "POST")
        #expect(request.path.hasSuffix("/v1/logs"))
        #expect(request.bodyByteCount > 0)
        #expect(request.headers["content-type"]?.contains("application/x-protobuf") == true)
        #expect(request.bodyContains("worktree-hash-live"))
        #expect(request.bodyContains("feature/otel-live"))
        #expect(request.bodyContains("live-otlp-smoke"))
        #expect(request.bodyContains("agentstudio.event.time_unix_nano"))

        let metricsRequest = try #require(
            await collector.waitForRequest(containing: "agentstudio_performance_events_total")
        )
        #expect(metricsRequest.method == "POST")
        #expect(metricsRequest.path.hasSuffix("/v1/metrics"))
        #expect(metricsRequest.bodyByteCount > 0)
        #expect(metricsRequest.headers["content-type"]?.contains("application/x-protobuf") == true)
        #expect(metricsRequest.bodyContains("performance.git.status"))
        #expect(metricsRequest.bodyContains("agentstudio_performance_event_elapsed_ms"))
        #expect(metricsRequest.bodyContains("agentstudio_performance_git_pending_count"))
        #expect(metricsRequest.bodyContains("review_metadata"))

        try await assertBridgeOTLPTraceRequests(collector)
    }

    private func assertBridgeOTLPTraceRequests(_ collector: LoopbackOTLPHTTPCollector) async throws {
        let bridgeLogRequest = try #require(
            await collector.waitForRequest(
                pathSuffix: "/v1/logs",
                containing: "performance.bridge.webkit.push_envelope"
            )
        )
        #expect(bridgeLogRequest.bodyContains(hexEncodedBytes: "11111111111111111111111111111111"))

        let bridgeTraceRequest = try #require(
            await collector.waitForRequest(
                pathSuffix: "/v1/traces",
                containing: "performance.bridge.webkit.push_envelope"
            )
        )
        #expect(bridgeTraceRequest.method == "POST")
        #expect(bridgeTraceRequest.path.hasSuffix("/v1/traces"))
        #expect(bridgeTraceRequest.bodyContains(hexEncodedBytes: "11111111111111111111111111111111"))
        #expect(bridgeTraceRequest.bodyContains(hexEncodedBytes: "2222222222222222"))
    }

    static func isolatedOTLPSinkFactory() -> AgentStudioTraceSinkFactory {
        let bootstrapper = AgentStudioOTLPBootstrapper()
        return AgentStudioTraceSinkFactory(
            makeJSONLSink: { _ in fatalError("JSONL sink is not used by this OTLP-only smoke") },
            makeOTLPSink: { context in
                AgentStudioOTLPTraceSink(context: context, bootstrapper: bootstrapper)
            }
        )
    }
}

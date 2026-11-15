import Foundation
import Logging
import Metrics
import OTel
import ServiceLifecycle

protocol AgentStudioOTLPBootstrapping: Sendable {
    func emit(_ record: AgentStudioOTLPProjectedLogRecord, context: AgentStudioOTLPTraceSinkContext) async
    func flush() async
    func shutdown() async
}

actor AgentStudioOTLPBootstrapper: AgentStudioOTLPBootstrapping {
    static let shared = AgentStudioOTLPBootstrapper()

    private var state: AgentStudioOTLPServiceState?
    private var didReportBootstrapFailure = false
    private var didShutdown = false

    func emit(_ record: AgentStudioOTLPProjectedLogRecord, context: AgentStudioOTLPTraceSinkContext) async {
        guard let state = bootstrapIfNeeded(record: record, context: context) else {
            return
        }

        Self.emitLog(record, state: state)
        state.performanceMetrics.record(record)
    }

    func flush() async {
        // Swift OTel owns batching behind the bootstrapped service. Routine AgentStudio
        // trace flushes must not stop that service; final drain happens in shutdown().
    }

    func shutdown() async {
        didShutdown = true
        guard let state else { return }
        state.queueStatistics.detach()
        await state.serviceGroup.triggerGracefulShutdown()
        await state.runTask.value
        self.state = nil
    }

    private func bootstrapIfNeeded(
        record: AgentStudioOTLPProjectedLogRecord,
        context: AgentStudioOTLPTraceSinkContext
    ) -> AgentStudioOTLPServiceState? {
        if let state {
            return state
        }
        guard !didShutdown else {
            return nil
        }

        do {
            let configuration = Self.otelConfiguration(record: record, context: context)
            let loggingBackend = try OTel.makeLoggingBackend(configuration: configuration)
            let metricsBackend = try OTel.makeMetricsBackend(configuration: configuration)
            let tracingBackend = try AgentStudioOTLPTracingBackend(configuration: configuration)
            let serviceGroup = ServiceGroup(
                services: [loggingBackend.service, metricsBackend.service, tracingBackend.service],
                logger: Logger(label: "agentstudio.otlp.service", factory: StreamLogHandler.standardError(label:))
            )
            context.queueStatistics.attach(gauges: .init(factory: metricsBackend.factory))
            let runTask = Task {
                do {
                    try await serviceGroup.run()
                } catch {
                    Self.writeStartupDiagnostic("AgentStudio OTLP service stopped with error: \(error)")
                }
            }
            let state = AgentStudioOTLPServiceState(
                serviceGroup: serviceGroup,
                runTask: runTask,
                logger: Logger(label: "agentstudio.otlp", factory: loggingBackend.factory),
                performanceMetrics: AgentStudioOTLPPerformanceMetrics(factory: metricsBackend.factory),
                tracingBackend: tracingBackend,
                queueStatistics: context.queueStatistics
            )
            self.state = state
            Self.writeStartupDiagnostic(
                "AgentStudio OTLP export enabled: logs=\(Self.logsEndpoint(from: context.endpoint)) "
                    + "metrics=\(Self.metricsEndpoint(from: context.endpoint)) "
                    + "traces=\(Self.tracesEndpoint(from: context.endpoint))"
            )
            return state
        } catch {
            if !didReportBootstrapFailure {
                didReportBootstrapFailure = true
                Self.writeStartupDiagnostic("AgentStudio OTLP bootstrap failed: \(error)")
            }
            return nil
        }
    }

    static func otelConfiguration(
        record: AgentStudioOTLPProjectedLogRecord,
        context: AgentStudioOTLPTraceSinkContext
    ) -> OTel.Configuration {
        var configuration = OTel.Configuration.default
        configuration.metrics.enabled = true
        configuration.metrics.exporter = .otlp
        configuration.metrics.otlpExporter.endpoint = Self.metricsEndpoint(from: context.endpoint)
        configuration.metrics.otlpExporter.protocol = .httpProtobuf
        configuration.metrics.exportInterval = AppPolicies.Diagnostics.otlpMetricsExportInterval
        configuration.metrics.exportTimeout = AppPolicies.Diagnostics.otlpExportTimeout
        configuration.metrics.valueHistogramBuckets[AgentStudioOTLPPerformanceMetrics.elapsedMetricLabel] =
            AgentStudioOTLPPerformanceMetrics.elapsedHistogramBuckets
        configuration.traces.enabled = true
        configuration.traces.exporter = .otlp
        configuration.traces.otlpExporter.endpoint = Self.tracesEndpoint(from: context.endpoint)
        configuration.traces.otlpExporter.protocol = .httpProtobuf
        configuration.traces.batchSpanProcessor.scheduleDelay = AppPolicies.Diagnostics.otlpTraceScheduleDelay
        configuration.traces.batchSpanProcessor.exportTimeout = AppPolicies.Diagnostics.otlpExportTimeout
        configuration.logs.enabled = true
        configuration.logs.level = .trace
        configuration.logs.exporter = .otlp
        configuration.logs.otlpExporter.endpoint = Self.logsEndpoint(from: context.endpoint)
        configuration.logs.otlpExporter.protocol = .httpProtobuf
        configuration.logs.batchLogRecordProcessor.scheduleDelay = AppPolicies.Diagnostics.otlpLogScheduleDelay
        configuration.logs.batchLogRecordProcessor.exportTimeout = AppPolicies.Diagnostics.otlpExportTimeout
        configuration.logs.batchLogRecordProcessor.maxQueueSize = AppPolicies.Diagnostics.otlpLogMaxQueueSize
        configuration.logs.batchLogRecordProcessor.maxExportBatchSize =
            AppPolicies.Diagnostics.otlpLogMaxExportBatchSize
        configuration.serviceName = record.resource["service.name"] ?? "agentstudio"
        configuration.resourceAttributes = record.resource.filter { key, _ in
            key != "service.name"
        }
        return configuration
    }

    private static func logsEndpoint(from endpoint: URL) -> String {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint.absoluteString
        }

        let path = components.path
        guard !path.hasSuffix("/v1/logs") else {
            return endpoint.absoluteString
        }

        if path.isEmpty || path == "/" {
            components.path = "/v1/logs"
        } else if path.hasSuffix("/") {
            components.path = "\(path)v1/logs"
        } else {
            components.path = "\(path)/v1/logs"
        }
        return components.url?.absoluteString ?? endpoint.absoluteString
    }

    private static func metricsEndpoint(from endpoint: URL) -> String {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint.absoluteString
        }

        let path = components.path
        guard !path.hasSuffix("/v1/metrics") else {
            return endpoint.absoluteString
        }

        if path.isEmpty || path == "/" {
            components.path = "/v1/metrics"
        } else if path.hasSuffix("/") {
            components.path = "\(path)v1/metrics"
        } else {
            components.path = "\(path)/v1/metrics"
        }
        return components.url?.absoluteString ?? endpoint.absoluteString
    }

    private static func tracesEndpoint(from endpoint: URL) -> String {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint.absoluteString
        }

        let path = components.path
        guard !path.hasSuffix("/v1/traces") else {
            return endpoint.absoluteString
        }

        if path.isEmpty || path == "/" {
            components.path = "/v1/traces"
        } else if path.hasSuffix("/") {
            components.path = "\(path)v1/traces"
        } else {
            components.path = "\(path)/v1/traces"
        }
        return components.url?.absoluteString ?? endpoint.absoluteString
    }

    private static func emitLog(
        _ record: AgentStudioOTLPProjectedLogRecord,
        state: AgentStudioOTLPServiceState
    ) {
        let metadata = Self.metadata(from: record.attributes)
        guard let parentTraceparent = Self.traceparent(from: record) else {
            state.logger.log(
                level: Logger.Level(record.severityText),
                "\(record.body)",
                metadata: metadata
            )
            return
        }

        state.tracingBackend.withSpan(
            operationName: record.body,
            parentTraceparent: parentTraceparent,
            startTimeUnixNano: record.timeUnixNano,
            durationMilliseconds: Self.elapsedMilliseconds(from: record),
            attributes: record.attributes
        ) {
            state.logger.log(
                level: Logger.Level(record.severityText),
                "\(record.body)",
                metadata: metadata
            )
        }
    }

    private static func traceparent(from record: AgentStudioOTLPProjectedLogRecord) -> String? {
        guard let traceID = record.traceID, let spanID = record.parentSpanID ?? record.spanID else {
            return nil
        }
        return "00-\(traceID)-\(spanID)-01"
    }

    private static func elapsedMilliseconds(from record: AgentStudioOTLPProjectedLogRecord) -> Double? {
        switch record.attributes["agentstudio.performance.elapsed_ms"] {
        case .double(let doubleValue):
            doubleValue
        case .int(let intValue):
            Double(intValue)
        case .bool, .string, .stringArray, .none:
            nil
        }
    }

    private static func metadata(
        from attributes: [String: AgentStudioTraceValue]
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [:]
        for (key, value) in attributes {
            metadata[key] = Logger.MetadataValue(value)
        }
        return metadata
    }

    private static func writeStartupDiagnostic(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
    }
}

private struct AgentStudioOTLPServiceState: Sendable {
    let serviceGroup: ServiceGroup
    let runTask: Task<Void, Never>
    let logger: Logger
    let performanceMetrics: AgentStudioOTLPPerformanceMetrics
    let tracingBackend: AgentStudioOTLPTracingBackend
    let queueStatistics: AgentStudioTraceQueueStatistics
}

extension Logger.Level {
    fileprivate init(_ severity: AgentStudioTraceSeverity) {
        switch severity {
        case .trace:
            self = .trace
        case .debug:
            self = .debug
        case .info:
            self = .info
        case .warn:
            self = .warning
        case .error:
            self = .error
        }
    }
}

extension Logger.MetadataValue {
    fileprivate init(_ value: AgentStudioTraceValue) {
        switch value {
        case .bool(let boolValue):
            self = .stringConvertible(boolValue)
        case .double(let doubleValue):
            self = .stringConvertible(doubleValue)
        case .int(let intValue):
            self = .stringConvertible(intValue)
        case .string(let stringValue):
            self = .string(stringValue)
        case .stringArray(let values):
            self = .array(values.map(Logger.Metadata.Value.string))
        }
    }
}

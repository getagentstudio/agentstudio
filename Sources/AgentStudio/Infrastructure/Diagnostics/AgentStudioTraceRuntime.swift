import Foundation
import OTel
import Tracing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

package struct AgentStudioTraceRuntime: Sendable {
    private let configuration: AgentStudioTraceConfiguration
    private let sinks: [any AgentStudioTraceSink]
    private let baseResource: [String: String]
    private let identityStore: AgentStudioTraceIdentityStore
    private let scopeVersion: String
    private let timeUnixNano: @Sendable () -> UInt64

    let queueStatistics: AgentStudioTraceQueueStatistics

    package let outputFileURL: URL?

    package var isEnabled: Bool {
        configuration.isEnabled && !sinks.isEmpty
    }

    package init(
        configuration: AgentStudioTraceConfiguration,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        serviceName: String = "AgentStudio",
        serviceVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        sessionID: String = UUID().uuidString,
        scopeVersion: String = "0.1.0",
        writerRetainedLineLimit: Int = 2048,
        timeUnixNano: @escaping @Sendable () -> UInt64
    ) {
        self.init(
            configuration: configuration,
            processIdentifier: processIdentifier,
            serviceName: serviceName,
            serviceVersion: serviceVersion,
            sessionID: sessionID,
            scopeVersion: scopeVersion,
            writerRetainedLineLimit: writerRetainedLineLimit,
            sinkFactory: .live,
            timeUnixNano: timeUnixNano
        )
    }

    package init(
        configuration: AgentStudioTraceConfiguration,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        serviceName: String = "AgentStudio",
        serviceVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        sessionID: String = UUID().uuidString,
        scopeVersion: String = "0.1.0",
        writerRetainedLineLimit: Int = 2048
    ) {
        self.init(
            configuration: configuration,
            processIdentifier: processIdentifier,
            serviceName: serviceName,
            serviceVersion: serviceVersion,
            sessionID: sessionID,
            scopeVersion: scopeVersion,
            writerRetainedLineLimit: writerRetainedLineLimit,
            sinkFactory: .live
        )
    }

    init(
        configuration: AgentStudioTraceConfiguration,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        serviceName: String = "AgentStudio",
        serviceVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        sessionID: String = UUID().uuidString,
        scopeVersion: String = "0.1.0",
        writerRetainedLineLimit: Int = 2048,
        sinkFactory: AgentStudioTraceSinkFactory,
        identityStore: AgentStudioTraceIdentityStore = .init(),
        timeUnixNano: @escaping @Sendable () -> UInt64 = Self.currentTimeUnixNano
    ) {
        self.configuration = configuration
        self.baseResource = Self.resourceAttributes(
            configuration: configuration,
            serviceName: serviceName,
            serviceVersion: serviceVersion,
            processIdentifier: processIdentifier,
            sessionID: sessionID
        )
        self.identityStore = identityStore
        self.scopeVersion = scopeVersion
        self.timeUnixNano = timeUnixNano
        let queueStatistics = AgentStudioTraceQueueStatistics()
        self.queueStatistics = queueStatistics
        let sinkBundle = Self.sinkBundle(
            configuration: configuration,
            processIdentifier: processIdentifier,
            writerRetainedLineLimit: writerRetainedLineLimit,
            sinkFactory: sinkFactory,
            queueStatistics: queueStatistics,
            timeUnixNano: timeUnixNano
        )
        self.sinks = sinkBundle.sinks
        self.outputFileURL = sinkBundle.outputFileURL

        if !configuration.unknownTagSelectors.isEmpty {
            Self.writeStartupDiagnostic(
                "AgentStudio tracing ignored unknown tag selectors: "
                    + configuration.unknownTagSelectors.joined(separator: ",")
            )
        }

        if let unsupportedBackendSelector = configuration.unsupportedBackendSelector {
            Self.writeStartupDiagnostic(
                "AgentStudio tracing ignored unsupported backend selector: "
                    + unsupportedBackendSelector
                    + "; using jsonl"
            )
        }

        if let rejectedOTLPEndpointSelector = configuration.rejectedOTLPEndpointSelector {
            Self.writeStartupDiagnostic(
                "AgentStudio tracing ignored non-loopback OTLP endpoint: "
                    + rejectedOTLPEndpointSelector
                    + "; using jsonl"
            )
        }

        if let unsupportedOTLPProtocolSelector = configuration.unsupportedOTLPProtocolSelector {
            Self.writeStartupDiagnostic(
                "AgentStudio tracing ignored unsupported OTLP protocol selector: "
                    + unsupportedOTLPProtocolSelector
                    + "; using jsonl"
            )
        }

        if isEnabled {
            if let outputFileURL {
                Self.writeStartupDiagnostic("AgentStudio tracing enabled: \(outputFileURL.path)")
            } else {
                Self.writeStartupDiagnostic("AgentStudio tracing enabled: otlp")
            }
        }
    }

    package static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        preferenceLayer: AgentStudioTracePreferenceLayer? = nil,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> Self {
        Self(
            configuration: AgentStudioTraceConfiguration.from(
                environment: environment,
                preferenceLayer: preferenceLayer
            ),
            processIdentifier: processIdentifier
        )
    }

    package func isEnabled(_ tag: AgentStudioTraceTag) -> Bool {
        configuration.isEnabled(tag)
    }

    package func timestampUnixNano() -> UInt64 {
        timeUnixNano()
    }

    package func updateIdentitySnapshot(
        _ snapshot: AgentStudioTraceIdentitySnapshot
    ) async -> AgentStudioTraceIdentityUpdateOutcome {
        await identityStore.update(snapshot)
    }

    package func record(
        tag: AgentStudioTraceTag,
        body: String,
        severity: AgentStudioTraceSeverity = .info,
        context: ServiceContext? = ServiceContext.current,
        traceID: String? = nil,
        spanID: String? = nil,
        parentSpanID: String? = nil,
        eventTimeUnixNano: UInt64? = nil,
        attributes: @autoclosure @Sendable () -> [String: AgentStudioTraceValue] = [:]
    ) async {
        guard configuration.isEnabled(tag), !sinks.isEmpty else { return }

        var mergedAttributes = attributes()
        mergedAttributes["agentstudio.trace.tag"] = .string(tag.rawValue)
        if let correlationID = context?.agentStudioCorrelationID {
            mergedAttributes["agentstudio.correlation_id"] = .string(correlationID)
        }
        let resource = await identityStore.resourceAttributes(
            for: mergedAttributes,
            baseResource: baseResource
        )

        let record = AgentStudioTraceRecord(
            timeUnixNano: eventTimeUnixNano ?? timeUnixNano(),
            severityText: severity,
            body: body,
            traceID: traceID ?? context?.otelTraceID,
            spanID: spanID,
            parentSpanID: parentSpanID,
            resource: resource,
            scope: .init(name: "agentstudio.\(tag.rawValue)", version: scopeVersion),
            attributes: mergedAttributes
        )
        await dispatch(record)
        guard configuration.flushMode == .immediate else { return }
        await flushFromRecord()
    }

    package func flush() async throws {
        var firstError: Error?
        for sink in sinks {
            do {
                try await sink.flush()
            } catch {
                if firstError == nil {
                    firstError = error
                }
                debugLog("[trace] failed to flush sink: \(error)")
                Self.writeStartupDiagnostic("AgentStudio tracing failed to flush sink: \(error)")
            }
        }
        if let firstError {
            throw firstError
        }
    }

    package func shutdown() async throws {
        var firstError: Error?
        for sink in sinks {
            do {
                try await sink.shutdown()
            } catch {
                if firstError == nil {
                    firstError = error
                }
                debugLog("[trace] failed to shut down sink: \(error)")
                Self.writeStartupDiagnostic("AgentStudio tracing failed to shut down sink: \(error)")
            }
        }
        if let firstError {
            throw firstError
        }
    }

    package func diagnostics() async -> AgentStudioTraceWriterDiagnostics {
        var failedFlushCount = 0
        var lastFlushErrorDescription: String?
        for sink in sinks {
            let diagnostics = await sink.diagnostics()
            failedFlushCount += diagnostics.failedFlushCount
            if let lastError = diagnostics.lastFlushErrorDescription {
                lastFlushErrorDescription = lastError
            }
        }
        return AgentStudioTraceWriterDiagnostics(
            failedFlushCount: failedFlushCount,
            lastFlushErrorDescription: lastFlushErrorDescription
        )
    }

    private func dispatch(_ record: AgentStudioTraceRecord) async {
        await withTaskGroup(of: Void.self) { taskGroup in
            for sink in sinks {
                taskGroup.addTask {
                    do {
                        try await sink.record(record)
                    } catch {
                        debugLog("[trace] failed to record \(record.body): \(error)")
                        Self.writeStartupDiagnostic("AgentStudio tracing failed to record \(record.body): \(error)")
                    }
                }
            }
        }
    }

    private func flushFromRecord() async {
        do {
            try await flush()
        } catch {
            debugLog("[trace] failed immediate flush: \(error)")
        }
    }

    private static func resourceAttributes(
        configuration: AgentStudioTraceConfiguration,
        serviceName: String,
        serviceVersion: String?,
        processIdentifier: Int32,
        sessionID: String
    ) -> [String: String] {
        var attributes = [
            "agentstudio.build.config": buildConfiguration,
            "agentstudio.release_channel": configuration.releaseChannel.rawValue,
            "agentstudio.runtime_flavor": configuration.runtimeFlavor.rawValue,
            "agentstudio.session.id": sessionID,
            "agent.proof.marker": configuration.traceName,
            "dev.build.config": buildConfiguration.lowercased(),
            "dev.release.channel": configuration.releaseChannel.rawValue,
            "dev.runtime.flavor": configuration.runtimeFlavor.rawValue,
            "process.pid": "\(processIdentifier)",
            "service.name": serviceName,
        ]
        if let proofToken = configuration.proofToken {
            attributes["agent.proof.launch"] = proofToken
        }
        if let serviceVersion, !serviceVersion.isEmpty {
            attributes["service.version"] = serviceVersion
        }
        return attributes
    }

    private static func sinkBundle(
        configuration: AgentStudioTraceConfiguration,
        processIdentifier: Int32,
        writerRetainedLineLimit: Int,
        sinkFactory: AgentStudioTraceSinkFactory,
        queueStatistics: AgentStudioTraceQueueStatistics,
        timeUnixNano: @escaping @Sendable () -> UInt64
    ) -> (sinks: [any AgentStudioTraceSink], outputFileURL: URL?) {
        guard configuration.isEnabled else {
            return ([], nil)
        }

        var sinks: [any AgentStudioTraceSink] = []
        var outputFileURL: URL?
        if configuration.backend.includesJSONL {
            let fileURL = configuration.outputFileURL(processIdentifier: processIdentifier)
            outputFileURL = fileURL
            sinks.append(
                sinkFactory.makeJSONLSink(
                    AgentStudioJSONLTraceSinkContext(
                        fileURL: fileURL,
                        retainedLineLimit: writerRetainedLineLimit,
                        timeUnixNano: timeUnixNano
                    )
                )
            )
        }

        if configuration.backend.includesOTLP, let endpoint = configuration.otlpEndpoint {
            sinks.append(
                sinkFactory.makeOTLPSink(
                    AgentStudioOTLPTraceSinkContext(
                        endpoint: endpoint,
                        otlpProtocol: configuration.otlpProtocol,
                        queueStatistics: queueStatistics
                    )
                )
            )
        }

        return (sinks, outputFileURL)
    }

    private static func currentTimeUnixNano() -> UInt64 {
        let nanosecondsPerSecond: UInt64 = 1_000_000_000
        #if canImport(Darwin) || canImport(Glibc)
            var currentTime = timespec()
            clock_gettime(CLOCK_REALTIME, &currentTime)
            return UInt64(currentTime.tv_sec) * nanosecondsPerSecond + UInt64(currentTime.tv_nsec)
        #else
            let seconds = UInt64(Date().timeIntervalSince1970)
            let nanoseconds = UInt64(
                Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * Double(nanosecondsPerSecond))
            return seconds * nanosecondsPerSecond + nanoseconds
        #endif
    }

    private static var buildConfiguration: String {
        #if DEBUG
            "DEBUG"
        #else
            "RELEASE"
        #endif
    }

    private static func writeStartupDiagnostic(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
    }
}

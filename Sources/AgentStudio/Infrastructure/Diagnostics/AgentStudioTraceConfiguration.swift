import Foundation

enum AgentStudioTraceFlushMode: String, Equatable, Sendable {
    case buffered
    case immediate

    static func parse(_ rawValue: String?) -> Self {
        guard
            let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            rawValue == Self.immediate.rawValue
        else { return .buffered }
        return .immediate
    }
}

enum AgentStudioTraceBackend: Equatable, Sendable {
    case jsonl
    case otlp
    case both

    var includesJSONL: Bool {
        switch self {
        case .jsonl, .both:
            true
        case .otlp:
            false
        }
    }

    var includesOTLP: Bool {
        switch self {
        case .otlp, .both:
            true
        case .jsonl:
            false
        }
    }

    static func parse(
        _ rawValue: String?,
        defaultBackend: Self
    ) -> (backend: Self, unsupportedSelector: String?) {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !rawValue.isEmpty
        else { return (defaultBackend, nil) }

        switch rawValue {
        case "jsonl":
            return (.jsonl, nil)
        case "otlp":
            return (.otlp, nil)
        case "both":
            return (.both, nil)
        default:
            return (.jsonl, rawValue)
        }
    }
}

enum AgentStudioTraceRuntimeFlavor: String, Equatable, Sendable {
    case debug
    case beta
    case stable

    static func from(
        releaseChannel: AppDataPaths.ReleaseChannel,
        isDebugBuild: Bool
    ) -> Self {
        if isDebugBuild {
            return .debug
        }

        switch releaseChannel {
        case .beta:
            return .beta
        case .stable:
            return .stable
        }
    }
}

enum AgentStudioOTLPProtocol: String, Equatable, Sendable {
    case httpProtobuf = "http/protobuf"

    static func parse(_ rawValue: String?) -> (otlpProtocol: Self, unsupportedSelector: String?) {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !rawValue.isEmpty
        else { return (.httpProtobuf, nil) }

        guard rawValue == Self.httpProtobuf.rawValue else {
            return (.httpProtobuf, rawValue)
        }
        return (.httpProtobuf, nil)
    }
}

package struct AgentStudioTraceConfiguration: Equatable, Sendable {
    static let defaultDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
    static let defaultOTLPEndpoint = URL(string: "http://127.0.0.1:4318")!
    static let safeDefaultTags: Set<AgentStudioTraceTag> = [
        .appStartup,
        .terminalStartup,
        .runtime,
        .surface,
        .persistenceRecovery,
    ]

    let enabledTags: Set<AgentStudioTraceTag>
    let traceName: String
    let proofToken: String?
    let directory: URL
    let flushMode: AgentStudioTraceFlushMode
    let backend: AgentStudioTraceBackend
    let runtimeFlavor: AgentStudioTraceRuntimeFlavor
    let releaseChannel: AppDataPaths.ReleaseChannel
    let otlpEndpoint: URL?
    let otlpProtocol: AgentStudioOTLPProtocol
    let unknownTagSelectors: [String]
    let unsupportedBackendSelector: String?
    let rejectedOTLPEndpointSelector: String?
    let unsupportedOTLPProtocolSelector: String?

    var isEnabled: Bool {
        !enabledTags.isEmpty
    }

    package static func from(
        environment: [String: String],
        preferenceLayer: AgentStudioTracePreferenceLayer? = nil,
        releaseChannel: AppDataPaths.ReleaseChannel = .current,
        isDebugBuild: Bool = AppDataPaths.isDebugBuild
    ) -> Self {
        let runtimeFlavor = AgentStudioTraceRuntimeFlavor.from(
            releaseChannel: releaseChannel,
            isDebugBuild: isDebugBuild
        )
        let selection = tagSelection(
            environment["AGENTSTUDIO_TRACE_TAGS"] ?? preferenceTraceTags(preferenceLayer),
            runtimeFlavor: runtimeFlavor
        )
        let traceName = sanitizedTraceName(environment["AGENTSTUDIO_TRACE_NAME"])
        let proofToken = sanitizedProofToken(environment["AGENTSTUDIO_TRACE_PROOF_TOKEN"])
        let directory = traceDirectory(environment["AGENTSTUDIO_TRACE_DIR"])
        let flushMode = AgentStudioTraceFlushMode.parse(
            environment["AGENTSTUDIO_TRACE_FLUSH"] ?? preferenceTraceFlush(preferenceLayer)
        )
        let backendSelection = AgentStudioTraceBackend.parse(
            environment["AGENTSTUDIO_TRACE_BACKEND"] ?? preferenceTraceBackend(preferenceLayer),
            defaultBackend: defaultBackend(runtimeFlavor: runtimeFlavor)
        )
        let protocolSelection = AgentStudioOTLPProtocol.parse(environment["OTEL_EXPORTER_OTLP_PROTOCOL"])
        let endpointSelection = otlpEndpointSelection(
            environment["OTEL_EXPORTER_OTLP_ENDPOINT"] ?? preferenceLayer?.otlpEndpoint,
            environment: environment,
            backend: backendSelection.backend,
            isTracingEnabled: !selection.tags.isEmpty,
            isProtocolSupported: protocolSelection.unsupportedSelector == nil
        )
        let backend = effectiveBackend(
            selectedBackend: backendSelection.backend,
            isTracingEnabled: !selection.tags.isEmpty,
            isOTLPEndpointAvailable: endpointSelection.url != nil,
            isProtocolSupported: protocolSelection.unsupportedSelector == nil
        )
        return Self(
            enabledTags: selection.tags,
            traceName: traceName,
            proofToken: proofToken,
            directory: directory,
            flushMode: flushMode,
            backend: backend,
            runtimeFlavor: runtimeFlavor,
            releaseChannel: releaseChannel,
            otlpEndpoint: endpointSelection.url,
            otlpProtocol: protocolSelection.otlpProtocol,
            unknownTagSelectors: selection.unknownSelectors,
            unsupportedBackendSelector: backendSelection.unsupportedSelector,
            rejectedOTLPEndpointSelector: endpointSelection.rejectedSelector,
            unsupportedOTLPProtocolSelector: protocolSelection.unsupportedSelector
        )
    }

    func isEnabled(_ tag: AgentStudioTraceTag) -> Bool {
        enabledTags.contains(tag)
    }

    func outputFileURL(processIdentifier: Int32) -> URL {
        directory.appendingPathComponent("agentstudio-\(traceName)-\(processIdentifier).jsonl")
    }

    private init(
        enabledTags: Set<AgentStudioTraceTag>,
        traceName: String,
        proofToken: String?,
        directory: URL,
        flushMode: AgentStudioTraceFlushMode,
        backend: AgentStudioTraceBackend,
        runtimeFlavor: AgentStudioTraceRuntimeFlavor,
        releaseChannel: AppDataPaths.ReleaseChannel,
        otlpEndpoint: URL?,
        otlpProtocol: AgentStudioOTLPProtocol,
        unknownTagSelectors: [String],
        unsupportedBackendSelector: String?,
        rejectedOTLPEndpointSelector: String?,
        unsupportedOTLPProtocolSelector: String?
    ) {
        self.enabledTags = enabledTags
        self.traceName = traceName
        self.proofToken = proofToken
        self.directory = directory
        self.flushMode = flushMode
        self.backend = backend
        self.runtimeFlavor = runtimeFlavor
        self.releaseChannel = releaseChannel
        self.otlpEndpoint = otlpEndpoint
        self.otlpProtocol = otlpProtocol
        self.unknownTagSelectors = unknownTagSelectors
        self.unsupportedBackendSelector = unsupportedBackendSelector
        self.rejectedOTLPEndpointSelector = rejectedOTLPEndpointSelector
        self.unsupportedOTLPProtocolSelector = unsupportedOTLPProtocolSelector
    }

    private static func tagSelection(
        _ rawValue: String?,
        runtimeFlavor: AgentStudioTraceRuntimeFlavor
    ) -> AgentStudioTraceTagSelection {
        guard rawValue == nil else {
            return AgentStudioTraceTag.parseSelection(rawValue)
        }

        switch runtimeFlavor {
        case .debug, .beta:
            return AgentStudioTraceTagSelection(tags: safeDefaultTags, unknownSelectors: [])
        case .stable:
            return AgentStudioTraceTagSelection(tags: [], unknownSelectors: [])
        }
    }

    private static func preferenceTraceTags(_ preferenceLayer: AgentStudioTracePreferenceLayer?) -> String? {
        guard let preferenceLayer else { return nil }
        guard preferenceLayer.enabled == true else { return "off" }
        return nonEmptyString(preferenceLayer.traceTags) ?? "*"
    }

    private static func preferenceTraceBackend(_ preferenceLayer: AgentStudioTracePreferenceLayer?) -> String? {
        guard let preferenceLayer else { return nil }
        return nonEmptyString(preferenceLayer.traceBackend) ?? (preferenceLayer.enabled == true ? "otlp" : nil)
    }

    private static func preferenceTraceFlush(_ preferenceLayer: AgentStudioTracePreferenceLayer?) -> String? {
        guard let preferenceLayer else { return nil }
        return nonEmptyString(preferenceLayer.traceFlush) ?? (preferenceLayer.enabled == true ? "buffered" : nil)
    }

    private static func nonEmptyString(_ rawValue: String?) -> String? {
        guard let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedValue.isEmpty else {
            return nil
        }
        return trimmedValue
    }

    private static func defaultBackend(runtimeFlavor: AgentStudioTraceRuntimeFlavor) -> AgentStudioTraceBackend {
        switch runtimeFlavor {
        case .debug, .beta:
            return .both
        case .stable:
            return .jsonl
        }
    }

    private static func effectiveBackend(
        selectedBackend: AgentStudioTraceBackend,
        isTracingEnabled: Bool,
        isOTLPEndpointAvailable: Bool,
        isProtocolSupported: Bool
    ) -> AgentStudioTraceBackend {
        guard isTracingEnabled else {
            return .jsonl
        }

        guard selectedBackend.includesOTLP else {
            return selectedBackend
        }

        guard isOTLPEndpointAvailable, isProtocolSupported else {
            return .jsonl
        }

        return selectedBackend
    }

    private static func sanitizedTraceName(_ rawValue: String?) -> String {
        let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedValue, !trimmedValue.isEmpty else {
            return "trace"
        }

        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = trimmedValue.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "trace" : sanitized
    }

    private static func sanitizedProofToken(_ rawValue: String?) -> String? {
        let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedValue, !trimmedValue.isEmpty else { return nil }

        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = trimmedValue.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? nil : sanitized
    }

    private static func traceDirectory(_ rawValue: String?) -> URL {
        let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedValue, !trimmedValue.isEmpty else {
            return Self.defaultDirectory
        }
        return URL(fileURLWithPath: NSString(string: trimmedValue).expandingTildeInPath, isDirectory: true)
    }

    private static func otlpEndpointSelection(
        _ rawValue: String?,
        environment: [String: String],
        backend: AgentStudioTraceBackend,
        isTracingEnabled: Bool,
        isProtocolSupported: Bool
    ) -> (url: URL?, rejectedSelector: String?) {
        guard isTracingEnabled, backend.includesOTLP, isProtocolSupported else {
            return (nil, nil)
        }

        // swift-otel 1.0.5 reapplies process-environment overrides when each
        // backend is created. A signal override can replace the shared endpoint.
        for signal in ["LOGS", "METRICS", "TRACES"] {
            guard let signalEndpoint = environment["OTEL_EXPORTER_OTLP_\(signal)_ENDPOINT"] else { continue }
            guard let url = URL(string: signalEndpoint), isLoopbackHTTPEndpoint(url) else {
                return (nil, signalEndpoint)
            }
        }

        let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointURL: URL
        let rejectedSelector: String?
        if let trimmedValue, !trimmedValue.isEmpty {
            guard let url = URL(string: trimmedValue), isLoopbackHTTPEndpoint(url) else {
                return (nil, trimmedValue)
            }
            endpointURL = url
            rejectedSelector = nil
        } else {
            endpointURL = defaultOTLPEndpoint
            rejectedSelector = nil
        }

        return (endpointURL, rejectedSelector)
    }

    private static func isLoopbackHTTPEndpoint(_ url: URL) -> Bool {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "http",
            let host = url.host(percentEncoded: false)?.lowercased()
        else { return false }

        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

}

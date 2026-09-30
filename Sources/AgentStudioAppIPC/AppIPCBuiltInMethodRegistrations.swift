import AgentStudioProgrammaticControl
import Foundation

package struct AppIPCBuiltInRegistrationInputs: Sendable {
    package let catalog: IPCBuiltInMethodCatalog
    package let runtimeId: UUID
    package let ports: AgentStudioAppIPCPorts
    package let eventBroker: IPCEventBroker

    package init(
        catalog: IPCBuiltInMethodCatalog,
        runtimeId: UUID,
        ports: AgentStudioAppIPCPorts,
        eventBroker: IPCEventBroker
    ) {
        self.catalog = catalog
        self.runtimeId = runtimeId
        self.ports = ports
        self.eventBroker = eventBroker
    }

    package func descriptorRepresentations<Parameters, Result>(
        for descriptor: IPCMethodDescriptor<Parameters, Result>
    ) throws -> IPCMethodDescriptorRepresentations<Parameters, Result>
    where Parameters: Codable & Sendable, Result: Codable & Sendable {
        try catalog.descriptorRepresentations(for: descriptor)
    }
}

package enum AppIPCBuiltInMethodRegistrations {
    package static func make(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        try
            (systemAndQueryRegistrations(inputs: inputs)
            + layoutAndTerminalRegistrations(inputs: inputs)
            + bridgeRegistrations(inputs: inputs)
            + presentationAndEventRegistrations(inputs: inputs)
            + sessionRegistrations(inputs: inputs)).sorted {
                $0.descriptor.metadata.name < $1.descriptor.metadata.name
            }
    }
}

enum AppIPCBuiltInRegistrationSupport {
    static func appTarget<Parameters: Sendable>(
        _ parameters: Parameters
    ) -> AppIPCTargetResolution<Parameters> {
        AppIPCTargetResolution(parameters: parameters, canonicalHandle: nil, target: .app)
    }

    static func principalTarget<Parameters: Sendable>(
        _ parameters: Parameters,
        context: AppIPCConnectionContext
    ) throws -> AppIPCTargetResolution<Parameters> {
        guard let principal = context.principal else {
            throw AppIPCTypedMethodRegistrationError.authenticationRequired
        }
        let target: IPCTargetScope
        switch principal.kind {
        case .spawnedPaneAgent(let boundPaneId, _):
            target = .pane(boundPaneId)
        case .automationClient, .futureMCPClient, .unsafeDebugClient:
            target = .app
        }
        return AppIPCTargetResolution(parameters: parameters, canonicalHandle: nil, target: target)
    }

    static func canonicalPaneTarget<Parameters: Sendable>(
        _ parameters: Parameters,
        rawHandle: String,
        tools: AppIPCTargetResolutionTools,
        agentArgumentRule: @Sendable (UUID) -> AppIPCAgentArgumentRule = { _ in .targetOnly },
        replacingHandle: @Sendable (Parameters, String) -> Parameters
    ) async throws -> AppIPCTargetResolution<Parameters> {
        let canonicalHandle = try await tools.canonicalizePaneHandle(rawHandle)
        guard case (.pane, .canonicalUUID(let paneId)) = (canonicalHandle.kind, canonicalHandle.reference) else {
            throw AppIPCTypedMethodRegistrationError.targetKindNotAllowed
        }
        return AppIPCTargetResolution(
            parameters: replacingHandle(parameters, "pane:\(paneId.uuidString)"),
            canonicalHandle: canonicalHandle,
            target: .pane(paneId.uuidString),
            agentArgumentRule: agentArgumentRule(paneId)
        )
    }

    static func validatedBridgePaneTarget<Parameters: Sendable>(
        _ parameters: Parameters,
        rawHandle: String,
        tools: AppIPCTargetResolutionTools,
        queryPort: any AppIPCQueryPort,
        replacingHandle: @Sendable (Parameters, String) -> Parameters
    ) async throws -> AppIPCTargetResolution<Parameters> {
        let resolution = try await canonicalPaneTarget(
            parameters,
            rawHandle: rawHandle,
            tools: tools,
            replacingHandle: replacingHandle
        )
        guard case .pane(let rawPaneId) = resolution.target,
            let paneId = UUID(uuidString: rawPaneId)
        else {
            throw AppIPCTypedMethodRegistrationError.targetKindNotAllowed
        }
        let panes = try await queryPort.listPanes().panes
        guard let pane = panes.first(where: { $0.id == paneId }) else {
            throw AppIPCBridgeError(reason: .targetNotFound)
        }
        guard pane.contentKind == .bridgePanel else {
            throw AppIPCBridgeError(reason: .unsupportedTarget)
        }
        return resolution
    }

    static func canonicalWindowTarget<Parameters: Sendable>(
        _ parameters: Parameters,
        windowId: UUID
    ) -> AppIPCTargetResolution<Parameters> {
        AppIPCTargetResolution(
            parameters: parameters,
            canonicalHandle: IPCHandle(kind: .window, reference: .canonicalUUID(windowId)),
            target: .app
        )
    }

    static func requiredCorrelation(_ correlationId: UUID?) throws -> UUID {
        guard let correlationId else {
            throw AppIPCTypedMethodRegistrationError.correlationMismatch
        }
        return correlationId
    }

    static func duration(seconds: Double) throws -> Duration {
        guard seconds.isFinite, seconds >= 0 else {
            throw AppIPCRuntimeError(reason: .validationRejected)
        }
        let milliseconds = (seconds * 1000).rounded(.up)
        guard milliseconds < Double(Int64.max) else {
            throw AppIPCRuntimeError(reason: .validationRejected)
        }
        return .milliseconds(Int64(milliseconds))
    }
}

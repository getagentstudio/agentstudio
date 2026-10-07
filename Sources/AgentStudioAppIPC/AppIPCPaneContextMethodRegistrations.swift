import AgentStudioProgrammaticControl
import Foundation

package struct AppIPCPaneContextError: Error, Equatable, Sendable {
    package enum Reason: String, Equatable, Sendable {
        case bindingRequired
        case conflict
        case paneGone
        case notSender
        case notOwnPane
        case noticeAlreadyRead
        case tooLarge
        case invalidField
        case stale
        case sourceNotInView
        case unavailable
        case internalError
    }

    package let reason: Reason
    package let field: String?
    package let staleness: IPCPaneWriteStaleness?
    package init(reason: Reason, field: String? = nil, staleness: IPCPaneWriteStaleness? = nil) {
        self.reason = reason
        self.field = field
        self.staleness = staleness
    }

    static func schemaRefusal(_ error: IPCSchemaValidationError) -> Self {
        let components = error.fieldPath.split(separator: ".")
        let field = error.fieldPath.contains(".shape") ? "form" : components.dropFirst().joined(separator: ".")
        return Self(reason: .invalidField, field: field.isEmpty ? nil : field)
    }
}

/// Wire-only boundary. App composition maps these values to PaneContextService
/// and resolves session writer claims through the existing Sessions owner.
package protocol AppIPCPaneContextPort: Sendable {
    func sendMessage(paneId: UUID, params: IPCPaneMessageSendParams) async throws -> IPCPaneMessageSendResult
    func askMessage(
        paneId: UUID, params: IPCPaneMessageAskParams,
        connectionEndCause: @escaping @Sendable () -> AppIPCConnectionEndCause
    ) async throws -> IPCPaneAskOutcome
    func withdrawMessage(paneId: UUID, params: IPCPaneMessageWithdrawParams) async throws
        -> IPCPaneMessageWithdrawResult
    func readChanges(paneId: UUID, params: IPCPaneMessageChangesParams) async throws -> IPCPaneMessageChangesResult
    func setLine(paneId: UUID, params: IPCPaneLineSetParams) async throws -> IPCPaneOrderedWriteResult
    func setTitle(paneId: UUID, params: IPCPaneTitleSetParams) async throws -> IPCPaneOrderedWriteResult
    func claimEpoch(paneId: UUID, params: IPCPaneWriterClaimEpochParams) async throws -> IPCPaneEpochClaimResult
    func readContext(paneId: UUID, params: IPCPaneContextGetParams, replyEnvelopeOverheadBytes: Int) async throws
        -> IPCPaneContextGetResult
}

/// Composition without a service cannot claim to apply pane context writes.
package struct UnavailableAppIPCPaneContextPort: AppIPCPaneContextPort {
    package init() {}
    package func sendMessage(paneId: UUID, params: IPCPaneMessageSendParams) async throws -> IPCPaneMessageSendResult {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
    package func askMessage(
        paneId: UUID, params: IPCPaneMessageAskParams,
        connectionEndCause: @escaping @Sendable () -> AppIPCConnectionEndCause
    ) async throws -> IPCPaneAskOutcome {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
    package func withdrawMessage(paneId: UUID, params: IPCPaneMessageWithdrawParams) async throws
        -> IPCPaneMessageWithdrawResult
    {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
    package func readChanges(paneId: UUID, params: IPCPaneMessageChangesParams) async throws
        -> IPCPaneMessageChangesResult
    {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
    package func setLine(paneId: UUID, params: IPCPaneLineSetParams) async throws -> IPCPaneOrderedWriteResult {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
    package func setTitle(paneId: UUID, params: IPCPaneTitleSetParams) async throws -> IPCPaneOrderedWriteResult {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
    package func claimEpoch(paneId: UUID, params: IPCPaneWriterClaimEpochParams) async throws -> IPCPaneEpochClaimResult
    {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
    package func readContext(paneId: UUID, params: IPCPaneContextGetParams, replyEnvelopeOverheadBytes: Int)
        async throws -> IPCPaneContextGetResult
    {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
}

extension AppIPCBuiltInMethodRegistrations {
    static func paneContextRegistrations(inputs: AppIPCBuiltInRegistrationInputs) throws
        -> [AnyAppIPCMethodRegistration]
    {
        try paneMessageRegistrations(inputs: inputs) + paneContextValueRegistrations(inputs: inputs)
    }

    private static func paneMessageRegistrations(inputs: AppIPCBuiltInRegistrationInputs) throws
        -> [AnyAppIPCMethodRegistration]
    {
        let descriptors = inputs.catalog.paneContext
        let port = inputs.ports.paneContextPort
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.messageSend),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, context, _ in
                    try AppIPCPaneContextTargetSupport.credentialTarget(
                        parameters, handle: parameters.handle, context: context)
                },
                connectionHandler: { parameters, _, target in
                    try await port.sendMessage(
                        paneId: AppIPCSessionTargetSupport.paneId(from: target), params: parameters)
                },
                execution: .inline
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.messageAsk),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, context, _ in
                    try AppIPCPaneContextTargetSupport.credentialTarget(
                        parameters, handle: parameters.handle, context: context)
                },
                connectionHandler: { parameters, context, target in
                    try await port.askMessage(
                        paneId: AppIPCSessionTargetSupport.paneId(from: target), params: parameters,
                        connectionEndCause: { context.connectionEndCause })
                },
                execution: .waitsBesideReader
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.messageWithdraw),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, context, _ in
                    try AppIPCPaneContextTargetSupport.credentialTarget(
                        parameters, handle: parameters.handle, context: context)
                },
                connectionHandler: { parameters, _, target in
                    try await port.withdrawMessage(
                        paneId: AppIPCSessionTargetSupport.paneId(from: target), params: parameters)
                },
                execution: .inline
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.messageChanges),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, context, _ in
                    try AppIPCPaneContextTargetSupport.credentialTarget(
                        parameters, handle: parameters.handle, context: context)
                },
                connectionHandler: { parameters, _, target in
                    try await port.readChanges(
                        paneId: AppIPCSessionTargetSupport.paneId(from: target), params: parameters)
                },
                execution: .inline
            ).erase(),
        ]
    }

    private static func paneContextValueRegistrations(inputs: AppIPCBuiltInRegistrationInputs) throws
        -> [AnyAppIPCMethodRegistration]
    {
        let descriptors = inputs.catalog.paneContext
        let port = inputs.ports.paneContextPort
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.lineSet),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, context, _ in
                    try AppIPCPaneContextTargetSupport.credentialTarget(
                        parameters, handle: parameters.handle, context: context)
                },
                connectionHandler: { parameters, _, target in
                    try await port.setLine(paneId: AppIPCSessionTargetSupport.paneId(from: target), params: parameters)
                },
                execution: .inline
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.titleSet),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, context, _ in
                    try AppIPCPaneContextTargetSupport.credentialTarget(
                        parameters, handle: parameters.handle, context: context)
                },
                connectionHandler: { parameters, _, target in
                    try await port.setTitle(paneId: AppIPCSessionTargetSupport.paneId(from: target), params: parameters)
                },
                execution: .inline
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.writerClaimEpoch),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, context, _ in
                    try AppIPCPaneContextTargetSupport.credentialTarget(
                        parameters, handle: parameters.handle, context: context)
                },
                connectionHandler: { parameters, _, target in
                    try await port.claimEpoch(
                        paneId: AppIPCSessionTargetSupport.paneId(from: target), params: parameters)
                },
                execution: .inline
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.contextGet),
                correlation: .notRequired,
                resolveTarget: { parameters, context, _ in
                    try AppIPCPaneContextTargetSupport.credentialTarget(
                        parameters, handle: parameters.handle, context: context)
                },
                connectionHandler: { parameters, context, target in
                    try await port.readContext(
                        paneId: AppIPCSessionTargetSupport.paneId(from: target), params: parameters,
                        replyEnvelopeOverheadBytes: context.replyEnvelopeOverheadBytes)
                },
                execution: .inline
            ).erase(),
        ]
    }

}

enum AppIPCPaneContextTargetSupport {
    static func credentialTarget<Parameters: Sendable>(
        _ parameters: Parameters, handle: String, context: AppIPCConnectionContext
    ) throws -> AppIPCTargetResolution<Parameters> {
        guard case .spawnedPaneAgent(let boundPaneId, _)? = context.principal?.kind else {
            throw AuthorizationError(reason: .unauthorized)
        }
        guard handle == "self" else { throw AppIPCPaneContextError(reason: .notOwnPane) }
        guard
            let paneId = UUID(uuidString: boundPaneId)
        else { throw AuthorizationError(reason: .unauthorized) }
        return AppIPCTargetResolution(
            parameters: parameters,
            canonicalHandle: IPCHandle(kind: .pane, reference: .canonicalUUID(paneId)),
            target: .pane(paneId.uuidString),
            resolvedPaneIds: [paneId],
            agentArgumentRule: .credentialPaneOnly
        )
    }
}

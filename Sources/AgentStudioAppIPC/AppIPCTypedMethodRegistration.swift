import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

package enum AppIPCTypedMethodRegistrationError: Error, Equatable, Sendable {
    case authenticationRequired
    case methodNotExposed
    case correlationPolicyMismatch
    case correlationMismatch
    case targetKindNotAllowed
    case parameterTransportEncodingFailed
    case resultTransportDecodingFailed
}

package enum AppIPCCorrelation<Parameters: Sendable>: Sendable {
    case notRequired
    case required(@Sendable (Parameters) throws -> UUID)
}

package struct AppIPCTargetResolution<Parameters: Sendable>: Sendable {
    package let parameters: Parameters
    package let canonicalHandle: IPCHandle?
    package let target: IPCTargetScope
    package let requiredScopes: [IPCPermissionScope]
    /// Every pane identity the request names, not only the permission target:
    /// a drawer command names the parent and the child.
    package let resolvedPaneIds: [UUID]
    /// The `command.execute` command, so admission can read its eligibility.
    package let commandId: String?
    package let agentArgumentRule: AppIPCAgentArgumentRule

    package init(
        parameters: Parameters,
        canonicalHandle: IPCHandle?,
        target: IPCTargetScope,
        requiredScopes: [IPCPermissionScope] = [],
        resolvedPaneIds: [UUID]? = nil,
        commandId: String? = nil,
        agentArgumentRule: AppIPCAgentArgumentRule = .targetOnly
    ) {
        self.parameters = parameters
        self.canonicalHandle = canonicalHandle
        self.target = target
        self.requiredScopes = requiredScopes
        self.resolvedPaneIds = resolvedPaneIds ?? Self.paneIds(in: target)
        self.commandId = commandId
        self.agentArgumentRule = agentArgumentRule
    }

    private static func paneIds(in target: IPCTargetScope) -> [UUID] {
        guard case .pane(let rawPaneId) = target, let paneId = UUID(uuidString: rawPaneId) else { return [] }
        return [paneId]
    }
}

package struct AppIPCTargetResolutionTools: Sendable {
    private let paneHandleCanonicalizer: @Sendable (String) async throws -> IPCHandle

    package init(
        canonicalizePaneHandle: @escaping @Sendable (String) async throws -> IPCHandle
    ) {
        self.paneHandleCanonicalizer = canonicalizePaneHandle
    }

    package func canonicalizePaneHandle(_ rawHandle: String) async throws -> IPCHandle {
        try await paneHandleCanonicalizer(rawHandle)
    }
}

package struct AppIPCMethodAuthorizationRequest: Equatable, Sendable {
    package let methodName: String
    package let requiredPrivileges: Set<IPCPrivilegeClass>
    package let dataScope: IPCDataScope
    package let target: IPCTargetScope
    package let additionalScopes: [IPCPermissionScope]
    package let resolvedPaneIds: [UUID]
    package let commandId: String?
    package let agentArgumentRule: AppIPCAgentArgumentRule

    package init(
        methodName: String, requiredPrivileges: Set<IPCPrivilegeClass>, dataScope: IPCDataScope, target: IPCTargetScope,
        additionalScopes: [IPCPermissionScope] = [],
        resolvedPaneIds: [UUID] = [],
        commandId: String? = nil,
        agentArgumentRule: AppIPCAgentArgumentRule = .targetOnly
    ) {
        self.methodName = methodName
        self.requiredPrivileges = requiredPrivileges
        self.dataScope = dataScope
        self.target = target
        self.additionalScopes = additionalScopes
        self.resolvedPaneIds = resolvedPaneIds
        self.commandId = commandId
        self.agentArgumentRule = agentArgumentRule
    }
}

package struct AppIPCTypedMethodRegistration<
    Parameters: Codable & Sendable,
    Result: Codable & Sendable
>: Sendable {
    private let descriptor: IPCMethodDescriptor<Parameters, Result>
    private let validatedErasedDescriptor: IPCAnyMethodDescriptor
    private let correlation: AppIPCCorrelation<Parameters>
    private let cachedTransportResult: AppIPCCachedTransportResult?
    private let prepareAndHandle:
        @Sendable (
            Parameters, UUID?, AppIPCConnectionContext, AppIPCTargetResolutionTools, AppIPCTypedMethodAuthorization
        ) async throws -> AppIPCInvocationResult

    /// Ordinary methods keep their existing typed resolver and use identity preparation.
    package init(
        descriptorRepresentations: IPCMethodDescriptorRepresentations<Parameters, Result>,
        correlation: AppIPCCorrelation<Parameters>,
        resolveTarget:
            @escaping @Sendable (Parameters, AppIPCConnectionContext, AppIPCTargetResolutionTools) async throws ->
            AppIPCTargetResolution<Parameters>,
        connectionHandler:
            @escaping @Sendable (Parameters, AppIPCConnectionContext, IPCTargetScope) async throws -> Result,
        cachedTransportResult: AppIPCCachedTransportResult? = nil
    ) {
        self.init(
            descriptorRepresentations: descriptorRepresentations, correlation: correlation,
            preparedCorrelation: correlation, prepare: { parameters, _, _ in parameters },
            resolveTarget: resolveTarget, connectionHandler: connectionHandler,
            cachedTransportResult: cachedTransportResult)
    }

    /// Wire parameters become a typed prepared value without introducing a
    /// second invocation or authorization path.
    package init<PreparedParameters: Sendable>(
        descriptorRepresentations: IPCMethodDescriptorRepresentations<Parameters, Result>,
        correlation: AppIPCCorrelation<Parameters>,
        preparedCorrelation: AppIPCCorrelation<PreparedParameters>,
        prepare:
            @escaping @Sendable (Parameters, AppIPCConnectionContext, AppIPCTargetResolutionTools)
            async throws(AgentStudioAppIPCRequestError) -> PreparedParameters,
        resolveTarget:
            @escaping @Sendable (PreparedParameters, AppIPCConnectionContext, AppIPCTargetResolutionTools) async throws
            -> AppIPCTargetResolution<PreparedParameters>,
        connectionHandler:
            @escaping @Sendable (PreparedParameters, AppIPCConnectionContext, IPCTargetScope) async throws -> Result,
        cachedTransportResult: AppIPCCachedTransportResult? = nil
    ) {
        let descriptor = descriptorRepresentations.typedDescriptor
        self.descriptor = descriptor
        validatedErasedDescriptor = descriptorRepresentations.erasedDescriptor
        self.correlation = correlation
        self.cachedTransportResult = cachedTransportResult
        prepareAndHandle = { parameters, wireCorrelation, context, tools, authorization in
            switch (descriptor.correlationPolicy, preparedCorrelation) {
            case (.required, .required), (.optional, .notRequired), (.notAccepted, .notRequired): break
            default: throw AppIPCTypedMethodRegistrationError.correlationPolicyMismatch
            }
            let prepared = try await prepare(parameters, context, tools)
            try Self.validateCorrelation(in: prepared, using: preparedCorrelation, matches: wireCorrelation)
            let resolution = try await resolveTarget(prepared, context, tools)
            try Self.validateCorrelation(
                in: resolution.parameters, using: preparedCorrelation, matches: wireCorrelation)
            try Self.validateTarget(resolution.canonicalHandle, allowedKinds: descriptor.allowedTargetKinds)
            if descriptor.principalAvailability == .authenticated {
                guard let principal = context.principal else {
                    throw AppIPCTypedMethodRegistrationError.authenticationRequired
                }
                try await authorization.authorize(
                    principal,
                    request: AppIPCMethodAuthorizationRequest(
                        methodName: descriptor.name, requiredPrivileges: descriptor.requiredPrivileges,
                        dataScope: descriptor.dataScope, target: resolution.target,
                        additionalScopes: resolution.requiredScopes, resolvedPaneIds: resolution.resolvedPaneIds,
                        commandId: resolution.commandId, agentArgumentRule: resolution.agentArgumentRule))
            }
            // Fixed runtime answers retain all access and authorization gates.
            if let cachedTransportResult { return try .encoded(cachedTransportResult.encodedValue()) }
            let result = try await connectionHandler(resolution.parameters, context, resolution.target)
            let encoded = try descriptor.encodeResult(result)
            do { return try .value(JSONDecoder().decode(JSONValue.self, from: encoded)) } catch {
                throw AppIPCTypedMethodRegistrationError.resultTransportDecodingFailed
            }
        }
    }

    package func erase() throws -> AnyAppIPCMethodRegistration {
        try validateCorrelationPolicy()
        return AnyAppIPCMethodRegistration(
            descriptor: validatedErasedDescriptor,
            cachedTransportResult: cachedTransportResult,
            invocation: { parameters, context, tools, authorization in
                try validateConnectionAccess(context)
                let parameterData: Data
                do { parameterData = try JSONEncoder().encode(parameters) } catch {
                    throw AppIPCTypedMethodRegistrationError.parameterTransportEncodingFailed
                }
                let validated = try descriptor.contract.validatedParameters(from: parameterData)
                let wireCorrelation = try normalizedWireCorrelationId(from: validated.json.data)
                try Self.validateCorrelation(in: validated.value, using: correlation, matches: wireCorrelation)
                return try await prepareAndHandle(validated.value, wireCorrelation, context, tools, authorization)
            })
    }

    private func validateConnectionAccess(_ context: AppIPCConnectionContext) throws {
        if descriptor.principalAvailability == .authenticated, context.principal == nil {
            throw AppIPCTypedMethodRegistrationError.authenticationRequired
        }

        guard descriptor.exposure == .debugTesting else {
            return
        }
        guard context.channel == .debug,
            let principal = context.principal,
            hasDiagnosticProvenance(principal)
        else {
            throw AppIPCTypedMethodRegistrationError.methodNotExposed
        }
    }

    private func hasDiagnosticProvenance(_ principal: IPCPrincipal) -> Bool {
        switch (principal.kind, principal.accessMode) {
        case (.automationClient, .automationSameUser),
            (.unsafeDebugClient, .unsafeDebug):
            true
        case (.automationClient, _),
            (.unsafeDebugClient, _),
            (.spawnedPaneAgent, _),
            (.futureMCPClient, _):
            false
        }
    }

    private func validateCorrelationPolicy() throws {
        switch (descriptor.correlationPolicy, correlation) {
        case (.required, .required), (.optional, .notRequired), (.notAccepted, .notRequired):
            return
        case (.required, .notRequired), (.optional, .required), (.notAccepted, .required):
            throw AppIPCTypedMethodRegistrationError.correlationPolicyMismatch
        }
    }

    private func normalizedWireCorrelationId(from normalizedParameters: Data) throws -> UUID? {
        guard descriptor.correlationPolicy == .required else { return nil }
        do {
            return try JSONDecoder().decode(
                AppIPCRequiredCorrelationEnvelope.self,
                from: normalizedParameters
            ).correlationId
        } catch {
            throw AppIPCTypedMethodRegistrationError.correlationMismatch
        }
    }

    private static func validateCorrelation<CheckedParameters: Sendable>(
        in parameters: CheckedParameters, using correlation: AppIPCCorrelation<CheckedParameters>,
        matches normalizedWireCorrelation: UUID?
    ) throws {
        switch correlation {
        case .notRequired:
            return
        case .required(let extractCorrelation):
            guard try extractCorrelation(parameters) == normalizedWireCorrelation else {
                throw AppIPCTypedMethodRegistrationError.correlationMismatch
            }
        }
    }

    private static func validateTarget(_ canonicalHandle: IPCHandle?, allowedKinds: Set<IPCHandleKind>) throws {
        guard let canonicalHandle else {
            guard allowedKinds.isEmpty else {
                throw AppIPCTypedMethodRegistrationError.targetKindNotAllowed
            }
            return
        }

        guard case .canonicalUUID = canonicalHandle.reference,
            allowedKinds.contains(canonicalHandle.kind)
        else {
            throw AppIPCTypedMethodRegistrationError.targetKindNotAllowed
        }
    }
}

package struct AnyAppIPCMethodRegistration: Sendable {
    package let descriptor: IPCAnyMethodDescriptor
    package let cachedTransportResult: AppIPCCachedTransportResult?
    private let invocation:
        @Sendable (
            JSONValue,
            AppIPCConnectionContext,
            AppIPCTargetResolutionTools,
            AppIPCTypedMethodAuthorization
        ) async throws -> AppIPCInvocationResult

    fileprivate init(
        descriptor: IPCAnyMethodDescriptor,
        cachedTransportResult: AppIPCCachedTransportResult?,
        invocation:
            @escaping @Sendable (
                JSONValue,
                AppIPCConnectionContext,
                AppIPCTargetResolutionTools,
                AppIPCTypedMethodAuthorization
            ) async throws -> AppIPCInvocationResult
    ) {
        self.descriptor = descriptor
        self.cachedTransportResult = cachedTransportResult
        self.invocation = invocation
    }

    package func invoke(
        parameters: JSONValue,
        connectionContext: AppIPCConnectionContext,
        targetResolutionTools: AppIPCTargetResolutionTools,
        authorize:
            @escaping @Sendable (
                IPCPrincipal,
                AppIPCMethodAuthorizationRequest
            ) async throws -> Void
    ) async throws -> AppIPCInvocationResult {
        try await invocation(
            parameters,
            connectionContext,
            targetResolutionTools,
            AppIPCTypedMethodAuthorization(authorize: authorize)
        )
    }
}

private struct AppIPCTypedMethodAuthorization: Sendable {
    private let authorization: @Sendable (IPCPrincipal, AppIPCMethodAuthorizationRequest) async throws -> Void

    init(
        authorize:
            @escaping @Sendable (
                IPCPrincipal,
                AppIPCMethodAuthorizationRequest
            ) async throws -> Void
    ) {
        self.authorization = authorize
    }

    func authorize(
        _ principal: IPCPrincipal,
        request: AppIPCMethodAuthorizationRequest
    ) async throws {
        try await authorization(principal, request)
    }
}

private struct AppIPCRequiredCorrelationEnvelope: Decodable {
    let correlationId: UUID
}

/// Ordinary results keep their existing transport projection; fixed runtime
/// results cross the writer boundary as validated bytes without a JSONValue tree.
package enum AppIPCInvocationResult: Sendable {
    case value(JSONValue)
    case encoded(Data)
}

import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

package struct AppIPCMethodRegistry: Sendable {
    package let channel: AgentStudioIPCChannel
    package let capabilities: IPCMethodCatalogResult
    /// The one cache behind `system.capabilities`. Held so a test that drives
    /// the real socket can prove the catalog is composed and encoded once and
    /// served from the stored value thereafter.
    package let capabilitiesTransportResultCache: AppIPCCachedTransportResult
    private let registrationsByName: [String: AnyAppIPCMethodRegistration]
    /// Every method and command this build knows on every channel: names,
    /// exposure and eligibility only, never handlers. It lets a pane agent
    /// hear "not yet allowed" for a recognized name its channel hides.
    private let recognizedMethodsByName: [String: AppIPCRecognizedEntry]
    private let recognizedCommandsById: [String: AppIPCRecognizedEntry]

    package init(
        registrations: [AnyAppIPCMethodRegistration],
        recognizedCommands: [AppIPCRecognizedEntry],
        channel: AgentStudioIPCChannel,
        capabilitiesComposition: IPCSystemCapabilitiesComposition
    ) throws {
        var seenNames: Set<String> = []
        for registration in registrations {
            let name = registration.descriptor.metadata.name
            guard seenNames.insert(name).inserted else {
                throw AppIPCMethodRegistryError.duplicateMethodName(name)
            }
        }
        let available = registrations.filter {
            $0.descriptor.metadata.exposure == .allChannels || channel == .debug
        }
        let availableNames = Set(available.map(\.descriptor.metadata.name))
        let recognizedUnexposedMethods = registrations.map(\.descriptor.metadata)
            .filter { !availableNames.contains($0.name) }
            .map {
                IPCRecognizedUnexposedName(name: $0.name, agentEligibility: $0.agentEligibility ?? .notYetAllowed)
            }
            .sorted { $0.name < $1.name }
        let composition = capabilitiesComposition
        let expectedMethodMetadata =
            (available.map(\.descriptor.metadata) + [composition.erasedDescriptor.metadata]).sorted {
                $0.name < $1.name
            }
        guard composition.result.methods == expectedMethodMetadata,
            composition.result.recognizedUnexposedMethods == recognizedUnexposedMethods
        else {
            throw AppIPCMethodRegistryError.capabilitiesCompositionMismatch
        }
        let capabilityResult = composition.result
        let encodedCapabilityResult = composition.encodedResult
        let capabilitiesTransportResultCache = AppIPCCachedTransportResult {
            try JSONDecoder().decode(
                JSONValue.self, from: encodedCapabilityResult)
        }
        let capabilityRegistration = try AppIPCTypedMethodRegistration(
            descriptorRepresentations: composition.descriptorRepresentations,
            correlation: .notRequired,
            resolveTarget: { parameters, context, _ in
                try AppIPCBuiltInRegistrationSupport.principalTarget(parameters, context: context)
            },
            connectionHandler: { _, _, _ in capabilityResult },
            cachedTransportResult: capabilitiesTransportResultCache
        ).erase()
        self.capabilitiesTransportResultCache = capabilitiesTransportResultCache
        self.channel = channel
        self.capabilities = composition.result
        self.registrationsByName = Dictionary(
            uniqueKeysWithValues: (available + [capabilityRegistration]).map { ($0.descriptor.metadata.name, $0) }
        )
        self.recognizedMethodsByName = Dictionary(
            uniqueKeysWithValues: (registrations + [capabilityRegistration]).map {
                ($0.descriptor.metadata.name, AppIPCRecognizedEntry(metadata: $0.descriptor.metadata))
            }
        )
        var recognizedCommandsById: [String: AppIPCRecognizedEntry] = [:]
        for command in recognizedCommands {
            guard recognizedCommandsById.updateValue(command, forKey: command.name) == nil else {
                throw AppIPCMethodRegistryError.duplicateCommandIdentifier(command.name)
            }
        }
        self.recognizedCommandsById = recognizedCommandsById
    }

    package func registration(named methodName: String) -> AnyAppIPCMethodRegistration? {
        registrationsByName[methodName]
    }

    package func recognizesMethod(named methodName: String) -> Bool {
        recognizedMethodsByName[methodName] != nil
    }

    /// The command's agent eligibility on this channel. A command this channel
    /// hides, or one this build does not know, is not yet allowed.
    package func commandAgentEligibility(_ commandId: String) -> IPCAgentEligibility {
        guard let command = recognizedCommandsById[commandId], command.isExposed(on: channel) else {
            return .notYetAllowed
        }
        return command.agentEligibility ?? .notYetAllowed
    }

    /// Routing admission for a pane agent, before schema validation: a
    /// recognized method or command that this channel hides or that is not yet
    /// allowed is refused by name, with no effect. An unknown method stays
    /// method-not-found and an unknown command reaches the command adapter's
    /// existing unknown-command outcome.
    package func paneAgentRoutingRefusal(methodName: String, parameters: JSONValue?) -> AuthorizationError? {
        guard let method = recognizedMethodsByName[methodName],
            let eligibility = method.agentEligibility
        else { return nil }
        guard method.isExposed(on: channel), eligibility != .notYetAllowed else {
            return .notYetAllowed(methodName)
        }
        guard methodName == AppIPCMethodNames.commandExecute,
            case .object(let fields)? = parameters,
            case .string(let commandId)? = fields["commandId"],
            recognizedCommandsById[commandId] != nil,
            commandAgentEligibility(commandId) == .notYetAllowed
        else { return nil }
        return .notYetAllowed(commandId)
    }
}

/// One recognized method or command: enough to refuse a pane agent by name
/// without reaching a handler.
package struct AppIPCRecognizedEntry: Equatable, Sendable {
    package let name: String
    package let exposure: IPCMethodExposure
    /// `nil` for an established Agent IPC v2 method.
    package let agentEligibility: IPCAgentEligibility?

    package init(name: String, exposure: IPCMethodExposure, agentEligibility: IPCAgentEligibility?) {
        self.name = name
        self.exposure = exposure
        self.agentEligibility = agentEligibility
    }

    init(metadata: IPCMethodCatalogEntry) {
        self.init(name: metadata.name, exposure: metadata.exposure, agentEligibility: metadata.agentEligibility)
    }

    func isExposed(on channel: AgentStudioIPCChannel) -> Bool {
        exposure == .allChannels || channel == .debug
    }
}

package enum AppIPCMethodNames {
    package static let commandExecute = "command.execute"
}

package enum AppIPCMethodRegistryError: Error, Equatable, Sendable {
    case duplicateMethodName(String)
    case duplicateCommandIdentifier(String)
    case capabilitiesCompositionMismatch
}

public struct AuthorizationError: Error, Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case methodNotFound
        case unauthorized
        case noBoundPane
        case missingGrant
        /// A pane agent named a method, command or target outside this
        /// layer's own-pane set.
        case notYetAllowed
        /// A pane agent asked for an effect agents are never allowed, such as
        /// closing its own pane or putting Bridge content into a drawer.
        case refusedForAgent
    }

    public let reason: Reason
    public let requiredScope: IPCPermissionScope?
    /// The method or command the refusal names, for the agent outcomes.
    public let refusedName: String?

    public init(reason: Reason, requiredScope: IPCPermissionScope? = nil, refusedName: String? = nil) {
        self.reason = reason
        self.requiredScope = requiredScope
        self.refusedName = refusedName
    }

    package static func notYetAllowed(_ name: String) -> Self {
        Self(reason: .notYetAllowed, refusedName: name)
    }

    package static func refusedForAgent(_ name: String) -> Self {
        Self(reason: .refusedForAgent, refusedName: name)
    }
}

public final class GrantLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var grantsByPrincipalId: [UUID: Set<IPCPermissionScope>] = [:]
    private var permissionRecordsById: [UUID: PermissionRecord] = [:]

    public init() {}

    public func grant(_ scope: IPCPermissionScope, to principalId: UUID) {
        lock.withLock {
            _ = grantsByPrincipalId[principalId, default: []].insert(scope)
        }
    }

    public func contains(_ scope: IPCPermissionScope, for principalId: UUID) -> Bool {
        lock.withLock {
            grantsByPrincipalId[principalId, default: []].contains(scope)
        }
    }

    public func revokeAll(for principalId: UUID) {
        lock.withLock {
            _ = grantsByPrincipalId.removeValue(forKey: principalId)
        }
    }

    public func revokeAll() {
        lock.withLock {
            grantsByPrincipalId.removeAll(keepingCapacity: false)
        }
    }

    public func recordPermissionRequest(_ record: PermissionRecord) {
        lock.withLock {
            permissionRecordsById[record.requestId] = record
        }
    }

    public func permissionRecord(requestId: UUID) -> PermissionRecord? {
        lock.withLock {
            permissionRecordsById[requestId]
        }
    }

    public func updatePermissionRecord(_ record: PermissionRecord) {
        lock.withLock {
            permissionRecordsById[record.requestId] = record
        }
    }

    public func permissionRecords() -> [PermissionRecord] {
        lock.withLock {
            Array(permissionRecordsById.values)
        }
    }

    public func resolvePendingPermissionRecord(
        requestId: UUID,
        approver: IPCPrincipal,
        decision: ApprovalPolicyDecision,
        canApprove: (PermissionRecord) -> Bool
    ) throws -> PermissionRecord {
        try lock.withLock {
            guard decision == .approve || decision == .deny else {
                throw PermissionBrokerError(reason: .unsupportedResolutionDecision)
            }
            guard let record = permissionRecordsById[requestId] else {
                throw PermissionBrokerError(reason: .requestNotFound)
            }
            guard record.state == .pending else {
                throw PermissionBrokerError(reason: .requestNotPending)
            }
            guard record.requesterPrincipalId != approver.principalId else {
                throw PermissionBrokerError(reason: .selfApprovalNotAllowed)
            }
            guard record.approvalRoute == .delegatedPrincipal(approver.principalId),
                canApprove(record)
            else {
                throw PermissionBrokerError(reason: .unauthorizedApprover)
            }

            let state: IPCPermissionRequestState = decision == .approve ? .granted : .denied
            let resolvedRecord = record.replacingState(state)
            permissionRecordsById[requestId] = resolvedRecord
            if state == .granted {
                _ = grantsByPrincipalId[record.requesterPrincipalId, default: []].insert(record.requestedScope)
            } else {
                grantsByPrincipalId[record.requesterPrincipalId]?.remove(record.requestedScope)
            }
            return resolvedRecord
        }
    }
}

public struct PermissionScopeCanonicalizer: Sendable {
    public init() {}

    public func canonicalize(_ scope: IPCPermissionScope, for principal: IPCPrincipal) throws -> IPCPermissionScope {
        let target: IPCTargetScope
        switch scope.target {
        case .selfPane:
            guard let boundPaneId = principal.boundPaneId else {
                throw AuthorizationError(reason: .noBoundPane)
            }
            target = .pane(boundPaneId)
        case .pane, .workspace, .app:
            target = scope.target
        }

        return IPCPermissionScope(
            privilege: scope.privilege,
            target: target,
            dataScope: scope.dataScope == .unspecified
                ? Self.dataScope(for: scope.privilege)
                : scope.dataScope
        )
    }

    public static func dataScope(for privilege: IPCPrivilegeClass) -> IPCDataScope {
        switch privilege {
        case .systemRead, .workspaceRead:
            .unspecified
        case .paneContextRead, .layoutMutate:
            .paneContext
        case .bridgeRead, .bridgeControl:
            .bridgeReviewPackage
        case .bridgeContentRead:
            .bridgeContent
        case .bridgeTelemetryRead, .bridgeTelemetryFlush:
            .bridgeTelemetry
        case .uiPresent:
            .uiSurface
        case .terminalRead, .terminalSnapshotRead:
            .terminalSnapshot
        case .terminalWrite, .terminalInputWrite:
            .terminalInput
        case .terminalStatusRead:
            .terminalStatus
        case .terminalWait:
            .terminalWait
        case .eventsRead, .permissionRequest, .permissionRead, .grantApprove:
            .permissionState
        case .appCommandExecute:
            .unspecified
        case .sidebarStateMutate:
            .sidebarState
        case .sessionReportWrite:
            .sessionReport
        case .sessionStateRead:
            .sessionState
        case .debugUnsafe:
            .unspecified
        }
    }
}

public struct AuthorizationService: Sendable {
    private let methodRegistry: AppIPCMethodRegistry
    private let grantLedger: GrantLedger
    private let canonicalizer: PermissionScopeCanonicalizer
    private let paneAgentAuthorization: AppIPCPaneAgentAuthorization

    package init(
        methodRegistry: AppIPCMethodRegistry,
        grantLedger: GrantLedger,
        canonicalizer: PermissionScopeCanonicalizer,
        ownPaneScopePort: any AppIPCOwnPaneScopePort,
        agentAuthorizationTelemetry: any AppIPCAgentAuthorizationTelemetry
    ) {
        self.methodRegistry = methodRegistry
        self.grantLedger = grantLedger
        self.canonicalizer = canonicalizer
        self.paneAgentAuthorization = AppIPCPaneAgentAuthorization(
            methodRegistry: methodRegistry, ownPaneScopePort: ownPaneScopePort,
            telemetry: agentAuthorizationTelemetry)
    }

    /// A pane agent's routing admission, before schema validation; see
    /// `AppIPCMethodRegistry.paneAgentRoutingRefusal`.
    package func paneAgentRoutingRefusal(methodName: String, parameters: JSONValue?) -> AuthorizationError? {
        paneAgentAuthorization.routingRefusal(methodName: methodName, parameters: parameters)
    }

    package func authorize(principal: IPCPrincipal, request: AppIPCMethodAuthorizationRequest) async throws {
        guard let registration = methodRegistry.registration(named: request.methodName) else {
            throw AuthorizationError(reason: .methodNotFound)
        }
        let metadata = registration.descriptor.metadata
        guard Set(metadata.requiredPrivileges) == request.requiredPrivileges,
            metadata.dataScope == request.dataScope
        else {
            throw AuthorizationError(reason: .unauthorized)
        }
        if isDiagnostic(principal), methodRegistry.channel == .debug {
            return
        }
        // A declared eligibility replaces the privilege baseline for pane
        // agents; there is no fallback to it. Established v2 methods declare
        // none and keep the path below unchanged.
        if case .spawnedPaneAgent(let boundPaneId, _) = principal.kind,
            let eligibility = metadata.agentEligibility
        {
            try await paneAgentAuthorization.authorize(
                boundPaneId: boundPaneId, methodEligibility: eligibility, request: request)
            return
        }
        guard metadata.exposure == .allChannels else { throw AuthorizationError(reason: .unauthorized) }
        for privilege in request.requiredPrivileges {
            try authorize(
                principal: principal,
                scope: IPCPermissionScope(
                    privilege: privilege, target: request.target, dataScope: request.dataScope
                ))
        }
        for scope in request.additionalScopes {
            try authorize(principal: principal, scope: scope)
        }
    }

    private func isDiagnostic(_ principal: IPCPrincipal) -> Bool {
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

    public func authorize(
        principal: IPCPrincipal,
        scope: IPCPermissionScope
    ) throws {
        let canonicalScope = try canonicalizer.canonicalize(scope, for: principal)

        if baselineAllows(canonicalScope, for: principal) {
            return
        }

        if canonicalScope.privilege == .debugUnsafe {
            throw AuthorizationError(reason: .unauthorized)
        }

        if grantLedger.contains(canonicalScope, for: principal.principalId) {
            return
        }

        throw AuthorizationError(reason: .missingGrant, requiredScope: canonicalScope)
    }

    private func baselineAllows(_ scope: IPCPermissionScope, for principal: IPCPrincipal) -> Bool {
        if scope.privilege == .grantApprove, principal.hasApprovalAuthority {
            return true
        }

        guard let boundPaneId = principal.boundPaneId, scope.target == .pane(boundPaneId) else {
            return false
        }

        return Self.baselineSelfPanePrivileges.contains(scope.privilege)
    }

    private static let baselineSelfPanePrivileges: Set<IPCPrivilegeClass> = [
        .eventsRead,
        .paneContextRead,
        .bridgeRead,
        .bridgeContentRead,
        .bridgeControl,
        .bridgeTelemetryRead,
        .bridgeTelemetryFlush,
        .permissionRead,
        .permissionRequest,
        .sessionReportWrite,
        .sessionStateRead,
        .systemRead,
        .terminalInputWrite,
        .terminalSnapshotRead,
        .terminalStatusRead,
        .terminalWait,
    ]

}

extension IPCPrincipal {
    fileprivate var boundPaneId: String? {
        switch kind {
        case .spawnedPaneAgent(let boundPaneId, _):
            boundPaneId
        case .automationClient, .futureMCPClient, .unsafeDebugClient:
            nil
        }
    }

    fileprivate var hasApprovalAuthority: Bool {
        switch approvalAuthority {
        case .delegatedApprover(let scopes), .policyConfigured(let scopes):
            !scopes.isEmpty
        case .noApprovalAuthority:
            false
        }
    }
}

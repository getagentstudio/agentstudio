import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

struct TypedConnectionRegistrationFixture {
    let contextId = UUIDv7.generate()
    let runtimeId = UUIDv7.generate()
    let paneId = UUIDv7.generate()

    var panePrincipal: IPCPrincipal {
        IPCPrincipal(
            principalId: UUIDv7.generate(),
            runtimeId: runtimeId,
            accessMode: .agentStudioOnly,
            kind: .spawnedPaneAgent(boundPaneId: paneId.uuidString, boundWorkspaceId: nil),
            approvalAuthority: .noApprovalAuthority
        )
    }

    var diagnosticPrincipal: IPCPrincipal {
        IPCPrincipal(
            principalId: UUIDv7.generate(),
            runtimeId: runtimeId,
            accessMode: .automationSameUser,
            kind: .automationClient,
            approvalAuthority: .noApprovalAuthority
        )
    }

    var unsafeDebugPrincipal: IPCPrincipal {
        IPCPrincipal(
            principalId: UUIDv7.generate(),
            runtimeId: runtimeId,
            accessMode: .unsafeDebug,
            kind: .unsafeDebugClient,
            approvalAuthority: .noApprovalAuthority
        )
    }

    var automationUnsafeHybridPrincipal: IPCPrincipal {
        IPCPrincipal(
            principalId: UUIDv7.generate(),
            runtimeId: runtimeId,
            accessMode: .unsafeDebug,
            kind: .automationClient,
            approvalAuthority: .noApprovalAuthority
        )
    }

    var unsafeAutomationHybridPrincipal: IPCPrincipal {
        IPCPrincipal(
            principalId: UUIDv7.generate(),
            runtimeId: runtimeId,
            accessMode: .automationSameUser,
            kind: .unsafeDebugClient,
            approvalAuthority: .noApprovalAuthority
        )
    }

    var futureMCPPrincipal: IPCPrincipal {
        IPCPrincipal(
            principalId: UUIDv7.generate(),
            runtimeId: runtimeId,
            accessMode: .automationSameUser,
            kind: .futureMCPClient,
            approvalAuthority: .noApprovalAuthority
        )
    }

    func context(
        channel: AgentStudioIPCChannel,
        principal: IPCPrincipal?,
        authenticate: @escaping @Sendable (IPCAuthLoginParams) async throws -> IPCAuthStatusResult = { _ in
            .unauthenticated
        },
        authenticationStatus: @escaping @Sendable () -> IPCAuthStatusResult = {
            .unauthenticated
        },
        eventSubscriber: any IPCEventSubscriber = TypedConnectionRecordingEventSubscriber()
    ) -> AppIPCConnectionContext {
        AppIPCConnectionContext(
            contextId: contextId,
            channel: channel,
            authenticatedContext: principal.map {
                AgentStudioIPCAuthenticatedContext(
                    principal: $0,
                    credentialIdentity: credentialIdentity(for: $0)
                )
            },
            authenticate: authenticate,
            authenticationStatus: authenticationStatus,
            eventSubscriber: eventSubscriber
        )
    }

    private func credentialIdentity(
        for principal: IPCPrincipal
    ) -> AgentStudioIPCAuthenticatedCredentialIdentity {
        switch principal.kind {
        case .spawnedPaneAgent:
            return .pane(recordID: UUIDv7.generate())
        case .automationClient, .futureMCPClient, .unsafeDebugClient, .paneClaim:
            return .diagnostic(generationID: UUIDv7.generate())
        }
    }

    var unusedTargetResolutionTools: AppIPCTargetResolutionTools {
        .init(canonicalizePaneHandle: { _ in
            Issue.record("Target resolution tools must not be called")
            throw TypedConnectionRegistrationFailure()
        })
    }

    func canonicalPaneTargetResolutionTools(
        recorder: TypedConnectionRegistrationRecorder
    ) -> AppIPCTargetResolutionTools {
        .init(canonicalizePaneHandle: { rawHandle in
            #expect(rawHandle == "pane:1")
            await recorder.record(.canonicalizeTarget)
            return IPCHandle(kind: .pane, reference: .canonicalUUID(paneId))
        })
    }

    static func preAuthenticationDescriptor<Parameters, Result>(
        name: String,
        parameters: Parameters,
        result: Result
    ) throws -> IPCMethodDescriptor<Parameters, Result>
    where Parameters: IPCSchemaProviding, Result: IPCSchemaProviding {
        try IPCMethodDescriptor(
            name: name,
            description: "Exercise a connection-local pre-authentication binding.",
            examples: [.init(description: "Pre-authentication example", parameters: parameters, result: result)],
            exposure: .allChannels,
            requiredPrivileges: [.systemRead],
            dataScope: .unspecified,
            allowedTargetKinds: [],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .queryReader,
            principalAvailability: .preAuthentication,
            resultSemantics: .applied,
            documentedErrors: [],
            isMutating: false,
            correlationPolicy: .notAccepted
        )
    }

    static func authenticatedDescriptor(
        exposure: IPCMethodExposure = .allChannels
    ) throws -> IPCMethodDescriptor<TypedConnectionParameters, TypedConnectionResult> {
        try IPCMethodDescriptor(
            name: "fixture.connectionMutation",
            description: "Exercise authenticated connection-context admission.",
            examples: [],
            exposure: exposure,
            requiredPrivileges: [.layoutMutate],
            dataScope: .paneContext,
            allowedTargetKinds: [.pane],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .workspaceAction,
            principalAvailability: .authenticated,
            resultSemantics: .applied,
            documentedErrors: [],
            isMutating: true,
            correlationPolicy: .required
        )
    }

    static func eventDescriptor() throws
        -> IPCMethodDescriptor<TypedConnectionEventParameters, TypedConnectionEventResult>
    {
        try IPCMethodDescriptor(
            name: "events.fixture",
            description: "Exercise the connection-owned event subscriber seam.",
            examples: [],
            exposure: .allChannels,
            requiredPrivileges: [.eventsRead],
            dataScope: .permissionState,
            allowedTargetKinds: [],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .eventReader,
            principalAvailability: .authenticated,
            resultSemantics: .accepted,
            documentedErrors: [],
            isMutating: false,
            correlationPolicy: .notAccepted
        )
    }
}

struct TypedConnectionParameters: Codable, Equatable, Sendable, IPCSchemaProviding {
    let handle: String
    let correlationId: UUID

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "handle", description: "Pane handle", schema: .string(minimumLength: 1)),
            .init(name: "correlationId", description: "Logical request identity", schema: IPCSchemaScalars.uuid),
        ])
    }
}

struct TypedConnectionResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    let canonicalHandle: String

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "canonicalHandle", description: "Canonical pane handle", schema: .string(minimumLength: 1))
        ])
    }
}

struct TypedConnectionEventParameters: Codable, Equatable, Sendable, IPCSchemaProviding {
    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [])
    }
}

struct TypedConnectionEventResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    let delivered: Bool

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "delivered", description: "Event delivery completed", schema: .boolean)
        ])
    }
}

actor TypedConnectionRegistrationRecorder {
    private var stages: [TypedConnectionRegistrationStage] = []

    func record(_ stage: TypedConnectionRegistrationStage) {
        stages.append(stage)
    }

    func snapshot() -> [TypedConnectionRegistrationStage] {
        stages
    }
}

enum TypedConnectionRegistrationStage: Equatable, Sendable {
    case resolveTarget
    case canonicalizeTarget
    case authorize(IPCPrincipal)
    case handler(contextId: UUID, principal: IPCPrincipal, target: IPCTargetScope)
}

actor TypedConnectionRecordingEventSubscriber: IPCEventSubscriber {
    private var frames: [String] = []

    func deliver(_ frame: String) -> IPCEventDeliveryResult {
        frames.append(frame)
        return .delivered
    }

    func snapshot() -> [String] {
        frames
    }
}

struct TypedConnectionRegistrationFailure: Error {}

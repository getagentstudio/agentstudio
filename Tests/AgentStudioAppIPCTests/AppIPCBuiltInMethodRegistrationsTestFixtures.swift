import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

struct BuiltInMethodRegistrationsFixture {
    let runtimeId = UUIDv7.generate()
    let windowId = UUIDv7.generate()
    let workspaceId = UUIDv7.generate()
    let repositoryId = UUIDv7.generate()
    let worktreeId = UUIDv7.generate()
    let tabId = UUIDv7.generate()
    let paneId = UUIDv7.generate()
    let commandId = UUIDv7.generate()
    let correlationId = UUIDv7.generate()
    let subscriptionId = UUIDv7.generate()
    let connectionId = UUIDv7.generate()

    var diagnosticPrincipal: IPCPrincipal {
        IPCPrincipal(
            principalId: UUIDv7.generate(),
            runtimeId: runtimeId,
            accessMode: .automationSameUser,
            kind: .automationClient,
            approvalAuthority: .noApprovalAuthority
        )
    }

    var catalog: IPCBuiltInMethodCatalog {
        get throws {
            try IPCBuiltInMethodCatalog(
                inputs: IPCBuiltInMethodCatalogInputs(
                    terminalWaitMaximumSeconds: 10,
                    relationships: IPCBuiltInMethodRelationshipInputs(
                        paneFocus: .noInteractiveIdentity,
                        paneClose: .noInteractiveIdentity,
                        drawerToggle: .noInteractiveIdentity,
                        drawerAddPane: .noInteractiveIdentity,
                        bridgeDiffLoad: .noInteractiveIdentity,
                        bridgeFileViewOpen: .noInteractiveIdentity
                    ),
                    examples: IPCBuiltInMethodExampleContext(
                        runtimeId: runtimeId,
                        windowId: windowId,
                        workspaceId: workspaceId,
                        repositoryId: repositoryId,
                        worktreeId: worktreeId,
                        tabId: tabId,
                        paneId: paneId,
                        commandId: commandId,
                        correlationId: correlationId,
                        subscriptionId: subscriptionId
                    )
                )
            )
        }
    }

    func registrations(
        queryPort: (any AppIPCQueryPort)? = nil,
        layoutPort: any AppIPCLayoutPort = FakeLayoutPort(),
        runtimePort: any AppIPCRuntimePort = FakeRuntimePort(),
        bridgePort: (any AppIPCBridgePort)? = nil,
        uiPresentationPort: (any AppIPCUIPresentationPort)? = nil,
        sessionsPort: (any AppIPCSessionsPort)? = nil,
        eventBroker: IPCEventBroker = IPCEventBroker()
    ) throws -> [AnyAppIPCMethodRegistration] {
        try AppIPCBuiltInMethodRegistrations.make(
            inputs: AppIPCBuiltInRegistrationInputs(
                catalog: catalog,
                runtimeId: runtimeId,
                ports: AgentStudioAppIPCPorts(
                    queryPort: queryPort ?? FakeQueryPort(runtimeId: runtimeId),
                    layoutPort: layoutPort,
                    runtimePort: runtimePort,
                    bridgePort: bridgePort ?? FakeBridgePort(paneId: paneId),
                    commandPort: FakeCommandPort(),
                    uiPresentationPort: uiPresentationPort
                        ?? FakeUIPresentationPort(
                            workspaceWindowId: windowId,
                            arrangementTabId: tabId,
                            arrangementContextPaneId: paneId
                        ),
                    sidebarPort: FakeSidebarPort(),
                    sessionsPort: sessionsPort ?? RecordingSessionsPort(),
                    permissionApprovalPort: FakePermissionApprovalPort(),
                    ownPaneScopePort: StaticOwnPaneScopePort(),
                    agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
                ),
                eventBroker: eventBroker
            )
        )
    }

    func connectionContext(
        principal: IPCPrincipal?,
        channel: AgentStudioIPCChannel = .debug,
        authenticate: @escaping @Sendable (IPCAuthLoginParams) async throws -> IPCAuthStatusResult = { _ in
            .unauthenticated
        },
        authenticationStatus: @escaping @Sendable () -> IPCAuthStatusResult = {
            .unauthenticated
        },
        subscriber: any IPCEventSubscriber = BuiltInRecordingEventSubscriber()
    ) -> AppIPCConnectionContext {
        AppIPCConnectionContext(
            contextId: connectionId,
            channel: channel,
            authenticatedContext: principal.map {
                AgentStudioIPCAuthenticatedContext(
                    principal: $0,
                    credentialIdentity: credentialIdentity(for: $0)
                )
            },
            authenticate: authenticate,
            authenticationStatus: authenticationStatus,
            eventSubscriber: subscriber
        )
    }

    private func credentialIdentity(
        for principal: IPCPrincipal
    ) -> AgentStudioIPCAuthenticatedCredentialIdentity {
        switch principal.kind {
        case .spawnedPaneAgent:
            return .pane(recordID: UUIDv7.generate())
        case .automationClient, .futureMCPClient, .unsafeDebugClient:
            return .diagnostic(generationID: UUIDv7.generate())
        }
    }

    func targetResolutionTools(
        recorder: BuiltInTargetResolutionRecorder? = nil
    ) -> AppIPCTargetResolutionTools {
        AppIPCTargetResolutionTools(canonicalizePaneHandle: { rawHandle in
            await recorder?.record(rawHandle)
            if rawHandle == "self" {
                return IPCHandle(kind: .pane, reference: .canonicalUUID(paneId))
            }
            // The declared pane selector accepts a bare canonical UUID, which
            // the live server resolves through IPCTargetSelector.
            if let canonicalPaneId = UUID(uuidString: rawHandle) {
                return IPCHandle(kind: .pane, reference: .canonicalUUID(canonicalPaneId))
            }
            let parsedHandle = try IPCHandle.parse(rawHandle)
            guard parsedHandle.kind == .pane else {
                throw AppIPCTypedMethodRegistrationError.targetKindNotAllowed
            }
            switch parsedHandle.reference {
            case .canonicalUUID(let requestedPaneId):
                return IPCHandle(kind: .pane, reference: .canonicalUUID(requestedPaneId))
            case .friendlyOrdinal:
                return IPCHandle(kind: .pane, reference: .canonicalUUID(paneId))
            }
        })
    }

    func paneSummary(contentKind: IPCPaneContentKind) -> IPCPaneSummary {
        IPCPaneSummary(
            id: paneId,
            ordinal: 1,
            contentKind: contentKind,
            residency: .active,
            tabId: tabId,
            repoId: repositoryId,
            worktreeId: worktreeId,
            isActive: true,
            isDrawerChild: false
        )
    }

    func registration(
        named methodName: String,
        in registrations: [AnyAppIPCMethodRegistration]
    ) throws -> AnyAppIPCMethodRegistration {
        try #require(registrations.first { $0.descriptor.metadata.name == methodName })
    }

    func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
        try JSONRPCCodec.encodeJSONValue(value)
    }
}

actor BuiltInTargetResolutionRecorder {
    private var rawHandles: [String] = []

    func record(_ rawHandle: String) {
        rawHandles.append(rawHandle)
    }

    func snapshot() -> [String] {
        rawHandles
    }
}

actor BuiltInAuthorizationRecorder {
    private var targets: [IPCTargetScope] = []

    func record(_ target: IPCTargetScope) {
        targets.append(target)
    }

    func snapshot() -> [IPCTargetScope] {
        targets
    }
}

actor BuiltInRecordingEventSubscriber: IPCEventSubscriber {
    private var frames: [String] = []

    func deliver(_ frame: String) -> IPCEventDeliveryResult {
        frames.append(frame)
        return .delivered
    }

    func snapshot() -> [String] {
        frames
    }
}

@MainActor
final class BuiltInRecordingUIPresentationPort: AppIPCUIPresentationPort {
    private(set) var arrangementsParameters: [IPCArrangementsOpenParams] = []
    private let tabId: UUID
    private let paneId: UUID

    init(tabId: UUID, paneId: UUID) {
        self.tabId = tabId
        self.paneId = paneId
    }

    func openCommandBar(_ params: IPCCommandBarOpenParams) throws -> IPCCommandBarOpenResult {
        IPCCommandBarOpenResult(
            workspaceWindowId: params.workspaceWindowId,
            scope: params.scope,
            correlationId: params.correlationId
        )
    }

    func openArrangements(_ params: IPCArrangementsOpenParams) throws -> IPCArrangementsOpenResult {
        arrangementsParameters.append(params)
        return IPCArrangementsOpenResult(
            workspaceWindowId: params.workspaceWindowId,
            tabId: tabId,
            contextPaneId: paneId,
            correlationId: params.correlationId
        )
    }
}

final class BuiltInRecordingTerminalWaitPort: AppIPCRuntimePort, @unchecked Sendable {
    private let paneId: UUID
    private let lock = NSLock()
    nonisolated(unsafe) private var recordedHandle: IPCHandle?
    nonisolated(unsafe) private var recordedTimeout: Duration?
    nonisolated(unsafe) private var recordedAfterSequence: UInt64?

    init(paneId: UUID) {
        self.paneId = paneId
    }

    var invocation: (handle: IPCHandle?, timeout: Duration?, afterSequence: UInt64?) {
        lock.withLock { (recordedHandle, recordedTimeout, recordedAfterSequence) }
    }

    func terminalStatus(_: IPCHandle, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws -> IPCTerminalStatusResult {
        throw BuiltInMethodRegistrationFailure()
    }

    func terminalSnapshot(_: IPCHandle, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws -> IPCTerminalSnapshotResult
    {
        throw BuiltInMethodRegistrationFailure()
    }

    func sendTerminalInput(
        to _: IPCHandle,
        input _: String,
        correlationId _: UUID?,
        ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalSendInputResult {
        throw BuiltInMethodRegistrationFailure()
    }

    func waitForTerminal(
        _ handle: IPCHandle,
        condition: IPCTerminalWaitCondition,
        timeout: Duration,
        afterSequence: UInt64?,
        ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalWaitResult {
        lock.withLock {
            recordedHandle = handle
            recordedTimeout = timeout
            recordedAfterSequence = afterSequence
        }
        return IPCTerminalWaitResult(
            paneId: paneId,
            condition: condition,
            eventName: .terminalTitleChanged,
            commandId: nil,
            correlationId: nil,
            exitCode: nil,
            duration: nil,
            healthy: nil
        )
    }
}

struct BuiltInMethodRegistrationFailure: Error {}

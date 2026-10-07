import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import AgentStudio

#if canImport(Darwin)
    import Darwin
#endif

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

func makeTestAppIPCMethodRegistry(
    registrations: [AnyAppIPCMethodRegistration],
    recognizedCommands: [AppIPCRecognizedEntry],
    channel: AgentStudioIPCChannel
) throws -> AppIPCMethodRegistry {
    try AppIPCMethodRegistry(
        registrations: registrations,
        recognizedCommands: recognizedCommands,
        channel: channel,
        capabilitiesComposition: makeTestIPCSystemCapabilitiesComposition(
            registrations: registrations,
            channel: channel
        )
    )
}

func makeTestIPCSystemCapabilitiesComposition(
    registrations: [AnyAppIPCMethodRegistration],
    channel: AgentStudioIPCChannel
) throws -> IPCSystemCapabilitiesComposition {
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
    guard let ping = available.first(where: { $0.descriptor.metadata.name == "system.ping" }) else {
        throw IPCSystemCapabilitiesCompositionError.illustrativeDescriptorMissing
    }
    return try IPCSystemCapabilitiesDescriptorFactory.compose(
        compatibility: .current,
        availableDescriptors: available.map(\.descriptor),
        illustrativeDescriptor: ping.descriptor,
        recognizedUnexposedMethods: recognizedUnexposedMethods
    )
}

nonisolated(nonsending) func withLiveServer<Result>(
    makeFixture: () throws -> LiveServerFixture,
    releaseHeldWork: @Sendable () async -> Void = {},
    body: (LiveServerFixture) async throws -> Result
) async throws -> Result {
    let fixture = try makeFixture()
    do {
        let result = try await body(fixture)
        await tearDownLiveServer(fixture, releaseHeldWork: releaseHeldWork)
        return result
    } catch {
        await tearDownLiveServer(fixture, releaseHeldWork: releaseHeldWork)
        throw error
    }
}

nonisolated(nonsending) private func tearDownLiveServer(
    _ fixture: LiveServerFixture,
    releaseHeldWork: @Sendable () async -> Void
) async {
    await releaseHeldWork()
    fixture.stopAcceptingConnections()
    await fixture.server.joinConnectionHandlers()
    let result = await fixture.server.drainCredentialPersistence()
    if result.failedOperationCount > 0 {
        Issue.record("Live-server fixture credential persistence drain failed: \(result)")
    }
    do {
        try FileManager.default.removeItem(at: fixture.rootURL)
    } catch {
        Issue.record(error, "Live-server fixture root removal failed")
    }
}

struct LiveServerFixture: Sendable {
    let runtimeId = UUID()
    let boundPaneId = UUID()
    let workspaceId = UUIDv7.generate()
    let rootURL: URL
    let paths: AgentStudioIPCPaths
    let server: LiveServerFixtureServer
    private let testCredentialResolver: IPCFixtureCredentialResolver?

    init(
        accessMode: IPCAccessMode = .agentStudioOnly,
        channel: AgentStudioIPCChannel = .debug,
        panes: [IPCPaneSummary] = [],
        queryPort: (any AppIPCQueryPort)? = nil,
        runtimePort: any AppIPCRuntimePort = FakeRuntimePort(),
        bridgePort: (any AppIPCBridgePort)? = nil,
        commandPort: any AppIPCCommandPort = FakeCommandPort(),
        uiPresentationPort: any AppIPCUIPresentationPort = FakeUIPresentationPort(),
        sidebarPort: any AppIPCSidebarPort = FakeSidebarPort(),
        sessionsPort: any AppIPCSessionsPort = RecordingSessionsPort(),
        commandComposition: IPCCommandMethodComposition? = nil,
        credentialResolver: (any AgentStudioIPCCredentialResolving)? = nil,
        credentialContinuityPort: any AgentStudioIPCCredentialContinuityPort = TestCredentialContinuityPort(),
        canonicalPaneMembership: (@MainActor @Sendable (UUID, UUID) -> Bool)? = nil,
        ownPaneScopes: [AppIPCOwnPaneScope] = [],
        cliStoreReadThroughPort: (any AppIPCCLIStoreReadThroughPort)? = nil
    ) throws {
        let resolvedCredentialResolver = credentialResolver ?? IPCFixtureCredentialResolver()
        testCredentialResolver = resolvedCredentialResolver as? IPCFixtureCredentialResolver
        rootURL = URL(
            fileURLWithPath: "/tmp/asipc-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        #if canImport(Darwin)
            _ = chmod(rootURL.path, 0o700)
        #endif
        // Everything past this point can throw; unwind the created root
        // directory rather than leak it, since a throw here never returns a
        // fixture for the async scope to tear down.
        do {
            paths = AgentStudioIPCPathResolver().paths(rootDirectory: rootURL)
            let ports = AgentStudioAppIPCPorts(
                queryPort: queryPort ?? FakeQueryPort(runtimeId: runtimeId, panes: panes),
                layoutPort: FakeLayoutPort(),
                runtimePort: runtimePort,
                bridgePort: bridgePort ?? FakeBridgePort(paneId: panes.first?.id ?? boundPaneId),
                commandPort: commandPort,
                uiPresentationPort: uiPresentationPort,
                sidebarPort: sidebarPort,
                sessionsPort: sessionsPort,
                permissionApprovalPort: FakePermissionApprovalPort(),
                // Unless a test names scopes, every bound pane is a main-layout
                // terminal with an empty drawer, so its own pane is itself.
                ownPaneScopePort: StaticOwnPaneScopePort(scopes: ownPaneScopes),
                agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
            )
            let eventBroker = IPCEventBroker()
            let catalog = try makeLiveServerBuiltInCatalog(
                runtimeId: runtimeId,
                paneId: panes.first?.id ?? boundPaneId
            )
            var registrations = try AppIPCBuiltInMethodRegistrations.make(
                inputs: AppIPCBuiltInRegistrationInputs(
                    catalog: catalog,
                    runtimeId: runtimeId,
                    ports: ports,
                    eventBroker: eventBroker
                )
            )
            if let commandComposition {
                registrations += try AppIPCCommandMethodRegistrations.make(
                    composition: commandComposition,
                    port: commandPort
                )
            }
            let methodRegistry = try makeTestAppIPCMethodRegistry(
                registrations: registrations,
                recognizedCommands: (commandComposition?.commands ?? []).map {
                    AppIPCRecognizedEntry(
                        name: $0.id.rawValue, exposure: $0.exposure, agentEligibility: $0.agentEligibility)
                },
                channel: channel
            )
            let service = AgentStudioAppIPCService(
                configuration: AgentStudioAppIPCConfiguration(
                    runtimeId: runtimeId,
                    accessMode: accessMode
                ),
                ports: ports,
                methodRegistry: methodRegistry,
                eventBroker: eventBroker
            )
            let fixtureWorkspaceID = workspaceId
            let fixtureBoundPaneID = boundPaneId
            let eligiblePaneIDs = Set(panes.map(\.id))
            let resolvedCanonicalPaneMembership =
                canonicalPaneMembership ?? { candidatePaneID, candidateWorkspaceID in
                    candidateWorkspaceID == fixtureWorkspaceID
                        && (candidatePaneID == fixtureBoundPaneID || eligiblePaneIDs.contains(candidatePaneID))
                }
            let principalRegistry = AgentStudioIPCPrincipalRegistry(
                runtimeId: runtimeId,
                credentialResolver: resolvedCredentialResolver,
                canonicalPaneMembership: resolvedCanonicalPaneMembership
            )
            server = LiveServerFixtureServer(
                AgentStudioAppIPCServer(
                    service: service,
                    paths: paths,
                    channel: channel,
                    principalRegistry: principalRegistry,
                    credentialContinuityPort: credentialContinuityPort,
                    cliStoreReadThroughPort: cliStoreReadThroughPort
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    func issueTestCredential(for intent: IPCFixtureCredentialIntent) throws -> AgentStudioIPCSubjectToken {
        guard let testCredentialResolver else {
            throw IPCFixtureCredentialError.requiresExplicitResolver
        }
        return testCredentialResolver.issueTestCredential(for: intent, workspaceId: workspaceId, runtimeId: runtimeId)
    }

    /// The reusable debug credential has no durable row: the app installs its
    /// verifier in the principal registry for the runtime's lifetime.
    func installDebugCredential() -> AgentStudioIPCSubjectToken {
        let token = AgentStudioIPCSubjectToken(rawValue: "debug-\(UUIDv7.generate().uuidString)")
        _ = server.principalRegistry.installDiagnosticCredential(
            verifierSHA256: Data(SHA256.hash(data: Data(token.rawValue.utf8)))
        )
        return token
    }

    func stop() {
        server.stop()
    }

    func stopAcceptingConnections() {
        server.stopAcceptingConnections()
    }

    @MainActor
    func shutdownThroughApplication(_ appDelegate: AppDelegate) async {
        await server.shutdownThroughApplication(appDelegate)
    }
}

/// The raw owner stays private so even a direct `fixture.server.stop()` goes
/// through the same checkpoint as scope teardown. Joins and drains remain
/// available as behavior-test stimuli; neither can reopen admission.
final class LiveServerFixtureServer: Sendable {
    private let owner: AgentStudioAppIPCServer
    private let hasStopped = Mutex(false)

    init(_ owner: AgentStudioAppIPCServer) {
        self.owner = owner
    }

    var principalRegistry: AgentStudioIPCPrincipalRegistry { owner.principalRegistry }
    var trackedConnectionHandlerCount: Int { owner.trackedConnectionHandlerCount }

    func start(
        processIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        startedAt: Date = Date()
    ) throws {
        try hasStopped.withLock { stopped in
            try owner.start(processIdentifier: processIdentifier, startedAt: startedAt)
            stopped = false
        }
    }

    func stop() {
        hasStopped.withLock { stopped in
            guard !stopped else { return }
            stopped = true
            owner.stop()
        }
    }

    func stopAcceptingConnections() {
        hasStopped.withLock { stopped in
            guard !stopped else { return }
            stopped = true
            owner.stopAcceptingConnections()
        }
    }

    func joinConnectionHandlers() async {
        await owner.joinConnectionHandlers()
    }

    func drainCredentialPersistence() async -> AgentStudioIPCCredentialPersistenceDrainResult {
        await owner.drainCredentialPersistence()
    }

    func invalidatePrincipals(boundToPaneId paneId: String) {
        owner.invalidatePrincipals(boundToPaneId: paneId)
    }

    func finalRevokePrincipals(boundToPaneID paneID: UUID) {
        owner.finalRevokePrincipals(boundToPaneID: paneID)
    }

    @MainActor
    func shutdownThroughApplication(_ appDelegate: AppDelegate) async {
        appDelegate.appIPCServer = owner
        await appDelegate.stopAcceptingAppIPCConnections()
        hasStopped.withLock { $0 = true }
        await appDelegate.drainAppIPCCredentialPersistence()
    }
}

final class TestCredentialContinuityPort: AgentStudioIPCCredentialContinuityPort, @unchecked Sendable {
    func registerIssuedPaneCredential(
        _: AgentStudioIPCIssuedPaneCredential,
        if _: @escaping @Sendable () -> Bool
    ) async throws -> Bool { true }

    func revokeAllPaneCredentials(paneID _: UUID) async throws {}
}

enum IPCFixtureCredentialIntent: Sendable {
    case pane(paneId: UUID, credentialRecordId: UUID, status: AgentStudioIPCPaneCredentialStatus)
}

enum IPCFixtureCredentialError: Error, Equatable {
    case requiresExplicitResolver
}

final class IPCFixtureCredentialResolver: AgentStudioIPCCredentialResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var resolutions: [String: AgentStudioIPCCredentialResolution] = [:]

    func issueTestCredential(
        for intent: IPCFixtureCredentialIntent,
        workspaceId: UUID,
        runtimeId _: UUID
    ) -> AgentStudioIPCSubjectToken {
        let token = AgentStudioIPCSubjectToken(rawValue: "fixture-\(UUIDv7.generate().uuidString)")
        let resolution: AgentStudioIPCCredentialResolution
        switch intent {
        case .pane(let paneId, let credentialRecordId, let status):
            resolution = .pane(
                paneID: paneId,
                workspaceID: workspaceId,
                credentialRecordID: credentialRecordId,
                status: status
            )
        }
        lock.withLock {
            resolutions[token.rawValue] = resolution
        }
        return token
    }

    func resolveCredential(
        _ credential: AgentStudioIPCSubjectToken,
        serverRuntimeID _: UUID
    ) async throws -> AgentStudioIPCCredentialResolution {
        guard let resolution = lock.withLock({ resolutions[credential.rawValue] }) else {
            throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
        }
        return resolution
    }
}

func makePaneSummary(
    id: UUID,
    ordinal: Int,
    contentKind: IPCPaneContentKind = .terminal
) -> IPCPaneSummary {
    IPCPaneSummary(
        id: id,
        ordinal: ordinal,
        contentKind: contentKind,
        residency: .active,
        tabId: nil,
        repoId: nil,
        worktreeId: nil,
        isActive: false,
        isDrawerChild: false
    )
}

func makePaneSnapshotResult(pane: IPCPaneSummary, paneCount: Int) -> IPCPaneSnapshotResult {
    IPCPaneSnapshotResult(
        pane: pane,
        tab: nil,
        workspace: IPCWorkspaceSummary(
            id: UUID(),
            ordinal: 1,
            name: "Test Workspace",
            tabCount: 1,
            paneCount: paneCount,
            isCurrent: true
        )
    )
}

private func makeLiveServerBuiltInCatalog(
    runtimeId: UUID,
    paneId: UUID
) throws -> IPCBuiltInMethodCatalog {
    let illustrativeId = UUIDv7.generate()
    return try IPCBuiltInMethodCatalog(
        inputs: IPCBuiltInMethodCatalogInputs(
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
                windowId: illustrativeId,
                workspaceId: illustrativeId,
                repositoryId: illustrativeId,
                worktreeId: illustrativeId,
                tabId: illustrativeId,
                paneId: paneId,
                commandId: illustrativeId,
                correlationId: illustrativeId,
                subscriptionId: illustrativeId
            )
        )
    )
}

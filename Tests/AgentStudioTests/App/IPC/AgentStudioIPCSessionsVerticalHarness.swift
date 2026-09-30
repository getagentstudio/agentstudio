import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import CryptoKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// Starts the real App IPC server over a temporary socket with a real Sessions
/// database, authenticated by the in-memory debug credential. Session methods need no
/// window, so the harness stops at what the composition itself requires.
@MainActor
struct SessionsVerticalHarness {
    enum Authentication {
        case diagnostic
        case boundPane
    }

    static let qualifiedProvider = IPCSessionProviderIdentity(
        identifier: "vertical-agent",
        version: "1.2.3",
        mode: "interactive"
    )

    let appDelegate: AppDelegate
    let commandHarness: PaneTabViewControllerCommandHarness
    let rootDirectory: URL
    let socketPath: String
    let token: AgentStudioIPCSubjectToken
    let boundPaneToken: AgentStudioIPCSubjectToken?
    let boundPaneId: UUID
    let sparePaneId: UUID
    /// The one registered window, which command arguments must name.
    let workspaceWindowId: UUID

    /// The profile the default provider identity qualifies against.
    static let qualifiedProviderProfile = SessionsProviderProfile(
        providerIdentifier: qualifiedProvider.identifier,
        exactVersion: qualifiedProvider.version,
        operatingMode: qualifiedProvider.mode,
        qualifiedCapabilities: [.sessionStart, .sessionEnd, .turnStart, .turnDone]
    )

    /// Supplying an escrow path exercises the real debug handover: the app mints
    /// the credential, installs its verifier in memory and writes the file the
    /// launcher named. Without one the harness installs a verifier directly,
    /// which is all a session-method test needs.
    static func make(
        providerProfiles: [SessionsProviderProfile] = [qualifiedProviderProfile],
        additionalProviderProfiles: [SessionsProviderProfile] = [],
        debugCredentialEscrowURL: URL? = nil,
        installActivityClock: Bool = false
    ) async throws -> Self {
        let commandHarness = makeHarness()
        let appDelegate = AppDelegate()
        var createdRootDirectory: URL?
        do {
            let boundPane = commandHarness.store.createPane(title: "Bound pane")
            let sparePane = commandHarness.store.createPane(title: "Spare pane")
            commandHarness.store.appendTab(Tab(paneId: boundPane.id))
            commandHarness.store.appendTab(Tab(paneId: sparePane.id))
            // Pane handle canonicalization reads the current window before it
            // resolves a pane, so the harness registers exactly one.
            let workspaceWindowId = UUIDv7.generate()
            commandHarness.windowLifecycleStore.recordWindowRegistered(workspaceWindowId)

            let sqliteFixture = try makeWorkspaceSQLiteBridgeFixture(
                workspaceId: commandHarness.store.identityAtom.workspaceId
            )
            let datastore = try preparedWorkspaceSQLiteDatastore(from: sqliteFixture.backend)
            guard case .ready = await datastore.prepareOptionalApplicationLocalSchema() else {
                throw SessionsVerticalHarnessError.optionalSchemaUnavailable
            }

            appDelegate.store = commandHarness.store
            appDelegate.workspaceSQLiteDatastore = datastore
            appDelegate.windowLifecycleStore = commandHarness.windowLifecycleStore
            appDelegate.atomStore = commandHarness.atomRegistry
            appDelegate.viewRegistry = commandHarness.viewRegistry
            appDelegate.workspaceSurfaceCoordinator = commandHarness.coordinator
            appDelegate.executor = commandHarness.executor
            let mainWindowController = SessionsVerticalMainWindowController(window: nil)
            mainWindowController.registeredWorkspaceWindowId = workspaceWindowId
            appDelegate.mainWindowController = mainWindowController
            appDelegate.appIPCSessionsProviderProfiles = providerProfiles + additionalProviderProfiles
            appDelegate.installAppIPCIdentityAuthority(datastore: datastore)
            var boundPaneToken: AgentStudioIPCSubjectToken?
            if installActivityClock {
                let activityAtom = appDelegate.atomStore.core.paneActivityTime
                let clock = PaneActivityClock { batch in activityAtom.apply(batch) }
                appDelegate.paneActivityClock = clock
                await clock.start()
                let paneToken = AgentStudioIPCSubjectToken(rawValue: "pane-activity-\(UUIDv7.generate().uuidString)")
                try appDelegate.appIPCPrincipalRegistry.registerIssuedPaneCredential(
                    paneID: boundPane.id,
                    workspaceID: commandHarness.store.identityAtom.workspaceId,
                    credentialRecordID: UUIDv7.generate(),
                    verifierSHA256: await credentialVerifier(for: paneToken.rawValue)
                )
                boundPaneToken = paneToken
            }

            // The tail of the identifier, not its head: a UUIDv7 begins with a
            // millisecond timestamp, so two harnesses built in the same millisecond
            // shared a directory name and the second failed to create it. The tail
            // is cryptographic random. The whole identifier will not do — the
            // socket underneath this root must fit in `sockaddr_un.sun_path`, which
            // is 104 bytes including the temporary directory and `/ipc/agentstudio.sock`.
            let rootDirectory = FileManager.default.temporaryDirectory
                .appending(path: "as-ipc-\(UUIDv7.generate().uuidString.suffix(12))")
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            createdRootDirectory = rootDirectory
            let paths = AgentStudioIPCPathResolver().paths(rootDirectory: rootDirectory)
            appDelegate.appIPCPaths = paths

            var token = AgentStudioIPCSubjectToken(rawValue: "sessions-vertical-\(UUIDv7.generate().uuidString)")
            appDelegate.appIPCDebugCredentialEscrowURL = debugCredentialEscrowURL
            if debugCredentialEscrowURL == nil {
                _ = appDelegate.appIPCPrincipalRegistry.installDiagnosticCredential(
                    verifierSHA256: await credentialVerifier(for: token.rawValue)
                )
            }
            await appDelegate.startAppIPCServer()
            guard appDelegate.appIPCServer != nil else {
                throw SessionsVerticalHarnessError.serverUnavailable
            }
            if let debugCredentialEscrowURL {
                guard let escrowData = try? Data(contentsOf: debugCredentialEscrowURL),
                    let escrow = try? JSONDecoder().decode(
                        IPCDebugCredentialEscrowDocument.self, from: escrowData
                    )
                else {
                    throw SessionsVerticalHarnessError.debugCredentialEscrowUnavailable
                }
                token = AgentStudioIPCSubjectToken(rawValue: escrow.token)
            }

            return Self(
                appDelegate: appDelegate,
                commandHarness: commandHarness,
                rootDirectory: rootDirectory,
                socketPath: paths.socketURL.path,
                token: token,
                boundPaneToken: boundPaneToken,
                boundPaneId: boundPane.id,
                sparePaneId: sparePane.id,
                workspaceWindowId: workspaceWindowId
            )
        } catch {
            // Unwind whatever this partial construction reached: a started
            // server, a started pane activity clock, the command harness's
            // coordinator/executor, and a created socket root, in that order
            // — the same production shutdown pair `tearDown()` uses.
            // paneActivityClock is nil unless installActivityClock installed
            // it, and shutdown() is idempotent, so this is a safe no-op when
            // it was never started.
            await appDelegate.stopAcceptingAppIPCConnections()
            await appDelegate.drainAppIPCCredentialPersistence()
            await appDelegate.paneActivityClock?.shutdown()
            await commandHarness.executor.stopAcceptingCommandsAndDrain()
            await commandHarness.coordinator.shutdown()
            if let createdRootDirectory {
                try? FileManager.default.removeItem(at: createdRootDirectory)
            }
            throw error
        }
    }

    @concurrent nonisolated private static func credentialVerifier(for token: String) async -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    /// Ingress closes first, then the durable drain — which now also joins
    /// every in-flight connection handler — then the pane activity clock a
    /// suite may have installed (nil, and this a no-op, unless
    /// installActivityClock requested one), and only then the command
    /// harness's own executor/coordinator shutdown, mirroring
    /// `withWorkspaceCommandHarness`'s awaited cleanup for the same harness
    /// type.
    func tearDown() async {
        await appDelegate.stopAcceptingAppIPCConnections()
        await appDelegate.drainAppIPCCredentialPersistence()
        await appDelegate.paneActivityClock?.shutdown()
        await commandHarness.executor.stopAcceptingCommandsAndDrain()
        await commandHarness.coordinator.shutdown()
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    /// A suite keeps its server and datastore, while each case gets panes with
    /// independent durable Sessions rows and source generations. When the
    /// suite installed a bound-pane credential, this mints a fresh one for the
    /// new bound pane rather than carrying the old pane's credential forward:
    /// the principal registry binds a credential to the pane ID that requested
    /// it, so reusing the old token here would authenticate as the wrong pane.
    func freshPanePair() async throws -> Self {
        let boundPane = commandHarness.store.createPane(title: "Bound pane")
        let sparePane = commandHarness.store.createPane(title: "Spare pane")
        commandHarness.store.appendTab(Tab(paneId: boundPane.id))
        commandHarness.store.appendTab(Tab(paneId: sparePane.id))
        var freshBoundPaneToken: AgentStudioIPCSubjectToken?
        if boundPaneToken != nil {
            let paneToken = AgentStudioIPCSubjectToken(rawValue: "pane-activity-\(UUIDv7.generate().uuidString)")
            try appDelegate.appIPCPrincipalRegistry.registerIssuedPaneCredential(
                paneID: boundPane.id,
                workspaceID: commandHarness.store.identityAtom.workspaceId,
                credentialRecordID: UUIDv7.generate(),
                verifierSHA256: await Self.credentialVerifier(for: paneToken.rawValue)
            )
            freshBoundPaneToken = paneToken
        }
        return Self(
            appDelegate: appDelegate,
            commandHarness: commandHarness,
            rootDirectory: rootDirectory,
            socketPath: socketPath,
            token: token,
            boundPaneToken: freshBoundPaneToken,
            boundPaneId: boundPane.id,
            sparePaneId: sparePane.id,
            workspaceWindowId: workspaceWindowId
        )
    }

    func bindBoundPane() async throws -> IPCSessionEventResult {
        try await sessionEvent(
            paneId: boundPaneId,
            provider: Self.qualifiedProvider,
            name: "sessionStart",
            conversationId: "conversation-\(boundPaneId.uuidString)"
        )
    }

    /// `occurrenceId` is a parameter so a case can name the occurrence it
    /// expects to find again in the pane's history rather than counting rows.
    func sessionEvent(
        paneId: UUID,
        provider: IPCSessionProviderIdentity,
        name: String,
        conversationId: String,
        occurrenceId: UUID = UUIDv7.generate(),
        correlationId: UUID = UUIDv7.generate(),
        authentication: Authentication = .diagnostic
    ) async throws -> IPCSessionEventResult {
        try await decoded(
            method: "session.event",
            params: .object([
                "handle": .string(paneId.uuidString),
                "provider": .object([
                    "identifier": .string(provider.identifier),
                    "version": .string(provider.version),
                    "mode": .string(provider.mode),
                ]),
                "event": .object([
                    "name": .string(name),
                    "conversationId": .string(conversationId),
                    "occurrenceId": .string(occurrenceId.uuidString),
                ]),
                "correlationId": .string(correlationId.uuidString),
            ]),
            authentication: authentication
        )
    }

    /// The pane's durable Sessions row, for a case that has to see history the
    /// `session.query` projection deliberately does not carry over the wire.
    func paneSnapshot(paneId: UUID) async throws -> SessionsSnapshot {
        let ingestion = try #require(appDelegate.appIPCSessionsIngestion)
        return try await ingestion.snapshot(
            .pane(paneId, page: SessionsSnapshotPage(limit: 100, after: nil))
        )
    }

    /// Sends fully formed parameters, for a caller that built them somewhere
    /// else — a provider hook projection, say — rather than field by field here.
    func sessionEvent(params: IPCSessionEventParams) async throws -> IPCSessionEventResult {
        try await decoded(
            method: "session.event",
            params: try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(params))
        )
    }

    func sessionReport(
        paneId: UUID,
        kind: String,
        explanation: String?,
        correlationId: UUID = UUIDv7.generate()
    ) async throws -> IPCSessionReportResult {
        try await decoded(
            method: "session.report",
            params: Self.reportParams(
                paneId: paneId, kind: kind, explanation: explanation, correlationId: correlationId
            )
        )
    }

    func rawSessionReport(
        paneId: UUID,
        kind: String,
        explanation: String?,
        correlationId: UUID = UUIDv7.generate()
    ) async throws -> JSONRPCResponseMessage {
        try await response(
            method: "session.report",
            params: Self.reportParams(
                paneId: paneId, kind: kind, explanation: explanation, correlationId: correlationId
            )
        )
    }

    func sessionMessage(
        paneId: UUID,
        text: String,
        correlationId: UUID = UUIDv7.generate()
    ) async throws -> IPCSessionMessageResult {
        try await decoded(
            method: "session.message",
            params: .object([
                "handle": .string(paneId.uuidString),
                "text": .string(text),
                "correlationId": .string(correlationId.uuidString),
            ])
        )
    }

    func sessionQuery(paneId: UUID) async throws -> IPCSessionQueryResult {
        try await decoded(
            method: "session.query",
            params: .object(["handle": .string(paneId.uuidString)])
        )
    }

    private static func reportParams(
        paneId: UUID,
        kind: String,
        explanation: String?,
        correlationId: UUID
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "handle": .string(paneId.uuidString),
            "kind": .string(kind),
            "correlationId": .string(correlationId.uuidString),
        ]
        if let explanation { fields["explanation"] = .string(explanation) }
        return .object(fields)
    }

    func decoded<Result: Decodable>(
        method: String,
        params: JSONValue,
        authentication: Authentication = .diagnostic
    ) async throws -> Result {
        let message = try await response(method: method, params: params, authentication: authentication)
        if let error = message.error {
            throw SessionsVerticalHarnessError.requestFailed(method: method, code: error.code, data: error.data)
        }
        let result = try #require(message.result)
        return try JSONDecoder().decode(Result.self, from: try JSONEncoder().encode(result))
    }

    func response(
        method: String,
        params: JSONValue,
        authentication: Authentication = .diagnostic
    ) async throws -> JSONRPCResponseMessage {
        try JSONRPCCodec.decodeResponse(
            try await responseFrame(method: method, params: params, authentication: authentication)
        )
    }

    /// Returns the frame exactly as it crossed the socket, so a caller can
    /// measure what the transport carried rather than what the composition
    /// would have produced in process.
    func responseFrame(
        method: String,
        params: JSONValue,
        authentication: Authentication = .diagnostic
    ) async throws -> String {
        let authenticationToken: AgentStudioIPCSubjectToken
        switch authentication {
        case .diagnostic:
            authenticationToken = token
        case .boundPane:
            guard let boundPaneToken else {
                throw SessionsVerticalHarnessError.boundPaneCredentialUnavailable
            }
            authenticationToken = boundPaneToken
        }
        let connection = try UnixSocketClient.connect(endpoint: UnixSocketEndpoint(path: socketPath))
        defer { connection.close() }
        var reader = SessionsVerticalFrameReader()
        try send(
            connection: connection,
            request: try JSONRPCClientRequest(
                id: .number(1),
                method: "auth.login",
                params: .object(["token": .string(authenticationToken.rawValue)])
            )
        )
        let loginResponse = try await reader.receiveResponse(connection: connection)
        try #require(loginResponse.error == nil)
        try send(
            connection: connection,
            request: try JSONRPCClientRequest(id: .number(2), method: method, params: params)
        )
        return try await reader.receiveFrame(connection: connection)
    }

    private func send(connection: UnixSocketConnection, request: JSONRPCClientRequest) throws {
        try connection.send(
            try NDJSONFrameEncoder.encode(JSONRPCCodec.encodeRequest(request), maxFrameBytes: 65_536)
        )
    }
}

/// Swift Testing scopes this trait around the suite, not each test case.
/// Task-local inheritance gives every case the same live server; freshPanePair
/// keeps their persisted state independent. A filtered suite still tears down.
struct SessionsVerticalHarnessTrait: SuiteTrait, TestScoping {
    enum ProviderProfiles: Sendable {
        case defaultProfiles
        case shipped
        case claudeCode
    }

    let providerProfiles: ProviderProfiles
    var isRecursive: Bool { false }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await SessionsVerticalHarnessBox.withScope(
            providerProfiles: providerProfiles,
            performing: function
        )
    }
}

enum SessionsVerticalHarnessContext {
    @TaskLocal static var current: SessionsVerticalHarnessBox?
}

@MainActor
final class SessionsVerticalHarnessBox {
    let harness: SessionsVerticalHarness

    private init(harness: SessionsVerticalHarness) {
        self.harness = harness
    }

    static func make(providerProfiles: SessionsVerticalHarnessTrait.ProviderProfiles) async throws -> Self {
        installTestCoreAtomsIfNeeded()
        let harness: SessionsVerticalHarness
        switch providerProfiles {
        case .defaultProfiles:
            harness = try await SessionsVerticalHarness.make()
        case .shipped:
            harness = try await SessionsVerticalHarness.make(
                providerProfiles: SessionsProviderProfile.shippedProfiles)
        case .claudeCode:
            harness = try await SessionsVerticalHarness.make(
                additionalProviderProfiles: [.claudeCodeCommandLine])
        }
        return Self(harness: harness)
    }

    static func withScope(
        providerProfiles: SessionsVerticalHarnessTrait.ProviderProfiles,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let fixture = try await make(providerProfiles: providerProfiles)
        do {
            try await SessionsVerticalHarnessContext.$current.withValue(fixture) {
                try await function()
            }
        } catch {
            await fixture.tearDown()
            throw error
        }
        await fixture.tearDown()
    }

    func freshPanePair() async throws -> SessionsVerticalHarness {
        try await harness.freshPanePair()
    }

    func tearDown() async {
        await harness.tearDown()
    }
}

enum SessionsVerticalHarnessError: Error {
    case optionalSchemaUnavailable
    case serverUnavailable
    case debugCredentialEscrowUnavailable
    case boundPaneCredentialUnavailable
    case requestFailed(method: String, code: Int, data: JSONValue?)
}

@MainActor
final class SessionsVerticalMainWindowController: MainWindowController {
    /// Command targeting resolves a workspace window through the controller,
    /// so the stub answers with the same identifier the harness registered.
    var registeredWorkspaceWindowId: UUID?

    override var acceptsIPCCommands: Bool { true }
    override var workspaceWindowId: UUID { registeredWorkspaceWindowId ?? super.workspaceWindowId }
}

struct SessionsVerticalFrameReader {
    private var decoder = NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes)
    private var queuedFrames: [String] = []

    mutating func receiveResponse(connection: UnixSocketConnection) async throws -> JSONRPCResponseMessage {
        try JSONRPCCodec.decodeResponse(try await receiveFrame(connection: connection))
    }

    mutating func receiveFrame(connection: UnixSocketConnection) async throws -> String {
        if !queuedFrames.isEmpty {
            return queuedFrames.removeFirst()
        }
        while true {
            let data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try connection.receive(maxBytes: 4096))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            queuedFrames.append(contentsOf: try decoder.append(data))
            if !queuedFrames.isEmpty {
                return queuedFrames.removeFirst()
            }
        }
    }
}

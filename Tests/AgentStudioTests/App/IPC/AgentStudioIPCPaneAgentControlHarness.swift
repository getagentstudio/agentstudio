import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// Starts the real App IPC server for a chosen channel over a real pane graph
/// and authenticates as pane agents with the credentials the App mints for its
/// terminals. The graph is one main terminal with one drawer child, and one
/// other main terminal in a second tab.
@MainActor
struct PaneAgentControlHarness {
    let appDelegate: AppDelegate
    let commandHarness: PaneTabViewControllerCommandHarness
    let rootDirectory: URL
    let socketPath: String
    let workspaceWindowId: UUID
    let mainPaneId: UUID
    let drawerChildPaneId: UUID
    let otherPaneId: UUID
    let runtimesByPaneId: [UUID: RecordingCommandPaneRuntime]

    var store: WorkspaceStore { commandHarness.store }

    static func make(channel: AgentStudioIPCChannel) async throws -> Self {
        let workspaceWindowId = UUIDv7.generate()
        let (commandHarness, datastore) = try await makeCanonicalIPCWorkspaceCommandHarness(
            workspaceWindowId: workspaceWindowId
        )
        let appDelegate = AppDelegate()
        var createdRootDirectory: URL?
        do {
            let store = commandHarness.store
            let mainPane = store.createPane(title: "Agent terminal")
            let otherPane = store.createPane(title: "Other terminal")
            let mainTab = Tab(paneId: mainPane.id)
            store.appendTab(mainTab)
            store.appendTab(Tab(paneId: otherPane.id))
            store.setActiveTab(mainTab.id)
            let drawerChild = try #require(store.addDrawerPane(to: mainPane.id))
            commandHarness.windowLifecycleStore.recordWindowRegistered(workspaceWindowId)

            var runtimesByPaneId: [UUID: RecordingCommandPaneRuntime] = [:]
            for paneId in [mainPane.id, drawerChild.id, otherPane.id] {
                let runtime = RecordingCommandPaneRuntime(paneId: PaneId(existingUUID: paneId))
                _ = commandHarness.runtimeRegistry.register(runtime)
                runtimesByPaneId[paneId] = runtime
            }

            guard case .ready = await datastore.prepareOptionalApplicationLocalSchema() else {
                throw PaneAgentControlHarnessError.optionalSchemaUnavailable
            }
            appDelegate.store = store
            appDelegate.workspaceSQLiteDatastore = datastore
            appDelegate.windowLifecycleStore = commandHarness.windowLifecycleStore
            appDelegate.atomStore = commandHarness.atomRegistry
            appDelegate.viewRegistry = commandHarness.viewRegistry
            appDelegate.workspaceSurfaceCoordinator = commandHarness.coordinator
            appDelegate.executor = commandHarness.executor
            let mainWindowController = SessionsVerticalMainWindowController(window: nil)
            mainWindowController.registeredWorkspaceWindowId = workspaceWindowId
            appDelegate.mainWindowController = mainWindowController
            appDelegate.installAppIPCIdentityAuthority(datastore: datastore)
            appDelegate.appIPCServerChannel = channel

            // The random tail keeps concurrent harness roots apart while the socket
            // path stays inside `sockaddr_un.sun_path`.
            let rootDirectory = FileManager.default.temporaryDirectory
                .appending(path: "as-pa-\(UUIDv7.generate().uuidString.suffix(12))")
            try FileManager.default.createDirectory(
                at: rootDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            createdRootDirectory = rootDirectory
            let paths = AgentStudioIPCPathResolver().paths(rootDirectory: rootDirectory)
            appDelegate.appIPCPaths = paths
            await appDelegate.startAppIPCServer()
            guard appDelegate.appIPCServer?.channel == channel else {
                throw PaneAgentControlHarnessError.serverUnavailable
            }

            return Self(
                appDelegate: appDelegate,
                commandHarness: commandHarness,
                rootDirectory: rootDirectory,
                socketPath: paths.socketURL.path,
                workspaceWindowId: workspaceWindowId,
                mainPaneId: mainPane.id,
                drawerChildPaneId: drawerChild.id,
                otherPaneId: otherPane.id,
                runtimesByPaneId: runtimesByPaneId
            )
        } catch {
            // Unwind whatever this partial construction reached, in the same
            // shape `tearDown()` uses.
            await appDelegate.stopAcceptingAppIPCConnections()
            await appDelegate.drainAppIPCCredentialPersistence()
            await commandHarness.executor.stopAcceptingCommandsAndDrain()
            await commandHarness.coordinator.shutdown()
            if let createdRootDirectory {
                try? FileManager.default.removeItem(at: createdRootDirectory)
            }
            throw error
        }
    }

    /// Ingress closes first — including joining every in-flight connection
    /// handler — then the durable drain, then the command harness drains and
    /// shuts down, the same shape `SessionsVerticalHarness.tearDown()` and
    /// `withWorkspaceCommandHarness` use for this harness type.
    func tearDown() async {
        await appDelegate.stopAcceptingAppIPCConnections()
        await appDelegate.drainAppIPCCredentialPersistence()
        await commandHarness.executor.stopAcceptingCommandsAndDrain()
        await commandHarness.coordinator.shutdown()
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    /// The credential the App hands the terminal bound to `paneId`.
    func agentToken(boundTo paneId: UUID) throws -> AgentStudioIPCSubjectToken {
        let environment = appDelegate.appIPCWorkspaceSurfaceLifecycle()
            .environment(paneId, store.identityAtom.workspaceId)
        return AgentStudioIPCSubjectToken(rawValue: try #require(environment["AGENTSTUDIO_PANE_TOKEN"]))
    }

    /// Workspace facts an agent must not move: selection, focus owner inputs,
    /// drawer expansion and membership.
    func workspaceFacts() -> PaneAgentWorkspaceFacts {
        PaneAgentWorkspaceFacts(
            paneIds: store.paneAtom.graphAtom.paneIDs,
            activeTabId: store.tabLayoutAtom.activeTabId,
            activePaneId: store.tabLayoutAtom.activeTab?.activePaneId,
            drawerChildIds: store.paneAtom.pane(mainPaneId)?.drawer?.paneIds ?? [],
            isDrawerExpanded: store.paneAtom.pane(mainPaneId)?.drawer?.isExpanded ?? false,
            activeDrawerChildId: store.drawerView(forParent: mainPaneId)?.activeChildId
        )
    }

    func command(
        _ command: AppCommand,
        arguments: IPCCommandArguments
    ) throws -> JSONValue {
        try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(
                IPCCommandExecutionRequest(
                    commandId: .init(rawValue: command.rawValue),
                    correlationId: UUIDv7.generate(),
                    arguments: arguments
                )))
    }

    func paneArguments(_ paneId: UUID) throws -> IPCCommandArguments {
        .pane(.init(workspaceWindowId: workspaceWindowId, paneSelector: try .init(rawValue: paneId.uuidString)))
    }

    func drawerChildArguments(parent: UUID, child: UUID) throws -> IPCCommandArguments {
        .drawerPane(
            .init(
                workspaceWindowId: workspaceWindowId,
                parentPaneSelector: try .init(rawValue: parent.uuidString),
                drawerPaneSelector: try .init(rawValue: child.uuidString)
            ))
    }

    /// One authenticated connection per request, exactly as the bundled CLI
    /// connects.
    func response(
        token: AgentStudioIPCSubjectToken,
        method: String,
        params: JSONValue
    ) async throws -> JSONRPCResponseMessage {
        let endpoint = UnixSocketEndpoint(path: socketPath)
        let connection = try await withoutBlockingCooperativePool { try UnixSocketClient.connect(endpoint: endpoint) }
        defer { connection.close() }
        var reader = SessionsVerticalFrameReader()
        try await send(
            connection: connection,
            request: try JSONRPCClientRequest(
                id: .number(1), method: "auth.login", params: .object(["token": .string(token.rawValue)])))
        let login = try await reader.receiveResponse(connection: connection)
        try #require(login.error == nil)
        try await send(
            connection: connection, request: try JSONRPCClientRequest(id: .number(2), method: method, params: params))
        return try await reader.receiveResponse(connection: connection)
    }

    private func send(connection: UnixSocketConnection, request: JSONRPCClientRequest) async throws {
        try await withoutBlockingCooperativePool {
            try connection.send(
                try NDJSONFrameEncoder.encode(JSONRPCCodec.encodeRequest(request), maxFrameBytes: 65_536))
        }
    }
}

/// The stable catalog cases only observe named refusals; one pane-agent server
/// serves all parameterized cases without changing their workspace facts.
struct PaneAgentHarnessTrait: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await PaneAgentHarnessBox.withScope(performing: function)
    }
}

enum PaneAgentHarnessContext {
    @TaskLocal static var current: PaneAgentHarnessBox?
}

@MainActor
final class PaneAgentHarnessBox {
    let harness: PaneAgentControlHarness

    private init(harness: PaneAgentControlHarness) {
        self.harness = harness
    }

    static func make() async throws -> Self {
        installTestCoreAtomsIfNeeded()
        return Self(harness: try await PaneAgentControlHarness.make(channel: .stable))
    }

    static func withScope(performing function: @Sendable () async throws -> Void) async throws {
        let fixture = try await make()
        do {
            try await PaneAgentHarnessContext.$current.withValue(fixture) {
                try await function()
            }
        } catch {
            await fixture.tearDown()
            throw error
        }
        await fixture.tearDown()
    }

    func tearDown() async {
        await harness.tearDown()
    }
}

struct PaneAgentWorkspaceFacts: Equatable {
    let paneIds: Set<UUID>
    let activeTabId: UUID?
    let activePaneId: UUID?
    let drawerChildIds: [UUID]
    let isDrawerExpanded: Bool
    let activeDrawerChildId: UUID?
}

enum PaneAgentControlHarnessError: Error {
    case optionalSchemaUnavailable
    case serverUnavailable
}

/// The refusal an agent receives, read from the wire.
struct PaneAgentRefusal: Equatable {
    let code: Int
    let reason: String?
    let name: String?

    init?(_ response: JSONRPCResponseMessage) {
        guard let error = response.error else { return nil }
        code = error.code
        if case .object(let data)? = error.data {
            if case .string(let reason)? = data["reason"] { self.reason = reason } else { reason = nil }
            if case .string(let name)? = data["name"] { self.name = name } else { name = nil }
        } else {
            reason = nil
            name = nil
        }
    }

    init(code: Int, reason: String?, name: String?) {
        self.code = code
        self.reason = reason
        self.name = name
    }

    static func notYetAllowed(_ name: String) -> Self {
        Self(code: -32_011, reason: "notYetAllowed", name: name)
    }

    static func refusedForAgent(_ name: String) -> Self {
        Self(code: -32_012, reason: "refusedForAgent", name: name)
    }
}

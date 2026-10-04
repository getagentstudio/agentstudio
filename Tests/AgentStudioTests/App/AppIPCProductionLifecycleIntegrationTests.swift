import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioSessions
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("App IPC production lifecycle integration", .serialized)
struct AppIPCProductionLifecycleIntegrationTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("App lifecycle denies a closed pane, restores the same token on Undo, and final-fences expiry")
    func appCompositionRoutesCoordinatorCloseUndoAndExpiryThroughSharedRegistry() async throws {
        let (core, store, datastore) = try await makeCanonicalIPCWorkspaceOwners()
        let workspaceID = core.workspaceIdentity.workspaceId
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        #expect(await store.flushAsync() == .persisted)
        let appDelegate = AppDelegate()
        appDelegate.store = store
        appDelegate.atomStore = AtomRegistry(core: core)
        appDelegate.installAppIPCIdentityAuthority(datastore: datastore)
        let lifecycle = appDelegate.appIPCWorkspaceSurfaceLifecycle()
        let surfaceManager = HarnessSurfaceManager()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: surfaceManager,
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: lifecycle,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )

        let environment = lifecycle.environment(pane.id, workspaceID)
        let rawToken = try #require(environment["AGENTSTUDIO_PANE_TOKEN"])
        #expect(environment["AGENTSTUDIO_PANE_ID"] == pane.id.uuidString)
        #expect(environment["AGENTSTUDIO_WORKSPACE_ID"] == workspaceID.uuidString)
        #expect(environment["AGENTSTUDIO_IPC_SOCKET"] == appDelegate.appIPCPaths.socketURL.path)
        #expect(environment["AGENTSTUDIO_CLI_STORE"] == appDelegate.appIPCPaths.cliStoreURL.path)
        #expect(environment["AGENTSTUDIO_CLI_STORE_CHANNEL"] == appDelegate.appIPCServerChannel.rawValue)
        #expect(environment["AGENTSTUDIO_CLI"]?.hasSuffix("/Contents/Helpers/agentstudio") == true)

        let token = AgentStudioIPCSubjectToken(rawValue: rawToken)
        let closeLease = try await appDelegate.appIPCPrincipalRegistry.authenticate(subjectToken: token)
        try await coordinator.execute(.closeTab(tabId: tab.id))
        #expect(store.paneAtom.pane(pane.id) == nil)
        #expect(await appDelegate.appIPCPrincipalRegistry.contextRemainsAuthorized(closeLease) == false)
        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            _ = try await appDelegate.appIPCPrincipalRegistry.authenticate(subjectToken: token)
        }

        try await coordinator.undoCloseTab()
        #expect(store.paneAtom.pane(pane.id) != nil)
        let undoLease = try await appDelegate.appIPCPrincipalRegistry.authenticate(subjectToken: token)
        #expect(await appDelegate.appIPCPrincipalRegistry.contextRemainsAuthorized(undoLease))

        try await coordinator.execute(.closeTab(tabId: tab.id))
        let secondClose = try #require(
            try await datastore.fetchAvailableUndoCloses(workspaceID: workspaceID).first)
        let retirements = try await store.expireUndoCloses(
            time: WorkspaceUndoJournalTime(
                utc: secondClose.expiresAt.addingTimeInterval(1),
                bootID: secondClose.deadlineBootID,
                uptimeNanoseconds: secondClose.deadlineUptimeNanoseconds + 1
            )
        )
        coordinator.consumeUndoRetirements(retirements)
        #expect(await appDelegate.appIPCPrincipalRegistry.contextRemainsAuthorized(undoLease) == false)
        #expect(appDelegate.appIPCPrincipalRegistry.finalRevokedPaneIDsSnapshot() == [pane.id])
        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            _ = try await appDelegate.appIPCPrincipalRegistry.authenticate(subjectToken: token)
        }
        await coordinator.shutdown()
    }

    @Test("shutdown without a published server stops RAM admission without persisting an issued verifier")
    func shutdownWithoutServerStopsAdmissionWithoutDurableDrain() async throws {
        let (core, store, datastore) = try await makeCanonicalIPCWorkspaceOwners()
        let workspaceID = core.workspaceIdentity.workspaceId
        guard case .ready = await datastore.prepareOptionalApplicationLocalSchema() else {
            Issue.record("Expected optional local schema readiness")
            return
        }
        let pane = store.createPane()
        let appDelegate = AppDelegate()
        appDelegate.store = store
        appDelegate.atomStore = AtomRegistry(core: core)
        appDelegate.installAppIPCIdentityAuthority(datastore: datastore)
        let environment = appDelegate.appIPCWorkspaceSurfaceLifecycle().environment(pane.id, workspaceID)
        let token = AgentStudioIPCSubjectToken(
            rawValue: try #require(environment["AGENTSTUDIO_PANE_TOKEN"])
        )

        await appDelegate.stopAcceptingAppIPCConnections()
        await appDelegate.drainAppIPCCredentialPersistence()

        #expect(appDelegate.appIPCServer == nil)
        #expect(appDelegate.appIPCInitializationTask == nil)
        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            _ = try await appDelegate.appIPCPrincipalRegistry.authenticate(subjectToken: token)
        }
        #expect(try await appDelegate.appIPCContinuityRepository.paneCredentials(paneID: pane.id).isEmpty)
    }

    @Test("no local datastore starts neither the IPC server nor the offline notification drain")
    func missingLocalDatastoreStartsNoServerAndNoSpoolDrain() async throws {
        let (core, store, datastore) = try await makeCanonicalIPCWorkspaceOwners()
        let appDelegate = AppDelegate()
        appDelegate.store = store
        appDelegate.atomStore = AtomRegistry(core: core)
        appDelegate.installAppIPCIdentityAuthority(datastore: datastore)
        appDelegate.workspaceSQLiteDatastore = nil

        await appDelegate.startAppIPCServer()

        #expect(appDelegate.appIPCServer == nil)
        #expect(appDelegate.paneCLIOutboxDrainTask == nil)
        #expect(appDelegate.appIPCSessionsPaneContextComposition == nil)
    }

    @Test("production App start reuses the early registry and shutdown persists a later unused token")
    func productionStartAndShutdownReuseEarlyRegistryAndPersistUnusedToken() async throws {
        let harness = try await makeServerCapableAppIPCTestHarness()
        do {
            let readinessPane = harness.store.createPane()
            let readinessRecordID = try #require(
                harness.appDelegate.paneIPCIdentityOwner
            ).environment(paneID: readinessPane.id, workspaceID: harness.workspaceID).credentialRecordID
            let earlyRegistry = harness.appDelegate.appIPCPrincipalRegistry!

            await harness.appDelegate.startAppIPCServer()
            let server = try #require(harness.appDelegate.appIPCServer)
            let composition = try #require(harness.appDelegate.appIPCSessionsPaneContextComposition)
            #expect(server.principalRegistry === earlyRegistry)

            let shutdownOnlyPane = harness.store.createPane()
            let shutdownOnlyRecordID = try #require(
                harness.appDelegate.paneIPCIdentityOwner
            ).environment(paneID: shutdownOnlyPane.id, workspaceID: harness.workspaceID).credentialRecordID
            #expect(
                try await harness.appDelegate.appIPCContinuityRepository.paneCredential(
                    paneID: shutdownOnlyPane.id,
                    credentialRecordID: shutdownOnlyRecordID
                ) == nil
            )

            await harness.appDelegate.stopAcceptingAppIPCConnections()
            await harness.appDelegate.drainAppIPCCredentialPersistence()

            #expect(harness.appDelegate.appIPCServer == nil)
            #expect(harness.appDelegate.appIPCSessionsPaneContextComposition == nil)
            #expect(harness.coordinator.paneContextService == nil)
            await #expect(throws: SessionsRepositoryError.ingestionFinished) {
                _ = try await composition.ingestion.prepareForLaunch(at: Date())
            }
            let closed = await composition.paneContextService.readDetail(
                .init(paneId: PaneId(existingUUID: shutdownOnlyPane.id), page: .first))
            #expect(closed == .unavailable(.decodeFailed("serviceStopped")))
            #expect(
                try await harness.appDelegate.appIPCContinuityRepository.paneCredential(
                    paneID: readinessPane.id,
                    credentialRecordID: readinessRecordID
                )?.status == .registered
            )
            #expect(
                try await harness.appDelegate.appIPCContinuityRepository.paneCredential(
                    paneID: shutdownOnlyPane.id,
                    credentialRecordID: shutdownOnlyRecordID
                )?.status == .registered
            )
        } catch {
            await harness.shutdown()
            throw error
        }
        await harness.shutdown()
    }
}

@MainActor
struct ServerCapableAppIPCTestHarness {
    let appDelegate: AppDelegate
    let store: WorkspaceStore
    let coordinator: WorkspaceSurfaceCoordinator
    let workspaceID: UUID
    let rootDirectory: URL

    func shutdown() async {
        await appDelegate.stopAcceptingAppIPCConnections()
        await appDelegate.drainAppIPCCredentialPersistence()
        await coordinator.shutdown()
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

@MainActor
func makeServerCapableAppIPCTestHarness(
    windowLifecycleStore: WindowLifecycleAtom = WindowLifecycleAtom()
) async throws -> ServerCapableAppIPCTestHarness {
    let (core, store, datastore) = try await makeCanonicalIPCWorkspaceOwners()
    let workspaceID = core.workspaceIdentity.workspaceId
    let appDelegate = AppDelegate()
    appDelegate.store = store
    appDelegate.workspaceSQLiteDatastore = datastore
    appDelegate.windowLifecycleStore = windowLifecycleStore
    appDelegate.atomStore = AtomRegistry(core: core)
    appDelegate.viewRegistry = ViewRegistry()
    appDelegate.installAppIPCIdentityAuthority(datastore: datastore)

    let rootDirectory = FileManager.default.temporaryDirectory
        .appending(path: "as-ipc-\(UUIDv7.generate().uuidString.suffix(8))")
    try FileManager.default.createDirectory(
        at: rootDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let paths = AgentStudioIPCPathResolver().paths(
        rootDirectory: rootDirectory,
        socketDirectory: nil
    )
    appDelegate.appIPCPaths = paths
    let membershipDirectory = store.paneAtom.graphAtom.paneContextMembershipDirectory
    appDelegate.paneIPCIdentityOwner = PaneIPCIdentityOwner(
        principalRegistry: appDelegate.appIPCPrincipalRegistry,
        socketURL: paths.socketURL,
        cliStoreURL: paths.cliStoreURL,
        cliStoreChannel: .debug,
        cliExecutableURL: Bundle.main.bundleURL.appending(path: "Contents/Helpers/agentstudio"),
        canonicalPaneMembership: { paneID, candidateWorkspaceID in
            membershipDirectory.contains(paneID: paneID, inWorkspace: candidateWorkspaceID)
        }
    )
    let coordinator = WorkspaceSurfaceCoordinator(
        store: store,
        viewRegistry: appDelegate.viewRegistry,
        runtime: SessionRuntime(store: store),
        surfaceManager: HarnessSurfaceManager(),
        runtimeRegistry: RuntimeRegistry(),
        windowLifecycleStore: windowLifecycleStore,
        ipcLifecycle: appDelegate.appIPCWorkspaceSurfaceLifecycle(),
        bridgePaneAttendance: appDelegate.atomStore.bridgePaneAttendance
    )
    appDelegate.workspaceSurfaceCoordinator = coordinator
    appDelegate.executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
    appDelegate.mainWindowController = ServerCapableIPCMainWindowController(window: nil)
    return ServerCapableAppIPCTestHarness(
        appDelegate: appDelegate,
        store: store,
        coordinator: coordinator,
        workspaceID: workspaceID,
        rootDirectory: rootDirectory
    )
}

@MainActor
private final class ServerCapableIPCMainWindowController: MainWindowController {
    override var acceptsIPCCommands: Bool { true }
}

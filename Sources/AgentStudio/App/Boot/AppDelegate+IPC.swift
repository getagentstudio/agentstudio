import AgentStudioAppIPC
import AgentStudioCLIStore
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import CryptoKit
import Foundation
import Security

/// Why optional App IPC did not start. Agent IPC v2 R-25 keeps IPC
/// unavailable without retry when its release edges or optional work fail;
/// `app.ipc.start` records which, so the unavailability is explicit.
enum AppIPCStartUnavailability: String, Equatable, Sendable {
    case firstFrameCancelled = "first_frame_cancelled"
    case firstFrameTimeout = "first_frame_timeout"
    case initializationCancelled = "initialization_cancelled"
    case localStoreUnavailable = "local_store_unavailable"
    case optionalSchemaUnavailable = "optional_schema_unavailable"
    case sessionsIngestionFailed = "sessions_ingestion_failed"
    case noActiveWindow = "no_active_window"
    case ipcPathUntrusted = "ipc_path_untrusted"
    case socketInUse = "socket_in_use"
    case serverStartFailed = "server_start_failed"
    case restoreBoundsUnavailable = "restore_bounds_unavailable"

    /// Names the server-start failures the owner can act on; anything else
    /// stays `server_start_failed`.
    init(serverStartError error: any Error) {
        switch error {
        case let layoutError as AppIPCLayoutError where layoutError.reason == .noActiveWindow:
            self = .noActiveWindow
        case is AgentStudioIPCFilesystemTrustError:
            self = .ipcPathUntrusted
        case let serverError as AgentStudioAppIPCServerError where serverError.reason == .liveSocketAlreadyExists:
            self = .socketInUse
        default:
            self = .serverStartFailed
        }
    }
}

@MainActor
enum AppIPCDeferredInitialization {
    /// Runs `initialization` after the first interactive frame. Returns why it
    /// did not start or complete, or `nil` after normal completion.
    @discardableResult
    static func run(
        windowLifecycleStore: WindowLifecycleAtom,
        initialization: @escaping @MainActor @Sendable () async -> Void
    ) async -> AppIPCStartUnavailability? {
        switch await windowLifecycleStore.waitUntilFirstInteractiveFramePublished() {
        case .completed:
            break
        case .fallbackTimeout:
            return .firstFrameTimeout
        case .cancelled:
            return .firstFrameCancelled
        }
        guard !Task.isCancelled else { return .firstFrameCancelled }
        await initialization()
        // Preserve cancellation that arrives during optional IPC initialization for the caller to record.
        return Task.isCancelled ? .initializationCancelled : nil
    }

    static func prepareOptionalSchema(
        using datastore: WorkspaceSQLiteDatastoreActor
    ) async -> Bool {
        guard case .ready = await datastore.prepareOptionalApplicationLocalSchema() else {
            return false
        }
        return !Task.isCancelled
    }
}

extension AppDelegate {
    func installAppIPCIdentityAuthority(datastore: WorkspaceSQLiteDatastoreActor) {
        let runtimeID = UUIDv7.generate()
        let paths = AgentStudioIPCPathResolver().paths(
            rootDirectory: AppDataPaths.rootDirectory(),
            socketDirectory: Self.appIPCSocketDirectory()
        )
        let repository = IPCContinuityRepository(datastore: datastore)
        let resolver = IPCContinuityCredentialResolver(repository: repository)
        let registry = AgentStudioIPCPrincipalRegistry(
            runtimeId: runtimeID,
            credentialResolver: resolver,
            canonicalPaneMembership: { [store] paneID, workspaceID in
                store.identityAtom.workspaceId == workspaceID && store.paneAtom.pane(paneID) != nil
            }
        )
        appIPCRuntimeID = runtimeID
        appIPCPaths = paths
        appIPCDebugCredentialEscrowURL = Self.appIPCDebugCredentialEscrowURL()
        appIPCContinuityRepository = repository
        appIPCCredentialResolver = resolver
        appIPCPrincipalRegistry = registry
        paneIPCIdentityOwner = PaneIPCIdentityOwner(
            principalRegistry: registry,
            socketURL: paths.socketURL,
            cliStoreURL: paths.cliStoreURL,
            cliStoreChannel: cliStoreChannel,
            cliExecutableURL: Bundle.main.bundleURL
                .appending(path: "Contents/Helpers/agentstudio"),
            canonicalPaneMembership: { [store] paneID, workspaceID in
                store.identityAtom.workspaceId == workspaceID && store.paneAtom.pane(paneID) != nil
            }
        )
    }

    func appIPCWorkspaceSurfaceLifecycle() -> WorkspaceSurfaceIPCLifecycle {
        let paneIPCIdentityOwner = paneIPCIdentityOwner!
        return WorkspaceSurfaceIPCLifecycle(
            environment: { paneID, workspaceID in
                paneIPCIdentityOwner.terminalEnvironment(paneID: paneID, workspaceID: workspaceID)
            },
            invalidatePaneIDs: { [weak self] paneIDs in
                for paneID in paneIDs {
                    if let server = self?.appIPCServer {
                        server.invalidatePrincipals(boundToPaneId: paneID.uuidString)
                    } else {
                        self?.appIPCPrincipalRegistry.invalidatePrincipals(boundToPaneId: paneID.uuidString)
                    }
                }
            },
            finalRevokePaneIDs: { [weak self] paneIDs in
                for paneID in paneIDs {
                    if let server = self?.appIPCServer {
                        server.finalRevokePrincipals(boundToPaneID: paneID)
                    } else {
                        self?.appIPCPrincipalRegistry.finalRevokePane(paneID)
                    }
                }
            }
        )
    }

    func scheduleAppIPCInitialization() {
        guard appIPCServer == nil, appIPCInitializationTask == nil else { return }
        let windowLifecycleStore = windowLifecycleStore!
        appIPCInitializationTask = Task { @MainActor [weak self] in
            let unavailability = await AppIPCDeferredInitialization.run(
                windowLifecycleStore: windowLifecycleStore
            ) { [weak self] in
                await self?.startAppIPCServer()
            }
            if let unavailability {
                self?.recordAppIPCStart(unavailable: unavailability)
            }
        }
    }

    /// Records `app.ipc.start`: started, or unavailable with its reason.
    func recordAppIPCStart(unavailable reason: AppIPCStartUnavailability? = nil) {
        guard !didRecordAppIPCStartOutcome else {
            appLogger.warning("Ignoring duplicate app.ipc.start outcome")
            return
        }
        didRecordAppIPCStartOutcome = true
        startupTraceRecorder?.recordAppStartup(
            "app.ipc.start",
            phase: "app_ipc",
            outcome: reason == nil ? "started" : "unavailable",
            attributes: reason.map { ["agentstudio.app.ipc.start.reason": .string($0.rawValue)] } ?? [:]
        )
    }

    func startAppIPCServer() async {
        guard appIPCServer == nil else { return }
        guard let workspaceSQLiteDatastore else {
            appLogger.warning("App IPC server skipped: local SQLite is unavailable")
            recordAppIPCStart(unavailable: .localStoreUnavailable)
            return
        }
        guard await AppIPCDeferredInitialization.prepareOptionalSchema(using: workspaceSQLiteDatastore) else {
            appLogger.warning("App IPC server skipped: optional local schema is unavailable")
            // A cancelled attempt is a shutdown, not an unavailable store.
            if !Task.isCancelled { recordAppIPCStart(unavailable: .optionalSchemaUnavailable) }
            return
        }
        guard appIPCServer == nil else { return }
        guard let sessionsIngestion = await prepareAppIPCSessionsIngestion(datastore: workspaceSQLiteDatastore) else {
            if !Task.isCancelled { recordAppIPCStart(unavailable: .sessionsIngestionFailed) }
            return
        }

        do {
            guard
                let composition = try await makeAppIPCServer(
                    sessionsIngestion: sessionsIngestion, datastore: workspaceSQLiteDatastore)
            else { return }
            try composition.server.start()
            appIPCServer = composition.server
            appLogger.info("App IPC server started at \(composition.socketURL.path, privacy: .private)")
            publishDebugCredentialEscrow(socketURL: composition.socketURL)
            startPaneCLIOutboxDrain(sessionsIngestion: sessionsIngestion, datastore: workspaceSQLiteDatastore)
            recordAppIPCStart()
        } catch {
            appLogger.warning(
                "App IPC server failed to start: \(error.localizedDescription, privacy: .private)")
            if !Task.isCancelled {
                recordAppIPCStart(unavailable: AppIPCStartUnavailability(serverStartError: error))
            }
        }
    }

    /// Only a debug app whose launcher named an escrow file hands out a reusable
    /// credential, and only after the socket is listening: the raw value reaches
    /// disk with the endpoint that accepts it. The credential lives in the
    /// principal registry's memory and is never persisted. A failed handover
    /// leaves debug authentication unavailable; it never falls back to the
    /// separate unsafe no-auth composition.
    private func publishDebugCredentialEscrow(socketURL: URL) {
        guard Self.compiledAppIPCChannel() == .debug,
            let escrowURL = appIPCDebugCredentialEscrowURL
        else { return }
        var credentialBytes = Data(count: 32)
        let generatedCredential = credentialBytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard generatedCredential == errSecSuccess else {
            appLogger.warning("Debug IPC credential unavailable: random generation failed")
            return
        }
        let token = credentialBytes.base64EncodedString()
        let generationID = appIPCPrincipalRegistry.installDiagnosticCredential(
            verifierSHA256: Data(SHA256.hash(data: Data(token.utf8)))
        )
        do {
            try AgentStudioIPCFilesystem.writeDebugCredentialEscrow(
                IPCDebugCredentialEscrowDocument(
                    runtimeId: appIPCRuntimeID,
                    socketPath: socketURL.path,
                    token: token
                ),
                to: escrowURL
            )
        } catch {
            appIPCPrincipalRegistry.revokeDiagnosticCredential()
            appLogger.warning(
                """
                Debug IPC credential unavailable: escrow handover failed for generation \
                \(generationID, privacy: .public)
                """
            )
        }
    }

    private func retireDebugCredentialEscrow() {
        appIPCPrincipalRegistry?.revokeDiagnosticCredential()
        guard let escrowURL = appIPCDebugCredentialEscrowURL else { return }
        AgentStudioIPCFilesystem.removeDebugCredentialEscrow(at: escrowURL)
    }

    /// Notifications the CLI queued while this app was unreachable are admitted
    /// once IPC is listening and ingestion is prepared. The drain is detached and
    /// awaited nowhere, so no startup, terminal or zmx path waits on it.
    private func startPaneCLIOutboxDrain(sessionsIngestion: SessionsIngestion, datastore: WorkspaceSQLiteDatastoreActor)
    {
        guard paneCLIOutboxDrainTask == nil, let storeURL = appIPCPaths?.cliStoreURL else {
            return
        }
        let lateAdmission = AgentStudioIPCSessionsAdapter(
            ingestion: sessionsIngestion,
            providerRegistry: SessionsProviderAdapterRegistry(profiles: appIPCSessionsProviderProfiles),
            admissionFreshness: .late
        )
        let sqliteAccess = WorkspaceSessionsSQLiteAccess(datastore: datastore)
        let channel = cliStoreChannel
        let telemetry = AgentStudioIPCAgentAuthorizationTelemetry(performanceTraceRecorder: performanceTraceRecorder)
        // Intake and catalog construction run off MainActor; the app only reads
        // the CLI file and its cursor uses the existing application-local writer.
        // swiftlint:disable:next no_task_detached
        paneCLIOutboxDrainTask = Task.detached(priority: .utility) {
            do {
                let drain = try PaneCLIOutboxDrain(
                    admission: lateAdmission, sqliteAccess: sqliteAccess,
                    expectedChannel: channel,
                    refusalProbe: { reason in
                        telemetry.recordOfflineNoticeRefusal(reason: reason)
                    })
                let report = await drain.drain(storeURL: storeURL)
                guard report.hasWork else { return }
                appLogger.info(
                    "Offline outbox admitted \(report.admittedEntryCount, privacy: .public) refused \(report.refusedEntryCount, privacy: .public) malformed \(report.malformedEntryCount, privacy: .public) retryable \(report.retryableEntryCount, privacy: .public)"
                )
            } catch { appLogger.warning("Offline outbox intake unavailable") }
        }
    }

    /// Sessions ingestion is built with the IPC server, not on the first-frame
    /// or terminal paths. Launch preparation ends the previous run's active
    /// sources before any live report can reach them.
    private func prepareAppIPCSessionsIngestion(
        datastore: WorkspaceSQLiteDatastoreActor
    ) async -> SessionsIngestion? {
        if let existing = appIPCSessionsIngestion { return existing }
        let ingestion = SessionsIngestion(
            repository: SessionsRepository(
                sqliteAccess: WorkspaceSessionsSQLiteAccess(datastore: datastore)
            ),
            limits: SessionsIngestionLimits(
                maximumPendingPerPane: AppPolicies.Sessions.maximumPendingIngestionPerPane,
                maximumPendingGlobal: AppPolicies.Sessions.maximumPendingIngestionGlobal
            ),
            // Ingestion statistics carry a raw pane UUID, which the OTLP scrub
            // rules exclude. Counts reach no sink until a scrubbed probe exists.
            probe: { _ in }
        )
        do {
            _ = try await ingestion.prepareForLaunch(at: Date())
        } catch {
            appLogger.warning(
                """
                Sessions ingestion skipped: launch preparation failed: \
                \(error.localizedDescription, privacy: .private)
                """
            )
            return nil
        }
        guard !Task.isCancelled else { return nil }
        appIPCSessionsIngestion = ingestion
        return ingestion
    }

    private func finishAppIPCSessionsIngestion() async {
        guard let ingestion = appIPCSessionsIngestion else { return }
        appIPCSessionsIngestion = nil
        await ingestion.finish()
    }

    /// Ends IPC ingress and nothing else. No durable write happens here and
    /// nothing waits for one, so this runs before the workspace flush: it
    /// closes the window in which a late `command.execute` or Bridge open could
    /// mutate state the flush has already written. The escrow file only names
    /// the socket, so it is retired here too.
    func stopAcceptingAppIPCConnections() async {
        if !launchRestoreObservationState.didComplete {
            recordAppIPCStart(unavailable: .restoreBoundsUnavailable)
        }
        let initializationTask = appIPCInitializationTask
        initializationTask?.cancel()
        await initializationTask?.value
        appIPCInitializationTask = nil
        retireDebugCredentialEscrow()
        appIPCServer?.stopAcceptingConnections()
    }

    /// The durable half, which runs after the workspace flush. It writes
    /// through the same serialized workspace datastore actor the offline spool
    /// drain admits through, and that drain holds a file lock across admission,
    /// so the spool drain is cancelled and joined before this waits on anything
    /// else. In-flight connection handlers are joined next, before the
    /// credential drain: a handler mid-request can still enqueue persistence
    /// work (`auth.login`'s `schedulePersistence` call, for one), and the
    /// drain only waits for what is already queued when it starts. Joining
    /// first is what makes every handler-originated write visible to this
    /// drain, not an afterthought to it.
    ///
    /// Requires `stopAcceptingAppIPCConnections()` to have already run:
    /// `joinConnectionHandlers()`'s own precondition is that callers close
    /// connections first, which is what unblocks a handler parked on the
    /// socket. This does not re-call `stopAcceptingConnections()` as a
    /// safety net — it queues new credential persistence via
    /// `beginGracefulShutdownAndSnapshotUnsavedCredentials()`, and nothing
    /// after this point drains it.
    func drainAppIPCCredentialPersistence() async {
        let outboxDrainTask = paneCLIOutboxDrainTask
        outboxDrainTask?.cancel()
        paneCLIOutboxDrainTask = nil
        await outboxDrainTask?.value
        guard let server = appIPCServer else {
            appIPCPrincipalRegistry?.shutdown()
            await finishAppIPCSessionsIngestion()
            appLogger.info("App IPC shutdown completed without a published server or durable drain")
            return
        }
        await server.joinConnectionHandlers()
        let result = await server.drainCredentialPersistence()
        appIPCServer = nil
        await finishAppIPCSessionsIngestion()
        if result.failedOperationCount > 0 {
            appLogger.warning(
                "App IPC credential persistence drain completed with \(result.failedOperationCount) failures"
            )
        }
    }

    private func makeAppIPCServer(
        sessionsIngestion: SessionsIngestion,
        datastore: WorkspaceSQLiteDatastoreActor
    ) async throws -> (server: AgentStudioAppIPCServer, socketURL: URL)? {
        let runtimeId = appIPCRuntimeID!
        let accessMode = Self.appIPCAccessMode()
        let paths = appIPCPaths!
        let windowLifecycleReader = WorkspaceWindowLifecycleReader(lifecycleStore: windowLifecycleStore)
        guard mainWindowController?.acceptsIPCCommands == true else {
            throw AppIPCLayoutError(reason: .noActiveWindow)
        }
        let commandPort = AgentStudioIPCCommandAdapter(
            workspaceId: store.identityAtom.workspaceId,
            channel: appIPCServerChannel,
            targetAuthorizer: WorkspaceDurableTargetAuthorizationPort(workspaceStore: store),
            shellCommandHandler: self
        )
        let commandCatalogProjectionInputs = commandPort.commandCatalogProjectionInputs()
        let ports = AgentStudioAppIPCPorts(
            queryPort: AgentStudioIPCQueryAdapter(
                runtimeId: runtimeId,
                accessMode: accessMode,
                appVersion: Self.appIPCAppVersion(),
                workspaceStore: store,
                windowLifecycleReader: windowLifecycleReader
            ),
            layoutPort: AgentStudioIPCLayoutAdapter(
                workspaceStore: store,
                windowLifecycleReader: windowLifecycleReader,
                paneFocusControl: self,
                workspaceActionExecutor: executor
            ),
            runtimePort: AgentStudioIPCRuntimeAdapter(
                workspaceStore: store,
                runtimeRegistry: workspaceSurfaceCoordinator.runtimeRegistry,
                commandDispatcher: workspaceSurfaceCoordinator
            ),
            bridgePort: AgentStudioIPCBridgeAdapter(
                workspaceStore: store,
                viewRegistry: viewRegistry,
                actionExecutor: executor
            ),
            commandPort: commandPort,
            uiPresentationPort: AgentStudioIPCUIPresentationAdapter(
                presenter: self,
                targetAuthorizer: WorkspaceDurableTargetAuthorizationPort(workspaceStore: store)
            ),
            sidebarPort: AgentStudioIPCSidebarAdapter(
                repoPrefs: atomStore.repoExplorerSidebarPrefs,
                sidebarState: atomStore.core.workspaceSidebarState
            ),
            sessionsPort: AgentStudioIPCSessionsAdapter(
                ingestion: sessionsIngestion,
                providerRegistry: SessionsProviderAdapterRegistry(
                    profiles: appIPCSessionsProviderProfiles
                ),
                activityClock: paneActivityClock
            ),
            permissionApprovalPort: AgentStudioIPCHumanApprovalPort(),
            ownPaneScopePort: WorkspaceOwnPaneScopePort(
                workspaceStore: store, performanceTraceRecorder: performanceTraceRecorder),
            agentAuthorizationTelemetry: AgentStudioIPCAgentAuthorizationTelemetry(
                performanceTraceRecorder: performanceTraceRecorder)
        )
        let eventBroker = IPCEventBroker()
        guard
            let registry = try await makeAppIPCMethodRegistry(
                runtimeId: runtimeId,
                ports: ports,
                eventBroker: eventBroker,
                commandCatalogProjectionInputs: commandCatalogProjectionInputs
            )
        else { return nil }
        let service = AgentStudioAppIPCService(
            configuration: AgentStudioAppIPCConfiguration(runtimeId: runtimeId, accessMode: accessMode),
            ports: ports,
            methodRegistry: registry,
            eventBroker: eventBroker
        )
        return (
            AgentStudioAppIPCServer(
                service: service,
                paths: paths,
                channel: appIPCServerChannel,
                principalRegistry: appIPCPrincipalRegistry,
                credentialContinuityPort: appIPCContinuityRepository,
                cliStoreReadThroughPort: AppCLIStoreReadThroughReader(
                    storeURL: paths.cliStoreURL, expectedChannel: cliStoreChannel, datastore: datastore)
            ),
            paths.socketURL
        )
    }

    private func makeAppIPCMethodRegistry(
        runtimeId: UUID,
        ports: AgentStudioAppIPCPorts,
        eventBroker: IPCEventBroker,
        commandCatalogProjectionInputs: AppIPCCommandCatalogProjectionInputs
    ) async throws -> AppIPCMethodRegistry? {
        let channel = appIPCServerChannel
        let recognizedCommands = commandCatalogProjectionInputs.recognizedCommands
        let builderInputs = AppIPCDescriptorCatalogBuildInputs(
            builtInCatalogInputs: Self.appIPCBuiltInMethodCatalogInputs(),
            channel: channel,
            commandCatalogProjectionInputs: commandCatalogProjectionInputs
        )
        let descriptorComposition = try await AppIPCDescriptorCatalogBuilder.buildOffMain(inputs: builderInputs)
        // The deferred initializer reports cancellation after this closure returns.
        guard !Task.isCancelled else { return nil }
        guard appIPCServer == nil else { return nil }

        var registrations = try AppIPCBuiltInMethodRegistrations.make(
            inputs: .init(
                catalog: descriptorComposition.builtInCatalog,
                runtimeId: runtimeId,
                ports: ports,
                eventBroker: eventBroker
            )
        )
        registrations += try AppIPCCommandMethodRegistrations.make(
            composition: descriptorComposition.commandComposition,
            port: ports.commandPort
        )
        return try AppIPCMethodRegistry(
            registrations: registrations,
            recognizedCommands: recognizedCommands,
            channel: channel,
            capabilitiesComposition: descriptorComposition.systemCapabilities
        )
    }

    private static func appIPCAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static func appIPCBuiltInMethodCatalogInputs() -> IPCBuiltInMethodCatalogInputs {
        IPCBuiltInMethodCatalogInputs(
            relationships: IPCBuiltInMethodRelationshipInputs(
                paneFocus: .appCommand(identifier: AppCommand.focusPane.rawValue),
                paneClose: .appCommand(identifier: AppCommand.closePane.rawValue),
                drawerToggle: .appCommand(identifier: AppCommand.toggleDrawer.rawValue),
                drawerAddPane: .appCommand(identifier: AppCommand.addDrawerPane.rawValue),
                bridgeDiffLoad: .appCommand(identifier: AppCommand.showBridgeReview.rawValue),
                bridgeFileViewOpen: .appCommand(identifier: AppCommand.showBridgeFiles.rawValue)
            ),
            examples: .init(illustrativeIdentifier: UUIDv7.generate())
        )
    }

    /// The channel this build serves. Composition reads `appIPCServerChannel`,
    /// which starts from this value.
    static func compiledAppIPCChannel() -> AgentStudioIPCChannel {
        #if DEBUG
            return .debug
        #else
            switch AppDataPaths.ReleaseChannel.current {
            case .stable:
                return .stable
            case .beta:
                return .beta
            }
        #endif
    }

    private var cliStoreChannel: CLIStoreChannel {
        switch appIPCServerChannel {
        case .stable: .stable
        case .beta: .beta
        case .debug: .debug
        }
    }

    private static func appIPCAccessMode() -> IPCAccessMode {
        #if DEBUG
            if ProcessInfo.processInfo.environment["AGENTSTUDIO_IPC_UNSAFE_NO_AUTH"] == "1" {
                return .unsafeDebug
            }
        #endif
        return .agentStudioOnly
    }

    private static func appIPCDebugCredentialEscrowURL() -> URL? {
        #if DEBUG
            guard
                let rawPath = ProcessInfo.processInfo
                    .environment[IPCDebugCredentialEscrowDocument.environmentVariableName]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawPath.isEmpty
            else {
                return nil
            }

            return URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath)
                .standardizedFileURL
        #else
            return nil
        #endif
    }

    private static func appIPCSocketDirectory() -> URL? {
        #if DEBUG
            guard
                let rawPath = ProcessInfo.processInfo.environment["AGENTSTUDIO_IPC_SOCKET_DIR"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawPath.isEmpty
            else {
                return nil
            }

            return URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath)
                .standardizedFileURL
        #else
            return nil
        #endif
    }
}

extension AppDelegate: PaneFocusAppControlling {
    func focusPane(_ paneId: UUID) async throws {
        guard let controller = mainWindowController, controller.acceptsIPCCommands,
            let focusControl = controller.makePaneFocusAppControl(store: store)
        else {
            throw AppIPCLayoutError(reason: .noActiveWindow)
        }
        try await focusControl.focusPane(paneId)
    }
}

import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

#if canImport(Darwin)
    import Darwin
#endif

public struct AgentStudioAppIPCServerError: Error, Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case accessModeOff
        case liveSocketAlreadyExists
        case socketUnlinkFailed
        case socketPermissionFailed
        case invalidParams
        case unauthenticated
    }

    public let reason: Reason
    public let errnoCode: Int32

    public init(reason: Reason, errnoCode: Int32 = 0) {
        self.reason = reason
        self.errnoCode = errnoCode
    }
}

public struct StaticApprovalPolicyStore: ApprovalPolicyStore {
    private let defaultDecision: ApprovalPolicyDecision

    public init(defaultDecision: ApprovalPolicyDecision = .ask) {
        self.defaultDecision = defaultDecision
    }

    public func decision(for _: PermissionRecord, requester _: IPCPrincipal) -> ApprovalPolicyDecision {
        defaultDecision
    }
}

public final class AgentStudioAppIPCServer: @unchecked Sendable {
    public let service: AgentStudioAppIPCService
    public let paths: AgentStudioIPCPaths
    public let channel: AgentStudioIPCChannel
    public let principalRegistry: AgentStudioIPCPrincipalRegistry
    public let grantLedger: GrantLedger

    private let listener: UnixSocketListener
    private let methodRegistry: AppIPCMethodRegistry
    private let authenticator: AgentStudioIPCAuthenticator
    private let credentialPersistenceLane: AgentStudioIPCCredentialPersistenceLane
    private let cliStoreReadThroughPort: (any AppIPCCLIStoreReadThroughPort)?
    let authorizationService: AuthorizationService
    let permissionBroker: PermissionBroker
    private let peerCredentialProvider: any PeerCredentialProviding
    private let peerCredentialGate: AgentStudioIPCPeerCredentialGate
    private let maxRequestFrameBytes: Int
    private let maxResponseFrameBytes: Int
    private let makeConnectionIO: @Sendable (UnixSocketConnection) -> AppIPCConnectionIO
    private let makeConnectionWriter: @Sendable (AppIPCConnectionIO, Int) -> AgentStudioAppIPCConnectionWriter
    private let lifecycleLock = NSLock()
    private var isRunning = false
    private var isStopping = false
    private var activeConnections: [ObjectIdentifier: UnixSocketConnection] = [:]
    private var activeConnectionContexts: [ObjectIdentifier: AgentStudioIPCAuthenticatedContext] = [:]
    /// One entry per connection handler `Task`, from acceptance until the
    /// handler itself finishes. `stopListenerAndConnections()` closes sockets
    /// but never clears this map — a stopped listener doesn't mean an
    /// in-flight handler has actually returned. Only the handler's own
    /// completion (in `unregisterConnection`) removes its entry, so
    /// `joinConnectionHandlers()` can prove every handler has drained.
    private var connectionHandlerTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    package init(
        service: AgentStudioAppIPCService,
        paths: AgentStudioIPCPaths,
        channel: AgentStudioIPCChannel,
        principalRegistry: AgentStudioIPCPrincipalRegistry,
        credentialContinuityPort: any AgentStudioIPCCredentialContinuityPort,
        cliStoreReadThroughPort: (any AppIPCCLIStoreReadThroughPort)?,
        approvalPolicyStore: any ApprovalPolicyStore = StaticApprovalPolicyStore(),
        peerCredentialProvider: any PeerCredentialProviding = DarwinPeerCredentialProvider(),
        currentUserIdentifier: uid_t = getuid(),
        maxRequestFrameBytes: Int = IPCFramePolicy.maximumRequestFrameBytes,
        maxResponseFrameBytes: Int = IPCFramePolicy.maximumResponseFrameBytes,
        makeConnectionIO: @escaping @Sendable (UnixSocketConnection) -> AppIPCConnectionIO = AppIPCConnectionIO.live,
        makeConnectionWriter: @escaping @Sendable (AppIPCConnectionIO, Int) -> AgentStudioAppIPCConnectionWriter = {
            AgentStudioAppIPCConnectionWriter(io: $0, maxFrameBytes: $1)
        }
    ) {
        self.service = service
        self.cliStoreReadThroughPort = cliStoreReadThroughPort
        self.paths = paths
        self.channel = channel
        self.methodRegistry = service.methodRegistry
        self.principalRegistry = principalRegistry
        self.grantLedger = principalRegistry.grantLedger
        self.authenticator = AgentStudioIPCAuthenticator(registry: principalRegistry)
        self.credentialPersistenceLane = AgentStudioIPCCredentialPersistenceLane(
            continuityPort: credentialContinuityPort
        )
        self.authorizationService = AuthorizationService(
            methodRegistry: methodRegistry,
            grantLedger: grantLedger,
            canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: service.ports.ownPaneScopePort,
            agentAuthorizationTelemetry: service.ports.agentAuthorizationTelemetry
        )
        self.permissionBroker = PermissionBroker(
            grantLedger: grantLedger,
            canonicalizer: PermissionScopeCanonicalizer(),
            approvalPolicyStore: approvalPolicyStore,
            humanApprovalPort: service.ports.permissionApprovalPort
        )
        self.listener = UnixSocketListener(endpoint: UnixSocketEndpoint(path: paths.socketURL.path))
        self.peerCredentialProvider = peerCredentialProvider
        self.peerCredentialGate = AgentStudioIPCPeerCredentialGate(currentUserIdentifier: currentUserIdentifier)
        self.maxRequestFrameBytes = maxRequestFrameBytes
        self.maxResponseFrameBytes = maxResponseFrameBytes
        self.makeConnectionIO = makeConnectionIO
        self.makeConnectionWriter = makeConnectionWriter
    }

    public func start(
        processIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        startedAt: Date = Date()
    ) throws {
        guard service.configuration.accessMode != .off else {
            throw AgentStudioAppIPCServerError(reason: .accessModeOff)
        }

        try AgentStudioIPCFilesystem.prepare(paths: paths)
        try resolveExistingSocketBeforeBind()
        setRunning(true)
        do {
            try listener.start { [self] connection in
                guard self.registerConnectionAndTrackHandler(connection) else {
                    connection.close()
                    return
                }
            }
            try secureSocketFile()
            let metadata = AgentStudioIPCRuntimeMetadata(
                runtimeId: service.configuration.runtimeId,
                processIdentifier: processIdentifier,
                channel: channel,
                socketPath: paths.socketURL.path,
                startedAt: startedAt
            )
            try AgentStudioIPCFilesystem.writeMetadata(metadata, paths: paths)
            for paneID in principalRegistry.finalRevokedPaneIDsSnapshot() {
                credentialPersistenceLane.enqueueFinalRevoke(paneID: paneID)
            }
            schedulePersistence(of: principalRegistry.issuedCredentialCandidates())
        } catch {
            stopListenerAndConnections()
            throw error
        }
    }

    public func stop() {
        markStopping()
        principalRegistry.shutdown()
        stopListenerAndConnections()
        principalRegistry.revokeAllGrants()
        try? FileManager.default.removeItem(at: paths.metadataURL)
    }

    /// Ends the accepting side: no new connection is admitted, live ones are
    /// closed, and any further request is refused. Unsaved credentials are
    /// snapshotted and queued here, while the registry still holds them; this
    /// call performs no durable write of its own and never waits for one, so a
    /// caller may run it before persisting other state.
    package func stopAcceptingConnections() {
        markStopping()
        let shutdownSnapshot = principalRegistry.beginGracefulShutdownAndSnapshotUnsavedCredentials()
        schedulePersistence(of: shutdownSnapshot)
        stopListenerAndConnections()
        principalRegistry.revokeAllGrants()
        try? FileManager.default.removeItem(at: paths.metadataURL)
    }

    /// Waits for the credential writes queued by `stopAcceptingConnections()`.
    /// This is the durable half and the only part that touches storage.
    package func drainCredentialPersistence() async -> AgentStudioIPCCredentialPersistenceDrainResult {
        await credentialPersistenceLane.drain()
    }

    public func invalidatePrincipals(boundToPaneId paneId: String) {
        principalRegistry.invalidatePrincipals(boundToPaneId: paneId)
        let connections = lifecycleLock.withLock {
            let matchingConnectionIdentifiers =
                activeConnectionContexts
                .filter { _, context in context.principal.isBound(toPaneId: paneId) }
                .map(\.key)
            for connectionIdentifier in matchingConnectionIdentifiers {
                activeConnectionContexts.removeValue(forKey: connectionIdentifier)
            }
            return matchingConnectionIdentifiers.compactMap { connectionIdentifier in
                activeConnections.removeValue(forKey: connectionIdentifier)
            }
        }
        for connection in connections {
            connection.close()
        }
    }

    package func finalRevokePrincipals(boundToPaneID paneID: UUID) {
        principalRegistry.finalRevokePane(paneID)
        closeConnections(boundToPaneID: paneID.uuidString)
        credentialPersistenceLane.enqueueFinalRevoke(paneID: paneID)
    }

    private func closeConnections(boundToPaneID paneID: String) {
        let connections = lifecycleLock.withLock {
            let matchingConnectionIdentifiers =
                activeConnectionContexts
                .filter { _, context in context.principal.isBound(toPaneId: paneID) }
                .map(\.key)
            for connectionIdentifier in matchingConnectionIdentifiers {
                activeConnectionContexts.removeValue(forKey: connectionIdentifier)
            }
            return matchingConnectionIdentifiers.compactMap { connectionIdentifier in
                activeConnections.removeValue(forKey: connectionIdentifier)
            }
        }
        for connection in connections {
            connection.close()
        }
    }

    private func handleRegisteredConnection(
        _ connection: UnixSocketConnection,
        io: AppIPCConnectionIO,
        writer: AgentStudioAppIPCConnectionWriter
    ) async {
        defer {
            unregisterConnection(connection)
            connection.close()
        }

        let connectionId = UUIDv7.generate()
        await handleConnectionRequests(connection, connectionId: connectionId, io: io, writer: writer)
        await service.eventBroker.removeSubscriptions(connectionId: connectionId)
        await writer.finishAcceptedOutput()
    }

    private func handleConnectionRequests(
        _ connection: UnixSocketConnection, connectionId: UUID,
        io: AppIPCConnectionIO, writer: AgentStudioAppIPCConnectionWriter
    ) async {

        do {
            let credentials = try connection.peerCredentials(using: peerCredentialProvider)
            try peerCredentialGate.validate(credentials)
        } catch {
            return
        }

        let socketSubscriber = AgentStudioAppIPCSocketEventSubscriber(writer: writer)
        let connectionState = AgentStudioAppIPCConnectionState()

        let reader = AgentStudioAppIPCConnectionReader(
            methodRegistry: methodRegistry, connection: connection, io: io, writer: writer,
            maxRequestFrameBytes: maxRequestFrameBytes,
            isStopping: { [self] in serverIsStopping() },
            executeRequest: { [self] request, replyId, state in
                try await process(
                    request, replyId: replyId, connection: connection, connectionId: connectionId,
                    connectionState: state, socketSubscriber: socketSubscriber
                )
            }
        )
        await reader.run(connectionState: connectionState)
    }

    private func process(
        _ request: JSONRPCRequest,
        replyId: JSONRPCIdentifier,
        connection: UnixSocketConnection,
        connectionId: UUID,
        connectionState: AgentStudioAppIPCConnectionState,
        socketSubscriber: any IPCEventSubscriber
    ) async throws -> AppIPCInvocationResult {
        guard serverIsRunning() else { throw AgentStudioAppIPCRequestError.unauthenticated }
        let registration = methodRegistry.registration(named: request.method)
        guard registration != nil || methodRegistry.recognizesMethod(named: request.method) else {
            throw AgentStudioAppIPCRequestError.methodNotFound
        }
        if connectionState.principal == nil, !connectionState.authenticationFailed,
            request.method != "auth.login", allowsUnsafeDebugNoAuthentication
        {
            let principal = IPCPrincipal(
                principalId: UUIDv7.generate(), runtimeId: service.configuration.runtimeId,
                accessMode: .unsafeDebug, kind: .unsafeDebugClient, approvalAuthority: .noApprovalAuthority
            )
            let context = AgentStudioIPCAuthenticatedContext(
                principal: principal,
                credentialIdentity: .diagnostic(generationID: UUIDv7.generate())
            )
            guard recordAuthenticatedContext(context, for: connection) else {
                throw AgentStudioAppIPCRequestError.unauthenticated
            }
            connectionState.setAuthenticatedContext(context)
        }
        if let authenticatedContext = connectionState.authenticatedContext,
            request.method != "auth.login",
            !AgentStudioIPCPreAuthMethods.isAllowed(request.method),
            !isExplicitUnsafeNoAuthenticationContext(authenticatedContext),
            !(await principalRegistry.contextRemainsAuthorized(authenticatedContext))
        {
            throw AgentStudioAppIPCRequestError.unauthenticated
        }
        if let principal = connectionState.principal, case .spawnedPaneAgent = principal.kind,
            let refusal = authorizationService.paneAgentRoutingRefusal(
                methodName: request.method, parameters: request.params)
        {
            throw refusal
        }
        guard let registration else { throw AgentStudioAppIPCRequestError.methodNotFound }
        let replyEnvelopeOverheadBytes =
            request.method == "pane.context.get"
            ? try AppIPCPaneContextReplyBudget.envelopeOverheadBytes(id: replyId) : 0
        let context = AppIPCConnectionContext(
            contextId: connectionId, channel: channel,
            authenticatedContext: connectionState.authenticatedContext,
            authenticate: { [self] params in
                do {
                    let authenticatedContext = try await authenticator.login(
                        subjectToken: AgentStudioIPCSubjectToken(rawValue: params.token)
                    ).authenticatedContext
                    guard authenticatedContextIsAllowedOnChannel(authenticatedContext) else {
                        principalRegistry.releaseLease(authenticatedContext)
                        throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
                    }
                    guard recordAuthenticatedContext(authenticatedContext, for: connection) else {
                        principalRegistry.releaseLease(authenticatedContext)
                        throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
                    }
                    if let replaced = connectionState.replaceAuthenticatedContext(authenticatedContext) {
                        principalRegistry.releaseLease(replaced)
                    }
                    if let candidate = authenticatedContext.persistenceCandidate {
                        schedulePersistence(of: [candidate])
                    }
                    let principal = authenticatedContext.principal
                    let readThrough = await cliStoreReadThroughPort?.readThrough()
                    return .authenticated(
                        principalId: principal.principalId, runtimeId: principal.runtimeId,
                        accessMode: principal.accessMode, cliStoreReadThrough: readThrough)
                } catch {
                    if let rejected = connectionState.rejectAuthentication() {
                        principalRegistry.releaseLease(rejected)
                    }
                    clearAuthenticatedContext(for: connection)
                    throw error
                }
            },
            authenticationStatus: {
                // Status is the connection-local principal snapshot. Login
                // supplies the separately read store cursor for call cleanup.
                guard let principal = connectionState.principal else { return .unauthenticated }
                return .authenticated(
                    principalId: principal.principalId, runtimeId: principal.runtimeId, accessMode: principal.accessMode
                )
            },
            eventSubscriber: socketSubscriber,
            connectionEndCause: { [self] in
                connectionState.endCause ?? (serverIsStopping() ? .stopping : .eof)
            },
            replyEnvelopeOverheadBytes: replyEnvelopeOverheadBytes
        )
        let tools = AppIPCTargetResolutionTools { [self] rawHandle in
            try await canonicalHandle(fromRawHandle: rawHandle, principal: context.principal)
        }
        do {
            return try await registration.invoke(
                parameters: request.params ?? .object([:]), connectionContext: context, targetResolutionTools: tools,
                authorize: { [self] principal, authorization in
                    try await authorizationService.authorize(principal: principal, request: authorization)
                }
            )
        } catch let error as IPCSchemaValidationError {
            guard registration.descriptor.metadata.executionOwner == .paneContextService else { throw error }
            // Only the new pane-context methods use their typed field refusal;
            // every existing registration keeps its established error bytes.
            throw AppIPCPaneContextError.schemaRefusal(error)
        }
    }

    private func schedulePersistence(of credentials: [AgentStudioIPCIssuedPaneCredential]) {
        for credential in credentials {
            guard principalRegistry.registrationRemainsEligible(credential) else { continue }
            credentialPersistenceLane.enqueueRegistration(
                credential,
                remainsEligible: { [weak principalRegistry] in
                    principalRegistry?.registrationRemainsEligible(credential) == true
                },
                didPersist: { [weak principalRegistry] in
                    principalRegistry?.markIssuedCredentialDurable(recordID: credential.credentialRecordID)
                }
            )
        }
    }

    private func isExplicitUnsafeNoAuthenticationContext(_ context: AgentStudioIPCAuthenticatedContext) -> Bool {
        allowsUnsafeDebugNoAuthentication
            && context.principal.accessMode == .unsafeDebug
            && context.principal.kind == .unsafeDebugClient
    }

    private func canonicalHandle(fromRawHandle rawHandle: String, principal: IPCPrincipal?) async throws -> IPCHandle {
        let selector: IPCTargetSelector
        do { selector = try IPCTargetSelector.parse(rawHandle, expectedKind: .pane) } catch {
            throw AgentStudioAppIPCRequestError.invalidParams
        }
        let paneId: UUID
        switch selector {
        case .selfPane:
            guard let principal, case .spawnedPaneAgent(let rawId, _) = principal.kind,
                let boundId = UUID(uuidString: rawId)
            else {
                throw AgentStudioAppIPCRequestError.unauthorized
            }
            paneId = boundId
        case .paneOrdinal(let ordinal):
            let panes = try await service.ports.queryPort.listPanes().panes
            guard panes.indices.contains(ordinal - 1) else { throw AppIPCQueryError(reason: .targetNotFound) }
            paneId = panes[ordinal - 1].id
        case .canonical(let kind, let id):
            guard kind == .pane else { throw AgentStudioAppIPCRequestError.invalidParams }
            paneId = id
        }
        _ = try await service.ports.queryPort.snapshotPane(paneId, ownPaneAssertion: nil)
        return IPCHandle(kind: .pane, reference: .canonicalUUID(paneId))
    }

    private func resolveExistingSocketBeforeBind() throws {
        guard FileManager.default.fileExists(atPath: paths.socketURL.path) else {
            return
        }

        do {
            let connection = try UnixSocketClient.connect(endpoint: UnixSocketEndpoint(path: paths.socketURL.path))
            connection.close()
            throw AgentStudioAppIPCServerError(reason: .liveSocketAlreadyExists)
        } catch let error as AgentStudioAppIPCServerError {
            throw error
        } catch {
            #if canImport(Darwin)
                guard unlink(paths.socketURL.path) == 0 else {
                    throw AgentStudioAppIPCServerError(reason: .socketUnlinkFailed, errnoCode: errno)
                }
            #else
                throw AgentStudioAppIPCServerError(reason: .socketUnlinkFailed)
            #endif
        }
    }

    private func secureSocketFile() throws {
        #if canImport(Darwin)
            guard chmod(paths.socketURL.path, 0o600) == 0 else {
                throw AgentStudioAppIPCServerError(reason: .socketPermissionFailed, errnoCode: errno)
            }
        #else
            throw AgentStudioAppIPCServerError(reason: .socketPermissionFailed)
        #endif
    }

    private func setRunning(_ running: Bool) {
        lifecycleLock.withLock {
            isRunning = running
            if running { isStopping = false }
        }
    }

    private func markStopping() {
        lifecycleLock.withLock { isStopping = true }
    }

    private func serverIsStopping() -> Bool {
        lifecycleLock.withLock { isStopping }
    }

    private func serverIsRunning() -> Bool {
        lifecycleLock.withLock {
            isRunning
        }
    }

    private var allowsUnsafeDebugNoAuthentication: Bool {
        service.configuration.accessMode == .unsafeDebug && channel == .debug
    }

    private func authenticatedContextIsAllowedOnChannel(
        _ context: AgentStudioIPCAuthenticatedContext
    ) -> Bool {
        switch context.principal.kind {
        case .spawnedPaneAgent:
            true
        case .automationClient, .futureMCPClient, .unsafeDebugClient:
            channel == .debug
        }
    }

    /// Registers the connection and spawns its handler `Task` in the same
    /// locked section that records it, so a handler that finishes
    /// immediately can never remove an entry before this call inserted it.
    private func registerConnectionAndTrackHandler(_ connection: UnixSocketConnection) -> Bool {
        guard serverIsRunning() else { return false }
        // The listener invokes acceptance on its own GCD queue. Construct
        // connection I/O there, outside the lifecycle lock and cooperative pool.
        let io = makeConnectionIO(connection)
        let writer = makeConnectionWriter(io, maxResponseFrameBytes)
        return lifecycleLock.withLock {
            guard isRunning else {
                return false
            }
            let connectionIdentifier = ObjectIdentifier(connection)
            activeConnections[connectionIdentifier] = connection
            connectionHandlerTasks[connectionIdentifier] = Task { [self] in
                await handleRegisteredConnection(connection, io: io, writer: writer)
            }
            return true
        }
    }

    private func unregisterConnection(_ connection: UnixSocketConnection) {
        let releasedContext: AgentStudioIPCAuthenticatedContext? = lifecycleLock.withLock {
            let connectionIdentifier = ObjectIdentifier(connection)
            // Always removes its own handler entry, even after a stop has
            // already cleared `activeConnections` below — completion is the
            // only thing `joinConnectionHandlers()` waits for.
            connectionHandlerTasks.removeValue(forKey: connectionIdentifier)
            guard activeConnections[connectionIdentifier] === connection else { return nil }
            _ = activeConnections.removeValue(forKey: connectionIdentifier)
            return activeConnectionContexts.removeValue(forKey: connectionIdentifier)
        }
        if let releasedContext {
            principalRegistry.releaseLease(releasedContext)
        }
    }

    /// Cancels every tracked connection handler and awaits its completion.
    /// Callers close connections first (`stopAcceptingConnections()`/`stop()`),
    /// which is what actually unblocks a handler waiting on the socket;
    /// cancellation only reaches handlers suspended on cancellation-aware
    /// work. No timeout here — the caller's own termination deadline bounds
    /// this call.
    package func joinConnectionHandlers() async {
        let tasks = lifecycleLock.withLock { Array(connectionHandlerTasks.values) }
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    /// Test-observable count of connection handlers still tracked, so
    /// `joinConnectionHandlers()`'s postcondition — an empty tracked set —
    /// can be asserted without polling or timing.
    package var trackedConnectionHandlerCount: Int {
        lifecycleLock.withLock { connectionHandlerTasks.count }
    }

    private func recordAuthenticatedContext(
        _ context: AgentStudioIPCAuthenticatedContext,
        for connection: UnixSocketConnection
    ) -> Bool {
        lifecycleLock.withLock {
            let connectionIdentifier = ObjectIdentifier(connection)
            guard isRunning, activeConnections[connectionIdentifier] === connection else { return false }
            activeConnectionContexts[connectionIdentifier] = context
            return true
        }
    }

    private func clearAuthenticatedContext(for connection: UnixSocketConnection) {
        lifecycleLock.withLock {
            _ = activeConnectionContexts.removeValue(forKey: ObjectIdentifier(connection))
        }
    }

    private func stopListenerAndConnections() {
        let connections = lifecycleLock.withLock {
            isRunning = false
            let connections = Array(activeConnections.values)
            activeConnections.removeAll(keepingCapacity: false)
            activeConnectionContexts.removeAll(keepingCapacity: false)
            return connections
        }
        listener.stop()
        for connection in connections {
            connection.close()
        }
    }
}

extension IPCPrincipal {
    fileprivate func isBound(toPaneId paneId: String) -> Bool {
        switch kind {
        case .spawnedPaneAgent(let boundPaneId, _):
            boundPaneId == paneId
        case .automationClient, .futureMCPClient, .unsafeDebugClient:
            false
        }
    }

    fileprivate func isBound(toPaneId paneId: String, workspaceID: UUID) -> Bool {
        switch kind {
        case .spawnedPaneAgent(let boundPaneId, let boundWorkspaceID):
            boundPaneId == paneId && boundWorkspaceID == workspaceID
        case .automationClient, .futureMCPClient, .unsafeDebugClient:
            false
        }
    }
}

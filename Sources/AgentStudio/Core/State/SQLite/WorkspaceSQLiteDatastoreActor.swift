import AgentStudioInfrastructure
import Foundation
import GRDB

package actor WorkspaceSQLiteDatastoreActor {
    private static let applicationLocalRepositoryScopeId = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private enum DatabasePreparationState {
        case unprepared
        case prepared(DatabasePreparationReceipt)
        case failed(CoreDatabasePreparationFailure)
    }

    private struct ApplicationLocalRepositoryBundle: Sendable {
        let applicationRepository: WorkspaceLocalRepository
        func repository(workspaceId: UUID) -> WorkspaceLocalRepository {
            WorkspaceLocalRepository(workspaceId: workspaceId, databaseWriter: applicationRepository.databaseWriter)
        }
    }

    private struct PreparedLocalDatabaseOutcome {
        var database: PreparedLocalDatabase
        var diagnostic: WorkspaceSQLitePreparationTraceRecord?
    }
    private(set) var backend: WorkspaceSQLiteStoreBackend?
    private var applicationLocalRepositoryBundle: ApplicationLocalRepositoryBundle?
    private let configuration: WorkspaceSQLiteDatastoreConfiguration?
    private let beforeFreshLocalDatabaseCreation: (@Sendable () throws -> Void)?
    private let localDatabaseReplacementObserver: WorkspaceLocalDatabaseReplacementObserver?
    private let probe: (@Sendable (ProbeEvent) async -> Void)?
    private let traceRecorder: WorkspaceSQLiteTraceRecorder

    private var databasePreparationState: DatabasePreparationState
    private var preparedCoreSnapshotConsumed: Bool
    // Accessed by the datastore persistence-order extension; never exposed outside Core.
    var workspaceSaveTail: Task<Void, Error>?
    var workspaceSaveTailGeneration: UInt64 = 0
    var repositoryLocalCleanupPending = true
    var retentionSurvivingIdentity: RepositoryRetentionSurvivingIdentity?
    var acceptedRepositoryTopologyCaptureRevision: UInt64?
    var acceptedWorkspaceCaptureRevisions: [UUID: WorkspaceCompositionRevision] = [:]
    var acceptedDrawerPresentationRevisions: [UUID: Int] = [:]
    var failedStructuralWorkspaceIDs = Set<UUID>()

    init(
        configuration: WorkspaceSQLiteDatastoreConfiguration,
        traceRuntime: AgentStudioTraceRuntime? = nil,
        beforeFreshLocalDatabaseCreation: (@Sendable () throws -> Void)? = nil,
        localDatabaseReplacementObserver: WorkspaceLocalDatabaseReplacementObserver? = nil,
        probe: (@Sendable (ProbeEvent) async -> Void)? = nil
    ) {
        self.backend = nil
        self.applicationLocalRepositoryBundle = nil
        self.configuration = configuration
        self.beforeFreshLocalDatabaseCreation = beforeFreshLocalDatabaseCreation
        self.localDatabaseReplacementObserver = localDatabaseReplacementObserver
        self.probe = probe
        self.traceRecorder = WorkspaceSQLiteTraceRecorder(traceRuntime: traceRuntime)
        self.databasePreparationState = .unprepared
        self.preparedCoreSnapshotConsumed = false
    }

    package init(
        preparedCoreRepository: WorkspaceCoreRepository,
        preparationReceipt: DatabasePreparationReceipt,
        preparedApplicationLocalRepository: WorkspaceLocalRepository?,
        traceRuntime: AgentStudioTraceRuntime? = nil,
        probe: (@Sendable (ProbeEvent) async -> Void)? = nil
    ) {
        switch (preparationReceipt.local, preparedApplicationLocalRepository) {
        case (.available, .some), (.unavailable, .none):
            break
        case (.available, .none), (.unavailable, .some):
            preconditionFailure("Prepared local receipt and repository capability must agree")
        }
        self.backend = WorkspaceSQLiteStoreBackend(
            coreRepository: preparedCoreRepository,
            makeLocalRepository: { _ in
                throw WorkspaceSQLiteDatastoreError.useDatastoreApplicationLocalRepositoryBundle
            },
            makeLocalRestoreRepository: { _ in
                throw WorkspaceSQLiteDatastoreError.useDatastoreApplicationLocalRepositoryBundle
            },
            coreDatabaseStartupProvenance: .createdDuringCurrentStartup
        )
        self.configuration = nil
        self.applicationLocalRepositoryBundle = preparedApplicationLocalRepository.map(
            ApplicationLocalRepositoryBundle.init(applicationRepository:)
        )
        self.beforeFreshLocalDatabaseCreation = nil
        self.localDatabaseReplacementObserver = nil
        self.probe = probe
        self.traceRecorder = WorkspaceSQLiteTraceRecorder(traceRuntime: traceRuntime)
        self.databasePreparationState = .prepared(preparationReceipt)
        self.preparedCoreSnapshotConsumed = false
    }

    package func prepareDatabasesForBoot() async -> DatabasePreparationResult {
        switch databasePreparationState {
        case .prepared(let receipt):
            return .prepared(receipt)
        case .failed(let failure):
            return .failed(failure)
        case .unprepared:
            break
        }

        let preparedCore: PreparedCoreDatabase
        do {
            preparedCore = try prepareCoreDatabaseForBoot()
        } catch {
            let failure =
                (error as? CoreDatabasePreparationFailure)
                ?? CoreDatabasePreparationFailure(
                    kind: .sqliteUnavailable,
                    failure: WorkspaceSQLiteDatastoreFailure(error)
                )
            databasePreparationState = .failed(failure)
            await traceRecorder.recordPreparation(
                .init(
                    database: .core,
                    phase: .prepareCore,
                    classification: WorkspaceSQLiteRecoveryClassifier.shouldQuarantine(error)
                        ? .corruptDatabase
                        : .coreAcceptanceFailed,
                    recoveryAttempt: .notAttempted,
                    disposition: .bootStopped,
                    sqliteResultCode: Self.sqliteResultCode(error),
                    errorType: String(reflecting: type(of: error)),
                    errorCase: (error as? WorkspaceCoreRepositoryError).flatMap {
                        Mirror(reflecting: $0).children.first?.label
                    }
                )
            )
            return .failed(failure)
        }

        let preparedLocal = prepareLocalDatabaseForBoot()
        let receipt = DatabasePreparationReceipt(core: preparedCore, local: preparedLocal.database)
        databasePreparationState = .prepared(receipt)
        if let diagnostic = preparedLocal.diagnostic {
            await traceRecorder.recordPreparation(diagnostic)
        }
        return .prepared(receipt)
    }

    func journalRepository() throws -> WorkspaceCoreRepository {
        try resolvedBackend().coreRepository
    }

    func performWorkspaceSnapshotBundleSave(
        _ bundle: WorkspaceSQLiteSaveBundle,
        undoChange: WorkspaceUndoJournalChange?
    ) async throws -> WorkspaceUndoJournalReceipt? {
        let admittedBundle = try workspaceBundleAdmittedForCurrentTopologyContext(bundle)
        let snapshot = admittedBundle.workspace
        await recordProbe(.saveWorkspaceSnapshot)
        var failurePhase = WorkspaceSQLiteTracePhase.openCore
        var failureDatabase: WorkspaceSQLiteTraceDatabase? = .core
        let journalReceipt: WorkspaceUndoJournalReceipt?
        await traceRecorder.recordOperation(
            .workspaceSave,
            phase: .commitCore,
            lane: .workspace,
            outcome: .started,
            workspaceId: snapshot.id,
            database: .core
        )
        await traceRecorder.recordSnapshot(
            .init(
                snapshot: snapshot,
                operation: .workspaceSave,
                phase: .commitCore,
                outcome: .started,
                error: nil
            )
        )
        let backend: WorkspaceSQLiteStoreBackend
        do {
            backend = try resolvedBackend()
            failurePhase = .commitCore
            failureDatabase = .core
            if undoChange != nil {
                try requireJournalMutationAdmission(reconciling: snapshot.id)
            }
            journalReceipt = try backend.replaceWorkspaceSnapshot(
                admittedBundle, updatesActiveSelection: true, undoChange: undoChange)
            if let revision = admittedBundle.captureRevision {
                acceptedWorkspaceCaptureRevisions[snapshot.id] = revision
            }
            failedStructuralWorkspaceIDs.remove(snapshot.id)
        } catch {
            if (error as? WorkspaceSQLiteDatastoreError) != .unreconciledStructuralSave {
                failedStructuralWorkspaceIDs.insert(snapshot.id)
            }
            await recordWorkspaceSaveFailure(
                snapshot: snapshot,
                phase: failurePhase,
                database: failureDatabase,
                error: error
            )
            await recordProbe(.saveWorkspaceSnapshotFailed)
            throw error
        }
        await traceRecorder.recordOperation(
            .workspaceSave,
            phase: .commitCore,
            lane: .workspace,
            outcome: .succeeded,
            workspaceId: snapshot.id,
            database: .core
        )
        if undoChange != nil {
            await recordProbe(.saveWorkspaceSnapshotSucceeded)
            return journalReceipt
        }
        do {
            failurePhase = .openLocalSave
            failureDatabase = .local
            let localRepository = try preparedLocalRepository(workspaceId: snapshot.id)
            failurePhase = .writeLocal
            failureDatabase = .local
            await traceRecorder.recordOperation(
                .workspaceSave,
                phase: .writeLocal,
                lane: .workspace,
                outcome: .started,
                workspaceId: snapshot.id,
                database: .local
            )
            try backend.writeLocalSnapshot(snapshot, localRepository: localRepository)
            recordAcceptedDrawerPresentationRevision(of: admittedBundle)
            await traceRecorder.recordOperation(
                .workspaceSave,
                phase: .writeLocal,
                lane: .workspace,
                outcome: .succeeded,
                workspaceId: snapshot.id,
                database: .local
            )
            await recordProbe(.saveWorkspaceSnapshotSucceeded)
        } catch {
            await recordLocalWorkspaceSaveFailure(
                workspaceId: snapshot.id,
                phase: failurePhase,
                error: error
            )
            await recordProbe(.saveWorkspaceSnapshotFailed)
            throw error
        }
        return journalReceipt
    }

    private func recordLocalWorkspaceSaveFailure(
        workspaceId: UUID,
        phase: WorkspaceSQLiteTracePhase,
        error: any Error
    ) async {
        await traceRecorder.recordOperation(
            .workspaceSave,
            phase: phase,
            lane: .workspace,
            outcome: .failed,
            workspaceId: workspaceId,
            database: .local,
            error: error
        )
        await traceRecorder.recordRecovery(
            .init(
                recoveryKind: .saveFailed,
                operation: .workspaceSave,
                phase: phase,
                lane: .workspace,
                outcome: .failed,
                workspaceId: workspaceId,
                database: .local,
                databaseURL: nil,
                error: error
            )
        )
    }

    private func recordWorkspaceSaveFailure(
        snapshot: WorkspaceSQLiteSnapshot,
        phase: WorkspaceSQLiteTracePhase,
        database: WorkspaceSQLiteTraceDatabase?,
        error: any Error
    ) async {
        await traceRecorder.recordSnapshot(
            .init(
                snapshot: snapshot,
                operation: .workspaceSave,
                phase: phase,
                outcome: .failed,
                error: error
            )
        )
        await traceRecorder.recordOperation(
            .workspaceSave,
            phase: phase,
            lane: .workspace,
            outcome: .failed,
            workspaceId: snapshot.id,
            database: database,
            error: error
        )
        await traceRecorder.recordRecovery(
            .init(
                recoveryKind: .saveFailed,
                operation: .workspaceSave,
                phase: phase,
                lane: .workspace,
                outcome: .failed,
                workspaceId: snapshot.id,
                database: database,
                databaseURL: nil,
                error: error
            )
        )
    }

    func loadAuthoritativeCoreSnapshot() async -> CoreLoadResult {
        await recordProbe(.loadWorkspaceSnapshot)
        switch databasePreparationState {
        case .unprepared:
            return .unavailable(.init(WorkspaceSQLiteDatastoreError.databasesNotPrepared))
        case .failed(let failure):
            return .unavailable(failure.failure)
        case .prepared(let receipt):
            if !preparedCoreSnapshotConsumed {
                preparedCoreSnapshotConsumed = true
                switch receipt.core {
                case .ready(let authoritativeSnapshot):
                    do {
                        guard let backend else {
                            return .unavailable(.init(WorkspaceSQLiteDatastoreError.databasesNotPrepared))
                        }
                        let localRepository = try? preparedLocalRepository(
                            workspaceId: authoritativeSnapshot.workspace.id
                        )
                        return .loaded(
                            try await backend.loadCompletedSnapshot(
                                authoritativeSnapshot: authoritativeSnapshot,
                                localRepositoryForWorkspaceId: { _ in
                                    guard let localRepository else {
                                        throw WorkspaceSQLiteDatastoreError.applicationLocalRepositoryUnavailable
                                    }
                                    return localRepository
                                }
                            )
                        )
                    } catch {
                        return .unavailable(.init(error))
                    }
                case .uninitialized:
                    return .uninitialized
                }
            }
        }
        await traceRecorder.recordOperation(
            .workspaceLoad,
            phase: .openCore,
            lane: .workspace,
            outcome: .started,
            workspaceId: nil,
            database: .core
        )
        do {
            let backend = try resolvedBackendForWorkspaceStartup()
            let snapshot = try await backend.loadCompletedSnapshot(
                localRepositoryForWorkspaceId: { workspaceId in
                    try await self.preparedLocalRepository(workspaceId: workspaceId)
                }
            )
            await traceRecorder.recordOperation(
                .workspaceLoad,
                phase: .openCore,
                lane: .workspace,
                outcome: .succeeded,
                workspaceId: snapshot.workspace.id,
                database: .core
            )
            return .loaded(snapshot)
        } catch is BackendUninitializedError {
            await traceRecorder.recordOperation(
                .workspaceLoad,
                phase: .openCore,
                lane: .workspace,
                outcome: .skipped,
                workspaceId: nil,
                database: .core
            )
            return .uninitialized
        } catch {
            await traceRecorder.recordOperation(
                .workspaceLoad,
                phase: .openCore,
                lane: .workspace,
                outcome: .failed,
                workspaceId: nil,
                database: .core,
                error: error
            )
            return .unavailable(.init(error))
        }
    }

    func loadRepositoryTopologySnapshot() async -> RepositoryTopologyLoadResult {
        do {
            let backend = try resolvedBackend()
            return .loaded(try backend.fetchRepositoryTopologySnapshot())
        } catch is BackendUninitializedError {
            return .uninitialized
        } catch {
            return .unavailable(.init(error))
        }
    }

    func selectActiveWorkspace(_ workspaceId: UUID, updatedAt: Date) async throws {
        try resolvedBackend().selectActiveWorkspace(workspaceId, updatedAt: updatedAt)
    }

    func loadRepoCacheState() async -> LocalCacheLoadResult {
        do {
            let repository = try preparedApplicationLocalRepository()
            return .loaded(filterRetiredCacheState(try repository.fetchCacheState()))
        } catch {
            return .unavailable(.init(error))
        }
    }

    func saveRepoCacheState(
        cacheState: WorkspaceLocalRepository.CacheStateRecord
    ) async throws {
        await traceRecorder.recordOperation(
            .repoCacheSave,
            phase: .writeLocal,
            lane: .repoCache,
            outcome: .started,
            workspaceId: nil,
            database: .local
        )
        guard !Task.isCancelled else {
            await traceRecorder.recordOperation(
                .repoCacheSave,
                phase: .writeLocal,
                lane: .repoCache,
                outcome: .skipped,
                workspaceId: nil,
                database: .local
            )
            throw CancellationError()
        }
        let repository = try preparedApplicationLocalRepository()
        do {
            let updatedAt = Date()
            try repository.replaceCacheState(cacheState: filterRetiredCacheState(cacheState), updatedAt: updatedAt)
            await traceRecorder.recordOperation(
                .repoCacheSave,
                phase: .writeLocal,
                lane: .repoCache,
                outcome: .succeeded,
                workspaceId: nil,
                database: .local
            )
        } catch {
            await traceRecorder.recordOperation(
                .repoCacheSave,
                phase: .writeLocal,
                lane: .repoCache,
                outcome: .failed,
                workspaceId: nil,
                database: .local,
                error: error
            )
            throw error
        }
    }

    func loadUIState(workspaceContextId: UUID) async -> LocalUILoadResult {
        do {
            let repository = try preparedLocalRepository(workspaceId: workspaceContextId)
            let state = try repository.hasSidebarState() ? repository.fetchSidebarState() : nil
            return .loaded(state)
        } catch {
            return .unavailable(.init(error))
        }
    }

    func saveUIState(
        _ state: WorkspaceLocalRepository.SidebarStateRecord,
        workspaceContextId: UUID
    ) async throws {
        await traceRecorder.recordOperation(
            .uiStateSave,
            phase: .writeLocal,
            lane: .uiState,
            outcome: .started,
            workspaceId: workspaceContextId,
            database: .local
        )
        let repository = try preparedLocalRepository(workspaceId: workspaceContextId)
        do {
            try repository.replaceSidebarState(state, updatedAt: Date())
            await traceRecorder.recordOperation(
                .uiStateSave,
                phase: .writeLocal,
                lane: .uiState,
                outcome: .succeeded,
                workspaceId: workspaceContextId,
                database: .local
            )
        } catch {
            await traceRecorder.recordOperation(
                .uiStateSave,
                phase: .writeLocal,
                lane: .uiState,
                outcome: .failed,
                workspaceId: workspaceContextId,
                database: .local,
                error: error
            )
            throw error
        }
    }

    func loadSidebarState(workspaceContextId: UUID) async -> LocalSidebarLoadResult {
        do {
            let repository = try preparedLocalRepository(workspaceId: workspaceContextId)
            return .loaded(try repository.fetchCollapsedGroups())
        } catch {
            return .unavailable(.init(error))
        }
    }

    func saveSidebarState(
        collapsedGroups: Set<SidebarGroupKey>,
        workspaceContextId: UUID
    ) async throws {
        await traceRecorder.recordOperation(
            .sidebarSave,
            phase: .writeLocal,
            lane: .sidebar,
            outcome: .started,
            workspaceId: workspaceContextId,
            database: .local
        )
        let repository = try preparedLocalRepository(workspaceId: workspaceContextId)
        do {
            try repository.replaceCollapsedGroups(collapsedGroups, updatedAt: Date())
            await traceRecorder.recordOperation(
                .sidebarSave,
                phase: .writeLocal,
                lane: .sidebar,
                outcome: .succeeded,
                workspaceId: workspaceContextId,
                database: .local
            )
        } catch {
            await traceRecorder.recordOperation(
                .sidebarSave,
                phase: .writeLocal,
                lane: .sidebar,
                outcome: .failed,
                workspaceId: workspaceContextId,
                database: .local,
                error: error
            )
            throw error
        }
    }

    package func loadWorkspaceSettings(workspaceId: UUID) async -> LocalSettingsLoadResult {
        do {
            let repository = try preparedLocalRepository(workspaceId: workspaceId)
            return .loaded(
                .init(
                    editor: localSettingsValue { try repository.fetchEditorPreferences() },
                    repoExplorer: localSettingsValue { try repository.fetchRepoExplorerPreferences() }
                )
            )
        } catch {
            return .unavailable(.init(error))
        }
    }

    package func saveWorkspaceSettings(
        editor: WorkspaceLocalRepository.EditorPreferencesRecord,
        repoExplorer: WorkspaceLocalRepository.RepoExplorerPreferencesRecord,
        workspaceId: UUID
    ) async throws {
        let repository = try preparedLocalRepository(workspaceId: workspaceId)
        let updatedAt = Date()
        try repository.replaceEditorPreferences(editor, updatedAt: updatedAt)
        try repository.replaceRepoExplorerPreferences(repoExplorer, updatedAt: updatedAt)
    }

    private func localSettingsValue<Value: Equatable & Sendable>(
        _ load: () throws -> Value
    ) -> LocalSettingsValue<Value> {
        do {
            return .loaded(try load())
        } catch {
            return .defaulted(.init(error))
        }
    }

    func loadWorkspaceEntityRecency(workspaceId: UUID) async -> WorkspaceEntityRecencyLoadResult {
        do {
            let repository = try preparedLocalRepository(workspaceId: workspaceId)
            return .loaded(try repository.fetchWorkspaceEntityRecency())
        } catch {
            return .unavailable(.init(error))
        }
    }

    func saveWorkspaceEntityRecency(
        _ recentEntities: [WorkspaceEntityRecency], workspaceId: UUID
    ) async throws {
        let repository = try preparedLocalRepository(workspaceId: workspaceId)
        try repository.replaceWorkspaceEntityRecency(recentEntities)
    }

    package func performLocalRestoreOperation<Output: Sendable>(
        workspaceId: UUID,
        _ operation: @Sendable (WorkspaceLocalRepository) throws -> Output
    ) async -> LocalRepositoryOperationResult<Output> {
        do {
            let repository = try preparedLocalRepository(workspaceId: workspaceId)
            return .completed(try operation(repository))
        } catch {
            return .unavailable(.init(error))
        }
    }

    package func performLocalSaveOperation<Output: Sendable>(
        workspaceId: UUID,
        _ operation: @Sendable (WorkspaceLocalRepository) throws -> Output
    ) async throws -> Output {
        await traceRecorder.recordOperation(
            .inboxSave,
            phase: .writeLocal,
            lane: .inbox,
            outcome: .started,
            workspaceId: workspaceId,
            database: .local
        )
        let repository = try preparedLocalRepository(workspaceId: workspaceId)
        do {
            let output = try operation(repository)
            await traceRecorder.recordOperation(
                .inboxSave,
                phase: .writeLocal,
                lane: .inbox,
                outcome: .succeeded,
                workspaceId: workspaceId,
                database: .local
            )
            return output
        } catch {
            await traceRecorder.recordOperation(
                .inboxSave,
                phase: .writeLocal,
                lane: .inbox,
                outcome: .failed,
                workspaceId: workspaceId,
                database: .local,
                error: error
            )
            throw error
        }
    }
}

extension WorkspaceSQLiteDatastoreActor {
    private func prepareCoreDatabaseForBoot() throws -> PreparedCoreDatabase {
        guard let configuration else {
            throw WorkspaceSQLiteDatastoreError.missingConfiguration
        }

        let coreDatabaseExisted = FileManager.default.fileExists(
            atPath: configuration.coreDatabaseURL.path
        )
        guard coreDatabaseExisted else {
            let writableBackend = try openConfiguredBackend(configuration: configuration)
            backend = writableBackend
            return try Self.strictlyPrepareCore(using: writableBackend)
        }

        try WorkspaceSQLiteStartupSchemaPreparer.migratePreexistingDatabaseIfRequired(
            at: configuration.coreDatabaseURL,
            label: "AgentStudio.sqlite.core.startup-schema-check",
            migrator: WorkspaceCoreMigrations.migrator
        )
        let startupReader = try SQLiteDatabaseFactory.makeBytePreservingStartupReader(
            at: configuration.coreDatabaseURL,
            label: "AgentStudio.sqlite.core.startup-read"
        )
        let startupBackend = WorkspaceSQLiteStoreBackend(
            coreRepository: WorkspaceCoreRepository(databaseWriter: startupReader),
            makeLocalRepository: { _ in
                throw WorkspaceSQLiteDatastoreError.databasesNotPrepared
            },
            makeLocalRestoreRepository: { _ in
                throw WorkspaceSQLiteDatastoreError.databasesNotPrepared
            },
            coreDatabaseStartupProvenance: .preexisting
        )
        let preparedCore: PreparedCoreDatabase
        do {
            preparedCore = try Self.strictlyPrepareCore(using: startupBackend)
        } catch {
            try? startupReader.close()
            throw error
        }
        try startupReader.close()

        let writableBackend = try openConfiguredBackend(configuration: configuration)
        backend = writableBackend
        return preparedCore
    }

    static func strictlyPrepareCore(
        using backend: WorkspaceSQLiteStoreBackend
    ) throws -> PreparedCoreDatabase {
        do {
            let authoritativeSnapshot = try backend.strictlySelectedAuthoritativeSnapshot()
            let coreOnlySnapshot = try backend.loadCompletedSnapshot(
                authoritativeSnapshot: authoritativeSnapshot,
                localRepository: nil
            )
            switch WorkspaceCompositionPreparer.prepare(coreOnlySnapshot.workspace) {
            case .prepared:
                break
            case .rejected(let rejection):
                throw CoreDatabasePreparationFailure(
                    kind: .compositionRejected,
                    failure: WorkspaceSQLiteDatastoreFailure(rejection)
                )
            }
            switch WorkspacePersistenceTransformer.prepareRepositoryTopology(
                coreOnlySnapshot.repositoryTopology
            ) {
            case .prepared:
                break
            case .rejected(let rejection):
                throw CoreDatabasePreparationFailure(
                    kind: .topologyRejected,
                    failure: WorkspaceSQLiteDatastoreFailure(rejection)
                )
            }
            return .ready(authoritativeSnapshot)
        } catch is BackendUninitializedError {
            return .uninitialized
        }
    }

    private func prepareLocalDatabaseForBoot() -> PreparedLocalDatabaseOutcome {
        guard let configuration else {
            return localUnavailableOutcome(
                error: WorkspaceSQLiteDatastoreError.missingConfiguration,
                phase: .openLocal,
                classification: .localOpenFailed,
                recoveryAttempt: .notAttempted
            )
        }
        // Fixed before any local recovery branch can return: a boot that leaves
        // local storage unavailable still lets panes be created, and those must
        // be newer than the cutoff a later successful import uses.
        let legacyDrawerImportCutoff = configuration.legacyDrawerPresentationSource?
            .establishPendingImportCutoff(now: Date())

        let mainDatabaseExists = FileManager.default.fileExists(
            atPath: configuration.localDatabaseURL.path
        )
        let walExists = FileManager.default.fileExists(
            atPath: "\(configuration.localDatabaseURL.path)-wal"
        )
        let shmExists = FileManager.default.fileExists(
            atPath: "\(configuration.localDatabaseURL.path)-shm"
        )
        if !mainDatabaseExists, walExists || shmExists {
            return replaceLocalDatabaseForBoot(
                configuration: configuration,
                reason: .incompleteFileSet,
                legacyDrawerImportCutoff: legacyDrawerImportCutoff
            )
        }

        do {
            let repository = try Self.openConfiguredLocalRepository(
                workspaceId: Self.applicationLocalRepositoryScopeId,
                configuration: configuration,
                legacyDrawerPresentationCapture: captureLegacyDrawerPresentationImport(
                    configuration: configuration,
                    importCutoff: legacyDrawerImportCutoff
                )
            )
            applicationLocalRepositoryBundle = .init(applicationRepository: repository)
            return .init(database: .available(recovery: nil), diagnostic: nil)
        } catch {
            guard WorkspaceSQLiteRecoveryClassifier.shouldQuarantine(error) else {
                return localUnavailableOutcome(
                    error: error,
                    phase: .openLocal,
                    classification: .localOpenFailed,
                    recoveryAttempt: .notAttempted
                )
            }
            return replaceLocalDatabaseForBoot(
                configuration: configuration,
                reason: .corruptDatabase,
                legacyDrawerImportCutoff: legacyDrawerImportCutoff
            )
        }
    }

    private func replaceLocalDatabaseForBoot(
        configuration: WorkspaceSQLiteDatastoreConfiguration,
        reason: LocalDatabaseRecoveryReason,
        legacyDrawerImportCutoff: Date?
    ) -> PreparedLocalDatabaseOutcome {
        let recoveredAt = Date()
        let quarantine = SQLiteSidecarQuarantine.quarantine(
            databaseURL: configuration.localDatabaseURL,
            date: recoveredAt
        )
        guard quarantine.succeeded else {
            return localUnavailableOutcome(
                error: WorkspaceLocalSQLiteStoreBackendError.quarantineFailed(
                    Self.applicationLocalRepositoryScopeId,
                    quarantinedFilename: quarantine.recoveryFilename
                ),
                phase: .replaceLocal,
                classification: .quarantineFailed,
                recoveryAttempt: .quarantineAndReplace
            )
        }

        do {
            try beforeFreshLocalDatabaseCreation?()
            let repository = try Self.openConfiguredLocalRepository(
                workspaceId: Self.applicationLocalRepositoryScopeId,
                configuration: configuration,
                legacyDrawerPresentationCapture: captureLegacyDrawerPresentationImport(
                    configuration: configuration,
                    importCutoff: legacyDrawerImportCutoff
                )
            )
            try localDatabaseReplacementObserver?(
                repository,
                WorkspaceLocalDatabaseReplacement(
                    quarantinedFilenames: quarantine.quarantinedFilenames,
                    reason: reason == .corruptDatabase ? "corrupt_database" : "incomplete_file_set",
                    recoveredAt: recoveredAt
                )
            )
            applicationLocalRepositoryBundle = .init(applicationRepository: repository)
            return .init(
                database: .available(recovery: .init(reason: reason)),
                diagnostic: .init(
                    database: .local,
                    phase: .replaceLocal,
                    classification: reason == .corruptDatabase
                        ? .corruptDatabase
                        : .incompleteFileSet,
                    recoveryAttempt: .quarantineAndReplace,
                    disposition: .localAvailable,
                    sqliteResultCode: nil
                )
            )
        } catch {
            return localUnavailableOutcome(
                error: error,
                phase: .replaceLocal,
                classification: .freshDatabaseCreationFailed,
                recoveryAttempt: .quarantineAndReplace
            )
        }
    }

    private func localUnavailableOutcome(
        error: any Error,
        phase: WorkspaceSQLitePreparationPhase,
        classification: WorkspaceSQLitePreparationClassification,
        recoveryAttempt: WorkspaceSQLitePreparationRecoveryAttempt
    ) -> PreparedLocalDatabaseOutcome {
        .init(
            database: .unavailable(.init(error)),
            diagnostic: .init(
                database: .local,
                phase: phase,
                classification: classification,
                recoveryAttempt: recoveryAttempt,
                disposition: .localUnavailable,
                sqliteResultCode: Self.sqliteResultCode(error)
            )
        )
    }

    private static func sqliteResultCode(_ error: any Error) -> Int? {
        guard let databaseError = error as? DatabaseError else { return nil }
        return Int(databaseError.resultCode.rawValue)
    }

    private func resolvedBackendForWorkspaceStartup() throws -> WorkspaceSQLiteStoreBackend {
        try resolvedBackend()
    }

    private func resolvedBackend() throws -> WorkspaceSQLiteStoreBackend {
        guard case .prepared = databasePreparationState else {
            throw WorkspaceSQLiteDatastoreError.databasesNotPrepared
        }
        guard let backend else {
            throw WorkspaceSQLiteDatastoreError.databasesNotPrepared
        }
        return backend
    }

    private func openConfiguredBackend(
        configuration: WorkspaceSQLiteDatastoreConfiguration
    ) throws
        -> WorkspaceSQLiteStoreBackend
    {
        let coreDatabaseStartupProvenance: WorkspaceSQLiteStoreBackend.CoreDatabaseStartupProvenance =
            FileManager.default.fileExists(atPath: configuration.coreDatabaseURL.path)
            ? .preexisting
            : .createdDuringCurrentStartup
        let coreDatabasePool = try SQLiteDatabaseFactory.makeFileBackedPool(
            at: configuration.coreDatabaseURL,
            label: "AgentStudio.sqlite.core"
        )
        let coreRepository = WorkspaceCoreRepository(databaseWriter: coreDatabasePool)
        try coreRepository.migrate()
        return WorkspaceSQLiteStoreBackend(
            coreRepository: coreRepository,
            makeLocalRepository: { _ in
                throw WorkspaceSQLiteDatastoreError.useDatastoreApplicationLocalRepositoryBundle
            },
            makeLocalRestoreRepository: { _ in
                throw WorkspaceSQLiteDatastoreError.useDatastoreApplicationLocalRepositoryBundle
            },
            coreDatabaseStartupProvenance: coreDatabaseStartupProvenance
        )
    }

    private func preparedLocalRepository(workspaceId: UUID) throws -> WorkspaceLocalRepository {
        guard case .prepared(let receipt) = databasePreparationState else {
            throw WorkspaceSQLiteDatastoreError.databasesNotPrepared
        }
        switch receipt.local {
        case .available:
            guard let applicationLocalRepositoryBundle else {
                throw WorkspaceSQLiteDatastoreError.applicationLocalRepositoryUnavailable
            }
            return applicationLocalRepositoryBundle.repository(workspaceId: workspaceId)
        case .unavailable(let failure):
            throw failure
        }
    }

    func preparedApplicationLocalRepository() throws -> WorkspaceLocalRepository {
        guard case .prepared(let receipt) = databasePreparationState else {
            throw WorkspaceSQLiteDatastoreError.databasesNotPrepared
        }
        switch receipt.local {
        case .available:
            guard let applicationLocalRepositoryBundle else {
                throw WorkspaceSQLiteDatastoreError.applicationLocalRepositoryUnavailable
            }
            return applicationLocalRepositoryBundle.applicationRepository
        case .unavailable(let failure):
            throw failure
        }
    }

    private func recordProbe(_ event: ProbeEvent) async {
        guard let probe else { return }
        await probe(event)
    }
}

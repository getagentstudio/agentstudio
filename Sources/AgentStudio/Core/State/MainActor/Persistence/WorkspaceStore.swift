import AgentStudioInfrastructure
import Foundation
import Observation
import os.log

private let workspaceStoreLogger = Logger(subsystem: "com.agentstudio", category: "WorkspaceStore")

enum WorkspaceStoreError: Error {
    case missingSQLiteSaveCoordinator
}

package enum WorkspaceStoreLoadFailure: Error, Equatable, Sendable {
    case missingSQLiteDatastore
    case sqliteUnavailable(WorkspaceSQLiteDatastoreFailure)
    case defaultWorkspaceInitializationFailed(WorkspaceSQLiteDatastoreFailure)
    case defaultWorkspacePersistenceMismatch
    case compositionRejected(WorkspaceCompositionPreparationRejection)
    case compositionApplyFailed(WorkspacePreparedCompositionApplyFailure)
    case topologyRejected(RepositoryTopologyIdentityRejection)

    package var diagnosticCode: WorkspaceStartupFailureDiagnosticCode {
        switch self {
        case .missingSQLiteDatastore:
            .missingSQLiteDatastore
        case .sqliteUnavailable:
            .sqliteUnavailable
        case .defaultWorkspaceInitializationFailed:
            .defaultWorkspaceInitializationFailed
        case .defaultWorkspacePersistenceMismatch:
            .defaultWorkspacePersistenceMismatch
        case .compositionRejected:
            .compositionRejected
        case .compositionApplyFailed:
            .compositionApplyFailed
        case .topologyRejected:
            .topologyRejected
        }
    }
}

package enum WorkspaceStartupFailureDiagnosticCode: String, Equatable, Sendable {
    case missingSQLiteDatastore = "missing_sqlite_datastore"
    case sqliteUnavailable = "sqlite_unavailable"
    case defaultWorkspaceInitializationFailed = "default_workspace_initialization_failed"
    case defaultWorkspacePersistenceMismatch = "default_workspace_persistence_mismatch"
    case compositionRejected = "composition_rejected"
    case compositionApplyFailed = "composition_apply_failed"
    case topologyRejected = "topology_rejected"
}

package enum WorkspaceStoreLoadResult: Equatable, Sendable {
    case loaded(WorkspacePreparedCompositionAcceptance)
    case initializedDefaultWorkspace(WorkspacePreparedCompositionAcceptance)
    case failed(WorkspaceStoreLoadFailure)
}

package typealias PaneAssociationBootReconciliationReporter =
    @MainActor @Sendable (PaneAssociationBootReconciliationSummary) -> Void

/// Main-actor persistence aggregate for the workspace atoms.
///
/// This type owns canonical SQLite composition loading, debounced persistence,
/// and flushing. Workspace-domain
/// mutations live on the owning atoms or `WorkspaceMutationCoordinator`.
@MainActor
package final class WorkspaceStore {
    package let identityAtom: WorkspaceIdentityAtom
    package let windowMemoryAtom: WorkspaceWindowMemoryAtom
    package let repositoryTopologyAtom: RepositoryTopologyAtom
    let paneGraphAtom: WorkspacePaneGraphAtom
    let drawerCursorAtom: WorkspaceDrawerCursorAtom
    package let paneAtom: WorkspacePaneAtom
    package let tabShellAtom: WorkspaceTabShellAtom
    let tabCursorAtom: WorkspaceTabCursorAtom
    let tabGraphAtom: WorkspaceTabGraphAtom
    let arrangementCursorAtom: WorkspaceArrangementCursorAtom
    package let panePresentationAtom: WorkspacePanePresentationAtom
    package let tabArrangementAtom: WorkspaceTabArrangementAtom
    package let tabLayoutAtom: WorkspaceTabLayoutAtom
    package let mutationCoordinator: WorkspaceMutationCoordinator

    private let sqliteDatastore: WorkspaceSQLiteDatastoreActor?
    // Unobserved mirror of persisted session metadata; loaded before composition publication.
    var terminalSessionProtocolVersionsByID: [ZmxSessionID: UInt8] = [:]
    private let sqliteSaveCoordinator: WorkspaceSQLiteSaveCoordinator?
    private let preparedCompositionApplier: WorkspacePreparedCompositionApplier
    private let persistDebounceDuration: Duration
    private let delay: AsyncDelay
    let recoveryReporter: PersistenceRecoveryReporter?
    private let paneAssociationBootReconciliationReporter: PaneAssociationBootReconciliationReporter?
    private let persistenceReasonReporter: PaneTopologyPersistenceReasonReporter?
    private var debouncedSaveTask: Task<Void, Never>?
    private var debouncedSaveFailureDamping = DebouncedSaveFailureDamping()
    private var isObservingPersistedState = false
    private var isApplyingInitialComposition = false
    private(set) var isDirty: Bool = false

    package var isAutosaveObservationActive: Bool {
        isObservingPersistedState
    }

    package init(
        identityAtom: WorkspaceIdentityAtom,
        windowMemoryAtom: WorkspaceWindowMemoryAtom,
        repositoryTopologyAtom: RepositoryTopologyAtom,
        paneAtom: WorkspacePaneAtom,
        tabLayoutAtom: WorkspaceTabLayoutAtom,
        mutationCoordinator: WorkspaceMutationCoordinator,
        sqliteDatastore: WorkspaceSQLiteDatastoreActor? = nil,
        sqliteSaveCoordinator: WorkspaceSQLiteSaveCoordinator? = nil,
        persistDebounceDuration: Duration = .milliseconds(500),
        clock: (any Clock<Duration> & Sendable)? = nil,
        recoveryReporter: PersistenceRecoveryReporter? = nil,
        paneAssociationBootReconciliationReporter: PaneAssociationBootReconciliationReporter? = nil,
        persistenceReasonReporter: PaneTopologyPersistenceReasonReporter? = nil
    ) {
        let resolvedTabShellAtom = tabLayoutAtom.shellAtom
        let resolvedTabArrangementAtom = tabLayoutAtom.arrangementAtom
        let resolvedPaneAtom = paneAtom
        preparedCompositionApplier = WorkspacePreparedCompositionApplier(
            owners: WorkspacePreparedCompositionOwners(
                workspaceIdentityAtom: identityAtom,
                workspaceWindowMemoryAtom: windowMemoryAtom,
                workspacePaneGraphAtom: resolvedPaneAtom.graphAtom,
                workspaceDrawerCursorAtom: resolvedPaneAtom.drawerCursorAtom,
                workspaceTabShellAtom: resolvedTabShellAtom,
                workspaceTabCursorAtom: resolvedTabShellAtom.cursorAtom,
                workspaceTabGraphAtom: resolvedTabArrangementAtom.graphAtom,
                workspaceArrangementCursorAtom: resolvedTabArrangementAtom.cursorAtom
            )
        )
        self.identityAtom = identityAtom
        self.windowMemoryAtom = windowMemoryAtom
        self.repositoryTopologyAtom = repositoryTopologyAtom
        self.paneGraphAtom = resolvedPaneAtom.graphAtom
        self.drawerCursorAtom = resolvedPaneAtom.drawerCursorAtom
        self.paneAtom = resolvedPaneAtom
        self.tabShellAtom = resolvedTabShellAtom
        self.tabCursorAtom = resolvedTabShellAtom.cursorAtom
        self.tabArrangementAtom = resolvedTabArrangementAtom
        self.tabGraphAtom = resolvedTabArrangementAtom.graphAtom
        self.arrangementCursorAtom = resolvedTabArrangementAtom.cursorAtom
        self.panePresentationAtom = resolvedTabArrangementAtom.presentationAtom
        self.tabLayoutAtom = tabLayoutAtom
        self.mutationCoordinator = mutationCoordinator
        let resolvedSQLiteSaveCoordinator =
            sqliteSaveCoordinator
            ?? sqliteDatastore.map { datastore in
                WorkspaceSQLiteSaveCoordinator(
                    identityAtom: identityAtom,
                    windowMemoryAtom: windowMemoryAtom,
                    workspacePaneAtom: resolvedPaneAtom,
                    workspaceTabLayoutAtom: tabLayoutAtom,
                    repositoryTopologyAtom: repositoryTopologyAtom,
                    sqliteDatastore: datastore
                )
            }
        self.sqliteDatastore = sqliteDatastore
        self.sqliteSaveCoordinator = resolvedSQLiteSaveCoordinator
        self.persistDebounceDuration = persistDebounceDuration
        delay = clock.map(AsyncDelay.clock) ?? .taskSleep
        self.recoveryReporter = recoveryReporter
        self.paneAssociationBootReconciliationReporter = paneAssociationBootReconciliationReporter
        self.persistenceReasonReporter = persistenceReasonReporter
    }

    typealias CloseEntry = WorkspaceMutationCoordinator.CloseEntry
    typealias TabCloseSnapshot = WorkspaceMutationCoordinator.TabCloseSnapshot
    typealias PaneCloseSnapshot = WorkspaceMutationCoordinator.PaneCloseSnapshot
    typealias CloseSnapshot = TabCloseSnapshot

    // MARK: - Persistence

    package func stopPendingIncompatibleTerminalSession(
        sessionID: ZmxSessionID, identity: Data?, operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        try await sqliteDatastore.stopPendingIncompatibleTerminalSession(
            sessionID: sessionID, identity: identity, operation: operation)
    }

    package func terminalSessionProtocolVersion(_ sessionID: ZmxSessionID) async throws -> UInt8? {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        return try await sqliteDatastore.terminalSessionProtocolVersion(sessionID)
    }

    package func recordTerminalSessionProtocolVersion(_ sessionID: ZmxSessionID, version: UInt8) async throws {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        try await sqliteDatastore.recordTerminalSessionProtocolVersion(sessionID, version: version)
        terminalSessionProtocolVersionsByID[sessionID] = version
    }

    package func pruneCompletedHistoryBatch() async throws -> Bool {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        return try await sqliteDatastore.pruneCompletedHistoryBatch()
    }

    package func terminalSessionCleanupBatch(after sessionID: ZmxSessionID?) async throws
        -> [WorkspaceTerminalSessionCleanupWork]
    {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        return try await sqliteDatastore.terminalSessionCleanupBatch(after: sessionID)
    }

    package func observePendingTerminalSession(
        sessionID: ZmxSessionID, observation: @escaping @Sendable () async throws -> Data?
    ) async throws {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        try await sqliteDatastore.observePendingTerminalSession(sessionID: sessionID, observation: observation)
    }

    package func retirePendingTerminalSession(
        sessionID: ZmxSessionID, identity: Data,
        operation: @escaping @Sendable () async throws -> ZmxSessionCleanupStatus
    ) async throws -> ZmxSessionCleanupStatus? {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        return try await sqliteDatastore.retirePendingTerminalSession(
            sessionID: sessionID, identity: identity, operation: operation)
    }

    package func expireUndoCloses(time: WorkspaceUndoJournalTime) async throws -> [WorkspaceUndoCloseRetirement] {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        return try await sqliteDatastore.expireAllUndoCloses(time: time)
    }

    package func nextUndoDeadline(bootID: String) async throws -> Int64? {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        return try await sqliteDatastore.nextUndoDeadline(bootID: bootID)
    }

    package func recoverUndoJournal(time: WorkspaceUndoJournalTime?) async throws -> WorkspaceUndoJournalRecovery {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        return try await sqliteDatastore.recoverUndoJournal(workspaceID: identityAtom.workspaceId, time: time)
    }

    @discardableResult
    package func closeForUndo(
        tabID: UUID,
        paneID: UUID?,
        closeID: UUID,
        time: WorkspaceUndoJournalTime,
        willPublish: @escaping @MainActor @Sendable (WorkspaceUndoCloseProposal, WorkspaceUndoJournalReceipt) -> Void,
        didPublish: @escaping @MainActor @Sendable (WorkspaceUndoCloseProposal, WorkspaceUndoJournalReceipt) -> Void
    ) async throws -> WorkspaceUndoJournalReceipt {
        guard let sqliteSaveCoordinator else { throw WorkspaceStoreError.missingSQLiteSaveCoordinator }
        return try await sqliteSaveCoordinator.commitCloseForUndo(
            tabID: tabID, paneID: paneID, closeID: closeID, time: time,
            publish: { [self] proposal, receipt in
                willPublish(proposal, receipt)
                mutationCoordinator.applyCommittedClose(proposal)
                didPublish(proposal, receipt)
            }
        )
    }

    @discardableResult
    package func undoClose(
        time: WorkspaceUndoJournalTime,
        willPublish: @escaping @MainActor @Sendable (WorkspaceUndoRestoreProposal, WorkspaceUndoJournalReceipt) -> Void,
        didPublish: @escaping @MainActor @Sendable (WorkspaceUndoRestoreProposal, WorkspaceUndoJournalReceipt) -> Void
    ) async throws -> WorkspaceUndoJournalReceipt? {
        guard let sqliteSaveCoordinator else { throw WorkspaceStoreError.missingSQLiteSaveCoordinator }
        return try await sqliteSaveCoordinator.commitMostRecentUndo(
            time: time,
            publish: { [self] proposal, receipt in
                willPublish(proposal, receipt)
                mutationCoordinator.applyCommittedRestore(proposal)
                didPublish(proposal, receipt)
            }
        )
    }

    package func discardPane(
        target: WorkspacePaneDiscardTarget,
        time: WorkspaceUndoJournalTime,
        willPublish: @escaping @MainActor @Sendable (Set<UUID>) -> Void,
        didPublish: @escaping @MainActor @Sendable (Set<UUID>) -> Void
    ) async throws {
        guard let sqliteSaveCoordinator else { throw WorkspaceStoreError.missingSQLiteSaveCoordinator }
        try await sqliteSaveCoordinator.commitPaneDiscard(target: target, time: time) { [self] proposal in
            willPublish(proposal.removedPaneIDs)
            mutationCoordinator.applyCommittedDiscard(proposal)
            didPublish(proposal.removedPaneIDs)
        }
    }

    package func createTerminalPane(
        metadata: PaneMetadata,
        placement: WorkspaceTerminalPlacement,
        nameForPane: @escaping @MainActor @Sendable (Pane) -> String,
        willPublish: @escaping @MainActor @Sendable (Pane) -> Void
    ) async throws -> Pane {
        guard let sqliteSaveCoordinator else { throw WorkspaceStoreError.missingSQLiteSaveCoordinator }
        return try await sqliteSaveCoordinator.commitTerminalCreation(
            metadata: metadata,
            placement: placement,
            topology: repositoryTopologyAtom.captureReadSnapshot(),
            nameForPane: nameForPane,
            publish: { [self] proposal in
                if let sessionID = proposal.pane.terminalState?.zmxSessionID {
                    terminalSessionProtocolVersionsByID[sessionID] = ZmxProtocol.version
                }
                willPublish(proposal.pane)
                mutationCoordinator.applyCommittedTerminalCreation(proposal)
            })
    }

    package func loadCanonicalComposition() async -> WorkspaceStoreLoadResult {
        guard let sqliteDatastore else {
            return .failed(.missingSQLiteDatastore)
        }

        switch await sqliteDatastore.loadAuthoritativeCoreSnapshot() {
        case .loaded(let snapshot):
            let topologyRestoreReasons =
                await WorkspacePersistenceTransformer.topologyRestoreReasonsOffMain(
                    snapshot.repositoryTopology
                )
            let restoreReasons = snapshot.persistenceReasons.union(
                topologyRestoreReasons
            )
            for reason in restoreReasons {
                persistenceReasonReporter?(reason)
            }
            switch await prepareAndApplyAuthoritativeSnapshot(snapshot) {
            case .success(let acceptance):
                return .loaded(acceptance)
            case .failure(let failure):
                return .failed(failure)
            }
        case .uninitialized:
            return await initializeAndApplyDefaultWorkspace(using: sqliteDatastore)
        case .unavailable(let failure):
            return .failed(.sqliteUnavailable(failure))
        }
    }

    private func initializeAndApplyDefaultWorkspace(
        using sqliteDatastore: WorkspaceSQLiteDatastoreActor
    ) async -> WorkspaceStoreLoadResult {
        let persistedAt = Date()
        let workspaceSnapshot = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            name: "Default Workspace",
            panes: [],
            tabs: [],
            activeTabId: nil,
            sidebarWidth: 250,
            windowFrame: nil,
            createdAt: persistedAt,
            updatedAt: persistedAt
        )
        let saveBundle = WorkspaceSQLiteSaveBundle(workspace: workspaceSnapshot)
        do {
            try await sqliteDatastore.saveWorkspaceSnapshotBundle(saveBundle)
        } catch {
            return .failed(.defaultWorkspaceInitializationFailed(.init(error)))
        }

        let persistedSnapshot: WorkspaceCoreLoadSnapshot
        switch await sqliteDatastore.loadAuthoritativeCoreSnapshot() {
        case .loaded(let snapshot):
            guard snapshot.workspace.hasSameSQLiteRepresentation(as: workspaceSnapshot) else {
                return .failed(.defaultWorkspacePersistenceMismatch)
            }
            persistedSnapshot = snapshot
        case .uninitialized:
            return .failed(.defaultWorkspacePersistenceMismatch)
        case .unavailable(let failure):
            return .failed(.defaultWorkspaceInitializationFailed(failure))
        }

        switch await prepareAndApplyAuthoritativeSnapshot(persistedSnapshot) {
        case .success(let acceptance):
            return .initializedDefaultWorkspace(acceptance)
        case .failure(let failure):
            return .failed(failure)
        }
    }

    private func prepareAndApplyAuthoritativeSnapshot(
        _ snapshot: WorkspaceCoreLoadSnapshot
    ) async -> Result<WorkspacePreparedCompositionAcceptance, WorkspaceStoreLoadFailure> {
        terminalSessionProtocolVersionsByID = snapshot.terminalSessionProtocolVersions
        let topologyPreparation = await WorkspacePersistenceTransformer.prepareRepositoryTopologyOffMain(
            snapshot.repositoryTopology
        )

        let preparedTopology: RepositoryTopologyReplacement
        switch topologyPreparation {
        case .prepared(let replacement):
            preparedTopology = replacement
        case .rejected(let rejection):
            return .failure(.topologyRejected(rejection))
        }

        let paneReconciliation = await WorkspacePersistenceTransformer.reconcilePanesForBootOffMain(
            in: snapshot.workspace,
            topology: preparedTopology
        )

        let preparedComposition: PreparedWorkspaceComposition
        switch await WorkspaceCompositionPreparer.prepareOffMain(paneReconciliation.workspace) {
        case .prepared(let prepared):
            preparedComposition = prepared
        case .rejected(let rejection):
            return .failure(.compositionRejected(rejection))
        }

        isApplyingInitialComposition = true
        defer { isApplyingInitialComposition = false }
        switch preparedCompositionApplier.apply(preparedComposition) {
        case .accepted(let acceptance):
            WorkspacePersistenceTransformer.applyPreparedRepositoryTopology(
                preparedTopology,
                repositoryTopologyAtom: repositoryTopologyAtom
            )
            paneAssociationBootReconciliationReporter?(paneReconciliation.associationSummary)
            isDirty = false
            if paneReconciliation.didChange {
                _ = await persistNow()
            }
            workspaceStoreLogger.info(
                "Installed SQLite workspace '\(preparedComposition.identity.workspaceName)' with \(preparedComposition.panes.count) pane(s), \(preparedComposition.tabs.count) tab(s)"
            )
            return .success(acceptance)
        case .failed(let failure):
            return .failure(.compositionApplyFailed(failure))
        }
    }

    @discardableResult
    package func flushAsync() async -> WorkspaceStoreFlushOutcome {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        let outcome = await persistNow()
        clearDebouncedSaveFailureDampingIfSucceeded(outcome)
        return outcome
    }

    private var prePersistHook: (() -> Void)?

    package func setPrePersistHook(_ hook: @escaping () -> Void) {
        prePersistHook = hook
    }

    package func startObserving() {
        guard !isObservingPersistedState else { return }
        isObservingPersistedState = true
        withObservationTracking {
            _ = identityAtom.workspaceId
            _ = identityAtom.workspaceName
            _ = identityAtom.createdAt
            _ = windowMemoryAtom.sidebarWidth
            _ = windowMemoryAtom.windowFrame
            _ = paneGraphAtom.paneAcceptedCommitRevision
            _ = drawerCursorAtom.expandedDrawerId
            _ = drawerCursorAtom.presentationPreferenceRevision
            _ = tabShellAtom.tabShells
            _ = tabCursorAtom.activeTabId
            _ = tabGraphAtom.tabStates
            _ = arrangementCursorAtom.activeArrangementIdsByTabId
            _ = arrangementCursorAtom.paneCursorsByArrangementId
            _ = arrangementCursorAtom.drawerCursorsByKey
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let shouldIgnore = self.isApplyingInitialComposition
                self.isObservingPersistedState = false
                self.startObserving()
                guard !shouldIgnore else { return }
                self.markDirtyObserved()
            }
        }
    }

    private func markDirtyObserved() {
        if !isDirty {
            isDirty = true
            ProcessInfo.processInfo.disableSuddenTermination()
        }

        debouncedSaveTask?.cancel()
        let delay = self.delay
        let persistDebounceDuration = self.persistDebounceDuration
        debouncedSaveTask = Task { @MainActor [weak self, delay, persistDebounceDuration] in
            try? await delay.wait(persistDebounceDuration)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.persistDebouncedAutosave()
        }
    }

    private func persistDebouncedAutosave() async {
        let shouldReportFailure = !debouncedSaveFailureDamping.shouldDampNextDebouncedFailureReport
        if !shouldReportFailure {
            workspaceStoreLogger.warning(
                "Damping repeated workspace autosave failure report after \(self.debouncedSaveFailureDamping.consecutiveFailureCount) identical failure(s); autosave will still retry"
            )
        }
        let outcome = await persistNow(shouldReportSaveFailure: shouldReportFailure)
        debouncedSaveFailureDamping.record(outcome)
    }

    @discardableResult
    private func persistNow(shouldReportSaveFailure: Bool = true) async -> WorkspaceStoreFlushOutcome {
        let persistedAt = Date()
        do {
            prePersistHook?()
            guard sqliteDatastore != nil, let sqliteSaveCoordinator else {
                throw WorkspaceStoreError.missingSQLiteSaveCoordinator
            }
            let savedBundle = try await sqliteSaveCoordinator.save(persistedAt: persistedAt)
            // A drawer preference committed while this capture was saving is
            // not acknowledged; it stays dirty for the next save or flush.
            let acknowledgesDrawerPresentation =
                savedBundle.drawerPresentationRevision.map {
                    $0 == drawerCursorAtom.presentationPreferenceRevision
                } ?? true
            if isDirty, acknowledgesDrawerPresentation {
                isDirty = false
                ProcessInfo.processInfo.enableSuddenTermination()
            }
            return .persisted
        } catch {
            workspaceStoreLogger.error("Failed to persist workspace: \(String(reflecting: error))")
            persistenceReasonReporter?(Self.persistenceFailureReason(for: error))
            if shouldReportSaveFailure {
                reportSaveFailed()
            }
            return .failed(String(describing: error))
        }
    }

    package static func persistenceFailureReason(
        for error: any Error
    ) -> PaneTopologyPersistenceReason {
        guard let failure = error as? WorkspaceSQLiteSaveCoordinatorFailure else {
            return .workspaceSaveDatabaseFailed
        }
        switch failure {
        case .compositionRejected:
            return .workspaceSaveCompositionRejected
        case .datastore(let datastoreFailure):
            return datastoreFailure.kind == .stateBridge
                ? .workspaceSaveBridgeFailed
                : .workspaceSaveDatabaseFailed
        }
    }

    private func clearDebouncedSaveFailureDampingIfSucceeded(_ outcome: WorkspaceStoreFlushOutcome) {
        guard outcome.succeeded else { return }
        debouncedSaveFailureDamping.reset()
    }

    func reportSaveFailed() {
        recoveryReporter?(
            .init(
                store: .workspace,
                workspaceId: identityAtom.workspaceId,
                recovery: .saveFailed
            )
        )
    }

    private func reportRecoveryEvents(_ events: [PersistenceRecoveryEvent]) {
        for event in events {
            recoveryReporter?(event)
        }
    }

}

private struct DebouncedSaveFailureDamping {
    private var failureSummary: String?
    private(set) var consecutiveFailureCount: Int = 0

    var shouldDampNextDebouncedFailureReport: Bool {
        consecutiveFailureCount >= AppPolicies.WorkspacePersistence.debouncedAutosaveFailureDampingThreshold
    }

    mutating func record(_ outcome: WorkspaceStoreFlushOutcome) {
        switch outcome {
        case .persisted:
            reset()
        case .failed(let summary):
            if failureSummary == summary {
                consecutiveFailureCount += 1
            } else {
                failureSummary = summary
                consecutiveFailureCount = 1
            }
        }
    }

    mutating func reset() {
        failureSummary = nil
        consecutiveFailureCount = 0
    }
}

import AgentStudioInfrastructure
import Foundation
import Observation
import os.log

private let repoCacheStoreLogger = Logger(subsystem: "com.agentstudio", category: "RepoCacheStore")

/// One persisted save attempt; its generation is minted by the owning store.
package struct RepoCacheStoreSaveScope: Hashable, Sendable {
    package let workspaceId: UUID
    package let generation: UInt64
}

/// Synchronous observations of the store's own transitions; they do not add
/// events to the app runtime bus. Completion acknowledges a committed SQLite write.
package enum RepoCacheStoreFact: Equatable, Sendable {
    case saveStarted
    case saveCompleted(sourceRevision: UInt64)
    case saveFailed
    case saveCancelled
}

package typealias RepoCacheStoreFactSink = @Sendable (RepoCacheStoreSaveScope, RepoCacheStoreFact) -> Void

struct RepoCacheSaveCapture: Sendable {
    let repoEnrichmentByRepoID: [UUID: RepoEnrichment]
    let worktreeEnrichmentByWorktreeID: [UUID: WorktreeEnrichment]
    let sourceRevision: UInt64
    let lastRebuiltAt: Date?
}

struct RepoCachePersistedProjection: Equatable, Sendable {
    let repoEnrichmentByRepoID: [UUID: RepoCacheRepoEnrichmentProjection]
    let worktreeEnrichmentByWorktreeID: [UUID: RepoCacheWorktreeEnrichmentProjection]
    let sourceRevision: UInt64
    let lastRebuiltAt: Date?
}

enum RepoCacheRepoEnrichmentProjection: Equatable, Sendable {
    case awaitingOrigin(repoID: UUID)
    case resolvedLocal(repoID: UUID, identity: RepoIdentity)
    case resolvedRemote(repoID: UUID, raw: RawRepoOrigin, identity: RepoIdentity)

    init(enrichment: RepoEnrichment) {
        switch enrichment {
        case .awaitingOrigin(let repoID), .statusUnavailable(let repoID, _):
            self = .awaitingOrigin(repoID: repoID)
        case .resolvedLocal(let repoID, let identity, _):
            self = .resolvedLocal(repoID: repoID, identity: identity)
        case .resolvedRemote(let repoID, let raw, let identity, _):
            self = .resolvedRemote(repoID: repoID, raw: raw, identity: identity)
        }
    }
}

struct RepoCacheWorktreeEnrichmentProjection: Equatable, Sendable {
    let worktreeID: UUID
    let repoID: UUID
    let branch: String
    let isMainWorktree: Bool

    init(enrichment: WorktreeEnrichment) {
        worktreeID = enrichment.worktreeId
        repoID = enrichment.repoId
        branch = enrichment.branch
        isMainWorktree = enrichment.isMainWorktree
    }
}

struct PreparedRepoCacheSave: Sendable {
    let cacheState: WorkspaceLocalRepository.CacheStateRecord
    let projection: RepoCachePersistedProjection
    let shouldPersist: Bool
}

enum RepoCacheSavePreparer {
    @concurrent nonisolated static func prepareOffMain(
        capture: RepoCacheSaveCapture,
        previousProjection: RepoCachePersistedProjection?,
        force: Bool
    ) async -> PreparedRepoCacheSave {
        let persistedRepoEnrichmentByRepoID = capture.repoEnrichmentByRepoID.mapValues(persistedEnrichment)
        let cacheState = WorkspaceLocalRepository.CacheStateRecord(
            repoEnrichmentByRepoId: persistedRepoEnrichmentByRepoID,
            worktreeEnrichmentByWorktreeId: capture.worktreeEnrichmentByWorktreeID,
            sourceRevision: capture.sourceRevision,
            lastRebuiltAt: capture.lastRebuiltAt
        )
        let projection = RepoCachePersistedProjection(
            repoEnrichmentByRepoID: persistedRepoEnrichmentByRepoID.mapValues {
                RepoCacheRepoEnrichmentProjection(enrichment: $0)
            },
            worktreeEnrichmentByWorktreeID: capture.worktreeEnrichmentByWorktreeID.mapValues {
                RepoCacheWorktreeEnrichmentProjection(enrichment: $0)
            },
            sourceRevision: capture.sourceRevision,
            lastRebuiltAt: capture.lastRebuiltAt
        )
        return PreparedRepoCacheSave(
            cacheState: cacheState,
            projection: projection,
            shouldPersist: force || projection != previousProjection
        )
    }

    private static func persistedEnrichment(_ enrichment: RepoEnrichment) -> RepoEnrichment {
        switch enrichment {
        case .statusUnavailable(let repoID, _):
            return .awaitingOrigin(repoId: repoID)
        case .awaitingOrigin, .resolvedLocal, .resolvedRemote:
            return enrichment
        }
    }
}

@MainActor
package final class RepoCacheStore {
    private enum SaveMode {
        case supersedeActive
        case afterActive
    }

    private let cacheAtom: RepoEnrichmentCacheAtom
    private let sqliteDatastore: WorkspaceSQLiteDatastoreActor
    private let persistDebounceDuration: Duration
    private let persistMaximumDelay: Duration
    private let delay: AsyncDelay
    private let recoveryReporter: PersistenceRecoveryReporter?
    private let factSink: RepoCacheStoreFactSink?
    private var debouncedSaveTask: Task<Void, Never>?
    private var maximumDelaySaveTask: Task<Void, Never>?
    private var activeSaveTask: Task<Void, Error>?
    private var saveGeneration: UInt64 = 0
    private var isObservingCacheState = false
    private var isRestoringState = false
    private var activeWorkspaceId: UUID?
    private var lastPersistedProjection: RepoCachePersistedProjection?
    package var isAutosaveObservationActive: Bool {
        isObservingCacheState
    }

    package init(
        cacheAtom: RepoEnrichmentCacheAtom,
        sqliteDatastore: WorkspaceSQLiteDatastoreActor,
        persistDebounceDuration: Duration = .milliseconds(500),
        persistMaximumDelay: Duration = AppPolicies.WorkspacePersistence.autosaveMaximumDelay,
        clock: (any Clock<Duration> & Sendable)? = nil,
        recoveryReporter: PersistenceRecoveryReporter? = nil,
        factSink: RepoCacheStoreFactSink? = nil
    ) {
        self.cacheAtom = cacheAtom
        self.sqliteDatastore = sqliteDatastore
        self.persistDebounceDuration = persistDebounceDuration
        self.persistMaximumDelay = persistMaximumDelay
        delay = clock.map(AsyncDelay.clock) ?? .taskSleep
        self.recoveryReporter = recoveryReporter
        self.factSink = factSink
    }

    convenience init(
        atom: RepoCacheAtom,
        sqliteDatastore: WorkspaceSQLiteDatastoreActor,
        persistDebounceDuration: Duration = .milliseconds(500),
        persistMaximumDelay: Duration = AppPolicies.WorkspacePersistence.autosaveMaximumDelay,
        clock: any Clock<Duration> = ContinuousClock(),
        recoveryReporter: PersistenceRecoveryReporter? = nil,
        factSink: RepoCacheStoreFactSink? = nil
    ) {
        self.init(
            cacheAtom: atom.enrichmentCacheAtom,
            sqliteDatastore: sqliteDatastore,
            persistDebounceDuration: persistDebounceDuration,
            persistMaximumDelay: persistMaximumDelay,
            clock: clock,
            recoveryReporter: recoveryReporter,
            factSink: factSink
        )
    }

    /// Begin observing atom mutations for debounced autosave.
    ///
    /// Stores do not observe from `init`: the owner first restores cache state,
    /// replays boot topology, and prunes stale entries as an explicit boot
    /// transaction. Production arms this from `WorkspaceBootStep.armPersistenceObservation`;
    /// tests or future isolated owners must opt in once their initial mutations are done.
    package func startObserving() {
        observeCacheState()
    }

    package func restoreAsync(for workspaceId: UUID) async {
        debouncedSaveTask?.cancel()
        maximumDelaySaveTask?.cancel()
        activeSaveTask?.cancel()
        debouncedSaveTask = nil
        maximumDelaySaveTask = nil
        activeWorkspaceId = workspaceId
        switch await sqliteDatastore.loadRepoCacheState() {
        case .loaded(let cacheState):
            isRestoringState = true
            cacheAtom.hydrate(
                .init(
                    repoEnrichmentByRepoId: cacheState.repoEnrichmentByRepoId,
                    worktreeEnrichmentByWorktreeId: cacheState.worktreeEnrichmentByWorktreeId,
                    sourceRevision: cacheState.sourceRevision,
                    lastRebuiltAt: cacheState.lastRebuiltAt
                )
            )
            isRestoringState = false
        case .unavailable(let failure):
            isRestoringState = false
            cacheAtom.clear()
            repoCacheStoreLogger.warning("Repo cache SQLite restore failed: \(failure.description)")
            recoveryReporter?(
                .init(
                    store: .repoCache,
                    workspaceId: workspaceId,
                    recovery: .resetToDefaults
                )
            )
        }
        let capture = captureCurrentSaveState()
        lastPersistedProjection = await RepoCacheSavePreparer.prepareOffMain(
            capture: capture,
            previousProjection: nil,
            force: true
        ).projection
    }

    package func flushAsync(for workspaceId: UUID) async throws {
        activeWorkspaceId = workspaceId
        debouncedSaveTask?.cancel()
        maximumDelaySaveTask?.cancel()
        debouncedSaveTask = nil
        maximumDelaySaveTask = nil
        try await persistNow(for: workspaceId, force: true, mode: .supersedeActive)
    }

    private func observeCacheState() {
        guard !isObservingCacheState else { return }
        isObservingCacheState = true
        withObservationTracking {
            _ = cacheAtom.cacheRevision
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                // Repo cache write owners are @MainActor; this traps if ownership changes.
                guard let self else { return }
                let shouldIgnore = self.isRestoringState
                self.isObservingCacheState = false
                self.observeCacheState()
                guard !shouldIgnore else { return }
                self.schedulePersist()
            }
        }
    }

    private func schedulePersist() {
        guard let workspaceId = activeWorkspaceId else { return }
        debouncedSaveTask?.cancel()
        let delay = self.delay
        let persistDebounceDuration = self.persistDebounceDuration
        debouncedSaveTask = Task { @MainActor [weak self, delay, persistDebounceDuration, workspaceId] in
            try? await delay.wait(persistDebounceDuration)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.autosave(for: workspaceId, fromMaximumDelay: false)
        }
        if maximumDelaySaveTask == nil {
            let persistMaximumDelay = self.persistMaximumDelay
            maximumDelaySaveTask = Task { @MainActor [weak self, delay, persistMaximumDelay, workspaceId] in
                try? await delay.wait(persistMaximumDelay)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.autosave(for: workspaceId, fromMaximumDelay: true)
            }
        }
    }

    private func autosave(for workspaceId: UUID, fromMaximumDelay: Bool) async {
        if fromMaximumDelay {
            debouncedSaveTask?.cancel()
        } else {
            maximumDelaySaveTask?.cancel()
        }
        debouncedSaveTask = nil
        maximumDelaySaveTask = nil
        do {
            try await persistNow(for: workspaceId, force: false, mode: .afterActive)
        } catch is CancellationError {
            return
        } catch {
            repoCacheStoreLogger.warning("Repo cache autosave failed: \(error.localizedDescription)")
        }
    }

    private func persistNow(for workspaceId: UUID, force: Bool, mode: SaveMode) async throws {
        try Task.checkCancellation()
        let previous: Task<Void, Error>?
        switch mode {
        case .supersedeActive:
            activeSaveTask?.cancel()
            previous = nil
        case .afterActive:
            previous = activeSaveTask
        }
        saveGeneration &+= 1
        let generation = saveGeneration
        let operation = Task { @MainActor [self] in
            if let previous {
                await withTaskCancellationHandler {
                    _ = try? await previous.value
                } onCancel: {
                    previous.cancel()
                }
            }
            try await persistCurrentCapture(for: workspaceId, force: force, generation: generation)
        }
        activeSaveTask = operation
        defer { if generation == saveGeneration { activeSaveTask = nil } }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func persistCurrentCapture(for workspaceId: UUID, force: Bool, generation: UInt64) async throws {
        try Task.checkCancellation()
        let capture = captureCurrentSaveState()
        let preparedSave = await RepoCacheSavePreparer.prepareOffMain(
            capture: capture,
            previousProjection: lastPersistedProjection,
            force: force
        )
        try Task.checkCancellation()
        guard preparedSave.shouldPersist else { return }
        let saveScope = RepoCacheStoreSaveScope(workspaceId: workspaceId, generation: generation)
        factSink?(saveScope, .saveStarted)
        var didCompleteSave = false
        do {
            // Cancellation may arrive after SQL commits but before its acknowledgement returns.
            lastPersistedProjection = nil
            try await sqliteDatastore.saveRepoCacheState(
                cacheState: preparedSave.cacheState
            )
            didCompleteSave = true
            factSink?(saveScope, .saveCompleted(sourceRevision: preparedSave.cacheState.sourceRevision))
            try Task.checkCancellation()
            lastPersistedProjection = preparedSave.projection
        } catch let error as CancellationError {
            if !didCompleteSave { factSink?(saveScope, .saveCancelled) }
            throw error
        } catch {
            factSink?(saveScope, .saveFailed)
            recoveryReporter?(
                .init(store: .repoCache, workspaceId: workspaceId, recovery: .saveFailed)
            )
            throw error
        }
    }

    func captureCurrentSaveState() -> RepoCacheSaveCapture {
        RepoCacheSaveCapture(
            repoEnrichmentByRepoID: cacheAtom.repoEnrichmentSnapshot(),
            worktreeEnrichmentByWorktreeID: cacheAtom.worktreeEnrichmentSnapshot(),
            sourceRevision: cacheAtom.sourceRevision,
            lastRebuiltAt: cacheAtom.lastRebuiltAt
        )
    }

}

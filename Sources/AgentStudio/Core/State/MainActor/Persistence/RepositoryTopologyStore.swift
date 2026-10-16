import AgentStudioInfrastructure
import Foundation
import Observation
import os.log

private let repositoryTopologyStoreLogger = Logger(subsystem: "com.agentstudio", category: "RepositoryTopologyStore")

/// One persisted capture in the store's already-serialized save tail.
package struct RepositoryTopologyStoreSaveScope: Hashable, Sendable {
    package let generation: UInt64
}

/// Synchronous observations of the store's own transitions; they do not add
/// events to the app runtime bus. Completion includes the store's commit acknowledgement.
package enum RepositoryTopologyStoreFact: Equatable, Sendable {
    case saveStarted
    case saveCompleted(captureRevision: UInt64)
    case saveFailed
    case saveCancelled
}

package typealias RepositoryTopologyStoreFactSink =
    @Sendable (RepositoryTopologyStoreSaveScope, RepositoryTopologyStoreFact) -> Void

@MainActor
package final class RepositoryTopologyStore {
    private let atom: RepositoryTopologyAtom
    private let sqliteDatastore: WorkspaceSQLiteDatastoreActor?
    private let persistDebounceDuration: Duration
    private let persistMaximumDelay: Duration
    private let delay: AsyncDelay
    private let factSink: RepositoryTopologyStoreFactSink?
    private var debouncedSaveTask: Task<Void, Never>?
    private var maximumDelaySaveTask: Task<Void, Never>?
    private var isObservingTopology = false
    private(set) var isDirty = false
    private var saveTail: Task<Void, Error>?
    private var saveTailGeneration: UInt64 = 0
    private var pendingReparenting: [PendingReparenting] = []

    private struct PendingReparenting: Sendable {
        let revision: UInt64
        let transitions: [RepositoryWorktreeReparenting]
    }

    package func recordReparenting(_ transitions: [RepositoryWorktreeReparenting], revision: UInt64) {
        guard !transitions.isEmpty else { return }
        pendingReparenting.append(.init(revision: revision, transitions: transitions))
    }

    package var isAutosaveObservationActive: Bool {
        isObservingTopology
    }

    package init(
        atom: RepositoryTopologyAtom,
        sqliteDatastore: WorkspaceSQLiteDatastoreActor? = nil,
        persistDebounceDuration: Duration = .milliseconds(500),
        persistMaximumDelay: Duration = AppPolicies.WorkspacePersistence.autosaveMaximumDelay,
        clock: (any Clock<Duration> & Sendable)? = nil,
        factSink: RepositoryTopologyStoreFactSink? = nil
    ) {
        self.atom = atom
        self.sqliteDatastore = sqliteDatastore
        self.persistDebounceDuration = persistDebounceDuration
        self.persistMaximumDelay = persistMaximumDelay
        delay = clock.map(AsyncDelay.clock) ?? .taskSleep
        self.factSink = factSink
    }

    package func startObserving() {
        observeTopology()
    }

    package func flushAsync() async throws {
        debouncedSaveTask?.cancel()
        maximumDelaySaveTask?.cancel()
        debouncedSaveTask = nil
        maximumDelaySaveTask = nil
        try await persistNow()
    }

    package func collect(
        _ candidates: RepositoryRetentionCandidates,
        expectedRevision: UInt64,
        at time: RepositoryRetentionTime
    ) async throws -> RepositoryLifecycleChange {
        guard let sqliteDatastore, atom.lifecycleRevision == expectedRevision else {
            throw RepositoryRetentionCollectionError.staleTopology
        }
        try await flushAsync()
        guard atom.lifecycleRevision == expectedRevision else { throw RepositoryRetentionCollectionError.staleTopology }
        let snapshot = try await sqliteDatastore.collectRetainedRepositoryLocations(
            candidates, expectedRevision: expectedRevision, at: time
        )
        guard
            case .prepared(let replacement) = await WorkspacePersistenceTransformer.prepareRepositoryTopologyOffMain(
                snapshot)
        else {
            preconditionFailure("Committed retention topology must satisfy canonical validation")
        }
        return RepositoryLifecycleChange(
            expectedRevision: expectedRevision, replacement: replacement, deltas: [], reparenting: [])
    }

    package func hasPendingLocalCleanup() async -> Bool {
        guard let sqliteDatastore else { return false }
        return await sqliteDatastore.repositoryLocalCleanupPending
    }

    package func unsettledRepositoryRetentionKeys() async throws -> Set<String> {
        guard let sqliteDatastore else { return [] }
        return try await sqliteDatastore.unsettledRepositoryRetentionKeys()
    }

    package func reconcileLocalOrphans() async -> RepositoryRetentionLocalCleanupResult {
        guard let sqliteDatastore else { return .complete }
        return await sqliteDatastore.reconcileRepositoryLocalOrphans()
    }

    private func observeTopology() {
        guard !isObservingTopology else { return }
        isObservingTopology = true
        withObservationTracking {
            _ = atom.repos
            _ = atom.watchedPaths
            _ = atom.unavailableRepoIds
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isObservingTopology = false
                self.observeTopology()
                self.schedulePersist()
            }
        }
    }

    private func schedulePersist() {
        isDirty = true
        debouncedSaveTask?.cancel()
        let delay = self.delay
        let persistDebounceDuration = self.persistDebounceDuration
        debouncedSaveTask = Task { @MainActor [weak self, delay, persistDebounceDuration] in
            try? await delay.wait(persistDebounceDuration)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.autosave(fromMaximumDelay: false)
        }
        if maximumDelaySaveTask == nil {
            let persistMaximumDelay = self.persistMaximumDelay
            maximumDelaySaveTask = Task { @MainActor [weak self, delay, persistMaximumDelay] in
                try? await delay.wait(persistMaximumDelay)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.autosave(fromMaximumDelay: true)
            }
        }
    }

    private func autosave(fromMaximumDelay: Bool) async {
        if fromMaximumDelay {
            debouncedSaveTask?.cancel()
        } else {
            maximumDelaySaveTask?.cancel()
        }
        debouncedSaveTask = nil
        maximumDelaySaveTask = nil
        do {
            try await persistNow()
        } catch {
            repositoryTopologyStoreLogger.warning(
                "Repository topology autosave failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistNow() async throws {
        let previous = saveTail
        saveTailGeneration &+= 1
        let generation = saveTailGeneration
        let operation = Task { @MainActor [self] in
            if let previous { _ = try? await previous.value }
            try await persistCurrentCapture(generation: generation)
        }
        saveTail = operation
        defer { if generation == saveTailGeneration { saveTail = nil } }
        try await operation.value
    }

    private func persistCurrentCapture(generation: UInt64) async throws {
        guard let sqliteDatastore else { return }
        let captureRevision = atom.lifecycleRevision
        let pending = pendingReparenting
        let repositories = atom.repos
        let unavailableRepositoryIDs = atom.unavailableRepoIds
        let watchedPaths = atom.watchedPaths
        let snapshot = await WorkspacePersistenceTransformer.makeRepositoryTopologySQLiteSnapshotOffMain(
            repositories: repositories,
            stableIdentity: RepositoryTopologyStableIdentity(
                repositoryStableKeysByID: atom.repositoryStableKeysByID,
                worktreeStableKeysByID: atom.worktreeStableKeysByID,
                watchedPathStableKeysByID: atom.watchedPathStableKeysByID
            ),
            unavailableRepositoryIDs: unavailableRepositoryIDs,
            watchedPaths: watchedPaths,
            persistedAt: Date(),
            absenceRecords: atom.absenceRecords
        )
        let reparenting = await Self.coalesceReparenting(pending, snapshot: snapshot)
        let saveScope = beginSaveFact(generation: generation)
        do {
            try await sqliteDatastore.saveRepositoryTopologySnapshot(
                snapshot, captureRevision: captureRevision, reparenting: reparenting
            )
            pendingReparenting.removeAll { $0.revision <= captureRevision }
            isDirty = atom.lifecycleRevision != captureRevision
            if let saveScope { factSink?(saveScope, .saveCompleted(captureRevision: captureRevision)) }
        } catch {
            if let saveScope {
                factSink?(saveScope, error is CancellationError ? .saveCancelled : .saveFailed)
            }
            throw error
        }
    }

    private func beginSaveFact(generation: UInt64) -> RepositoryTopologyStoreSaveScope? {
        guard let factSink else { return nil }
        let scope = RepositoryTopologyStoreSaveScope(generation: generation)
        factSink(scope, .saveStarted)
        return scope
    }
    @concurrent nonisolated private static func coalesceReparenting(
        _ pending: [PendingReparenting],
        snapshot: RepositoryTopologySQLiteSnapshot
    ) async -> [RepositoryWorktreeReparenting] {
        var transitionsByID: [UUID: RepositoryWorktreeReparenting] = [:]
        for batch in pending {
            for transition in batch.transitions {
                let first = transitionsByID[transition.worktreeID] ?? transition
                transitionsByID[transition.worktreeID] = .init(
                    worktreeID: transition.worktreeID,
                    expectedRepositoryID: first.expectedRepositoryID,
                    repositoryID: transition.repositoryID
                )
            }
        }
        return snapshot.worktrees.compactMap { worktree in
            guard let transition = transitionsByID[worktree.id],
                transition.repositoryID == worktree.repoId,
                transition.expectedRepositoryID != transition.repositoryID
            else { return nil }
            return transition
        }
    }

}

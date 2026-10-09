import AgentStudioInfrastructure
import Foundation
import Observation
import os.log

private let sidebarCacheStoreLogger = Logger(subsystem: "com.agentstudio", category: "SidebarCacheStore")

/// One persisted save attempt; its generation is minted by the owning store.
package struct SidebarCacheStoreSaveScope: Hashable, Sendable {
    package let workspaceId: UUID
    package let generation: UInt64
}

/// Synchronous observations of the store's own transitions; they do not add
/// events to the app runtime bus. Completion acknowledges a committed SQLite write.
package enum SidebarCacheStoreFact: Equatable, Sendable {
    case saveStarted
    case saveCompleted
    case saveFailed
    case saveCancelled
}

package typealias SidebarCacheStoreFactSink = @Sendable (SidebarCacheStoreSaveScope, SidebarCacheStoreFact) -> Void

@MainActor
package final class SidebarCacheStore {
    private let atom: SidebarCacheState
    private let sqliteDatastore: WorkspaceSQLiteDatastoreActor
    private let persistDebounceDuration: Duration
    private let delay: AsyncDelay
    private let recoveryReporter: PersistenceRecoveryReporter?
    private let factSink: SidebarCacheStoreFactSink?
    private var saveFactGeneration: UInt64 = 0
    private var debouncedSaveTask: Task<Void, Never>?
    private var isObservingCacheState = false
    private var isRestoringState = false
    private var activeWorkspaceId: UUID?
    package var isAutosaveObservationActive: Bool {
        isObservingCacheState
    }

    package init(
        atom: SidebarCacheState,
        sqliteDatastore: WorkspaceSQLiteDatastoreActor,
        persistDebounceDuration: Duration = .milliseconds(500),
        clock: (any Clock<Duration> & Sendable)? = nil,
        recoveryReporter: PersistenceRecoveryReporter? = nil,
        factSink: SidebarCacheStoreFactSink? = nil
    ) {
        self.atom = atom
        self.sqliteDatastore = sqliteDatastore
        self.persistDebounceDuration = persistDebounceDuration
        delay = clock.map(AsyncDelay.clock) ?? .taskSleep
        self.recoveryReporter = recoveryReporter
        self.factSink = factSink
    }

    /// Begin observing atom mutations for debounced autosave.
    ///
    /// The owner arms observation after restore-time mutations are complete; see
    /// `RepoCacheStore.startObserving` for the boot-order rationale.
    package func startObserving() {
        observeCacheState()
    }

    package func restoreAsync(for workspaceId: UUID) async {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        activeWorkspaceId = workspaceId
        switch await sqliteDatastore.loadSidebarState(workspaceContextId: workspaceId) {
        case .loaded(let collapsedGroups):
            isRestoringState = true
            atom.setCollapsedGroups(collapsedGroups)
            isRestoringState = false
        case .unavailable(let failure):
            isRestoringState = false
            atom.clear()
            sidebarCacheStoreLogger.warning("Sidebar cache SQLite restore failed: \(failure.description)")
            recoveryReporter?(
                .init(
                    store: .sidebarCache,
                    workspaceId: workspaceId,
                    recovery: .resetToDefaults
                )
            )
        }
    }

    package func flushAsync(for workspaceId: UUID) async throws {
        activeWorkspaceId = workspaceId
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        try await persistNow(for: workspaceId)
    }

    private func observeCacheState() {
        guard !isObservingCacheState else { return }
        isObservingCacheState = true
        withObservationTracking {
            _ = atom.collapsedGroups
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                // SidebarCacheState is @MainActor; this traps if that ownership changes.
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
            do {
                try await self.persistNow(for: workspaceId)
            } catch {
                sidebarCacheStoreLogger.warning("Sidebar cache autosave failed: \(error.localizedDescription)")
            }
        }
    }

    private func persistNow(for workspaceId: UUID) async throws {
        let saveScope = beginSaveFact(for: workspaceId)
        do {
            try await sqliteDatastore.saveSidebarState(
                collapsedGroups: atom.collapsedGroups,
                workspaceContextId: workspaceId
            )
            if let saveScope { factSink?(saveScope, .saveCompleted) }
        } catch {
            if let saveScope {
                factSink?(saveScope, error is CancellationError ? .saveCancelled : .saveFailed)
            }
            reportSaveFailed(workspaceId: workspaceId)
            throw error
        }
    }

    private func beginSaveFact(for workspaceId: UUID) -> SidebarCacheStoreSaveScope? {
        guard let factSink else { return nil }
        saveFactGeneration &+= 1
        let scope = SidebarCacheStoreSaveScope(workspaceId: workspaceId, generation: saveFactGeneration)
        factSink(scope, .saveStarted)
        return scope
    }

    private func reportSaveFailed(workspaceId: UUID) {
        recoveryReporter?(
            .init(store: .sidebarCache, workspaceId: workspaceId, recovery: .saveFailed)
        )
    }

}

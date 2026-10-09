import AgentStudioInfrastructure
import Foundation
import Observation
import os.log

private let uiStateStoreLogger = Logger(subsystem: "com.agentstudio", category: "UIStateStore")

/// One persisted save attempt; its generation is minted by the owning store.
package struct UIStateStoreSaveScope: Hashable, Sendable {
    package let workspaceId: UUID
    package let generation: UInt64
}

/// Synchronous observations of the store's own transitions; they do not add
/// events to the app runtime bus. Completion acknowledges a committed SQLite write.
package enum UIStateStoreFact: Equatable, Sendable {
    case saveStarted
    case saveCompleted
    case saveFailed
    case saveCancelled
}

package typealias UIStateStoreFactSink = @Sendable (UIStateStoreSaveScope, UIStateStoreFact) -> Void

@MainActor
package final class UIStateStore {
    private let atom: WorkspaceSidebarState
    private let sqliteDatastore: WorkspaceSQLiteDatastoreActor
    private let persistDebounceDuration: Duration
    private let delay: AsyncDelay
    private let recoveryReporter: PersistenceRecoveryReporter?
    private let factSink: UIStateStoreFactSink?
    private var saveFactGeneration: UInt64 = 0
    private var debouncedSaveTask: Task<Void, Never>?
    private var isObservingUIState = false
    private var isRestoringState = false
    private var activeWorkspaceId: UUID?
    package var isAutosaveObservationActive: Bool {
        isObservingUIState
    }

    package init(
        atom: WorkspaceSidebarState,
        sqliteDatastore: WorkspaceSQLiteDatastoreActor,
        persistDebounceDuration: Duration = .milliseconds(500),
        clock: (any Clock<Duration> & Sendable)? = nil,
        recoveryReporter: PersistenceRecoveryReporter? = nil,
        factSink: UIStateStoreFactSink? = nil
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
        observeUIState()
    }

    package func restoreAsync(for workspaceId: UUID) async {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        activeWorkspaceId = workspaceId
        switch await sqliteDatastore.loadUIState(workspaceContextId: workspaceId) {
        case .loaded(let state):
            isRestoringState = true
            if let state {
                atom.hydrate(
                    filterText: state.filterText,
                    isFilterVisible: state.isFilterVisible,
                    sidebarCollapsed: state.sidebarCollapsed,
                    sidebarSurface: state.sidebarSurface,
                    repoGroupingMode: state.repoGroupingMode,
                    paneGroupingMode: state.paneGroupingMode,
                    repoSubgroupMode: state.repoSubgroupMode,
                    paneSubgroupMode: state.paneSubgroupMode,
                    showsPinnedRepos: state.showsPinnedRepos,
                    showsPinnedPanes: state.showsPinnedPanes,
                    showsDrawerPanes: state.showsDrawerPanes
                )
            } else {
                atom.clear()
            }
            isRestoringState = false
        case .unavailable(let failure):
            isRestoringState = false
            atom.clear()
            uiStateStoreLogger.warning("UI state SQLite restore failed: \(failure.description)")
            recoveryReporter?(
                .init(
                    store: .uiState,
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

    private func observeUIState() {
        guard !isObservingUIState else { return }
        isObservingUIState = true
        withObservationTracking {
            _ = atom.filterText
            _ = atom.isFilterVisible
            _ = atom.sidebarCollapsed
            _ = atom.sidebarSurface
            _ = atom.repoGroupingMode
            _ = atom.paneGroupingMode
            _ = atom.repoSubgroupMode
            _ = atom.paneSubgroupMode
            _ = atom.showsPinnedRepos
            _ = atom.showsPinnedPanes
            _ = atom.showsDrawerPanes
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                // WorkspaceSidebarState is @MainActor; this traps if that ownership changes.
                guard let self else { return }
                let shouldIgnore = self.isRestoringState
                self.isObservingUIState = false
                self.observeUIState()
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
                uiStateStoreLogger.warning("UI state autosave failed: \(error.localizedDescription)")
            }
        }
    }

    private func persistNow(for workspaceId: UUID) async throws {
        let saveScope = beginSaveFact(for: workspaceId)
        do {
            try await sqliteDatastore.saveUIState(
                currentSidebarStateRecord(),
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

    private func beginSaveFact(for workspaceId: UUID) -> UIStateStoreSaveScope? {
        guard let factSink else { return nil }
        saveFactGeneration &+= 1
        let scope = UIStateStoreSaveScope(workspaceId: workspaceId, generation: saveFactGeneration)
        factSink(scope, .saveStarted)
        return scope
    }

    private func reportSaveFailed(workspaceId: UUID) {
        recoveryReporter?(
            .init(store: .uiState, workspaceId: workspaceId, recovery: .saveFailed)
        )
    }

    private func currentSidebarStateRecord() -> WorkspaceLocalRepository.SidebarStateRecord {
        .init(
            filterText: atom.filterText,
            isFilterVisible: atom.isFilterVisible,
            sidebarCollapsed: atom.sidebarCollapsed,
            sidebarSurface: atom.sidebarSurface,
            repoGroupingMode: atom.repoGroupingMode,
            paneGroupingMode: atom.paneGroupingMode,
            repoSubgroupMode: atom.repoSubgroupMode,
            paneSubgroupMode: atom.paneSubgroupMode,
            showsPinnedRepos: atom.showsPinnedRepos,
            showsPinnedPanes: atom.showsPinnedPanes,
            showsDrawerPanes: atom.showsDrawerPanes
        )
    }

}

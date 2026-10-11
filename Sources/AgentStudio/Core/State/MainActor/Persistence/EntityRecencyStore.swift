import AgentStudioInfrastructure
import Foundation
import Observation

package enum EntityRecencyStoreSaveLane: Hashable, Sendable {
    case application
    case workspace(UUID)
}

/// One persisted save attempt in the store's application or workspace lane.
package struct EntityRecencyStoreSaveScope: Hashable, Sendable {
    package let lane: EntityRecencyStoreSaveLane
    package let generation: UInt64
}

/// Synchronous observations of the store's own transitions; they do not add
/// events to the app runtime bus. Completion acknowledges a committed SQLite write.
package enum EntityRecencyStoreFact: Equatable, Sendable {
    case saveStarted
    case saveCompleted
    case saveFailed
    case saveCancelled
}

package typealias EntityRecencyStoreFactSink = @Sendable (EntityRecencyStoreSaveScope, EntityRecencyStoreFact) -> Void

@MainActor
package final class EntityRecencyStore {
    private let applicationAtom: ApplicationEntityRecencyAtom
    private let workspaceAtom: WorkspaceEntityRecencyAtom
    private let sqliteDatastore: WorkspaceSQLiteDatastoreActor
    private let persistDebounceDuration: Duration
    private let delay: AsyncDelay
    private let factSink: EntityRecencyStoreFactSink?
    private var saveFactGeneration: UInt64 = 0

    private var applicationSaveTask: Task<Void, Never>?
    private var workspaceSaveTask: Task<Void, Never>?
    private var isObservationArmed = false
    private var isObservingApplication = false
    private var isObservingWorkspace = false
    private var isRestoringApplication = false
    private var isRestoringWorkspace = false

    package private(set) var isApplicationHydrated = false
    package private(set) var hydratedWorkspaceID: UUID?

    package var isApplicationObservationActive: Bool {
        isObservingApplication
    }

    package var isWorkspaceObservationActive: Bool {
        isObservingWorkspace
    }

    package init(
        applicationAtom: ApplicationEntityRecencyAtom,
        workspaceAtom: WorkspaceEntityRecencyAtom,
        sqliteDatastore: WorkspaceSQLiteDatastoreActor,
        persistDebounceDuration: Duration = .milliseconds(500),
        clock: (any Clock<Duration> & Sendable)? = nil,
        factSink: EntityRecencyStoreFactSink? = nil
    ) {
        self.applicationAtom = applicationAtom
        self.workspaceAtom = workspaceAtom
        self.sqliteDatastore = sqliteDatastore
        self.persistDebounceDuration = persistDebounceDuration
        delay = clock.map(AsyncDelay.clock) ?? .taskSleep
        self.factSink = factSink
    }

    package func restoreApplicationAsync() async {
        guard !isApplicationHydrated else { return }
        applicationSaveTask?.cancel()
        applicationSaveTask = nil
        isRestoringApplication = true
        switch await sqliteDatastore.loadApplicationEntityRecency() {
        case .loaded(let recentEntities):
            applicationAtom.hydrate(recentEntities)
        case .unavailable:
            applicationAtom.clear()
        }
        isRestoringApplication = false
        isApplicationHydrated = true
        observeApplicationIfReady()
    }

    package func restoreWorkspaceAsync(for workspaceID: UUID) async {
        workspaceSaveTask?.cancel()
        workspaceSaveTask = nil

        if let previousWorkspaceID = hydratedWorkspaceID, previousWorkspaceID != workspaceID {
            try? await flushWorkspaceAsync(for: previousWorkspaceID)
        }

        isRestoringWorkspace = true
        workspaceAtom.clear()
        switch await sqliteDatastore.loadWorkspaceEntityRecency(workspaceId: workspaceID) {
        case .loaded(let recentEntities):
            workspaceAtom.hydrate(workspaceID: workspaceID, recentEntities: recentEntities)
        case .unavailable:
            workspaceAtom.hydrate(workspaceID: workspaceID, recentEntities: [])
        }
        hydratedWorkspaceID = workspaceID
        isRestoringWorkspace = false
        observeWorkspaceIfReady()
    }

    package func startObserving() {
        isObservationArmed = true
        observeApplicationIfReady()
        observeWorkspaceIfReady()
    }

    package func flushApplicationAsync() async throws {
        guard isApplicationHydrated else { return }
        applicationSaveTask?.cancel()
        applicationSaveTask = nil
        let saveScope: EntityRecencyStoreSaveScope?
        if factSink != nil {
            saveScope = beginSaveFact(in: .application)
        } else {
            saveScope = nil
        }
        do {
            try await sqliteDatastore.saveApplicationEntityRecency(applicationAtom.recentEntities)
            if let saveScope { factSink?(saveScope, .saveCompleted) }
        } catch {
            if let saveScope {
                factSink?(saveScope, error is CancellationError ? .saveCancelled : .saveFailed)
            }
            throw error
        }
    }

    package func flushWorkspaceAsync(for workspaceID: UUID) async throws {
        guard hydratedWorkspaceID == workspaceID, workspaceAtom.workspaceID == workspaceID else {
            return
        }
        workspaceSaveTask?.cancel()
        workspaceSaveTask = nil
        let saveScope: EntityRecencyStoreSaveScope?
        if factSink != nil {
            saveScope = beginSaveFact(in: .workspace(workspaceID))
        } else {
            saveScope = nil
        }
        do {
            try await sqliteDatastore.saveWorkspaceEntityRecency(
                workspaceAtom.recentEntities,
                workspaceId: workspaceID
            )
            if let saveScope { factSink?(saveScope, .saveCompleted) }
        } catch {
            if let saveScope {
                factSink?(saveScope, error is CancellationError ? .saveCancelled : .saveFailed)
            }
            throw error
        }
    }

    private func beginSaveFact(in lane: EntityRecencyStoreSaveLane) -> EntityRecencyStoreSaveScope? {
        guard let factSink else { return nil }
        saveFactGeneration &+= 1
        let scope = EntityRecencyStoreSaveScope(lane: lane, generation: saveFactGeneration)
        factSink(scope, .saveStarted)
        return scope
    }

    package func flushAllAsync() async throws {
        var applicationFlushError: (any Error)?
        var workspaceFlushError: (any Error)?
        do {
            try await flushApplicationAsync()
        } catch {
            applicationFlushError = error
        }

        if let workspaceID = hydratedWorkspaceID {
            do {
                try await flushWorkspaceAsync(for: workspaceID)
            } catch {
                workspaceFlushError = error
            }
        }
        if let applicationFlushError {
            throw applicationFlushError
        }
        if let workspaceFlushError {
            throw workspaceFlushError
        }
    }

    private func observeApplicationIfReady() {
        guard
            isObservationArmed,
            isApplicationHydrated,
            !isObservingApplication
        else { return }

        isObservingApplication = true
        withObservationTracking {
            _ = applicationAtom.recentEntities
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let shouldIgnore = self.isRestoringApplication
                self.isObservingApplication = false
                self.observeApplicationIfReady()
                guard !shouldIgnore else { return }
                self.scheduleApplicationSave()
            }
        }
    }

    private func observeWorkspaceIfReady() {
        guard
            isObservationArmed,
            hydratedWorkspaceID != nil,
            !isObservingWorkspace
        else { return }

        isObservingWorkspace = true
        withObservationTracking {
            _ = workspaceAtom.workspaceID
            _ = workspaceAtom.recentEntities
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let shouldIgnore = self.isRestoringWorkspace
                self.isObservingWorkspace = false
                self.observeWorkspaceIfReady()
                guard !shouldIgnore else { return }
                self.scheduleWorkspaceSave()
            }
        }
    }

    private func scheduleApplicationSave() {
        applicationSaveTask?.cancel()
        let delay = self.delay
        let persistDebounceDuration = self.persistDebounceDuration
        applicationSaveTask = Task { @MainActor [weak self, delay, persistDebounceDuration] in
            try? await delay.wait(persistDebounceDuration)
            guard !Task.isCancelled, let self else { return }
            try? await self.flushApplicationAsync()
        }
    }

    private func scheduleWorkspaceSave() {
        guard let workspaceID = hydratedWorkspaceID else { return }
        workspaceSaveTask?.cancel()
        let delay = self.delay
        let persistDebounceDuration = self.persistDebounceDuration
        workspaceSaveTask = Task { @MainActor [weak self, delay, persistDebounceDuration, workspaceID] in
            try? await delay.wait(persistDebounceDuration)
            guard !Task.isCancelled, let self else { return }
            try? await self.flushWorkspaceAsync(for: workspaceID)
        }
    }

}

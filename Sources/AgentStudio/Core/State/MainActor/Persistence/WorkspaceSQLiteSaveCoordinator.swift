import Foundation
import os.log

private let workspaceSQLiteSavePreparationLogger = Logger(
    subsystem: "com.agentstudio",
    category: "WorkspaceSQLiteSavePreparation"
)

enum WorkspaceSQLiteSaveCoordinatorFailure: Error, Equatable, Sendable {
    case compositionRejected(WorkspaceCompositionPreparationRejection)
    case datastore(WorkspaceSQLiteDatastoreFailure)
}

struct WorkspaceSQLiteSaveCapture: Sendable {
    let revision: WorkspaceCompositionRevision
    let workspaceID: UUID
    let workspaceName: String
    let paneStatesByID: [UUID: PaneGraphState]
    let expandedDrawerID: UUID?
    let drawerPresentationPreferences: [UUID: DrawerPresentationPreference]
    /// Preference revision this capture acknowledges once saved.
    let drawerPresentationRevision: Int
    let tabShells: [TabShell]
    let tabGraphStates: [TabGraphState]
    let activeArrangementIDsByTabID: [UUID: UUID]
    let paneCursorsByArrangementID: [UUID: ArrangementPaneCursorState]
    let drawerCursorsByKey: [ArrangementDrawerCursorKey: ArrangementDrawerCursorState]
    let activeTabID: UUID?
    let sidebarWidth: CGFloat
    let windowFrame: CGRect?
    let createdAt: Date
    let persistedAt: Date
}

enum WorkspaceSQLiteSavePreparation {
    @concurrent nonisolated static func prepareOffMain(
        _ capture: WorkspaceSQLiteSaveCapture
    ) async -> WorkspaceSQLiteSaveBundle {
        let panes = capture.paneStatesByID.values.compactMap { paneState -> Pane? in
            guard !paneState.residency.isPendingUndo else { return nil }
            return paneState.pane(isDrawerExpanded: paneState.drawer?.drawerId == capture.expandedDrawerID)
        }
        let tabGraphStatesByID = Dictionary(
            uniqueKeysWithValues: capture.tabGraphStates.map { ($0.tabId, $0) }
        )
        let tabs = capture.tabShells.compactMap { shell -> Tab? in
            guard let graphState = tabGraphStatesByID[shell.id] else {
                workspaceSQLiteSavePreparationLogger.warning(
                    "tabs: missing graph state for shell \(shell.id)"
                )
                return nil
            }
            let arrangements = graphState.arrangements.map { graphArrangement in
                var arrangement = PaneArrangement(
                    id: graphArrangement.id,
                    name: graphArrangement.name,
                    isDefault: graphArrangement.isDefault,
                    layout: graphArrangement.layout,
                    minimizedPaneIds: graphArrangement.minimizedPaneIds,
                    activePaneId: capture.paneCursorsByArrangementID[graphArrangement.id]?.activePaneId,
                    drawerViews: Dictionary(
                        uniqueKeysWithValues: graphArrangement.drawerViews.map { drawerID, drawerGraphState in
                            let cursorKey = ArrangementDrawerCursorKey(
                                arrangementId: graphArrangement.id,
                                drawerId: drawerID
                            )
                            let activeChildID = capture.drawerCursorsByKey[cursorKey]?.activeChildId
                            var drawerView = DrawerView(
                                layout: drawerGraphState.layout,
                                activeChildId: activeChildID,
                                minimizedPaneIds: drawerGraphState.minimizedPaneIds
                            )
                            // Preserve an explicitly empty cursor after DrawerView normalization.
                            drawerView.activeChildId = activeChildID
                            return (drawerID, drawerView)
                        }
                    )
                )
                // Preserve an explicitly empty cursor after PaneArrangement normalization.
                arrangement.activePaneId = capture.paneCursorsByArrangementID[graphArrangement.id]?.activePaneId
                return arrangement
            }
            let activeArrangementID =
                capture.activeArrangementIDsByTabID[graphState.tabId]
                ?? arrangements.first(where: \.isDefault)?.id
                ?? arrangements.first?.id
                // No arrangement is invalid and is rejected before SQLite I/O.
                // Use existing identity as the rejection sentinel; saving must not mint identity.
                ?? graphState.tabId
            return Tab(
                id: shell.id,
                name: shell.name,
                allPaneIds: graphState.allPaneIds,
                arrangements: arrangements,
                activeArrangementId: activeArrangementID,
                colorHex: shell.colorHex
            )
        }
        return WorkspaceSQLiteSaveBundle(
            workspace: .init(
                id: capture.workspaceID,
                name: capture.workspaceName,
                panes: panes,
                tabs: tabs,
                activeTabId: capture.activeTabID,
                sidebarWidth: capture.sidebarWidth,
                windowFrame: capture.windowFrame,
                createdAt: capture.createdAt,
                updatedAt: capture.persistedAt,
                drawerPresentationPreferences: capture.drawerPresentationPreferences
            ),
            captureRevision: capture.revision,
            drawerPresentationRevision: capture.drawerPresentationRevision
        )
    }
}

@MainActor
package final class WorkspaceSQLiteSaveCoordinator {
    private let identityAtom: WorkspaceIdentityAtom
    private let windowMemoryAtom: WorkspaceWindowMemoryAtom
    private let workspacePaneAtom: WorkspacePaneAtom
    private let workspaceTabLayoutAtom: WorkspaceTabLayoutAtom
    private let repositoryTopologyAtom: RepositoryTopologyAtom?
    private let sqliteDatastore: WorkspaceSQLiteDatastoreActor

    package init(
        identityAtom: WorkspaceIdentityAtom,
        windowMemoryAtom: WorkspaceWindowMemoryAtom,
        workspacePaneAtom: WorkspacePaneAtom,
        workspaceTabLayoutAtom: WorkspaceTabLayoutAtom,
        repositoryTopologyAtom: RepositoryTopologyAtom? = nil,
        sqliteDatastore: WorkspaceSQLiteDatastoreActor
    ) {
        self.identityAtom = identityAtom
        self.windowMemoryAtom = windowMemoryAtom
        self.workspacePaneAtom = workspacePaneAtom
        self.workspaceTabLayoutAtom = workspaceTabLayoutAtom
        self.repositoryTopologyAtom = repositoryTopologyAtom
        self.sqliteDatastore = sqliteDatastore
    }

    var compositionRevision: WorkspaceCompositionRevision {
        .init(
            panes: workspacePaneAtom.graphAtom.paneAcceptedCommitRevision,
            tabShells: workspaceTabLayoutAtom.shellAtom.tabShellAcceptedCommitRevision,
            tabGraphs: workspaceTabLayoutAtom.arrangementAtom.graphAtom.tabGraphAcceptedCommitRevision,
            topologyContextRevision: repositoryTopologyAtom?.lifecycleRevision
        )
    }

    func captureCurrentSaveState(persistedAt: Date) -> WorkspaceSQLiteSaveCapture {
        let arrangementAtom = workspaceTabLayoutAtom.arrangementAtom
        return WorkspaceSQLiteSaveCapture(
            revision: compositionRevision,
            workspaceID: identityAtom.workspaceId,
            workspaceName: identityAtom.workspaceName,
            paneStatesByID: workspacePaneAtom.graphAtom.paneStateSnapshot(),
            expandedDrawerID: workspacePaneAtom.drawerCursorAtom.expandedDrawerId,
            drawerPresentationPreferences: workspacePaneAtom.drawerCursorAtom.presentationPreferencesByOwnerPaneId,
            drawerPresentationRevision: workspacePaneAtom.drawerCursorAtom.presentationPreferenceRevision,
            tabShells: workspaceTabLayoutAtom.shellAtom.tabShells,
            tabGraphStates: arrangementAtom.graphAtom.tabStates,
            activeArrangementIDsByTabID: arrangementAtom.cursorAtom.activeArrangementIdsByTabId,
            paneCursorsByArrangementID: arrangementAtom.cursorAtom.paneCursorsByArrangementId,
            drawerCursorsByKey: arrangementAtom.cursorAtom.drawerCursorsByKey,
            activeTabID: workspaceTabLayoutAtom.activeTabId,
            sidebarWidth: windowMemoryAtom.sidebarWidth,
            windowFrame: windowMemoryAtom.windowFrame,
            createdAt: identityAtom.createdAt,
            persistedAt: persistedAt
        )
    }

    func captureCurrentSaveBundle(persistedAt: Date) async -> WorkspaceSQLiteSaveBundle {
        await WorkspaceSQLiteSavePreparation.prepareOffMain(
            captureCurrentSaveState(persistedAt: persistedAt)
        )
    }

    /// Keep capture, preparation, commit and publication in the existing writer order.
    /// Autosaves cannot overtake a close while its value snapshot is being prepared.
    func commitCloseForUndo(
        tabID: UUID,
        paneID: UUID?,
        closeID: UUID,
        time: WorkspaceUndoJournalTime,
        publish: @escaping @MainActor @Sendable (WorkspaceUndoCloseProposal, WorkspaceUndoJournalReceipt) -> Void
    ) async throws -> WorkspaceUndoJournalReceipt {
        try await sqliteDatastore.withWorkspacePersistenceOrder { [self] datastore in
            let (capture, isManagementLayerActive) = await MainActor.run {
                (captureCurrentSaveState(persistedAt: time.utc), atom(\.managementLayer).isActive)
            }
            let source = await WorkspaceSQLiteSavePreparation.prepareOffMain(capture)
            let proposal = try await WorkspaceUndoComposition.prepareCloseOffMain(
                in: source, tabID: tabID, paneID: paneID, closeID: closeID, time: time,
                isManagementLayerActive: isManagementLayerActive
            )
            switch await WorkspaceCompositionPreparer.prepareOffMain(proposal.bundle.workspace) {
            case .prepared:
                break
            case .rejected(let rejection):
                throw WorkspaceSQLiteSaveCoordinatorFailure.compositionRejected(rejection)
            }
            guard
                let receipt = try await datastore.performWorkspaceSnapshotBundleSave(
                    proposal.bundle, undoChange: .record(proposal.write)
                )
            else {
                preconditionFailure("A committed close must return its journal receipt")
            }
            let revision = await MainActor.run {
                publish(proposal, receipt)
                return compositionRevision
            }
            datastore.acceptedWorkspaceCaptureRevisions[source.id] = revision
            return receipt
        }
    }

    func commitTerminalCreation(
        metadata: PaneMetadata,
        placement: WorkspaceTerminalPlacement,
        topology: RepositoryTopologyReadSnapshot,
        nameForPane: @escaping @MainActor @Sendable (Pane) -> String,
        publish: @escaping @MainActor @Sendable (WorkspaceTerminalCreationProposal) -> Void
    ) async throws -> Pane {
        try await sqliteDatastore.withWorkspacePersistenceOrder { [self] datastore in
            let capture = await captureCurrentSaveState(persistedAt: Date())
            let source = await WorkspaceSQLiteSavePreparation.prepareOffMain(capture)
            let prepared = try await WorkspaceTerminalCreationComposition.preparePaneOffMain(
                metadata: metadata, topology: topology, source: source, placement: placement)
            let name = await nameForPane(prepared.pane)
            let proposal = try await WorkspaceTerminalCreationComposition.preparePlacementOffMain(
                in: source, pane: prepared.pane, name: name, associationOutcome: prepared.outcome, placement: placement)
            switch await WorkspaceCompositionPreparer.prepareOffMain(proposal.bundle.workspace) {
            case .prepared: break
            case .rejected(let rejection):
                throw WorkspaceSQLiteSaveCoordinatorFailure.compositionRejected(rejection)
            }
            guard let sessionID = proposal.pane.terminalState?.zmxSessionID else {
                throw ZmxSessionControlFailure.invalidIdentity
            }
            _ = try await datastore.performWorkspaceSnapshotBundleSave(
                proposal.bundle, undoChange: .create(sessionID: sessionID))
            let revision = await MainActor.run {
                publish(proposal)
                return compositionRevision
            }
            datastore.acceptedWorkspaceCaptureRevisions[source.id] = revision
            return proposal.pane
        }
    }

    func commitPaneDiscard(
        target: WorkspacePaneDiscardTarget,
        time: WorkspaceUndoJournalTime,
        publish: @escaping @MainActor @Sendable (WorkspacePaneDiscardProposal) -> Void
    ) async throws {
        try await sqliteDatastore.withWorkspacePersistenceOrder { [self] datastore in
            let capture = await captureCurrentSaveState(persistedAt: time.utc)
            let source = await WorkspaceSQLiteSavePreparation.prepareOffMain(capture)
            let proposal = try await WorkspacePaneDiscardComposition.prepareOffMain(
                in: source, target: target)
            switch await WorkspaceCompositionPreparer.prepareOffMain(proposal.bundle.workspace) {
            case .prepared: break
            case .rejected(let rejection):
                throw WorkspaceSQLiteSaveCoordinatorFailure.compositionRejected(rejection)
            }
            _ = try await datastore.performWorkspaceSnapshotBundleSave(
                proposal.bundle, undoChange: .discard(time: time))
            let revision = await MainActor.run {
                publish(proposal)
                return compositionRevision
            }
            datastore.acceptedWorkspaceCaptureRevisions[source.id] = revision
        }
    }

    func commitMostRecentUndo(
        time: WorkspaceUndoJournalTime,
        publish: @escaping @MainActor @Sendable (WorkspaceUndoRestoreProposal, WorkspaceUndoJournalReceipt) -> Void
    ) async throws -> WorkspaceUndoJournalReceipt? {
        try await sqliteDatastore.withWorkspacePersistenceOrder { [self] datastore in
            let capture = await captureCurrentSaveState(persistedAt: time.utc)
            let source = await WorkspaceSQLiteSavePreparation.prepareOffMain(capture)
            let available = try datastore.journalRepository().fetchAvailableUndoCloses(workspaceID: source.id)
            for close in available {
                let proposal: WorkspaceUndoRestoreProposal
                do {
                    proposal = try await WorkspaceUndoComposition.prepareRestoreOffMain(
                        in: source, close: close, time: time
                    )
                } catch is WorkspaceUndoCompositionFailure {
                    // Invalid placement retains ownership and cannot hide an older restorable operation.
                    continue
                } catch WorkspaceUndoJournalFailure.undoExpired {
                    continue
                }
                guard
                    let receipt = try await datastore.performWorkspaceSnapshotBundleSave(
                        proposal.bundle, undoChange: .restore(closeID: close.closeID, time: time)
                    )
                else {
                    preconditionFailure("A committed restore must return its journal receipt")
                }
                let revision = await MainActor.run {
                    publish(proposal, receipt)
                    return compositionRevision
                }
                datastore.acceptedWorkspaceCaptureRevisions[source.id] = revision
                return receipt
            }
            return nil
        }
    }

    func save(
        persistedAt: Date
    ) async throws(WorkspaceSQLiteSaveCoordinatorFailure) -> WorkspaceSQLiteSaveBundle {
        var captureDate = persistedAt
        while true {
            let bundle = await captureCurrentSaveBundle(persistedAt: captureDate)
            switch await WorkspaceCompositionPreparer.prepareOffMain(bundle.workspace) {
            case .prepared:
                break
            case .rejected(let rejection):
                throw .compositionRejected(rejection)
            }
            do {
                try await sqliteDatastore.saveWorkspaceSnapshotBundle(bundle)
                return bundle
            } catch WorkspaceSQLiteDatastoreError.staleWorkspaceCapture {
                // A newer committed composition superseded preparation; never replay the old payload.
                captureDate = Date()
            } catch {
                throw .datastore(.init(error))
            }
        }
    }
}

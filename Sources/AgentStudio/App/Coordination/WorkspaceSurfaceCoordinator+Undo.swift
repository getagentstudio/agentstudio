import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@MainActor
extension WorkspaceSurfaceCoordinator {
    private enum ViewRestoreOutcome {
        case restored
        case deferred(reason: String)
        case hardFailure(reason: String)
    }

    func executeDurableClose(tabID: UUID, paneID: UUID?) async throws {
        syncWebviewStates()
        let time = try await undoClock()
        try await store.closeForUndo(
            tabID: tabID, paneID: paneID, closeID: UUIDv7.generate(), time: time,
            willPublish: { [self] proposal, _ in
                ipcLifecycle.invalidatePaneIDs(proposal.removedPaneIDs)
                retireZoomCompanions(forSourcePanes: proposal.removedPaneIDs)
                surfaceManager.retainSurfacesForUndo(forPaneIDs: proposal.removedPaneIDs)
                for pane in proposal.snapshot.panes where proposal.removedPaneIDs.contains(pane.id) {
                    teardownView(for: pane.id, retainingUndoSurface: true)
                }
            },
            didPublish: { [self] proposal, receipt in
                for paneID in proposal.removedPaneIDs { viewRegistry.retireSlot(for: paneID) }
                publishUndoReceipt(
                    receipt, adding: proposal.write.isUndoAvailable ? .init(proposal: proposal) : nil)
            }
        )
    }

    /// SQLite validates placement and consumes the chosen owner before native materialization.
    @discardableResult
    func undoCloseTab() async throws -> Bool {
        let time = try await undoClock()
        let receipt = try await store.undoClose(
            time: time,
            willPublish: { [self] proposal, _ in
                for pane in proposal.close.snapshot.panes {
                    closeTransitionCoordinator.cancelCloseTransition(pane.id)
                }
            },
            didPublish: { [self] proposal, receipt in
                publishUndoReceipt(receipt)
                materializeRestoredPanes(proposal.close.snapshot.panes)
            }
        )
        return receipt != nil
    }

    private func materializeRestoredPanes(_ panes: [Pane]) {
        for pane in panes {
            viewRegistry.ensureSlot(for: pane.id)
        }
        for pane in panes.reversed() {
            guard viewRegistry.view(for: pane.id) == nil else { continue }
            let worktree = pane.worktreeId.flatMap(store.repositoryTopologyAtom.worktree)
            let repo = pane.repoId.flatMap { store.repositoryTopologyAtom.repo($0) }
            switch restoreUndoPane(pane, worktree: worktree, repo: repo, label: "Restored") {
            case .restored:
                break
            case .deferred(let reason):
                Self.logger.info("Undo renderer deferred: \(reason)")
            case .hardFailure(let reason):
                // Rendering cannot revoke the restored logical pane/session owner.
                Self.logger.warning("Undo renderer failed; preserving restored pane ownership: \(reason)")
            }
        }
    }

    private func restoreUndoPane(
        _ pane: Pane,
        worktree: Worktree?,
        repo: Repo?,
        label: String
    ) -> ViewRestoreOutcome {
        if case .bridgePanel = pane.content {
            replaceClosedBridgePaneActivityAuthorityForUndo(paneId: pane.id)
        }
        switch pane.content {
        case .terminal:
            if remountRetainedSurfaceIfAvailable(for: pane, worktree: worktree, repo: repo) != nil {
                return .restored
            }
            if let worktree, let repo {
                if restoreView(for: pane, worktree: worktree, repo: repo) != nil {
                    return .restored
                }
                Self.logger.error("Could not immediately restore terminal pane \(pane.id)")
            } else if createViewForContentUsingCurrentGeometry(pane: pane) != nil {
                return .restored
            } else {
                Self.logger.error("Could not immediately recreate terminal pane \(pane.id)")
            }
            return terminalViewRestoreOutcome(for: pane)

        case .bridgePanel:
            if bridgePaneRetirementTasksByPaneId[pane.id] != nil {
                bridgePaneRetirementsRequiringRestore.insert(pane.id)
                return .restored
            }
            if createViewForContent(pane: pane) != nil {
                return .restored
            }
            Self.logger.error("Failed to recreate \(label.lowercased()) pane \(pane.id)")
            return .hardFailure(reason: "nonTerminalViewCreationFailed")

        case .webview, .codeViewer:
            if createViewForContent(pane: pane) != nil {
                return .restored
            }
            Self.logger.error("Failed to recreate \(label.lowercased()) pane \(pane.id)")
            return .hardFailure(reason: "nonTerminalViewCreationFailed")

        case .unsupported:
            // Unsupported content has no renderer implementation in this build.
            // Keep the pane model restored so user state is preserved, but log that no view can be recreated.
            Self.logger.warning("Cannot restore unsupported pane \(pane.id)")
            return .restored
        }
    }

    private func terminalViewRestoreOutcome(for pane: Pane) -> ViewRestoreOutcome {
        switch viewRegistry.terminalStatusPlaceholderView(for: pane.id)?.mode {
        case .preparing:
            return .deferred(reason: "terminalViewPreparing")
        case .waitingForGeometry:
            // SPEC R5: a settled deferral, not a failure — the same
            // disposition as `.preparing`, distinguished only for diagnostics.
            return .deferred(reason: "terminalViewWaitingForGeometry")
        case .failedToStart, .incompatibleSessionVersion:
            return .hardFailure(reason: "terminalViewFailedToStart")
        case nil:
            return .hardFailure(reason: "terminalViewCreationReturnedNilWithoutPlaceholder")
        }
    }

}

struct WorkspaceUndoCloseProjection {
    let closeID: UUID
    let snapshot: WorkspaceUndoCloseSnapshot

    init(record: WorkspaceUndoCloseRecord) {
        closeID = record.closeID
        snapshot = record.snapshot
    }

    init(proposal: WorkspaceUndoCloseProposal) {
        closeID = proposal.write.closeID
        snapshot = proposal.snapshot
    }
}

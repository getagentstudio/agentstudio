import AgentStudioInfrastructure
import Foundation

package enum WorkspaceTerminalPlacement: Sendable {
    case newTab
    case split(Split)
    case drawer(DrawerInsertion)

    package struct Split: Sendable {
        let tabID: UUID
        let anchorID: UUID
        let direction: Layout.SplitDirection
        let position: Layout.Position
        let sizingMode: DropSizingMode

        package init(
            tabID: UUID, anchorID: UUID, direction: Layout.SplitDirection, position: Layout.Position,
            sizingMode: DropSizingMode
        ) {
            self.tabID = tabID
            self.anchorID = anchorID
            self.direction = direction
            self.position = position
            self.sizingMode = sizingMode
        }
    }

    package struct DrawerInsertion: Sendable {
        let tabID: UUID
        let parentID: UUID
        let anchorID: UUID?
        let direction: SplitNewDirection
        let sizingMode: DropSizingMode
        /// The identity a background creation named up front; `nil` mints one.
        let childID: UUID?
        let presentation: DrawerChildPresentation

        package init(
            tabID: UUID, parentID: UUID, anchorID: UUID?, direction: SplitNewDirection, sizingMode: DropSizingMode,
            childID: UUID? = nil, presentation: DrawerChildPresentation = .interactive
        ) {
            self.tabID = tabID
            self.parentID = parentID
            self.anchorID = anchorID
            self.direction = direction
            self.sizingMode = sizingMode
            self.childID = childID
            self.presentation = presentation
        }
    }
}

struct WorkspaceTerminalCreationProposal: Sendable {
    let bundle: WorkspaceSQLiteSaveBundle
    let pane: Pane
    let tab: Tab
    let associationOutcome: PaneAssociationOutcome
    let placement: WorkspaceTerminalPlacement
}

enum WorkspaceTerminalCreationComposition {
    @concurrent nonisolated static func preparePaneOffMain(
        metadata proposedMetadata: PaneMetadata, topology: RepositoryTopologyReadSnapshot,
        source: WorkspaceSQLiteSaveBundle, placement: WorkspaceTerminalPlacement
    ) async throws -> (pane: Pane, outcome: PaneAssociationOutcome) {
        let metadata: PaneMetadata
        let kind: PaneKind?
        var paneID = UUIDv7.generate()
        if case .drawer(let insertion) = placement {
            paneID = insertion.childID ?? paneID
            let parentID = insertion.parentID
            let anchorID = insertion.anchorID
            guard let parent = source.workspace.panes.first(where: { $0.id == parentID }),
                let drawer = parent.drawer,
                anchorID.map({ drawer.paneIds.contains($0) }) ?? true
            else { throw WorkspaceUndoCompositionFailure.missingTarget }
            let cwd = parent.metadata.facets.cwd ?? parent.metadata.launchDirectory ?? proposedMetadata.launchDirectory
            metadata = PaneMetadata(
                launchDirectory: cwd, title: "Drawer",
                facets: parent.metadata.facets.fillingNilFields(from: PaneContextFacets(cwd: cwd)))
            kind = .drawerChild(parentPaneId: parentID)
        } else {
            metadata = proposedMetadata
            kind = nil
        }
        var facets = metadata.facets
        let outcome: PaneAssociationOutcome
        if let repoID = facets.repoId, let worktreeID = facets.worktreeId,
            topology.repo(repoID) != nil, topology.worktree(worktreeID)?.repoId == repoID
        {
            outcome = .stampedKnown
        } else {
            let resolved = topology.repoAndWorktree(containing: facets.cwd ?? metadata.launchDirectory)
            facets.repoId = resolved?.repo.id
            facets.worktreeId = resolved?.worktree.id
            outcome = resolved == nil ? .freeNil : .resolvedChanged
        }
        let cwd =
            [facets.cwd, metadata.launchDirectory, FileManager.default.homeDirectoryForCurrentUser]
            .compactMap { candidate -> URL? in
                guard case .accepted(let location) = PaneFilesystemLocationPolicy.runtimeCWDUpdate(candidate) else {
                    return nil
                }
                return location
            }.first ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        facets.cwd = cwd
        let pane = Pane(
            id: paneID,
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata(launchDirectory: cwd, title: metadata.title, facets: facets),
            kind: kind)
        return (pane, outcome)
    }

    @concurrent nonisolated static func preparePlacementOffMain(
        in source: WorkspaceSQLiteSaveBundle,
        pane: Pane,
        name: String,
        associationOutcome: PaneAssociationOutcome,
        placement: WorkspaceTerminalPlacement
    ) async throws -> WorkspaceTerminalCreationProposal {
        let tab: Tab
        var updated = source.workspace
        switch placement {
        case .newTab:
            tab = Tab(paneId: pane.id, name: name)
            updated.tabs.append(tab)
            updated.activeTabId = tab.id
        case .split(let insertion):
            let tabID = insertion.tabID
            let anchorID = insertion.anchorID
            let direction = insertion.direction
            let position = insertion.position
            let sizingMode = insertion.sizingMode
            guard let index = updated.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceUndoCompositionFailure.missingTarget
            }
            let original = updated.tabs[index]
            let state = TabArrangementState(
                tabId: original.id, allPaneIds: original.allPaneIds,
                arrangements: original.arrangements, activeArrangementId: original.activeArrangementId)
            guard
                let inserted = TabArrangementMutationRules.insertingNewPane(
                    pane.id, in: state, at: anchorID, direction: direction, position: position, sizingMode: sizingMode)
            else { throw WorkspaceUndoCompositionFailure.invalidComposition }
            tab = Tab(
                id: original.id, name: original.name, allPaneIds: inserted.allPaneIds,
                arrangements: inserted.arrangements, activeArrangementId: inserted.activeArrangementId,
                colorHex: original.colorHex)
            updated.tabs[index] = tab
        case .drawer(let insertion):
            let tabID = insertion.tabID
            let parentID = insertion.parentID
            let anchorID = insertion.anchorID
            let direction = insertion.direction
            let sizingMode = insertion.sizingMode
            guard let tabIndex = updated.tabs.firstIndex(where: { $0.id == tabID }),
                let parentIndex = updated.panes.firstIndex(where: { $0.id == parentID }),
                let drawerID = updated.panes[parentIndex].drawer?.drawerId
            else { throw WorkspaceUndoCompositionFailure.missingTarget }
            let original = updated.tabs[tabIndex]
            let state = TabArrangementState(
                tabId: original.id, allPaneIds: original.allPaneIds,
                arrangements: original.arrangements, activeArrangementId: original.activeArrangementId)
            guard
                let inserted = TabArrangementMutationRules.insertingNewDrawerPane(
                    pane.id, in: state,
                    insertion: .init(
                        parentPaneId: parentID, drawerId: drawerID,
                        targetDrawerPaneId: anchorID, direction: direction, sizingMode: sizingMode,
                        selectsInsertedChild: insertion.presentation == .interactive))
            else { throw WorkspaceUndoCompositionFailure.invalidComposition }
            tab = Tab(
                id: original.id, name: original.name, allPaneIds: inserted.allPaneIds,
                arrangements: inserted.arrangements, activeArrangementId: inserted.activeArrangementId,
                colorHex: original.colorHex)
            updated.tabs[tabIndex] = tab
            let expandsDrawer = insertion.presentation == .interactive
            if expandsDrawer {
                // Match WorkspaceDrawerCursorAtom's single-ID expansion in the durable proposal.
                // A background (agent) insertion leaves every drawer's expansion as the person set it.
                for paneIndex in updated.panes.indices {
                    guard paneIndex != parentIndex else { continue }
                    updated.panes[paneIndex].withDrawer { $0.isExpanded = false }
                }
            }
            updated.panes[parentIndex].withDrawer {
                $0.paneIds.append(pane.id)
                if expandsDrawer { $0.isExpanded = true }
            }
        }
        updated.panes.append(pane)
        return .init(
            bundle: .init(workspace: updated, captureRevision: source.captureRevision),
            pane: pane, tab: tab, associationOutcome: associationOutcome, placement: placement)
    }
}

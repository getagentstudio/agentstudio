import CoreGraphics
import Foundation

package enum WorkspaceCompositionPreparationRejection: Error, Equatable, Sendable {
    case activeTabMissing
    case activeTabNotFound(UUID)
    case activeArrangementNotFound(tabID: UUID, arrangementID: UUID)
    case activePaneMissing(arrangementID: UUID)
    case activePaneNotVisible(arrangementID: UUID, paneID: UUID)
    case arrangementLayoutPaneListedMultipleTimes(arrangementID: UUID, paneID: UUID)
    case arrangementLayoutDividerListedMultipleTimes(arrangementID: UUID, dividerID: UUID)
    case arrangementLayoutUsesDrawerChild(arrangementID: UUID, paneID: UUID, parentPaneID: UUID)
    case arrangementMinimizedPaneMissingFromLayout(arrangementID: UUID, paneID: UUID)
    case arrangementPaneMissingFromTab(tabID: UUID, arrangementID: UUID, paneID: UUID)
    case defaultArrangementLayoutIsEmpty(tabID: UUID, arrangementID: UUID)
    case duplicateArrangementID(UUID)
    case duplicateDrawerID(UUID)
    case duplicatePaneID(UUID)
    case duplicateTabID(UUID)
    case duplicateTabPaneID(tabID: UUID, paneID: UUID)
    case drawerContainsMissingPane(drawerID: UUID, paneID: UUID)
    case drawerViewActiveChildMissing(arrangementID: UUID, drawerID: UUID)
    case drawerViewActiveChildNotVisible(arrangementID: UUID, drawerID: UUID, paneID: UUID)
    case drawerViewLayoutIsEmpty(arrangementID: UUID, drawerID: UUID)
    case drawerViewLayoutDividerListedMultipleTimes(arrangementID: UUID, drawerID: UUID, dividerID: UUID)
    case drawerViewMissingDrawer(arrangementID: UUID, drawerID: UUID)
    case drawerViewPaneListedMultipleTimes(arrangementID: UUID, paneID: UUID)
    case drawerViewPaneNotInDrawer(drawerID: UUID, paneID: UUID)
    case drawerViewMinimizedPaneMissingFromLayout(arrangementID: UUID, drawerID: UUID, paneID: UUID)
    case drawerViewParentPaneMissingFromLayout(arrangementID: UUID, drawerID: UUID, parentPaneID: UUID)
    case paneOwnedByMultipleTabs(paneID: UUID, firstTabID: UUID, secondTabID: UUID)
    case paneNotOwnedByTab(UUID)
    case invalidPaneGraph(WorkspacePaneGraphReplacementRejection)
    case invalidDefaultArrangementCount(tabID: UUID, count: Int)
    case multipleExpandedDrawers(firstDrawerID: UUID, secondDrawerID: UUID)
    case tabHasNoArrangements(UUID)
    case tabHasNoPanes(UUID)
    case tabPaneMissingFromArrangements(tabID: UUID, paneID: UUID)
    case tabReferencesMissingPane(tabID: UUID, paneID: UUID)
}

enum WorkspaceCompositionPreparationResult: Equatable, Sendable {
    case prepared(PreparedWorkspaceComposition)
    case rejected(WorkspaceCompositionPreparationRejection)
}

struct PreparedWorkspaceCompositionIdentity: Equatable, Sendable {
    let workspaceID: UUID
    let workspaceName: String
    let createdAt: Date
}

struct PreparedWorkspaceCompositionWindowMemory: Equatable, Sendable {
    let sidebarWidth: CGFloat
    let windowFrame: CGRect?
}

struct PreparedWorkspacePaneGraph: Equatable, Sendable {
    let replacement: WorkspacePaneGraphReplacement
}

struct PreparedWorkspaceTabShells: Equatable, Sendable {
    let shells: [TabShell]
    let indexByID: [UUID: Int]
}

struct PreparedWorkspaceTabGraph: Equatable, Sendable {
    let states: [TabGraphState]
    let indexByID: [UUID: Int]
    let tabIDByPaneID: [UUID: UUID]
}

struct PreparedWorkspaceArrangementCursors: Equatable, Sendable {
    let activeArrangementIDsByTabID: [UUID: UUID]
    let paneCursorsByArrangementID: [UUID: ArrangementPaneCursorState]
    let drawerCursorsByKey: [ArrangementDrawerCursorKey: ArrangementDrawerCursorState]
}

private struct PreparedWorkspaceCompositionPaneInputs {
    let paneIDs: Set<UUID>
    let panes: [Pane]
    let drawerParentPaneIDByDrawerID: [UUID: UUID]
    let drawerPaneIDsByDrawerID: [UUID: Set<UUID>]
}

private struct PreparedWorkspaceCompositionTabInputs {
    let tabIDByPaneID: [UUID: UUID]
}

private struct PreparedWorkspaceContentInputs {
    let terminalActivationInput: TerminalActivationInput
    let nonterminalContentMountInput: NonterminalContentMountInput
}

private struct PreparedCompositionDrawerViewValidationContext {
    let drawerID: UUID
    let arrangementID: UUID
    let tabID: UUID
    let tabPaneIDs: Set<UUID>
    let mainLayoutPaneIDs: Set<UUID>
    let drawerPaneIDs: Set<UUID>
}

/// An immutable, fully validated composition replacement.
///
/// Only `WorkspaceCompositionPreparer` can construct this value. MainActor apply
/// therefore installs precomputed owner projections without repeating fleet
/// validation or consulting repository topology.
struct PreparedWorkspaceComposition: Equatable, Sendable {
    let identity: PreparedWorkspaceCompositionIdentity
    let windowMemory: PreparedWorkspaceCompositionWindowMemory
    let panes: [Pane]
    let tabs: [Tab]
    let activeTabID: UUID?
    let paneGraph: PreparedWorkspacePaneGraph
    let paneContextMembership: PaneContextMembershipInstallation
    let expandedDrawerID: UUID?
    let drawerPresentationPreferences: [UUID: DrawerPresentationPreference]
    let tabShells: PreparedWorkspaceTabShells
    let tabGraph: PreparedWorkspaceTabGraph
    let arrangementCursors: PreparedWorkspaceArrangementCursors
    let terminalActivationInput: TerminalActivationInput
    let nonterminalContentMountInput: NonterminalContentMountInput

    fileprivate init(
        identity: PreparedWorkspaceCompositionIdentity,
        windowMemory: PreparedWorkspaceCompositionWindowMemory,
        panes: [Pane],
        tabs: [Tab],
        activeTabID: UUID?,
        paneGraph: PreparedWorkspacePaneGraph,
        expandedDrawerID: UUID?,
        drawerPresentationPreferences: [UUID: DrawerPresentationPreference],
        tabShells: PreparedWorkspaceTabShells,
        tabGraph: PreparedWorkspaceTabGraph,
        arrangementCursors: PreparedWorkspaceArrangementCursors,
        terminalActivationInput: TerminalActivationInput,
        nonterminalContentMountInput: NonterminalContentMountInput
    ) {
        self.identity = identity
        self.windowMemory = windowMemory
        self.panes = panes
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.paneGraph = paneGraph
        self.paneContextMembership = PaneContextMembershipInstallation(
            workspaceId: identity.workspaceID, membershipRevision: 1,
            entries: panes.map { pane in
                let facts = PaneStructuralFacts(state: PaneGraphState(pane: pane))
                return PaneContextMembershipEntry(
                    paneId: PaneId(existingUUID: facts.paneID), placement: facts.placement,
                    ownedDrawerChildIds: facts.ownedDrawerPaneIDs.map { PaneId(existingUUID: $0) })
            })
        self.expandedDrawerID = expandedDrawerID
        self.drawerPresentationPreferences = drawerPresentationPreferences
        self.tabShells = tabShells
        self.tabGraph = tabGraph
        self.arrangementCursors = arrangementCursors
        self.terminalActivationInput = terminalActivationInput
        self.nonterminalContentMountInput = nonterminalContentMountInput
    }
}

enum WorkspaceCompositionPreparer {
    @concurrent nonisolated static func prepareOffMain(
        _ snapshot: WorkspaceSQLiteSnapshot
    ) async -> WorkspaceCompositionPreparationResult {
        prepare(snapshot)
    }

    static func prepare(
        _ snapshot: WorkspaceSQLiteSnapshot
    ) -> WorkspaceCompositionPreparationResult {
        let paneInputs: PreparedWorkspaceCompositionPaneInputs
        switch preparePaneInputs(from: snapshot.panes) {
        case .success(let preparedPaneInputs):
            paneInputs = preparedPaneInputs
        case .failure(let rejection):
            return .rejected(rejection)
        }

        let tabInputs: PreparedWorkspaceCompositionTabInputs
        switch prepareTabInputs(snapshot: snapshot, paneInputs: paneInputs) {
        case .success(let preparedTabInputs):
            tabInputs = preparedTabInputs
        case .failure(let rejection):
            return .rejected(rejection)
        }

        let paneGraph: PreparedWorkspacePaneGraph
        switch makePreparedPaneGraph(from: paneInputs.panes) {
        case .success(let preparedPaneGraph):
            paneGraph = preparedPaneGraph
        case .failure(let rejection):
            return .rejected(.invalidPaneGraph(rejection))
        }
        let tabShells = makePreparedTabShells(from: snapshot.tabs)
        let tabGraphStates = snapshot.tabs.map {
            TabGraphState(
                tabId: $0.id,
                allPaneIds: $0.allPaneIds,
                arrangements: $0.arrangements.map(PaneArrangementGraphState.init)
            )
        }
        let tabGraphIndexByID = Dictionary(
            uniqueKeysWithValues: tabGraphStates.enumerated().map { ($0.element.tabId, $0.offset) }
        )
        let arrangementCursors = makeArrangementCursors(from: snapshot.tabs)
        let contentInputs = makePreparedContentInputs(
            panes: snapshot.panes,
            tabs: snapshot.tabs,
            activeTabID: snapshot.activeTabId,
            tabIDByPaneID: tabInputs.tabIDByPaneID
        )

        return .prepared(
            PreparedWorkspaceComposition(
                identity: PreparedWorkspaceCompositionIdentity(
                    workspaceID: snapshot.id,
                    workspaceName: snapshot.name,
                    createdAt: snapshot.createdAt
                ),
                windowMemory: PreparedWorkspaceCompositionWindowMemory(
                    sidebarWidth: snapshot.sidebarWidth,
                    windowFrame: snapshot.windowFrame
                ),
                panes: snapshot.panes,
                tabs: snapshot.tabs,
                activeTabID: snapshot.activeTabId,
                paneGraph: paneGraph,
                expandedDrawerID: makeExpandedDrawerID(from: snapshot.panes),
                drawerPresentationPreferences: snapshot.drawerPresentationPreferences,
                tabShells: tabShells,
                tabGraph: PreparedWorkspaceTabGraph(
                    states: tabGraphStates,
                    indexByID: tabGraphIndexByID,
                    tabIDByPaneID: tabInputs.tabIDByPaneID
                ),
                arrangementCursors: arrangementCursors,
                terminalActivationInput: contentInputs.terminalActivationInput,
                nonterminalContentMountInput: contentInputs.nonterminalContentMountInput
            ))
    }

    private static func preparePaneInputs(
        from panes: [Pane]
    ) -> Result<PreparedWorkspaceCompositionPaneInputs, WorkspaceCompositionPreparationRejection> {
        var paneIDs = Set<UUID>()
        var drawerIDs = Set<UUID>()
        var firstExpandedDrawerID: UUID?
        for pane in panes {
            guard paneIDs.insert(pane.id).inserted else {
                return .failure(.duplicatePaneID(pane.id))
            }
            if let drawer = pane.drawer {
                guard drawerIDs.insert(drawer.drawerId).inserted else {
                    return .failure(.duplicateDrawerID(drawer.drawerId))
                }
                if drawer.isExpanded {
                    if let firstExpandedDrawerID {
                        return .failure(
                            .multipleExpandedDrawers(
                                firstDrawerID: firstExpandedDrawerID,
                                secondDrawerID: drawer.drawerId
                            ))
                    }
                    firstExpandedDrawerID = drawer.drawerId
                }
            }
        }

        var drawerPaneIDsByDrawerID: [UUID: Set<UUID>] = [:]
        for pane in panes {
            guard let drawer = pane.drawer else { continue }
            for childPaneID in drawer.paneIds where !paneIDs.contains(childPaneID) {
                return .failure(
                    .drawerContainsMissingPane(drawerID: drawer.drawerId, paneID: childPaneID)
                )
            }
            drawerPaneIDsByDrawerID[drawer.drawerId] = Set(drawer.paneIds)
        }

        return .success(
            PreparedWorkspaceCompositionPaneInputs(
                paneIDs: paneIDs,
                panes: panes,
                drawerParentPaneIDByDrawerID: makeDrawerParentPaneIDsByDrawerID(from: panes),
                drawerPaneIDsByDrawerID: drawerPaneIDsByDrawerID
            ))
    }

    private static func prepareTabInputs(
        snapshot: WorkspaceSQLiteSnapshot,
        paneInputs: PreparedWorkspaceCompositionPaneInputs
    ) -> Result<PreparedWorkspaceCompositionTabInputs, WorkspaceCompositionPreparationRejection> {
        let tabs = snapshot.tabs
        if tabs.isEmpty {
            if let activeTabID = snapshot.activeTabId {
                return .failure(.activeTabNotFound(activeTabID))
            }
        } else {
            guard let activeTabID = snapshot.activeTabId else {
                return .failure(.activeTabMissing)
            }
            guard tabs.contains(where: { $0.id == activeTabID }) else {
                return .failure(.activeTabNotFound(activeTabID))
            }
        }

        let panesByID = Dictionary(uniqueKeysWithValues: paneInputs.panes.map { ($0.id, $0) })
        var tabIDs = Set<UUID>()
        var arrangementIDs = Set<UUID>()
        var tabIDByPaneID: [UUID: UUID] = [:]
        for tab in tabs {
            guard tabIDs.insert(tab.id).inserted else {
                return .failure(.duplicateTabID(tab.id))
            }
            guard !tab.allPaneIds.isEmpty else {
                return .failure(.tabHasNoPanes(tab.id))
            }
            guard !tab.arrangements.isEmpty else {
                return .failure(.tabHasNoArrangements(tab.id))
            }

            var tabPaneIDs = Set<UUID>()
            for paneID in tab.allPaneIds {
                guard tabPaneIDs.insert(paneID).inserted else {
                    return .failure(.duplicateTabPaneID(tabID: tab.id, paneID: paneID))
                }
                guard paneInputs.paneIDs.contains(paneID) else {
                    return .failure(.tabReferencesMissingPane(tabID: tab.id, paneID: paneID))
                }
                if let firstTabID = tabIDByPaneID.updateValue(tab.id, forKey: paneID), firstTabID != tab.id {
                    return .failure(
                        .paneOwnedByMultipleTabs(
                            paneID: paneID,
                            firstTabID: firstTabID,
                            secondTabID: tab.id
                        ))
                }
            }

            let defaultCount = tab.arrangements.count(where: \.isDefault)
            guard defaultCount == 1 else {
                return .failure(.invalidDefaultArrangementCount(tabID: tab.id, count: defaultCount))
            }
            guard tab.arrangements.contains(where: { $0.id == tab.activeArrangementId }) else {
                return .failure(
                    .activeArrangementNotFound(
                        tabID: tab.id,
                        arrangementID: tab.activeArrangementId
                    ))
            }

            var referencedPaneIDs = Set<UUID>()
            for arrangement in tab.arrangements {
                guard arrangementIDs.insert(arrangement.id).inserted else {
                    return .failure(.duplicateArrangementID(arrangement.id))
                }
                if let rejection = validateArrangement(
                    arrangement,
                    tabID: tab.id,
                    tabPaneIDs: tabPaneIDs,
                    panesByID: panesByID,
                    paneInputs: paneInputs,
                    referencedPaneIDs: &referencedPaneIDs
                ) {
                    return .failure(rejection)
                }
                if arrangement.isDefault, arrangement.layout.isEmpty {
                    return .failure(
                        .defaultArrangementLayoutIsEmpty(
                            tabID: tab.id,
                            arrangementID: arrangement.id
                        ))
                }
            }
            for paneID in tab.allPaneIds where !referencedPaneIDs.contains(paneID) {
                return .failure(.tabPaneMissingFromArrangements(tabID: tab.id, paneID: paneID))
            }
        }

        for pane in paneInputs.panes where tabIDByPaneID[pane.id] == nil {
            guard
                isRecoverableUnownedPane(
                    pane,
                    panesByID: panesByID,
                    tabIDByPaneID: tabIDByPaneID
                )
            else {
                return .failure(.paneNotOwnedByTab(pane.id))
            }
        }
        return .success(PreparedWorkspaceCompositionTabInputs(tabIDByPaneID: tabIDByPaneID))
    }

    private static func isRecoverableUnownedPane(
        _ pane: Pane,
        panesByID: [UUID: Pane],
        tabIDByPaneID: [UUID: UUID]
    ) -> Bool {
        guard pane.residency == .backgrounded || pane.residency.isOrphaned else {
            return false
        }
        guard case .drawerChild(let parentPaneID) = pane.kind else {
            return true
        }
        guard
            tabIDByPaneID[parentPaneID] == nil,
            let parentPane = panesByID[parentPaneID],
            parentPane.residency == .backgrounded || parentPane.residency.isOrphaned
        else {
            return false
        }
        return parentPane.drawer?.paneIds.contains(pane.id) == true
    }

    private static func validateArrangement(
        _ arrangement: PaneArrangement,
        tabID: UUID,
        tabPaneIDs: Set<UUID>,
        panesByID: [UUID: Pane],
        paneInputs: PreparedWorkspaceCompositionPaneInputs,
        referencedPaneIDs: inout Set<UUID>
    ) -> WorkspaceCompositionPreparationRejection? {
        var seenLayoutPaneIDs = Set<UUID>()
        for paneID in arrangement.layout.paneIds {
            guard seenLayoutPaneIDs.insert(paneID).inserted else {
                return .arrangementLayoutPaneListedMultipleTimes(
                    arrangementID: arrangement.id,
                    paneID: paneID
                )
            }
            guard tabPaneIDs.contains(paneID) else {
                return .arrangementPaneMissingFromTab(
                    tabID: tabID,
                    arrangementID: arrangement.id,
                    paneID: paneID
                )
            }
            if case .drawerChild(let parentPaneID) = panesByID[paneID]?.kind {
                return .arrangementLayoutUsesDrawerChild(
                    arrangementID: arrangement.id,
                    paneID: paneID,
                    parentPaneID: parentPaneID
                )
            }
            referencedPaneIDs.insert(paneID)
        }
        var seenDividerIDs = Set<UUID>()
        for dividerID in arrangement.layout.dividerIds where !seenDividerIDs.insert(dividerID).inserted {
            return .arrangementLayoutDividerListedMultipleTimes(
                arrangementID: arrangement.id,
                dividerID: dividerID
            )
        }
        for paneID in arrangement.minimizedPaneIds where !arrangement.layout.contains(paneID) {
            return .arrangementMinimizedPaneMissingFromLayout(
                arrangementID: arrangement.id,
                paneID: paneID
            )
        }
        let visiblePaneIDs = arrangement.layout.paneIds.filter { !arrangement.minimizedPaneIds.contains($0) }
        if let activePaneID = arrangement.activePaneId {
            guard visiblePaneIDs.contains(activePaneID) else {
                return .activePaneNotVisible(arrangementID: arrangement.id, paneID: activePaneID)
            }
        } else if !visiblePaneIDs.isEmpty {
            return .activePaneMissing(arrangementID: arrangement.id)
        }

        for (drawerID, drawerView) in arrangement.drawerViews {
            guard let parentPaneID = paneInputs.drawerParentPaneIDByDrawerID[drawerID] else {
                return .drawerViewMissingDrawer(arrangementID: arrangement.id, drawerID: drawerID)
            }
            guard arrangement.layout.contains(parentPaneID) else {
                return .drawerViewParentPaneMissingFromLayout(
                    arrangementID: arrangement.id,
                    drawerID: drawerID,
                    parentPaneID: parentPaneID
                )
            }
            let validation = validateDrawerView(
                drawerView,
                context: PreparedCompositionDrawerViewValidationContext(
                    drawerID: drawerID,
                    arrangementID: arrangement.id,
                    tabID: tabID,
                    tabPaneIDs: tabPaneIDs,
                    mainLayoutPaneIDs: seenLayoutPaneIDs,
                    drawerPaneIDs: paneInputs.drawerPaneIDsByDrawerID[drawerID] ?? []
                )
            )
            switch validation {
            case .accepted(let drawerReferencedPaneIDs):
                referencedPaneIDs.formUnion(drawerReferencedPaneIDs)
            case .rejected(let rejection):
                return rejection
            }
        }
        return nil
    }

    private enum DrawerViewValidationResult {
        case accepted(referencedPaneIDs: Set<UUID>)
        case rejected(WorkspaceCompositionPreparationRejection)
    }

    private static func validateDrawerView(
        _ drawerView: DrawerView,
        context: PreparedCompositionDrawerViewValidationContext
    ) -> DrawerViewValidationResult {
        let drawerID = context.drawerID
        let arrangementID = context.arrangementID
        guard !drawerView.layout.topRow.isEmpty else {
            return .rejected(.drawerViewLayoutIsEmpty(arrangementID: arrangementID, drawerID: drawerID))
        }
        var seenPaneIDs = Set<UUID>()
        for paneID in drawerView.layout.paneIds {
            guard seenPaneIDs.insert(paneID).inserted, !context.mainLayoutPaneIDs.contains(paneID) else {
                return .rejected(
                    .drawerViewPaneListedMultipleTimes(arrangementID: arrangementID, paneID: paneID))
            }
            guard context.drawerPaneIDs.contains(paneID) else {
                return .rejected(.drawerViewPaneNotInDrawer(drawerID: drawerID, paneID: paneID))
            }
            guard context.tabPaneIDs.contains(paneID) else {
                return .rejected(
                    .arrangementPaneMissingFromTab(
                        tabID: context.tabID,
                        arrangementID: arrangementID,
                        paneID: paneID
                    )
                )
            }
        }
        var seenDividerIDs = Set<UUID>()
        for dividerID in drawerView.layout.dividerIds where !seenDividerIDs.insert(dividerID).inserted {
            return .rejected(
                .drawerViewLayoutDividerListedMultipleTimes(
                    arrangementID: arrangementID,
                    drawerID: drawerID,
                    dividerID: dividerID
                )
            )
        }
        for paneID in drawerView.minimizedPaneIds where !drawerView.layout.contains(paneID) {
            return .rejected(
                .drawerViewMinimizedPaneMissingFromLayout(
                    arrangementID: arrangementID,
                    drawerID: drawerID,
                    paneID: paneID
                )
            )
        }
        let visiblePaneIDs = drawerView.layout.paneIds.filter { !drawerView.minimizedPaneIds.contains($0) }
        if let activeChildID = drawerView.activeChildId {
            guard visiblePaneIDs.contains(activeChildID) else {
                return .rejected(
                    .drawerViewActiveChildNotVisible(
                        arrangementID: arrangementID,
                        drawerID: drawerID,
                        paneID: activeChildID
                    )
                )
            }
        } else if !visiblePaneIDs.isEmpty {
            return .rejected(
                .drawerViewActiveChildMissing(arrangementID: arrangementID, drawerID: drawerID))
        }
        return .accepted(referencedPaneIDs: seenPaneIDs)
    }

    private static func makeDrawerParentPaneIDsByDrawerID(from panes: [Pane]) -> [UUID: UUID] {
        Dictionary(
            uniqueKeysWithValues: panes.compactMap { pane in
                pane.drawer.map { ($0.drawerId, pane.id) }
            }
        )
    }

    private static func makeExpandedDrawerID(from panes: [Pane]) -> UUID? {
        panes.compactMap { pane -> UUID? in
            guard let drawer = pane.drawer, drawer.isExpanded else { return nil }
            return drawer.drawerId
        }.last
    }

    private static func makePreparedPaneGraph(
        from panes: [Pane]
    ) -> Result<PreparedWorkspacePaneGraph, WorkspacePaneGraphReplacementRejection> {
        WorkspacePaneGraphReplacement.prepare(
            Dictionary(uniqueKeysWithValues: panes.map { ($0.id, PaneGraphState(pane: $0)) })
        ).map { PreparedWorkspacePaneGraph(replacement: $0) }
    }

    private static func makePreparedTabShells(from tabs: [Tab]) -> PreparedWorkspaceTabShells {
        let shells = tabs.map {
            TabShell(id: $0.id, name: $0.name, colorHex: $0.colorHex)
        }
        return PreparedWorkspaceTabShells(
            shells: shells,
            indexByID: Dictionary(
                uniqueKeysWithValues: shells.enumerated().map { ($0.element.id, $0.offset) }
            )
        )
    }

    private static func makePreparedContentInputs(
        panes: [Pane],
        tabs: [Tab],
        activeTabID: UUID?,
        tabIDByPaneID: [UUID: UUID]
    ) -> PreparedWorkspaceContentInputs {
        let tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let panesByID = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
        var terminalEntries: [(sourceIndex: Int, descriptor: TerminalActivationDescriptor)] = []
        var nonterminalEntries: [(sourceIndex: Int, descriptor: NonterminalContentMountDescriptor)] = []

        for (sourceIndex, pane) in panes.enumerated() {
            // Terminal descriptor inclusion below requires only a strictly
            // valid tab and a resolved host placement (SPEC R1 in full):
            // residency is not a gate here for terminals. The nonterminal
            // lane keeps its residency guards inside its own switch case —
            // an unowned recoverable pane still gets no host placement at
            // all via the `tabIDByPaneID`/`tabsByID` guard below, unchanged.
            guard let tabID = tabIDByPaneID[pane.id], let tab = tabsByID[tabID] else {
                continue
            }
            guard
                let hostPlacement = contentHostPlacement(
                    for: pane,
                    tabID: tabID,
                    panesByID: panesByID
                )
            else {
                preconditionFailure("validated drawer pane is missing its host placement")
            }
            let visibilityPriority = contentVisibilityPriority(
                for: pane,
                tab: tab,
                activeTabID: activeTabID,
                panesByID: panesByID
            )

            switch preparedContentDescriptor(
                for: pane,
                visibilityPriority: visibilityPriority,
                hostPlacement: hostPlacement
            ) {
            case .terminal(let descriptor):
                terminalEntries.append((sourceIndex, descriptor))
            case .nonterminal(let descriptor):
                guard pane.residency.isActive else { continue }
                if case .drawerChild(let parentPaneID) = pane.kind,
                    panesByID[parentPaneID]?.residency.isActive != true
                {
                    continue
                }
                nonterminalEntries.append((sourceIndex, descriptor))
            }
        }

        terminalEntries.sort { lhs, rhs in
            if lhs.descriptor.visibilityPriority != rhs.descriptor.visibilityPriority {
                return lhs.descriptor.visibilityPriority < rhs.descriptor.visibilityPriority
            }
            return lhs.sourceIndex < rhs.sourceIndex
        }
        nonterminalEntries.sort { lhs, rhs in
            if lhs.descriptor.visibilityPriority != rhs.descriptor.visibilityPriority {
                return lhs.descriptor.visibilityPriority < rhs.descriptor.visibilityPriority
            }
            return lhs.sourceIndex < rhs.sourceIndex
        }
        return PreparedWorkspaceContentInputs(
            terminalActivationInput: TerminalActivationInput(
                entries: terminalEntries.map(\.descriptor)
            ),
            nonterminalContentMountInput: NonterminalContentMountInput(
                entries: nonterminalEntries.map(\.descriptor)
            )
        )
    }

    private enum PreparedContentDescriptor {
        case terminal(TerminalActivationDescriptor)
        case nonterminal(NonterminalContentMountDescriptor)
    }

    private static func preparedContentDescriptor(
        for pane: Pane,
        visibilityPriority: TerminalActivationVisibilityPriority,
        hostPlacement: TerminalHostPlacementIdentity
    ) -> PreparedContentDescriptor {
        switch pane.content {
        case .terminal:
            return .terminal(
                TerminalActivationDescriptor(
                    pane: pane,
                    visibilityPriority: visibilityPriority,
                    hostPlacement: hostPlacement
                )
            )
        case .webview:
            return .nonterminal(
                nonterminalContentDescriptor(
                    .webview(pane),
                    visibilityPriority: visibilityPriority,
                    hostPlacement: hostPlacement
                )
            )
        case .bridgePanel:
            return .nonterminal(
                nonterminalContentDescriptor(
                    .bridgePanel(pane),
                    visibilityPriority: visibilityPriority,
                    hostPlacement: hostPlacement
                )
            )
        case .codeViewer:
            return .nonterminal(
                nonterminalContentDescriptor(
                    .codeViewer(pane),
                    visibilityPriority: visibilityPriority,
                    hostPlacement: hostPlacement
                )
            )
        case .unsupported:
            return .nonterminal(
                nonterminalContentDescriptor(
                    .unsupported(pane),
                    visibilityPriority: visibilityPriority,
                    hostPlacement: hostPlacement
                )
            )
        }
    }

    private static func nonterminalContentDescriptor(
        _ content: NonterminalContentMountContent,
        visibilityPriority: TerminalActivationVisibilityPriority,
        hostPlacement: TerminalHostPlacementIdentity
    ) -> NonterminalContentMountDescriptor {
        NonterminalContentMountDescriptor(
            content: content,
            visibilityPriority: visibilityPriority,
            hostPlacement: hostPlacement
        )
    }

    private static func contentHostPlacement(
        for pane: Pane,
        tabID: UUID,
        panesByID: [UUID: Pane]
    ) -> TerminalHostPlacementIdentity? {
        switch pane.kind {
        case .layout:
            return .tab(tabID: tabID)
        case .drawerChild(let parentPaneID):
            guard let parentPane = panesByID[parentPaneID], let drawer = parentPane.drawer else { return nil }
            return .drawer(
                tabID: tabID,
                parentPaneID: PaneId(existingUUID: parentPaneID),
                drawerID: drawer.drawerId
            )
        }
    }

    private static func contentVisibilityPriority(
        for pane: Pane,
        tab: Tab,
        activeTabID: UUID?,
        panesByID: [UUID: Pane]
    ) -> TerminalActivationVisibilityPriority {
        // Residency is an input here, not only at the (now terminal-only)
        // call-site guard removed above: a residency-backgrounded terminal
        // still receives a descriptor, but never an active/visible priority.
        // Nonterminal panes never reach this while non-active — their own
        // residency guard already excludes them before this call — so this
        // is a no-op for them and newly load-bearing for terminals only.
        guard pane.residency.isActive else { return .hidden }
        guard tab.id == activeTabID else { return .hidden }
        let arrangement = tab.activeArrangement
        switch pane.kind {
        case .layout:
            let isVisible =
                arrangement.layout.contains(pane.id)
                && !arrangement.minimizedPaneIds.contains(pane.id)
            guard isVisible else { return .hidden }
            return arrangement.activePaneId == pane.id ? .activeVisible : .visible
        case .drawerChild(let parentPaneID):
            let parentIsVisible =
                arrangement.layout.contains(parentPaneID)
                && !arrangement.minimizedPaneIds.contains(parentPaneID)
            guard parentIsVisible,
                let parentDrawer = panesByID[parentPaneID]?.drawer,
                parentDrawer.isExpanded,
                let drawerView = arrangement.drawerViews[parentDrawer.drawerId],
                drawerView.layout.contains(pane.id),
                !drawerView.minimizedPaneIds.contains(pane.id)
            else { return .hidden }
            return drawerView.activeChildId == pane.id ? .activeVisible : .visible
        }
    }

    private static func makeArrangementCursors(
        from tabs: [Tab]
    ) -> PreparedWorkspaceArrangementCursors {
        var activeArrangementIDsByTabID: [UUID: UUID] = [:]
        var paneCursorsByArrangementID: [UUID: ArrangementPaneCursorState] = [:]
        var drawerCursorsByKey: [ArrangementDrawerCursorKey: ArrangementDrawerCursorState] = [:]
        for tab in tabs {
            activeArrangementIDsByTabID[tab.id] = tab.activeArrangementId
            for arrangement in tab.arrangements {
                paneCursorsByArrangementID[arrangement.id] = .init(activePaneId: arrangement.activePaneId)
                for (drawerID, drawerView) in arrangement.drawerViews {
                    drawerCursorsByKey[
                        ArrangementDrawerCursorKey(arrangementId: arrangement.id, drawerId: drawerID)
                    ] = .init(activeChildId: drawerView.activeChildId)
                }
            }
        }
        return PreparedWorkspaceArrangementCursors(
            activeArrangementIDsByTabID: activeArrangementIDsByTabID,
            paneCursorsByArrangementID: paneCursorsByArrangementID,
            drawerCursorsByKey: drawerCursorsByKey
        )
    }
}

import AgentStudioInfrastructure
import Foundation
import Observation

struct DrawerViewGraphState: Equatable, Hashable, Sendable {
    var layout: DrawerGridLayout
    var minimizedPaneIds: Set<UUID>

    init(layout: DrawerGridLayout = DrawerGridLayout(), minimizedPaneIds: Set<UUID> = []) {
        self.layout = layout
        self.minimizedPaneIds = minimizedPaneIds.intersection(layout.paneIds)
    }

    init(_ drawerView: DrawerView) {
        self.init(layout: drawerView.layout, minimizedPaneIds: drawerView.minimizedPaneIds)
    }
}

struct PaneArrangementGraphState: Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var isDefault: Bool
    var layout: Layout
    var minimizedPaneIds: Set<UUID>
    var drawerViews: [UUID: DrawerViewGraphState]

    init(
        id: UUID,
        name: String,
        isDefault: Bool,
        layout: Layout,
        minimizedPaneIds: Set<UUID>,
        drawerViews: [UUID: DrawerViewGraphState]
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.layout = layout
        self.minimizedPaneIds = minimizedPaneIds.intersection(layout.paneIds)
        self.drawerViews = drawerViews
    }

    init(_ arrangement: PaneArrangement) {
        self.init(
            id: arrangement.id,
            name: arrangement.name,
            isDefault: arrangement.isDefault,
            layout: arrangement.layout,
            minimizedPaneIds: arrangement.minimizedPaneIds,
            drawerViews: arrangement.drawerViews.mapValues(DrawerViewGraphState.init)
        )
    }
}

package struct TabGraphState: Equatable, Hashable, Sendable {
    let tabId: UUID
    var allPaneIds: [UUID]
    var arrangements: [PaneArrangementGraphState]

    package var tabID: UUID { tabId }

    package var paneIDs: [UUID] { allPaneIds }

    package func paneIDs(inArrangement arrangementID: UUID) -> [UUID]? {
        arrangements.first { $0.id == arrangementID }?.layout.paneIds
    }

    init(tabId: UUID, allPaneIds: [UUID], arrangements: [PaneArrangementGraphState]) {
        self.tabId = tabId
        self.allPaneIds = allPaneIds
        self.arrangements = arrangements
    }

    init(_ state: TabArrangementState) {
        self.init(
            tabId: state.tabId,
            allPaneIds: state.allPaneIds,
            arrangements: state.arrangements.map(PaneArrangementGraphState.init)
        )
    }
}

@MainActor
@Observable
package final class WorkspaceTabGraphAtom {
    @ObservationIgnored private let tabStateFamily = AtomFamily<UUID, TabGraphState>(
        telemetryLabel: "workspace_tab_graph",
        isContentEqual: ==
    )
    @ObservationIgnored private let acceptedCommitRevision = AtomRevision()
    private var tabOrder: [UUID] = []
    private var tabIndexByID: [UUID: Int] = [:]
    private var tabIDByPaneID: [UUID: UUID] = [:]
    private var tabIDByArrangementID: [UUID: UUID] = [:]

    var tabGraphAcceptedCommitRevision: Int { acceptedCommitRevision.value }

    var tabStates: [TabGraphState] {
        tabOrder.compactMap { tabStateFamily.value(for: $0) }
    }

    /// Raw COW capture for detached readers; no ordered-array reconstruction.
    package func tabStateSnapshot() -> [UUID: TabGraphState] {
        tabStateFamily.snapshot()
    }

    package var tabIDsInOrder: [UUID] { tabOrder }

    var tabCount: Int {
        tabOrder.count
    }

    func containsTab(_ id: UUID) -> Bool {
        tabIndexByID[id] != nil
    }

    func replaceStates(_ states: [TabGraphState]) {
        replaceTabStates(states)
    }

    func replaceTabStates(_ states: [TabGraphState]) {
        let indexes = Self.makeIndexes(states)
        guard tabStates != states else { return }
        let mutation = AtomMutationContext(aggregateRevision: acceptedCommitRevision)
        mutation.recordAcceptedChange()
        tabStateFamily.replaceAll(
            Dictionary(uniqueKeysWithValues: states.map { ($0.tabId, $0) }),
            mutation: mutation
        )
        tabOrder = states.map(\.tabId)
        tabIndexByID = indexes.tabIndexByID
        tabIDByPaneID = indexes.tabIDByPaneID
        tabIDByArrangementID = indexes.tabIDByArrangementID
        mutation.commit()
    }

    func tabState(_ tabId: UUID) -> TabGraphState? {
        tabStateFamily.value(for: tabId)
    }

    /// Read the keyed semantic revision without materializing the tab's
    /// arrangements or drawer projections.
    package func tabStateRevision(for tabId: UUID) -> Int {
        tabStateFamily.revision(for: tabId)
    }

    func tabIndex(for tabID: UUID) -> Int? {
        tabIndexByID[tabID]
    }

    func tabID(containingPane paneID: UUID) -> UUID? {
        tabIDByPaneID[paneID]
    }

    func tabID(containingArrangement arrangementID: UUID) -> UUID? {
        tabIDByArrangementID[arrangementID]
    }

    private static func makeIndexes(
        _ states: [TabGraphState]
    ) -> (
        tabIndexByID: [UUID: Int],
        tabIDByPaneID: [UUID: UUID],
        tabIDByArrangementID: [UUID: UUID]
    ) {
        var tabIndexByID: [UUID: Int] = [:]
        var tabIDByPaneID: [UUID: UUID] = [:]
        var tabIDByArrangementID: [UUID: UUID] = [:]
        for (index, state) in states.enumerated() {
            precondition(
                tabIndexByID.updateValue(index, forKey: state.tabId) == nil,
                "tab graph identity must be unique"
            )
            for paneID in state.allPaneIds {
                if let firstTabID = tabIDByPaneID.updateValue(state.tabId, forKey: paneID),
                    firstTabID != state.tabId
                {
                    preconditionFailure(
                        "pane \(paneID) cannot belong to tab \(firstTabID) and tab \(state.tabId)"
                    )
                }
            }
            for arrangement in state.arrangements {
                guard tabIDByArrangementID.updateValue(state.tabId, forKey: arrangement.id) == nil else {
                    preconditionFailure("arrangement \(arrangement.id) must have one tab owner")
                }
            }
        }
        return (tabIndexByID, tabIDByPaneID, tabIDByArrangementID)
    }
}

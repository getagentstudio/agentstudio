import Foundation

/// Snapshot of a single arrangement's command-validation identity.
/// Carries only what the validator needs: existence and default ownership.
package struct ArrangementSnapshot: Equatable {
    package let id: UUID
    package let isDefault: Bool

    package init(id: UUID, isDefault: Bool) {
        self.id = id
        self.isDefault = isDefault
    }
}

/// Snapshot of a single tab's structural state.
/// Contains ONLY IDs and counts — no NSView references.
package struct TabSnapshot: Equatable {
    let id: UUID
    let visiblePaneIds: [UUID]
    let layoutPaneIds: [UUID]
    let ownedPaneIds: [UUID]
    let minimizedPaneIds: Set<UUID>
    let activePaneId: UUID?
    let activeArrangementId: UUID?
    let arrangements: [ArrangementSnapshot]
    let isLayoutSplit: Bool

    package init(
        id: UUID,
        visiblePaneIds: [UUID],
        layoutPaneIds: [UUID]? = nil,
        ownedPaneIds: [UUID],
        minimizedPaneIds: Set<UUID> = [],
        activePaneId: UUID?,
        isLayoutSplit: Bool? = nil,
        activeArrangementId: UUID? = nil,
        arrangements: [ArrangementSnapshot] = []
    ) {
        self.id = id
        self.visiblePaneIds = visiblePaneIds
        self.layoutPaneIds = layoutPaneIds ?? visiblePaneIds
        self.ownedPaneIds = ownedPaneIds
        self.minimizedPaneIds = minimizedPaneIds
        self.activePaneId = activePaneId
        self.activeArrangementId = activeArrangementId
        self.arrangements = arrangements
        self.isLayoutSplit = isLayoutSplit ?? (visiblePaneIds.count > 1)
    }

    var isSplit: Bool { isLayoutSplit }
    var visiblePaneCount: Int { visiblePaneIds.count }
    var ownedPaneCount: Int { ownedPaneIds.count }

    func ownsPane(_ paneId: UUID) -> Bool {
        ownedPaneIds.contains(paneId)
    }

    func showsPane(_ paneId: UUID) -> Bool {
        visiblePaneIds.contains(paneId)
    }

    func laysOutPane(_ paneId: UUID) -> Bool {
        layoutPaneIds.contains(paneId)
    }

    func arrangement(_ arrangementId: UUID) -> ArrangementSnapshot? {
        arrangements.first { $0.id == arrangementId }
    }
}

/// Lightweight, pure-value snapshot of tab/pane state for validation.
/// Contains ONLY structural information (IDs, counts) — no NSView references.
/// Tests construct these directly with UUIDs.
package struct ActionStateSnapshot: Equatable {
    let tabs: [TabSnapshot]
    let activeTabId: UUID?
    let isManagementLayerActive: Bool
    /// Runtime-only Zoom source pane keyed by owning tab.
    let zoomSourcePaneIdByTabId: [UUID: UUID]
    package let knownRepoIds: Set<UUID>
    package let knownWorktreeIds: Set<UUID>
    package let knownPaneIds: Set<UUID>
    /// Drawer child -> parent layout pane mapping for drag/drop policy checks.
    let drawerParentByPaneId: [UUID: UUID]
    /// Parent layout pane -> current drawer layout for validator-side legality checks.
    let drawerLayoutByParentPaneId: [UUID: DrawerGridLayout]
    /// Drawer children whose content is a browser.
    let drawerBrowserPaneIds: Set<UUID>

    /// Reverse lookup: owned paneId → tabId for O(1) resolution.
    private let ownedPaneToTab: [UUID: UUID]
    /// Reverse lookup: visible paneId → tabId for O(1) resolution.
    private let visiblePaneToTab: [UUID: UUID]

    package init(
        tabs: [TabSnapshot],
        activeTabId: UUID?,
        isManagementLayerActive: Bool,
        zoomSourcePaneIdByTabId: [UUID: UUID] = [:],
        knownRepoIds: Set<UUID> = [],
        knownWorktreeIds: Set<UUID> = [],
        knownPaneIds: Set<UUID>? = nil,
        drawerParentByPaneId: [UUID: UUID] = [:],
        drawerLayoutByParentPaneId: [UUID: DrawerGridLayout] = [:],
        drawerBrowserPaneIds: Set<UUID> = []
    ) {
        self.drawerBrowserPaneIds = drawerBrowserPaneIds
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.isManagementLayerActive = isManagementLayerActive
        self.zoomSourcePaneIdByTabId = zoomSourcePaneIdByTabId
        self.knownRepoIds = knownRepoIds
        self.knownWorktreeIds = knownWorktreeIds
        self.drawerParentByPaneId = drawerParentByPaneId
        self.drawerLayoutByParentPaneId = drawerLayoutByParentPaneId

        var ownedLookup: [UUID: UUID] = [:]
        var visibleLookup: [UUID: UUID] = [:]
        for tab in tabs {
            for paneId in tab.ownedPaneIds {
                ownedLookup[paneId] = tab.id
            }
            for paneId in tab.visiblePaneIds {
                visibleLookup[paneId] = tab.id
            }
        }
        // Drawer panes belong to the same tab as their parent layout pane.
        // A drawer cannot exist without its parent, so the parent is always
        // in the lookup by this point.
        for (drawerPaneId, parentPaneId) in drawerParentByPaneId {
            guard let parentTabId = ownedLookup[parentPaneId] else { continue }
            ownedLookup[drawerPaneId] = parentTabId
        }
        self.ownedPaneToTab = ownedLookup
        self.visiblePaneToTab = visibleLookup
        self.knownPaneIds = knownPaneIds ?? Set(ownedLookup.keys)
    }

    func tab(_ id: UUID) -> TabSnapshot? {
        tabs.first { $0.id == id }
    }

    func tabOwnsPane(_ tabId: UUID, paneId: UUID) -> Bool {
        ownedPaneToTab[paneId] == tabId
    }

    func tabShowsPane(_ tabId: UUID, paneId: UUID) -> Bool {
        visiblePaneToTab[paneId] == tabId
    }

    func tabOwning(paneId: UUID) -> TabSnapshot? {
        guard let tabId = ownedPaneToTab[paneId] else { return nil }
        return tab(tabId)
    }

    func tabShowing(paneId: UUID) -> TabSnapshot? {
        guard let tabId = visiblePaneToTab[paneId] else { return nil }
        return tab(tabId)
    }

    func drawerParentPaneId(of paneId: UUID) -> UUID? {
        drawerParentByPaneId[paneId]
    }

    func drawerLayout(for parentPaneId: UUID) -> DrawerGridLayout? {
        drawerLayoutByParentPaneId[parentPaneId]
    }

    var tabCount: Int { tabs.count }

    /// All pane IDs across all tabs. Used for cardinality validation.
    var allOwnedPaneIds: Set<UUID> {
        Set(tabs.flatMap(\.ownedPaneIds))
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tabs == rhs.tabs
            && lhs.activeTabId == rhs.activeTabId
            && lhs.isManagementLayerActive == rhs.isManagementLayerActive
            && lhs.zoomSourcePaneIdByTabId == rhs.zoomSourcePaneIdByTabId
            && lhs.knownRepoIds == rhs.knownRepoIds
            && lhs.knownWorktreeIds == rhs.knownWorktreeIds
            && lhs.knownPaneIds == rhs.knownPaneIds
            && lhs.drawerParentByPaneId == rhs.drawerParentByPaneId
            && lhs.drawerLayoutByParentPaneId == rhs.drawerLayoutByParentPaneId
    }
}

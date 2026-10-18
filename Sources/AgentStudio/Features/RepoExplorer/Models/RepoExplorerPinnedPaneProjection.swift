import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

package struct RepoExplorerPinnedPaneProjectionRequest: Sendable {
    let paneStatesByID: [UUID: PaneGraphState]
    let tabStatesByID: [UUID: TabGraphState]
    let tabIDsInOrder: [UUID]
    let activeArrangementIDsByTabID: [UUID: UUID]
    let activityTimesByPaneID: [UUID: PaneActivityTime]
    let showsDrawerPanes: Bool
    let referenceInstant: ContinuousClock.Instant
    let wallNow: Date
    let calendar: Calendar

    @MainActor
    package init(
        coreAtoms: CoreAtoms
    ) {
        self.paneStatesByID = coreAtoms.workspacePaneGraph.paneStateSnapshot()
        self.tabStatesByID = coreAtoms.workspaceTabGraph.tabStateSnapshot()
        self.tabIDsInOrder = coreAtoms.workspaceTabGraph.tabIDsInOrder
        self.activeArrangementIDsByTabID = coreAtoms.workspaceArrangementCursor.activeArrangementIdsByTabId
        self.activityTimesByPaneID = coreAtoms.paneActivityTime.snapshot()
        self.showsDrawerPanes = coreAtoms.workspaceSidebarState.showsDrawerPanes
        self.referenceInstant = ContinuousClock.now
        self.wallNow = Date()
        self.calendar = .current
    }
}

package enum RepoExplorerPinnedPaneProjector {
    @concurrent nonisolated package static func project(
        _ request: RepoExplorerPinnedPaneProjectionRequest,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) async throws -> [UUID] {
        let clock = ContinuousClock()
        let started = clock.now
        defer {
            performanceTraceRecorder?.recordDuration(
                .sidebarProjection,
                duration: started.duration(to: clock.now),
                attributes: [
                    "agentstudio.performance.sidebar.surface": .string("repo"),
                    "agentstudio.performance.sidebar.query_state": .string("empty"),
                    "agentstudio.performance.sidebar.group_mode": .string("not_applicable"),
                    "agentstudio.performance.sidebar.phase": .string("pinned_projection_worker"),
                    "agentstudio.performance.sidebar.trigger": .string("pinned_navigation"),
                ]
            )
        }
        try Task.checkCancellation()

        var eligibleMembers: [RepoExplorerPinnedActivityMember] = []
        var seenPaneIDs = Set<UUID>()
        for (tabIndex, tabID) in request.tabIDsInOrder.enumerated() {
            guard let tabState = request.tabStatesByID[tabID] else { continue }
            let selectedPaneIDs =
                request.activeArrangementIDsByTabID[tabID].flatMap {
                    tabState.paneIDs(inArrangement: $0)
                } ?? []
            let selectedPaneIndexes = Dictionary(
                uniqueKeysWithValues: selectedPaneIDs.enumerated().map { ($0.element, $0.offset) })
            for (paneIndex, paneID) in tabState.paneIDs.enumerated() {
                guard seenPaneIDs.insert(paneID).inserted,
                    let paneState = request.paneStatesByID[paneID],
                    paneState.sessionResidency.isActive,
                    paneState.isPinned
                else {
                    continue
                }
                try Task.checkCancellation()

                eligibleMembers.append(
                    RepoExplorerPinnedActivityMember(
                        paneID: paneID,
                        tabIndex: tabIndex,
                        paneIndexInTab: selectedPaneIndexes[paneID] ?? paneIndex,
                        activityTime: request.activityTimesByPaneID[paneID],
                        isDrawer: paneState.isDrawerChild,
                        ownerPaneID: paneState.parentPaneId
                    )
                )
            }
        }

        return RepoExplorerProjection.orderedPinnedPaneGroups(
            eligibleMembers,
            showsDrawers: request.showsDrawerPanes,
            referenceInstant: request.referenceInstant,
            wallNow: request.wallNow,
            calendar: request.calendar
        ).flatMap(\.paneIDs)
    }

    @concurrent nonisolated package static func targetPaneID(
        from request: RepoExplorerPinnedPaneProjectionRequest,
        originPaneID: UUID?,
        previous: Bool,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) async throws -> UUID? {
        let orderedPaneIDs = try await project(request, performanceTraceRecorder: performanceTraceRecorder)
        return RepoExplorerPinnedPaneNavigationPolicy.targetPaneID(
            from: originPaneID,
            direction: previous ? .previous : .next,
            orderedPaneIDs: orderedPaneIDs
        )
    }
}

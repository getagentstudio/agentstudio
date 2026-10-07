import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

package typealias RepoExplorerGroupingMode = RepoSidebarGroupingMode
package typealias RepoExplorerSortOrder = SidebarSortDirection

extension RepoSidebarGroupingMode {
    var title: String {
        switch self {
        case .repo:
            return "Repo"
        case .activity:
            return "Activity"
        case .tab:
            return "Tab"
        }
    }

    var icon: CommandIcon {
        switch self {
        case .repo:
            return .system(.folder)
        case .activity:
            return .system(.clock)
        case .tab:
            return .system(.rectangleStack)
        }
    }
}

enum RepoExplorerPaneSecondaryLine: Equatable, Sendable {
    case note(String)
    case terminalOutput(String)

    var text: String {
        switch self {
        case .note(let text), .terminalOutput(let text): text
        }
    }

    var iconSystemName: String {
        switch self {
        case .note: "long.text.page.and.pencil"
        case .terminalOutput: "apple.terminal"
        }
    }

    var isTerminalOutput: Bool {
        if case .terminalOutput = self { return true }
        return false
    }
}

struct RepoExplorerPaneRowFacts: Equatable, Sendable {
    let terminalTitle: String
    let sessionStatus: AgentSessionStatus?
    let contextDisplay: PaneContextDisplay?
    let activityAt: Date?
    let paneActivityTime: PaneActivityTime?
    let isPinned: Bool
    let noteText: String?
    let latestMessageText: String?
    let recencyReferenceDate: Date
    let recencyText: String
    let recencyTier: RepoExplorerPaneRecencyTier
    let nextPresentationChangeDate: Date?
    let isActive: Bool
    let isDrawerPane: Bool
    let drawerOwnerPaneID: UUID?

    init(
        terminalTitle: String,
        sessionStatus: AgentSessionStatus? = nil,
        contextDisplay: PaneContextDisplay? = nil,
        activityAt: Date? = nil,
        paneActivityTime: PaneActivityTime? = nil,
        isPinned: Bool = false,
        noteText: String? = nil,
        latestMessageText: String?,
        recencyReferenceDate: Date,
        recencyText: String,
        recencyTier: RepoExplorerPaneRecencyTier = .strongBlue,
        nextPresentationChangeDate: Date? = nil,
        isActive: Bool,
        isDrawerPane: Bool = false,
        drawerOwnerPaneID: UUID? = nil
    ) {
        self.terminalTitle = terminalTitle
        self.sessionStatus = sessionStatus
        self.contextDisplay = contextDisplay
        self.activityAt = activityAt
        self.paneActivityTime = paneActivityTime
        self.isPinned = isPinned
        self.noteText = noteText
        self.latestMessageText = latestMessageText
        self.recencyReferenceDate = recencyReferenceDate
        self.recencyText = recencyText
        self.recencyTier = recencyTier
        self.nextPresentationChangeDate = nextPresentationChangeDate
        self.isActive = isActive
        self.isDrawerPane = isDrawerPane
        self.drawerOwnerPaneID = drawerOwnerPaneID
    }

    var secondaryLine: RepoExplorerPaneSecondaryLine? {
        normalizedSecondaryText(noteText).map(RepoExplorerPaneSecondaryLine.note)
    }

    var sidebarTerminalTitle: String {
        contextDisplay?.agentTitle ?? terminalTitle
    }

    private func normalizedSecondaryText(_ text: String?) -> String? {
        let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedText, !normalizedText.isEmpty else { return nil }
        return normalizedText
    }
}

struct RepoExplorerTabGroupFacts: Equatable, Sendable {
    let displayTitle: String
}

enum RepoExplorerPaneRecencyText {
    static func display(lastInteractedAt: Date, now: Date) -> String {
        let elapsedSeconds = max(0, now.timeIntervalSince(lastInteractedAt))
        let elapsedMinutes = Int(elapsedSeconds / 60)
        if elapsedMinutes < 1 { return "Now" }
        if elapsedMinutes < 60 { return "\(elapsedMinutes)m" }
        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 { return "\(elapsedHours)h" }
        return "\(elapsedHours / 24)d"
    }

    static func nextPresentationChangeDate(referenceDate: Date, now: Date) -> Date {
        let elapsedSeconds = max(0, now.timeIntervalSince(referenceDate))
        let nextTextBoundary: TimeInterval
        if elapsedSeconds < 60 {
            nextTextBoundary = 60
        } else if elapsedSeconds < 60 * 60 {
            nextTextBoundary = (floor(elapsedSeconds / 60) + 1) * 60
        } else if elapsedSeconds < 24 * 60 * 60 {
            nextTextBoundary = (floor(elapsedSeconds / (60 * 60)) + 1) * 60 * 60
        } else {
            nextTextBoundary = (floor(elapsedSeconds / (24 * 60 * 60)) + 1) * 24 * 60 * 60
        }

        let tierBoundaries = [
            AppPolicies.EntityRecency.strongBlueDuration,
            AppPolicies.EntityRecency.mediumBlueDuration,
            AppPolicies.EntityRecency.mutedBlueDuration,
            AppPolicies.EntityRecency.faintBlueDuration,
        ]
        let nextTierBoundary = tierBoundaries.first { $0 > elapsedSeconds }
        return referenceDate.addingTimeInterval(min(nextTextBoundary, nextTierBoundary ?? nextTextBoundary))
    }
}

enum RepoExplorerPaneRecencyTier: Equatable, Sendable {
    case strongBlue
    case mediumBlue
    case mutedBlue
    case faintBlue
    case grey

    static func classify(referenceDate: Date, now: Date) -> Self {
        let elapsed = max(0, now.timeIntervalSince(referenceDate))
        if elapsed < AppPolicies.EntityRecency.strongBlueDuration { return .strongBlue }
        if elapsed < AppPolicies.EntityRecency.mediumBlueDuration { return .mediumBlue }
        if elapsed < AppPolicies.EntityRecency.mutedBlueDuration { return .mutedBlue }
        if elapsed < AppPolicies.EntityRecency.faintBlueDuration { return .faintBlue }
        return .grey
    }
}

extension SidebarSortDirection {
    var title: String {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        }
    }
}

struct RepoExplorerSnapshot: Equatable, Sendable {
    let repos: [RepoPresentationItem]
    let repoEnrichmentSnapshotByRepoId: [UUID: RepoEnrichment]
    let surface: SidebarSurface
    let groupingMode: RepoExplorerGroupingMode
    let subgroupMode: SidebarSubgroupMode
    let sortField: SidebarSortField
    let showsPinned: Bool
    let showsDrawerPanes: Bool
    let referenceDate: Date
    let referenceInstant: ContinuousClock.Instant?
    let calendar: Calendar
    let sortOrder: RepoExplorerSortOrder
    let query: String
    let paneLocationsByWorktreeId: [UUID: [WorkspacePaneLocation]]
    let unassociatedPaneLocations: [WorkspacePaneLocation]
    let bridgePaneCommandCandidatesByWorktreeId: [UUID: [BridgePaneCommandCandidate]]

    init(
        repos: [RepoPresentationItem],
        repoEnrichmentByRepoId: [UUID: RepoEnrichment],
        surface: SidebarSurface = .repos,
        groupingMode: RepoExplorerGroupingMode = .repo,
        subgroupMode: SidebarSubgroupMode = .ungrouped,
        sortField: SidebarSortField = .name,
        showsPinned: Bool = true,
        showsDrawerPanes: Bool = true,
        referenceDate: Date = Date(timeIntervalSince1970: 0),
        referenceInstant: ContinuousClock.Instant? = nil,
        calendar: Calendar = .current,
        sortOrder: RepoExplorerSortOrder = .default,
        query: String,
        paneLocationsByWorktreeId: [UUID: [WorkspacePaneLocation]] = [:],
        unassociatedPaneLocations: [WorkspacePaneLocation] = [],
        bridgePaneCommandCandidatesByWorktreeId: [UUID: [BridgePaneCommandCandidate]] = [:]
    ) {
        self.repos = repos
        self.repoEnrichmentSnapshotByRepoId = repoEnrichmentByRepoId
        self.surface = surface
        self.groupingMode = groupingMode
        self.subgroupMode = subgroupMode
        self.sortField = sortField
        self.showsPinned = showsPinned
        self.showsDrawerPanes = showsDrawerPanes
        self.referenceDate = referenceDate
        self.referenceInstant = referenceInstant
        self.calendar = calendar
        self.sortOrder = sortOrder
        self.query = query
        self.paneLocationsByWorktreeId = paneLocationsByWorktreeId
        self.unassociatedPaneLocations = unassociatedPaneLocations
        self.bridgePaneCommandCandidatesByWorktreeId = bridgePaneCommandCandidatesByWorktreeId
    }

    func replacing(
        repos: [RepoPresentationItem]? = nil,
        repoEnrichmentByRepoId: [UUID: RepoEnrichment]? = nil,
        surface: SidebarSurface? = nil,
        groupingMode: RepoExplorerGroupingMode? = nil,
        subgroupMode: SidebarSubgroupMode? = nil,
        sortField: SidebarSortField? = nil,
        showsPinned: Bool? = nil,
        showsDrawerPanes: Bool? = nil,
        referenceDate: Date? = nil,
        referenceInstant: ContinuousClock.Instant? = nil,
        calendar: Calendar? = nil,
        sortOrder: RepoExplorerSortOrder? = nil,
        query: String? = nil,
        bridgePaneCommandCandidatesByWorktreeId: [UUID: [BridgePaneCommandCandidate]]? = nil
    ) -> Self {
        Self(
            repos: repos ?? self.repos,
            repoEnrichmentByRepoId: repoEnrichmentByRepoId ?? repoEnrichmentSnapshotByRepoId,
            surface: surface ?? self.surface,
            groupingMode: groupingMode ?? self.groupingMode,
            subgroupMode: subgroupMode ?? self.subgroupMode,
            sortField: sortField ?? self.sortField,
            showsPinned: showsPinned ?? self.showsPinned,
            showsDrawerPanes: showsDrawerPanes ?? self.showsDrawerPanes,
            referenceDate: referenceDate ?? self.referenceDate,
            referenceInstant: referenceInstant ?? self.referenceInstant,
            calendar: calendar ?? self.calendar,
            sortOrder: sortOrder ?? self.sortOrder,
            query: query ?? self.query,
            paneLocationsByWorktreeId: paneLocationsByWorktreeId,
            unassociatedPaneLocations: unassociatedPaneLocations,
            bridgePaneCommandCandidatesByWorktreeId: bridgePaneCommandCandidatesByWorktreeId
                ?? self.bridgePaneCommandCandidatesByWorktreeId
        )
    }
}

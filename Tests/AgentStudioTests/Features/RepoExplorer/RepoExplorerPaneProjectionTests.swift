import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@Suite("RepoExplorer pane projection")
struct RepoExplorerPaneProjectionTests {
    @Test("pane and tab recency colors degrade through policy-owned time tiers")
    func recencyTierUsesPolicyThresholds() {
        let now = Date(timeIntervalSince1970: 100_000)

        #expect(
            RepoExplorerPaneRecencyTier.classify(referenceDate: now.addingTimeInterval(-60), now: now) == .strongBlue)
        #expect(
            RepoExplorerPaneRecencyTier.classify(referenceDate: now.addingTimeInterval(-(10 * 60)), now: now)
                == .mediumBlue
        )
        #expect(
            RepoExplorerPaneRecencyTier.classify(referenceDate: now.addingTimeInterval(-(60 * 60)), now: now)
                == .mutedBlue
        )
        #expect(
            RepoExplorerPaneRecencyTier.classify(referenceDate: now.addingTimeInterval(-(12 * 60 * 60)), now: now)
                == .faintBlue
        )
        #expect(
            RepoExplorerPaneRecencyTier.classify(referenceDate: now.addingTimeInterval(-(24 * 60 * 60)), now: now)
                == .grey
        )
    }

    @Test("pane row keeps a person note but never shows terminal output or a zsh drawer fallback")
    func paneSecondaryLineUsesOnlyPersonNote() {
        let referenceDate = Date(timeIntervalSince1970: 10)
        let notedPane = RepoExplorerPaneRowFacts(
            terminalTitle: "zsh",
            noteText: "Waiting on review",
            latestMessageText: "Tests passed",
            recencyReferenceDate: referenceDate,
            recencyText: "Now",
            isActive: false
        )
        let activePane = RepoExplorerPaneRowFacts(
            terminalTitle: "zsh",
            latestMessageText: "Tests passed",
            recencyReferenceDate: referenceDate,
            recencyText: "Now",
            isActive: false
        )
        let quietPane = RepoExplorerPaneRowFacts(
            terminalTitle: "zsh",
            latestMessageText: nil,
            recencyReferenceDate: referenceDate,
            recencyText: "Now",
            isActive: false
        )

        #expect(notedPane.secondaryLine == .note("Waiting on review"))
        #expect(activePane.secondaryLine == nil)
        #expect(quietPane.secondaryLine == nil)

        let drawerPane = RepoExplorerPaneRowFacts(
            terminalTitle: "Drawer",
            latestMessageText: nil,
            recencyReferenceDate: referenceDate,
            recencyText: "Now",
            isActive: false,
            isDrawerPane: true
        )
        #expect(drawerPane.sidebarTerminalTitle == "Drawer")
    }

    @Test("Panes rows are sorted by the one activity time within an activity bucket")
    func allPanesRowsCarryPresentationFactsInActivityOrder() throws {
        let repoId = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoId, name: "agent-studio.sidebar-grouping")
        let olderPaneId = UUIDv7.generate()
        let newerPaneId = UUIDv7.generate()
        let tabId = UUIDv7.generate()
        let referenceInstant = ContinuousClock.now
        let snapshot = RepoExplorerSnapshot(
            repos: [makeRepo(id: repoId, worktrees: [worktree])],
            repoEnrichmentByRepoId: [repoId: resolvedRemote(repoId: repoId)],
            surface: .panes,
            groupingMode: .repo,
            sortField: .activity,
            referenceDate: Date(timeIntervalSince1970: 30),
            referenceInstant: referenceInstant,
            sortOrder: .descending,
            query: "",
            paneLocationsByWorktreeId: [
                worktree.id: [
                    .init(
                        paneId: olderPaneId,
                        tabId: tabId,
                        tabIndex: 0,
                        paneIndexInTab: 0,
                        isActiveInTab: false
                    ),
                    .init(
                        paneId: newerPaneId,
                        tabId: tabId,
                        tabIndex: 0,
                        paneIndexInTab: 1,
                        isActiveInTab: true
                    ),
                ]
            ]
        )

        let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts(
            [
                olderPaneId: .init(
                    terminalTitle: "old shell",
                    paneActivityTime: PaneActivityTime(
                        orderingInstant: referenceInstant.advanced(by: .seconds(-30)),
                        wallTime: Date(timeIntervalSince1970: 1),
                        source: .terminal
                    ),
                    latestMessageText: "No activity yet",
                    recencyReferenceDate: Date(timeIntervalSince1970: 10),
                    recencyText: "2m",
                    isActive: false
                ),
                newerPaneId: .init(
                    terminalTitle: "tests running",
                    paneActivityTime: PaneActivityTime(
                        orderingInstant: referenceInstant.advanced(by: .seconds(-10)),
                        wallTime: Date(timeIntervalSince1970: 2),
                        source: .hook
                    ),
                    noteText: "Review ready",
                    latestMessageText: "Tests passed",
                    recencyReferenceDate: Date(timeIntervalSince1970: 20),
                    recencyText: "Now",
                    isActive: true,
                    isDrawerPane: true
                ),
            ],
            snapshot: snapshot
        )
        let projection = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: prepared)

        let group = try #require(projection.resolvedGroups.first)
        let rows = try #require(projection.paneRowsByGroupId[group.id])
        #expect(rows.map(\.destination.paneId) == [newerPaneId, olderPaneId])
        #expect(rows[0].primaryText == "tests running")
        #expect(rows[0].secondaryText == "Review ready")
        #expect(rows[0].recencyText == "Now")
        #expect(rows[0].isActive)
        #expect(rows[0].isDrawerPane)
    }

    @Test("activity sorting never falls back to focus recency")
    func activitySortingNeverFallsBackToFocusRecency() throws {
        let repoId = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoId)
        let neverFocusedPaneId = UUIDv7.generate()
        let previouslyFocusedPaneId = UUIDv7.generate()
        let tabId = UUIDv7.generate()
        let referenceInstant = ContinuousClock.now
        let snapshot = RepoExplorerSnapshot(
            repos: [makeRepo(id: repoId, worktrees: [worktree])],
            repoEnrichmentByRepoId: [repoId: resolvedRemote(repoId: repoId)],
            surface: .panes,
            groupingMode: .repo,
            sortField: .activity,
            referenceDate: Date(timeIntervalSince1970: 30),
            referenceInstant: referenceInstant,
            sortOrder: .descending,
            query: "",
            paneLocationsByWorktreeId: [
                worktree.id: [
                    .init(
                        paneId: neverFocusedPaneId,
                        tabId: tabId,
                        tabIndex: 0,
                        paneIndexInTab: 0,
                        isActiveInTab: true
                    ),
                    .init(
                        paneId: previouslyFocusedPaneId,
                        tabId: tabId,
                        tabIndex: 0,
                        paneIndexInTab: 1,
                        isActiveInTab: false
                    ),
                ]
            ]
        )
        let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts(
            [
                neverFocusedPaneId: .init(
                    terminalTitle: "new pane",
                    paneActivityTime: PaneActivityTime(
                        orderingInstant: referenceInstant.advanced(by: .seconds(-20)),
                        wallTime: Date(timeIntervalSince1970: 1),
                        source: .terminal
                    ),
                    latestMessageText: "No activity yet",
                    recencyReferenceDate: Date(timeIntervalSince1970: 20),
                    recencyText: "Now",
                    isActive: true
                ),
                previouslyFocusedPaneId: .init(
                    terminalTitle: "old pane",
                    paneActivityTime: PaneActivityTime(
                        orderingInstant: referenceInstant.advanced(by: .seconds(-10)),
                        wallTime: Date(timeIntervalSince1970: 2),
                        source: .hook
                    ),
                    latestMessageText: "No activity yet",
                    recencyReferenceDate: Date(timeIntervalSince1970: 10),
                    recencyText: "5m",
                    isActive: false
                ),
            ],
            snapshot: snapshot
        )
        let projection = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: prepared)

        let group = try #require(projection.resolvedGroups.first)
        let rows = try #require(projection.paneRowsByGroupId[group.id])
        #expect(rows.map(\.destination.paneId) == [previouslyFocusedPaneId, neverFocusedPaneId])
    }

    @Test("Panes activity grouping retains every tab member without a tab heading")
    func byTabProjectsPaneRowsUnderDisplayTitleHeaders() throws {
        let repoId = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoId)
        let firstTabId = UUIDv7.generate()
        let secondTabId = UUIDv7.generate()
        let firstPaneId = UUIDv7.generate()
        let secondPaneId = UUIDv7.generate()
        let thirdPaneId = UUIDv7.generate()
        let projection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [makeRepo(id: repoId, worktrees: [worktree])],
                repoEnrichmentByRepoId: [repoId: resolvedRemote(repoId: repoId)],
                surface: .panes,
                groupingMode: .tab,
                query: "",
                paneLocationsByWorktreeId: [
                    worktree.id: [
                        .init(
                            paneId: secondPaneId,
                            tabId: secondTabId,
                            tabIndex: 1,
                            paneIndexInTab: 0,
                            isActiveInTab: false
                        ),
                        .init(
                            paneId: firstPaneId,
                            tabId: firstTabId,
                            tabIndex: 0,
                            paneIndexInTab: 0,
                            isActiveInTab: true
                        ),
                        .init(
                            paneId: thirdPaneId,
                            tabId: firstTabId,
                            tabIndex: 0,
                            paneIndexInTab: 1,
                            isActiveInTab: false
                        ),
                    ]
                ]
            ),
            paneRowFactsByPaneId: [
                firstPaneId: .init(
                    terminalTitle: "first terminal",
                    latestMessageText: "First message",
                    recencyReferenceDate: Date(timeIntervalSince1970: 10),
                    recencyText: "Now",
                    isActive: true
                ),
                secondPaneId: .init(
                    terminalTitle: "second terminal",
                    latestMessageText: "Second message",
                    recencyReferenceDate: Date(timeIntervalSince1970: 20),
                    recencyText: "Now",
                    isActive: false
                ),
                thirdPaneId: .init(
                    terminalTitle: "third terminal",
                    latestMessageText: "Third message",
                    recencyReferenceDate: Date(timeIntervalSince1970: 30),
                    recencyText: "Now",
                    isActive: false
                ),
            ],
            tabGroupFactsByTabId: [
                firstTabId: .init(displayTitle: "Implementation"),
                secondTabId: .init(displayTitle: "Tests"),
            ]
        )

        #expect(projection.resolvedGroups.map(\.repoTitle) == ["No activity"])
        #expect(projection.resolvedGroups.map(\.organizationName) == [nil])
        #expect(projection.worktreeRowsByGroupId.isEmpty)
        let activityRows = try #require(projection.paneRowsByGroupId[projection.resolvedGroups[0].id])
        #expect(Set(activityRows.map(\.destination.paneId)) == [firstPaneId, secondPaneId, thirdPaneId])
    }

    @Test("activity membership includes associated and unassociated panes across tabs")
    func byTabIncludesMixedAndAllUnassociatedTabs() throws {
        let fixture = makeMixedAndUnassociatedTabFixture()
        let projection = fixture.projection
        let repoId = fixture.repoId
        let associatedPaneId = fixture.associatedPaneId
        let mixedUnassociatedPaneId = fixture.mixedUnassociatedPaneId
        let unassociatedOnlyPaneId = fixture.unassociatedOnlyPaneId

        #expect(projection.resolvedGroups.map(\.repoTitle) == ["No activity"])
        #expect(projection.resolvedGroups.map(\.organizationName) == [nil])
        let groupID = "panes:panes:activity:6"
        let activityRows = try #require(projection.paneRowsByGroupId[groupID])
        #expect(
            Set(activityRows.map(\.destination.paneId))
                == [associatedPaneId, mixedUnassociatedPaneId, unassociatedOnlyPaneId]
        )

        let rowIndex = RepoExplorerRowIndex(
            projection: projection,
            collapsedGroupIds: [],
            isFiltering: false
        )
        let paneEntries = rowIndex.entries.compactMap { entry -> (String, UUID)? in
            guard case .resolvedPaneRow(let groupId, let identity, _) = entry else { return nil }
            return (groupId, identity.paneId)
        }
        #expect(Set(paneEntries.map(\.1)) == [associatedPaneId, mixedUnassociatedPaneId, unassociatedOnlyPaneId])
        let resolvedRows = rowIndex.entries.compactMap { entry -> RepoExplorerResolvedPaneContext? in
            guard case .resolvedPaneRow(let groupId, let identity, let rowId) = entry else { return nil }
            guard case .tabPane(let rowGroupId, let paneId) = rowId else {
                Issue.record("Panes rows require tab-owned identity")
                return nil
            }
            #expect(rowGroupId == groupId)
            #expect(paneId == identity.paneId)
            return rowIndex.resolvePane(
                groupId: groupId,
                repoId: identity.repoId,
                paneId: identity.paneId,
                rowId: rowId
            )
        }
        #expect(Set(resolvedRows.map(\.destination.paneId)) == Set(paneEntries.map(\.1)))
        #expect(resolvedRows.first { $0.destination.paneId == associatedPaneId }?.row.repoId == repoId)
        #expect(resolvedRows.first { $0.destination.paneId == mixedUnassociatedPaneId }?.row.repoId == nil)
        #expect(resolvedRows.first { $0.destination.paneId == unassociatedOnlyPaneId }?.row.repoId == nil)

        let collapsed = RepoExplorerRowIndex(
            projection: projection,
            collapsedGroupIds: [groupID],
            isFiltering: false
        )
        #expect(
            !collapsed.entries.contains { entry in
                guard case .resolvedPaneRow(let groupId, _, _) = entry else { return false }
                return groupId == groupID
            }
        )
    }

    @Test("repository association changes enrichment without changing activity membership identity")
    func byTabAssociationTransitionPreservesMembershipIdentity() throws {
        let repoId = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoId)
        let tabId = UUIDv7.generate()
        let paneId = UUIDv7.generate()
        let location = WorkspacePaneLocation(
            paneId: paneId,
            tabId: tabId,
            tabIndex: 0,
            paneIndexInTab: 0,
            isActiveInTab: true
        )
        let repository = makeRepo(id: repoId, worktrees: [worktree])
        let associated = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [repository],
                repoEnrichmentByRepoId: [repoId: resolvedRemote(repoId: repoId)],
                surface: .panes,
                groupingMode: .tab,
                query: "",
                paneLocationsByWorktreeId: [worktree.id: [location]]
            ),
            branchNameByWorktreeId: [worktree.id: "main"],
            branchStatusByWorktreeId: [worktree.id: .unknown]
        )
        let unassociated = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [repository],
                repoEnrichmentByRepoId: [repoId: resolvedRemote(repoId: repoId)],
                surface: .panes,
                groupingMode: .tab,
                query: "",
                unassociatedPaneLocations: [location]
            )
        )

        #expect(associated.resolvedGroups.map(\.id) == unassociated.resolvedGroups.map(\.id))
        #expect(associated.resolvedGroups.map(\.organizationName) == [nil])
        #expect(unassociated.resolvedGroups.map(\.organizationName) == [nil])
        let associatedIndex = RepoExplorerRowIndex(
            projection: associated,
            collapsedGroupIds: [],
            isFiltering: false
        )
        let unassociatedIndex = RepoExplorerRowIndex(
            projection: unassociated,
            collapsedGroupIds: [],
            isFiltering: false
        )
        let associatedRowID = try #require(
            associatedIndex.entries.compactMap { entry -> RepoExplorerRowID? in
                guard case .resolvedPaneRow(_, _, let rowID) = entry else { return nil }
                return rowID
            }.first
        )
        let unassociatedRowID = try #require(
            unassociatedIndex.entries.compactMap { entry -> RepoExplorerRowID? in
                guard case .resolvedPaneRow(_, _, let rowID) = entry else { return nil }
                return rowID
            }.first
        )
        #expect(associatedRowID == unassociatedRowID)
        let expectedGroupID = "panes:panes:activity:6"
        #expect(associatedRowID == .tabPane(groupID: expectedGroupID, paneID: paneId))
        let associatedRow = try #require(associated.paneRowsByGroupId[expectedGroupID]?.first)
        let unassociatedRow = try #require(unassociated.paneRowsByGroupId[expectedGroupID]?.first)
        #expect(associatedRow.repoId == repoId)
        #expect(associatedRow.worktreeId == worktree.id)
        #expect(associatedRow.branchContextText == "agent-studio · main")
        #expect(unassociatedRow.repoId == nil)
        #expect(unassociatedRow.worktreeId == nil)
        #expect(unassociatedRow.branchContextText == nil)
        #expect(unassociatedRow.branchStatus == nil)
    }

    @Test("empty states distinguish no repositories, no panes, and no tabs")
    func emptyStatesMatchGroupingMode() {
        let emptyRepoProjection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(repos: [], repoEnrichmentByRepoId: [:], groupingMode: .repo, query: "")
        )
        let repoId = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoId)
        let repo = makeRepo(id: repoId, worktrees: [worktree])
        let enrichment = [repoId: resolvedRemote(repoId: repoId)]
        let emptyPaneProjection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [repo],
                repoEnrichmentByRepoId: enrichment,
                surface: .panes,
                groupingMode: .repo,
                query: ""
            )
        )
        let emptyTabProjection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [repo],
                repoEnrichmentByRepoId: enrichment,
                surface: .panes,
                groupingMode: .tab,
                query: ""
            )
        )

        #expect(emptyRepoProjection.emptyState == .noRepositories)
        #expect(emptyPaneProjection.emptyState == .noPanes)
        #expect(emptyTabProjection.emptyState == .noPanes)
    }

    @Test("recency text changes only at minute boundaries")
    func recencyTextUsesCoarseMinuteBuckets() {
        let lastInteraction = Date(timeIntervalSince1970: 100)
        #expect(
            RepoExplorerPaneRecencyText.display(
                lastInteractedAt: lastInteraction,
                now: Date(timeIntervalSince1970: 161)
            ) == "1m"
        )
        #expect(
            RepoExplorerPaneRecencyText.display(
                lastInteractedAt: lastInteraction,
                now: Date(timeIntervalSince1970: 199)
            ) == "1m"
        )
    }

    @Test("pane grouping keeps validated associations in worktree buckets and isolates unassociated panes")
    func paneGroupingSeparatesAssociatedAndUnassociatedPanes() throws {
        let repoId = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoId)
        let associatedPaneId = UUIDv7.generate()
        let nilAssociationPaneId = UUIDv7.generate()
        let danglingAssociationPaneId = UUIDv7.generate()
        let tabId = UUIDv7.generate()
        let projection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [makeRepo(id: repoId, worktrees: [worktree])],
                repoEnrichmentByRepoId: [repoId: resolvedRemote(repoId: repoId)],
                surface: .panes,
                groupingMode: .repo,
                query: "",
                paneLocationsByWorktreeId: [
                    worktree.id: [
                        WorkspacePaneLocation(
                            paneId: associatedPaneId,
                            tabId: tabId,
                            tabIndex: 0,
                            paneIndexInTab: 0,
                            isActiveInTab: true
                        )
                    ]
                ],
                unassociatedPaneLocations: [
                    WorkspacePaneLocation(
                        paneId: nilAssociationPaneId,
                        tabId: tabId,
                        tabIndex: 0,
                        paneIndexInTab: 1,
                        isActiveInTab: false
                    ),
                    WorkspacePaneLocation(
                        paneId: danglingAssociationPaneId,
                        tabId: tabId,
                        tabIndex: 0,
                        paneIndexInTab: 2,
                        isActiveInTab: false
                    ),
                ]
            )
        )

        #expect(projection.paneDestinationsByWorktreeId[worktree.id]?.map(\.paneId) == [associatedPaneId])
        #expect(projection.sections.map(\.kind) == [.panes])
        let unassociatedGroupID = "panes:panes:activity:6"
        let unassociatedGroup = try #require(
            projection.resolvedGroups.first { $0.id == unassociatedGroupID }
        )
        #expect(unassociatedGroup.repoTitle == "No activity")
        #expect(
            Set(projection.paneRowsByGroupId[unassociatedGroupID, default: []].map { $0.destination.paneId })
                == [associatedPaneId, nilAssociationPaneId, danglingAssociationPaneId]
        )

        let rowIndex = RepoExplorerRowIndex(
            projection: projection,
            collapsedGroupIds: [],
            isFiltering: false
        )
        #expect(
            Set(
                rowIndex.entries.compactMap { entry -> UUID? in
                    guard case .resolvedPaneRow(_, let identity, _) = entry else { return nil }
                    return identity.repoId == nil ? identity.paneId : nil
                }) == [nilAssociationPaneId, danglingAssociationPaneId]
        )
    }

    @Test("Ungrouped pane labels render without a worktree fallback")
    func ungroupedPaneLabelOmitsWorktreeFallback() {
        let destination = RepoExplorerUnassociatedPaneDestination(
            paneId: UUIDv7.generate(),
            tabId: UUIDv7.generate(),
            tabIndex: 1,
            paneIndexInTab: 2,
            isActiveInTab: true
        )

        #expect(destination.label(paneDisplayLabel: "Terminal") == "Terminal — Tab 2, Pane 3 — Active")
    }

    @Test("pane destinations sort by tab pane and stable pane identity")
    func paneDestinationsUseCanonicalLocationOrder() throws {
        let repoId = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoId)
        let firstTiePaneId = try #require(UUID(uuidString: "00000000-0000-7000-8000-000000000001"))
        let secondTiePaneId = try #require(UUID(uuidString: "00000000-0000-7000-8000-000000000002"))
        let earlierTabPaneId = try #require(UUID(uuidString: "00000000-0000-7000-8000-000000000003"))
        let projection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [makeRepo(id: repoId, worktrees: [worktree])],
                repoEnrichmentByRepoId: [repoId: resolvedRemote(repoId: repoId)],
                surface: .panes,
                groupingMode: .repo,
                query: "",
                paneLocationsByWorktreeId: [
                    worktree.id: [
                        WorkspacePaneLocation(
                            paneId: secondTiePaneId,
                            tabId: UUIDv7.generate(),
                            tabIndex: 1,
                            paneIndexInTab: 0,
                            isActiveInTab: false
                        ),
                        WorkspacePaneLocation(
                            paneId: earlierTabPaneId,
                            tabId: UUIDv7.generate(),
                            tabIndex: 0,
                            paneIndexInTab: 4,
                            isActiveInTab: true
                        ),
                        WorkspacePaneLocation(
                            paneId: firstTiePaneId,
                            tabId: UUIDv7.generate(),
                            tabIndex: 1,
                            paneIndexInTab: 0,
                            isActiveInTab: false
                        ),
                    ]
                ]
            )
        )

        #expect(
            projection.paneDestinationsByWorktreeId[worktree.id]?.map(\.paneId)
                == [earlierTabPaneId, firstTiePaneId, secondTiePaneId]
        )
    }

    @Test("search filters visible leaves without filtering repository pane destinations")
    func searchDoesNotFilterRepositoryPaneDestinations() throws {
        let repoId = UUIDv7.generate()
        let matchingWorktree = makeWorktree(repoId: repoId, name: "matching")
        let hiddenWorktree = makeWorktree(repoId: repoId, name: "hidden")
        let matchingPaneId = UUIDv7.generate()
        let hiddenPaneId = UUIDv7.generate()
        let projection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [makeRepo(id: repoId, worktrees: [matchingWorktree, hiddenWorktree])],
                repoEnrichmentByRepoId: [repoId: resolvedRemote(repoId: repoId)],
                groupingMode: .repo,
                query: "matching",
                paneLocationsByWorktreeId: [
                    matchingWorktree.id: [
                        WorkspacePaneLocation(
                            paneId: matchingPaneId,
                            tabId: UUIDv7.generate(),
                            tabIndex: 0,
                            paneIndexInTab: 0,
                            isActiveInTab: true
                        )
                    ],
                    hiddenWorktree.id: [
                        WorkspacePaneLocation(
                            paneId: hiddenPaneId,
                            tabId: UUIDv7.generate(),
                            tabIndex: 1,
                            paneIndexInTab: 0,
                            isActiveInTab: true
                        )
                    ],
                ]
            )
        )

        let group = try #require(projection.resolvedGroups.first)
        #expect(group.repos.flatMap(\.worktrees).map(\.id) == [matchingWorktree.id])
        #expect(
            projection.paneDestinationsByRepoId[repoId]?.map(\.paneId)
                == [matchingPaneId, hiddenPaneId]
        )
    }

    @Test("pane search filters activity rows by their projected location label")
    func paneSearchFiltersNoRepositoryRows() throws {
        let paneId = UUIDv7.generate()
        let baseSnapshot = RepoExplorerSnapshot(
            repos: [],
            repoEnrichmentByRepoId: [:],
            surface: .panes,
            groupingMode: .repo,
            query: "not-present",
            unassociatedPaneLocations: [
                WorkspacePaneLocation(
                    paneId: paneId,
                    tabId: UUIDv7.generate(),
                    tabIndex: 0,
                    paneIndexInTab: 1,
                    isActiveInTab: true
                )
            ]
        )

        let noMatch = RepoExplorerProjection.project(baseSnapshot)
        #expect(noMatch.sections.isEmpty)
        #expect(noMatch.emptyState == .searchNoResults)

        let matching = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [],
                repoEnrichmentByRepoId: [:],
                surface: .panes,
                groupingMode: .repo,
                query: "pane 2",
                unassociatedPaneLocations: baseSnapshot.unassociatedPaneLocations
            )
        )
        #expect(matching.sections.map(\.kind) == [.panes])
        let groupID = "panes:panes:activity:6"
        #expect(matching.resolvedGroups.map(\.id) == [groupID])
        #expect(matching.paneRowsByGroupId[groupID]?.map { $0.destination.paneId } == [paneId])
    }

    func makeRepo(id: UUID, worktrees: [Worktree]) -> RepoPresentationItem {
        RepoPresentationItem(
            id: id,
            name: "agent-studio",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
            stableKey: "agent-studio",
            worktrees: worktrees
        )
    }

    private func makeMixedAndUnassociatedTabFixture() -> ByTabMembershipFixture {
        let repoId = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoId)
        let mixedTabId = UUIDv7.generate()
        let unassociatedTabId = UUIDv7.generate()
        let associatedPaneId = UUIDv7.generate()
        let mixedUnassociatedPaneId = UUIDv7.generate()
        let unassociatedOnlyPaneId = UUIDv7.generate()
        let projection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [makeRepo(id: repoId, worktrees: [worktree])],
                repoEnrichmentByRepoId: [repoId: resolvedRemote(repoId: repoId)],
                surface: .panes,
                groupingMode: .tab,
                query: "",
                paneLocationsByWorktreeId: [
                    worktree.id: [
                        WorkspacePaneLocation(
                            paneId: associatedPaneId,
                            tabId: mixedTabId,
                            tabIndex: 0,
                            paneIndexInTab: 0,
                            isActiveInTab: true
                        )
                    ]
                ],
                unassociatedPaneLocations: [
                    WorkspacePaneLocation(
                        paneId: mixedUnassociatedPaneId,
                        tabId: mixedTabId,
                        tabIndex: 0,
                        paneIndexInTab: 1,
                        isActiveInTab: false
                    ),
                    WorkspacePaneLocation(
                        paneId: unassociatedOnlyPaneId,
                        tabId: unassociatedTabId,
                        tabIndex: 1,
                        paneIndexInTab: 0,
                        isActiveInTab: true
                    ),
                ]
            ),
            paneRowFactsByPaneId: [
                associatedPaneId: paneFacts(
                    title: "associated", activity: "Associated activity", time: 30, isActive: true),
                mixedUnassociatedPaneId: paneFacts(
                    title: "mixed unassociated", activity: "Mixed activity", time: 20, recency: "1m"),
                unassociatedOnlyPaneId: paneFacts(
                    title: "unassociated only", activity: "Unassociated activity", time: 10, recency: "2m",
                    isActive: true),
            ],
            tabGroupFactsByTabId: [
                mixedTabId: .init(displayTitle: "Mixed"),
                unassociatedTabId: .init(displayTitle: "Unassociated"),
            ]
        )
        return ByTabMembershipFixture(
            projection: projection,
            repoId: repoId,
            mixedTabId: mixedTabId,
            unassociatedTabId: unassociatedTabId,
            associatedPaneId: associatedPaneId,
            mixedUnassociatedPaneId: mixedUnassociatedPaneId,
            unassociatedOnlyPaneId: unassociatedOnlyPaneId
        )
    }

    private func paneFacts(
        title: String,
        activity: String,
        time: TimeInterval,
        recency: String = "Now",
        isActive: Bool = false
    ) -> RepoExplorerPaneRowFacts {
        RepoExplorerPaneRowFacts(
            terminalTitle: title,
            latestMessageText: activity,
            recencyReferenceDate: Date(timeIntervalSince1970: time),
            recencyText: recency,
            isActive: isActive
        )
    }

    func makeWorktree(repoId: UUID, name: String = "main") -> Worktree {
        Worktree(repoId: repoId, name: name, path: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func resolvedRemote(repoId: UUID) -> RepoEnrichment {
        .resolvedRemote(
            repoId: repoId,
            raw: RawRepoOrigin(origin: "git@github.com:askluna/agent-studio.git", upstream: nil),
            identity: RepoIdentity(
                groupKey: "remote:askluna/agent-studio",
                remoteSlug: "askluna/agent-studio",
                organizationName: "askluna",
                displayName: "agent-studio"
            ),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private struct ByTabMembershipFixture {
    let projection: RepoExplorerSidebarProjection
    let repoId: UUID
    let mixedTabId: UUID
    let unassociatedTabId: UUID
    let associatedPaneId: UUID
    let mixedUnassociatedPaneId: UUID
    let unassociatedOnlyPaneId: UUID
}

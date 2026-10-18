import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

private let organizationReferenceDate = Date(timeIntervalSince1970: 1_788_804_000)
private let organizationReferenceInstant = ContinuousClock.now

extension RepoExplorerReadModelTests {
    @MainActor
    @Test("drawer visibility forwards to the sidebar memory owner")
    func drawerVisibilityForwardsToSidebarMemory() {
        let sidebarState = WorkspaceSidebarState()
        let preferences = RepoExplorerSidebarPrefsAtom(sidebarState: sidebarState)
        #expect(preferences.showsDrawerPanes)

        preferences.setShowsDrawerPanes(false)

        #expect(!preferences.showsDrawerPanes)
        #expect(!sidebarState.showsDrawerPanes)
    }

    @MainActor
    @Test("fixed Panes policy keeps both Active sections in tab order")
    func fixedPanesPolicyKeepsHotSectionsInTabOrder() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let repoID = UUIDv7.generate()
        let checkout = worktree(repoId: repoID)
        let repository = repo(id: repoID, name: "repository", worktrees: [checkout])
        let tabID = UUIDv7.generate()
        let olderPinned = UUIDv7.generate()
        let newerPinned = UUIDv7.generate()
        let olderOrdinary = UUIDv7.generate()
        let newerOrdinary = UUIDv7.generate()
        let paneIDs = [olderPinned, newerPinned, olderOrdinary, newerOrdinary]
        let preferences = RepoExplorerSidebarPrefsAtom()
        preferences.setGroupingMode(.tab, for: .panes)
        preferences.setSortField(.name, for: .panes)
        preferences.setSortDirection(.ascending, for: .panes)
        let projection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [repository],
                repoEnrichmentByRepoId: [repoID: resolvedRemote(repoId: repoID, displayName: repository.name)],
                surface: .panes,
                groupingMode: preferences.groupingMode(for: .panes),
                subgroupMode: preferences.subgroupMode(for: .panes),
                sortField: preferences.sortField(for: .panes),
                showsPinned: true,
                referenceDate: now,
                referenceInstant: organizationReferenceInstant,
                calendar: organizationCalendar,
                sortOrder: preferences.sortDirection(for: .panes),
                query: "",
                paneLocationsByWorktreeId: [
                    checkout.id: paneIDs.enumerated().map {
                        paneLocation(paneID: $0.element, tabID: tabID, paneIndex: $0.offset)
                    }
                ]
            ),
            paneRowFactsByPaneId: [
                olderPinned: paneFacts(title: "Z pinned", activityAt: now.addingTimeInterval(-40), isPinned: true),
                newerPinned: paneFacts(title: "A pinned", activityAt: now.addingTimeInterval(-10), isPinned: true),
                olderOrdinary: paneFacts(title: "Z ordinary", activityAt: now.addingTimeInterval(-40)),
                newerOrdinary: paneFacts(title: "A ordinary", activityAt: now.addingTimeInterval(-10)),
            ]
        )

        #expect(projection.sections.map(\.kind) == [.pinnedPanes, .panes])
        let pinnedSection = try #require(projection.sections.first)
        let ordinarySection = try #require(projection.sections.last)
        #expect(self.paneIDs(in: pinnedSection, projection: projection) == [olderPinned, newerPinned])
        #expect(self.paneIDs(in: ordinarySection, projection: projection) == [olderOrdinary, newerOrdinary])
    }

    @Test("Repos activity sections keep checkouts together and pinned repos exclusive")
    func reposActivitySectionsKeepRepositoriesTogether() {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let activeID = UUIDv7.generate()
        let pinnedID = UUIDv7.generate()
        let quietID = UUIDv7.generate()
        let activeCheckout = worktree(repoId: activeID, name: "active-checkout")
        let quietCheckout = worktree(repoId: activeID, name: "quiet-checkout")
        let pinnedCheckout = worktree(repoId: pinnedID)
        let repositories = [
            repo(id: activeID, name: "active-repo", worktrees: [activeCheckout, quietCheckout]),
            repo(id: pinnedID, name: "pinned-repo", isPinned: true, worktrees: [pinnedCheckout]),
            repo(id: quietID, name: "quiet-repo", worktrees: [worktree(repoId: quietID)]),
        ]
        let paneID = UUIDv7.generate()
        let snapshot = RepoExplorerSnapshot(
            repos: repositories,
            repoEnrichmentByRepoId: Dictionary(
                uniqueKeysWithValues: repositories.map {
                    ($0.id, resolvedRemote(repoId: $0.id, displayName: $0.name))
                }),
            surface: .repos, groupingMode: .activity, showsPinned: true,
            referenceDate: now, calendar: organizationCalendar, query: "",
            paneLocationsByWorktreeId: [activeCheckout.id: [paneLocation(paneID: paneID, tabID: UUIDv7.generate())]]
        )
        let facts = [paneID: paneFacts(title: "output", activityAt: now.addingTimeInterval(-30))]
        let projection = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: facts)
        #expect(projection.sections.map(\.kind) == [.pinnedRepositories, .activeRepos, .noActivityRepos])
        #expect(projection.sections[0].resolvedGroups.flatMap(\.repos).map(\.id) == [pinnedID])
        #expect(projection.sections[1].resolvedGroups.flatMap(\.repos).flatMap(\.worktrees).count == 2)
        let index = RepoExplorerRowIndex(projection: projection, collapsedGroupIds: [], isFiltering: false)
        #expect(
            index.entries.allSatisfy {
                if case .activitySubgroup = $0 { return false }
                return true
            })
        let filtered = RepoExplorerProjection.project(
            snapshot.replacing(query: "quiet-checkout"), paneRowFactsByPaneId: facts
        )
        #expect(filtered.sections.map(\.kind) == [.activeRepos])
        let merged = RepoExplorerProjection.project(snapshot.replacing(showsPinned: false), paneRowFactsByPaneId: facts)
        #expect(merged.sections.map(\.kind) == [.activeRepos, .noActivityRepos])
        #expect(merged.sections.flatMap(\.resolvedGroups).flatMap(\.repos).count == 3)
        let repoMode = RepoExplorerProjection.project(
            snapshot.replacing(groupingMode: .repo), paneRowFactsByPaneId: facts)
        #expect(repoMode.sections.map(\.title) == ["Pinned repos", "Open repos", "Available repos"])
    }

    @Test("whitespace-only query preserves collapsed groups through the worker")
    func whitespaceQueryPreservesCollapsedGroups() throws {
        let repoID = UUIDv7.generate()
        let repository = repo(id: repoID, name: "alpha", worktrees: [worktree(repoId: repoID)])
        let groupID = "repos:repositories:remote:askluna/alpha"
        let result = try RepoExplorerProjectionWorker.project(
            RepoExplorerProjectionRequest(
                generation: 1,
                snapshot: RepoExplorerSnapshot(
                    repos: [repository],
                    repoEnrichmentByRepoId: [repoID: resolvedRemote(repoId: repoID, displayName: "alpha")],
                    query: "  "
                ),
                collapsedGroupIds: [groupID], isFiltering: true, trigger: .search
            ))
        #expect(!result.rowIndex.isFiltering)
        #expect(result.rowIndex.entries.map(\.id) == [.sectionHeader(.repositories), .group(groupID: groupID)])
    }

    @Test("Panes membership does not depend on repository enrichment", arguments: RepoExplorerGroupingMode.allCases)
    func paneMembershipSurvivesPendingRepositoryEnrichment(groupingMode: RepoExplorerGroupingMode) {
        let repoID = UUIDv7.generate()
        let paneID = UUIDv7.generate()
        let tabID = UUIDv7.generate()
        let checkout = worktree(repoId: repoID)
        let repository = repo(id: repoID, name: "loading", worktrees: [checkout])
        let projection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [repository], repoEnrichmentByRepoId: [repoID: .awaitingOrigin(repoId: repoID)],
                surface: .panes, groupingMode: groupingMode, query: "",
                paneLocationsByWorktreeId: [checkout.id: [paneLocation(paneID: paneID, tabID: tabID)]]
            ),
            paneRowFactsByPaneId: [paneID: paneFacts(title: "Build")]
        )
        #expect(projection.paneRowsByGroupId.values.flatMap { $0 }.map { $0.destination.paneId } == [paneID])
        #expect(projection.loadingRepos.isEmpty)
    }

    private var organizationCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("Repos and Panes partition independent pins and merge them without data loss")
    func surfacesPartitionIndependentPinsAndMergeWithoutDataLoss() throws {
        let pinnedRepoID = UUIDv7.generate()
        let ordinaryRepoID = UUIDv7.generate()
        let closedRepoID = UUIDv7.generate()
        let pinnedWorktree = worktree(repoId: pinnedRepoID, name: "pinned-worktree")
        let ordinaryWorktree = worktree(repoId: ordinaryRepoID, name: "ordinary-worktree")
        let closedWorktree = worktree(repoId: closedRepoID, name: "closed-worktree")
        let pinnedPaneID = UUIDv7.generate()
        let ordinaryPaneID = UUIDv7.generate()
        let tabID = UUIDv7.generate()
        let repositories = [
            repo(id: pinnedRepoID, name: "pinned-repository", isPinned: true, worktrees: [pinnedWorktree]),
            repo(id: ordinaryRepoID, name: "ordinary-repository", worktrees: [ordinaryWorktree]),
            repo(id: closedRepoID, name: "closed-repository", worktrees: [closedWorktree]),
        ]
        let enrichment = Dictionary(
            uniqueKeysWithValues: repositories.map {
                ($0.id, resolvedRemote(repoId: $0.id, displayName: $0.name))
            }
        )
        let locations = [
            pinnedWorktree.id: [paneLocation(paneID: ordinaryPaneID, tabID: tabID, paneIndex: 0)],
            ordinaryWorktree.id: [paneLocation(paneID: pinnedPaneID, tabID: tabID, paneIndex: 1)],
        ]
        let paneFacts = [
            pinnedPaneID: paneFacts(title: "Pinned Pane", isPinned: true),
            ordinaryPaneID: paneFacts(title: "Ordinary Pane"),
        ]

        let reposWithPins = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: repositories,
                repoEnrichmentByRepoId: enrichment,
                surface: .repos,
                showsPinned: true,
                query: "",
                paneLocationsByWorktreeId: locations
            ),
            paneRowFactsByPaneId: paneFacts
        )
        let panesWithPins = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: repositories,
                repoEnrichmentByRepoId: enrichment,
                surface: .panes,
                groupingMode: .repo,
                showsPinned: true,
                query: "",
                paneLocationsByWorktreeId: locations
            ),
            paneRowFactsByPaneId: paneFacts
        )

        #expect(
            reposWithPins.sections.map(\.kind)
                == [.pinnedRepositories, .openRepositories, .repositories]
        )
        #expect(reposWithPins.sections[0].resolvedGroups.flatMap(\.repos).map(\.id) == [pinnedRepoID])
        #expect(reposWithPins.sections[1].resolvedGroups.flatMap(\.repos).map(\.id) == [ordinaryRepoID])
        #expect(reposWithPins.sections[2].resolvedGroups.flatMap(\.repos).map(\.id) == [closedRepoID])
        #expect(panesWithPins.sections.map(\.kind) == [.pinnedPanes, .panes])
        #expect(paneIDs(in: panesWithPins.sections[0], projection: panesWithPins) == [pinnedPaneID])
        #expect(paneIDs(in: panesWithPins.sections[1], projection: panesWithPins) == [ordinaryPaneID])

        let reposMerged = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: repositories,
                repoEnrichmentByRepoId: enrichment,
                surface: .repos,
                showsPinned: false,
                query: "",
                paneLocationsByWorktreeId: locations
            ),
            paneRowFactsByPaneId: paneFacts
        )
        let panesMerged = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: repositories,
                repoEnrichmentByRepoId: enrichment,
                surface: .panes,
                groupingMode: .repo,
                showsPinned: false,
                query: "",
                paneLocationsByWorktreeId: locations
            ),
            paneRowFactsByPaneId: paneFacts
        )

        #expect(reposMerged.sections.map(\.kind) == [.openRepositories, .repositories])
        #expect(
            Set(reposMerged.sections.flatMap(\.resolvedGroups).flatMap(\.repos).map(\.id))
                == Set(repositories.map(\.id))
        )
        #expect(panesMerged.sections.map(\.kind) == [.panes])
        #expect(Set(paneIDs(in: panesMerged.sections[0], projection: panesMerged)) == [pinnedPaneID, ordinaryPaneID])
    }

    @Test("legacy grouping inputs leave fixed Activity and canonical tab ownership intact")
    func legacyGroupingInputsPreserveFixedActivityAndTabOwnership() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let repoID = UUIDv7.generate()
        let worktree = worktree(repoId: repoID, name: "main")
        let repoPaneID = UUIDv7.generate()
        let unassociatedPaneID = UUIDv7.generate()
        let laterTabID = UUIDv7.generate()
        let earlierTabID = UUIDv7.generate()
        let repository = repo(id: repoID, name: "repository", worktrees: [worktree])
        let snapshots = RepoExplorerGroupingMode.allCases.map { groupingMode in
            RepoExplorerSnapshot(
                repos: [repository],
                repoEnrichmentByRepoId: [repoID: resolvedRemote(repoId: repoID, displayName: repository.name)],
                surface: .panes,
                groupingMode: groupingMode,
                referenceDate: now,
                referenceInstant: organizationReferenceInstant,
                calendar: organizationCalendar,
                query: "",
                paneLocationsByWorktreeId: [
                    worktree.id: [paneLocation(paneID: repoPaneID, tabID: laterTabID, tabIndex: 1)]
                ],
                unassociatedPaneLocations: [
                    paneLocation(paneID: unassociatedPaneID, tabID: earlierTabID, tabIndex: 0)
                ]
            )
        }
        let facts = [
            repoPaneID: paneFacts(title: "Repository Pane", activityAt: now.addingTimeInterval(-30)),
            unassociatedPaneID: paneFacts(title: "Loose Pane"),
        ]

        let projections = snapshots.map {
            RepoExplorerProjection.project($0, paneRowFactsByPaneId: facts)
        }
        for projection in projections {
            let rows = projection.paneRowsByGroupId.values.flatMap { $0 }
            #expect(Set(rows.map { $0.destination.paneId }) == [repoPaneID, unassociatedPaneID])
            #expect(rows.allSatisfy { $0.membershipOwner == .tab })
        }

        for projection in projections {
            #expect(projection.resolvedGroups.map(\.repoTitle) == ["Active", "No activity"])
            #expect(projection.sections.map(\.kind) == [.panes])
        }
    }

    @Test("fixed Activity emits bucket headers without nested subgroup rows")
    func fixedActivityUsesBucketHeadersWithoutSubgroups() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let repoID = UUIDv7.generate()
        let worktree = worktree(repoId: repoID, name: "main")
        let activePaneID = UUIDv7.generate()
        let quietPaneID = UUIDv7.generate()
        let tabID = UUIDv7.generate()
        let repository = repo(id: repoID, name: "repository", worktrees: [worktree])
        let base = RepoExplorerSnapshot(
            repos: [repository],
            repoEnrichmentByRepoId: [repoID: resolvedRemote(repoId: repoID, displayName: repository.name)],
            surface: .panes,
            groupingMode: .repo,
            subgroupMode: .activity,
            referenceDate: now,
            referenceInstant: organizationReferenceInstant,
            calendar: organizationCalendar,
            query: "",
            paneLocationsByWorktreeId: [
                worktree.id: [
                    paneLocation(paneID: activePaneID, tabID: tabID, paneIndex: 0),
                    paneLocation(paneID: quietPaneID, tabID: tabID, paneIndex: 1),
                ]
            ]
        )
        let facts = [
            activePaneID: paneFacts(title: "Active", activityAt: now.addingTimeInterval(-30)),
            quietPaneID: paneFacts(title: "Quiet"),
        ]

        let projection = RepoExplorerProjection.project(base, paneRowFactsByPaneId: facts)
        #expect(projection.resolvedGroups.map(\.repoTitle) == ["Active", "No activity"])
        let rowIndex = RepoExplorerRowIndex(
            projection: projection,
            collapsedGroupIds: [],
            isFiltering: false
        )
        #expect(
            rowIndex.entries.allSatisfy { entry in
                if case .activitySubgroup = entry { return false }
                return true
            }
        )
        let materialization = RepoExplorerMaterializationSnapshot.build(
            rowIndex: rowIndex,
            inputs: RepoExplorerMaterializationInputs(
                snapshot: base, projection: projection,
                branchStatusByWorktreeID: [:], branchNameByWorktreeID: [:],
                bridgeCommandResolutionByWorktreeID: [:], paneRowFactsByPaneID: facts
            )
        )
        for row in materialization.rows where row.layout.rowClass == .pane {
            #expect(row.layout.metrics.primaryLineHeight >= AppStyles.General.Button.compact)
        }
    }

    @Test("legacy sort inputs leave fixed Activity bucket and leaf order unchanged")
    func sortInputsDoNotReorderFixedActivity() {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let repoID = UUIDv7.generate()
        let worktree = worktree(repoId: repoID, name: "main")
        let olderPaneID = UUIDv7.generate()
        let newerPaneID = UUIDv7.generate()
        let unknownPaneID = UUIDv7.generate()
        let tabID = UUIDv7.generate()
        let repository = repo(id: repoID, name: "repository", worktrees: [worktree])
        let base = RepoExplorerSnapshot(
            repos: [repository],
            repoEnrichmentByRepoId: [repoID: resolvedRemote(repoId: repoID, displayName: repository.name)],
            surface: .panes,
            groupingMode: .tab,
            referenceDate: now,
            referenceInstant: organizationReferenceInstant,
            calendar: organizationCalendar,
            query: "",
            paneLocationsByWorktreeId: [
                worktree.id: [
                    paneLocation(paneID: newerPaneID, tabID: tabID, paneIndex: 0),
                    paneLocation(paneID: unknownPaneID, tabID: tabID, paneIndex: 1),
                    paneLocation(paneID: olderPaneID, tabID: tabID, paneIndex: 2),
                ]
            ]
        )
        let facts = [
            olderPaneID: paneFacts(title: "Alpha", activityAt: now.addingTimeInterval(-3000)),
            newerPaneID: paneFacts(title: "Beta", activityAt: now.addingTimeInterval(-300)),
            unknownPaneID: paneFacts(title: "Gamma"),
        ]
        let cases: [(SidebarSortField, RepoExplorerSortOrder)] = [
            (.name, .ascending),
            (.name, .descending),
            (.activity, .ascending),
            (.activity, .descending),
        ]

        for (sortField, sortOrder) in cases {
            let projection = RepoExplorerProjection.project(
                base.replacing(sortField: sortField, sortOrder: sortOrder),
                paneRowFactsByPaneId: facts
            )
            #expect(projection.resolvedGroups.map(\.repoTitle) == ["Just Now", "Last hour", "No activity"])
            let paneIDs = projection.resolvedGroups.flatMap { group in
                projection.paneRowsByGroupId[group.id, default: []].map(\.destination.paneId)
            }
            #expect(paneIDs == [newerPaneID, olderPaneID, unknownPaneID])
        }
    }

    @Test("Repos worktree activity uses the newest eligible pane timestamp without focus fallback")
    func reposWorktreeActivityUsesNewestEligiblePaneTimestamp() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let repoID = UUIDv7.generate()
        let worktree = worktree(repoId: repoID, name: "main")
        let olderPaneID = UUIDv7.generate()
        let activePaneID = UUIDv7.generate()
        let tabID = UUIDv7.generate()
        let repository = repo(id: repoID, name: "repository", worktrees: [worktree])
        let projection = RepoExplorerProjection.project(
            RepoExplorerSnapshot(
                repos: [repository],
                repoEnrichmentByRepoId: [repoID: resolvedRemote(repoId: repoID, displayName: repository.name)],
                surface: .repos,
                groupingMode: .activity,
                referenceDate: now,
                calendar: organizationCalendar,
                query: "",
                paneLocationsByWorktreeId: [
                    worktree.id: [
                        paneLocation(paneID: olderPaneID, tabID: tabID, paneIndex: 0),
                        paneLocation(paneID: activePaneID, tabID: tabID, paneIndex: 1),
                    ]
                ]
            ),
            paneRowFactsByPaneId: [
                olderPaneID: paneFacts(
                    title: "Recently Focused",
                    activityAt: now.addingTimeInterval(-3000),
                    recencyReferenceDate: now
                ),
                activePaneID: paneFacts(
                    title: "Output Pane",
                    activityAt: now.addingTimeInterval(-30),
                    recencyReferenceDate: now.addingTimeInterval(-20_000)
                ),
            ]
        )

        let groupID = try #require(projection.resolvedGroups.first?.id)
        let row = try #require(projection.worktreeRowsByGroupId[groupID]?.first)
        #expect(row.activitySubgroup == nil)
        #expect(projection.sections.map(\.kind) == [.activeRepos])
    }

    @Test(
        "Panes uses bucket groups while Repos has no nested activity headings",
        arguments: [SidebarSurface.repos, .panes], [false, true]
    )
    func activityBucketsStayAtSectionLevel(surface: SidebarSurface, hasDifferentActivity: Bool) throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let repoID = UUIDv7.generate()
        let firstWorktree = worktree(repoId: repoID, name: "uniquealpha")
        let secondWorktree = worktree(repoId: repoID, name: "uniquebeta")
        let firstPaneID = UUIDv7.generate()
        let secondPaneID = UUIDv7.generate()
        let tabID = UUIDv7.generate()
        let repository = repo(id: repoID, name: "repository", worktrees: [firstWorktree, secondWorktree])
        let facts = [
            firstPaneID: paneFacts(title: "uniquealpha", activityAt: now.addingTimeInterval(-30)),
            secondPaneID: paneFacts(
                title: "uniquebeta", activityAt: hasDifferentActivity ? nil : now.addingTimeInterval(-30)
            ),
        ]
        let groupingModes: [RepoExplorerGroupingMode] = surface == .repos ? [.repo] : [.repo, .tab]
        for groupingMode in groupingModes {
            for query in ["", "uniquealpha"] {
                let projection = RepoExplorerProjection.project(
                    RepoExplorerSnapshot(
                        repos: [repository],
                        repoEnrichmentByRepoId: [repoID: resolvedRemote(repoId: repoID, displayName: repository.name)],
                        surface: surface, groupingMode: groupingMode, subgroupMode: .activity,
                        referenceDate: now,
                        referenceInstant: surface == .panes ? organizationReferenceInstant : nil,
                        calendar: organizationCalendar, query: query,
                        paneLocationsByWorktreeId: [
                            firstWorktree.id: [paneLocation(paneID: firstPaneID, tabID: tabID, paneIndex: 0)],
                            secondWorktree.id: [paneLocation(paneID: secondPaneID, tabID: tabID, paneIndex: 1)],
                        ]
                    ),
                    paneRowFactsByPaneId: facts
                )
                let index = RepoExplorerRowIndex(
                    projection: projection, collapsedGroupIds: [], isFiltering: !query.isEmpty
                )
                let headings = index.entries.compactMap { entry -> RepoExplorerActivityBucket? in
                    if case .activitySubgroup(_, let bucket) = entry { return bucket }
                    return nil
                }
                #expect(headings.isEmpty)
                if surface == .panes {
                    let expectedTitles =
                        hasDifferentActivity && query.isEmpty
                        ? ["Active", "No activity"] : ["Active"]
                    #expect(projection.resolvedGroups.map(\.repoTitle) == expectedTitles)
                }
                let leafCount = index.entries.filter { entry in
                    switch entry {
                    case .resolvedPaneRow, .resolvedWorktreeRow: true
                    default: false
                    }
                }.count
                #expect(leafCount == (query.isEmpty ? 2 : 1))
            }
        }
    }

    private func paneLocation(
        paneID: UUID,
        tabID: UUID,
        tabIndex: Int = 0,
        paneIndex: Int = 0
    ) -> WorkspacePaneLocation {
        WorkspacePaneLocation(
            paneId: paneID,
            tabId: tabID,
            tabIndex: tabIndex,
            paneIndexInTab: paneIndex,
            isActiveInTab: paneIndex == 0
        )
    }

    private func paneFacts(
        title: String,
        activityAt: Date? = nil,
        isPinned: Bool = false,
        recencyReferenceDate: Date = Date(timeIntervalSince1970: 0)
    ) -> RepoExplorerPaneRowFacts {
        RepoExplorerPaneRowFacts(
            terminalTitle: title,
            activityAt: activityAt,
            paneActivityTime: activityAt.map {
                PaneActivityTime(
                    orderingInstant: organizationReferenceInstant.advanced(
                        by: .seconds(Int($0.timeIntervalSince(organizationReferenceDate)))
                    ),
                    wallTime: $0,
                    source: .terminal
                )
            },
            isPinned: isPinned,
            latestMessageText: nil,
            recencyReferenceDate: recencyReferenceDate,
            recencyText: "Now",
            isActive: false
        )
    }

    private func paneIDs(
        in section: RepoExplorerSidebarSection,
        projection: RepoExplorerSidebarProjection
    ) -> [UUID] {
        section.resolvedGroups.flatMap { group in
            projection.paneRowsByGroupId[group.id, default: []].map { $0.destination.paneId }
        }
    }
}

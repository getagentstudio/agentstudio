import AgentStudioCore
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite("RepoExplorerView", .serialized)
struct RepoExplorerViewTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("By Repo retains the shared Git owner and O12 panes use context controls")
    func gitStatusRenderSitesUseTheSharedOwner() throws {
        // O12 retires pane-row Git chips. By Repo still owns the shared PR glyph/colour path;
        // pane entries use the App-injected context controls instead of inline PR chips.
        let worktreeRowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
            encoding: .utf8
        )
        let paneRowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerPaneNavigation.swift",
            encoding: .utf8
        )
        let sharedChipsSource = try String(
            contentsOfFile: "Sources/AgentStudio/Core/Views/SidebarChips.swift",
            encoding: .utf8
        )

        #expect(
            worktreeRowSource.range(
                of: #"SidebarGitStatusChips\(\s*branchStatus:"#,
                options: .regularExpression
            ) != nil
        )
        #expect(paneRowSource.contains("paneContextControl(paneId, .kind(chip))"))
        for source in [worktreeRowSource, paneRowSource] {
            // Neither row constructs its own inline PR chip anymore; the octicon string only
            // appears inside the shared spec itself (SidebarChips.swift), never at a row call site.
            #expect(!source.contains("octicon-git-pull-request"))
        }
        #expect(sharedChipsSource.contains("SidebarPullRequestChipSpec.chip(count:"))
    }

    @Test("organization controls use shared picker chrome without persistent pin fill")
    func organizationControlsUseSharedPickerChrome() throws {
        let toolbarSource = try String(
            contentsOfFile:
                "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+CommandToolbar.swift",
            encoding: .utf8
        )
        let sharedControlSource = try String(
            contentsOfFile:
                "Sources/AgentStudio/SharedComponents/SidebarSortButton.swift",
            encoding: .utf8
        )

        #expect(toolbarSource.contains("SidebarToolbarPickerButton("))
        #expect(toolbarSource.contains("showsActiveBackground: false"))
        #expect(sharedControlSource.contains("SidebarToolbarButtonStyle(isOpen: isOpen)"))
        #expect(sharedControlSource.contains("isActive: isActive && showsActiveBackground"))
    }

    @Test("flat list entries expand a resolved group into header and child rows")
    func flatListEntriesExpandResolvedGroupIntoHeaderAndChildRows() {
        let repoId = UUID()
        let worktree = Worktree(
            repoId: repoId,
            name: "main",
            path: URL(fileURLWithPath: "/tmp/agent-studio"),
            isMainWorktree: true
        )
        let repo = RepoPresentationItem(
            id: repoId,
            name: "agent-studio",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
            stableKey: "agent-studio",
            worktrees: [worktree]
        )
        let group = RepoPresentationGroup(
            id: "remote:askluna/agent-studio",
            repoTitle: "agent-studio",
            organizationName: "askluna",
            repos: [repo]
        )

        let entries = RepoExplorerView.buildListEntries(
            groups: [group],
            collapsedGroupIds: [],
            isFiltering: false
        )

        #expect(entries.count == 2)
        guard
            case .resolvedGroupHeader(let headerGroup) = entries[0],
            case .resolvedWorktreeRow(let childGroupId, let childRepoId, let childWorktreeId, _) = entries[1]
        else {
            Issue.record("Expected flat resolved header followed by child row")
            return
        }

        #expect(headerGroup.id == group.id)
        #expect(childGroupId == group.id)
        #expect(childRepoId == repo.id)
        #expect(childWorktreeId == worktree.id)
    }

    @Test("flat list entries keep collapsed groups flat with header only")
    func flatListEntriesKeepCollapsedGroupsFlatWithHeaderOnly() {
        let repoId = UUID()
        let repo = RepoPresentationItem(
            id: repoId,
            name: "agent-studio",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
            stableKey: "agent-studio",
            worktrees: [Worktree(repoId: repoId, name: "main", path: URL(fileURLWithPath: "/tmp/agent-studio"))]
        )
        let group = RepoPresentationGroup(
            id: "remote:askluna/agent-studio",
            repoTitle: "agent-studio",
            organizationName: "askluna",
            repos: [repo]
        )

        let entries = RepoExplorerView.buildListEntries(
            groups: [group],
            collapsedGroupIds: [group.id],
            isFiltering: false
        )

        #expect(entries.count == 1)
        guard case .resolvedGroupHeader(let headerGroup) = entries[0] else {
            Issue.record("Expected collapsed group to render header only")
            return
        }
        #expect(headerGroup.id == group.id)
    }

    @Test("flat list entries only include resolved headers and worktree rows")
    func flatListEntriesOnlyIncludeResolvedHeadersAndWorktreeRows() {
        let resolvedRepoId = UUID()
        let resolvedGroup = RepoPresentationGroup(
            id: "remote:askluna/agent-studio",
            repoTitle: "agent-studio",
            organizationName: "askluna",
            repos: [
                RepoPresentationItem(
                    id: resolvedRepoId,
                    name: "agent-studio",
                    repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
                    stableKey: "agent-studio",
                    worktrees: [
                        Worktree(
                            repoId: resolvedRepoId,
                            name: "main",
                            path: URL(fileURLWithPath: "/tmp/agent-studio")
                        )
                    ]
                )
            ]
        )

        let entries = RepoExplorerView.buildListEntries(
            groups: [resolvedGroup],
            collapsedGroupIds: [resolvedGroup.id],
            isFiltering: false
        )

        #expect(entries.count == 1)
        guard case .resolvedGroupHeader = entries[0] else {
            Issue.record("Expected only the resolved header entry")
            return
        }
    }

    @Test("checkout icon kind uses star for the main worktree")
    func checkoutIconKindUsesStarForMainWorktree() {
        let repoId = UUID()
        let repo = RepoPresentationItem(
            id: repoId,
            name: "agent-studio",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
            stableKey: "agent-studio",
            worktrees: [
                Worktree(
                    repoId: repoId,
                    name: "main",
                    path: URL(fileURLWithPath: "/tmp/agent-studio"),
                    isMainWorktree: true
                ),
                Worktree(
                    repoId: repoId,
                    name: "feature-sidebar",
                    path: URL(fileURLWithPath: "/tmp/agent-studio-feature"),
                    isMainWorktree: false
                ),
            ]
        )
        let worktree = repo.worktrees[0]
        #expect(RepoExplorerView.checkoutIconKind(for: worktree, in: repo) == .mainCheckout)
    }

    @Test("checkout icon kind uses git-worktree for a secondary worktree")
    func checkoutIconKindUsesGitWorktreeForSecondaryWorktree() {
        let repoId = UUID()
        let repo = RepoPresentationItem(
            id: repoId,
            name: "agent-studio",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
            stableKey: "agent-studio",
            worktrees: [
                Worktree(
                    repoId: repoId,
                    name: "main",
                    path: URL(fileURLWithPath: "/tmp/agent-studio"),
                    isMainWorktree: true
                ),
                Worktree(
                    repoId: repoId,
                    name: "feature-sidebar",
                    path: URL(fileURLWithPath: "/tmp/agent-studio-feature"),
                    isMainWorktree: false
                ),
            ]
        )
        let worktree = repo.worktrees[1]
        #expect(RepoExplorerView.checkoutIconKind(for: worktree, in: repo) == .gitWorktree)
    }

    @Test("checkout icon kind uses star for a standalone repo")
    func checkoutIconKindUsesStarForStandaloneRepo() {
        let repoId = UUID()
        let repo = RepoPresentationItem(
            id: repoId,
            name: "agent-studio",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
            stableKey: "agent-studio",
            worktrees: [
                Worktree(
                    repoId: repoId,
                    name: "main",
                    path: URL(fileURLWithPath: "/tmp/agent-studio"),
                    isMainWorktree: true
                )
            ]
        )
        #expect(RepoExplorerView.checkoutIconKind(for: repo.worktrees[0], in: repo) == .mainCheckout)
    }

    @Test("worktrees of the same repo share color, different repo in same group gets different color")
    func worktreeFamilyColorInvariant() {
        let repoAId = UUID()
        let repoBId = UUID()
        let repoA = RepoPresentationItem(
            id: repoAId,
            name: "agent-studio",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
            stableKey: "agent-studio-a",
            worktrees: [
                Worktree(
                    repoId: repoAId,
                    name: "main",
                    path: URL(fileURLWithPath: "/tmp/agent-studio"),
                    isMainWorktree: true
                ),
                Worktree(
                    repoId: repoAId,
                    name: "feature",
                    path: URL(fileURLWithPath: "/tmp/agent-studio-feature"),
                    isMainWorktree: false
                ),
            ]
        )
        let repoB = RepoPresentationItem(
            id: repoBId,
            name: "agent-studio-fork",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio-fork"),
            stableKey: "agent-studio-b",
            worktrees: [
                Worktree(
                    repoId: repoBId,
                    name: "main",
                    path: URL(fileURLWithPath: "/tmp/agent-studio-fork"),
                    isMainWorktree: true
                )
            ]
        )
        // One group with two repos — this is the real sidebar scenario
        let group = RepoPresentationGroup(
            id: "remote:askluna/agent-studio",
            repoTitle: "agent-studio",
            organizationName: "askluna",
            repos: [repoA, repoB]
        )

        // All worktrees of repoA share color (keyed by repo.id)
        let colorA = RepoExplorerView.checkoutColorHex(for: repoA, in: group)

        // repoB gets a different color
        let colorB = RepoExplorerView.checkoutColorHex(for: repoB, in: group)

        // Family invariant: same repo = same color, different repo = different color
        #expect(colorA != colorB, "Different repos in same group should get different colors")

        // Color is deterministic — calling again produces same result
        let colorAAgain = RepoExplorerView.checkoutColorHex(for: repoA, in: group)
        #expect(colorA == colorAAgain, "Color should be deterministic for same repo")
    }

    @Test("single repo in a group uses the first automatic palette color")
    func singleRepoInGroupUsesFirstAutomaticPaletteColor() {
        let repo = RepoPresentationItem(
            id: UUID(),
            name: "agent-studio",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
            stableKey: "agent-studio",
            worktrees: [
                Worktree(
                    repoId: UUID(),
                    name: "main",
                    path: URL(fileURLWithPath: "/tmp/agent-studio"),
                    isMainWorktree: true
                )
            ]
        )
        let group = RepoPresentationGroup(
            id: "remote:askluna/agent-studio",
            repoTitle: "agent-studio",
            organizationName: "askluna",
            repos: [repo]
        )

        let color = RepoExplorerView.checkoutColorHex(for: repo, in: group)

        #expect(color == RepoPresentationGrouping.automaticPaletteHexes[0])
    }

    @Test("sidebar projection separates resolved groups from loading repos")
    func sidebarProjectionSeparatesResolvedGroupsFromLoadingRepos() {
        let resolvedId = UUID()
        let unresolvedId = UUID()
        let missingId = UUID()

        let resolvedRepo = RepoPresentationItem(
            id: resolvedId,
            name: "resolved-repo",
            repoPath: URL(fileURLWithPath: "/tmp/resolved-repo"),
            stableKey: "resolved-repo",
            worktrees: [Worktree(repoId: resolvedId, name: "main", path: URL(fileURLWithPath: "/tmp/resolved-repo"))]
        )
        let unresolvedRepo = RepoPresentationItem(
            id: unresolvedId,
            name: "loading-repo",
            repoPath: URL(fileURLWithPath: "/tmp/loading-repo"),
            stableKey: "loading-repo",
            worktrees: [Worktree(repoId: unresolvedId, name: "main", path: URL(fileURLWithPath: "/tmp/loading-repo"))]
        )
        let missingRepo = RepoPresentationItem(
            id: missingId,
            name: "missing-repo",
            repoPath: URL(fileURLWithPath: "/tmp/missing-repo"),
            stableKey: "missing-repo",
            worktrees: [Worktree(repoId: missingId, name: "main", path: URL(fileURLWithPath: "/tmp/missing-repo"))]
        )

        let projection = RepoExplorerView.projectSidebar(
            repos: [resolvedRepo, unresolvedRepo, missingRepo],
            repoEnrichmentByRepoId: [
                resolvedId: .resolvedRemote(
                    repoId: resolvedId,
                    raw: RawRepoOrigin(origin: "git@github.com:org/resolved-repo.git", upstream: nil),
                    identity: RepoIdentity(
                        groupKey: "remote:org/resolved-repo",
                        remoteSlug: "org/resolved-repo",
                        organizationName: "org",
                        displayName: "resolved-repo"
                    ),
                    updatedAt: Date()
                ),
                unresolvedId: .awaitingOrigin(repoId: unresolvedId),
            ],
            query: ""
        )

        #expect(projection.resolvedGroups.count == 1)
        #expect(projection.resolvedGroups.first?.repos.map(\.id) == [resolvedId])
        #expect(Set(projection.loadingRepos.map(\.id)) == Set([unresolvedId, missingId]))
        #expect(projection.showsNoResults == false)
    }

    @Test("sidebar projection keeps loading matches visible during filtering")
    func sidebarProjectionKeepsLoadingMatchesVisibleDuringFiltering() {
        let loadingRepo = RepoPresentationItem(
            id: UUID(),
            name: "loading-target",
            repoPath: URL(fileURLWithPath: "/tmp/loading-target"),
            stableKey: "loading-target",
            worktrees: [Worktree(repoId: UUID(), name: "main", path: URL(fileURLWithPath: "/tmp/loading-target"))]
        )

        let projection = RepoExplorerView.projectSidebar(
            repos: [loadingRepo],
            repoEnrichmentByRepoId: [:],
            query: "loading"
        )

        #expect(projection.resolvedGroups.isEmpty)
        #expect(projection.loadingRepos.map(\.id) == [loadingRepo.id])
        #expect(projection.showsNoResults == false)
    }

    @Test("sidebar projection shows no results only when both sections are empty for a query")
    func sidebarProjectionShowsNoResultsOnlyWhenBothSectionsAreEmpty() {
        let loadingRepo = RepoPresentationItem(
            id: UUID(),
            name: "loading-target",
            repoPath: URL(fileURLWithPath: "/tmp/loading-target"),
            stableKey: "loading-target",
            worktrees: [Worktree(repoId: UUID(), name: "main", path: URL(fileURLWithPath: "/tmp/loading-target"))]
        )

        let projection = RepoExplorerView.projectSidebar(
            repos: [loadingRepo],
            repoEnrichmentByRepoId: [:],
            query: "no-match"
        )

        #expect(projection.resolvedGroups.isEmpty)
        #expect(projection.loadingRepos.isEmpty)
        #expect(projection.showsNoResults)
    }

    @Test("branchStatus maps centralized local-git summary + PR count")
    func branchStatusMapsLocalSummaryAndPRCount() {
        let worktreeId = UUID()
        let repoId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
        let enrichment = WorktreeEnrichment(
            worktreeId: worktreeId,
            repoId: repoId,
            branch: "feature/sidebar",
            snapshot: GitWorkingTreeSnapshot(
                worktreeId: worktreeId,
                rootPath: rootPath,
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 2),
                branch: "feature/sidebar"
            )
        )

        let status = RepoExplorerView.branchStatus(
            enrichment: enrichment,
            pullRequestFacts: PullRequestFacts(openCount: 3, exactOpenURL: nil)
        )

        #expect(status.isDirty == true)
        #expect(status.prCount == 3)
        #expect(status.syncState == .unknown)
        #expect(status.linesAdded == 0)
        #expect(status.linesDeleted == 0)
    }

    @Test("primary grouping uses shared metadata group key")
    func primaryGroupingUsesSharedMetadataGroupKey() {
        let groupKey = "remote:askluna/agent-studio"
        let firstRepo = RepoPresentationItem(
            id: UUID(),
            name: "agent-studio-a",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio-a"),
            stableKey: "a",
            worktrees: [Worktree(repoId: UUID(), name: "main", path: URL(fileURLWithPath: "/tmp/agent-studio-a"))]
        )
        let secondRepo = RepoPresentationItem(
            id: UUID(),
            name: "agent-studio-b",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio-b"),
            stableKey: "b",
            worktrees: [Worktree(repoId: UUID(), name: "main", path: URL(fileURLWithPath: "/tmp/agent-studio-b"))]
        )
        let metadataByRepoId: [UUID: RepoIdentityMetadata] = [
            firstRepo.id: RepoIdentityMetadata(
                groupKey: groupKey,
                repoName: "agent-studio",
                organizationName: "askluna",
                lastPathComponent: "agent-studio-a"
            ),
            secondRepo.id: RepoIdentityMetadata(
                groupKey: groupKey,
                repoName: "agent-studio",
                organizationName: "askluna",
                lastPathComponent: "agent-studio-b"
            ),
        ]

        let groups = RepoPresentationGrouping.buildGroups(
            repos: [firstRepo, secondRepo],
            metadataByRepoId: metadataByRepoId
        )

        #expect(groups.count == 1)
        #expect(groups.first?.id == groupKey)
        #expect(groups.first?.repos.count == 2)
    }

    @Test("projection fingerprint changes when repo graduates from loading to resolved")
    func projectionFingerprintChangesWhenTopologyChanges() {
        let repo = RepoPresentationItem(
            id: UUID(),
            name: "agent-studio",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
            stableKey: "agent-studio",
            worktrees: [Worktree(repoId: UUID(), name: "main", path: URL(fileURLWithPath: "/tmp/agent-studio"))]
        )

        let loadingProjection = RepoExplorerView.projectSidebar(
            repos: [repo],
            repoEnrichmentByRepoId: [
                repo.id: .awaitingOrigin(repoId: repo.id)
            ],
            query: ""
        )
        let resolvedProjection = RepoExplorerView.projectSidebar(
            repos: [repo],
            repoEnrichmentByRepoId: [
                repo.id: .resolvedRemote(
                    repoId: repo.id,
                    raw: RawRepoOrigin(origin: "git@github.com:askluna/agent-studio.git", upstream: nil),
                    identity: RepoIdentity(
                        groupKey: "remote:askluna/agent-studio",
                        remoteSlug: "askluna/agent-studio",
                        organizationName: "askluna",
                        displayName: "agent-studio"
                    ),
                    updatedAt: Date()
                )
            ],
            query: ""
        )

        let loadingFingerprint = RepoExplorerView.projectionFingerprint(for: loadingProjection)
        let resolvedFingerprint = RepoExplorerView.projectionFingerprint(for: resolvedProjection)

        #expect(loadingFingerprint != resolvedFingerprint)
        #expect(loadingProjection.loadingRepos.map(\.id) == [repo.id])
        #expect(resolvedProjection.resolvedGroups.first?.repos.map(\.id) == [repo.id])
    }

    @Test("projection fingerprint includes rendered worktree identity")
    func projectionFingerprintIncludesRenderedWorktreeIdentity() {
        let repoId = UUID()
        let worktreeId = UUID()
        let originalRepo = RepoPresentationItem(
            id: repoId,
            name: "agent-studio",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio"),
            stableKey: "agent-studio",
            worktrees: [
                Worktree(
                    id: worktreeId,
                    repoId: repoId,
                    name: "before",
                    path: URL(fileURLWithPath: "/tmp/agent-studio.before")
                )
            ]
        )
        let changedRepo = RepoPresentationItem(
            id: repoId,
            name: originalRepo.name,
            repoPath: originalRepo.repoPath,
            stableKey: originalRepo.stableKey,
            worktrees: [
                Worktree(
                    id: worktreeId,
                    repoId: repoId,
                    name: "after",
                    path: URL(fileURLWithPath: "/tmp/agent-studio.after")
                )
            ]
        )
        let enrichment: [UUID: RepoEnrichment] = [
            repoId: .resolvedLocal(
                repoId: repoId,
                identity: RemoteIdentityNormalizer.localIdentity(repoName: "agent-studio"),
                updatedAt: Date()
            )
        ]

        let original = RepoExplorerView.projectSidebar(
            repos: [originalRepo], repoEnrichmentByRepoId: enrichment, query: "")
        let changed = RepoExplorerView.projectSidebar(
            repos: [changedRepo], repoEnrichmentByRepoId: enrichment, query: "")

        #expect(
            RepoExplorerView.projectionFingerprint(for: original)
                != RepoExplorerView.projectionFingerprint(for: changed))
    }

    @Test("projection fingerprint includes search no-results state")
    func projectionFingerprintIncludesSearchNoResultsState() {
        let content = RepoExplorerSidebarProjection(
            sections: [],
            resolvedGroups: [], loadingRepos: [], emptyState: .content)
        let searchNoResults = RepoExplorerSidebarProjection(
            sections: [],
            resolvedGroups: [], loadingRepos: [], emptyState: .searchNoResults)

        #expect(
            RepoExplorerView.projectionFingerprint(for: content)
                != RepoExplorerView.projectionFingerprint(for: searchNoResults))
    }

    @Test("projection fingerprint includes deterministic projected row placement")
    func projectionFingerprintIncludesProjectedRowPlacement() {
        let repoId = UUID()
        let worktree = Worktree(repoId: repoId, name: "main", path: URL(fileURLWithPath: "/tmp/main"))
        let repo = RepoPresentationItem(
            id: repoId, name: "repo", repoPath: worktree.path, stableKey: "repo", worktrees: [worktree])
        let first = RepoExplorerProjectedWorktreeRow(
            groupId: "group", repo: repo, worktree: worktree, rowId: "row", checkoutColorHex: "#000000",
            placementContext: RepoExplorerPlacementContext(
                paneId: UUID(), tabId: UUID(), tabIndex: 0, paneIndexInTab: 0, isActiveInTab: true))
        let second = RepoExplorerProjectedWorktreeRow(
            groupId: "group", repo: repo, worktree: worktree, rowId: "row", checkoutColorHex: "#000000",
            placementContext: RepoExplorerPlacementContext(
                paneId: first.placementContext!.paneId, tabId: first.placementContext!.tabId,
                tabIndex: 1, paneIndexInTab: 0, isActiveInTab: true))
        let group = RepoPresentationGroup(
            id: "group",
            repoTitle: repo.name,
            organizationName: nil,
            repos: [repo]
        )
        let sections = [
            RepoExplorerSidebarSection(
                kind: .repositories,
                resolvedGroups: [group],
                loadingRepos: []
            )
        ]
        let firstProjection = RepoExplorerSidebarProjection(
            sections: sections,
            resolvedGroups: [group], worktreeRowsByGroupId: ["group": [first]], loadingRepos: [], emptyState: .content)
        let secondProjection = RepoExplorerSidebarProjection(
            sections: sections,
            resolvedGroups: [group], worktreeRowsByGroupId: ["group": [second]], loadingRepos: [], emptyState: .content)

        #expect(
            RepoExplorerView.projectionFingerprint(for: firstProjection)
                != RepoExplorerView.projectionFingerprint(for: secondProjection))
    }

    @Test("first surviving projection reports initial completion exactly once")
    func firstSurvivingProjectionReportsInitialCompletionExactlyOnce() {
        #expect(
            RepoExplorerView.shouldReportInitialProjection(
                hasReportedInitialProjection: false
            ))
        #expect(
            !RepoExplorerView.shouldReportInitialProjection(
                hasReportedInitialProjection: true
            ))
    }

    @Test("repo metadata builder uses resolved local identity when available")
    func repoMetadataBuilderUsesResolvedLocalIdentity() {
        let repo = RepoPresentationItem(
            id: UUID(),
            name: "MyProject",
            repoPath: URL(fileURLWithPath: "/tmp/MyProject"),
            stableKey: "my-project",
            worktrees: [Worktree(repoId: UUID(), name: "main", path: URL(fileURLWithPath: "/tmp/MyProject"))]
        )

        let metadata = RepoExplorerView.buildRepoMetadata(
            repos: [repo],
            repoEnrichmentByRepoId: [
                repo.id: .resolvedLocal(
                    repoId: repo.id,
                    identity: RemoteIdentityNormalizer.localIdentity(repoName: "MyProject"),
                    updatedAt: Date()
                )
            ]
        )

        #expect(metadata[repo.id]?.groupKey == "local:MyProject")
        #expect(metadata[repo.id]?.organizationName == nil)
    }

    @Test("missing metadata falls back to path grouping key")
    func missingMetadataFallsBackToPathGroupingKey() {
        let repo = RepoPresentationItem(
            id: UUID(),
            name: "path-repo",
            repoPath: URL(fileURLWithPath: "/tmp/path-repo"),
            stableKey: "path",
            worktrees: [Worktree(repoId: UUID(), name: "main", path: URL(fileURLWithPath: "/tmp/path-repo"))]
        )

        let groups = RepoPresentationGrouping.buildGroups(
            repos: [repo],
            metadataByRepoId: [:]
        )

        #expect(groups.count == 1)
        #expect(groups.first?.id == "path:\(repo.repoPath.standardizedFileURL.path)")
    }

    @Test("branch label prefers enrichment branch over canonical fallback")
    func branchLabelPrefersEnrichmentBranch() {
        let worktree = Worktree(
            repoId: UUID(),
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/feature-a"),
            isMainWorktree: false
        )
        let enrichment = WorktreeEnrichment(
            worktreeId: worktree.id,
            repoId: UUID(),
            branch: "feature/fix-primary-sidebar",
            snapshot: nil
        )

        let label = atom(\.paneDisplay).resolvedBranchName(
            worktree: worktree,
            enrichment: enrichment
        )

        #expect(label == "feature/fix-primary-sidebar")
    }

    @Test("branch label falls back to detached head only when both sources are empty")
    func branchLabelDetachedHeadFallback() {
        let worktree = Worktree(
            repoId: UUID(),
            name: "unknown",
            path: URL(fileURLWithPath: "/tmp/unknown"),
            isMainWorktree: false
        )

        let label = atom(\.paneDisplay).resolvedBranchName(
            worktree: worktree,
            enrichment: nil
        )

        #expect(label == "detached HEAD")
    }

    @Test("repo metadata builder uses resolved remote identity when available")
    func repoMetadataBuilderUsesResolvedIdentity() {
        let repo = RepoPresentationItem(
            id: UUID(),
            name: "agent-studio-local",
            repoPath: URL(fileURLWithPath: "/tmp/agent-studio-local"),
            stableKey: "agent-studio-local",
            worktrees: [Worktree(repoId: UUID(), name: "main", path: URL(fileURLWithPath: "/tmp/agent-studio-local"))]
        )

        let metadata = RepoExplorerView.buildRepoMetadata(
            repos: [repo],
            repoEnrichmentByRepoId: [
                repo.id: .resolvedRemote(
                    repoId: repo.id,
                    raw: RawRepoOrigin(origin: "git@github.com:askluna/agent-studio.git", upstream: nil),
                    identity: RepoIdentity(
                        groupKey: "remote:askluna/agent-studio",
                        remoteSlug: "askluna/agent-studio",
                        organizationName: "askluna",
                        displayName: "agent-studio"
                    ),
                    updatedAt: Date()
                )
            ]
        )

        #expect(metadata[repo.id]?.groupKey == "remote:askluna/agent-studio")
        #expect(metadata[repo.id]?.organizationName == "askluna")
    }

    @Test("primaryRepoForGroup prefers repo whose repoPath matches one of its worktrees")
    func primaryRepoForGroupPrefersRepoPathMatch() {
        let repoA = RepoPresentationItem(
            id: UUID(),
            name: "askluna-finance-rlvr-forking",
            repoPath: URL(fileURLWithPath: "/tmp/askluna-finance-rlvr-forking"),
            stableKey: "a",
            worktrees: [
                Worktree(
                    repoId: UUID(),
                    name: "rlvr-forking",
                    path: URL(fileURLWithPath: "/tmp/askluna-finance-rlvr-forking")
                )
            ]
        )
        let repoB = RepoPresentationItem(
            id: UUID(),
            name: "askluna-finance",
            repoPath: URL(fileURLWithPath: "/tmp/askluna-finance"),
            stableKey: "b",
            worktrees: [
                Worktree(
                    repoId: UUID(),
                    name: "transaction-table-3", path: URL(fileURLWithPath: "/tmp/transaction-table-3")
                )
            ]
        )
        let group = RepoPresentationGroup(
            id: "remote:askluna/askluna-finance",
            repoTitle: "askluna-finance",
            organizationName: "askluna",
            repos: [repoA, repoB]
        )

        let primaryRepo = RepoExplorerView.primaryRepoForGroup(group)
        #expect(primaryRepo?.id == repoA.id)
    }

    @Test("primaryRepoForGroup falls back deterministically when no repo has a main-path match")
    func primaryRepoForGroupFallsBackDeterministically() {
        let repoA = RepoPresentationItem(
            id: UUID(),
            name: "b-repo",
            repoPath: URL(fileURLWithPath: "/tmp/b-repo"),
            stableKey: "b",
            worktrees: [Worktree(repoId: UUID(), name: "feat-b", path: URL(fileURLWithPath: "/tmp/feat-b"))]
        )
        let repoB = RepoPresentationItem(
            id: UUID(),
            name: "a-repo",
            repoPath: URL(fileURLWithPath: "/tmp/a-repo"),
            stableKey: "a",
            worktrees: [Worktree(repoId: UUID(), name: "feat-a", path: URL(fileURLWithPath: "/tmp/feat-a"))]
        )
        let group = RepoPresentationGroup(
            id: "remote:org/repo",
            repoTitle: "repo",
            organizationName: "org",
            repos: [repoA, repoB]
        )

        let primaryRepo = RepoExplorerView.primaryRepoForGroup(group)
        #expect(primaryRepo?.name == "a-repo")
    }

}

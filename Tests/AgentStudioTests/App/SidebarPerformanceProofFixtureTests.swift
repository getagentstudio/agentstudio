import AgentStudioInfrastructure
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension SidebarPerformanceProofStartupDiagnosticTests {
    @Test("historical fixture activity uses the typed store and preserves warm and unknown demand")
    func historicalFixtureActivityPreservesMixedDemandPopulations() async throws {
        let referenceDate = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let horizon = AppPolicies.EntityRecency.applicationActivityHorizon
        let warmRepositoryID = UUIDv7.generate()
        let warmWorktreeID = UUIDv7.generate()
        let firstUnknownRepositoryID = UUIDv7.generate()
        let firstUnknownWorktreeID = UUIDv7.generate()
        let secondUnknownRepositoryID = UUIDv7.generate()
        let secondUnknownWorktreeID = UUIDv7.generate()
        let repositories = [
            RepositoryActivityTopology(
                repositoryID: warmRepositoryID,
                repositoryStableKey: "1111111111111111",
                worktreeStableKeysByID: [warmWorktreeID: "2222222222222222"]
            ),
            RepositoryActivityTopology(
                repositoryID: firstUnknownRepositoryID,
                repositoryStableKey: "3333333333333333",
                worktreeStableKeysByID: [firstUnknownWorktreeID: "4444444444444444"]
            ),
            RepositoryActivityTopology(
                repositoryID: secondUnknownRepositoryID,
                repositoryStableKey: "5555555555555555",
                worktreeStableKeysByID: [secondUnknownWorktreeID: "6666666666666666"]
            ),
        ]
        let (activityAtom, activityStore) = try await makeCurrentCoverageActivityStore(
            referenceDate: referenceDate
        )
        let initialActivityByStableKey = activityAtom.snapshot()
        let initialClassificationInput = RepositoryActivityClassificationInput(
            repositories: repositories,
            openWorktreeIDs: [],
            localActivityHydrationDisposition: activityAtom.hydrationDisposition,
            repositoryLocalActivityByStableKey: initialActivityByStableKey,
            referenceDate: referenceDate,
            inactivityHorizon: horizon
        )
        let firstRootURL = URL(fileURLWithPath: "/fixture/first-root")
        let secondRootURL = URL(fileURLWithPath: "/fixture/second-root")
        let warmRepositoryPath = firstRootURL.appendingPathComponent("warm")
        let inactiveCandidatePath = firstRootURL.appendingPathComponent("inactive-candidate")
        let unknownRemainderPath = secondRootURL.appendingPathComponent("unknown-remainder")
        let repositoryPathsByID = [
            warmRepositoryID: warmRepositoryPath,
            firstUnknownRepositoryID: inactiveCandidatePath,
            secondUnknownRepositoryID: unknownRemainderPath,
        ]
        let watchedRootSummary = WatchedFolderRefreshSummary(
            repoPathsByWatchedFolder: [
                firstRootURL: [warmRepositoryPath, inactiveCandidatePath],
                secondRootURL: [unknownRemainderPath],
            ]
        )

        let seed = try #require(
            await SidebarPerformanceProofFixture.makeHistoricalInactiveActivitySeed(
                classificationInput: initialClassificationInput,
                repositoryPathsByID: repositoryPathsByID,
                watchedRootSummary: watchedRootSummary,
                rootURLs: [firstRootURL, secondRootURL]
            )
        )
        _ = try await activityStore.commitAsync(seed.commit)
        let acceptedActivityByStableKey = activityAtom.snapshot()
        let finalClassificationInput = RepositoryActivityClassificationInput(
            repositories: repositories,
            openWorktreeIDs: [],
            localActivityHydrationDisposition: activityAtom.hydrationDisposition,
            repositoryLocalActivityByStableKey: acceptedActivityByStableKey,
            referenceDate: referenceDate,
            inactivityHorizon: horizon
        )
        let finalClassification = RepositoryActivityClassifier.classify(finalClassificationInput)
        let demand = try await settledHistoricalActivityDemand(
            classificationInput: finalClassificationInput,
            attendedWorktreeIDs: [
                warmWorktreeID,
                firstUnknownWorktreeID,
                secondUnknownWorktreeID,
            ],
            repositoryIDByWorktreeID: [
                warmWorktreeID: warmRepositoryID,
                firstUnknownWorktreeID: firstUnknownRepositoryID,
                secondUnknownWorktreeID: secondUnknownRepositoryID,
            ]
        )

        #expect(seed.repositoryIDs == [firstUnknownRepositoryID])
        #expect(finalClassification.warmRepositoryIDs == [warmRepositoryID])
        #expect(finalClassification.locallyInactiveRepositoryIDs == [firstUnknownRepositoryID])
        #expect(finalClassification.unknownRepositoryIDs == [secondUnknownRepositoryID])
        #expect(demand.automaticRemoteAndForgeWorktreeIds == [warmWorktreeID])
        #expect(demand.backgroundOnlyAutomaticWorktreeIds == [secondUnknownWorktreeID])
        #expect(!demand.automaticLocalGitWorktreeIds.contains(firstUnknownWorktreeID))
    }

    @Test("historical fixture activity refuses to consume the last unknown repository")
    func historicalFixtureActivityRequiresAnUnknownRemainder() async throws {
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let repository = RepositoryActivityTopology(
            repositoryID: repositoryID,
            repositoryStableKey: "7777777777777777",
            worktreeStableKeysByID: [worktreeID: "8888888888888888"]
        )
        let referenceDate = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let classificationInput = RepositoryActivityClassificationInput(
            repositories: [repository],
            openWorktreeIDs: [],
            localActivityHydrationDisposition: .authoritative,
            repositoryLocalActivityByStableKey: [:],
            referenceDate: referenceDate,
            inactivityHorizon: AppPolicies.EntityRecency.applicationActivityHorizon
        )
        let rootURL = URL(fileURLWithPath: "/fixture/root")
        let repositoryPath = rootURL.appendingPathComponent("only-unknown")

        let seed = await SidebarPerformanceProofFixture.makeHistoricalInactiveActivitySeed(
            classificationInput: classificationInput,
            repositoryPathsByID: [repositoryID: repositoryPath],
            watchedRootSummary: WatchedFolderRefreshSummary(
                repoPathsByWatchedFolder: [rootURL: [repositoryPath]]
            ),
            rootURLs: [rootURL]
        )

        #expect(seed == nil)
    }

    private func settledHistoricalActivityDemand(
        classificationInput: RepositoryActivityClassificationInput,
        attendedWorktreeIDs: Set<UUID>,
        repositoryIDByWorktreeID: [UUID: UUID]
    ) async throws -> RepositoryFactDemandSnapshot {
        let receiver = SidebarHistoricalActivityDemandReceiver()
        let coordinator = RepositoryFactDemandCoordinator(
            wallClockNow: { classificationInput.referenceDate },
            delivery: { snapshot in
                await receiver.receive(snapshot)
            }
        )
        coordinator.accept(
            RepositoryFactDemandInput(
                activePaneWorktreeId: nil,
                sidebarAttendedWorktreeIds: attendedWorktreeIDs,
                visibleActiveTabWorktreeIds: [],
                openWorktreeIds: classificationInput.openWorktreeIDs,
                repositoryIdByWorktreeId: repositoryIDByWorktreeID,
                activityTopology: classificationInput.repositories,
                localActivityHydrationDisposition: classificationInput.localActivityHydrationDisposition,
                repositoryLocalActivityByStableKey: classificationInput.repositoryLocalActivityByStableKey
            )
        )
        await coordinator.waitUntilIdle()
        let deliveredDemand = await receiver.lastSnapshot()
        await coordinator.shutdown()
        return try #require(deliveredDemand)
    }

    private func makeCurrentCoverageActivityStore(
        referenceDate: Date
    ) async throws -> (atom: RepositoryLocalActivityAtom, store: RepositoryLocalActivityStore) {
        let sqliteFixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: UUIDv7.generate())
        let datastore = try preparedWorkspaceSQLiteDatastore(from: sqliteFixture.backend)
        let atom = RepositoryLocalActivityAtom()
        let store = RepositoryLocalActivityStore(atom: atom, sqliteDatastore: datastore)
        _ = try await store.commitAsync(
            try RepositoryLocalActivityCommit(
                repositoryUpdates: [
                    RepositoryLocalActivityUpdate(
                        repositoryStableKey: "1111111111111111",
                        qualifyingActivityAt: referenceDate,
                        coverageChange: .restart(at: referenceDate)
                    ),
                    RepositoryLocalActivityUpdate(
                        repositoryStableKey: "3333333333333333",
                        coverageChange: .restart(at: referenceDate)
                    ),
                    RepositoryLocalActivityUpdate(
                        repositoryStableKey: "5555555555555555",
                        coverageChange: .restart(at: referenceDate)
                    ),
                ],
                updatedAt: referenceDate
            )
        )
        return (atom, store)
    }

    @Test("strict fixture refreshes two real roots plus one isolated control root")
    func strictFixtureRefreshesTwoRealRootsPlusOneIsolatedControlRoot() throws {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        #expect(
            SidebarPerformanceProofFixture.strictWatchedRootURLs == [
                homeURL.appendingPathComponent("code/opensource", isDirectory: true).standardizedFileURL,
                homeURL.appendingPathComponent("code/projects", isDirectory: true).standardizedFileURL,
            ]
        )
        let fixtureSource = try String(
            contentsOfFile: "Sources/AgentStudio/App/Boot/SidebarPerformanceProofFixture+RealSize.swift",
            encoding: .utf8
        )
        let diagnosticSource = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/AppDelegate+SidebarPerformanceProofStartupDiagnostics.swift",
            encoding: .utf8
        )
        let combinedSource = fixtureSource + diagnosticSource

        let requiredRoots = try #require(
            combinedSource.range(of: "strictWatchedRootURLs")
        )
        let addWatchedPath = try #require(
            combinedSource.range(of: "mutationCoordinator.addWatchedPath")
        )
        let refreshWatchedFolders = try #require(
            diagnosticSource.range(of: "commands.refreshWatchedFolders")
        )
        let completedSummary = try #require(
            diagnosticSource.range(of: "WatchedFolderRefreshSummary")
        )
        #expect(requiredRoots.lowerBound < addWatchedPath.lowerBound)
        #expect(completedSummary.lowerBound < refreshWatchedFolders.lowerBound)
        #expect(fixtureSource.contains("controlRootURL: URL"))
        #expect(fixtureSource.contains("rootURLs + [controlRootURL]"))
        #expect(combinedSource.contains("summary.repoPaths(in: rootURL).isEmpty"))
        #expect(combinedSource.contains("summary.repoPaths(in: controlRootURL) == [controlRootURL]"))
        #expect(combinedSource.contains("controlRootPresent: true"))
        #expect(combinedSource.contains("control_root_present"))
        #expect(combinedSource.contains("unknownRepositoryCount"))
        #expect(combinedSource.contains("unknownWorktreeCount"))
        #expect(combinedSource.contains("unknown_repository_count"))
        #expect(combinedSource.contains("unknown_worktree_count"))
        #expect(!diagnosticSource.contains("unclassifiedRepositoryCount"))
        #expect(!diagnosticSource.contains("populateRealSizeTopology"))

        let preparationStart = try #require(
            diagnosticSource.range(of: "private func prepareStrictSidebarPerformanceProofFixture(")
        )
        let preparationEnd = try #require(
            diagnosticSource.range(of: "private struct StrictColdRepositoryProof")
        )
        let preparation = diagnosticSource[preparationStart.lowerBound..<preparationEnd.lowerBound]
        let controlPreparation = try #require(
            preparation.range(of: "await prepareStrictSidebarControl(action: action)"))
        let fleetRegistration = try #require(
            preparation.range(of: "SidebarPerformanceProofFixture.registerStrictWatchedRoots("))
        let fleetScan = try #require(
            preparation.range(of: "refreshStrictWatchedRootsAndAwaitZeroLogicalDebt(watchedPaths)"))
        #expect(controlPreparation.lowerBound < fleetRegistration.lowerBound)
        #expect(fleetRegistration.lowerBound < fleetScan.lowerBound)
        let controlStart = try #require(diagnosticSource.range(of: "private func prepareStrictSidebarControl("))
        let controlPreparationSource = diagnosticSource[controlStart.lowerBound...]
        let controlScan = try #require(
            controlPreparationSource.range(of: "controlSummary.repoPaths(in: controlRootURL)"))
        let coldProof = try #require(
            controlPreparationSource.range(of: "await proveStrictColdRepositoryControl(controlRootURL)"))
        let sourceRegistration = try #require(
            controlPreparationSource.range(
                of: "await workspaceSurfaceCoordinator.syncFilesystemRootsAndActivityUntilIdle()"))
        #expect(controlScan.lowerBound < coldProof.lowerBound)
        #expect(controlScan.lowerBound < sourceRegistration.lowerBound)
        #expect(sourceRegistration.lowerBound < coldProof.lowerBound)
    }

    @Test("fresh strict cold control starts unknown before real FSEvent promotion")
    func freshStrictColdControlStartsUnknown() {
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let activity = RepositoryActivityClassifier.classify(
            RepositoryActivityClassificationInput(
                repositories: [
                    RepositoryActivityTopology(
                        repositoryID: repositoryID,
                        repositoryStableKey: "strict-cold-control",
                        worktreeStableKeysByID: [worktreeID: "strict-cold-control"]
                    )
                ],
                openWorktreeIDs: [],
                localActivityHydrationDisposition: .authoritative,
                repositoryLocalActivityByStableKey: [:],
                referenceDate: Date(),
                inactivityHorizon: AppPolicies.EntityRecency.applicationActivityHorizon
            )
        )

        #expect(activity.unknownRepositoryIDs == [repositoryID])
        #expect(
            AppDelegate.strictColdRepositoryControlIsEligible(
                repositoryID: repositoryID,
                activity: activity
            )
        )
    }

    @Test("strict cold control accepts only completed remote refresh settlement")
    func strictColdControlAcceptsOnlyCompletedRemoteRefreshSettlement() {
        let repositoryID = UUIDv7.generate()
        let attemptID = UUIDv7.generate()
        let accepted = RepositoryFactUpdateProgress.admitted(
            repoId: repositoryID,
            attemptId: attemptID,
            applicableSources: [.remoteReferences],
            terminalResultsBySource: [:]
        ).settled([.remoteReferences: .completed])
        #expect(AppDelegate.strictRemoteRepositoryUpdateCompleted(accepted))

        let noApplicable = RepositoryFactUpdateProgress.admitted(
            repoId: repositoryID,
            attemptId: attemptID,
            applicableSources: [],
            terminalResultsBySource: [.remoteReferences: .notApplicable]
        )
        #expect(!AppDelegate.strictRemoteRepositoryUpdateCompleted(noApplicable))

        let threeSources = RepositoryFactUpdateProgress.admitted(
            repoId: repositoryID,
            attemptId: attemptID,
            applicableSources: Set(RepositoryFactSource.allCases),
            terminalResultsBySource: [:]
        ).settled(
            Dictionary(
                uniqueKeysWithValues: RepositoryFactSource.allCases.map { ($0, .completed) }
            )
        )
        #expect(!AppDelegate.strictRemoteRepositoryUpdateCompleted(threeSources))

        let failedRemote = RepositoryFactUpdateProgress.admitted(
            repoId: repositoryID,
            attemptId: attemptID,
            applicableSources: [.remoteReferences],
            terminalResultsBySource: [:]
        ).settled([.remoteReferences: .failed])
        #expect(!AppDelegate.strictRemoteRepositoryUpdateCompleted(failedRemote))
    }

    @Test("strict pane fixture creates five tabs and twenty nonterminal pane models")
    func strictPaneFixtureCreatesOnlyNonterminalPaneModels() throws {
        withTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let viewRegistry = ViewRegistry()
            let placeholderFileURL = URL(fileURLWithPath: "/tmp/sidebar-performance-placeholder.txt")

            #expect(
                SidebarPerformanceProofFixture.populateStrictPaneFleet(
                    store: store,
                    viewRegistry: viewRegistry,
                    placeholderFileURL: placeholderFileURL
                )
            )
            #expect(
                store.tabLayoutAtom.tabs.count
                    == AppPolicies.SidebarPerformanceProof.strictTabCount
            )
            let panes = store.paneAtom.paneSnapshot().values
            #expect(panes.count == AppPolicies.SidebarPerformanceProof.strictPaneModelCount)
            #expect(
                panes.allSatisfy { pane in
                    if case .codeViewer(let state) = pane.content {
                        return state.filePath == placeholderFileURL
                    }
                    return false
                }
            )
        }
    }

}

private actor SidebarHistoricalActivityDemandReceiver {
    private var snapshot: RepositoryFactDemandSnapshot?

    func receive(_ snapshot: RepositoryFactDemandSnapshot) {
        self.snapshot = snapshot
    }

    func lastSnapshot() -> RepositoryFactDemandSnapshot? {
        snapshot
    }
}

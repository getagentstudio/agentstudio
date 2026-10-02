import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct WorkspaceBridgeConstructionIntegrationTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("actual Bridge view factory gives two panes File authority from one application coordinator")
        func bridgeViewFactoryInjectsOneApplicationCoordinator() async throws {
            // Arrange
            let constructionCoordinator = BridgeWorktreeProductConstructionCoordinator()
            let harness = makeBridgePaneActivityTestHarness(
                worktreeProductConstructionCoordinator: constructionCoordinator
            )
            let setup = try makeTwoPaneWorktreeSetup(in: harness)
            enterForegroundNativeEnvironment(harness)

            // Act
            let firstView = harness.coordinator.createBridgePaneView(
                for: setup.firstPane,
                state: setup.state
            )
            let secondView = harness.coordinator.createBridgePaneView(
                for: setup.secondPane,
                state: setup.state
            )

            // Assert
            #expect(
                harness.coordinator.worktreeProductConstructionCoordinator
                    === constructionCoordinator
            )
            try await expectAvailableFileSource(
                from: firstView.controller,
                repoId: setup.repoId,
                worktreeId: setup.worktree.id
            )
            try await expectAvailableFileSource(
                from: secondView.controller,
                repoId: setup.repoId,
                worktreeId: setup.worktree.id
            )

            await harness.finish()
        }

        @Test("steady-state Bridge creation registers its filesystem projection context")
        func steadyStateBridgeCreationRegistersFilesystemProjectionContext() async throws {
            // Arrange
            let harness = makeBridgePaneActivityTestHarness()
            let setup = try makeTwoPaneWorktreeSetup(in: harness)
            let affectedKeyCountBefore = harness.coordinator.filesystemAffectedKeyRequestCount

            // Act
            let mountedView = harness.coordinator.createViewForContent(pane: setup.firstPane)

            // Assert
            #expect(mountedView != nil)
            #expect(
                harness.coordinator.filesystemAffectedKeyRequestCount
                    == affectedKeyCountBefore + 1
            )
            let update = try #require(
                harness.coordinator.pendingFilesystemPaneUpdatesByPaneId[setup.firstPane.id]
            )
            guard case .upsert(let entry) = update.kind else {
                Issue.record("Steady-state Bridge mount did not upsert its filesystem context")
                await harness.finish()
                return
            }
            #expect(entry.paneId == setup.firstPane.id)
            #expect(entry.repoId == setup.repoId)
            #expect(entry.worktreeId == setup.worktree.id)
            #expect(
                entry.cwd
                    == URL(
                        filePath: setup.worktree.path.path,
                        directoryHint: .isDirectory
                    )
            )

            await harness.finish()
        }

        @Test("create-before-tab Bridge Review waits for accepted Review mode after foreground promotion")
        func createBeforeTabBridgeReviewWaitsForAcceptedModeAfterForegroundPromotion() async throws {
            // Arrange
            let harness = makeBridgePaneActivityTestHarness()
            let repo = harness.store.addRepo(
                at: harness.tempDirectory.appending(path: "create-before-tab-review-repo")
            )
            let worktree = try #require(
                harness.store.repo(repo.id)?.worktrees.first(where: { $0.isMainWorktree })
            )
            let state = BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: worktree.path.path,
                    baseline: .unstaged)
            )
            let pane = makeBridgePane(
                title: "Create-before-tab Review",
                repo: repo,
                worktree: worktree,
                state: state,
                store: harness.store
            )
            let comparisonGate = BridgeComparisonGate()
            let reviewProvider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "create-before-tab-base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "create-before-tab-head", kind: .workingTree),
                    changedFiles: [
                        makeBridgeEndpointChangedFile(
                            fileId: "create-before-tab-item",
                            path: "Sources/CreateBeforeTab.swift",
                            sizeBytes: 100
                        )
                    ]
                ),
                contentByHandleId: [:],
                comparisonGate: comparisonGate
            )
            harness.viewRegistry.ensureSlot(for: pane.id)
            harness.coordinator.bridgeReviewSourceProviderOverridesByPaneId[pane.id] = reviewProvider
            enterForegroundNativeEnvironment(harness)

            // Act — install and schedule the coordinator view before the pane owns a tab.
            let view = harness.coordinator.createBridgePaneView(for: pane, state: state)

            // Assert — loaded-hidden retains the initial intake without entering the provider.
            #expect(harness.coordinator.bridgePaneActivity(for: pane.id) == .loadedHidden)
            #expect(view.controller.activeReviewRefreshTask == nil)
            #expect(await reviewProvider.recordedComparisonRequestsCount() == 0)
            #expect(view.controller.paneState.diff.packageMetadata == nil)

            // Act — tab ownership promotes activity but does not choose a viewer mode.
            let tab = Tab(paneId: pane.id, name: "Create-before-tab Review")
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            await expectBridgePaneActivity(
                .foreground,
                for: pane.id,
                in: harness.coordinator,
                because: "the newly activated create-before-tab Review tab became visible"
            )

            // Assert — foreground promotion alone still admits no Review construction.
            #expect(view.controller.activeReviewRefreshTask == nil)
            #expect(await reviewProvider.recordedComparisonRequestsCount() == 0)

            // Act — the committed initial Review mode is the construction admission.
            let productAdmission = try #require(view.controller.productAdmissionGate.acquire())
            await view.controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "create-before-tab-product-session",
                sequence: 1,
                mode: .review,
                activeSource: nil,
                productAdmission: productAdmission
            )
            await comparisonGate.waitForStartedComparisonCount(1)
            await comparisonGate.releaseAll()
            await waitForActiveReviewRefreshTaskToFinish(view.controller)

            // Assert
            #expect(await reviewProvider.recordedComparisonRequestsCount() == 1)
            #expect(view.controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity == .foreground)
            #expect(
                view.controller.paneState.diff.packageMetadata?.orderedItemIds
                    == ["item-create-before-tab-item"]
            )

            await harness.finish()
        }

        @Test("production Review open waits for the committed initial Review mode")
        func productionReviewOpenWaitsForCommittedInitialReviewMode() async throws {
            // Arrange
            let repositoryURL = try await FilesystemTestGitRepo.create(
                named: "bridge-production-review-open-activity"
            )
            defer { FilesystemTestGitRepo.destroy(repositoryURL) }
            try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
            let defaultTargetOID = try await FilesystemTestGitRepo.runGit(
                at: repositoryURL,
                args: ["rev-parse", "HEAD"]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try await FilesystemTestGitRepo.runGit(
                at: repositoryURL,
                args: ["update-ref", "refs/remotes/origin/main", defaultTargetOID]
            )
            try await FilesystemTestGitRepo.runGit(
                at: repositoryURL,
                args: ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"]
            )
            let harness = makeBridgePaneActivityTestHarness()
            let repo = harness.store.addRepo(at: repositoryURL)
            let worktree = try #require(
                harness.store.repo(repo.id)?.worktrees.first(where: { $0.isMainWorktree })
            )
            enterForegroundNativeEnvironment(harness)

            // Act
            let pane = try #require(
                harness.coordinator.openBridgeReviewInNewTab(worktreeId: worktree.id)
            )
            let controller = try #require(
                harness.viewRegistry.allBridgeViews[pane.id]?.controller
            )

            // Assert — pane creation establishes activity but does not choose a metadata mode.
            guard case .bridgePanel(let persistedBridgeState) = harness.store.pane(pane.id)?.content,
                case .workspace(_, let comparisonIntent) = persistedBridgeState.source
            else {
                Issue.record("Production Review open did not persist a workspace Bridge source")
                await harness.finish()
                return
            }
            #expect(
                comparisonIntent == nil
            )
            #expect(harness.coordinator.bridgePaneActivity(for: pane.id) == .foreground)
            #expect(controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity == .foreground)
            #expect(controller.activeReviewRefreshTask == nil)
            #expect(controller.paneState.diff.packageMetadata == nil)

            // Act — the committed null-source Review mode admits initial construction.
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "production-review-open-product-session",
                sequence: 1,
                mode: .review,
                activeSource: nil,
                productAdmission: productAdmission
            )

            // Assert
            let admittedReviewTask = controller.activeReviewRefreshTask
            #expect(admittedReviewTask != nil)
            await admittedReviewTask?.value
            await waitForActiveReviewRefreshTaskToFinish(controller)
            #expect(controller.paneState.diff.status == .ready)
            #expect(controller.paneState.diff.packageMetadata != nil)

            await harness.finish()
        }

        @Test("production File View open starts without a fabricated comparison target")
        func productionFileViewOpenStartsWithoutComparisonTarget() async throws {
            // Arrange
            let repositoryURL = try await FilesystemTestGitRepo.create(
                named: "bridge-production-file-open-comparison-intent"
            )
            defer { FilesystemTestGitRepo.destroy(repositoryURL) }
            try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
            let harness = makeBridgePaneActivityTestHarness()
            let repo = harness.store.addRepo(at: repositoryURL)
            let worktree = try #require(
                harness.store.repo(repo.id)?.worktrees.first(where: { $0.isMainWorktree })
            )
            enterForegroundNativeEnvironment(harness)

            // Act
            let pane = try #require(
                harness.coordinator.openBridgeFilesInNewTab(worktreeId: worktree.id)
            )

            // Assert
            guard case .bridgePanel(let persistedBridgeState) = harness.store.pane(pane.id)?.content,
                case .workspace(_, let comparisonIntent) = persistedBridgeState.source
            else {
                Issue.record("Production File View open did not persist a workspace Bridge source")
                await harness.finish()
                return
            }
            #expect(
                comparisonIntent == nil
            )
            let controller = try #require(
                harness.viewRegistry.allBridgeViews[pane.id]?.controller
            )
            #expect(controller.activeReviewRefreshTask == nil)
            #expect(controller.paneState.diff.packageMetadata == nil)

            await harness.finish()
        }

        @Test("topology replay repairs an active restored Review controller created before topology")
        func topologyReplayRepairsActiveRestoredReviewController() async throws {
            // Arrange
            let repositoryURL = try await FilesystemTestGitRepo.create(
                named: "bridge-restored-review-topology-replay"
            )
            defer { FilesystemTestGitRepo.destroy(repositoryURL) }
            try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
            try await withBridgeConstructionCommandHarness { harness, executor in
                let state = BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: repositoryURL.path,
                        baseline: .unstaged)
                )
                let pane = harness.store.createPane(
                    content: .bridgePanel(state),
                    metadata: PaneMetadata(
                        contentType: .diff,
                        launchDirectory: repositoryURL,
                        title: "Restored Review before topology"
                    )
                )
                harness.viewRegistry.ensureSlot(for: pane.id)
                let reviewProvider = BridgeReviewSourceProviderFake(
                    comparison: BridgeEndpointComparison(
                        baseEndpoint: makeBridgeEndpoint(
                            endpointId: "restored-topology-base",
                            kind: .gitRef
                        ),
                        headEndpoint: makeBridgeEndpoint(
                            endpointId: "restored-topology-head",
                            kind: .workingTree
                        ),
                        changedFiles: [
                            makeBridgeEndpointChangedFile(
                                fileId: "restored-topology-item",
                                path: "Sources/RestoredTopology.swift",
                                sizeBytes: 100
                            )
                        ]
                    ),
                    contentByHandleId: [:]
                )
                harness.coordinator.bridgeReviewSourceProviderOverridesByPaneId[pane.id] = reviewProvider
                let tab = Tab(paneId: pane.id, name: "Restored Review before topology")
                harness.store.appendTab(tab)
                harness.store.setActiveTab(tab.id)
                enterForegroundNativeEnvironment(harness)
                let initialView = harness.coordinator.createBridgePaneView(for: pane, state: state)

                // Assert — initial construction cannot acquire worktree-scoped Review work.
                #expect(initialView.controller.runtime.metadata.repoId == nil)
                #expect(initialView.controller.runtime.metadata.worktreeId == nil)
                #expect(initialView.controller.activeReviewRefreshTask == nil)
                #expect(initialView.controller.paneState.diff.packageMetadata == nil)
                #expect(await reviewProvider.recordedComparisonRequestsCount() == 0)

                // Act — repository topology restoration completes after the pane was mounted.
                let restoredRepo = harness.store.addRepo(at: repositoryURL)
                let restoredWorktree = try #require(
                    harness.store.repo(restoredRepo.id)?.worktrees.first(where: { $0.isMainWorktree })
                )
                harness.coordinator.repairRestoredBridgePanesAfterInitialTopologyReplay()
                _ = await executor.submitGesture { _ in true }.value
                await harness.coordinator.drainBridgePaneRetirements()
                let replacementController = try #require(
                    harness.viewRegistry.allBridgeViews[pane.id]?.controller
                )

                // Assert — topology repair restores identity but does not choose Review.
                #expect(replacementController !== initialView.controller)
                #expect(replacementController.runtime.metadata.repoId == restoredRepo.id)
                #expect(replacementController.runtime.metadata.worktreeId == restoredWorktree.id)
                #expect(replacementController.activeReviewRefreshTask == nil)
                #expect(replacementController.paneState.diff.packageMetadata == nil)
                #expect(await reviewProvider.recordedComparisonRequestsCount() == 0)

                // Act — the repaired pane starts Review only after its committed mode arrives.
                let productAdmission = try #require(
                    replacementController.productAdmissionGate.acquire()
                )
                await replacementController.handleCommittedProductActiveViewerModeUpdate(
                    sessionId: "restored-topology-product-session",
                    sequence: 1,
                    mode: .review,
                    activeSource: nil,
                    productAdmission: productAdmission
                )
                await waitForActiveReviewRefreshTaskToFinish(replacementController)

                // Assert — accepted Review mode uses the reconstructed immutable provider identity.
                #expect(replacementController.paneState.diff.status == .ready)
                #expect(replacementController.paneState.diff.packageMetadata != nil)
                #expect(await reviewProvider.recordedComparisonRequestsCount() == 1)

                // Act — the one-shot replay hook is idempotent after identity is repaired.
                harness.coordinator.repairRestoredBridgePanesAfterInitialTopologyReplay()
                _ = await executor.submitGesture { _ in true }.value
                await harness.coordinator.drainBridgePaneRetirements()
                let stableController = try #require(
                    harness.viewRegistry.allBridgeViews[pane.id]?.controller
                )

                // Assert — no second reconstruction or Review package build is admitted.
                #expect(stableController === replacementController)
                #expect(await reviewProvider.recordedComparisonRequestsCount() == 1)
            }
        }

        @Test("one worktree freshness advance precedes invalidation fan-out to both panes")
        func freshnessAdvancesOnceBeforePaneFanOut() async throws {
            // Arrange
            let eventProbe = BridgeWorktreeProductConstructionEventProbe()
            let constructionCoordinator = BridgeWorktreeProductConstructionCoordinator(
                eventSink: eventProbe.eventSink
            )
            let harness = makeBridgePaneActivityTestHarness(
                worktreeProductConstructionCoordinator: constructionCoordinator
            )
            let setup = try makeTwoPaneWorktreeSetup(in: harness)
            enterForegroundNativeEnvironment(harness)
            let firstView = harness.coordinator.createBridgePaneView(
                for: setup.firstPane,
                state: setup.state
            )
            let secondView = harness.coordinator.createBridgePaneView(
                for: setup.secondPane,
                state: setup.state
            )
            await registerFilesystemProjectionContexts(
                for: [setup.firstPane, setup.secondPane],
                in: harness
            )
            // G2 retains hidden Review invalidations; only the foreground native fixture shows Review.
            try await showReviewInNativeFixture(secondView.controller)
            await waitForActiveReviewRefreshTaskToFinish(secondView.controller)
            let owner = BridgeWorktreeProductOwnerKey(
                repoIdentity: setup.repoId.uuidString,
                worktreeIdentity: setup.worktree.id.uuidString,
                stableRootIdentity: StableKey.fromPath(setup.worktree.path),
                providerIdentity: "integration-provider"
            )
            let key = makeBridgeReviewConstructionKey(owner: owner)
            let gate = BridgeWorktreeProductConstructionGate(
                artifact: makeBridgeReviewConstructionArtifact()
            )
            let oldAcquisition = Task {
                try await constructionCoordinator.acquire(key: key, build: gate.run)
            }
            await gate.waitUntilStarted()
            let changeset = FileChangeset(
                worktreeId: setup.worktree.id,
                repoId: setup.repoId,
                rootPath: setup.worktree.path,
                paths: ["Sources/Changed.swift"],
                timestamp: .now,
                batchSeq: 1
            )

            // Act
            _ = await harness.coordinator.handleFilesystemEnvelopeIfNeeded(
                RuntimeEnvelopeHarness.filesystemEnvelope(
                    event: .filesChanged(changeset: changeset),
                    repoId: setup.repoId,
                    worktreeId: setup.worktree.id
                )
            )
            let oldResult = await oldAcquisition.result
            await gate.release(invocation: 1)
            _ = await eventProbe.waitFor(.staleCompletionDropped)
            let currentAcquisition = Task {
                try await constructionCoordinator.acquire(key: key, build: gate.run)
            }
            await gate.waitUntilStarted(count: 2)
            await gate.release(invocation: 2)
            let currentLease = try await currentAcquisition.value

            // Assert
            guard case .failure(let oldError) = oldResult else {
                Issue.record("The stale pre-envelope construction unexpectedly published")
                return
            }
            #expect(oldError as? BridgeWorktreeProductConstructionError == .invalidated)
            #expect(currentLease.epoch.rawValue == 2)
            #expect(await gate.recordedInvocationCount() == 2)
            let hiddenPaneRefresh =
                firstView.controller.refreshAdmissionCoordinator.diagnosticSnapshot
            let foregroundPaneRefresh =
                secondView.controller.refreshAdmissionCoordinator.diagnosticSnapshot
            #expect(hiddenPaneRefresh.dirtyFact?.filePaths == ["Sources/Changed.swift"])
            #expect(hiddenPaneRefresh.refreshPassCount == 0)
            #expect(foregroundPaneRefresh.dirtyFact == nil)
            #expect(foregroundPaneRefresh.refreshPassCount == 2)

            await constructionCoordinator.release(currentLease)
            await harness.finish()
        }

        @Test("workspace shutdown closes and physically drains shared construction")
        func workspaceShutdownClosesAndDrainsConstruction() async throws {
            // Arrange
            let constructionCoordinator = BridgeWorktreeProductConstructionCoordinator()
            let harness = makeBridgePaneActivityTestHarness(
                worktreeProductConstructionCoordinator: constructionCoordinator
            )
            let gate = BridgeWorktreeProductConstructionGate(
                artifact: makeBridgeReviewConstructionArtifact()
            )
            let acquisition = Task {
                try await constructionCoordinator.acquire(
                    key: makeBridgeReviewConstructionKey(),
                    build: gate.run
                )
            }
            await gate.waitUntilStarted()

            // Act
            let workspaceShutdown = Task { @MainActor in
                await harness.coordinator.shutdown()
            }
            let acquisitionResult = await acquisition.result

            // Assert
            guard case .failure(let error) = acquisitionResult else {
                Issue.record("Workspace shutdown unexpectedly published shared construction")
                return
            }
            #expect(error as? BridgeWorktreeProductConstructionError == .coordinatorClosed)
            let drainingSnapshot = await constructionCoordinator.snapshot()
            #expect(drainingSnapshot.inFlightCount == 1)
            #expect(drainingSnapshot.drainingTombstoneCount == 1)

            await gate.release()
            await workspaceShutdown.value
            await assertBridgeConstructionCoordinatorDrained(constructionCoordinator)
            try? FileManager.default.removeItem(at: harness.tempDirectory)
        }

        @Test("matching Git snapshot advances the canonical worktree freshness")
        func matchingGitSnapshotAdvancesFreshness() async throws {
            // Arrange
            let eventProbe = BridgeWorktreeProductConstructionEventProbe()
            let constructionCoordinator = BridgeWorktreeProductConstructionCoordinator(
                eventSink: eventProbe.eventSink
            )
            let harness = makeBridgePaneActivityTestHarness(
                worktreeProductConstructionCoordinator: constructionCoordinator
            )
            let setup = try makeTwoPaneWorktreeSetup(in: harness)
            await registerFilesystemProjectionContexts(
                for: [setup.firstPane, setup.secondPane],
                in: harness
            )
            let owner = BridgeWorktreeProductOwnerKey(
                repoIdentity: setup.repoId.uuidString,
                worktreeIdentity: setup.worktree.id.uuidString,
                stableRootIdentity: StableKey.fromPath(setup.worktree.path),
                providerIdentity: "snapshot-integration-provider"
            )
            let key = makeBridgeReviewConstructionKey(owner: owner)
            let gate = BridgeWorktreeProductConstructionGate(
                artifact: makeBridgeReviewConstructionArtifact()
            )
            let oldAcquisition = Task {
                try await constructionCoordinator.acquire(key: key, build: gate.run)
            }
            await gate.waitUntilStarted()

            // Act
            _ = await harness.coordinator.handleFilesystemEnvelopeIfNeeded(
                RuntimeEnvelopeHarness.gitEnvelope(
                    event: .snapshotChanged(
                        snapshot: GitWorkingTreeSnapshot(
                            worktreeId: setup.worktree.id,
                            repoId: setup.repoId,
                            rootPath: setup.worktree.path,
                            summary: .init(changed: 1, staged: 0, untracked: 0),
                            branch: "feature/shared-construction"
                        )
                    ),
                    repoId: setup.repoId,
                    worktreeId: setup.worktree.id,
                    observationLifetime: .worktree(
                        try #require(
                            harness.store.repositoryTopologyAtom.worktreeObservationLifetimes[setup.worktree.id]))
                )
            )
            let oldResult = await oldAcquisition.result
            await gate.release(invocation: 1)
            _ = await eventProbe.waitFor(.staleCompletionDropped)
            let currentAcquisition = Task {
                try await constructionCoordinator.acquire(key: key, build: gate.run)
            }
            await gate.waitUntilStarted(count: 2)
            await gate.release(invocation: 2)
            let currentLease = try await currentAcquisition.value

            // Assert
            guard case .failure(let oldError) = oldResult else {
                Issue.record("The pre-snapshot construction unexpectedly published")
                return
            }
            #expect(oldError as? BridgeWorktreeProductConstructionError == .invalidated)
            #expect(currentLease.epoch.rawValue == 2)

            await constructionCoordinator.release(currentLease)
            await harness.finish()
        }

        @Test("unresolved topology does not invent a worktree construction identity")
        func unresolvedTopologyDoesNotAdvanceFreshness() async throws {
            // Arrange
            let constructionCoordinator = BridgeWorktreeProductConstructionCoordinator()
            let harness = makeBridgePaneActivityTestHarness(
                worktreeProductConstructionCoordinator: constructionCoordinator
            )
            let repoId = UUID()
            let worktreeId = UUID()
            let rootPath = harness.tempDirectory.appending(path: "unresolved-worktree")
            let owner = BridgeWorktreeProductOwnerKey(
                repoIdentity: repoId.uuidString,
                worktreeIdentity: worktreeId.uuidString,
                stableRootIdentity: StableKey.fromPath(rootPath),
                providerIdentity: "unresolved-integration-provider"
            )
            let key = makeBridgeReviewConstructionKey(owner: owner)
            let gate = BridgeWorktreeProductConstructionGate(
                artifact: makeBridgeReviewConstructionArtifact()
            )
            let acquisition = Task {
                try await constructionCoordinator.acquire(key: key, build: gate.run)
            }
            await gate.waitUntilStarted()

            // Act
            _ = await harness.coordinator.handleFilesystemEnvelopeIfNeeded(
                RuntimeEnvelopeHarness.filesystemEnvelope(
                    event: .filesChanged(
                        changeset: FileChangeset(
                            worktreeId: worktreeId,
                            repoId: repoId,
                            rootPath: rootPath,
                            paths: ["Sources/Unresolved.swift"],
                            timestamp: .now,
                            batchSeq: 1
                        )
                    ),
                    repoId: repoId,
                    worktreeId: worktreeId
                )
            )
            await gate.release()
            let lease = try await acquisition.value

            // Assert
            #expect(lease.epoch.rawValue == 1)
            #expect(await gate.recordedInvocationCount() == 1)

            await constructionCoordinator.release(lease)
            await harness.finish()
        }
    }
}

@MainActor
private func registerFilesystemProjectionContexts(
    for panes: [Pane],
    in harness: BridgePaneActivityTestHarness
) async {
    for pane in panes {
        harness.coordinator.upsertPaneFilesystemProjectionContext(for: pane)
    }
    await harness.coordinator.syncFilesystemRootsAndActivityUntilIdle()
}

private struct TwoPaneWorktreeSetup {
    let repoId: UUID
    let worktree: Worktree
    let state: BridgePaneState
    let firstPane: Pane
    let secondPane: Pane
}

@MainActor
private func makeTwoPaneWorktreeSetup(
    in harness: BridgePaneActivityTestHarness
) throws -> TwoPaneWorktreeSetup {
    let repositoryURL = harness.tempDirectory.appending(path: "shared-construction-repo")
    // C2 validates File roots before minting source authority; this fixture owns a healthy root.
    try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    let repo = harness.store.addRepo(at: repositoryURL)
    let worktree = try #require(
        harness.store.repo(repo.id)?.worktrees.first(where: { $0.isMainWorktree })
    )
    let state = BridgePaneState(
        panelKind: .diffViewer,
        source: .workspace(
            rootPath: worktree.path.path,
            baseline: .unstaged)
    )
    let firstPane = makeBridgePane(
        title: "First shared construction pane",
        repo: repo,
        worktree: worktree,
        state: state,
        store: harness.store
    )
    let secondPane = makeBridgePane(
        title: "Second shared construction pane",
        repo: repo,
        worktree: worktree,
        state: state,
        store: harness.store
    )
    harness.viewRegistry.ensureSlot(for: firstPane.id)
    harness.viewRegistry.ensureSlot(for: secondPane.id)
    harness.store.appendTab(Tab(paneId: firstPane.id, name: "First shared construction pane"))
    let secondTab = Tab(paneId: secondPane.id, name: "Second shared construction pane")
    harness.store.appendTab(secondTab)
    harness.store.setActiveTab(secondTab.id)
    return TwoPaneWorktreeSetup(
        repoId: repo.id,
        worktree: worktree,
        state: state,
        firstPane: firstPane,
        secondPane: secondPane
    )
}

@MainActor
private func makeBridgePane(
    title: String,
    repo: Repo,
    worktree: Worktree,
    state: BridgePaneState,
    store: WorkspaceStore
) -> Pane {
    store.createPane(
        content: .bridgePanel(state),
        metadata: PaneMetadata(
            contentType: .diff,
            title: title,
            facets: PaneContextFacets(
                repoId: repo.id,
                repoName: repo.name,
                worktreeId: worktree.id,
                worktreeName: worktree.name,
                cwd: worktree.path
            )
        )
    )
}

@MainActor
private func expectAvailableFileSource(
    from controller: BridgePaneController,
    repoId: UUID,
    worktreeId: UUID
) async throws {
    let provider = try #require(controller.productSchemeProvider)
    let request = try bridgeFileSourceCurrentRequest(paneId: controller.paneId)
    let fileSourceResponse = await provider.response(for: request)
    let hasAvailableFileSource =
        if case .callCompleted(let response) = fileSourceResponse,
            case .fileSourceCurrent(.available) = response.call
        { true } else { false }
    #expect(
        hasAvailableFileSource,
        Comment(rawValue: "Expected production-injected File source authority; actual: \(fileSourceResponse)")
    )
    guard case .callCompleted(let response) = fileSourceResponse,
        case .fileSourceCurrent(.available(let source)) = response.call
    else {
        return
    }
    #expect(source.repoId == repoId.uuidString)
    #expect(source.worktreeId == worktreeId.uuidString)
}

private func bridgeFileSourceCurrentRequest(paneId: UUID) throws -> BridgeProductControlRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductControlRequest.self,
        from: JSONSerialization.data(
            withJSONObject: [
                "call": [
                    "method": "file.source.current",
                    "request": [:],
                ],
                "kind": "product.call",
                "paneSessionId": paneId.uuidString,
                "requestId": "shared-construction-source-current",
                "requestSequence": 1,
                "wireVersion": BridgeProductWireContract.version,
                "workerDerivationEpoch": 1,
                "workerInstanceId": "shared-construction-worker",
            ],
            options: [.sortedKeys]
        )
    )
}

@MainActor
private func withBridgeConstructionCommandHarness(
    _ operation: @MainActor (BridgePaneActivityTestHarness, WorkspaceActionExecutor) async throws -> Void
) async throws {
    let harness = makeBridgePaneActivityTestHarness()
    let executor = WorkspaceActionExecutor(coordinator: harness.coordinator, store: harness.store)
    do {
        try await operation(harness, executor)
    } catch {
        await executor.stopAcceptingCommandsAndDrain()
        await harness.finish()
        throw error
    }
    await executor.stopAcceptingCommandsAndDrain()
    await harness.finish()
}

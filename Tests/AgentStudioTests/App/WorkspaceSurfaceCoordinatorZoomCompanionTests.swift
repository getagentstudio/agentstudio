import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct WorkspaceSurfaceCoordinatorZoomCompanionTests {
        init() {
            installTestAtomRegistryIfNeeded()
        }

        @Test("Zoom creates one retained Files companion outside durable workspace membership")
        func createsRetainedFilesCompanionOutsideDurableMembership() async throws {
            let harness = makeZoomCompanionHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: harness.worktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.setActiveTab(sourceTab.id)
            harness.store.panePresentationAtom.enterZoom(
                inTab: sourceTab.id,
                sourcePaneId: sourcePane.id,
                viewerPresentation: .retryable
            )

            let presentation = harness.coordinator.reconcileZoomCompanion(
                sourcePaneId: sourcePane.id,
                owningTabId: sourceTab.id
            )
            let companionPaneId = try #require(presentation.companionPaneId)

            #expect(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)
                    == ZoomCompanionMetadata(
                        owningTabId: sourceTab.id,
                        resolvedWorktreeId: harness.worktree.id,
                        companionPaneId: companionPaneId,
                        lastZoomVisibility: .visible
                    )
            )
            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation == .retainedVisible(companionPaneId: companionPaneId)
            )
            #expect(harness.viewRegistry.allBridgeViews[companionPaneId] != nil)
            #expect(
                harness.viewRegistry.allBridgeViews[companionPaneId]?.controller.bridgePaneState.panelKind
                    == .fileViewer
            )
            #expect(harness.coordinator.runtimeForPane(PaneId(existingUUID: companionPaneId)) is BridgeRuntime)
            #expect(harness.coordinator.bridgePaneActivity(for: companionPaneId) == .foreground)

            #expect(harness.store.pane(companionPaneId) == nil)
            #expect(!sourceTab.allPaneIds.contains(companionPaneId))
            #expect(
                !harness.store.programmaticControlSnapshot().panes.contains {
                    $0.id == companionPaneId
                }
            )
            #expect(
                harness.coordinator.resolveBridgePaneCommand(worktreeId: harness.worktree.id)?
                    .resolution == .create
            )
            #expect(
                harness.store.tab(sourceTab.id)?.arrangements.allSatisfy {
                    !$0.layout.contains(companionPaneId)
                        && !$0.minimizedPaneIds.contains(companionPaneId)
                } == true
            )

            let retainedHostIdentity = harness.viewRegistry.allBridgeViews[companionPaneId].map(
                ObjectIdentifier.init
            )
            #expect(
                harness.store.panePresentationAtom.setZoomViewerVisible(
                    false,
                    forSourcePane: sourcePane.id
                )
            )
            harness.coordinator.refreshBridgePaneActivities()
            #expect(harness.coordinator.bridgePaneActivity(for: companionPaneId) == .loadedHidden)

            let reconciledPresentation = harness.coordinator.reconcileZoomCompanion(
                sourcePaneId: sourcePane.id,
                owningTabId: sourceTab.id
            )
            #expect(reconciledPresentation == .retainedHidden(companionPaneId: companionPaneId))
            #expect(
                harness.viewRegistry.allBridgeViews[companionPaneId].map(ObjectIdentifier.init)
                    == retainedHostIdentity
            )

            await harness.coordinator.shutdown()
        }

        @Test("Zoom companion retains its selected comparison while hidden")
        func zoomCompanionRetainsSelectedComparisonWhileHidden() async throws {
            // Arrange
            let harness = makeZoomCompanionHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: harness.worktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.panePresentationAtom.enterZoom(
                inTab: sourceTab.id,
                sourcePaneId: sourcePane.id,
                viewerPresentation: .retryable
            )
            let presentation = harness.coordinator.reconcileZoomCompanion(
                sourcePaneId: sourcePane.id,
                owningTabId: sourceTab.id
            )
            let companionPaneId = try #require(presentation.companionPaneId)
            let mountedView = try #require(harness.viewRegistry.allBridgeViews[companionPaneId])
            let productAdmission = try #require(
                mountedView.controller.productAdmissionGate.acquire()
            )
            let selectedTarget = WorkspaceReviewContributionTarget.branch(name: "stack/base")
            _ = productAdmission.withValidAdmission {
                mountedView.controller.refreshAdmissionCoordinator.workAdmissionSource
                    .admitReviewComparisonIntent(
                        workerDerivationEpoch: 1,
                        productAdmission: productAdmission
                    )
            }

            // Act
            let didApplyTarget = await mountedView.controller
                .handleCommittedProductReviewComparisonUpdate(
                    BridgeProductReviewComparisonUpdateRequest(target: selectedTarget),
                    workerDerivationEpoch: 1,
                    productAdmission: productAdmission
                )
            #expect(didApplyTarget == .applied)
            #expect(
                harness.store.panePresentationAtom.setZoomViewerVisible(
                    false,
                    forSourcePane: sourcePane.id
                )
            )
            let hiddenPresentation = harness.coordinator.reconcileZoomCompanion(
                sourcePaneId: sourcePane.id,
                owningTabId: sourceTab.id
            )

            // Assert
            #expect(didApplyTarget == .applied)
            #expect(hiddenPresentation == .retainedHidden(companionPaneId: companionPaneId))
            #expect(
                mountedView.controller.bridgePaneState.source
                    == .workspace(
                        rootPath: harness.worktree.path.path,
                        baseline: WorkspaceBaseline(contributionTarget: selectedTarget)
                    )
            )
            #expect(harness.store.pane(companionPaneId) == nil)

            await harness.coordinator.shutdown()
        }

        @Test("Zoom companion ignores cached checkout and starts without a comparison target")
        func zoomCompanionStartsWithoutTargetWhenCheckoutIsCached() async throws {
            let harness = makeZoomCompanionHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let repo = try #require(
                harness.store.repositoryTopologyAtom.repo(containing: harness.worktree.id)
            )
            let mainWorktree = try #require(
                repo.worktrees.first { $0.isMainWorktree }
            )
            atom(\.repoCache).setWorktreeEnrichment(
                WorktreeEnrichment(
                    worktreeId: mainWorktree.id,
                    repoId: repo.id,
                    branch: "master",
                    isMainWorktree: true
                )
            )
            defer { atom(\.repoCache).removeWorktree(mainWorktree.id) }
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: harness.worktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.panePresentationAtom.enterZoom(
                inTab: sourceTab.id,
                sourcePaneId: sourcePane.id,
                viewerPresentation: .retryable
            )

            let presentation = harness.coordinator.reconcileZoomCompanion(
                sourcePaneId: sourcePane.id,
                owningTabId: sourceTab.id
            )
            let companionPaneId = try #require(presentation.companionPaneId)
            let companionState = try #require(
                harness.viewRegistry.allBridgeViews[companionPaneId]?.controller.bridgePaneState
            )

            guard case .workspace(_, let comparisonIntent) = companionState.source else {
                Issue.record("Expected Zoom companion to use a workspace source")
                await harness.coordinator.shutdown()
                return
            }
            #expect(
                comparisonIntent == nil
            )

            await harness.coordinator.shutdown()
        }

        @Test("Zoom companion starts without a comparison target when checkout enrichment is absent")
        func zoomCompanionStartsWithoutTargetWhenCheckoutEnrichmentIsAbsent() async throws {
            let harness = makeZoomCompanionHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: harness.worktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.panePresentationAtom.enterZoom(
                inTab: sourceTab.id,
                sourcePaneId: sourcePane.id,
                viewerPresentation: .retryable
            )

            let presentation = harness.coordinator.reconcileZoomCompanion(
                sourcePaneId: sourcePane.id,
                owningTabId: sourceTab.id
            )
            let companionPaneId = try #require(presentation.companionPaneId)
            let companionState = try #require(
                harness.viewRegistry.allBridgeViews[companionPaneId]?.controller.bridgePaneState
            )

            guard case .workspace(_, let comparisonIntent) = companionState.source else {
                Issue.record("Expected Zoom companion to use a workspace source")
                await harness.coordinator.shutdown()
                return
            }
            #expect(
                comparisonIntent == nil
            )

            await harness.coordinator.shutdown()
        }

        @Test("Zoom command creates Files, cancel retains it hidden, and re-entry resumes the same host")
        func zoomCommandCreatesRetainsAndResumesCompanion() async throws {
            let owningWindowId = UUID()
            let harness = makeHarness(workspaceWindowId: owningWindowId)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let (_, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: worktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.setActiveTab(sourceTab.id)
            harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
            harness.coordinator.startBridgePaneActivityObservation()
            harness.appLifecycleStore.setActive(true)
            harness.windowLifecycleStore.recordWindowRegistered(owningWindowId)
            harness.windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(
                    isVisible: true,
                    isMiniaturized: false,
                    isOccluded: false
                ),
                for: owningWindowId
            )

            await harness.executeCommand(.zoomPane)

            let enteredPresentation = try #require(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)
            )
            let companionPaneId = try #require(enteredPresentation.viewerPresentation.companionPaneId)
            let retainedHostIdentity = try #require(
                harness.viewRegistry.allBridgeViews[companionPaneId].map(ObjectIdentifier.init)
            )
            #expect(
                harness.viewRegistry.allBridgeViews[companionPaneId]?.controller.bridgePaneState.panelKind
                    == .fileViewer
            )
            #expect(harness.coordinator.bridgePaneActivity(for: companionPaneId) == .foreground)

            await harness.executeCommand(.zoomPane)

            #expect(harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id) == nil)
            #expect(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?
                    .companionPaneId == companionPaneId
            )
            #expect(
                harness.viewRegistry.allBridgeViews[companionPaneId].map(ObjectIdentifier.init)
                    == retainedHostIdentity
            )
            #expect(harness.coordinator.bridgePaneActivity(for: companionPaneId) == .loadedHidden)

            await harness.executeCommand(.zoomPane)

            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation == .retainedVisible(companionPaneId: companionPaneId)
            )
            #expect(
                harness.viewRegistry.allBridgeViews[companionPaneId].map(ObjectIdentifier.init)
                    == retainedHostIdentity
            )
            #expect(harness.coordinator.bridgePaneActivity(for: companionPaneId) == .foreground)

            await harness.coordinator.shutdown()
        }

        @Test("home-fallback Zoom source keeps Viewer hidden without borrowing the only worktree")
        func homeFallbackZoomSourceDoesNotBorrowOnlyRegisteredWorktree() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let repository = harness.store.addRepo(
                at: harness.tempDir.appending(path: "only-repository")
            )
            let onlyWorktree = try #require(repository.worktrees.single)
            let sourcePane = harness.store.createPane()
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.setActiveTab(sourceTab.id)
            harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)

            #expect(
                harness.store.repositoryTopologyAtom.repos.flatMap(\.worktrees).map(\.id)
                    == [onlyWorktree.id]
            )
            #expect(sourcePane.parentPaneId == nil)
            #expect(sourcePane.worktreeId == nil)
            #expect(sourcePane.metadata.cwd == FileManager.default.homeDirectoryForCurrentUser)

            await harness.executeCommand(.zoomPane)

            let companion = harness.store.panePresentationAtom.zoomCompanion(
                forSourcePane: sourcePane.id
            )
            #expect(companion == nil)
            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation == .unavailable
            )
            #expect(harness.viewRegistry.allBridgeViews.isEmpty)

            await harness.coordinator.shutdown()
        }

        @Test("live CWD retargets a visible Review companion between registered worktrees")
        func liveCWDRetargetsVisibleReviewCompanion() async throws {
            let paneEventBus = makeTestPaneRuntimeEventBus()
            let harness = makeHarness(paneEventBus: paneEventBus)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let (_, sourceWorktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let (_, destinationWorktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: sourceWorktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.setActiveTab(sourceTab.id)
            harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
            await harness.executeCommand(.zoomPane)
            let originalCompanionPaneId = try #require(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?
                    .companionPaneId
            )
            #expect(
                harness.coordinator.requestBridgePaneSurface(
                    .review,
                    paneId: originalCompanionPaneId
                )
            )
            #expect(
                harness.viewRegistry.allBridgeViews[originalCompanionPaneId]?.controller
                    .retainedViewerSurface == .review
            )

            await postCWDChange(
                destinationWorktree.path.appending(path: "Sources"),
                paneId: sourcePane.id,
                to: paneEventBus
            )
            await eventually("Zoom companion should retarget to the destination worktree") {
                guard
                    let replacement = harness.store.panePresentationAtom.zoomCompanion(
                        forSourcePane: sourcePane.id
                    )
                else {
                    return false
                }
                return replacement.resolvedWorktreeId == destinationWorktree.id
                    && replacement.companionPaneId != originalCompanionPaneId
            }

            let replacementCompanionPaneId = try #require(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?
                    .companionPaneId
            )
            await harness.coordinator.drainBridgePaneRetirements()

            #expect(harness.viewRegistry.allBridgeViews[originalCompanionPaneId] == nil)
            #expect(
                harness.coordinator.runtimeForPane(
                    PaneId(existingUUID: originalCompanionPaneId)
                ) == nil
            )
            #expect(
                harness.viewRegistry.allBridgeViews[replacementCompanionPaneId]?.controller
                    .retainedViewerSurface == .review
            )
            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation
                    == .retainedVisible(companionPaneId: replacementCompanionPaneId)
            )

            await harness.coordinator.shutdown()
        }

        @Test("leaving registered worktrees retires stale Viewer content and shows unavailable")
        func leavingRegisteredWorktreesShowsUnavailableWithoutStaleContent() async throws {
            let paneEventBus = makeTestPaneRuntimeEventBus()
            let harness = makeHarness(paneEventBus: paneEventBus)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let (_, sourceWorktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: sourceWorktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.setActiveTab(sourceTab.id)
            harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
            await harness.executeCommand(.zoomPane)
            let originalCompanionPaneId = try #require(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?
                    .companionPaneId
            )

            await postCWDChange(
                harness.tempDir.appending(path: "unwatched"),
                paneId: sourcePane.id,
                to: paneEventBus
            )
            await eventually("Zoom Viewer should become visibly unavailable") {
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation == .unavailableVisible
                    && harness.store.panePresentationAtom.zoomCompanion(
                        forSourcePane: sourcePane.id
                    ) == nil
            }
            await harness.coordinator.drainBridgePaneRetirements()

            #expect(harness.viewRegistry.allBridgeViews[originalCompanionPaneId] == nil)
            #expect(
                harness.coordinator.runtimeForPane(
                    PaneId(existingUUID: originalCompanionPaneId)
                ) == nil
            )
            #expect(harness.viewRegistry.allBridgeViews.isEmpty)

            await harness.coordinator.shutdown()
        }

        @Test("returning to a registered worktree restores hidden Review continuity")
        func returningToRegisteredWorktreeRestoresHiddenReviewContinuity() async throws {
            let paneEventBus = makeTestPaneRuntimeEventBus()
            let harness = makeHarness(paneEventBus: paneEventBus)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let (_, sourceWorktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let (_, destinationWorktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: sourceWorktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.setActiveTab(sourceTab.id)
            harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
            await harness.executeCommand(.zoomPane)
            let originalCompanionPaneId = try #require(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?
                    .companionPaneId
            )
            #expect(
                harness.coordinator.requestBridgePaneSurface(
                    .review,
                    paneId: originalCompanionPaneId
                )
            )
            await harness.executeCommand(.showViewer)

            await postCWDChange(
                harness.tempDir.appending(path: "unwatched"),
                paneId: sourcePane.id,
                to: paneEventBus
            )
            await eventually("hidden Viewer should become unavailable without opening its column") {
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation == .unavailable
            }

            await postCWDChange(
                destinationWorktree.path.appending(path: "Sources"),
                paneId: sourcePane.id,
                to: paneEventBus
            )
            await eventually("registered worktree should restore a hidden companion") {
                guard
                    let replacement = harness.store.panePresentationAtom.zoomCompanion(
                        forSourcePane: sourcePane.id
                    )
                else {
                    return false
                }
                return replacement.resolvedWorktreeId == destinationWorktree.id
                    && replacement.lastZoomVisibility == .hidden
            }

            let replacementCompanionPaneId = try #require(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?
                    .companionPaneId
            )
            #expect(replacementCompanionPaneId != originalCompanionPaneId)
            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation
                    == .retainedHidden(companionPaneId: replacementCompanionPaneId)
            )
            #expect(
                harness.viewRegistry.allBridgeViews[replacementCompanionPaneId]?.controller
                    .retainedViewerSurface == .review
            )

            await harness.coordinator.shutdown()
        }

        @Test("Zoom uses the stored association instead of re-resolving a contradictory CWD")
        func zoomUsesStoredAssociationInsteadOfContradictoryCWD() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let (sourceRepo, sourceWorktree) = makeRepoAndWorktree(
                harness.store,
                root: harness.tempDir
            )
            let (_, destinationWorktree) = makeRepoAndWorktree(
                harness.store,
                root: harness.tempDir
            )
            let sourcePane = harness.store.createPane(
                launchDirectory: sourceWorktree.path,
                facets: PaneContextFacets(
                    repoId: sourceRepo.id,
                    worktreeId: sourceWorktree.id,
                    cwd: destinationWorktree.path.appending(path: "Sources")
                )
            )
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.setActiveTab(sourceTab.id)
            harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)

            await harness.executeCommand(.zoomPane)

            #expect(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?
                    .resolvedWorktreeId == sourceWorktree.id
            )

            await harness.coordinator.shutdown()
        }

        @Test("same-worktree Zoom targets retain distinct source-owned companions")
        func sameWorktreeSourcesRetainDistinctCompanions() async throws {
            let owningWindowId = UUID()
            let harness = makeHarness(workspaceWindowId: owningWindowId)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let (_, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let firstSourcePane = makeZoomSourcePane(in: harness.store, worktree: worktree)
            let secondSourcePane = makeZoomSourcePane(in: harness.store, worktree: worktree)
            let sourceTab = Tab(paneId: firstSourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.insertPane(
                secondSourcePane.id,
                inTab: sourceTab.id,
                at: firstSourcePane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
            harness.store.setActiveTab(sourceTab.id)
            harness.store.setActivePane(firstSourcePane.id, inTab: sourceTab.id)
            enterForegroundZoomEnvironment(harness, owningWindowId: owningWindowId)
            let durablePaneIds = harness.store.paneAtom.graphAtom.paneIDs
            let expectedSourcePaneIds = Set([firstSourcePane.id, secondSourcePane.id])
            let runtimeCountBeforeZoom = harness.runtimeRegistry.count
            let slotPaneIdsBeforeZoom = harness.viewRegistry.slotPaneIdsForTesting
            let bridgeHostPaneIdsBeforeZoom = Set(harness.viewRegistry.allBridgeViews.keys)
            #expect(harness.store.panePresentationAtom.zoomCompanionsBySourcePaneId.isEmpty)

            await harness.executeCommand(.zoomPane)

            let firstCompanionPaneId = try #require(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: firstSourcePane.id)?
                    .companionPaneId
            )
            let firstHostIdentity = try #require(
                harness.viewRegistry.allBridgeViews[firstCompanionPaneId].map(ObjectIdentifier.init)
            )
            #expect(harness.store.panePresentationAtom.zoomCompanionsBySourcePaneId.count == 1)
            #expect(harness.runtimeRegistry.count == runtimeCountBeforeZoom + 1)
            #expect(
                harness.viewRegistry.slotPaneIdsForTesting
                    == slotPaneIdsBeforeZoom.union(expectedSourcePaneIds).union([firstCompanionPaneId])
            )
            #expect(
                Set(harness.viewRegistry.allBridgeViews.keys)
                    == bridgeHostPaneIdsBeforeZoom.union([firstCompanionPaneId])
            )

            await harness.executeCommand(
                .zoomPane,
                target: secondSourcePane.id,
                targetType: .pane
            )

            let secondCompanionPaneId = try #require(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: secondSourcePane.id)?
                    .companionPaneId
            )
            #expect(secondCompanionPaneId != firstCompanionPaneId)
            let companionPaneIds = Set([firstCompanionPaneId, secondCompanionPaneId])
            #expect(harness.store.panePresentationAtom.zoomCompanionsBySourcePaneId.count == 2)
            #expect(harness.runtimeRegistry.count == runtimeCountBeforeZoom + 2)
            #expect(
                harness.viewRegistry.slotPaneIdsForTesting
                    == slotPaneIdsBeforeZoom.union(expectedSourcePaneIds).union([
                        firstCompanionPaneId,
                        secondCompanionPaneId,
                    ])
            )
            #expect(
                Set(harness.viewRegistry.allBridgeViews.keys)
                    == bridgeHostPaneIdsBeforeZoom.union(companionPaneIds)
            )
            #expect(harness.coordinator.bridgePaneActivity(for: firstCompanionPaneId) == .loadedHidden)
            #expect(harness.coordinator.bridgePaneActivity(for: secondCompanionPaneId) == .foreground)

            await harness.executeCommand(
                .zoomPane,
                target: firstSourcePane.id,
                targetType: .pane
            )

            #expect(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: firstSourcePane.id)?
                    .companionPaneId == firstCompanionPaneId
            )
            #expect(
                harness.viewRegistry.allBridgeViews[firstCompanionPaneId].map(ObjectIdentifier.init)
                    == firstHostIdentity
            )
            #expect(harness.coordinator.bridgePaneActivity(for: firstCompanionPaneId) == .foreground)
            #expect(harness.coordinator.bridgePaneActivity(for: secondCompanionPaneId) == .loadedHidden)
            #expect(harness.store.paneAtom.graphAtom.paneIDs == durablePaneIds)
            #expect(
                harness.store.tab(sourceTab.id)?.arrangements.allSatisfy {
                    !$0.layout.contains(firstCompanionPaneId)
                        && !$0.layout.contains(secondCompanionPaneId)
                        && !$0.minimizedPaneIds.contains(firstCompanionPaneId)
                        && !$0.minimizedPaneIds.contains(secondCompanionPaneId)
                } == true
            )

            await harness.coordinator.shutdown()
        }

        @Test("hidden Viewer preference survives Zoom cancel and re-entry")
        func hiddenViewerPreferenceSurvivesZoomReentry() async throws {
            let owningWindowId = UUID()
            let harness = makeHarness(workspaceWindowId: owningWindowId)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let (_, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: worktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.setActiveTab(sourceTab.id)
            harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
            enterForegroundZoomEnvironment(harness, owningWindowId: owningWindowId)
            await harness.executeCommand(.zoomPane)
            let companionPaneId = try #require(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?
                    .companionPaneId
            )

            await harness.executeCommand(.showViewer)
            await harness.executeCommand(.zoomPane)
            await harness.executeCommand(.zoomPane)

            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation == .retainedHidden(companionPaneId: companionPaneId)
            )
            #expect(
                harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id)?
                    .lastZoomVisibility == .hidden
            )
            #expect(harness.coordinator.bridgePaneActivity(for: companionPaneId) == .loadedHidden)

            await harness.coordinator.shutdown()
        }

        @Test("Zoom companion projects visible and hidden Git-read ranks")
        func zoomCompanionProjectsGitReadRanks() async throws {
            let owningWindowId = UUID()
            let eventProbe = BridgeGitReadSchedulerEventProbe()
            let scheduler = BridgeGitReadScheduler(
                topology: makeBridgeGitReadSchedulerTopology(),
                eventSink: eventProbe.eventSink
            )
            let harness = makeHarness(
                workspaceWindowId: owningWindowId,
                bridgeGitReadScheduler: scheduler
            )
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let (_, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: worktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.setActiveTab(sourceTab.id)
            harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
            enterForegroundZoomEnvironment(harness, owningWindowId: owningWindowId)
            await harness.executeCommand(.zoomPane)
            let companionPaneId = try #require(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation.companionPaneId
            )
            await harness.coordinator.drainBridgeGitReadActivityPropagation()
            #expect(
                harness.coordinator.bridgePaneActivity(for: companionPaneId)
                    == .foreground
            )

            _ = try await scheduler.read(
                request: makeBridgeGitReadRequest(
                    worktree: worktree.stableKey,
                    operationClass: .selectedVisibleContent,
                    key: "zoom-visible"
                )
            ) {
                "visible"
            }
            let visibleStart = try #require(
                eventProbe.events.last {
                    $0.kind == .started
                        && $0.operationClass == .selectedVisibleContent
                }
            )
            #expect(visibleStart.worktreeKey == BridgeGitReadWorktreeKey(token: worktree.stableKey))
            #expect(visibleStart.activityRank == .foreground)

            await harness.executeCommand(.showViewer)
            await harness.coordinator.drainBridgeGitReadActivityPropagation()
            #expect(
                harness.coordinator.bridgePaneActivity(for: companionPaneId)
                    == .loadedHidden
            )
            _ = try await scheduler.read(
                request: makeBridgeGitReadRequest(
                    worktree: worktree.stableKey,
                    operationClass: .selectedVisibleContent,
                    key: "zoom-hidden"
                )
            ) {
                "hidden"
            }
            let hiddenStart = try #require(
                eventProbe.events.last {
                    $0.kind == .started
                        && $0.operationClass == .selectedVisibleContent
                }
            )
            #expect(hiddenStart.activityRank == .loadedHidden)

            await harness.coordinator.shutdown()
        }

        @Test("rejected Files request retires every partial Zoom companion resource")
        func rejectedFilesRequestRetiresPartialCompanionResources() async throws {
            var capturedCompanionPaneId: UUID?
            var capturedStore: WorkspaceStore?
            var capturedViewRegistry: ViewRegistry?
            var capturedRuntimeRegistry: RuntimeRegistry?
            let harness = makeHarness { surface, companionPaneId in
                #expect(surface == .file)
                capturedCompanionPaneId = companionPaneId
                #expect(capturedStore?.pane(companionPaneId) == nil)
                #expect(capturedViewRegistry?.allBridgeViews[companionPaneId] != nil)
                #expect(
                    capturedRuntimeRegistry?.runtime(
                        for: PaneId(existingUUID: companionPaneId)
                    ) is BridgeRuntime
                )
                return false
            }
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            capturedStore = harness.store
            capturedViewRegistry = harness.viewRegistry
            capturedRuntimeRegistry = harness.runtimeRegistry
            let (_, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let sourcePane = makeZoomSourcePane(in: harness.store, worktree: worktree)
            let sourceTab = Tab(paneId: sourcePane.id)
            harness.store.appendTab(sourceTab)
            harness.store.setActiveTab(sourceTab.id)
            harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)
            let runtimeCountBeforeZoom = harness.runtimeRegistry.count
            let slotPaneIdsBeforeZoom = harness.viewRegistry.slotPaneIdsForTesting

            await harness.executeCommand(.zoomPane)

            let companionPaneId = try #require(capturedCompanionPaneId)
            #expect(
                harness.coordinator.bridgePaneActivityAuthorityIdentity(for: companionPaneId)
                    == nil
            )
            #expect(
                harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation == .retryable
            )
            #expect(harness.store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id) == nil)
            #expect(harness.coordinator.pendingBridgePaneRetirementCount == 1)

            await harness.coordinator.drainBridgePaneRetirements()

            #expect(harness.viewRegistry.allBridgeViews[companionPaneId] == nil)
            #expect(harness.viewRegistry.peekSlotForTesting(companionPaneId) == nil)
            #expect(
                harness.coordinator.runtimeForPane(PaneId(existingUUID: companionPaneId)) == nil
            )
            #expect(harness.runtimeRegistry.count == runtimeCountBeforeZoom)
            #expect(
                harness.viewRegistry.slotPaneIdsForTesting
                    == slotPaneIdsBeforeZoom.union([sourcePane.id])
            )
            #expect(
                harness.coordinator.bridgePaneActivityAuthorityIdentity(for: companionPaneId)
                    == nil
            )

            await harness.coordinator.shutdown()
        }

        @Test("unresolvable Zoom source keeps visible Viewer unavailable without partial resources")
        func unresolvableSourceLeavesNoPartialCompanionResources() async {
            let store = WorkspaceStore()
            let viewRegistry = ViewRegistry()
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: viewRegistry,
                runtime: SessionRuntime(store: store),
                windowLifecycleStore: WindowLifecycleAtom(),
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
            let sourcePane = store.createPane()
            let sourceTab = Tab(paneId: sourcePane.id)
            store.appendTab(sourceTab)
            store.setActiveTab(sourceTab.id)
            store.panePresentationAtom.enterZoom(
                inTab: sourceTab.id,
                sourcePaneId: sourcePane.id,
                viewerPresentation: .retryable
            )

            let presentation = coordinator.reconcileZoomCompanion(
                sourcePaneId: sourcePane.id,
                owningTabId: sourceTab.id
            )

            #expect(presentation == .unavailableVisible)
            #expect(
                store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id)?
                    .viewerPresentation == .unavailableVisible
            )
            #expect(store.panePresentationAtom.zoomCompanion(forSourcePane: sourcePane.id) == nil)
            #expect(viewRegistry.allBridgeViews.isEmpty)
            #expect(viewRegistry.registeredPaneIds == [sourcePane.id] || viewRegistry.registeredPaneIds.isEmpty)

            await coordinator.shutdown()
        }
    }
}

@MainActor
private struct ZoomCompanionHarness {
    let root: URL
    let store: WorkspaceStore
    let viewRegistry: ViewRegistry
    let coordinator: WorkspaceSurfaceCoordinator
    let worktree: Worktree
}

@MainActor
private func makeZoomCompanionHarness() -> ZoomCompanionHarness {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "agentstudio-zoom-companion-\(UUID().uuidString)")
    let store = WorkspaceStore()
    let (_, worktree) = makeRepoAndWorktree(store, root: root)
    let viewRegistry = ViewRegistry()
    let coordinator = WorkspaceSurfaceCoordinator(
        store: store,
        viewRegistry: viewRegistry,
        runtime: SessionRuntime(store: store),
        windowLifecycleStore: WindowLifecycleAtom(),
        ipcLifecycle: .testUnavailable,
        bridgePaneAttendance: BridgePaneAttendanceAtom()
    )
    return ZoomCompanionHarness(
        root: root,
        store: store,
        viewRegistry: viewRegistry,
        coordinator: coordinator,
        worktree: worktree
    )
}

@MainActor
private func makeZoomSourcePane(
    in store: WorkspaceStore,
    worktree: Worktree
) -> Pane {
    store.createPane(
        launchDirectory: worktree.path,
        facets: PaneContextFacets(
            repoId: worktree.repoId,
            worktreeId: worktree.id,
            cwd: worktree.path
        )
    )
}

@MainActor
private func enterForegroundZoomEnvironment(
    _ harness: PaneTabViewControllerCommandHarness,
    owningWindowId: UUID
) {
    harness.coordinator.startBridgePaneActivityObservation()
    harness.appLifecycleStore.setActive(true)
    harness.windowLifecycleStore.recordWindowRegistered(owningWindowId)
    harness.windowLifecycleStore.recordWindowPresentation(
        WindowPresentationFacts(
            isVisible: true,
            isMiniaturized: false,
            isOccluded: false
        ),
        for: owningWindowId
    )
}

private func postCWDChange(
    _ cwd: URL,
    paneId: UUID,
    to paneEventBus: EventBus<RuntimeEnvelope>
) async {
    _ = await paneEventBus.post(
        RuntimeEnvelopeHarness.paneEnvelope(
            event: .terminal(.cwdChanged(cwd.path)),
            paneId: PaneId(existingUUID: paneId)
        )
    )
}

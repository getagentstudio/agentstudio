import AgentStudioTestHarness
import Foundation
import Observation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

private final class BridgePaneActivityObservationInvalidationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var invalidationCount: Int {
        lock.withLock { storedCount }
    }

    func record() {
        lock.withLock {
            storedCount += 1
        }
    }
}

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct WorkspaceBridgePaneActivityIntegrationTests {
        enum ActivityHidingMutation: CaseIterable, CustomTestStringConvertible {
            case inactiveTab
            case inactiveArrangement
            case minimized
            case zoomExcluded
            case backgroundedResidency

            var testDescription: String {
                switch self {
                case .inactiveTab:
                    "inactive tab"
                case .inactiveArrangement:
                    "inactive arrangement"
                case .minimized:
                    "minimized pane"
                case .zoomExcluded:
                    "Zoom-excluded pane"
                case .backgroundedResidency:
                    "backgrounded residency"
                }
            }
        }

        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("prepared initial mount leaves hidden Bridge panes dormant until steady-state selection")
        func preparedInitialMountLeavesHiddenBridgePaneDormantUntilSteadyStateSelection() async throws {
            // Arrange
            let harness = makeBridgePaneActivityTestHarness()
            let hiddenBridgePane = harness.store.createPane(
                content: .bridgePanel(
                    BridgePaneState(
                        panelKind: .fileViewer,
                        source: .commit(sha: "hidden-restore")
                    )
                ),
                metadata: PaneMetadata(title: "Hidden files", facets: .init(cwd: harness.tempDirectory))
            )
            let hiddenTab = Tab(paneId: hiddenBridgePane.id, name: "Hidden")
            harness.store.appendTab(hiddenTab)
            harness.store.setActiveTab(harness.tabId)
            enterForegroundNativeEnvironment(harness)
            harness.windowLifecycleStore.recordTerminalContainerBounds(
                CGRect(x: 0, y: 0, width: 1200, height: 800)
            )
            harness.windowLifecycleStore.recordLaunchLayoutSettled()
            harness.coordinator.refreshBridgePaneActivities()
            let generation = WorkspaceContentMountGeneration()
            let cohort = WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: []),
                nonterminalContentMountInput: NonterminalContentMountInput(
                    entries: [
                        NonterminalContentMountDescriptor(
                            content: .bridgePanel(harness.bridgePane),
                            visibilityPriority: .activeVisible,
                            hostPlacement: .tab(tabID: harness.tabId)
                        ),
                        NonterminalContentMountDescriptor(
                            content: .bridgePanel(hiddenBridgePane),
                            visibilityPriority: .hidden,
                            hostPlacement: .tab(tabID: hiddenTab.id)
                        ),
                    ]
                )
            )
            harness.viewRegistry.beginInitialRestore()
            let mountCoordinator = WorkspacePreparedContentMountCoordinator(
                cohort: cohort,
                viewRegistry: harness.viewRegistry,
                terminalAdmissionPort: PreparedTerminalMountAdmissionPort(
                    generation: generation,
                    initialFramesByPaneID: [:],
                    viewRegistry: harness.viewRegistry,
                    mountHandler: harness.coordinator,
                    descriptorsByPaneID: [:]
                ),
                nonterminalAdmissionPort: PreparedNonterminalMountAdmissionPort(
                    generation: generation,
                    coordinator: harness.coordinator
                )
            )

            // Act
            let settlement = await mountCoordinator.mount()

            // Assert
            #expect(harness.viewRegistry.allBridgeViews[harness.bridgePane.id] != nil)
            await expectBridgePaneActivity(
                .dormant,
                for: hiddenBridgePane.id,
                in: harness.coordinator,
                because: "startup must not construct a hidden Bridge host"
            )
            let hiddenAuthorityIdentity = harness.coordinator.bridgePaneActivityAuthorityIdentity(
                for: hiddenBridgePane.id
            )
            #expect(hiddenAuthorityIdentity != nil)
            #expect(harness.viewRegistry.allBridgeViews[hiddenBridgePane.id] == nil)
            #expect(harness.viewRegistry.registeredPaneIds == [harness.bridgePane.id])
            #expect(
                Set(settlement.nonterminal.outcomesByPaneID.keys)
                    == [PaneId(existingUUID: harness.bridgePane.id)]
            )
            #expect(
                harness.viewRegistry.preparedContentMountState(
                    for: PaneId(existingUUID: hiddenBridgePane.id),
                    generation: generation
                ) == nil
            )

            // Act — selection reveals the pane through the established steady-state mount path.
            harness.store.setActiveTab(hiddenTab.id)
            let mountedHiddenBridgeView = try #require(
                harness.coordinator.createViewForContent(pane: hiddenBridgePane)
            )
            harness.coordinator.refreshBridgePaneActivities()

            // Assert
            await expectBridgePaneActivity(
                .foreground,
                for: hiddenBridgePane.id,
                in: harness.coordinator,
                because: "the hidden restored tab activated"
            )
            let registeredHiddenBridgeView = try #require(
                harness.viewRegistry.allBridgeViews[hiddenBridgePane.id]
            )
            #expect(mountedHiddenBridgeView === registeredHiddenBridgeView)
            #expect(harness.viewRegistry.registeredPaneIds == [harness.bridgePane.id, hiddenBridgePane.id])
            #expect(
                harness.coordinator.bridgePaneActivityAuthorityIdentity(for: hiddenBridgePane.id)
                    == hiddenAuthorityIdentity
            )
            await harness.finish()
        }

        @Test("installed Bridge pane is foreground through selected workspace facts")
        func installedBridgePaneBecomesForegroundFromExactNativeFacts() async throws {
            let harness = makeBridgePaneActivityTestHarness()

            try await installBridgeControllerAndEnterForeground(harness)

            #expect(harness.coordinator.bridgePaneActivity(for: harness.bridgePane.id) == .foreground)
            #expect(harness.viewRegistry.allBridgeViews[harness.bridgePane.id] != nil)

            await harness.finish()
        }

        @Test("held preview presents an installed Bridge target and hides the covered peer")
        func heldPreviewPresentsInstalledBridgeTargetAndHidesCoveredPeer() async throws {
            let harness = makeBridgePaneActivityTestHarness()
            enterForegroundNativeEnvironment(harness)
            harness.windowLifecycleStore.recordTerminalContainerBounds(
                CGRect(x: 0, y: 0, width: 1200, height: 800)
            )
            try await installBridgeControllerAndEnterForeground(harness)

            let previewPane = harness.store.createPane(
                content: .bridgePanel(
                    BridgePaneState(
                        panelKind: .fileViewer,
                        source: .commit(sha: "held-preview")
                    )
                ),
                metadata: PaneMetadata(title: "Preview files", facets: .init(cwd: harness.tempDirectory))
            )
            let previewTab = Tab(paneId: previewPane.id, name: "Preview")
            harness.store.appendTab(previewTab)
            harness.store.setActiveTab(harness.tabId)
            #expect(harness.store.tabLayoutAtom.activeTabId == harness.tabId)
            _ = try #require(harness.coordinator.createViewForContent(pane: previewPane))

            let heldState = HeldPanePreviewState()
            harness.coordinator.bindHeldPanePreviewState(heldState)
            let target = ValidatedPanePreviewTarget(
                paneID: previewPane.id,
                owningTabID: previewTab.id,
                provider: previewPane.provider,
                sessionID: previewPane.terminalState?.zmxSessionID
            )

            #expect(heldState.beginSpaceHold(requestedTarget: target))
            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = harness.coordinator.beginHeldPanePreviewPreparation()

            #expect(heldState.presentedTarget == target)
            #expect(harness.store.tabLayoutAtom.activeTabId == harness.tabId)
            await expectBridgePaneActivity(
                .foreground,
                for: previewPane.id,
                in: harness.coordinator,
                because: "the installed preview target uses normal foreground admission"
            )
            await expectBridgePaneActivity(
                .loadedHidden,
                for: harness.bridgePane.id,
                in: harness.coordinator,
                because: "the canonical Bridge peer is covered by the preview"
            )

            heldState.endSpaceHold()
            harness.coordinator.refreshBridgePaneActivities()
            #expect(harness.store.tabLayoutAtom.activeTabId == harness.tabId)
            await expectBridgePaneActivity(
                .foreground,
                for: harness.bridgePane.id,
                in: harness.coordinator,
                because: "release restores canonical Bridge activity"
            )
            await harness.finish()
        }

        @Test("application deactivation leaves the foreground Bridge tab working")
        func applicationDeactivationLeavesForegroundBridgeTabWorking() async throws {
            let harness = makeBridgePaneActivityTestHarness()
            try await installBridgeControllerAndEnterForeground(harness)

            harness.appLifecycleStore.setActive(false)

            await expectBridgePaneActivity(
                .foreground,
                for: harness.bridgePane.id,
                in: harness.coordinator,
                because: "application activation is not Bridge tab activity"
            )
            #expect(harness.viewRegistry.allBridgeViews[harness.bridgePane.id] != nil)
            await harness.finish()
        }

        @Test("Bridge activity observation ignores pane titles and invalidates for residency")
        func bridgeActivityObservationIsTitleInsensitive() async throws {
            let harness = makeBridgePaneActivityTestHarness()
            try await installBridgeControllerAndEnterForeground(harness)
            let invalidationRecorder = BridgePaneActivityObservationInvalidationRecorder()
            withObservationTracking {
                _ = harness.coordinator.bridgePaneActivity(for: harness.bridgePane.id)
            } onChange: {
                invalidationRecorder.record()
            }

            harness.store.paneAtom.updatePaneTitle(
                harness.bridgePane.id,
                title: "Updated review title"
            )
            for _ in 0..<20 {
                await Task.yield()
            }

            #expect(invalidationRecorder.invalidationCount == 0)

            harness.store.paneAtom.setResidency(.backgrounded, for: harness.bridgePane.id)
            await assertEventuallyMain("residency should refresh Bridge pane activity") {
                invalidationRecorder.invalidationCount == 1
            }
            await expectBridgePaneActivity(
                .loadedHidden,
                for: harness.bridgePane.id,
                in: harness.coordinator,
                because: "backgrounded residency is structural activity input"
            )
            await harness.finish()
        }

        @Test(
            "each pane hiding fact demotes an installed Bridge pane to loaded-hidden",
            arguments: ActivityHidingMutation.allCases
        )
        func eachNativeHidingFactDemotesToLoadedHidden(_ mutation: ActivityHidingMutation) async throws {
            let harness = makeBridgePaneActivityTestHarness()
            try await installBridgeControllerAndEnterForeground(harness)

            apply(mutation, to: harness)

            await expectBridgePaneActivity(
                .loadedHidden,
                for: harness.bridgePane.id,
                in: harness.coordinator,
                because: mutation.testDescription
            )
            #expect(harness.viewRegistry.view(for: harness.bridgePane.id) != nil)

            await harness.finish()
        }

        @Test("owning window state does not suspend a foreground Bridge tab")
        func owningWindowStateDoesNotSuspendForegroundBridgeTab() async throws {
            let harness = makeBridgePaneActivityTestHarness()
            try await installBridgeControllerAndEnterForeground(harness)

            harness.windowLifecycleStore.recordWindowVisibility(false, for: harness.owningWindowId)
            harness.windowLifecycleStore.recordWindowMiniaturization(true, for: harness.owningWindowId)
            harness.windowLifecycleStore.recordWindowOcclusion(true, for: harness.owningWindowId)

            await expectBridgePaneActivity(
                .foreground,
                for: harness.bridgePane.id,
                in: harness.coordinator,
                because: "the selected Bridge tab stays alive regardless of app/window foreground state"
            )

            await harness.finish()
        }

        @Test("key, focus, and active viewer signals cannot mint foreground activity")
        func keyFocusAndViewerSignalsCannotMintForegroundActivity() async throws {
            let harness = makeBridgePaneActivityTestHarness()
            try await installBridgeControllerAndEnterForeground(harness)
            let foreignVisibleWindowId = UUID()
            harness.windowLifecycleStore.recordWindowRegistered(foreignVisibleWindowId)
            harness.windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(
                    isVisible: true,
                    isMiniaturized: false,
                    isOccluded: false
                ),
                for: foreignVisibleWindowId
            )
            harness.store.paneAtom.setResidency(.backgrounded, for: harness.bridgePane.id)
            await expectBridgePaneActivity(
                .loadedHidden,
                for: harness.bridgePane.id,
                in: harness.coordinator,
                because: "the pane itself has backgrounded residency"
            )
            harness.windowLifecycleStore.recordWindowBecameKey(foreignVisibleWindowId)
            harness.windowLifecycleStore.recordWindowBecameFocused(foreignVisibleWindowId)
            let controller = try #require(harness.viewRegistry.allBridgeViews[harness.bridgePane.id]?.controller)

            controller.setActiveViewerModeAcceptedSignalForExplicitReviewRequestWithoutAdmissionCheck(
                streamId: "viewer-signal-must-not-mint-activity",
                generation: 1
            )
            for _ in 0..<10 {
                await Task.yield()
            }

            #expect(harness.coordinator.bridgePaneActivity(for: harness.bridgePane.id) == .loadedHidden)

            await harness.finish()
        }

        @Test("repair teardown preserves authority identity and never returns a loaded pane to dormant")
        func repairTeardownPreservesAuthorityIdentityAndLoadedState() async throws {
            let harness = makeBridgePaneActivityTestHarness()
            try await installBridgeControllerAndEnterForeground(harness)
            let originalAuthorityIdentity = try #require(
                harness.coordinator.bridgePaneActivityAuthorityIdentity(for: harness.bridgePane.id)
            )
            let originalController = try #require(
                harness.viewRegistry.allBridgeViews[harness.bridgePane.id]?.controller
            )

            harness.coordinator.teardownView(
                for: harness.bridgePane.id,
                shouldUnregisterRuntime: false
            )

            #expect(harness.coordinator.bridgePaneActivity(for: harness.bridgePane.id) == .loadedHidden)
            #expect(
                harness.coordinator.bridgePaneActivityAuthorityIdentity(for: harness.bridgePane.id)
                    == originalAuthorityIdentity
            )
            await harness.coordinator.drainBridgePaneRetirements()
            await expectBridgePaneActivity(
                .foreground,
                for: harness.bridgePane.id,
                in: harness.coordinator,
                because: "repair recreated the installed Bridge controller"
            )
            let replacementController = try #require(
                harness.viewRegistry.allBridgeViews[harness.bridgePane.id]?.controller
            )
            #expect(replacementController !== originalController)
            #expect(
                harness.coordinator.bridgePaneActivityAuthorityIdentity(for: harness.bridgePane.id)
                    == originalAuthorityIdentity
            )

            await harness.finish()
        }

        @Test("close publishes terminal activity before asynchronous Bridge retirement completes")
        func closePublishesTerminalActivitySynchronously() async throws {
            let harness = makeBridgePaneActivityTestHarness()
            try await installBridgeControllerAndEnterForeground(harness)
            let originalAuthorityIdentity = try #require(
                harness.coordinator.bridgePaneActivityAuthorityIdentity(for: harness.bridgePane.id)
            )

            harness.coordinator.teardownView(
                for: harness.bridgePane.id,
                shouldUnregisterRuntime: true
            )

            #expect(harness.coordinator.bridgePaneActivity(for: harness.bridgePane.id) == .closed)
            #expect(
                harness.coordinator.bridgePaneActivityAuthorityIdentity(for: harness.bridgePane.id)
                    == originalAuthorityIdentity
            )
            #expect(harness.coordinator.pendingBridgePaneRetirementCount == 1)
            #expect(harness.viewRegistry.view(for: harness.bridgePane.id) != nil)
            await harness.coordinator.drainBridgePaneRetirements()
            #expect(harness.coordinator.bridgePaneActivity(for: harness.bridgePane.id) == .closed)

            await harness.finish()
        }

        @Test("close then undo installs fresh authority immune to stale retirement completion")
        func closeThenUndoInstallsFreshAuthority() async throws {
            let harness = makeBridgePaneActivityTestHarness(store: try makeWorkspaceJournalTestStore())
            let retirementGate = HeldStep<Void>(
                "prior Bridge controller review refresh", cancellation: .holdThroughCancellation)
            var heldRefreshTask: Task<Void, Never>?
            do {
                try await installBridgeControllerAndEnterForeground(harness)
                let originalAuthorityIdentity = try #require(
                    harness.coordinator.bridgePaneActivityAuthorityIdentity(for: harness.bridgePane.id)
                )
                let originalController = try #require(
                    harness.viewRegistry.allBridgeViews[harness.bridgePane.id]?.controller
                )

                try #require(originalController.activeReviewRefreshTask == nil)
                let heldTask = Task<Void, Never> { try? await retirementGate.arrive(()) }
                heldRefreshTask = heldTask
                originalController.activeReviewRefreshTask = heldTask
                _ = try await retirementGate.firstArrival()

                try await harness.coordinator.execute(.closeTab(tabId: harness.tabId))
                try await retirementGate.cancellationObserved()
                #expect(harness.coordinator.bridgePaneActivity(for: harness.bridgePane.id) == .closed)
                #expect(harness.coordinator.pendingBridgePaneRetirementCount == 1)

                let retirementTask = try #require(
                    harness.coordinator.bridgePaneRetirementTasksByPaneId[harness.bridgePane.id])
                try await harness.coordinator.undoCloseTab()

                let replacementAuthorityIdentity = try #require(
                    harness.coordinator.bridgePaneActivityAuthorityIdentity(for: harness.bridgePane.id)
                )
                #expect(replacementAuthorityIdentity != originalAuthorityIdentity)
                #expect(harness.coordinator.pendingBridgePaneRetirementCount == 1)
                retirementGate.release()
                await heldTask.value
                await retirementTask.value
                #expect(harness.coordinator.pendingBridgePaneRetirementCount == 0)
                try #require(
                    harness.coordinator.bridgePaneActivityAuthorityIdentity(for: harness.bridgePane.id)
                        == replacementAuthorityIdentity,
                    "Stale retirement must preserve the fresh undo authority")
                await expectBridgePaneActivity(
                    .foreground,
                    for: harness.bridgePane.id,
                    in: harness.coordinator,
                    because: "undo recreated the Bridge pane under its fresh authority"
                )
                let replacementController = try #require(
                    harness.viewRegistry.allBridgeViews[harness.bridgePane.id]?.controller
                )
                #expect(replacementController !== originalController)
                #expect(
                    harness.coordinator.bridgePaneActivityAuthorityIdentity(for: harness.bridgePane.id)
                        == replacementAuthorityIdentity
                )
            } catch {
                retirementGate.release()
                await heldRefreshTask?.value
                await harness.finish()
                throw error
            }
            await harness.finish()
        }

        private func apply(_ mutation: ActivityHidingMutation, to harness: BridgePaneActivityTestHarness) {
            switch mutation {
            case .inactiveTab:
                let backgroundPane = harness.store.createPane(
                    content: .webview(
                        WebviewState(url: URL(string: "https://example.com/active-tab")!)
                    ),
                    metadata: PaneMetadata(title: "Active tab")
                )
                let activeTab = Tab(paneId: backgroundPane.id)
                harness.store.appendTab(activeTab)
                harness.store.setActiveTab(activeTab.id)
            case .inactiveArrangement:
                harness.store.tabLayoutAtom.switchArrangement(
                    to: harness.alternateArrangementId,
                    inTab: harness.tabId
                )
            case .minimized:
                #expect(
                    harness.store.tabLayoutAtom.minimizePane(
                        harness.bridgePane.id,
                        inTab: harness.tabId
                    )
                )
            case .zoomExcluded:
                guard harness.store.tabLayoutAtom.tab(harness.tabId) != nil else {
                    Issue.record("Expected activity fixture tab")
                    return
                }
                harness.store.panePresentationAtom.enterZoom(
                    inTab: harness.tabId,
                    sourcePaneId: harness.siblingPane.id,
                    viewerPresentation: .unavailable
                )
            case .backgroundedResidency:
                harness.store.paneAtom.setResidency(.backgrounded, for: harness.bridgePane.id)
            }
        }

    }
}

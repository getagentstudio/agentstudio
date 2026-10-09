import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioTerminal
import AppKit
import Foundation

#if DEBUG
    @MainActor
    struct SidebarPerformanceProofFixture {
        let paneId: UUID
        let arrangementPaneId: UUID
        let tabId: UUID
        let arrangementId: UUID
        let repositoryId: UUID
        let worktreeId: UUID

        static func prepare(
            store: WorkspaceStore,
            repositoryRoot: URL,
            openTerminal: () async -> Pane?
        ) async -> Self? {
            let fixtureRepository = store.mutationCoordinator.addRepo(at: repositoryRoot)
            guard
                let fixtureWorktree = fixtureRepository.worktrees.first,
                let pane = await openTerminal(),
                pane.metadata.contentType == .terminal,
                let tabId = store.tabLayoutAtom.tabID(containingPane: pane.id),
                let arrangementId = store.tabLayoutAtom.tab(tabId)?.activeArrangementId
            else { return nil }
            let sortableRepositoryRoot = repositoryRoot.appendingPathComponent(
                "agentstudio-sidebar-sort-fixture",
                isDirectory: true
            )
            _ = store.mutationCoordinator.addRepo(at: sortableRepositoryRoot)
            let arrangementPane = store.paneAtom.createPane(
                title: "Arrangement Fixture",
                provider: .zmx,
                lifetime: .temporary,
                zmxSessionID: .generateUUIDv7()
            )
            guard
                store.tabLayoutAtom.insertPane(
                    arrangementPane.id,
                    inTab: tabId,
                    at: pane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            else { return nil }
            populateRealSizeTopology(store: store, repositoryRoot: repositoryRoot)
            populateRealSizePaneFleet(store: store)
            store.tabLayoutAtom.renameTab(tabId, name: "Tab")
            return Self(
                paneId: pane.id,
                arrangementPaneId: arrangementPane.id,
                tabId: tabId,
                arrangementId: arrangementId,
                repositoryId: fixtureRepository.id,
                worktreeId: fixtureWorktree.id
            )
        }
    }
#endif

@MainActor
extension AppDelegate {
    func runStartupDiagnosticActionIfRequested() {
        guard let action = AgentStudioStartupDiagnosticAction.fromEnvironment() else { return }
        startupTraceRecorder.recordAppStartup(
            "app.startup_diagnostic_action.requested",
            phase: "startup_diagnostic_action",
            attributes: startupDiagnosticTraceAttributes(for: action)
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.dispatched",
                phase: "startup_diagnostic_action",
                attributes: self.startupDiagnosticTraceAttributes(for: action)
            )
            switch action.kind {
            case .newTab:
                await Task.yield()
                self.commandDispatcherForBoot().dispatch(.newTab)
            case .commandBarRepoFilter:
                await Task.yield()
                self.commandDispatcherForBoot().dispatch(.showCommandBarEverything)
                await Task.yield()
                self.commandBarController.setQueryText("# repo")
                self.startupTraceRecorder.recordAppStartup(
                    "app.startup_diagnostic_action.command_exercised",
                    phase: "startup_diagnostic_action",
                    outcome: "succeeded",
                    attributes: self.startupDiagnosticTraceAttributes(for: action)
                )
                self.startupTraceRecorder.recordAppStartup(
                    "app.startup_diagnostic_action.completed",
                    phase: "startup_diagnostic_action",
                    outcome: "succeeded",
                    attributes: self.startupDiagnosticTraceAttributes(for: action)
                )
            case .tccUpgradeProbe:
                await self.runTCCUpgradeProbeDiagnostic(action: action)
            #if DEBUG
                case .crossTabMoveGeometrySmoke:
                    await self.runCrossTabMoveGeometrySmokeDiagnostic(action: action)
                case .ipcTerminalSmoke:
                    await self.runIPCTerminalSmokeDiagnostic(action: action)
                case .paneAssociationRuntimeProof:
                    await self.runPaneAssociationRuntimeProofDiagnostic(action: action)
                case .bridgeReviewObservabilitySmoke:
                    await self.runBridgeReviewObservabilitySmokeDiagnostic(action: action)
                case .bridgeFileViewObservabilitySmoke:
                    await self.runBridgeFileViewObservabilitySmokeDiagnostic(action: action)
                case .bridgeFileViewCommandRouteObservabilitySmoke:
                    await self.runBridgeFileViewCommandRouteObservabilitySmokeDiagnostic(action: action)
                case .bridgeFileViewTargetedRouteObservabilitySmoke:
                    await self.runBridgeFileViewTargetedRouteObservabilitySmokeDiagnostic(action: action)
                case .bridgeReviewToFileViewObservabilitySmoke:
                    await self.runBridgeReviewToFileViewObservabilitySmokeDiagnostic(action: action)
                case .bridgeProductPaintCorrelation:
                    await self.runBridgeProductPaintCorrelationDiagnostic(action: action)
                case .bridgeProductStreamWebKitFeasibility:
                    await self.runBridgeProductStreamWebKitFeasibilityDiagnostic(action: action)
                case .sidebarPerformanceProof:
                    await self.runSidebarPerformanceProofDiagnostic(action: action)
                case .sidebarCPUZeroPTYIdle, .sidebarCPUQuiescentPTYIdle, .sidebarCPUSearchClear,
                    .sidebarCPUGrouping, .sidebarCPUHideShow, .sidebarCPUTabSwitch:
                    await self.runStrictSidebarCPUPopulationDiagnostic(action: action)
                case .repoExplorerKeyMutationProof:
                    await self.runRepoExplorerKeyMutationProofDiagnostic(action: action)
                case .repoExplorerInteractionProof:
                    await self.runRepoExplorerInteractionProofDiagnostic(action: action)
            #endif
            case .addWatchFolder:
                guard let folderURL = AgentStudioStartupDiagnosticAction.watchFolderURL() else {
                    self.startupTraceRecorder.recordAppStartup(
                        "app.startup_diagnostic_action.skipped",
                        phase: "startup_diagnostic_action",
                        attributes: self.startupDiagnosticTraceAttributes(for: action).merging([
                            "agentstudio.startup_diagnostic.skip_reason": .string("missing_watch_folder")
                        ]) { _, newValue in newValue }
                    )
                    return
                }
                await self.handleWatchFolderRequested(startingAt: folderURL)
            }
        }
    }

    private func runTCCUpgradeProbeDiagnostic(
        action: AgentStudioStartupDiagnosticAction
    ) async {
        let monitorConfiguration = AgentStudioTCCUpgradeProbeMonitorConfiguration.from()
        let recorder = AgentStudioTCCDiagnosticRecorder(traceRuntime: traceRuntime)
        let bundleKind = AgentStudioTCCDiagnosticRecorder.bundleKind()
        let baselineBundleSnapshot = AgentStudioTCCBundleDiskSnapshot.current()
        let probePair = Self.recordTCCUpgradeProbeSequence(
            recorder: recorder,
            bundleKind: bundleKind,
            baselineBundleSnapshot: baselineBundleSnapshot,
            currentBundleSnapshot: baselineBundleSnapshot,
            actionRawValue: action.kind.rawValue,
            probeSequence: 0
        )
        try? await recorder.drain()

        let probesGranted = probePair.documents.result == .granted && probePair.messagesData.result == .granted
        let outcome = probesGranted ? "succeeded" : "blocked"
        startupTraceRecorder.recordAppStartup(
            "app.startup_diagnostic_action.command_exercised",
            phase: "startup_diagnostic_action",
            outcome: outcome,
            attributes: startupDiagnosticTraceAttributes(for: action).merging([
                "agentstudio.startup_diagnostic.render_proof.succeeded": .bool(probesGranted)
            ]) { _, newValue in newValue }
        )
        startupTraceRecorder.recordAppStartup(
            probesGranted
                ? "app.startup_diagnostic_action.completed"
                : "app.startup_diagnostic_action.blocked",
            phase: "startup_diagnostic_action",
            outcome: outcome,
            attributes: startupDiagnosticTraceAttributes(for: action).merging([
                "agentstudio.startup_diagnostic.render_proof.succeeded": .bool(probesGranted)
            ]) { _, newValue in newValue }
        )
        guard monitorConfiguration.repeatCount > 0 else { return }

        let actionRawValue = action.kind.rawValue
        let traceRuntime = traceRuntime
        let baselineBundleSnapshotForMonitor = baselineBundleSnapshot
        // TCC monitoring runs blocking shell probes; keep the diagnostic off the MainActor.
        // swiftlint:disable:next no_task_detached
        Task.detached(priority: .background) {
            let bundleKind = AgentStudioTCCDiagnosticRecorder.bundleKind()
            for probeSequence in 1...monitorConfiguration.repeatCount {
                try? await Task.sleep(nanoseconds: monitorConfiguration.intervalNanoseconds)
                let bundleSnapshot = AgentStudioTCCBundleDiskSnapshot.current()
                let recorder = AgentStudioTCCDiagnosticRecorder(traceRuntime: traceRuntime)
                Self.recordTCCUpgradeProbeSequence(
                    recorder: recorder,
                    bundleKind: bundleKind,
                    baselineBundleSnapshot: baselineBundleSnapshotForMonitor,
                    currentBundleSnapshot: bundleSnapshot,
                    actionRawValue: actionRawValue,
                    probeSequence: probeSequence
                )
                try? await recorder.drain()
            }
        }
    }

    @discardableResult
    nonisolated private static func recordTCCUpgradeProbeSequence(
        recorder: AgentStudioTCCDiagnosticRecorder,
        bundleKind: AgentStudioTCCBundleKind,
        baselineBundleSnapshot: AgentStudioTCCBundleDiskSnapshot,
        currentBundleSnapshot: AgentStudioTCCBundleDiskSnapshot,
        actionRawValue: String,
        probeSequence: Int
    ) -> TCCUpgradeProbePair {
        let codeIdentityKind = currentBundleSnapshot.codeIdentityKind(comparedTo: baselineBundleSnapshot)
        recorder.recordAppIdentitySnapshot(
            phase: .startupDiagnostic,
            bundleKind: bundleKind,
            codeIdentityKind: codeIdentityKind,
            bundleChanged: codeIdentityKind == .differentDiskIdentity,
            bundleExecutableReachable: currentBundleSnapshot.isReachable,
            startupDiagnosticAction: actionRawValue,
            probeSequence: probeSequence,
            rawBundlePath: currentBundleSnapshot.rawBundlePath,
            rawExecutablePath: currentBundleSnapshot.rawExecutablePath
        )

        let probePair = runTCCUpgradeAccessProbePair()
        Self.recordTCCUpgradeAccessProbe(
            recorder: recorder,
            bundleKind: bundleKind,
            target: .documents,
            outcome: probePair.documents,
            actionRawValue: actionRawValue,
            probeSequence: probeSequence
        )
        Self.recordTCCUpgradeAccessProbe(
            recorder: recorder,
            bundleKind: bundleKind,
            target: .messagesData,
            outcome: probePair.messagesData,
            actionRawValue: actionRawValue,
            probeSequence: probeSequence
        )
        return probePair
    }

    nonisolated private static func runTCCUpgradeAccessProbePair() -> TCCUpgradeProbePair {
        TCCUpgradeProbePair(
            documents: AgentStudioTCCDiagnosticRecorder.shellChildDocumentsDirectoryProbe(),
            messagesData: AgentStudioTCCDiagnosticRecorder.shellChildMessagesDataDirectoryProbe()
        )
    }

    nonisolated private static func recordTCCUpgradeAccessProbe(
        recorder: AgentStudioTCCDiagnosticRecorder,
        bundleKind: AgentStudioTCCBundleKind,
        target: AgentStudioTCCAccessTarget,
        outcome: AgentStudioTCCAccessProbeOutcome,
        actionRawValue: String,
        probeSequence: Int
    ) {
        recorder.recordAccessProbe(
            AgentStudioTCCAccessProbeRecord(
                phase: .startupDiagnostic,
                subject: .shellChild,
                target: target,
                result: outcome.result,
                responsibleKind: AgentStudioTCCDiagnosticRecorder.responsibleKind(for: bundleKind),
                commandExitClass: outcome.commandExitClass,
                startupDiagnosticAction: actionRawValue,
                probeSequence: probeSequence,
                rawProbePath: outcome.rawPath
            ))
    }

    private struct TCCUpgradeProbePair {
        let documents: AgentStudioTCCAccessProbeOutcome
        let messagesData: AgentStudioTCCAccessProbeOutcome
    }

    #if DEBUG
        private func runIPCTerminalSmokeDiagnostic(
            action: AgentStudioStartupDiagnosticAction
        ) async {
            NSApp.activate(ignoringOtherApps: true)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
            await waitForStartupDiagnosticAppActivation()

            guard let terminalContainerBounds = await startupDiagnosticLaunchRestoreBounds() else {
                startupTraceRecorder.recordAppStartup(
                    "app.startup_diagnostic_action.skipped",
                    phase: "startup_diagnostic_action",
                    outcome: "skipped",
                    attributes: startupDiagnosticTraceAttributes(for: action).merging([
                        "agentstudio.startup_diagnostic.skip_reason": .string("missing_bounds")
                    ]) { _, newValue in newValue }
                )
                return
            }

            if !launchRestoreObservationState.didComplete {
                await finishLaunchRestore(
                    using: terminalContainerBounds,
                    source: "ipcTerminalSmokePreflight"
                )
            }

            guard
                let pane = try? await workspaceSurfaceCoordinator.openFloatingTerminal(
                    launchDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    title: "IPC Smoke Terminal"
                )
            else {
                startupTraceRecorder.recordAppStartup(
                    "app.startup_diagnostic_action.blocked",
                    phase: "startup_diagnostic_action",
                    outcome: "blocked",
                    attributes: startupDiagnosticTraceAttributes(for: action).merging([
                        "agentstudio.startup_diagnostic.skip_reason": .string("terminal_open_failed")
                    ]) { _, newValue in newValue }
                )
                return
            }

            workspaceSurfaceCoordinator.restoreVisiblePaneIfNeeded(
                pane.id,
                forceWhenBoundsExist: true
            )
            await Task.yield()
            mainWindowController?.syncVisibleTerminalGeometry(reason: "ipcTerminalSmoke")
            let renderProof = await waitForIPCTerminalSmokeRenderProof(for: pane.id)
            guard renderProof.succeeded else {
                startupTraceRecorder.recordAppStartup(
                    "app.startup_diagnostic_action.blocked",
                    phase: "startup_diagnostic_action",
                    outcome: "blocked",
                    attributes: startupDiagnosticTraceAttributes(for: action).merging(
                        [
                            "agentstudio.startup_diagnostic.created_pane.count": .int(1),
                            "agentstudio.startup_diagnostic.pane.id": .string(pane.id.uuidString),
                        ].merging(renderProof.attributes) { _, newValue in newValue }
                    ) { _, newValue in newValue }
                )
                return
            }
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.command_exercised",
                phase: "startup_diagnostic_action",
                outcome: "succeeded",
                attributes: startupDiagnosticTraceAttributes(for: action).merging(
                    [
                        "agentstudio.startup_diagnostic.created_pane.count": .int(1),
                        "agentstudio.startup_diagnostic.pane.id": .string(pane.id.uuidString),
                    ].merging(renderProof.attributes) { _, newValue in newValue }
                ) { _, newValue in newValue }
            )
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.completed",
                phase: "startup_diagnostic_action",
                outcome: "succeeded",
                attributes: startupDiagnosticTraceAttributes(for: action).merging(
                    [
                        "agentstudio.startup_diagnostic.created_pane.count": .int(1),
                        "agentstudio.startup_diagnostic.pane.id": .string(pane.id.uuidString),
                    ].merging(renderProof.attributes) { _, newValue in newValue }
                ) { _, newValue in newValue }
            )
        }

        private func runSidebarPerformanceProofDiagnostic(
            action: AgentStudioStartupDiagnosticAction
        ) async {
            let result = await RepoExplorerNativeTablePilot.run(
                performanceTraceRecorder: performanceTraceRecorder
            )
            let projectionTrigger = AppPolicies.SidebarProjection.Trigger.startupDiagnostic
            let attributes = startupDiagnosticTraceAttributes(for: action).merging(
                sidebarPerformanceProofPolicyAttributes().merging([
                    "agentstudio.startup_diagnostic.native_table_pilot.policy_id": .string(
                        result.policyID
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.policy_version": .int(
                        result.policyVersion
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.result_version": .int(
                        RepoExplorerNativeTablePilotResult.resultVersion
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.scale.count": .int(
                        result.scaleCount
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.liveness_projection.count": .int(
                        result.livenessProjectionCount
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.drain_completed.count": .int(
                        result.drainedScaleCount
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.template_pair.count": .int(
                        result.templatePairCount
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.warmup_transaction.count": .int(
                        result.warmupTransactionCountPerScale
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.measured_transaction.count": .int(
                        result.measuredTransactionCountPerScale
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.baseline_measurement.count": .int(
                        result.baselineMeasurementCount
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.doubled_measurement.count": .int(
                        result.doubledMeasurementCount
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.baseline_p95_ms": .double(
                        result.baselineMembershipP95Milliseconds
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.doubled_p95_ms": .double(
                        result.doubledMembershipP95Milliseconds
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.growth_percent": .double(
                        result.doubledOffscreenGrowthPercent
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.exactness": .int(
                        result.exactness ? 1 : 0
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.completed": .int(
                        result.completed ? 1 : 0
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.passed": .int(
                        result.passed ? 1 : 0
                    ),
                    "agentstudio.startup_diagnostic.native_table_pilot.failure_reason": .string(
                        result.failureReason?.rawValue ?? "none"
                    ),
                    "agentstudio.performance.sidebar.surface": .string("repo"),
                    "agentstudio.performance.sidebar.phase": .string(projectionTrigger.rawValue),
                    "agentstudio.performance.sidebar.query_state": .string("empty"),
                    "agentstudio.performance.sidebar.group_mode": .string("repo"),
                    "agentstudio.performance.sidebar.input.count": .int(
                        AppPolicies.SidebarPerformanceProof.repositoryCount
                            + AppPolicies.SidebarPerformanceProof.worktreeCount
                    ),
                ]) { _, newValue in newValue }
            ) { _, newValue in newValue }
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.command_exercised",
                phase: "startup_diagnostic_action",
                outcome: result.passed ? "succeeded" : "failed",
                attributes: attributes
            )
            performanceTraceRecorder?.record(
                .sidebarProjection,
                attributes: attributes
            )
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.completed",
                phase: "startup_diagnostic_action",
                outcome: result.passed ? "succeeded" : "failed",
                attributes: attributes
            )
        }

        func prepareSidebarPerformanceProofFixture(
            action: AgentStudioStartupDiagnosticAction
        ) async -> SidebarPerformanceProofFixture? {
            NSApp.activate(ignoringOtherApps: true)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
            await waitForStartupDiagnosticAppActivation()
            guard let terminalContainerBounds = await startupDiagnosticLaunchRestoreBounds() else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "missing_bounds"
                )
                return nil
            }
            if !launchRestoreObservationState.didComplete {
                await finishLaunchRestore(
                    using: terminalContainerBounds,
                    source: "sidebarPerformanceProofPreflight"
                )
            }
            guard
                let fixture = await SidebarPerformanceProofFixture.prepare(
                    store: store,
                    repositoryRoot: FileManager.default.homeDirectoryForCurrentUser,
                    openTerminal: {
                        try? await workspaceSurfaceCoordinator.openFloatingTerminal(
                            launchDirectory: FileManager.default.homeDirectoryForCurrentUser,
                            title: "Sidebar Performance Terminal"
                        )
                    })
            else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "terminal_fixture_failed"
                )
                return nil
            }
            workspaceSurfaceCoordinator.restoreVisiblePaneIfNeeded(
                fixture.paneId,
                forceWhenBoundsExist: true
            )
            await Task.yield()
            mainWindowController?.syncVisibleTerminalGeometry(reason: "sidebarPerformanceProof")
            let terminalRenderProof = await waitForIPCTerminalSmokeRenderProof(for: fixture.paneId)
            guard terminalRenderProof.succeeded else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "terminal_render_failed"
                )
                return nil
            }
            return fixture
        }

        func recordBlockedSidebarPerformanceProofDiagnostic(
            action: AgentStudioStartupDiagnosticAction,
            reason: String
        ) {
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.blocked",
                phase: "startup_diagnostic_action",
                outcome: "blocked",
                attributes: startupDiagnosticTraceAttributes(for: action).merging([
                    "agentstudio.startup_diagnostic.skip_reason": .string(reason)
                ]) { _, newValue in newValue }
            )
        }

    #endif

    private func runCrossTabMoveGeometrySmokeDiagnostic(
        action: AgentStudioStartupDiagnosticAction
    ) async {
        guard let terminalContainerBounds = await startupDiagnosticLaunchRestoreBounds() else {
            RestoreTrace.log("StartupDiagnostic.crossTabMoveGeometrySmoke skipped reason=missingBounds")
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.skipped",
                phase: "startup_diagnostic_action",
                outcome: "skipped",
                attributes: startupDiagnosticTraceAttributes(for: action).merging([
                    "agentstudio.startup_diagnostic.skip_reason": .string("missing_bounds")
                ]) { _, newValue in newValue }
            )
            return
        }

        if !launchRestoreObservationState.didComplete {
            await finishLaunchRestore(
                using: terminalContainerBounds,
                source: "crossTabMoveGeometrySmokePreflight"
            )
        }

        let fixture = createCrossTabMoveGeometrySmokeFixture()
        RestoreTrace.log(
            """
            StartupDiagnostic.crossTabMoveGeometrySmoke prepared sourceTab=\(fixture.sourceTabId) \
            destTab=\(fixture.destinationTabId) movedPane=\(fixture.movedPaneId) \
            sourceLeftPane=\(fixture.sourceLeftPaneId) targetPane=\(fixture.targetPaneId) \
            otherDestinationPane=\(fixture.otherDestinationPaneId) bounds=\(NSStringFromRect(terminalContainerBounds))
            """
        )

        mountCrossTabMoveGeometrySmokeFixture(
            fixture,
            terminalContainerBounds: terminalContainerBounds
        )
        mainWindowController?.syncVisibleTerminalGeometry(reason: "crossTabMoveGeometrySmokeBefore")
        await Task.yield()
        let applied = await executor.execute(
            .movePaneAcrossTabs(
                CrossTabPaneMoveRequest(
                    paneId: fixture.movedPaneId,
                    sourceTabId: fixture.sourceTabId,
                    destTabId: fixture.destinationTabId,
                    targetPaneId: fixture.targetPaneId,
                    direction: .horizontal,
                    position: .after
                )
            )
        )
        guard applied else {
            RestoreTrace.log("StartupDiagnostic.crossTabMoveGeometrySmoke mutationRejected")
            return
        }
        await Task.yield()
        mainWindowController?.syncVisibleTerminalGeometry(reason: "crossTabMoveGeometrySmokeAfter")
        let renderProof = crossTabMoveGeometrySmokeRenderProof(for: fixture)
        startupTraceRecorder.recordAppStartup(
            "app.startup_diagnostic_action.command_exercised",
            phase: "startup_diagnostic_action",
            outcome: "succeeded",
            attributes: startupDiagnosticTraceAttributes(for: action).merging(
                [
                    "agentstudio.startup_diagnostic.created_pane.count": .int(fixture.paneIds.count),
                    "agentstudio.startup_diagnostic.destination_initial_pane.count": .int(2),
                    "agentstudio.startup_diagnostic.fixture.tab.count": .int(2),
                ].merging(renderProof.attributes) { _, newValue in newValue }
            ) { _, newValue in newValue }
        )
        let renderProofSucceeded = renderProof.succeeded
        let finalMessage =
            renderProofSucceeded
            ? "app.startup_diagnostic_action.completed"
            : "app.startup_diagnostic_action.blocked"
        let finalOutcome = renderProofSucceeded ? "succeeded" : "blocked"
        RestoreTrace.log(
            """
            StartupDiagnostic.crossTabMoveGeometrySmoke \(finalOutcome) activeTab=\(store.tabLayoutAtom.activeTabId?.uuidString ?? "nil") \
            expectedVisiblePanes=\(renderProof.expectedVisiblePaneCount) fixtureTerminalViews=\(renderProof.terminalViewCount) \
            fixtureSurfaceIds=\(renderProof.surfaceIdCount) fixtureMountedSurfaces=\(renderProof.mountedSurfaceCount) \
            validGeometry=\(renderProof.validGeometryCount) fixturePanes=\(fixture.paneIds.count)
            """
        )
        startupTraceRecorder.recordAppStartup(
            finalMessage,
            phase: "startup_diagnostic_action",
            outcome: finalOutcome,
            attributes: startupDiagnosticTraceAttributes(for: action).merging(
                [
                    "agentstudio.startup_diagnostic.created_pane.count": .int(fixture.paneIds.count),
                    "agentstudio.startup_diagnostic.destination_initial_pane.count": .int(2),
                    "agentstudio.startup_diagnostic.fixture.tab.count": .int(2),
                ].merging(renderProof.attributes) { _, newValue in newValue }
            ) { _, newValue in newValue }
        )
    }

    func waitForStartupDiagnosticAppActivation() async {
        let clock = ContinuousClock()
        let start = clock.now
        while !NSApp.isActive
            && !Task.isCancelled
            && start.duration(to: clock.now) < AppPolicies.StartupDiagnostic.appActivationTimeout
        {
            do {
                try await Task.sleep(nanoseconds: Duration.milliseconds(50).nanosecondsForTaskSleep)
            } catch {
                return
            }
        }
    }

    func startupDiagnosticLaunchRestoreBounds() async -> CGRect? {
        if windowLifecycleStore.isReadyForLaunchRestore {
            return windowLifecycleStore.terminalContainerBounds
        }

        let bridge = WindowRestoreBridge(windowLifecycleStore: windowLifecycleStore)
        return await Self.firstLaunchRestoreBounds(
            from: bridge.stream,
            timeout: AppPolicies.StartupDiagnostic.launchRestoreBoundsTimeout
        )
    }

    nonisolated static func firstLaunchRestoreBounds(
        from stream: AsyncStream<CGRect>,
        timeout: Duration
    ) async -> CGRect? {
        await withTaskGroup(of: CGRect?.self, returning: CGRect?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeout.nanosecondsForTaskSleep)
                } catch {
                    return nil
                }
                return nil
            }

            guard let firstResult = await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return firstResult
        }
    }

    private func crossTabMoveGeometrySmokeRenderProof(
        for fixture: CrossTabMoveGeometrySmokeFixture
    ) -> CrossTabMoveGeometrySmokeRenderProof {
        let expectedVisiblePaneIds = fixture.expectedVisiblePaneIdsAfterMove
        let terminalViews = expectedVisiblePaneIds.compactMap { viewRegistry.terminalView(for: $0) }
        let mountedSurfaces = terminalViews.compactMap(\.ghosttySurface)
        let validGeometryCount = mountedSurfaces.filter(Self.surfaceHasValidSmokeGeometry).count

        return CrossTabMoveGeometrySmokeRenderProof(
            expectedVisiblePaneCount: expectedVisiblePaneIds.count,
            terminalViewCount: terminalViews.count,
            surfaceIdCount: expectedVisiblePaneIds.compactMap { viewRegistry.terminalView(for: $0)?.surfaceId }.count,
            mountedSurfaceCount: mountedSurfaces.count,
            validGeometryCount: validGeometryCount
        )
    }

    private func ipcTerminalSmokeRenderProof(for paneId: UUID) -> CrossTabMoveGeometrySmokeRenderProof {
        let terminalView = viewRegistry.terminalView(for: paneId)
        let mountedSurfaces = [terminalView?.ghosttySurface].compactMap { $0 }
        let validGeometryCount = mountedSurfaces.filter(Self.surfaceHasValidSmokeGeometry).count
        let runtime = workspaceSurfaceCoordinator.runtimeForPane(PaneId(existingUUID: paneId))

        return CrossTabMoveGeometrySmokeRenderProof(
            expectedVisiblePaneCount: 1,
            terminalViewCount: terminalView == nil ? 0 : 1,
            surfaceIdCount: terminalView?.surfaceId == nil ? 0 : 1,
            mountedSurfaceCount: mountedSurfaces.count,
            validGeometryCount: runtime?.lifecycle == .ready ? validGeometryCount : 0
        )
    }

    func waitForIPCTerminalSmokeRenderProof(for paneId: UUID) async -> CrossTabMoveGeometrySmokeRenderProof {
        let clock = ContinuousClock()
        let start = clock.now
        var proof = ipcTerminalSmokeRenderProof(for: paneId)
        while !proof.succeeded
            && !Task.isCancelled
            && start.duration(to: clock.now) < AppPolicies.StartupDiagnostic.ipcTerminalSmokeReadinessTimeout
        {
            do {
                try await Task.sleep(nanoseconds: Duration.milliseconds(50).nanosecondsForTaskSleep)
            } catch {
                return proof
            }
            mainWindowController?.syncVisibleTerminalGeometry(reason: "ipcTerminalSmokeReadiness")
            proof = ipcTerminalSmokeRenderProof(for: paneId)
        }
        return proof
    }

    private static func surfaceHasValidSmokeGeometry(_ surface: Ghostty.SurfaceView) -> Bool {
        frameIsFiniteAndPositive(surface.frame) && frameIsFiniteAndPositive(surface.bounds)
    }

    nonisolated static func frameIsFiniteAndPositive(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
            && rect.size.width > 0
            && rect.size.height > 0
    }

    private func createCrossTabMoveGeometrySmokeFixture() -> CrossTabMoveGeometrySmokeFixture {
        let movedPane = createCrossTabMoveGeometrySmokePane(title: "Smoke Move Source")
        let sourceLeftPane = createCrossTabMoveGeometrySmokePane(title: "Smoke Source Left")
        let targetPane = createCrossTabMoveGeometrySmokePane(title: "Smoke Destination Target")
        let otherDestinationPane = createCrossTabMoveGeometrySmokePane(title: "Smoke Destination Peer")
        for paneId in [movedPane.id, sourceLeftPane.id, targetPane.id, otherDestinationPane.id] {
            viewRegistry.ensureSlot(for: paneId)
        }

        let sourceTab = Tab(paneId: movedPane.id, name: "Smoke Source")
        let destinationTab = Tab(paneId: targetPane.id, name: "Smoke Destination")
        store.tabLayoutAtom.appendTab(sourceTab)
        store.tabLayoutAtom.appendTab(destinationTab)
        _ = store.tabLayoutAtom.insertPane(
            sourceLeftPane.id,
            inTab: sourceTab.id,
            at: movedPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        _ = store.tabLayoutAtom.insertPane(
            otherDestinationPane.id,
            inTab: destinationTab.id,
            at: targetPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        store.tabLayoutAtom.setActiveTab(destinationTab.id)

        return CrossTabMoveGeometrySmokeFixture(
            sourceTabId: sourceTab.id,
            destinationTabId: destinationTab.id,
            movedPaneId: movedPane.id,
            sourceLeftPaneId: sourceLeftPane.id,
            targetPaneId: targetPane.id,
            otherDestinationPaneId: otherDestinationPane.id
        )
    }

    private func mountCrossTabMoveGeometrySmokeFixture(
        _ fixture: CrossTabMoveGeometrySmokeFixture,
        terminalContainerBounds: CGRect
    ) {
        let resolvedPaneFramesByTabID = workspaceSurfaceCoordinator.resolveInitialFramesByTabId(
            in: terminalContainerBounds
        )
        for paneID in fixture.paneIds {
            guard viewRegistry.view(for: paneID) == nil,
                let pane = store.paneAtom.pane(paneID)
            else {
                continue
            }
            _ = workspaceSurfaceCoordinator.createViewForContent(
                pane: pane,
                initialFrame: workspaceSurfaceCoordinator.initialFrame(
                    for: pane,
                    resolvedPaneFramesByTabId: resolvedPaneFramesByTabID
                ),
                treatAsRestoredSessionStart: false
            )
        }
    }

    private func createCrossTabMoveGeometrySmokePane(title: String) -> Pane {
        store.paneAtom.createPane(
            title: title,
            provider: .zmx,
            lifetime: .temporary,
            zmxSessionID: .generateUUIDv7()
        )
    }

    func startupDiagnosticTraceAttributes(
        for action: AgentStudioStartupDiagnosticAction
    ) -> [String: AgentStudioTraceValue] {
        [
            "agentstudio.command.source": .string("startup_diagnostic"),
            "agentstudio.command.name": .string(action.commandName),
            "agentstudio.startup_diagnostic.action": .string(action.kind.rawValue),
        ]
    }
}

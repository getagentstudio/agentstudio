import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Observation

#if DEBUG
    struct SidebarPerformanceProofWindowAttendance: Equatable, Sendable {
        let applicationIsActive: Bool
        let applicationIsHidden: Bool
        let windowIsVisible: Bool
        let windowIsKey: Bool
        let windowIsMiniaturized: Bool
        let windowIsOnActiveSpace: Bool
        let windowOcclusionIsVisible: Bool

        var isAttended: Bool {
            applicationIsActive
                && !applicationIsHidden
                && windowIsVisible
                && windowIsKey
                && !windowIsMiniaturized
                && windowIsOnActiveSpace
                && windowOcclusionIsVisible
        }

        @MainActor
        static func capture(window: NSWindow) -> Self {
            Self(
                applicationIsActive: NSApp.isActive,
                applicationIsHidden: NSApp.isHidden,
                windowIsVisible: window.isVisible,
                windowIsKey: window.isKeyWindow,
                windowIsMiniaturized: window.isMiniaturized,
                windowIsOnActiveSpace: window.isOnActiveSpace,
                windowOcclusionIsVisible: window.occlusionState.contains(.visible)
            )
        }
    }

    enum StrictSidebarWindowAttendanceDisposition: String, Equatable, Sendable {
        case attended
        case timedOut = "timed_out"
        case cancelled
    }

    @MainActor
    private final class StrictRepositoryUpdateProgressObserver {
        let stream: AsyncStream<RepositoryFactUpdateProgress?>

        private weak var repoCache: RepoCacheAtom?
        private let repositoryID: UUID
        private let continuation: AsyncStream<RepositoryFactUpdateProgress?>.Continuation
        private var isObserving = true

        init(repoCache: RepoCacheAtom?, repositoryID: UUID) {
            self.repoCache = repoCache
            self.repositoryID = repositoryID
            (stream, continuation) = AsyncStream.makeStream(
                of: RepositoryFactUpdateProgress?.self,
                bufferingPolicy: .bufferingOldest(16)
            )
            observe()
        }

        deinit {
            continuation.finish()
        }

        private func observe() {
            guard isObserving else { return }
            let progress = withObservationTracking {
                repoCache?.repositoryFactUpdateProgress(for: repositoryID)
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.observe()
                }
            }
            continuation.yield(progress)
            if progress?.phase == .settled {
                isObserving = false
                continuation.finish()
            }
        }
    }

    private struct StrictSidebarPerformanceFixtureEvidence {
        let repositoryCount: Int
        let worktreeCount: Int
        let topologyFingerprint: String
        let expectedSessionCount: Int
        let controlRootPresent: Bool
        let warmRepositoryCount: Int
        let inactiveRepositoryCount: Int
        let unknownRepositoryCount: Int
        let seededInactiveRepositoryCount: Int
        let warmWorktreeCount: Int
        let inactiveWorktreeCount: Int
        let unknownWorktreeCount: Int
        let coldAutomaticDeadlineCount: Int
        let coldLocalAutomaticSourceStartCount: UInt64
        let coldFSEventLocalCompletionCount: Int
        let explicitSourceAdmittedCount: Int
        let explicitSourceTerminalCount: Int
        let explicitProgressSettledCount: Int
        let explicitLocalAdmittedCount: Int
        let explicitRemoteAdmittedCount: Int
        let explicitForgeAdmittedCount: Int
    }

    extension AppDelegate {
        func sidebarPerformanceProofPolicyAttributes() -> [String: AgentStudioTraceValue] {
            let policy = AppPolicies.SidebarPerformanceProof.self
            return [
                "agentstudio.startup_diagnostic.sidebar_proof.policy_id": .string(policy.policyID),
                "agentstudio.startup_diagnostic.sidebar_proof.policy_version": .int(policy.policyVersion),
                "agentstudio.startup_diagnostic.sidebar_proof.standard_trace_tags": .string(
                    policy.standardTraceTags.joined(separator: ",")),
                "agentstudio.startup_diagnostic.sidebar_proof.diagnostic_trace_tags": .string(
                    policy.diagnosticTraceTags.joined(separator: ",")),
                "agentstudio.startup_diagnostic.sidebar_proof.idle_populations": .string(
                    policy.idlePopulationNames.joined(separator: ",")),
                "agentstudio.startup_diagnostic.sidebar_proof.action_populations": .string(
                    policy.actionPopulationNames.joined(separator: ",")),
                "agentstudio.startup_diagnostic.sidebar_proof.idle_p99_max_percent": .double(
                    policy.idleProcessCPUP99MaximumPercent),
                "agentstudio.startup_diagnostic.sidebar_proof.action_p95_max_percent": .double(
                    policy.actionProcessCPUP95MaximumPercent),
                "agentstudio.startup_diagnostic.sidebar_proof.sample_interval_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(from: policy.sampleInterval)),
                "agentstudio.startup_diagnostic.sidebar_proof.metrics_export_interval_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(
                        from: policy.metricsExportInterval)),
                "agentstudio.startup_diagnostic.sidebar_proof.idle_sample_floor": .int(
                    policy.requiredIdleUsableSampleCount),
                "agentstudio.startup_diagnostic.sidebar_proof.action_count_floor": .int(
                    policy.requiredSuccessfulActionCount),
                "agentstudio.startup_diagnostic.sidebar_proof.action_sample_floor": .int(
                    policy.requiredActionBearingSampleCount),
                "agentstudio.startup_diagnostic.sidebar_proof.fixture_preparation_timeout_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(
                        from: policy.fixturePreparationTimeout)),
                "agentstudio.startup_diagnostic.sidebar_proof.fixture_state_observation_interval_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(
                        from: policy.fixtureStateObservationInterval)),
                "agentstudio.startup_diagnostic.sidebar_proof.fixture_tab_count": .int(
                    policy.strictTabCount),
                "agentstudio.startup_diagnostic.sidebar_proof.fixture_pane_model_count": .int(
                    policy.strictPaneModelCount),
                "agentstudio.startup_diagnostic.sidebar_proof.zero_pty_expected_session_count": .int(
                    policy.zeroPTYExpectedSessionCount),
                "agentstudio.startup_diagnostic.sidebar_proof.zmx_inventory_interval_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(
                        from: policy.zmxInventoryInterval)),
                "agentstudio.startup_diagnostic.sidebar_proof.search_character_count": .int(
                    policy.searchCharacterCount),
                "agentstudio.startup_diagnostic.sidebar_proof.search_character_interval_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(from: policy.searchCharacterInterval)),
                "agentstudio.startup_diagnostic.sidebar_proof.quiescence_interval_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(from: policy.quiescenceInterval)),
                "agentstudio.startup_diagnostic.sidebar_proof.readback_timeout_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(from: policy.actionReadbackTimeout)),
                "agentstudio.startup_diagnostic.sidebar_proof.sampler_gap_max_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(from: policy.maximumSamplerGap)),
                "agentstudio.startup_diagnostic.sidebar_proof.action_sample_boundary_offset_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(
                        from: policy.maximumActionSampleBoundaryOffset)),
                "agentstudio.startup_diagnostic.sidebar_proof.action_sample_start_offset_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(
                        from: policy.actionSampleStartOffset)),
                "agentstudio.startup_diagnostic.sidebar_proof.diagnostic_cpu_delta_max_points": .double(
                    policy.maximumDiagnosticCPUP95DeltaPercentagePoints),
                "agentstudio.startup_diagnostic.sidebar_proof.diagnostic_interaction_growth_max_percent": .double(
                    policy.maximumDiagnosticInteractionP95GrowthPercent),
                "agentstudio.startup_diagnostic.sidebar_proof.git_status_physical_limit": .int(
                    policy.gitStatusPhysicalLimit),
                "agentstudio.startup_diagnostic.sidebar_proof.remote_reference_physical_limit": .int(
                    policy.remoteReferencePhysicalLimit),
                "agentstudio.startup_diagnostic.sidebar_proof.forge_physical_limit": .int(
                    policy.forgePhysicalLimit),
                "agentstudio.startup_diagnostic.sidebar_proof.git_maximum_settlement_ms": .double(
                    AgentStudioPerformanceTraceRecorder.milliseconds(
                        from: policy.gitMaximumSettlementInterval)),
            ]
        }

        func runStrictSidebarCPUPopulationDiagnostic(
            action: AgentStudioStartupDiagnosticAction
        ) async {
            guard let population = SidebarPerformanceProofPopulation(kind: action.kind),
                let mainWindowController,
                let window = mainWindowController.window
            else {
                recordStrictSidebarPopulationResult(action: action, outcome: "failed")
                return
            }
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic.sidebar_proof.policy_projected",
                phase: "startup_diagnostic_action",
                outcome: "ready",
                attributes: startupDiagnosticTraceAttributes(for: action).merging(
                    sidebarPerformanceProofPolicyAttributes()
                ) { _, newValue in newValue }
            )
            let session = SidebarPerformanceProofSession(
                population: population,
                window: window,
                recorder: startupTraceRecorder,
                commandDispatcher: self.commandDispatcherForBoot(),
                performanceRecorder: performanceTraceRecorder,
                settleRepositoryFactDemandAdmission: { [weak workspaceSurfaceCoordinator] in
                    await workspaceSurfaceCoordinator?
                        .settleRepositoryFactDemandAdmissionForPerformanceProof()
                },
                readAttendance: { [weak self] in
                    self?.readStrictSidebarWindowAttendance(window: window)
                        ?? SidebarPerformanceProofWindowAttendance.capture(window: window)
                },
                readShell: { [weak mainWindowController] in
                    mainWindowController?.sidebarPerformanceProofShellReadback()
                }
            )
            sidebarPerformanceProofSession = session
            defer {
                if !population.isIdle {
                    sidebarPerformanceProofSession = nil
                }
            }

            guard
                let fixtureEvidence = await prepareStrictSidebarPerformanceProofFixture(
                    action: action,
                    population: population
                )
            else {
                recordStrictSidebarPopulationResult(action: action, outcome: "failed")
                return
            }
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic.sidebar_proof.fixture_ready",
                phase: "startup_diagnostic_action",
                outcome: "ready",
                attributes: startupDiagnosticTraceAttributes(for: action).merging(
                    strictSidebarFixtureReadyAttributes(fixtureEvidence)
                ) { _, newValue in newValue }
            )
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            let attendanceDisposition = await waitForStrictSidebarWindowAttendance(window)
            guard attendanceDisposition == .attended else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "window_attendance_\(attendanceDisposition.rawValue)"
                )
                recordStrictSidebarPopulationResult(action: action, outcome: "failed")
                return
            }
            mainWindowController.expandSidebar()
            self.commandDispatcherForBoot().dispatch(.showReposSidebar)
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.command_exercised",
                phase: "startup_diagnostic_action",
                outcome: "ready",
                attributes: startupDiagnosticTraceAttributes(for: action).merging(
                    sidebarPerformanceProofPolicyAttributes()
                ) { _, newValue in newValue }
            )
            let succeeded = await session.run()
            recordStrictSidebarPopulationResult(
                action: action,
                outcome: succeeded ? "succeeded" : "failed"
            )
        }

        private func strictSidebarFixtureReadyAttributes(
            _ fixtureEvidence: StrictSidebarPerformanceFixtureEvidence
        ) -> [String: AgentStudioTraceValue] {
            [
                "agentstudio.startup_diagnostic.sidebar_proof.open_source_root_present": .bool(true),
                "agentstudio.startup_diagnostic.sidebar_proof.project_dev_root_present": .bool(true),
                "agentstudio.startup_diagnostic.sidebar_proof.control_root_present": .bool(
                    fixtureEvidence.controlRootPresent),
                "agentstudio.startup_diagnostic.sidebar_proof.discovered_repository_count": .int(
                    fixtureEvidence.repositoryCount),
                "agentstudio.startup_diagnostic.sidebar_proof.discovered_worktree_count": .int(
                    fixtureEvidence.worktreeCount),
                "agentstudio.startup_diagnostic.sidebar_proof.topology_fingerprint": .string(
                    fixtureEvidence.topologyFingerprint),
                "agentstudio.startup_diagnostic.sidebar_proof.tab_count": .int(
                    AppPolicies.SidebarPerformanceProof.strictTabCount),
                "agentstudio.startup_diagnostic.sidebar_proof.pane_model_count": .int(
                    AppPolicies.SidebarPerformanceProof.strictPaneModelCount),
                "agentstudio.startup_diagnostic.sidebar_proof.expected_session_variant": .int(
                    fixtureEvidence.expectedSessionCount),
                "agentstudio.startup_diagnostic.sidebar_proof.warm_repository_count": .int(
                    fixtureEvidence.warmRepositoryCount),
                "agentstudio.startup_diagnostic.sidebar_proof.inactive_repository_count": .int(
                    fixtureEvidence.inactiveRepositoryCount),
                "agentstudio.startup_diagnostic.sidebar_proof.unknown_repository_count": .int(
                    fixtureEvidence.unknownRepositoryCount),
                "agentstudio.startup_diagnostic.sidebar_proof.seeded_inactive_repository_count": .int(
                    fixtureEvidence.seededInactiveRepositoryCount),
                "agentstudio.startup_diagnostic.sidebar_proof.warm_worktree_count": .int(
                    fixtureEvidence.warmWorktreeCount),
                "agentstudio.startup_diagnostic.sidebar_proof.inactive_worktree_count": .int(
                    fixtureEvidence.inactiveWorktreeCount),
                "agentstudio.startup_diagnostic.sidebar_proof.unknown_worktree_count": .int(
                    fixtureEvidence.unknownWorktreeCount),
                "agentstudio.startup_diagnostic.sidebar_proof.cold_automatic_deadline_count": .int(
                    fixtureEvidence.coldAutomaticDeadlineCount),
                "agentstudio.startup_diagnostic.sidebar_proof.cold_local_automatic_source_start_count": .int(
                    Int(clamping: fixtureEvidence.coldLocalAutomaticSourceStartCount)),
                "agentstudio.startup_diagnostic.sidebar_proof.cold_fsevent_local_completion_count": .int(
                    fixtureEvidence.coldFSEventLocalCompletionCount),
                "agentstudio.startup_diagnostic.sidebar_proof.explicit_source_admitted_count": .int(
                    fixtureEvidence.explicitSourceAdmittedCount),
                "agentstudio.startup_diagnostic.sidebar_proof.explicit_source_terminal_count": .int(
                    fixtureEvidence.explicitSourceTerminalCount),
                "agentstudio.startup_diagnostic.sidebar_proof.explicit_progress_settled_count": .int(
                    fixtureEvidence.explicitProgressSettledCount),
                "agentstudio.startup_diagnostic.sidebar_proof.explicit_local_admitted_count": .int(
                    fixtureEvidence.explicitLocalAdmittedCount),
                "agentstudio.startup_diagnostic.sidebar_proof.explicit_remote_admitted_count": .int(
                    fixtureEvidence.explicitRemoteAdmittedCount),
                "agentstudio.startup_diagnostic.sidebar_proof.explicit_forge_admitted_count": .int(
                    fixtureEvidence.explicitForgeAdmittedCount),
            ]
        }

        private func readStrictSidebarWindowAttendance(
            window: NSWindow
        ) -> SidebarPerformanceProofWindowAttendance {
            _ = appLifecycleStore.isActive
            _ = windowLifecycleStore.keyWindowId
            if let preferredWindowID = windowLifecycleStore.preferredWorkspaceWindowId {
                _ = windowLifecycleStore.presentationFacts(for: preferredWindowID)
            }
            return SidebarPerformanceProofWindowAttendance.capture(window: window)
        }

        private func waitForStrictSidebarWindowAttendance(
            _ window: NSWindow
        ) async -> StrictSidebarWindowAttendanceDisposition {
            let clock = ContinuousClock()
            let start = clock.now
            while true {
                let attendance = SidebarPerformanceProofWindowAttendance.capture(window: window)
                if let disposition = Self.strictSidebarWindowAttendanceDisposition(
                    for: attendance,
                    taskIsCancelled: Task.isCancelled,
                    deadlineReached: start.duration(to: clock.now)
                        >= AppPolicies.SidebarPerformanceProof.actionReadbackTimeout
                ) {
                    return disposition
                }
                do {
                    try await AsyncDelay.taskSleep.wait(
                        AppPolicies.SidebarPerformanceProof.fixtureStateObservationInterval)
                } catch {
                    return .cancelled
                }
            }
        }

        static func strictSidebarWindowAttendanceDisposition(
            for attendance: SidebarPerformanceProofWindowAttendance,
            taskIsCancelled: Bool,
            deadlineReached: Bool
        ) -> StrictSidebarWindowAttendanceDisposition? {
            if taskIsCancelled { return .cancelled }
            if attendance.isAttended { return .attended }
            if deadlineReached { return .timedOut }
            return nil
        }

        private func prepareStrictSidebarPerformanceProofFixture(
            action: AgentStudioStartupDiagnosticAction,
            population: SidebarPerformanceProofPopulation
        ) async -> StrictSidebarPerformanceFixtureEvidence? {
            guard let (controlRootURL, coldProof) = await prepareStrictSidebarControl(action: action)
            else { return nil }
            guard
                let watchedPaths = SidebarPerformanceProofFixture.registerStrictWatchedRoots(
                    store: store,
                    controlRootURL: controlRootURL
                )
            else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "required_watched_roots_unavailable"
                )
                return nil
            }
            guard let summary = await refreshStrictWatchedRootsAndAwaitZeroLogicalDebt(watchedPaths)
            else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "required_watched_root_scan_timeout_or_debt"
                )
                return nil
            }
            let rootURLs = SidebarPerformanceProofFixture.strictWatchedRootURLs
            guard
                rootURLs.allSatisfy({ rootURL in
                    !summary.repoPaths(in: rootURL).isEmpty
                }),
                summary.repoPaths(in: controlRootURL) == [controlRootURL],
                summary.filesystemLogicalDebtCount == 0,
                let topologyFingerprint = summary.topologyFingerprint
            else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "required_watched_root_scan_incomplete"
                )
                return nil
            }

            await workspaceSurfaceCoordinator.syncFilesystemRootsAndActivityUntilIdle()
            guard prepareStrictSidebarPaneFleet(action: action, controlRootURL: controlRootURL) else { return nil }
            await workspaceSurfaceCoordinator.settleRepositoryFactDemandAdmissionForPerformanceProof()
            guard
                let seededInactiveRepositoryCount = await prepareStrictSidebarHistoricalInactiveActivity(
                    action: action,
                    summary: summary,
                    rootURLs: rootURLs
                )
            else { return nil }
            let activity = await strictSidebarRepositoryActivityClassification()
            guard !activity.warmRepositoryIDs.isEmpty,
                !activity.locallyInactiveRepositoryIDs.isEmpty,
                !activity.unknownRepositoryIDs.isEmpty,
                !activity.warmWorktreeIDs.isEmpty,
                !activity.locallyInactiveWorktreeIDs.isEmpty,
                !activity.unknownWorktreeIDs.isEmpty,
                let gitDebt = await workspaceSurfaceCoordinator?
                    .gitLogicalDebtSnapshotForPerformanceProof()
            else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "warm_cold_activity_fixture_incomplete"
                )
                return nil
            }

            let repositoryCount = rootURLs.reduce(into: 0) { count, rootURL in
                count += summary.repoPaths(in: rootURL).count
            }
            let linkedWorktreeCount = rootURLs.reduce(into: 0) { count, rootURL in
                count += summary.linkedWorktreePaths(in: rootURL).count
            }
            return StrictSidebarPerformanceFixtureEvidence(
                repositoryCount: repositoryCount,
                worktreeCount: repositoryCount + linkedWorktreeCount,
                topologyFingerprint: topologyFingerprint,
                expectedSessionCount: AppPolicies.SidebarPerformanceProof.zeroPTYExpectedSessionCount,
                controlRootPresent: true,
                warmRepositoryCount: activity.warmRepositoryIDs.count,
                inactiveRepositoryCount: activity.locallyInactiveRepositoryIDs.count,
                unknownRepositoryCount: activity.unknownRepositoryIDs.count,
                seededInactiveRepositoryCount: seededInactiveRepositoryCount,
                warmWorktreeCount: activity.warmWorktreeIDs.count,
                inactiveWorktreeCount: activity.locallyInactiveWorktreeIDs.count,
                unknownWorktreeCount: activity.unknownWorktreeIDs.count,
                coldAutomaticDeadlineCount: gitDebt.inactiveAutomaticDeadlineCount,
                coldLocalAutomaticSourceStartCount: gitDebt.inactiveAutomaticSourceStartCount,
                coldFSEventLocalCompletionCount: coldProof.localCompletionCount,
                explicitSourceAdmittedCount: coldProof.admittedSourceCount,
                explicitSourceTerminalCount: coldProof.terminalSourceCount,
                explicitProgressSettledCount: coldProof.progressSettledCount,
                explicitLocalAdmittedCount: coldProof.localAdmittedCount,
                explicitRemoteAdmittedCount: coldProof.remoteAdmittedCount,
                explicitForgeAdmittedCount: coldProof.forgeAdmittedCount
            )
        }

        private func prepareStrictSidebarPaneFleet(
            action: AgentStudioStartupDiagnosticAction,
            controlRootURL: URL
        ) -> Bool {
            guard
                SidebarPerformanceProofFixture.populateStrictPaneFleet(
                    store: store,
                    viewRegistry: viewRegistry,
                    placeholderFileURL: controlRootURL.appendingPathComponent("baseline.txt")
                )
            else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "pane_fleet_failed"
                )
                return false
            }
            return true
        }

        private struct StrictColdRepositoryProof {
            let localCompletionCount: Int
            let admittedSourceCount: Int
            let terminalSourceCount: Int
            let progressSettledCount: Int
            let localAdmittedCount: Int
            let remoteAdmittedCount: Int
            let forgeAdmittedCount: Int
        }

        private func proveStrictColdRepositoryControl(
            _ controlRootURL: URL
        ) async -> StrictColdRepositoryProof? {
            let topology = store.repositoryTopologyAtom
            guard
                let repository = topology.repositoryIdsInOrder.lazy.compactMap({ topology.repo($0) })
                    .first(where: { $0.repoPath.standardizedFileURL == controlRootURL.standardizedFileURL }),
                let worktree = repository.worktrees.first(where: \.isMainWorktree)
            else { return nil }
            let beforeActivity = await strictSidebarRepositoryActivityClassification()
            guard
                Self.strictColdRepositoryControlIsEligible(
                    repositoryID: repository.id,
                    activity: beforeActivity
                )
            else { return nil }
            let coldMutationURL = controlRootURL.appendingPathComponent(
                "sidebar-cold-proof-change.txt")
            guard await Self.writeStrictColdMutation(at: coldMutationURL) else { return nil }
            guard
                await waitForStrictColdLocalCompletion(
                    worktreeID: worktree.id,
                    repositoryID: repository.id
                )
            else { return nil }
            guard await Self.removeStrictColdMutation(at: coldMutationURL) else { return nil }
            let progressObserver = StrictRepositoryUpdateProgressObserver(
                repoCache: repoCache,
                repositoryID: repository.id
            )
            guard
                let coldDebt = await workspaceSurfaceCoordinator?
                    .gitLogicalDebtSnapshotForPerformanceProof(),
                coldDebt.inactiveAutomaticDeadlineCount == 0,
                coldDebt.inactiveAutomaticSourceStartCount == 0,
                self.commandDispatcherForBoot().dispatch(
                    .updateRepositoryFacts,
                    target: repository.id,
                    targetType: .repo,
                    executionContext: .interactive
                )
            else { return nil }
            guard
                let settledProgress = await waitForStrictRepositoryUpdateSettlement(
                    progressStream: progressObserver.stream
                ),
                Self.strictRemoteRepositoryUpdateCompleted(settledProgress)
            else { return nil }
            let afterActivity = await strictSidebarRepositoryActivityClassification()
            guard afterActivity.warmRepositoryIDs.contains(repository.id)
            else { return nil }
            return StrictColdRepositoryProof(
                localCompletionCount: 1,
                admittedSourceCount: settledProgress.applicableSources.count,
                terminalSourceCount: settledProgress.settledResultsBySource.count,
                progressSettledCount: 1,
                localAdmittedCount: settledProgress.applicableSources.contains(.localGit) ? 1 : 0,
                remoteAdmittedCount: settledProgress.applicableSources.contains(.remoteReferences) ? 1 : 0,
                forgeAdmittedCount: settledProgress.applicableSources.contains(.forge) ? 1 : 0
            )
        }

        static func strictColdRepositoryControlIsEligible(
            repositoryID: UUID,
            activity: RepositoryActivityClassification
        ) -> Bool {
            activity.unknownRepositoryIDs.contains(repositoryID)
        }

        static func strictRemoteRepositoryUpdateCompleted(
            _ progress: RepositoryFactUpdateProgress
        ) -> Bool {
            progress.phase == .settled
                && progress.applicableSources == [.remoteReferences]
                && progress.unsettledSources.isEmpty
                && progress.settledResultsBySource == [.remoteReferences: .completed]
        }

        private func waitForStrictColdLocalCompletion(
            worktreeID: UUID,
            repositoryID: UUID
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + AppPolicies.SidebarPerformanceProof.fixturePreparationTimeout
            while clock.now < deadline {
                if Self.strictColdLocalCompletionObserved(
                    repoCache?.worktreeEnrichment(for: worktreeID)
                ) {
                    // Registration may read the file before its FSEvent checkpoint.
                    // Require the activity owner's promotion before removing the stimulus.
                    let activity = await strictSidebarRepositoryActivityClassification()
                    if activity.warmRepositoryIDs.contains(repositoryID) { return true }
                }
                do {
                    try await AsyncDelay.taskSleep.wait(
                        AppPolicies.SidebarPerformanceProof.fixtureStateObservationInterval)
                } catch { return false }
            }
            recordStrictColdActivityTimeout(repositoryID: repositoryID, worktreeID: worktreeID)
            return false
        }

        private func recordStrictColdActivityTimeout(repositoryID: UUID, worktreeID: UUID) {
            guard let action = AgentStudioStartupDiagnosticAction.fromEnvironment() else { return }
            let topology = store.repositoryTopologyAtom
            let activity = atomStore.core.repositoryLocalActivity
            let storedKey = topology.repositoryStableKey(for: repositoryID)
            let computedKey = topology.repo(repositoryID)?.stableKey
            let record = storedKey.flatMap { activity.activity(for: $0) }
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.blocked",
                phase: "startup_diagnostic_action",
                outcome: "blocked",
                attributes: startupDiagnosticTraceAttributes(for: action).merging([
                    "agentstudio.startup_diagnostic.skip_reason": .string("cold_activity_publication_timeout"),
                    "agentstudio.startup_diagnostic.sidebar_proof.control_keys_match": .bool(storedKey == computedKey),
                    "agentstudio.startup_diagnostic.sidebar_proof.control_activity_authoritative": .bool(
                        activity.hydrationDisposition == .authoritative),
                    "agentstudio.startup_diagnostic.sidebar_proof.control_activity_present": .bool(record != nil),
                    "agentstudio.startup_diagnostic.sidebar_proof.control_qualifying_activity_present": .bool(
                        record?.lastQualifyingActivityAt != nil),
                    "agentstudio.startup_diagnostic.sidebar_proof.control_promotion_unsettled": .bool(
                        record?.ownedPromotionUnsettled == true),
                    "agentstudio.startup_diagnostic.sidebar_proof.control_untracked_present": .bool(
                        Self.strictColdLocalCompletionObserved(repoCache?.worktreeEnrichment(for: worktreeID))),
                ]) { _, newValue in newValue }
            )
        }

        @concurrent nonisolated private static func writeStrictColdMutation(
            at mutationURL: URL
        ) async -> Bool {
            do {
                try Data("cold repository local correctness".utf8).write(
                    to: mutationURL,
                    options: .atomic
                )
                return true
            } catch { return false }
        }

        @concurrent nonisolated private static func removeStrictColdMutation(
            at mutationURL: URL
        ) async -> Bool {
            do {
                try FileManager.default.removeItem(at: mutationURL)
                return true
            } catch { return false }
        }

        static func strictColdLocalCompletionObserved(
            _ enrichment: WorktreeEnrichment?
        ) -> Bool {
            GitBranchStatus.status(
                enrichment: enrichment,
                pullRequestFacts: nil
            ).untrackedFileCount > 0
        }

        private func waitForStrictRepositoryUpdateSettlement(
            progressStream: AsyncStream<RepositoryFactUpdateProgress?>
        ) async -> RepositoryFactUpdateProgress? {
            await withTaskGroup(of: RepositoryFactUpdateProgress?.self) { group in
                group.addTask {
                    for await progress in progressStream {
                        guard let progress else { continue }
                        switch progress.phase {
                        case .captured:
                            continue
                        case .inProgress:
                            continue
                        case .settled:
                            return progress
                        }
                    }
                    return nil
                }
                group.addTask {
                    do {
                        try await AsyncDelay.taskSleep.wait(
                            AppPolicies.SidebarPerformanceProof.fixturePreparationTimeout)
                    } catch {}
                    return nil
                }
                let result = await group.next()
                group.cancelAll()
                guard let result else { return nil }
                return result
            }
        }

        private func strictSidebarRepositoryActivityClassification() async
            -> RepositoryActivityClassification
        {
            let input = captureStrictSidebarRepositoryActivityInput(referenceDate: Date())
            return await Self.classifyStrictSidebarRepositoryActivity(input)
        }

        func captureStrictSidebarRepositoryActivityInput(
            referenceDate: Date
        ) -> RepositoryActivityClassificationInput {
            SidebarPerformanceProofFixture.captureRepositoryActivityInput(
                store: store,
                repositoryLocalActivity: atomStore.core.repositoryLocalActivity,
                referenceDate: referenceDate
            )
        }

        @concurrent nonisolated private static func classifyStrictSidebarRepositoryActivity(
            _ input: RepositoryActivityClassificationInput
        ) async -> RepositoryActivityClassification {
            RepositoryActivityClassifier.classify(input)
        }

        private func prepareStrictSidebarControl(
            action: AgentStudioStartupDiagnosticAction
        ) async -> (controlRootURL: URL, coldProof: StrictColdRepositoryProof)? {
            guard let controlRootURL = action.sidebarPerformanceControlRootURL() else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "continuity_control_root_unavailable"
                )
                return nil
            }
            guard
                let watchedPath = store.mutationCoordinator.addWatchedPath(controlRootURL)
            else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "continuity_control_root_unavailable"
                )
                return nil
            }
            // Prove the control before fleet registration queues background Git work.
            // Registration establishes coverage; only the real mutation supplies activity.
            guard
                let controlSummary = await refreshStrictWatchedRootsAndAwaitZeroLogicalDebt([watchedPath]),
                controlSummary.repoPaths(in: controlRootURL) == [controlRootURL],
                controlSummary.filesystemLogicalDebtCount == 0
            else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "continuity_control_scan_incomplete"
                )
                return nil
            }
            // A completed inventory scan does not join the separate source-registration lane.
            // Its participants and stable-key bindings must exist before the stimulus is written.
            await workspaceSurfaceCoordinator.syncFilesystemRootsAndActivityUntilIdle()
            atomStore.core.workspaceSidebarState.setSidebarSurface(.repos)
            mainWindowController?.expandSidebar()
            guard let coldProof = await proveStrictColdRepositoryControl(controlRootURL) else {
                recordBlockedSidebarPerformanceProofDiagnostic(
                    action: action,
                    reason: "cold_repository_control_failed"
                )
                return nil
            }
            return (controlRootURL, coldProof)
        }

        private func refreshStrictWatchedRootsAndAwaitZeroLogicalDebt(
            _ watchedPaths: [WatchedPath]
        ) async -> WatchedFolderRefreshSummary? {
            let commands = watchedFolderCommands!
            let timeout = AppPolicies.SidebarPerformanceProof.fixturePreparationTimeout
            let observationInterval = AppPolicies.SidebarPerformanceProof.fixtureStateObservationInterval
            return await withTaskGroup(of: WatchedFolderRefreshSummary?.self) { group in
                group.addTask {
                    let summary = await commands.refreshWatchedFolders(watchedPaths)
                    while !Task.isCancelled {
                        let logicalDebtCount = await commands.filesystemLogicalDebtCount()
                        if logicalDebtCount == 0 {
                            return summary.replacingFilesystemLogicalDebtCount(logicalDebtCount)
                        }
                        do {
                            try await AsyncDelay.taskSleep.wait(observationInterval)
                        } catch {
                            return nil
                        }
                    }
                    return nil
                }
                group.addTask {
                    do {
                        try await AsyncDelay.taskSleep.wait(timeout)
                    } catch {
                        return nil
                    }
                    return nil
                }
                guard let result = await group.next() else {
                    group.cancelAll()
                    return nil
                }
                group.cancelAll()
                return result
            }
        }

        private func recordStrictSidebarPopulationResult(
            action: AgentStudioStartupDiagnosticAction,
            outcome: String
        ) {
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.completed",
                phase: "startup_diagnostic_action",
                outcome: outcome,
                attributes: startupDiagnosticTraceAttributes(for: action).merging(
                    sidebarPerformanceProofPolicyAttributes()
                ) { _, newValue in newValue }
            )
        }
    }

    @MainActor
    struct SidebarPerformanceProofNativeInputDriver {
        private let delay: AsyncDelay

        init(delay: AsyncDelay = .taskSleep) {
            self.delay = delay
        }

        func typeFixtureQuery(in window: NSWindow) async -> Bool {
            let query = AppPolicies.SidebarPerformanceProof.fixtureQuery
            guard query.count == AppPolicies.SidebarPerformanceProof.searchCharacterCount,
                window.firstResponder is NSTextView
            else { return false }

            for character in query {
                guard let keyCode = Self.keyCodeByCharacter[character],
                    sendKey(
                        character: String(character),
                        keyCode: keyCode,
                        modifiers: [],
                        to: window
                    )
                else { return false }
                do {
                    try await delay.wait(AppPolicies.SidebarPerformanceProof.searchCharacterInterval)
                } catch {
                    return false
                }
            }

            return (window.firstResponder as? NSTextView)?.string == query
        }

        func clearFixtureQuery(in window: NSWindow) -> Bool {
            guard sendKey(character: "a", keyCode: 0, modifiers: [.command], to: window),
                sendKey(character: "", keyCode: 51, modifiers: [], to: window)
            else { return false }
            return (window.firstResponder as? NSTextView)?.string.isEmpty == true
        }

        private func sendKey(
            character: String,
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags,
            to window: NSWindow
        ) -> Bool {
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: character,
                    charactersIgnoringModifiers: character,
                    isARepeat: false,
                    keyCode: keyCode
                )
            else { return false }
            window.sendEvent(event)
            return true
        }

        private static let keyCodeByCharacter: [Character: UInt16] = [
            "w": 13,
            "o": 31,
            "r": 15,
            "k": 40,
            "t": 17,
            "e": 14,
        ]
    }
#endif

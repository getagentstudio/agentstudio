import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AppKit
import Foundation

#if DEBUG
    @MainActor
    extension AppDelegate {
        func runRepoExplorerKeyMutationProofDiagnostic(
            action: AgentStudioStartupDiagnosticAction
        ) async {
            NSApp.activate(ignoringOtherApps: true)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
            await waitForStartupDiagnosticAppActivation()
            guard let terminalContainerBounds = await startupDiagnosticLaunchRestoreBounds() else {
                recordRepoExplorerKeyMutationBlocked(action: action, reason: "missing_bounds")
                return
            }
            if !launchRestoreObservationState.didComplete {
                await finishLaunchRestore(
                    using: terminalContainerBounds,
                    source: "repoExplorerKeyMutationProofPreflight"
                )
            }

            let fixtureApplySequence = currentRepoExplorerMainActorApplySequence()
            guard
                let fixture = await SidebarPerformanceProofFixture.prepare(
                    store: store,
                    repositoryRoot: FileManager.default.homeDirectoryForCurrentUser,
                    openTerminal: {
                        try? await workspaceSurfaceCoordinator.openFloatingTerminal(
                            launchDirectory: FileManager.default.homeDirectoryForCurrentUser,
                            title: "Repo Explorer Key Mutation Proof"
                        )
                    })
            else {
                recordRepoExplorerKeyMutationBlocked(action: action, reason: "terminal_fixture_failed")
                return
            }

            guard
                await settleRepoExplorerProjection(
                    fixture: fixture,
                    fixtureApplySequence: fixtureApplySequence,
                    action: action
                )
            else { return }

            await runRepoExplorerKeyMutationPhase(
                action: action,
                phase: "rendered_repo_pinned",
                keyClass: "rendered_repo_pinned"
            ) { await self.runRenderedRepoPinnedMutations() }
            await runRepoExplorerKeyMutationPhase(
                action: action,
                phase: "rendered_worktree_fact",
                keyClass: "rendered_worktree_fact"
            ) { await self.runRenderedWorktreeFactMutations() }
            await runRepoExplorerKeyMutationPhase(
                action: action,
                phase: "relevant_key",
                keyClass: "relevant"
            ) { await self.runRelevantTopologyKeyMutations() }
            await runRepoExplorerKeyMutationPhase(
                action: action,
                phase: "unrelated_tab_arrangement_pane",
                keyClass: "unrelated_tab_arrangement_pane"
            ) {
                await self.runUnrelatedArrangementMutations(
                    tabId: fixture.tabId,
                    leftPaneId: fixture.paneId,
                    rightPaneId: fixture.arrangementPaneId
                )
            }
            await runRepoExplorerKeyMutationPhase(
                action: action,
                phase: "observed_tab_title_informational",
                keyClass: "observed_tab_title"
            ) { await self.runObservedTabTitleMutations(tabId: fixture.tabId) }
            await runRepoExplorerKeyMutationPhase(
                action: action,
                phase: "unrendered_attendance",
                keyClass: "unrendered_attendance",
                facet: "attendance",
                rowRelation: "unrendered"
            ) { await self.runAttendanceMutations(paneId: UUIDv7.generate()) }
            await runRepoExplorerKeyMutationPhase(
                action: action,
                phase: "pane_activity_facet_change",
                keyClass: "relevant",
                facet: "activity",
                rowRelation: "owning"
            ) { await self.runPaneActivityFacetMutations(paneId: fixture.paneId) }
            await runRepoExplorerKeyMutationPhase(
                action: action,
                phase: "missing_key_insertion",
                keyClass: "missing_declared_key"
            ) { await self.runMissingTopologyKeyInsertions() }

            let attributes = startupDiagnosticTraceAttributes(for: action).merging([
                "agentstudio.startup_diagnostic.repo_explorer_key_mutation.count": .int(802)
            ]) { _, newValue in newValue }
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.command_exercised",
                phase: "startup_diagnostic_action",
                outcome: "succeeded",
                attributes: attributes
            )
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.completed",
                phase: "startup_diagnostic_action",
                outcome: "succeeded",
                attributes: attributes
            )
        }

        func runRepoExplorerInteractionProofDiagnostic(
            action: AgentStudioStartupDiagnosticAction
        ) async {
            NSApp.activate(ignoringOtherApps: true)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
            await waitForStartupDiagnosticAppActivation()
            self.commandDispatcherForBoot().dispatch(.showCommandBarEverything)
            await Task.yield()
            recordRepoExplorerKeyMutationStep(action: action, phase: "command_bar_open", count: 1)
            commandBarController.dismiss()
            await Task.yield()
            recordRepoExplorerKeyMutationStep(action: action, phase: "command_bar_close", count: 1)
            recordRepoExplorerKeyMutationStep(action: action, phase: "tab_move_program_instrument_gap", count: 0)
            recordRepoExplorerKeyMutationStep(action: action, phase: "cmd_r_program_instrument_gap", count: 0)
            recordRepoExplorerKeyMutationStep(action: action, phase: "divider_program_instrument_gap", count: 0)
            let attributes = startupDiagnosticTraceAttributes(for: action)
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.completed",
                phase: "startup_diagnostic_action",
                outcome: "succeeded",
                attributes: attributes
            )
        }

        private func currentRepoExplorerMainActorApplySequence() -> UInt64 {
            RepoExplorerPerformanceTelemetry.shared.sequence(for: "mainactor_apply")
        }

        private func runRepoExplorerKeyMutationPhase(
            action: AgentStudioStartupDiagnosticAction,
            phase: String,
            keyClass: String,
            facet: String? = nil,
            rowRelation: String? = nil,
            mutations: () async -> Void
        ) async {
            recordRepoExplorerKeyMutationStep(action: action, phase: "\(phase)_start", count: 0)
            RepoExplorerPerformanceTelemetry.shared.setContext(
                keyClass: keyClass,
                facet: facet,
                rowRelation: rowRelation
            )
            await mutations()
            await Task.yield()
            await Task.yield()
            RepoExplorerPerformanceTelemetry.shared.setContext(keyClass: nil)
            recordRepoExplorerKeyMutationStep(action: action, phase: "\(phase)_settled")
            recordRepoExplorerKeyMutationStep(action: action, phase: "\(phase)_end")
        }

        private func waitForRepoExplorerProjectionReadiness(
            fixture: SidebarPerformanceProofFixture
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: AppPolicies.StartupDiagnostic.appActivationTimeout)
            repeat {
                let repositoryTopologyAtom = store.repositoryTopologyAtom
                if repositoryTopologyAtom.repositoryIdsInOrder.contains(fixture.repositoryId),
                    repositoryTopologyAtom.worktreeIdsInOrder.contains(fixture.worktreeId)
                {
                    return true
                }
                await Task.yield()
            } while clock.now < deadline
            return false
        }

        private func recordRepoExplorerAtomSlotMutation() {
            RepoExplorerPerformanceTelemetry.shared.record(
                stage: "atom_slot",
                outcome: "changed"
            )
        }

        private func settleRepoExplorerProjection(
            fixture: SidebarPerformanceProofFixture,
            fixtureApplySequence: UInt64,
            action: AgentStudioStartupDiagnosticAction
        ) async -> Bool {
            RepoExplorerPerformanceTelemetry.shared.setContext(keyClass: "diagnostic_settle")
            defer { RepoExplorerPerformanceTelemetry.shared.setContext(keyClass: nil) }
            atomStore.core.workspaceSidebarState.setSidebarSurface(.repos)
            mainWindowController?.expandSidebar()
            guard await waitForRepoExplorerProjectionReadiness(fixture: fixture) else {
                recordRepoExplorerKeyMutationBlocked(action: action, reason: "repo_explorer_projection_not_ready")
                return false
            }
            guard await waitForRepoExplorerKeyedWakeStage("mainactor_apply", after: fixtureApplySequence) else {
                recordRepoExplorerKeyMutationBlocked(action: action, reason: "repo_explorer_projection_not_settled")
                return false
            }
            return true
        }

        private func waitForRepoExplorerKeyedWakeStage(
            _ stage: String,
            after sequence: UInt64
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: AppPolicies.StartupDiagnostic.appActivationTimeout)
            repeat {
                if RepoExplorerPerformanceTelemetry.shared.sequence(for: stage) > sequence {
                    return true
                }
                await Task.yield()
            } while clock.now < deadline
            return false
        }

        private func runRenderedRepoPinnedMutations() async {
            guard let repository = store.repositoryTopologyAtom.repos.first else { return }
            var nextPinnedState = !repository.isPinned
            for _ in 0..<100 {
                let captureSequence = RepoExplorerPerformanceTelemetry.shared.sequence(
                    for: "capture_rebuild"
                )
                store.mutationCoordinator.setRepoPinned(
                    repository.id,
                    isPinned: nextPinnedState
                )
                nextPinnedState.toggle()
                recordRepoExplorerAtomSlotMutation()
                guard
                    await waitForRepoExplorerKeyedWakeStage(
                        "capture_rebuild",
                        after: captureSequence
                    )
                else { return }
            }
        }

        private func runRenderedWorktreeFactMutations() async {
            guard
                let repository = store.repositoryTopologyAtom.repos.first,
                let worktree = repository.worktrees.first
            else { return }
            var enrichment =
                atomStore.core.repoCache.worktreeEnrichment(for: worktree.id)
                ?? WorktreeEnrichment(
                    worktreeId: worktree.id,
                    repoId: repository.id,
                    branch: "diagnostic-a",
                    isMainWorktree: worktree.isMainWorktree
                )
            for _ in 0..<100 {
                let captureSequence = RepoExplorerPerformanceTelemetry.shared.sequence(
                    for: "capture_rebuild"
                )
                enrichment.updateBranch(enrichment.branch == "diagnostic-a" ? "diagnostic-b" : "diagnostic-a")
                atomStore.core.repoCache.setWorktreeEnrichment(enrichment)
                recordRepoExplorerAtomSlotMutation()
                guard
                    await waitForRepoExplorerKeyedWakeStage(
                        "capture_rebuild",
                        after: captureSequence
                    )
                else { return }
            }
        }

        private func runRelevantTopologyKeyMutations() async {
            guard let repository = store.repositoryTopologyAtom.repos.first else { return }
            var nextPinnedState = !repository.isPinned
            for _ in 0..<100 {
                let captureSequence = RepoExplorerPerformanceTelemetry.shared.sequence(
                    for: "capture_rebuild"
                )
                store.mutationCoordinator.setRepoPinned(
                    repository.id,
                    isPinned: nextPinnedState
                )
                nextPinnedState.toggle()
                recordRepoExplorerAtomSlotMutation()
                guard
                    await waitForRepoExplorerKeyedWakeStage(
                        "capture_rebuild",
                        after: captureSequence
                    )
                else { return }
            }
        }

        private func runUnrelatedArrangementMutations(
            tabId: UUID,
            leftPaneId: UUID,
            rightPaneId: UUID
        ) async {
            for mutationIndex in 0..<100 {
                store.tabLayoutAtom.resizeVisiblePanePair(
                    tabId: tabId,
                    leftPaneId: leftPaneId,
                    rightPaneId: rightPaneId,
                    ratio: mutationIndex.isMultiple(of: 2) ? 0.4 : 0.6
                )
                recordRepoExplorerAtomSlotMutation()
                await Task.yield()
            }
        }

        private func runObservedTabTitleMutations(tabId: UUID) async {
            for mutationIndex in 0..<100 {
                store.tabLayoutAtom.renameTab(tabId, name: "Observed Tab \(mutationIndex)")
                recordRepoExplorerAtomSlotMutation()
                await Task.yield()
            }
        }

        private func runAttendanceMutations(paneId: UUID) async {
            for _ in 0..<100 {
                atomStore.bridgePaneAttendance.record(.paneFocus, for: paneId)
                recordRepoExplorerAtomSlotMutation()
                await Task.yield()
            }
        }

        private func runPaneActivityFacetMutations(paneId: UUID) async {
            for mutationIndex in 0..<100 {
                if mutationIndex.isMultiple(of: 2) {
                    atomStore.core.paneActivityStatus.recordSettledActivity(
                        paneId: paneId,
                        lastOutputLine: "Diagnostic activity \(mutationIndex)"
                    )
                } else {
                    atomStore.core.paneActivityStatus.clear(paneId: paneId)
                }
                recordRepoExplorerAtomSlotMutation()
                await Task.yield()
            }
        }

        private func runMissingTopologyKeyInsertions() async {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appending(path: "agentstudio-repo-explorer-missing")
            for _ in 0..<50 {
                var membershipSequence = RepoExplorerPerformanceTelemetry.shared.sequence(
                    for: "membership_path"
                )
                let repository = store.mutationCoordinator.addRepo(at: fixtureRoot)
                recordRepoExplorerAtomSlotMutation()
                guard
                    await waitForRepoExplorerKeyedWakeStage(
                        "membership_path",
                        after: membershipSequence
                    )
                else { return }
                membershipSequence = RepoExplorerPerformanceTelemetry.shared.sequence(
                    for: "membership_path"
                )
                store.mutationCoordinator.removeRepo(repository.id)
                recordRepoExplorerAtomSlotMutation()
                guard
                    await waitForRepoExplorerKeyedWakeStage(
                        "membership_path",
                        after: membershipSequence
                    )
                else { return }
            }
        }

        private func recordRepoExplorerKeyMutationStep(
            action: AgentStudioStartupDiagnosticAction,
            phase: String,
            count: Int = 100
        ) {
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.step",
                phase: "startup_diagnostic_action",
                outcome: "succeeded",
                attributes: startupDiagnosticTraceAttributes(for: action).merging([
                    "agentstudio.startup_diagnostic.repo_explorer_key_mutation.phase": .string(phase),
                    "agentstudio.startup_diagnostic.repo_explorer_key_mutation.count": .int(count),
                ]) { _, newValue in newValue }
            )
        }

        private func recordRepoExplorerKeyMutationBlocked(
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
    }
#endif

import AgentStudioBridge
import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation

@MainActor
extension AppDelegate {
    #if DEBUG
        func runBridgeReviewObservabilitySmokeDiagnostic(
            action: AgentStudioStartupDiagnosticAction
        ) async {
            recordBridgeReviewObservabilitySmokePhase("activation_started", action: action)
            NSApp.activate(ignoringOtherApps: true)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
            recordBridgeReviewObservabilitySmokePhase("window_ordered", action: action)
            await waitForStartupDiagnosticAppActivation()
            recordBridgeReviewObservabilitySmokePhase("activation_wait_finished", action: action)
            recordBridgeReviewObservabilitySmokePhase("bounds_wait_started", action: action)

            guard let terminalContainerBounds = await startupDiagnosticLaunchRestoreBounds() else {
                recordStartupDiagnosticSkipped(action: action, reason: "missing_bounds")
                return
            }
            recordBridgeReviewObservabilitySmokePhase("bounds_ready", action: action)

            if !launchRestoreObservationState.didComplete {
                recordBridgeReviewObservabilitySmokePhase("launch_restore_started", action: action)
                await finishLaunchRestore(
                    using: terminalContainerBounds,
                    source: "bridgeReviewObservabilitySmokePreflight"
                )
                recordBridgeReviewObservabilitySmokePhase("launch_restore_finished", action: action)
            }

            let realWorktreeId = bridgeReviewObservabilitySmokeWorktreeId()
            recordBridgeReviewObservabilitySmokePhase("pane_open_started", action: action)
            let pane: Pane?
            if let realWorktreeId {
                pane = workspaceSurfaceCoordinator.openBridgeReviewInNewTab(worktreeId: realWorktreeId)
            } else {
                pane = workspaceSurfaceCoordinator.openBridgeReviewObservabilitySmoke()
            }
            guard let pane else {
                recordStartupDiagnosticBlocked(action: action, reason: "bridge_pane_creation_failed")
                return
            }
            recordBridgeReviewObservabilitySmokePhase("pane_opened", action: action)

            recordBridgeReviewObservabilitySmokePhase("restore_views_started", action: action)
            workspaceSurfaceCoordinator.restoreVisiblePaneIfNeeded(pane.id, forceWhenBoundsExist: true)
            await Task.yield()
            recordBridgeReviewObservabilitySmokePhase("restore_views_finished", action: action)

            guard
                let bridgeView = viewRegistry.view(for: pane.id)?
                    .mountedContent(as: BridgePaneMountView.self)
            else {
                recordStartupDiagnosticBlocked(action: action, reason: "bridge_view_missing")
                return
            }
            recordBridgeReviewObservabilitySmokePhase("bridge_view_mounted", action: action)

            if realWorktreeId == nil {
                await recordBridgeReviewNoSourceStartupDiagnostic(
                    controller: bridgeView.controller,
                    action: action
                )
                return
            }

            recordBridgeReviewObservabilitySmokePhase("render_proof_started", action: action)
            let renderProof = await waitForBridgeReviewObservabilitySmokeRenderProof(
                for: bridgeView.controller
            )
            recordBridgeReviewObservabilitySmokePhase("render_proof_finished", action: action)
            let telemetrySidecarLifecyclePrepared: Bool
            if renderProof.succeeded {
                telemetrySidecarLifecyclePrepared = await prepareBridgeReviewTelemetrySidecarProof(
                    controller: bridgeView.controller,
                    action: action
                )
            } else {
                telemetrySidecarLifecyclePrepared = true
            }
            recordBridgeReviewObservabilitySmokeDiagnosticResult(
                action: action,
                outcome: telemetrySidecarLifecyclePrepared
                    ? renderProof.startupDiagnosticOutcome
                    : "blocked",
                renderProof: renderProof
            )
        }

        private func recordBridgeReviewNoSourceStartupDiagnostic(
            controller: BridgePaneController,
            action: AgentStudioStartupDiagnosticAction
        ) async {
            let observation: BridgeReviewNoSourceStartupRenderProof
            do {
                let result = try await controller.page.callJavaScript(Self.bridgeReviewNoSourceRenderStateJavaScript)
                guard let json = result as? String, let data = json.data(using: .utf8) else {
                    recordStartupDiagnosticBlocked(action: action, reason: "no_source_projection_unavailable")
                    return
                }
                observation = try JSONDecoder().decode(BridgeReviewNoSourceStartupRenderProof.self, from: data)
            } catch {
                recordStartupDiagnosticBlocked(action: action, reason: "no_source_projection_unavailable")
                return
            }
            let outcome = observation.succeeded ? "succeeded" : "blocked"
            let attributes = startupDiagnosticTraceAttributes(for: action).merging(
                observation.attributes
            ) { _, observed in observed }
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.command_exercised",
                phase: "startup_diagnostic_action",
                outcome: outcome,
                attributes: attributes
            )
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.\(observation.succeeded ? "completed" : "blocked")",
                phase: "startup_diagnostic_action",
                outcome: outcome,
                attributes: attributes
            )
        }

        static let bridgeReviewNoSourceRenderStateJavaScript = """
            const content = document.querySelector('[data-bridge-region="review-content"]');
            const tree = document.querySelector('[data-bridge-region="review-tree"]');
            return JSON.stringify({
              contentState: content?.getAttribute('data-presentation-state') ?? null,
              contentReason: content?.getAttribute('data-empty-reason') ?? null,
              treeState: tree?.getAttribute('data-presentation-state') ?? null,
              treeReason: tree?.getAttribute('data-empty-reason') ?? null
            });
            """

        private func recordStartupDiagnosticSkipped(
            action: AgentStudioStartupDiagnosticAction,
            reason: String
        ) {
            recordStartupDiagnosticUnavailable(action: action, outcome: "skipped", reason: reason)
        }

        private func recordStartupDiagnosticBlocked(
            action: AgentStudioStartupDiagnosticAction,
            reason: String
        ) {
            recordStartupDiagnosticUnavailable(action: action, outcome: "blocked", reason: reason)
        }

        private func recordStartupDiagnosticUnavailable(
            action: AgentStudioStartupDiagnosticAction,
            outcome: String,
            reason: String
        ) {
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.\(outcome)",
                phase: "startup_diagnostic_action",
                outcome: outcome,
                attributes: startupDiagnosticTraceAttributes(for: action).merging([
                    "agentstudio.startup_diagnostic.skip_reason": .string(reason)
                ]) { _, newValue in newValue }
            )
        }

        private func bridgeReviewObservabilitySmokeWorktreeId() -> UUID? {
            guard let folderURL = AgentStudioStartupDiagnosticAction.watchFolderURL() else {
                return nil
            }
            return store.mutationCoordinator.ensureMainWorktree(at: folderURL.standardizedFileURL).id
        }

        private func recordBridgeReviewObservabilitySmokePhase(
            _ phase: String,
            action: AgentStudioStartupDiagnosticAction
        ) {
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.bridge_smoke.\(phase)",
                phase: "startup_diagnostic_action",
                attributes: startupDiagnosticTraceAttributes(for: action)
            )
        }

        private func prepareBridgeReviewTelemetrySidecarProof(
            controller: BridgePaneController,
            action: AgentStudioStartupDiagnosticAction
        ) async -> Bool {
            recordBridgeReviewObservabilitySmokePhase("telemetry_nonterminal_drain_started", action: action)
            do {
                let flushResult = try await controller.flushTelemetryForIPC()
                guard
                    flushResult.kind == .report,
                    flushResult.drained == true,
                    flushResult.report?.proofEligible == true,
                    flushResult.report?.mainProducerHighWatermark != nil,
                    flushResult.report?.commProducerHighWatermark != nil
                else {
                    recordBridgeReviewObservabilitySmokePhase(
                        "telemetry_nonterminal_drain_failed",
                        action: action
                    )
                    return false
                }
            } catch {
                recordBridgeReviewObservabilitySmokePhase(
                    "telemetry_nonterminal_drain_failed",
                    action: action
                )
                return false
            }
            recordBridgeReviewObservabilitySmokePhase("telemetry_nonterminal_drain_finished", action: action)
            recordBridgeReviewObservabilitySmokePhase("telemetry_terminal_retirement_started", action: action)
            // Teardown force-attempts the terminal drain; Victoria is authoritative for its receipt validity.
            let retired = await controller.beginTeardown().value
            recordBridgeReviewObservabilitySmokePhase(
                retired
                    ? "telemetry_terminal_retirement_finished"
                    : "telemetry_terminal_retirement_failed",
                action: action
            )
            return retired
        }

        private func recordBridgeReviewObservabilitySmokeDiagnosticResult(
            action: AgentStudioStartupDiagnosticAction,
            outcome: String,
            renderProof: BridgeReviewObservabilitySmokeRenderProof
        ) {
            var attributes = startupDiagnosticTraceAttributes(for: action).merging(
                renderProof.attributes
            ) { _, newValue in newValue }
            if let skipReason = renderProof.startupDiagnosticSkipReason {
                attributes["agentstudio.startup_diagnostic.skip_reason"] = .string(skipReason)
            }
            startupTraceRecorder.recordAppStartup(
                "app.startup_diagnostic_action.command_exercised",
                phase: "startup_diagnostic_action",
                outcome: outcome,
                attributes: attributes
            )
            let completionEventName =
                switch outcome {
                case "succeeded":
                    "app.startup_diagnostic_action.completed"
                case "skipped":
                    "app.startup_diagnostic_action.skipped"
                default:
                    "app.startup_diagnostic_action.blocked"
                }
            startupTraceRecorder.recordAppStartup(
                completionEventName,
                phase: "startup_diagnostic_action",
                outcome: outcome,
                attributes: attributes
            )
        }

        private func waitForBridgeReviewObservabilitySmokeRenderProof(
            for controller: BridgePaneController
        ) async -> BridgeReviewObservabilitySmokeRenderProof {
            let clock = ContinuousClock()
            let start = clock.now
            var proof = await bridgeReviewObservabilitySmokeRenderProof(for: controller)
            while !proof.succeeded
                && start.duration(to: clock.now) < AppPolicies.StartupDiagnostic.bridgeReviewSmokeReadinessTimeout
            {
                try? await Task.sleep(nanoseconds: Duration.milliseconds(50).nanosecondsForTaskSleep)
                proof = await bridgeReviewObservabilitySmokeRenderProof(for: controller)
            }
            return proof
        }

        private func bridgeReviewObservabilitySmokeRenderProof(
            for controller: BridgePaneController
        ) async -> BridgeReviewObservabilitySmokeRenderProof {
            do {
                let result = try await controller.page.callJavaScript(
                    Self.bridgeReviewObservabilitySmokeRenderStateJavaScript)
                guard let json = result as? String,
                    let data = json.data(using: .utf8)
                else {
                    return .unavailable()
                }
                let snapshot = try JSONDecoder().decode(
                    BridgeReviewObservabilitySmokeRenderSnapshot.self,
                    from: data
                )
                return BridgeReviewObservabilitySmokeRenderProof(
                    snapshot: snapshot,
                    expectedVisiblePaneCount: 1,
                    expectedReviewItemCount: controller.paneState.diff.packageMetadata?.orderedItemIds.count ?? 0
                )
            } catch {
                return .unavailable()
            }
        }

    #endif
}

#if DEBUG
    struct BridgeReviewNoSourceStartupRenderProof: Decodable {
        let contentState: String?
        let contentReason: String?
        let treeState: String?
        let treeReason: String?

        var succeeded: Bool {
            contentState == "empty" && contentReason == "noSource"
                && treeState == "empty" && treeReason == "noSource"
        }

        var attributes: [String: AgentStudioTraceValue] {
            [
                "agentstudio.startup_diagnostic.review_content.state": .string(contentState ?? "missing"),
                "agentstudio.startup_diagnostic.review_content.empty_reason": .string(contentReason ?? "missing"),
                "agentstudio.startup_diagnostic.review_tree.state": .string(treeState ?? "missing"),
                "agentstudio.startup_diagnostic.review_tree.empty_reason": .string(treeReason ?? "missing"),
                "agentstudio.startup_diagnostic.render_proof.succeeded": .bool(succeeded),
            ]
        }
    }
#endif

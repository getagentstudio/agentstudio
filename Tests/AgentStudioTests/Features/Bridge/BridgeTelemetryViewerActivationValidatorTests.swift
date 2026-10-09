import Testing

@testable import AgentStudioBridge

@Suite
struct BridgeTelemetryViewerActivationValidatorTests {
    @Test
    func validatorAcceptsScrubbedViewerActivationAndFileSelectionSamples() {
        let validator = BridgeTelemetryEventValidator(
            scopeGate: BridgeTelemetryScopeGate(enabledScopes: [.web])
        )
        let activationSample = sampleWithWebAttributes(
            WebSampleProps(
                name: "performance.bridge.web.viewer_activation",
                phase: "viewer_activation_requested",
                plane: "control",
                priority: "warm",
                slice: "review_rpc",
                transport: "local",
                extraStrings: [
                    "agentstudio.bridge.activation.cause": "review_file_corner",
                    "agentstudio.bridge.activation.from_viewer": "review",
                    "agentstudio.bridge.result": "started",
                    "agentstudio.bridge.viewer": "file",
                ],
                extraNumbers: [
                    "agentstudio.bridge.activation.sequence": 7
                ],
                extraBooleans: [
                    "agentstudio.bridge.activation.source_available": false
                ]
            )
        )
        let fileSelectionSample = sampleWithWebAttributes(
            WebSampleProps(
                name: "performance.bridge.web.selection_commit",
                phase: "selection_commit",
                plane: "data",
                priority: "warm",
                slice: "tree_prepare_input",
                transport: "local",
                extraStrings: [
                    "agentstudio.bridge.result": "success",
                    "agentstudio.bridge.result_reason": "none",
                    "agentstudio.bridge.selection.origin": "review_file_corner",
                    "agentstudio.bridge.viewer": "file",
                ],
                extraNumbers: [
                    "agentstudio.bridge.activation.sequence": 7,
                    "agentstudio.bridge.source.generation": 12,
                ]
            )
        )
        let contextSwitcherSelectionSample = sampleWithWebAttributes(
            WebSampleProps(
                name: "performance.bridge.web.selection_commit",
                phase: "selection_commit",
                plane: "data",
                priority: "warm",
                slice: "tree_prepare_input",
                transport: "local",
                extraStrings: [
                    "agentstudio.bridge.result": "success",
                    "agentstudio.bridge.result_reason": "none",
                    "agentstudio.bridge.selection.origin": "context_switcher",
                    "agentstudio.bridge.viewer": "file",
                ],
                extraNumbers: [
                    "agentstudio.bridge.activation.sequence": 8,
                    "agentstudio.bridge.source.generation": 12,
                ]
            )
        )
        let commWorkerSessionSample = sampleWithWebAttributes(
            WebSampleProps(
                name: "performance.bridge.web.comm_worker_session",
                phase: "comm_worker_session_snapshot",
                plane: "control",
                priority: "hot",
                slice: "worker_task",
                transport: "local",
                extraStrings: [
                    "agentstudio.bridge.worker.file_mode_dispatch": "posted",
                    "agentstudio.bridge.worker.file_select_dispatch": "queued_not_ready",
                    "agentstudio.bridge.worker.review_select_dispatch": "none",
                    "agentstudio.bridge.worker.replacement_reason": "runtime_recovery",
                    "agentstudio.bridge.worker.replacement_source": "review_installed_receipt_failed",
                    "agentstudio.bridge.worker.session_state": "replacement_requested",
                ],
                extraNumbers: [
                    "agentstudio.bridge.worker.native_bootstrap_install.count": 1,
                    "agentstudio.bridge.worker.queued_command.count": 2,
                    "agentstudio.bridge.worker.replacement_request.count": 1,
                ]
            )
        )

        #expect(validator.validate(activationSample) == .accepted)
        #expect(validator.validate(fileSelectionSample) == .accepted)
        #expect(validator.validate(contextSwitcherSelectionSample) == .accepted)
        #expect(validator.validate(commWorkerSessionSample) == .accepted)
    }
}

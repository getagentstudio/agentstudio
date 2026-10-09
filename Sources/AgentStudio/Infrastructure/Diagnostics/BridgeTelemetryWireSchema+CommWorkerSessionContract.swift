import Foundation

extension BridgeTelemetryWireSchema {
    static func commWorkerSessionContractMatches(_ contract: EventContract) -> Bool {
        contract.matches(
            .init(
                phase: "comm_worker_session_snapshot",
                plane: .control,
                priority: .hot,
                slice: .workerTask,
                transport: "local",
                attributeKeys: .init(
                    additionalStringKeys: [
                        "agentstudio.bridge.worker.file_mode_dispatch",
                        "agentstudio.bridge.worker.file_select_dispatch",
                        "agentstudio.bridge.worker.review_select_dispatch",
                        "agentstudio.bridge.worker.replacement_reason",
                        "agentstudio.bridge.worker.replacement_source",
                        "agentstudio.bridge.worker.session_state",
                    ],
                    numericKeys: [
                        "agentstudio.bridge.worker.native_bootstrap_install.count",
                        "agentstudio.bridge.worker.queued_command.count",
                        "agentstudio.bridge.worker.replacement_request.count",
                    ]
                )
            )
        )
    }
}

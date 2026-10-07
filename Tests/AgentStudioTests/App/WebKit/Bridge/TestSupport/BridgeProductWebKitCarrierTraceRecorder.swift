import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge

actor BridgeProductWebKitCarrierTraceRecorder: BridgePerformanceTraceRecording {
    enum TraceCondition: Sendable {
        case reviewPublication
        case canonicalSubscriptionsAndReviewPublication

        func isSatisfied(by trace: BridgeProductWebKitCarrierTrace) -> Bool {
            switch self {
            case .reviewPublication:
                trace.hasReviewMetadataPublication
            case .canonicalSubscriptionsAndReviewPublication:
                trace.hasCanonicalEagerSubscriptions && trace.hasReviewMetadataPublication
            }
        }
    }

    private var samples: [BridgeTelemetrySample] = []
    private let firstApplication: BridgeProductWebKitFirstApplicationRecorder?
    private let traces = FactRecorder<String, BridgeProductWebKitCarrierTrace>(
        vocabulary: .init(describeScope: { $0 }, describeFact: { String(describing: $0) }, isClosing: { _, _ in false })
    )

    init(firstApplication: BridgeProductWebKitFirstApplicationRecorder? = nil) {
        self.firstApplication = firstApplication
    }

    func record(sample: BridgeTelemetrySample, receivedAtUnixNano _: UInt64) {
        samples.append(sample)
        firstApplication?.observe(sample)
        let trace = scrubbedTrace()
        for condition in [TraceCondition.reviewPublication, .canonicalSubscriptionsAndReviewPublication] {
            if condition.isSatisfied(by: trace) { traces.append(scope: String(describing: condition), fact: trace) }
        }
    }

    func waitForTrace(_ condition: TraceCondition) async -> BridgeProductWebKitCarrierTrace? {
        let current = scrubbedTrace()
        if condition.isSatisfied(by: current) { return current }
        return try? await traces.expectNext(
            in: String(describing: condition), where: { condition.isSatisfied(by: $0) },
            "carrier trace satisfies \(condition)")
    }

    func recordDrop(
        reason _: BridgeTelemetryDropReason,
        droppedCount _: Int,
        firstRejectedEventName _: String?,
        receivedAtUnixNano _: UInt64
    ) {}

    func drain() {}

    func scrubbedTrace() -> BridgeProductWebKitCarrierTrace {
        BridgeProductWebKitCarrierTrace(
            fileMetadataPhases: phases(
                eventName: "performance.bridge.swift.metadata_bootstrap_lifecycle",
                protocolName: "worktree-file"
            ),
            panePresentationEvents: panePresentationEvents(),
            reviewMetadataPhases: phases(
                eventName: "performance.bridge.swift.metadata_bootstrap_lifecycle",
                protocolName: "review"
            ),
            reviewPublicationPhases: phases(
                eventName: "performance.bridge.swift.review_metadata_publication",
                protocolName: "review"
            )
        )
    }

    func reviewStageSamples() -> [String] {
        samples.enumerated().compactMap { index, sample in
            let attributes = sample.stringAttributes
            let phase = attributes["agentstudio.bridge.phase"] ?? "none"
            let surface = attributes["agentstudio.bridge.surface"] ?? "none"
            let slice = attributes["agentstudio.bridge.slice"] ?? "none"
            let protocolName = attributes["agentstudio.bridge.protocol"] ?? "none"
            let taskKind = attributes["agentstudio.bridge.task_kind"] ?? "none"
            let isApplicationStage = ["batch", "candidate", "publication", "application", "install"]
                .contains { phase.contains($0) }
            guard
                sample.name.contains("review") || phase.contains("review")
                    || surface == "review" || slice.contains("review")
                    || protocolName == "review" || taskKind.contains("review") || isApplicationStage
            else { return nil }
            let revisions = sample.numericAttributes.filter { $0.key.contains("revision") }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            return [
                "index=\(index)",
                "name=\(sample.name)",
                "phase=\(phase)",
                "result=\(attributes["agentstudio.bridge.result"] ?? "none")",
                "reason=\(attributes["agentstudio.bridge.result_reason"] ?? "none")",
                "revision=\(revisions)",
                "operation=\(attributes["agentstudio.bridge.operation.id"] ?? "none")",
                "surface=\(surface)",
                "slice=\(slice)",
                "taskKind=\(taskKind)",
            ].joined(separator: " ")
        }
    }

    private func panePresentationEvents() -> [BridgeProductWebKitCarrierPanePresentationTrace] {
        samples.compactMap { sample in
            guard sample.name == "performance.bridge.swift.pane_presentation",
                let presentationRevision =
                    sample.numericAttributes["agentstudio.bridge.presentation.revision"],
                let resultReason =
                    sample.stringAttributes["agentstudio.bridge.result_reason"],
                let stage = sample.stringAttributes["agentstudio.bridge.phase"]
            else { return nil }
            return BridgeProductWebKitCarrierPanePresentationTrace(
                presentationRevision: Int(presentationRevision),
                resultReason: resultReason,
                stage: stage
            )
        }
    }

    private func phases(eventName: String, protocolName: String) -> [String] {
        samples.compactMap { sample in
            guard sample.name == eventName,
                sample.stringAttributes["agentstudio.bridge.protocol"] == protocolName
            else { return nil }
            return sample.stringAttributes["agentstudio.bridge.phase"]
        }
    }
}

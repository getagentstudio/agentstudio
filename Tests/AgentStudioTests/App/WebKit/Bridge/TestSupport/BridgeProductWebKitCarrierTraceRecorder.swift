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
    private var nextCompletedPublicationWrite: HeldStep<Void>?
    private var foregroundCatchUp: BridgeProductWebKitCatchUpTerminalExpectation?
    private var foregroundCatchUpOperations: Set<BridgeProductWebKitCatchUpOperation> = []
    private let firstApplication: BridgeProductWebKitFirstApplicationRecorder?
    private let traces = FactRecorder<String, BridgeProductWebKitCarrierTrace>(
        vocabulary: .init(describeScope: { $0 }, describeFact: { String(describing: $0) }, isClosing: { _, _ in false })
    )

    init(firstApplication: BridgeProductWebKitFirstApplicationRecorder? = nil) {
        self.firstApplication = firstApplication
    }

    func holdNextCompletedPublicationWrite(at step: HeldStep<Void>) {
        precondition(nextCompletedPublicationWrite == nil)
        nextCompletedPublicationWrite = step
    }

    func record(sample: BridgeTelemetrySample, receivedAtUnixNano _: UInt64) async {
        if sample.name == "performance.bridge.swift.review_metadata_publication",
            sample.stringAttributes["agentstudio.bridge.phase"] == "review_metadata_publication_completed",
            let step = nextCompletedPublicationWrite
        {
            nextCompletedPublicationWrite = nil
            try? await step.arrive(())
        }
        samples.append(sample)
        recordForegroundCatchUp(sample)
        firstApplication?.observe(sample)
        let trace = scrubbedTrace()
        for condition in [TraceCondition.reviewPublication, .canonicalSubscriptionsAndReviewPublication] {
            if condition.isSatisfied(by: trace) { traces.append(scope: String(describing: condition), fact: trace) }
        }
        if sample.name == "performance.bridge.swift.review_metadata_publication",
            sample.stringAttributes["agentstudio.bridge.phase"] == "review_metadata_publication_completed"
        {
            traces.append(
                scope: "completed Review publication count \(trace.completedReviewPublicationCount)", fact: trace)
        }
    }

    func prepareForegroundCatchUp(
        dirtyFact: BridgePaneRefreshDirtyFact?,
        reviewModeIdentity: BridgeProductWebKitActiveViewerModeIdentity
    ) -> BridgeProductWebKitCatchUpTerminalExpectation {
        precondition(foregroundCatchUp == nil)
        let expectation = BridgeProductWebKitCatchUpTerminalExpectation(
            dirtyFact: dirtyFact,
            reviewModeIdentity: reviewModeIdentity
        )
        foregroundCatchUp = expectation
        return expectation
    }

    func finishForegroundCatchUp() async throws {
        let expectation = foregroundCatchUp
        foregroundCatchUp = nil
        foregroundCatchUpOperations.removeAll()
        expectation?.recorder.receive(.ended)
        try await expectation?.recorder.finish()
    }

    private func recordForegroundCatchUp(_ sample: BridgeTelemetrySample) {
        guard let foregroundCatchUp,
            sample.name == "performance.bridge.swift.operation_lifecycle",
            let laneValue = sample.stringAttributes["agentstudio.bridge.viewer"],
            let lane = BridgePaneRefreshLane(rawValue: laneValue),
            foregroundCatchUp.lanes.contains(lane),
            let operationId = sample.stringAttributes["agentstudio.bridge.operation.id"],
            let phase = sample.stringAttributes["agentstudio.bridge.phase"]
        else { return }
        let operation = BridgeProductWebKitCatchUpOperation(lane: lane, operationId: operationId)
        if phase == "refresh_reserved" {
            foregroundCatchUpOperations.insert(operation)
            foregroundCatchUp.recorder.append(scope: operation, fact: .reserved)
        } else if phase == "refresh_operation_terminal", foregroundCatchUpOperations.contains(operation),
            let result = sample.stringAttributes["agentstudio.bridge.result"]
        {
            foregroundCatchUp.recorder.append(scope: operation, fact: .terminal(result: result))
        }
    }

    func waitForTrace(_ condition: TraceCondition) async -> BridgeProductWebKitCarrierTrace? {
        let current = scrubbedTrace()
        if condition.isSatisfied(by: current) { return current }
        return try? await traces.expectNext(
            in: String(describing: condition), where: { condition.isSatisfied(by: $0) },
            "carrier trace satisfies \(condition)")
    }

    func waitForCompletedReviewPublicationCount(_ expectedCount: Int) async throws -> BridgeProductWebKitCarrierTrace {
        precondition(expectedCount >= 0)
        let current = scrubbedTrace()
        if current.completedReviewPublicationCount >= expectedCount { return current }
        return try await traces.expectNext(
            in: "completed Review publication count \(expectedCount)",
            where: { $0.completedReviewPublicationCount >= expectedCount },
            "\(expectedCount) completed Review publication writes recorded"
        )
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

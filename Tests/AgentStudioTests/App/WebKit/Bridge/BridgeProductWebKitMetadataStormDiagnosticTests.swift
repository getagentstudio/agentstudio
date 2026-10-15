import Testing

@testable import AgentStudioBridge

@Suite("Hidden metadata storm admission summary")
struct BridgeProductWebKitMetadataStormDiagnosticTests {
    @Test(
        "only enqueued presentations count as hidden admission",
        arguments: [
            (
                stage: BridgePanePresentationTraceEvent.Stage.notEnqueued,
                reason: BridgePanePresentationTraceEvent.ResultReason.deduplicated,
                expectedCount: 0
            ),
            (
                stage: BridgePanePresentationTraceEvent.Stage.notEnqueued,
                reason: BridgePanePresentationTraceEvent.ResultReason.producerRejected,
                expectedCount: 0
            ),
            (
                stage: BridgePanePresentationTraceEvent.Stage.enqueued,
                reason: BridgePanePresentationTraceEvent.ResultReason.noReason,
                expectedCount: 1
            ),
            (
                stage: BridgePanePresentationTraceEvent.Stage.enqueued,
                reason: BridgePanePresentationTraceEvent.ResultReason.producerQueueReset,
                expectedCount: 1
            ),
        ]
    )
    func countsOnlyEnqueuedPresentations(
        stage: BridgePanePresentationTraceEvent.Stage,
        reason: BridgePanePresentationTraceEvent.ResultReason,
        expectedCount: Int
    ) {
        // Arrange
        let baseline = makeTrace(paneEvents: [])
        let after = makeTrace(paneEvents: [
            .init(presentationRevision: 16, resultReason: reason.rawValue, stage: stage.rawValue)
        ])

        // Act
        let summary = BridgeProductWebKitMetadataStormDiagnostic.summarize(
            nativeBefore: .unavailable,
            nativeAfter: .unavailable,
            traceBefore: baseline,
            traceAfter: after
        )

        // Assert: rejected attempts remain visible even though no frame was admitted.
        #expect(summary.productDeltas.admittedPanePresentationCount == expectedCount)
        #expect(summary.productDeltas.fileMetadataPhaseCount == 0)
        #expect(summary.productDeltas.reviewMetadataPhaseCount == 0)
        #expect(summary.message.contains("pane=+1[\(stage.rawValue)@16:\(reason.rawValue)]"))
    }

    @Test("admission counts only the appended trace suffix and retains other product deltas")
    func excludesBaselineBeforeCountingAdmissions() {
        // Arrange
        let enqueuedStage = BridgePanePresentationTraceEvent.Stage.enqueued.rawValue
        let notEnqueuedStage = BridgePanePresentationTraceEvent.Stage.notEnqueued.rawValue
        let noReason = BridgePanePresentationTraceEvent.ResultReason.noReason.rawValue
        let deduplicatedReason = BridgePanePresentationTraceEvent.ResultReason.deduplicated.rawValue
        let priorPresentation = BridgeProductWebKitCarrierPanePresentationTrace(
            presentationRevision: 15, resultReason: noReason, stage: enqueuedStage
        )
        let baseline = makeTrace(paneEvents: [priorPresentation], filePhases: ["prior"], reviewPhases: ["prior"])
        let after = makeTrace(
            paneEvents: [
                priorPresentation,
                .init(presentationRevision: 15, resultReason: deduplicatedReason, stage: notEnqueuedStage),
                .init(presentationRevision: 16, resultReason: noReason, stage: enqueuedStage),
            ],
            filePhases: ["prior", "file-added"],
            reviewPhases: ["prior", "review-added", "review-added-again"]
        )

        // Act
        let summary = BridgeProductWebKitMetadataStormDiagnostic.summarize(
            nativeBefore: .unavailable,
            nativeAfter: .unavailable,
            traceBefore: baseline,
            traceAfter: after
        )

        // Assert
        #expect(summary.productDeltas.admittedPanePresentationCount == 1)
        #expect(summary.productDeltas.fileMetadataPhaseCount == 1)
        #expect(summary.productDeltas.reviewMetadataPhaseCount == 2)
        #expect(
            summary.message.contains(
                "pane=+2[\(notEnqueuedStage)@15:\(deduplicatedReason),\(enqueuedStage)@16:\(noReason)]"
            )
        )
        #expect(summary.message.contains("file=+1[file-added]"))
        #expect(summary.message.contains("review=+2[review-added,review-added-again]"))
    }

    private func makeTrace(
        paneEvents: [BridgeProductWebKitCarrierPanePresentationTrace],
        filePhases: [String] = [],
        reviewPhases: [String] = []
    ) -> BridgeProductWebKitCarrierTrace {
        BridgeProductWebKitCarrierTrace(
            fileMetadataPhases: filePhases,
            panePresentationEvents: paneEvents,
            reviewMetadataPhases: reviewPhases,
            reviewPublicationPhases: []
        )
    }
}

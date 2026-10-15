import Testing

@Suite("Hidden metadata storm admission summary")
struct BridgeProductWebKitMetadataStormDiagnosticTests {
    @Test(
        "only enqueued presentations count as hidden admission",
        arguments: [
            (stage: "pane_presentation_not_enqueued", reason: "deduplicated", expectedCount: 0),
            (stage: "pane_presentation_not_enqueued", reason: "producer_rejected", expectedCount: 0),
            (stage: "pane_presentation_enqueued", reason: "none", expectedCount: 1),
            (stage: "pane_presentation_enqueued", reason: "producer_queue_reset", expectedCount: 1),
        ]
    )
    func countsOnlyEnqueuedPresentations(stage: String, reason: String, expectedCount: Int) {
        // Arrange
        let baseline = makeTrace(paneEvents: [])
        let after = makeTrace(paneEvents: [
            .init(presentationRevision: 16, resultReason: reason, stage: stage)
        ])

        // Act
        let summary = BridgeProductWebKitMetadataStormDiagnostic.summarize(
            nativeBefore: .unavailable,
            nativeAfter: .unavailable,
            traceBefore: baseline,
            traceAfter: after
        )

        // Assert: rejected attempts remain visible even though no frame was admitted.
        #expect(summary.productDeltas.panePresentationEventCount == expectedCount)
        #expect(summary.productDeltas.fileMetadataPhaseCount == 0)
        #expect(summary.productDeltas.reviewMetadataPhaseCount == 0)
        #expect(summary.message.contains("pane=+1[\(stage)@16:\(reason)]"))
    }

    @Test("admission counts only the appended trace suffix and retains other product deltas")
    func excludesBaselineBeforeCountingAdmissions() {
        // Arrange
        let priorPresentation = BridgeProductWebKitCarrierPanePresentationTrace(
            presentationRevision: 15, resultReason: "none", stage: "pane_presentation_enqueued"
        )
        let baseline = makeTrace(paneEvents: [priorPresentation], filePhases: ["prior"], reviewPhases: ["prior"])
        let after = makeTrace(
            paneEvents: [
                priorPresentation,
                .init(presentationRevision: 15, resultReason: "deduplicated", stage: "pane_presentation_not_enqueued"),
                .init(presentationRevision: 16, resultReason: "none", stage: "pane_presentation_enqueued"),
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
        #expect(summary.productDeltas.panePresentationEventCount == 1)
        #expect(summary.productDeltas.fileMetadataPhaseCount == 1)
        #expect(summary.productDeltas.reviewMetadataPhaseCount == 2)
        #expect(
            summary.message.contains(
                "pane=+2[pane_presentation_not_enqueued@15:deduplicated,pane_presentation_enqueued@16:none]"
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

/// Product frames a hidden pane admitted between two carrier traces.
///
/// These are the frames the isolation invariant is actually about. The metadata
/// stream sequence is deliberately absent: it also counts protocol
/// acknowledgements, which must keep flowing while a pane is hidden.
struct BridgeProductWebKitHiddenStormProductDeltas: Sendable, Equatable {
    let panePresentationEventCount: Int
    let fileMetadataPhaseCount: Int
    let reviewMetadataPhaseCount: Int
}

/// What a hidden pane admitted during the storm, as both an assertable value and
/// the human-readable line. Built together from one reading of the traces so the
/// assertion and the diagnostic can never disagree.
struct BridgeProductWebKitHiddenStormSummary: Sendable {
    let message: String
    let productDeltas: BridgeProductWebKitHiddenStormProductDeltas
}

/// Formats bounded existing telemetry for the hidden-pane journey failure.
enum BridgeProductWebKitMetadataStormDiagnostic {
    static func summarize(
        nativeBefore: BridgeProductWebKitCarrierNativeSnapshot,
        nativeAfter: BridgeProductWebKitCarrierNativeSnapshot,
        traceBefore: BridgeProductWebKitCarrierTrace,
        traceAfter: BridgeProductWebKitCarrierTrace
    ) -> BridgeProductWebKitHiddenStormSummary {
        let admitted = admittedFrames(traceBefore: traceBefore, traceAfter: traceAfter)
        return BridgeProductWebKitHiddenStormSummary(
            message: message(nativeBefore: nativeBefore, nativeAfter: nativeAfter, admitted: admitted),
            productDeltas: BridgeProductWebKitHiddenStormProductDeltas(
                panePresentationEventCount: admitted.panePresentationEventCount,
                fileMetadataPhaseCount: admitted.filePhases.count,
                reviewMetadataPhaseCount: admitted.reviewPhases.count
            )
        )
    }

    private static func message(
        nativeBefore: BridgeProductWebKitCarrierNativeSnapshot,
        nativeAfter: BridgeProductWebKitCarrierNativeSnapshot,
        admitted: AdmittedFrames
    ) -> String {
        "hidden metadata storm: sequence=\(nativeBefore.nextMetadataStreamSequence)"
            + "->\(nativeAfter.nextMetadataStreamSequence), "
            + "control=next:\(nativeBefore.nextControlRequestSequence)"
            + "->\(nativeAfter.nextControlRequestSequence)"
            + "/inFlight:\(String(describing: nativeBefore.inFlightControlRequestSequence))"
            + "->\(String(describing: nativeAfter.inFlightControlRequestSequence)), "
            + "frames=queued:\(nativeBefore.queuedFrameCount)->\(nativeAfter.queuedFrameCount)"
            + "/inFlight:\(nativeBefore.inFlightFrameReceiptCount)"
            + "->\(nativeAfter.inFlightFrameReceiptCount), "
            + "pane=\(boundedDescription(admitted.paneEvents)), "
            + "file=\(boundedDescription(admitted.filePhases)), "
            + "review=\(boundedDescription(admitted.reviewPhases))"
    }

    private struct AdmittedFrames {
        // Keep rejected attempts in the diagnostic, but count only admitted frames.
        let paneEvents: ArraySlice<BridgeProductWebKitCarrierPanePresentationTrace>
        let panePresentationEventCount: Int
        let filePhases: ArraySlice<String>
        let reviewPhases: ArraySlice<String>
    }

    /// The one place "what did the hidden pane admit" is computed.
    private static func admittedFrames(
        traceBefore: BridgeProductWebKitCarrierTrace,
        traceAfter: BridgeProductWebKitCarrierTrace
    ) -> AdmittedFrames {
        let paneEvents = appendedValues(
            traceAfter.panePresentationEvents,
            after: traceBefore.panePresentationEvents
        )
        return AdmittedFrames(
            paneEvents: paneEvents,
            panePresentationEventCount: paneEvents.count(where: { $0.stage == "pane_presentation_enqueued" }),
            filePhases: appendedValues(
                traceAfter.fileMetadataPhases,
                after: traceBefore.fileMetadataPhases
            ),
            reviewPhases: appendedValues(
                traceAfter.reviewMetadataPhases,
                after: traceBefore.reviewMetadataPhases
            )
        )
    }

    private static func appendedValues<Element>(
        _ values: [Element],
        after baseline: [Element]
    ) -> ArraySlice<Element> {
        values.dropFirst(min(values.count, baseline.count))
    }

    private static func boundedDescription<Element>(
        _ values: ArraySlice<Element>
    ) -> String {
        let visibleValues = values.prefix(8).map { String(describing: $0) }
        let omittedCount = values.count - visibleValues.count
        let suffix = omittedCount == 0 ? "" : ",+\(omittedCount) more"
        return "+\(values.count)[\(visibleValues.joined(separator: ","))\(suffix)]"
    }
}

@testable import AgentStudioBridge

@MainActor
enum BridgeProductWebKitFirstApplicationDiagnostic {
    struct Input {
        let controller: BridgePaneController
        let outcome: BridgeProductWebKitFirstApplicationOutcome
        let source: BridgeWebKitFailingReviewMetadataSource
        let traceRecorder: BridgeProductWebKitCarrierTraceRecorder
    }

    static func capture(_ input: Input) async -> String {
        let sourceCapture = await input.source.firstViewCaptureDiagnostic()
        let firstDelivery = await input.source.snapshot().deliveryAttempts.first
        let initialIdentity =
            firstDelivery.map {
                "publication=\($0.publicationId),package=\($0.package.packageId),items=\($0.package.orderedItemIds.count)"
            } ?? "no initial committed delivery"
        let pageDiagnostic =
            (try? await input.controller.page.callJavaScript(
                """
                const diagnostic = window.__bridgeReviewSelectionDiagnostic;
                return JSON.stringify({
                  reviewInstallationGate: diagnostic?.reviewInstallationGate ?? null,
                  reviewCandidateSource: diagnostic?.reviewCandidateSource ?? null,
                  lastReviewDisplayPatch: diagnostic?.lastReviewDisplayPatch ?? null
                });
                """
            )) as? String ?? "unavailable"
        let stages = await input.traceRecorder.reviewStageSamples()
        return
            "outcome=\(input.outcome);initial=\(initialIdentity);source capture=\(sourceCapture);page=\(pageDiagnostic);telemetry=\(stages)"
    }
}

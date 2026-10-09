import WebKit

@MainActor
enum BridgeProductWebKitReplacementFactTestSupport {
    static func read(_ page: WebPage) async -> String {
        let encoded = try? await page.callJavaScript(
            """
            const diagnostic = window.__bridgeReviewSelectionDiagnostic;
            return JSON.stringify({
              facts: diagnostic?.workerReplacementFacts ?? [],
              replacementRequestCount: diagnostic?.replacementRequestCount ?? 0,
              droppedFactCount: diagnostic?.droppedWorkerReplacementFactCount ?? 0
            });
            """
        )
        return encoded as? String ?? "unavailable"
    }
}

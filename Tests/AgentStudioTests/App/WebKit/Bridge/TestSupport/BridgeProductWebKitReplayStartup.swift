@testable import AgentStudioBridge
@testable import AgentStudioTestSupport

@MainActor
enum BridgeProductWebKitReplayStartup {
    struct Input {
        let controller: BridgePaneController
        let controllerTarget: BridgeProductWebKitCarrierControllerTarget
        let fileSource: BridgeWebKitTrackingFileMetadataSource
        let reviewSource: BridgeWebKitFailingReviewMetadataSource
        let traceRecorder: BridgeProductWebKitCarrierTraceRecorder
    }

    struct OpenedSubscriptions {
        let file: BridgeProductWebKitCarrierSubscriptionIdentity
        let review: BridgeProductWebKitCarrierSubscriptionIdentity
    }

    enum StartupError: Error {
        case initialPublicationEnded(String)
        case fileModeDidNotActivate
        case metadataSubscriptionsDidNotOpen
        case reviewModeDidNotActivate
    }

    static func prepare(_ input: Input) async throws -> OpenedSubscriptions {
        let outcome = try await input.controllerTarget.waitForFirstApplicationReceipt()
        guard case .receipt(let receipt) = outcome, receipt.applicationResult == .advanced else {
            throw StartupError.initialPublicationEnded(
                await BridgeProductWebKitFirstApplicationDiagnostic.capture(
                    .init(
                        controller: input.controller, outcome: outcome, source: input.reviewSource,
                        traceRecorder: input.traceRecorder)))
        }
        // File is demand-driven; establish the real surface before proving its continuity.
        guard await BridgeProductWebKitCarrierTestSupport.activateFileMode(input.controller.page) else {
            throw StartupError.fileModeDidNotActivate
        }
        async let fileOpen = input.fileSource.waitForFirstOpen()
        async let reviewOpen = input.reviewSource.waitForFirstOpen()
        guard let file = await fileOpen, let review = await reviewOpen else {
            throw StartupError.metadataSubscriptionsDidNotOpen
        }
        let activatedReview = try await input.controller.page.callJavaScript(
            """
            const button = document.querySelector('[data-testid="bridge-viewer-context-review"]');
            if (!(button instanceof HTMLButtonElement) || button.disabled) return false;
            button.click();
            return true;
            """
        )
        guard activatedReview as? Bool == true else { throw StartupError.reviewModeDidNotActivate }
        _ = try await WebPageEventWaits.waitForDocumentValue(
            input.controller.page,
            reader: """
                return document.querySelector('[data-testid="bridge-app-root"]')
                  ?.getAttribute('data-bridge-viewer-mode') === 'review' ? true : null;
                """,
            milestone: "replay fixture restores Review mode",
            lastObservation: """
                return document.querySelector('[data-testid="bridge-app-root"]')
                  ?.getAttribute('data-bridge-viewer-mode') ?? 'missing';
                """
        )
        return OpenedSubscriptions(file: file, review: review)
    }
}

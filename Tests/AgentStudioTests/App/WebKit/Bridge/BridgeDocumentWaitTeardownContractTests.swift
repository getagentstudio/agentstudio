import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
private final class BridgeDocumentWaitTeardownObservation {
    var settlementDescription: String?
}

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgeDocumentWaitTeardownContractTests {
        @Test("GO26 real hosted-pane teardown settles an unresolved document promise")
        func hostedPaneTeardownSettlesUnresolvedDocumentPromise() async throws {
            let repoURL = try await FilesystemTestGitRepo.create(named: "bridge-document-wait-teardown-contract")
            defer { FilesystemTestGitRepo.destroy(repoURL) }
            let controller = BridgeProductRealGitFileAndReviewWebKitTests().makeController(
                repoURL: repoURL, traceRecorder: BridgeProductWebKitCarrierTraceRecorder())
            let observation = BridgeDocumentWaitTeardownObservation()
            var pendingCall: Task<Void, Never>?
            var preparationFailure: (any Error)?

            do {
                try await BridgeProductWebKitTwoPaneJourneyTestSupport.withHostedControllers([controller]) {
                    controller.loadApp()
                    await WebPageEventWaits.waitForNavigationToFinish(controller.page)
                    try await WebPageEventWaits.waitForDocumentSelector(
                        controller.page, "[data-testid=\"bridge-app-root\"]")
                    _ = try await controller.page.callJavaScript(
                        """
                        window.__go26DocumentObserverInstalled = new Promise(resolve => {
                          window.__go26RecordDocumentObserverInstalled = resolve;
                        });
                        return true;
                        """
                    )
                    pendingCall = Task { @MainActor in
                        do {
                            _ = try await controller.page.callJavaScript(
                                """
                                const readDocumentValue = () =>
                                  document.querySelector('[data-go26-teardown-contract-ready="true"]');
                                return await new Promise(resolve => {
                                  let observer = null;
                                  const attempt = () => {
                                    const value = readDocumentValue();
                                    if (value === null || value === undefined) return false;
                                    observer?.disconnect();
                                    resolve(value);
                                    return true;
                                  };
                                  if (attempt()) return;
                                  observer = new MutationObserver(attempt);
                                  observer.observe(document.documentElement, {
                                    attributes: true, characterData: true, childList: true, subtree: true
                                  });
                                  window.__go26RecordDocumentObserverInstalled(true);
                                });
                                """
                            )
                            observation.settlementDescription = "GO26 unresolved document call settled by return"
                        } catch {
                            observation.settlementDescription =
                                "GO26 unresolved document call threw \(String(reflecting: type(of: error))): \(error)"
                        }
                    }
                    let installed = try await awaitBridgeWebKitMilestone("GO26 never-ready MutationObserver installed")
                    {
                        try await controller.page.callJavaScript("return await window.__go26DocumentObserverInstalled;")
                    }
                    try #require(installed as? Bool == true, "GO26 contract observer did not install")
                    // Returning invokes the journey's real stopLoading/unmount/retain teardown.
                }
            } catch {
                preparationFailure = error
            }

            if let pendingCall {
                try await awaitBridgeWebKitMilestone(
                    "GO26 document call physical settlement after real two-pane teardown"
                ) {
                    await pendingCall.value
                }
            }
            if let preparationFailure { throw preparationFailure }
            let settlement = try #require(
                observation.settlementDescription, "GO26 pending document await did not record physical settlement")
            print(settlement)
        }
    }
}

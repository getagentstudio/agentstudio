import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

private enum DocumentWaitContractOutcome: String, CaseIterable, Sendable {
    case abort, success, readerError, failedStart
}

@MainActor
private final class DocumentWaitFailureObservation {
    var error: (any Error)?
}

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgeDocumentWaitTeardownContractTests {
        @Test(
            "GO26 live registry settles and disconnects its document observer",
            arguments: DocumentWaitContractOutcome.allCases)
        private func liveRegistrySettlesDocumentObserver(outcome: DocumentWaitContractOutcome) async throws {
            try await withContractPage { page in
                try await withInstalledDocumentWait(page: page) { pending in
                    switch outcome {
                    case .abort:
                        try await awaitBridgeWebKitMilestone(
                            "GO26 live contract abort acknowledgement token=\(pending.token)"
                        ) {
                            try await pending.abort(reason: "live contract closing fact")
                        }
                        let envelope = try await pending.join()
                        guard case .aborted(let token, let reason) = envelope else {
                            Issue.record("GO26 live abort returned a value instead of its sentinel")
                            return
                        }
                        #expect(token == pending.token)
                        #expect(reason == "live contract closing fact")
                    case .success:
                        _ = try await page.callJavaScript(
                            "document.documentElement.setAttribute('data-go26-state', 'ready');")
                        #expect(try await pending.join().value() as? String == "ready value")
                    case .failedStart:
                        try await renderFailureSummary(page, title: "Bridge couldn't start.")
                        guard case .failedStart = try await pending.join() else {
                            Issue.record("GO26 terminal marker did not return its terminal envelope")
                            return
                        }
                    case .readerError:
                        _ = try await page.callJavaScript(
                            "document.documentElement.setAttribute('data-go26-state', 'throw');")
                        do {
                            _ = try await pending.join()
                            Issue.record("GO26 throwing reader unexpectedly succeeded")
                        } catch {
                            #expect(String(describing: error).contains("GO26 reader failed"))
                        }
                    }
                    #expect(try await requireRemovedEntry(page: page, token: pending.token))
                    #expect(try await page.callJavaScript("return globalThis.__go26DisconnectCount;") as? Int == 1)
                }
            }
        }

        @Test("GO26 early abort is consumed before the document reader runs")
        func earlyAbortIsConsumedBeforeReaderRuns() async throws {
            try await withContractPage { page in
                let token = UUIDv7.generate().uuidString
                _ = try await page.callJavaScript("globalThis.__go26ReaderCount = 0;")
                #expect(try await WebPagePendingDocumentWait.abort(page: page, token: token, reason: "early close"))
                let pending = WebPagePendingDocumentWait(
                    page: page, token: token, reader: "globalThis.__go26ReaderCount++; return null;")
                let envelope = try await pending.join()
                guard case .aborted(let actualToken, let reason) = envelope else {
                    Issue.record("GO26 pre-aborted entry was lost")
                    return
                }
                #expect(actualToken == token)
                #expect(reason == "early close")
                #expect(try await page.callJavaScript("return globalThis.__go26ReaderCount;") as? Int == 0)
                #expect(try await requireRemovedEntry(page: page, token: token))
            }
        }

        @Test("GO26 already-recorded owner closure throws before calling JavaScript")
        func recordedClosureDoesNotCallJavaScript() async throws {
            try await withContractPage { page in
                let source = try WebPageDocumentWaitClosingSource(pane: "already closed pane")
                source.record(.pageClosed, requestId: "closed-request")
                source.record(.navigationFailed("later failure"), requestId: "later-request")
                _ = try await page.callJavaScript("globalThis.__go26ReaderCount = 0;")
                do {
                    _ = try await WebPageEventWaits.waitForDocumentValue(
                        page, reader: "globalThis.__go26ReaderCount++; return true;",
                        milestone: "closed milestone", closingSource: source)
                    Issue.record("GO26 ignored a recorded owner failure")
                } catch let failure as WebPageDocumentWaitOwnerFailure {
                    #expect(failure.closure.scope.requestId == "closed-request")
                    #expect(failure.description.contains("closed milestone"))
                    #expect(failure.description.contains("pageClosed"))
                }
                #expect(try await page.callJavaScript("return globalThis.__go26ReaderCount;") as? Int == 0)
                let observedClosure = try await source.recorder.expectNext(
                    in: .init(pane: "already closed pane", requestId: "closed-request"),
                    where: {
                        if case .pageClosed = $0 { return true }
                        return false
                    }, "pageClosed")
                #expect(observedClosure.description == "pageClosed")
                try await source.finish()
            }
        }

        @Test("GO26 owner failure joins a document success without replacing the failure")
        func ownerFailureKeepsItsDispositionWhenDocumentSucceeds() async throws {
            try await withContractPage { page in
                try await withInstalledDocumentWait(page: page) { pending in
                    let closure = WebPageDocumentWaitClosure(
                        scope: .init(pane: "racing pane", requestId: "racing-request"),
                        reason: .pageClosed)
                    // The closing disposition is captured before success is released.
                    _ = try await page.callJavaScript(
                        "document.documentElement.setAttribute('data-go26-state', 'ready');")
                    #expect(try await pending.join().value() as? String == "ready value")
                    do {
                        _ = try await WebPageEventWaits.settleClosedDocumentWait(
                            pending, closure: closure, milestone: "racing milestone")
                        Issue.record("GO26 document success replaced its winning owner failure")
                    } catch let failure as WebPageDocumentWaitOwnerFailure {
                        #expect(failure.closure.scope.requestId == "racing-request")
                        #expect(failure.description.contains("pageClosed"))
                    }
                    #expect(try await requireRemovedEntry(page: page, token: pending.token))
                    #expect(try await page.callJavaScript("return globalThis.__go26DisconnectCount;") as? Int == 1)
                }
            }
        }

        @Test("GO26 navigation closing fact aborts and joins the live document waiter")
        func navigationClosingFactAbortsAndJoinsWaiter() async throws {
            try await withContractPage { page in
                let source = try WebPageDocumentWaitClosingSource(pane: "closing pane")
                let observation = DocumentWaitFailureObservation()
                try await prepareInstallationFact(page)
                let waiter = Task { @MainActor in
                    do {
                        _ = try await WebPageEventWaits.waitForDocumentValue(
                            page, reader: installationReader + "return null;",
                            milestone: "never-ready File", closingSource: source)
                        Issue.record("GO26 closing fact waiter unexpectedly succeeded")
                    } catch { observation.error = error }
                }
                do {
                    try #require(try await requireInstallationFact(page), "GO26 document observer did not install")
                    source.record(.pageClosed, requestId: "owner-request")
                    await waiter.value
                } catch {
                    source.record(.cancelled)
                    await waiter.value
                    try? await source.finish()
                    throw error
                }
                let failure = try #require(observation.error as? WebPageDocumentWaitOwnerFailure)
                #expect(failure.closure.scope.pane == "closing pane")
                #expect(failure.closure.scope.requestId == "owner-request")
                #expect(failure.milestone == "never-ready File")
                #expect(failure.description.contains("pageClosed"))
                #expect(
                    try await page.callJavaScript("return globalThis.__agentstudioTestDocumentWaits.size;") as? Int == 0
                )
                let observedClosure = try await source.recorder.expectNext(
                    in: .init(pane: "closing pane", requestId: "owner-request"),
                    where: {
                        if case .pageClosed = $0 { return true }
                        return false
                    }, "pageClosed")
                #expect(observedClosure.description == "pageClosed")
                try await source.finish()
            }
        }

        @Test("GO26 existing failed-start marker wins over an immediate ready value")
        func existingFailedStartMarkerClosesBeforeReadyValue() async throws {
            try await withContractPage { page in
                try await renderFailureSummary(page, title: "Bridge couldn't start.")
                do {
                    _ = try await WebPageEventWaits.waitForDocumentValue(
                        page, reader: "return true;", milestone: "already failed File")
                    Issue.record("GO26 ignored an existing terminal marker")
                } catch let failure as WebPageDocumentWaitOwnerFailure {
                    #expect(failure.closure.scope.pane == "page")
                    #expect(failure.closure.scope.requestId == nil)
                    #expect(failure.milestone == "already failed File")
                    #expect(failure.description.contains("reason=failedStart"))
                }
                #expect(
                    try await page.callJavaScript("return globalThis.__agentstudioTestDocumentWaits.size;") as? Int == 0
                )
            }
        }

        @Test("GO26 transient bootstrap failures await the terminal failed-start DOM", arguments: [false, true])
        func failedStartMarkerClosesPendingWait(staleReady: Bool) async throws {
            try await withContractPage { page in
                let source = try WebPageDocumentWaitClosingSource(pane: "terminal pane")
                source.recordBootstrapFailure(.deliveryFailed)
                source.recordBootstrapFailure(.activationFailed)
                #expect(source.firstClosure == nil)
                let observation = DocumentWaitFailureObservation()
                try await prepareInstallationFact(page)
                let waiter = Task { @MainActor in
                    do {
                        _ = try await WebPageEventWaits.waitForDocumentValue(
                            page,
                            reader: installationReader + """
                                return document.documentElement.getAttribute('data-go26-state') === 'ready' ? true : null;
                                """, milestone: "terminal File", closingSource: source)
                        Issue.record("GO26 terminal marker waiter unexpectedly succeeded")
                    } catch { observation.error = error }
                }
                do {
                    try #require(try await requireInstallationFact(page), "GO26 terminal observer did not install")
                    source.recordBootstrapFailure(.activationFailed)
                    #expect(source.firstClosure == nil)
                    try await renderFailureSummary(page, title: "Bridge couldn't start.", staleReady: staleReady)
                    await waiter.value
                } catch {
                    waiter.cancel()
                    await waiter.value
                    try? await source.finish()
                    throw error
                }
                let failure = try #require(observation.error as? WebPageDocumentWaitOwnerFailure)
                #expect(failure.closure.scope.pane == "terminal pane")
                #expect(failure.closure.scope.requestId == nil)
                #expect(failure.milestone == "terminal File")
                #expect(failure.description.contains("reason=failedStart"))
                #expect(failure.description.contains("bootstrap failed 3 times, last=activation_failed"))
                #expect(
                    try await page.callJavaScript("return globalThis.__agentstudioTestDocumentWaits.size;") as? Int == 0
                )
                try await source.finish()
            }
        }

        @Test("GO26 ordinary viewer failure summary does not close a ready document wait")
        func ordinaryFailureSummaryAllowsReadyValue() async throws {
            try await withContractPage { page in
                try await withInstalledDocumentWait(page: page) { pending in
                    try await renderFailureSummary(page, title: "Files couldn't load.", staleReady: true)
                    #expect(try await pending.join().value() as? String == "ready value")
                    #expect(try await requireRemovedEntry(page: page, token: pending.token))
                    #expect(try await page.callJavaScript("return globalThis.__go26DisconnectCount;") as? Int == 1)
                }
            }
        }

        @Test("GO26 cancelled installed waiter names cancellation and empties its registry")
        func cancelledWaiterAbortsAndJoins() async throws {
            try await withContractPage { page in
                let source = try WebPageDocumentWaitClosingSource(pane: "cancelled pane")
                let observation = DocumentWaitFailureObservation()
                try await prepareInstallationFact(page)
                let waiter = Task { @MainActor in
                    do {
                        _ = try await WebPageEventWaits.waitForDocumentValue(
                            page, reader: installationReader + "return null;",
                            milestone: "cancelled File", closingSource: source)
                        Issue.record("GO26 cancelled waiter unexpectedly succeeded")
                    } catch { observation.error = error }
                }
                do {
                    try #require(try await requireInstallationFact(page), "GO26 cancellation observer did not install")
                    waiter.cancel()
                    await waiter.value
                } catch {
                    waiter.cancel()
                    await waiter.value
                    try? await source.finish()
                    throw error
                }
                let failure = try #require(observation.error as? WebPageDocumentWaitOwnerFailure)
                #expect(failure.description.contains("reason=wait cancelled"))
                #expect(failure.closure.scope.requestId == nil)
                #expect(failure.milestone == "cancelled File")
                #expect(
                    try await page.callJavaScript("return globalThis.__agentstudioTestDocumentWaits.size;") as? Int == 0
                )
                try await source.finish()
            }
        }

        private func withContractPage(_ operation: @MainActor (WebPage) async throws -> Void) async throws {
            let repoURL = try await FilesystemTestGitRepo.create(named: "bridge-document-wait-abort-contract")
            defer { FilesystemTestGitRepo.destroy(repoURL) }
            let controller = BridgeProductRealGitFileAndReviewWebKitTests().makeController(
                repoURL: repoURL, traceRecorder: BridgeProductWebKitCarrierTraceRecorder())
            try await BridgeProductWebKitTwoPaneJourneyTestSupport.withHostedControllers([controller]) {
                controller.loadApp()
                await WebPageEventWaits.waitForNavigationToFinish(controller.page)
                try await WebPageEventWaits.waitForDocumentSelector(
                    controller.page, "[data-testid=\"bridge-app-root\"]")
                // Pre-fix red fails HERE, before starting any never-resolving call.
                _ = try await WebPageEventWaits.waitForDocumentValue(controller.page, reader: "return true;")
                let registryExists = try await controller.page.callJavaScript(
                    "return globalThis.__agentstudioTestDocumentWaits instanceof Map;")
                try #require(registryExists as? Bool == true, "GO26 document wait registry was not installed")
                try await operation(controller.page)
            }
        }

        private func withInstalledDocumentWait(
            page: WebPage, operation: @MainActor (WebPagePendingDocumentWait) async throws -> Void
        ) async throws {
            try await prepareInstallationFact(page)
            let pending = WebPagePendingDocumentWait(
                page: page,
                reader: installationReader + """
                    const state = document.documentElement.getAttribute('data-go26-state');
                    if (state === 'throw') throw new Error('GO26 reader failed');
                    return state === 'ready' ? 'ready value' : null;
                    """)
            do {
                try #require(try await requireInstallationFact(page), "GO26 document observer did not install")
                let instrumented = try await page.callJavaScript(
                    """
                    const observer = globalThis.__agentstudioTestDocumentWaits.get(token)?.observer;
                    if (!observer) return false;
                    globalThis.__go26DisconnectCount = 0;
                    const disconnect = observer.disconnect.bind(observer);
                    observer.disconnect = () => { globalThis.__go26DisconnectCount++; disconnect(); };
                    return true;
                    """, arguments: ["token": pending.token])
                try #require(instrumented as? Bool == true, "GO26 registered observer is missing")
                try await operation(pending)
                _ = try? await pending.join()
            } catch {
                let cleanup = Task { @MainActor in
                    _ = try? await WebPageEventWaits.settleClosedDocumentWait(
                        pending,
                        closure: .init(scope: .init(pane: "contract fixture", requestId: nil), reason: .cancelled),
                        milestone: "contract error-path cleanup")
                }
                await cleanup.value
                throw error
            }
        }

        private func renderFailureSummary(_ page: WebPage, title: String, staleReady: Bool = false) async throws {
            _ = try await page.callJavaScript(
                """
                const summary = document.createElement('div');
                summary.setAttribute('data-testid', 'bridge-pane-failure-summary');
                summary.setAttribute('data-bridge-region', 'pane-failure');
                summary.setAttribute('data-presentation-state', 'failed');
                const heading = document.createElement('div');
                heading.setAttribute('data-slot', 'alert-title');
                heading.textContent = title;
                summary.append(heading);
                document.body.append(summary);
                if (staleReady) document.documentElement.setAttribute('data-go26-state', 'ready');
                """, arguments: ["title": title, "staleReady": staleReady])
        }

        private func prepareInstallationFact(_ page: WebPage) async throws {
            _ = try await page.callJavaScript(
                """
                document.documentElement.removeAttribute('data-go26-state');
                globalThis.__go26Installed = new Promise(resolve => { globalThis.__go26RecordInstalled = resolve; });
                return true;
                """)
        }

        private var installationReader: String {
            """
            if (globalThis.__go26RecordInstalled) {
              globalThis.__go26RecordInstalled(true);
              delete globalThis.__go26RecordInstalled;
            }
            """
        }

        private func requireInstallationFact(_ page: WebPage) async throws -> Bool {
            let installed = try await awaitBridgeWebKitMilestone("GO26 registry observer installation") {
                try await page.callJavaScript("return await globalThis.__go26Installed;")
            }
            return try #require(installed as? Bool, "GO26 missing document observer installation fact")
        }

        private func requireRemovedEntry(page: WebPage, token: String) async throws -> Bool {
            let removed = try await page.callJavaScript(
                "return !globalThis.__agentstudioTestDocumentWaits.has(token);", arguments: ["token": token])
            return try #require(removed as? Bool, "GO26 missing registry entry removal observation")
        }
    }
}

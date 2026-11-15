import Foundation
import JavaScriptCore
import Testing
import WebKit

@testable import AgentStudioBridge
@testable import AgentStudioTestSupport

@MainActor
extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    @Test
    func selectedReviewPaneRetirementSourceFollowsControllerTeardown() async throws {
        let repoURL = try await FilesystemTestGitRepo.create(named: "selected-review-pane-retirement")
        defer { FilesystemTestGitRepo.destroy(repoURL) }
        let controller = makeController(repoURL: repoURL, traceRecorder: BridgeProductWebKitCarrierTraceRecorder())
        let source = try WebPageDocumentWaitClosingSource(pane: controller.paneId.uuidString)
        source.observePaneRetirement(controller)
        let retirement = controller.beginTeardown()
        do {
            _ = try await source.recorder.expectNext(
                in: .init(pane: controller.paneId.uuidString, requestId: nil),
                where: { if case .pageClosed = $0 { true } else { false } },
                "selected Review pane teardown closes document waits")
            #expect(await retirement.value)
            try await source.finish()
        } catch {
            _ = await retirement.value
            try? await source.finish()
            throw error
        }
    }

    @Test
    func selectedReviewContentWaitRejectsRetiredPane() async throws {
        let repoURL = try await FilesystemTestGitRepo.create(named: "selected-review-retired-pane")
        defer { FilesystemTestGitRepo.destroy(repoURL) }
        let controller = makeController(repoURL: repoURL, traceRecorder: BridgeProductWebKitCarrierTraceRecorder())
        let run = try await BridgeProductWebKitCarrierTestSupport.withHostedController(controller) { hosted in
            let navigation = hosted.page.load(
                html: """
                    <html><body><div data-testid="review-viewer-shell"
                      data-selected-content-state="ready" data-selected-display-path="tracked.txt"
                      data-review-metadata-generation="41"></div>
                    <div data-testid="bridge-code-view-panel" data-selected-content-line-count="2"
                      data-review-rendered-item-id="literalItem"
                      data-selected-content-cache-keys="head:descriptor:literalHash"></div></body></html>
                    """)
            var finished = false
            for try await event in navigation where event == .finished {
                finished = true
                break
            }
            try #require(finished, "Retirement fixture navigation ended without a finished document")
            let retirement = hosted.beginTeardown()
            do {
                _ = try await BridgeProductWebKitSelectedReviewContentWait.wait(
                    hosted, expectedPath: "tracked.txt", expectedHashes: "head:literalHash",
                    expectedGeneration: 41, expectedItemId: "literalItem")
                Issue.record(
                    "Retired pane must close the selected Review content wait before accepting stale ready DOM")
            } catch let failure as WebPageDocumentWaitOwnerFailure {
                #expect(failure.closure.scope.pane == hosted.paneId.uuidString)
                #expect(failure.closure.reason.description == "pageClosed")
                #expect(failure.milestone == "Review selected content rendered")
            } catch {
                _ = await retirement.value
                throw error
            }
            #expect(await retirement.value)
        }
        #expect(run.teardownSnapshot.hasZeroResidue)
    }

    @Test(arguments: ["failed", "unavailable"])
    func selectedReviewContentReaderClosesOnCorrelatedFailure(_ state: String) throws {
        let context = try #require(JSContext())
        context.setObject(state, forKeyedSubscript: "terminalState" as NSString)
        let observation = context.evaluateScript(
            selectedReviewReaderFixture + """
                shellAttributes['data-selected-content-state'] = terminalState;
                contentRegionAttributes['data-presentation-state'] = 'failed';
                returnValue = (() => { \(BridgeProductWebKitSelectedReviewContentWait.reader) })();
                JSON.stringify(returnValue);
                """)
        try #require(context.exception == nil, "Reader must execute without a JavaScript exception")
        // Literal terminal oracle. This is a reader unit check, not native proof.
        let encoded = try #require(observation?.toString())
        try #require(encoded != "null", "Terminal \(state) must close the selected Review content wait")
        let terminal = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        do {
            _ = try BridgeProductWebKitSelectedReviewContentWait.requireRenderedPath(from: terminal)
            Issue.record("Correlated failed content must throw with its diagnostic")
        } catch let failure as BridgeProductWebKitSelectedReviewContentFailure {
            #expect(failure.path == "tracked.txt")
            #expect(failure.generation == 41)
            #expect(failure.state == state)
            #expect(failure.description.contains("\"pageAvailability\":\"\(state)\""))
            #expect(failure.description.contains("\"captureInstalled\":false"))
        }
    }

    @Test
    func selectedReviewFailureCaptureCarriesWorkerAndRenderReasons() throws {
        let context = try #require(JSContext())
        let observation = context.evaluateScript(
            selectedReviewReaderFixture + selectedReviewCaptureFixture
                + BridgeProductWebKitSelectedReviewFailureCapture.script + """
                    const channel = new window.MessageChannel();
                    const identity = {packageId: 'literalPackage', reviewGeneration: 41,
                      publicationId: 'literalPublication', revision: 7, sourceIdentity: 'literalSource'};
                    channel.port2.deliver({kind: 'reviewRenderPatch', reviewPublicationIdentity: identity,
                      publicationSequence: 12, workerDerivationEpoch: 3,
                      patches: [{slice: 'contentAvailability', operation: 'upsert', itemId: 'literalItem',
                        payload: {state: 'failed', reason: 'load_failed'}}]});
                    channel.port2.deliver({kind: 'reviewRenderPatch',
                      reviewPublicationIdentity: {...identity, reviewGeneration: 40},
                      patches: [{slice: 'contentAvailability', operation: 'upsert', itemId: 'literalItem',
                        payload: {state: 'failed', reason: 'stale'}}]});
                    console.error('Bridge Review render-copy invariant breach',
                      {kind: 'review_selected_ready_without_render_copy', itemId: 'literalItem'});
                    shellAttributes['data-selected-content-state'] = 'failed';
                    JSON.stringify((() => { \(BridgeProductWebKitSelectedReviewContentWait.reader) })());
                    """)
        try #require(context.exception == nil)
        let encoded = try #require(observation?.toString())
        let terminal = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        do {
            _ = try BridgeProductWebKitSelectedReviewContentWait.requireRenderedPath(from: terminal)
            Issue.record("Correlated failed content must throw with the captured causes")
        } catch let failure as BridgeProductWebKitSelectedReviewContentFailure {
            let diagnostic = try #require(
                try JSONSerialization.jsonObject(with: Data(failure.diagnostic.utf8)) as? [String: Any])
            let records = try #require(diagnostic["correlatedWorkerAvailability"] as? [[String: Any]])
            #expect(records.count == 1)
            let record = try #require(records.first)
            let availability = try #require(record["availability"] as? [String: Any])
            #expect(availability["reason"] as? String == "load_failed")
            #expect(record["publicationSequence"] as? Int == 12)
            let identity = try #require(record["identity"] as? [String: Any])
            #expect(identity["publicationId"] as? String == "literalPublication")
            #expect(failure.description.contains("review_selected_ready_without_render_copy"))
        }
    }

    @Test
    func selectedReviewFailureCaptureNamesMissingRenderCopyBeforeConsoleEffect() throws {
        let context = try #require(JSContext())
        let observation = context.evaluateScript(
            selectedReviewReaderFixture + selectedReviewCaptureFixture
                + BridgeProductWebKitSelectedReviewFailureCapture.script + """
                    const channel = new window.MessageChannel();
                    channel.port2.deliver({kind: 'reviewRenderPatch',
                      reviewPublicationIdentity: {packageId: 'literalPackage', reviewGeneration: 41},
                      patches: [{slice: 'contentAvailability', operation: 'upsert', itemId: 'literalItem',
                        payload: {state: 'ready'}}]});
                    shellAttributes['data-selected-content-state'] = 'failed';
                    delete panelAttributes['data-review-rendered-item-id'];
                    (() => { \(BridgeProductWebKitSelectedReviewContentWait.failureDiagnosticReader) })();
                    """)
        try #require(context.exception == nil)
        let encoded = try #require(observation?.toString())
        let result = try #require(
            try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(result["inferredRenderControllerReason"] as? String == "review_selected_ready_without_render_copy")
        #expect((result["renderControllerReasons"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test
    func selectedReviewFailureCaptureBoundsRecordsAndPreservesConsole() throws {
        let context = try #require(JSContext())
        let observation = context.evaluateScript(
            selectedReviewCaptureFixture + BridgeProductWebKitSelectedReviewFailureCapture.script + """
                for (let index = 0; index < 70; index += 1) {
                  console.error('Bridge Review render-copy invariant breach',
                    {kind: 'review_selected_ready_without_render_copy', itemId: `item-${index}`});
                }
                JSON.stringify({count: window.__bridgeSelectedReviewFailureCapture.records.length,
                  dropped: window.__bridgeSelectedReviewFailureCapture.droppedRecordCount,
                  firstItem: window.__bridgeSelectedReviewFailureCapture.records[0].itemId,
                  forwardedConsoleErrors});
                """)
        try #require(context.exception == nil)
        let encoded = try #require(observation?.toString())
        let result = try #require(
            try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(result["count"] as? Int == 64)
        #expect(result["dropped"] as? Int == 6)
        #expect(result["firstItem"] as? String == "item-6")
        #expect(result["forwardedConsoleErrors"] as? Int == 70)
    }

    @Test(arguments: ["loading", "unavailable", "differentPath", "differentGeneration", "wrongHashes", "noLines"])
    func selectedReviewContentReaderKeepsIncompleteOrUncorrelatedStateOpen(_ scenario: String) throws {
        let context = try #require(JSContext())
        context.setObject(scenario, forKeyedSubscript: "scenario" as NSString)
        let observation = context.evaluateScript(
            selectedReviewReaderFixture + """
                if (scenario === 'loading' || scenario === 'unavailable') {
                  shellAttributes['data-selected-content-state'] = scenario;
                } else if (scenario === 'differentPath') {
                  shellAttributes['data-selected-content-state'] = 'failed';
                  shellAttributes['data-selected-display-path'] = 'other.txt';
                } else if (scenario === 'differentGeneration') {
                  shellAttributes['data-selected-content-state'] = 'failed';
                  shellAttributes['data-review-metadata-generation'] = '40';
                } else if (scenario === 'wrongHashes') {
                  panelAttributes['data-selected-content-cache-keys'] = 'head:descriptor:otherHash';
                } else if (scenario === 'noLines') {
                  panelAttributes['data-selected-content-line-count'] = '0';
                }
                JSON.stringify((() => { \(BridgeProductWebKitSelectedReviewContentWait.reader) })());
                """)
        try #require(context.exception == nil)
        #expect(observation?.toString() == "null")
    }

    @Test
    func selectedReviewContentReaderRetainsRenderedContentOracle() throws {
        let context = try #require(JSContext())
        let observation = context.evaluateScript(
            selectedReviewReaderFixture + """
                (() => { \(BridgeProductWebKitSelectedReviewContentWait.reader) })();
                """)
        try #require(context.exception == nil)
        #expect(
            try BridgeProductWebKitSelectedReviewContentWait.requireRenderedPath(
                from: observation?.toString()) == "tracked.txt")
    }
}

// The stand-in represents only DOM attributes. The native Git/provider/worker
// regression remains separate and must run on a host with functional WebKit.
private let selectedReviewReaderFixture = """
    const expectedPath = 'tracked.txt';
    const expectedHashes = 'head:literalHash';
    const expectedGeneration = 41;
    const expectedItemId = 'literalItem';
    const window = {};
    const shellAttributes = {
      'data-selected-content-state': 'ready',
      'data-selected-display-path': 'tracked.txt',
      'data-review-metadata-generation': '41',
      'data-review-metadata-id': 'literalPackage'
    };
    const panelAttributes = {
      'data-selected-content-cache-keys': 'head:descriptor:literalHash',
      'data-selected-content-line-count': '2',
      'data-review-rendered-item-id': 'literalItem'
    };
    const contentRegionAttributes = {'data-presentation-state': 'content'};
    const document = {querySelector: selector => {
      if (selector === '[data-bridge-region="review-content"]') {
        return {getAttribute: name => contentRegionAttributes[name] ?? null};
      }
      const attributes = selector === '[data-testid="review-viewer-shell"]'
        ? shellAttributes : panelAttributes;
      return {getAttribute: name => attributes[name] ?? null};
    }};
    window.document = document;
    """

// Only the observation transport is a stand-in. The native hash-mismatch
// scenario separately proves the diagnostic against the real worker message.
private let selectedReviewCaptureFixture = """
    globalThis.window ??= {};
    let forwardedConsoleErrors = 0;
    const console = {error: () => { forwardedConsoleErrors += 1; }};
    window.MessageChannel = class {
      constructor() {
        const listeners = [];
        this.port2 = {
          addEventListener: (name, listener) => { if (name === 'message') listeners.push(listener); },
          deliver: data => { for (const listener of listeners) listener({data}); }
        };
      }
    };
    """

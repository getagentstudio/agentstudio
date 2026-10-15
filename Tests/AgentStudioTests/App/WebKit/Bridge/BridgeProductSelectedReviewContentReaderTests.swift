import Foundation
import JavaScriptCore
import Testing

@MainActor
extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    @Test
    func selectedReviewContentReaderClosesOnCorrelatedFailure() throws {
        let context = try #require(JSContext())
        let observation = context.evaluateScript(
            selectedReviewReaderFixture + """
                shellAttributes['data-selected-content-state'] = 'failed';
                returnValue = (() => { \(BridgeProductWebKitSelectedReviewContentWait.reader) })();
                JSON.stringify(returnValue);
                """)
        try #require(context.exception == nil, "Reader must execute without a JavaScript exception")
        // Literal terminal oracle. This is a reader unit check, not native proof.
        let encoded = try #require(observation?.toString())
        let terminal = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        #expect(
            throws: BridgeProductWebKitSelectedReviewContentFailure(
                path: "tracked.txt", generation: 41, state: "failed")
        ) {
            try BridgeProductWebKitSelectedReviewContentWait.requireRenderedPath(from: terminal)
        }
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
    const shellAttributes = {
      'data-selected-content-state': 'ready',
      'data-selected-display-path': 'tracked.txt',
      'data-review-metadata-generation': '41'
    };
    const panelAttributes = {
      'data-selected-content-cache-keys': 'head:descriptor:literalHash',
      'data-selected-content-line-count': '2',
      'data-review-rendered-item-id': 'literalItem'
    };
    const document = {querySelector: selector => {
      const attributes = selector === '[data-testid="review-viewer-shell"]'
        ? shellAttributes : panelAttributes;
      return {getAttribute: name => attributes[name] ?? null};
    }};
    """

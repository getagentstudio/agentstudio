import Foundation
import WebKit

struct BridgeProductWebKitSelectedReviewContentFailure: Error, Equatable, CustomStringConvertible {
    let path: String
    let generation: Int
    let state: String

    var description: String {
        "Review selected content rendered: terminal state=\(state),path=\(path),generation=\(generation)"
    }
}

@MainActor
enum BridgeProductWebKitSelectedReviewContentWait {
    static let reader = """
        const shell = document.querySelector('[data-testid="review-viewer-shell"]');
        const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
        const hashes = (panel?.getAttribute('data-selected-content-cache-keys') ?? '')
          .split(',').filter(Boolean)
          .map(entry => `${entry.split(':')[0] ?? ''}:${entry.split(':').pop() ?? ''}`)
          .join(',');
        const path = shell?.getAttribute('data-selected-display-path');
        const state = shell?.getAttribute('data-selected-content-state');
        const generation = Number(shell?.getAttribute('data-review-metadata-generation'));
        if (path !== expectedPath || generation !== expectedGeneration) return null;
        if (state === 'failed') return {state, path, generation};
        return state === 'ready'
          && Number(panel?.getAttribute('data-selected-content-line-count') ?? '0') > 0
          && Boolean(panel?.getAttribute('data-review-rendered-item-id') ?? panel?.getAttribute('data-selected-item-id'))
          && path === expectedPath && hashes === expectedHashes ? path : null;
        """

    static let diagnostic = """
        const shell = document.querySelector('[data-testid="review-viewer-shell"]');
        const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
        return `state=${shell?.getAttribute('data-selected-content-state') ?? 'missing'},path=${shell?.getAttribute('data-selected-display-path') ?? 'missing'},generation=${shell?.getAttribute('data-review-metadata-generation') ?? 'missing'},lines=${panel?.getAttribute('data-selected-content-line-count') ?? 'missing'}`;
        """

    static func wait(
        _ page: WebPage, expectedPath: String, expectedHashes: String, expectedGeneration: Int
    ) async throws -> Any? {
        let observation = try await WebPageEventWaits.waitForDocumentValue(
            page, reader: reader,
            arguments: [
                "expectedPath": expectedPath, "expectedHashes": expectedHashes,
                "expectedGeneration": expectedGeneration,
            ],
            milestone: "Review selected content rendered", lastObservation: diagnostic
        )
        return try requireRenderedPath(from: observation)
    }

    static func requireRenderedPath(from observation: Any?) throws -> String {
        if let terminal = observation as? [String: Any],
            terminal["state"] as? String == "failed",
            let path = terminal["path"] as? String,
            let generation = terminal["generation"] as? Int
        {
            throw BridgeProductWebKitSelectedReviewContentFailure(
                path: path, generation: generation, state: "failed")
        }
        guard let path = observation as? String else {
            throw WebPageDocumentWaitProtocolFailure(detail: "unexpected selected Review content observation")
        }
        return path
    }
}

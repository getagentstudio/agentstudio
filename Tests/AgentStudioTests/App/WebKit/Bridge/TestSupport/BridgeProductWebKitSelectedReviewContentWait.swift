import Foundation
import WebKit

@testable import AgentStudioBridge

struct BridgeProductWebKitSelectedReviewContentFailure: Error, Equatable, CustomStringConvertible {
    let path: String
    let generation: Int
    let state: String
    let diagnostic: String

    var description: String {
        "Review selected content rendered: terminal state=\(state),path=\(path),generation=\(generation),cause=\(diagnostic)"
    }
}

@MainActor
enum BridgeProductWebKitSelectedReviewContentWait {
    static let failureDiagnosticReader = """
        const shell = document.querySelector('[data-testid="review-viewer-shell"]');
        const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
        const owner = window.__bridgeReviewSelectionDiagnostic;
        const capture = window.__bridgeSelectedReviewFailureCapture;
        const attribute = name => shell?.getAttribute(name) ?? null;
        const packageId = attribute('data-review-metadata-id');
        const generation = Number(attribute('data-review-metadata-generation'));
        const records = capture?.records ?? [];
        const correlatedWorkerAvailability = records.filter(record => record.kind === 'workerAvailability'
          && record.identity?.packageId === packageId
          && record.identity?.reviewGeneration === generation && record.itemId === expectedItemId);
        const renderedItemId = panel?.getAttribute('data-review-rendered-item-id')
          ?? panel?.getAttribute('data-selected-item-id') ?? null;
        return JSON.stringify({
          pageAvailability: attribute('data-selected-content-state'),
          contentPresentation: document.querySelector('[data-bridge-region="review-content"]')
            ?.getAttribute('data-presentation-state') ?? null,
          path: attribute('data-selected-display-path'), packageId, generation,
          revision: attribute('data-review-metadata-revision'),
          renderedItemId,
          lineCount: panel?.getAttribute('data-selected-content-line-count') ?? null,
          selectedDemand: {
            itemId: attribute('data-review-selected-demand-item-id'),
            packageId: attribute('data-review-selected-demand-package-id'),
            generation: attribute('data-review-selected-demand-package-generation'),
            status: attribute('data-review-selected-demand-result-status'),
            reason: attribute('data-review-selected-demand-result-reason'),
            loadFailureKind: attribute('data-review-selected-demand-load-failure-kind')
          },
          reviewPresentation: owner?.reviewPresentation ?? null,
          installationGate: owner?.reviewInstallationGate ?? null,
          lastDisplayPatch: owner?.lastReviewDisplayPatch ?? null,
          captureInstalled: capture !== undefined,
          droppedRecordCount: capture?.droppedRecordCount ?? 0,
          selectedItemId: expectedItemId,
          correlatedWorkerAvailability,
          // The controller's console effect may follow the failed DOM mutation.
          // Keep this inference separate from reasons actually emitted by it.
          inferredRenderControllerReason: attribute('data-selected-content-state') === 'failed'
            && correlatedWorkerAvailability.at(-1)?.availability?.state === 'ready'
            && renderedItemId === null ? 'review_selected_ready_without_render_copy' : null,
          renderControllerReasons: records.filter(record =>
            record.kind === 'review_selected_ready_without_render_copy' && record.itemId === expectedItemId
            && record.pagePackageId === packageId && record.pageGeneration === generation)
        });
        """

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
        // Raw unavailable can precede a demand. A failed region is the owner's
        // final read disposition; loading and other in-flight states stay open.
        const contentPresentation = document.querySelector('[data-bridge-region="review-content"]')
          ?.getAttribute('data-presentation-state');
        if (state === 'failed' || (state === 'unavailable' && contentPresentation === 'failed')) return {state, path, generation,
          diagnostic: (() => { \(failureDiagnosticReader) })()};
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
        _ controller: BridgePaneController, expectedPath: String, expectedHashes: String, expectedGeneration: Int,
        expectedItemId: String
    ) async throws -> Any? {
        let closingSource = try WebPageDocumentWaitClosingSource(pane: controller.paneId.uuidString)
        closingSource.observePaneRetirement(controller)
        closingSource.observePage(controller.page)
        do {
            let observation = try await WebPageEventWaits.waitForDocumentValue(
                controller.page, reader: reader,
                arguments: [
                    "expectedPath": expectedPath, "expectedHashes": expectedHashes,
                    "expectedGeneration": expectedGeneration,
                    "expectedItemId": expectedItemId,
                ],
                milestone: "Review selected content rendered", lastObservation: diagnostic, closingSource: closingSource
            )
            let path = try requireRenderedPath(from: observation)
            try await closingSource.finish()
            return path
        } catch {
            let primaryFailure = error
            try? await closingSource.finish()
            throw primaryFailure
        }
    }

    static func requireRenderedPath(from observation: Any?) throws -> String {
        if let terminal = observation as? [String: Any],
            let state = terminal["state"] as? String,
            state == "failed" || state == "unavailable",
            let path = terminal["path"] as? String,
            let generation = terminal["generation"] as? Int
        {
            throw BridgeProductWebKitSelectedReviewContentFailure(
                path: path, generation: generation, state: state,
                diagnostic: terminal["diagnostic"] as? String ?? "unavailable")
        }
        guard let path = observation as? String else {
            throw WebPageDocumentWaitProtocolFailure(detail: "unexpected selected Review content observation")
        }
        return path
    }
}

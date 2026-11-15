import Testing
import WebKit

@testable import AgentStudioBridge

/// Observes existing worker messages and the render controller's console reason.
/// Records are bounded and document-local; navigation releases the observers.
@MainActor
enum BridgeProductWebKitSelectedReviewFailureCapture {
    static func install(on controller: BridgePaneController) throws {
        // Reuse the packaged-capture seam without adding a production test API.
        let contentController = try #require(
            Mirror(reflecting: controller).children.first { $0.label == "userContentController" }?.value
                as? WKUserContentController
        )
        contentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    static let script = """
        (() => {
          const capture = {records: [], droppedRecordCount: 0};
          window.__bridgeSelectedReviewFailureCapture = capture;
          const record = value => {
            if (capture.records.length === 64) {
              capture.records.shift();
              capture.droppedRecordCount += 1;
            }
            capture.records.push(value);
          };
          const originalError = console.error;
          console.error = function(...arguments_) {
            const reason = arguments_[1];
            if (reason?.kind === 'review_selected_ready_without_render_copy') {
              const shell = window.document?.querySelector('[data-testid="review-viewer-shell"]');
              record({kind: reason.kind, itemId: reason.itemId,
                pagePackageId: shell?.getAttribute('data-review-metadata-id') ?? null,
                pageGeneration: Number(shell?.getAttribute('data-review-metadata-generation'))});
            }
            return Reflect.apply(originalError, this, arguments_);
          };
          const OriginalMessageChannel = window.MessageChannel;
          window.MessageChannel = new Proxy(OriginalMessageChannel, {
            construct(target, arguments_) {
              const channel = Reflect.construct(target, arguments_);
              channel.port2.addEventListener('message', event => {
                const message = event.data;
                if (message?.kind !== 'reviewRenderPatch') return;
                for (const patch of message.patches ?? []) {
                  if (patch.slice !== 'contentAvailability') continue;
                  record({kind: 'workerAvailability',
                    identity: message.reviewPublicationIdentity,
                    publicationSequence: message.publicationSequence,
                    workerDerivationEpoch: message.workerDerivationEpoch,
                    operation: patch.operation, itemId: patch.itemId ?? null,
                    availability: patch.payload ?? null});
                }
              });
              // The product owns port.start(), close(), and message handling.
              return channel;
            }
          });
        })();
        """
}

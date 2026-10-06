import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing
import WebKit

@testable import AgentStudioBridge
@testable import AgentStudioTestSupport

/// Test-only forwarding of the existing page diagnostic, with no stream reads of its own.
@MainActor
final class BridgePackagedLiveCapture {
    private let controller: BridgePaneController
    private let contentController: WKUserContentController
    private struct CaptureState {
        var isClosed = false
        var tasks: [Task<Void, Never>] = []
    }
    private nonisolated let snapshotTasks = Mutex(CaptureState())

    init(controller: BridgePaneController) throws {
        self.controller = controller
        // The production controller keeps this existing controller private. Reflect
        // that single stored reference rather than adding a production testing API.
        contentController = try #require(
            Mirror(reflecting: controller).children.first { $0.label == "userContentController" }?.value
                as? WKUserContentController
        )
        let recorder = WebKitScriptMessageRecorder { [weak self] observation in
            self?.snapshotTasks.withLock { state in
                guard !state.isClosed else { return }
                TestEventLogWriter.append(
                    "packaged_observation\t\(observation)\n", path: HeldStepEventLog.environment.path)
                state.tasks.append(
                    Task { @MainActor in
                        let native = await packagedProductNativeReadback(controller)
                        TestEventLogWriter.append(
                            "packaged_native\tcorrelated=\(observation)\tnative=\(native)\n",
                            path: HeldStepEventLog.environment.path)
                    })
            }
        }
        contentController.add(recorder, contentWorld: .page, name: "pageProbe")
        contentController.addUserScript(
            WKUserScript(
                source: Self.captureScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )
    }

    func withManagedPage(_ operation: @escaping @MainActor (WebPage) async throws -> Void) async throws {
        do {
            try await WebPageTestHarness.withManagedPage(controller.page, operation: operation)
        } catch {
            await close()
            throw error
        }
        await close()
    }

    private func close() async {
        _ = try? await controller.page.callJavaScript("window.__bridgePackagedLiveCaptureStop?.();")
        contentController.removeScriptMessageHandler(forName: "pageProbe", contentWorld: .page)
        let tasks = snapshotTasks.withLock { state -> [Task<Void, Never>] in
            state.isClosed = true
            let pending = state.tasks
            state.tasks.removeAll()
            return pending
        }
        for task in tasks { await task.value }
    }

    private static let captureScript = #"""
        (() => {
          const forward = observation => {
            window.webkit.messageHandlers.pageProbe.postMessage(JSON.stringify(observation));
          };
          let current = window.__bridgeProductMetadataStreamDiagnostic;
          Object.defineProperty(window, '__bridgeProductMetadataStreamDiagnostic', {
            configurable: true,
            get: () => current,
            set: value => {
              current = value;
              forward({kind: 'streamHealth', diagnostic: value});
            }
          });
          if (current !== undefined) forward({kind: 'streamHealth', diagnostic: current});

          let reviewDiagnostic = window.__bridgeReviewSelectionDiagnostic;
          const observeReviewDiagnostic = value => value === undefined ? undefined : new Proxy(value, {
            set(target, property, next) {
              const before = JSON.stringify(target[property]);
              const changed = Reflect.set(target, property, next);
              if (before !== JSON.stringify(next)) forward({
                kind: 'reviewOwnerDiagnostic', changedField: String(property), diagnostic: target
              });
              return changed;
            }
          });
          reviewDiagnostic = observeReviewDiagnostic(reviewDiagnostic);
          Object.defineProperty(window, '__bridgeReviewSelectionDiagnostic', {
            configurable: true, get: () => reviewDiagnostic,
            set: value => {
              reviewDiagnostic = observeReviewDiagnostic(value);
              forward({kind: 'reviewOwnerDiagnostic', changedField: 'installed', diagnostic: value});
            }
          });
          let lastReviewDOM = '';
          const observeReviewDOM = () => {
            const snapshot = {
              activeViewerMode: document.querySelector('[data-testid="bridge-app-root"]')
                ?.getAttribute('data-bridge-viewer-mode') ?? null,
              shellPresent: document.querySelector('[data-testid="review-viewer-shell"]') !== null,
              regions: Array.from(document.querySelectorAll('[data-bridge-region^="review-"]'))
                .map(region => ({region: region.getAttribute('data-bridge-region'),
                  state: region.getAttribute('data-presentation-state'),
                  emptyReason: region.getAttribute('data-empty-reason')}))
            };
            const encoded = JSON.stringify(snapshot);
            if (encoded === lastReviewDOM) return;
            lastReviewDOM = encoded;
            forward({kind: 'reviewDOM', ...snapshot});
          };
          const reviewDOMObserver = new MutationObserver(observeReviewDOM);
          reviewDOMObserver.observe(document, {subtree: true, childList: true, attributes: true,
            attributeFilter: ['data-bridge-viewer-mode', 'data-presentation-state', 'data-empty-reason']});
          const portObservers = [];
          window.__bridgePackagedLiveCaptureStop = () => {
            reviewDOMObserver.disconnect();
            for (const {port, listener} of portObservers) port.removeEventListener('message', listener);
            portObservers.length = 0;
          };
          const OriginalMessageChannel = window.MessageChannel;
          window.MessageChannel = new Proxy(OriginalMessageChannel, {
            construct(target, arguments_) {
              const channel = Reflect.construct(target, arguments_);
              const port = channel.port2;
              const listener = event => {
                const incoming = event.data;
                if (incoming?.kind === 'viewRecoveryStatus') {
                  forward({kind: 'productViewRecoveryStatus', message: incoming});
                } else if (incoming?.kind === 'reviewCandidateStarted' ||
                           incoming?.kind === 'reviewCandidateReady' ||
                           incoming?.kind === 'reviewCandidateFailed' ||
                           incoming?.kind === 'reviewDisplayPatch') {
                  const source = incoming.patches?.find(patch => patch.slice === 'reviewSource')?.payload;
                  forward({kind: 'productReviewPublicationMessage', messageKind: incoming.kind,
                    identity: incoming.reviewPublicationIdentity ?? null,
                    publicationId: incoming.publicationId ?? null, packageId: incoming.packageId ?? null,
                    epoch: incoming.epoch ?? null, revision: incoming.revision ?? null,
                    sourceStatus: source?.status ?? null,
                    comparison: incoming.patches?.find(patch => patch.slice === 'reviewComparison')?.payload ?? null});
                }
              };
              port.addEventListener('message', listener);
              portObservers.push({port, listener});
              const originalPost = port.postMessage.bind(port);
              port.postMessage = (...postArguments) => {
                const message = postArguments[0];
                if (message?.command === 'renderDisposition')
                  forward({kind: 'productReviewPublicationReceipts', receipts:
                    message.receipts.filter(receipt => receipt.surface === 'review')});
                return originalPost(...postArguments);
              };
              // Its owner calls start and close. This observer creates no channel
              // of its own and never advances, suppresses, or repeats a message.
              return channel;
            }
          });

          // The packaged worker is a Blob made from its fetched module source.
          // Prefix that same source; do not add an import of a URL its owner revokes.
          function installWorkerCommandObservation() {
            const originalFetch = self.fetch;
            const operations = new Map();
            const subscriptions = new Map();
            const report = observation => {
              try { self.postMessage({
                direction: 'serverWorkerToMain', kind: 'health', status: 'ready',
                transferDescriptors: [], wireVersion: 1,
                message: 'packaged-subscription:' + JSON.stringify(observation)
              }); } catch {}
            };
            report({kind: 'commandProbe', phase: 'workerInstalled'});
            self.fetch = async (...arguments_) => {
              const [input, init] = arguments_;
              const url = typeof input === 'string' ? input : input?.url ?? String(input);
              let request;
              try {
                if (url.includes('/command') && init?.body !== undefined) {
                  const body = init.body;
                  const text = typeof body === 'string' ? body :
                    (ArrayBuffer.isView(body) || Object.prototype.toString.call(body) === '[object ArrayBuffer]')
                    ? new TextDecoder().decode(body) : null;
                  if (text !== null) request = JSON.parse(text);
                }
              } catch {}
              if (url.includes('/command') && request === undefined)
                report({kind: 'commandProbe', phase: 'unparsedRequest', bodyType: Object.prototype.toString.call(init?.body)});
              const correlation = request?.kind === 'subscription.open'
                ? {openRequestId: request.requestId, subscriptionId: request.subscriptionId,
                   subscriptionKind: request.subscription?.subscriptionKind,
                   workerDerivationEpoch: request.workerDerivationEpoch}
                : operations.get(request?.operationId) ?? subscriptions.get(request?.subscriptionId);
              if (request?.kind === 'subscription.open') subscriptions.set(request.subscriptionId, correlation);
              if (correlation !== undefined)
                report({kind: 'command', phase: 'sent', requestKind: request.kind, requestId: request.requestId ?? null,
                        operationId: request.operationId ?? null, ...correlation});
              let response;
              try { response = await Reflect.apply(originalFetch, self, arguments_); }
              catch (error) {
                if (correlation !== undefined)
                  report({kind: 'command', phase: 'fetchRejected', requestKind: request.kind, requestId: request.requestId ?? null,
                          error: String(error), ...correlation});
                throw error;
              }
              if (correlation === undefined) return response;
              report({kind: 'command', phase: 'response', requestKind: request.kind, requestId: request.requestId ?? null,
                      status: response.status, ...correlation});
              const body = response.body;
              if (body === null) return response;
              const getReader = body.getReader.bind(body);
              // Observe the caller's existing reads. Never clone or tee a response,
              // and never read the metadata stream or introduce another pull.
              body.getReader = (...readerArguments) => {
                const reader = getReader(...readerArguments);
                const chunks = [];
                let byteCount = 0;
                let reported = false;
                return new Proxy(reader, {
                  get(target, property) {
                    if (property !== 'read') {
                      const value = Reflect.get(target, property, target);
                      return typeof value === 'function' ? value.bind(target) : value;
                    }
                    return async (...readArguments) => {
                      const result = await Reflect.apply(target.read, target, readArguments);
                      if (!result.done && byteCount <= 262144) {
                        byteCount += result.value.byteLength;
                        if (byteCount <= 262144) chunks.push(result.value.slice());
                      }
                      if (result.done && !reported) {
                        reported = true;
                        let payload;
                        try {
                          const bytes = new Uint8Array(byteCount <= 262144 ? byteCount : 0);
                          let offset = 0;
                          for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
                          payload = JSON.parse(new TextDecoder().decode(bytes));
                        } catch {}
                        if (payload?.kind === 'operation.admitted' && payload.operationId)
                          operations.set(payload.operationId, {...correlation, commandKind: request.kind, commandRequestId: request.requestId});
                        report({kind: 'command', phase: 'bodyConsumed', requestKind: request.kind, requestId: request.requestId ?? null,
                          status: response.status, responseKind: payload?.kind ?? null,
                          responseCode: payload?.failureCode ?? payload?.code ?? payload?.error?.code ?? null,
                          resultStatus: payload?.outcome ?? payload?.status ?? null,
                          result: payload?.result ?? payload?.value ?? null,
                          operationId: payload?.operationId ?? request.operationId ?? null,
                          ...correlation});
                        if (request.kind === 'operation.resultAcknowledgement') operations.delete(request.operationId);
                        if (request.kind === 'subscription.cancel') subscriptions.delete(request.subscriptionId);
                      }
                      return result;
                    };
                  }
                });
              };
              return response;
            };
          }
          const OriginalBlob = window.Blob;
          window.Blob = new Proxy(OriginalBlob, {
            construct(target, arguments_) {
              const [parts, options] = arguments_;
              if (options?.type?.includes('javascript'))
                forward({kind: 'workerSourceProbe', parts: parts?.length ?? null, matched: parts?.some(part => typeof part === 'string' && part.includes('metadataStream.open')) ?? false});
              if (Array.isArray(parts) && parts.some(part =>
                  typeof part === 'string' && part.includes('metadataStream.open'))) {
                const prefix = '(' + installWorkerCommandObservation.toString() + ')();\n';
                return Reflect.construct(target, [[prefix, ...parts], options]);
              }
              return Reflect.construct(target, arguments_);
            }
          });
          const OriginalWorker = window.Worker;
          window.Worker = new Proxy(OriginalWorker, {
            construct(target, arguments_) {
              const worker = Reflect.construct(target, arguments_);
              forward({kind: 'workerConstructed', urlScheme: String(arguments_[0]).split(':')[0]});
              worker.addEventListener('message', event => {
                const message = event.data?.message;
                if (event.data?.kind === 'health' && typeof message === 'string' &&
                    message.startsWith('packaged-subscription:')) {
                  forward(JSON.parse(message.slice('packaged-subscription:'.length)));
                }
              });
              return worker;
            }
          });
        })();
        """#
}

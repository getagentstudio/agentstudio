import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

/// Event-driven waits for the WebKit lane.
///
/// Every one of these replaces a `ContinuousClock` deadline poll. Named waits
/// appear in the runner's HeldStep ledger if its process hang bound fires.
enum WebPageEventWaits {
    /// Suspends until the page stops loading.
    ///
    /// `WebPage` is `@Observable`, so this parks on the page's own change
    /// notification instead of sampling. The loop re-registers because
    /// `onChange` fires on willSet and is one-shot; it suspends every pass rather
    /// than spinning.
    @MainActor
    @discardableResult
    static func waitForNavigationToFinish(_ page: WebPage) async -> Bool {
        await waitForPageChange(on: page, reader: { !page.isLoading }, until: { $0 })
    }

    /// Suspends until the page reports the expected title.
    @MainActor
    @discardableResult
    static func waitForTitle(_ page: WebPage, equals expectedTitle: String) async -> String {
        await waitForPageChange(on: page, reader: { page.title }, until: { $0 == expectedTitle })
    }

    @MainActor
    static func waitForTitle(_ page: WebPage, beginningWith prefix: String) async -> String {
        await waitForPageChange(on: page, reader: { page.title }, until: { $0.hasPrefix(prefix) })
    }

    /// Suspends until a JavaScript reader returns a value, and answers with it.
    ///
    /// `readerBody` is a JavaScript function body that returns the value once its
    /// condition holds and `null` (or `undefined`) while it does not. It runs once
    /// up front and then again from a `MutationObserver` on
    /// `document.documentElement` watching `childList`, `subtree`, `attributes` and
    /// `characterData` — every channel through which the Bridge app publishes
    /// test-visible state. The same observer closes on the qualified failed-start
    /// pane summary, before accepting any stale ready value. Observer callbacks are microtasks fired by the mutation
    /// itself: they are NOT throttled by page visibility or requestAnimationFrame,
    /// which is what makes this sound on the hidden headless page the lane runs,
    /// where no animation frames are scheduled at all.
    ///
    /// It answers with whatever the reader sees at the moment a mutation is
    /// delivered, so a value that appears and is replaced inside one mutation batch
    /// can be missed. Every caller here waits for a settled end state, not a
    /// transient. Reader errors reject the promise after removing the registry
    /// entry and disconnecting its observer, including errors after a mutation.
    @MainActor
    static func waitForDocumentValue(
        _ page: WebPage,
        reader readerBody: String,
        arguments: [String: Any] = [:],
        milestone: String? = nil,
        lastObservation diagnosticBody: String = "return null;",
        closingSource: WebPageDocumentWaitClosingSource? = nil
    ) async throws -> Any? {
        let name = milestone ?? "document value"
        if let failure = closingSource?.firstClosure {
            throw failure.named(name, bootstrapDiagnostics: closingSource?.bootstrapDiagnostics)
        }
        let pendingName = await namedPageMilestone(
            page, milestone: milestone, diagnosticBody: diagnosticBody, arguments: arguments,
            bootstrapDiagnostics: closingSource?.bootstrapDiagnostics)
        if let failure = closingSource?.firstClosure {
            throw failure.named(name, bootstrapDiagnostics: closingSource?.bootstrapDiagnostics)
        }
        let (events, signal) = AsyncStream.makeStream(
            of: WebPageDocumentWaitWake.self, bufferingPolicy: .unbounded)
        let observationId = closingSource?.observe { signal.yield($0) }
        defer {
            if let observationId { closingSource?.removeObservation(observationId) }
            signal.finish()
        }
        let pending = WebPagePendingDocumentWait(
            page: page, reader: readerBody, arguments: arguments,
            onCompleted: { signal.yield(.documentCompleted) })
        let eventWait = Task { @MainActor in
            var iterator = events.makeAsyncIterator()
            while true {
                let diagnostics = closingSource.map { "; " + $0.bootstrapDiagnostics } ?? ""
                let wake =
                    (try? await awaitBridgeWebKitMilestone(
                        "GO26 document value pane=\(closingSource?.pane ?? "page") milestone=\(pendingName ?? name) token=\(pending.token)\(diagnostics)"
                    ) {
                        await iterator.next() ?? .cancelled
                    }) ?? .cancelled
                // A diagnostic event only refreshes the named wait; it cannot
                // settle the document or duplicate the page's replacement budget.
                if case .diagnosticsUpdated = wake { continue }
                return wake
            }
        }
        let wake = await withTaskCancellationHandler {
            await eventWait.value
        } onCancel: {
            signal.yield(.cancelled)
        }
        // An unstructured CLEANUP task is joined; it does not inherit the
        // caller's cancellation, which must not skip the abort acknowledgement.
        let completion = WebPageDocumentWaitCompletion()
        let cleanup = Task { @MainActor in
            do {
                switch wake {
                case .documentCompleted:
                    let envelope = try await pending.join()
                    if case .failedStart = envelope {
                        let closure = WebPageDocumentWaitClosure(
                            scope: .init(pane: closingSource?.pane ?? "page", requestId: nil), reason: .failedStart)
                        throw closure.named(name, bootstrapDiagnostics: closingSource?.bootstrapDiagnostics)
                    }
                    completion.result = .success(try envelope.value())
                case .closed(let closure):
                    completion.result = .success(
                        try await settleClosedDocumentWait(
                            pending, closure: closure, milestone: name, stepName: pendingName,
                            bootstrapDiagnostics: closingSource?.bootstrapDiagnostics))
                case .diagnosticsUpdated:
                    preconditionFailure("GO26 diagnostic event cannot settle a document wait")
                case .cancelled:
                    let closure = WebPageDocumentWaitClosure(
                        scope: .init(pane: closingSource?.pane ?? "page", requestId: nil), reason: .cancelled)
                    completion.result = .success(
                        try await settleClosedDocumentWait(
                            pending, closure: closure, milestone: name, stepName: pendingName,
                            bootstrapDiagnostics: closingSource?.bootstrapDiagnostics))
                }
            } catch {
                completion.result = .failure(error)
            }
        }
        // Any? is kept on MainActor rather than crossing Task's Sendable result.
        await cleanup.value
        return try #require(completion.result).get()
    }

    @MainActor
    static func settleClosedDocumentWait(
        _ pending: WebPagePendingDocumentWait,
        closure: WebPageDocumentWaitClosure,
        milestone: String,
        stepName: String? = nil,
        bootstrapDiagnostics: String? = nil
    ) async throws -> Any? {
        let failure = closure.named(milestone, bootstrapDiagnostics: bootstrapDiagnostics)
        let name = (stepName ?? milestone) + (bootstrapDiagnostics.map { "; " + $0 } ?? "")
        if closure.reason.requiresPageAbort && pending.result == nil {
            do {
                try await awaitBridgeWebKitMilestone(
                    "GO26 abort acknowledgement pane=\(closure.scope.pane) milestone=\(name) token=\(pending.token)"
                ) {
                    try await pending.abort(reason: failure.description)
                }
            } catch {
                // A rejected abort must still join the original physical call.
                _ = try? await awaitBridgeWebKitMilestone(
                    "GO26 original document call join after rejected abort pane=\(closure.scope.pane) milestone=\(name) token=\(pending.token)"
                ) { try await pending.join() }
                throw failure
            }
        }
        let original = try? await awaitBridgeWebKitMilestone(
            "GO26 original document call join pane=\(closure.scope.pane) milestone=\(name) token=\(pending.token)"
        ) { try await pending.join() }
        if closure.reason.requiresPageAbort, pending.didAbort, original?.wasAborted != true {
            // Success/error may have removed its entry before the abort arrived.
            // Delete that early-abort tombstone only AFTER the original is joined.
            do {
                try await awaitBridgeWebKitMilestone(
                    "GO26 abort acknowledgement cleanup pane=\(closure.scope.pane) milestone=\(name) token=\(pending.token)"
                ) { try await pending.removeEarlyAbort() }
            } catch { throw failure }
        }
        throw failure
    }

    /// Observes the document and every open shadow root. Pierre places File
    /// rows inside open roots, whose mutations do not reach a document observer.
    @MainActor
    static func waitForOpenShadowRootValue(
        _ page: WebPage,
        reader readerBody: String,
        arguments: [String: Any] = [:],
        milestone: String? = nil,
        lastObservation diagnosticBody: String = "return null;"
    ) async throws -> Any? {
        let pendingName = await namedPageMilestone(
            page, milestone: milestone, diagnosticBody: diagnosticBody, arguments: arguments
        )
        let observe: @MainActor () async throws -> Any? = {
            try await page.callJavaScript(
                """
                const findInOpenShadowRoots = (root, selector) => {
                  const direct = root.querySelector(selector);
                  if (direct !== null) return direct;
                  for (const element of root.querySelectorAll('*')) {
                    if (element.shadowRoot === null) continue;
                    const nested = findInOpenShadowRoots(element.shadowRoot, selector);
                    if (nested !== null) return nested;
                  }
                  return null;
                };
                const readOpenShadowRootText = root => {
                  let text = root.textContent ?? '';
                  for (const element of root.querySelectorAll('*')) {
                    if (element.shadowRoot !== null) text += readOpenShadowRootText(element.shadowRoot);
                  }
                  return text;
                };
                const readValue = () => { \(readerBody) };
                return await new Promise(resolve => {
                  const observers = new Map();
                  const observeRoot = root => {
                    if (!observers.has(root)) {
                      const observer = new MutationObserver(attempt);
                      observer.observe(root, {
                        attributes: true, characterData: true, childList: true, subtree: true
                      });
                      observers.set(root, observer);
                    }
                    for (const element of root.querySelectorAll('*')) {
                      if (element.shadowRoot !== null) observeRoot(element.shadowRoot);
                    }
                  };
                  const attempt = () => {
                    observeRoot(document.documentElement);
                    const value = readValue();
                    if (value === null || value === undefined) return;
                    for (const observer of observers.values()) observer.disconnect();
                    resolve(value);
                  };
                  attempt();
                });
                """,
                arguments: arguments
            )
        }
        if let pendingName {
            return try await awaitBridgeWebKitMilestone(pendingName, operation: observe)
        }
        return try await observe()
    }

    /// Suspends until `document.querySelector(selector)` is non-null.
    @MainActor
    @discardableResult
    static func waitForDocumentSelector(
        _ page: WebPage, _ selector: String,
        closingSource: WebPageDocumentWaitClosingSource? = nil, milestone: String? = nil
    ) async throws -> Bool {
        let observed = try await waitForDocumentValue(
            page,
            reader: "return document.querySelector(selector) === null ? null : true;",
            arguments: ["selector": selector], milestone: milestone, closingSource: closingSource
        )
        return try #require(observed as? Bool, "GO26 selector wait did not return its matched observation")
    }

    /// Suspends until the controller's bridge handshake has completed.
    ///
    /// `isBridgeReady` is a stored property of an `@Observable` type, so the
    /// transition is observable and needs no production seam.
    @MainActor
    @discardableResult
    static func waitForBridgeReady(_ controller: BridgePaneController) async -> Bool {
        while true {
            let observed = controller.isBridgeReady
            if observed { return observed }
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = controller.isBridgeReady
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    private static func namedPageMilestone(
        _ page: WebPage,
        milestone: String?,
        diagnosticBody: String,
        arguments: [String: Any],
        bootstrapDiagnostics: String? = nil
    ) async -> String? {
        guard let milestone else { return nil }
        let diagnosticName = milestone + (bootstrapDiagnostics.map { "; " + $0 } ?? "")
        let readbackTask = Task { @MainActor in
            (try? await awaitBridgeWebKitMilestone("GO26 last observation milestone=\(diagnosticName)") {
                let value = try await page.callJavaScript(diagnosticBody, arguments: arguments)
                return value.map { String(describing: $0) } ?? "unavailable"
            }) ?? "unavailable"
        }
        let readback = await readbackTask.value
        return "\(milestone); last=\(readback)"
    }

    /// Parks on the page's own observation until `condition` holds.
    @MainActor
    private static func waitForPageChange<ObservedValue>(
        on page: WebPage,
        reader: @escaping () -> ObservedValue,
        until matches: @escaping (ObservedValue) -> Bool
    ) async -> ObservedValue {
        while true {
            let observed = reader()
            if matches(observed) { return observed }
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = page.isLoading
                    _ = page.title
                    _ = page.url
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}

/// The element `hasReviewShell` is computed from
/// (`BridgePaneController+IPCProjection.swift:449`). The wait and the assertion
/// must read the same element or the wait proves nothing about the assertion.
let bridgeReviewShellSelector = "[data-testid=\"review-viewer-shell\"]"

@MainActor
private final class WebPageDocumentWaitCompletion {
    var result: Result<Any?, any Error>?
}

enum WebPageDocumentWaitEnvelope {
    case value(Any?)
    case failedStart
    case aborted(token: String, reason: String)

    var wasAborted: Bool {
        if case .aborted = self { return true }
        return false
    }

    func value() throws -> Any? {
        switch self {
        case .value(let value): return value
        case .failedStart:
            throw WebPageDocumentWaitProtocolFailure(detail: "terminal reason=failedStart")
        case .aborted(let token, let reason):
            throw WebPageDocumentWaitProtocolFailure(detail: "aborted token=\(token) reason=\(reason)")
        }
    }
}

struct WebPageDocumentWaitProtocolFailure: Error, CustomStringConvertible {
    let detail: String
    var description: String { "GO26 document wait protocol: \(detail)" }
}

/// One physical call. Only join() observes completion; cancellation never detaches it.
@MainActor
final class WebPagePendingDocumentWait {
    let token: String
    let page: WebPage
    let contentWorld: WKContentWorld
    private(set) var result: Result<WebPageDocumentWaitEnvelope, any Error>?
    private(set) var didAbort = false
    private var operation: Task<Void, Never>?

    init(
        page: WebPage, token: String = UUIDv7.generate().uuidString,
        reader: String, arguments: [String: Any] = [:],
        onCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.page = page
        self.token = token
        contentWorld = .page
        var callArguments = arguments
        callArguments["__go26WaitToken"] = token
        let pageArguments = callArguments
        operation = Task { @MainActor in
            do {
                let raw = try await page.callJavaScript(
                    Self.script(reader: reader), arguments: pageArguments,
                    contentWorld: contentWorld)
                let envelope = try #require(raw as? [String: Any], "GO26 missing tagged document result")
                try #require(envelope["token"] as? String == token, "GO26 document token mismatch")
                switch envelope["kind"] as? String {
                case "value": result = .success(.value(envelope["value"]))
                case "terminal":
                    try #require(envelope["reason"] as? String == "failedStart", "GO26 unknown terminal reason")
                    result = .success(.failedStart)
                case "aborted":
                    result = .success(.aborted(token: token, reason: try #require(envelope["reason"] as? String)))
                default: throw WebPageDocumentWaitProtocolFailure(detail: "unknown envelope kind")
                }
            } catch {
                result = .failure(error)
            }
            onCompleted()
        }
    }

    func join() async throws -> WebPageDocumentWaitEnvelope {
        await operation?.value
        operation = nil
        return try #require(result, "GO26 physical document call settled without a result").get()
    }

    func abort(reason: String) async throws {
        let acknowledged = try await Self.abort(page: page, token: token, reason: reason, contentWorld: contentWorld)
        try #require(acknowledged, "GO26 abort token was not acknowledged")
        didAbort = true
    }

    func removeEarlyAbort() async throws {
        _ = try await page.callJavaScript(
            "globalThis.__agentstudioTestDocumentWaits?.delete(token); return true;",
            arguments: ["token": token], contentWorld: contentWorld)
    }

    static func abort(page: WebPage, token: String, reason: String, contentWorld: WKContentWorld = .page) async throws
        -> Bool
    {
        (try await page.callJavaScript(
            """
            const registry = globalThis.__agentstudioTestDocumentWaits ??= new Map();
            const entry = registry.get(token);
            if (entry?.kind === 'pending') entry.abort(reason);
            else if (entry === undefined) registry.set(token, {kind: 'pre-aborted', reason});
            return true;
            """, arguments: ["token": token, "reason": reason], contentWorld: contentWorld)) as? Bool == true
    }

    static func script(reader: String) -> String {
        """
        const token = __go26WaitToken;
        const registry = globalThis.__agentstudioTestDocumentWaits ??= new Map();
        const readDocumentValue = () => { \(reader) };
        return await new Promise((resolve, reject) => {
          let observer = null;
          let settled = false;
          const cleanup = () => { observer?.disconnect(); registry.delete(token); };
          const finish = envelope => {
            if (settled) return;
            settled = true; cleanup(); resolve({...envelope, token});
          };
          const earlierAbort = registry.get(token);
          const entry = {kind: 'pending', observer: null, abort: reason => finish({kind: 'aborted', reason})};
          registry.set(token, entry);
          if (earlierAbort?.kind === 'pre-aborted') {
            finish({kind: 'aborted', reason: earlierAbort.reason}); return;
          }
          const attempt = () => {
            if (settled) return true;
            try {
              // The shared summary also renders recoverable viewer failures.
              // Qualify the pane-wide failed-start title before accepting stale ready DOM.
              const failures = document.querySelectorAll(
                '[data-testid="bridge-pane-failure-summary"][data-bridge-region="pane-failure"][data-presentation-state="failed"]'
              );
              for (const failure of failures) {
                if (failure.querySelector('[data-slot="alert-title"]')?.textContent?.trim() === "Bridge couldn't start.") {
                  finish({kind: 'terminal', reason: 'failedStart'}); return true;
                }
              }
              const value = readDocumentValue();
              if (value === null || value === undefined) return false;
              finish({kind: 'value', value}); return true;
            } catch (error) {
              settled = true; cleanup(); reject(error); return true;
            }
          };
          try {
            if (attempt()) return;
            observer = new MutationObserver(attempt);
            entry.observer = observer;
            observer.observe(document.documentElement, {
              attributes: true, characterData: true, childList: true, subtree: true
            });
          } catch (error) { settled = true; cleanup(); reject(error); }
        });
        """
    }
}

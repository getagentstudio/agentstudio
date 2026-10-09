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
    static func waitForNavigationToFinish(_ page: WebPage) async {
        await waitForPageChange(on: page) { !page.isLoading }
    }

    /// Suspends until the page reports the expected title.
    @MainActor
    static func waitForTitle(_ page: WebPage, equals expectedTitle: String) async {
        await waitForPageChange(on: page) { page.title == expectedTitle }
    }

    @MainActor
    static func waitForTitle(_ page: WebPage, beginningWith prefix: String) async -> String {
        await waitForPageChange(on: page) { page.title.hasPrefix(prefix) }
        return page.title
    }

    /// Suspends until a JavaScript reader returns a value, and answers with it.
    ///
    /// `readerBody` is a JavaScript function body that returns the value once its
    /// condition holds and `null` (or `undefined`) while it does not. It runs once
    /// up front and then again from a `MutationObserver` on
    /// `document.documentElement` watching `childList`, `subtree`, `attributes` and
    /// `characterData` — every channel through which the Bridge app publishes
    /// test-visible state. Observer callbacks are microtasks fired by the mutation
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
            throw failure.named(name)
        }
        let (events, signal) = AsyncStream.makeStream(
            of: WebPageDocumentWaitWake.self, bufferingPolicy: .bufferingOldest(1))
        let observationId = closingSource?.observe { closure in signal.yield(.closed(closure)) }
        defer {
            if let observationId { closingSource?.removeObservation(observationId) }
            signal.finish()
        }
        let pending = WebPagePendingDocumentWait(
            page: page, reader: readerBody, arguments: arguments,
            diagnostic: diagnosticBody, onCompleted: { signal.yield(.documentCompleted) })
        let eventWait = Task { @MainActor in
            (try? await awaitBridgeWebKitMilestone(
                "GO26 document value pane=\(closingSource?.pane ?? "page") milestone=\(name) token=\(pending.token)"
            ) {
                var iterator = events.makeAsyncIterator()
                return await iterator.next() ?? .cancelled
            }) ?? .cancelled
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
                    completion.result = .success(try await pending.join().value())
                case .closed(let closure):
                    completion.result = .success(
                        try await settleClosedDocumentWait(pending, closure: closure, milestone: name))
                case .cancelled:
                    let closure = WebPageDocumentWaitClosure(
                        scope: .init(pane: closingSource?.pane ?? "page", requestId: nil), reason: .cancelled)
                    completion.result = .success(
                        try await settleClosedDocumentWait(pending, closure: closure, milestone: name))
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
        milestone: String
    ) async throws -> Any? {
        let failure = closure.named(milestone)
        if closure.reason.requiresPageAbort && pending.result == nil {
            do {
                try await awaitBridgeWebKitMilestone(
                    "GO26 abort acknowledgement pane=\(closure.scope.pane) milestone=\(milestone) token=\(pending.token)"
                ) {
                    try await pending.abort(reason: failure.description)
                }
            } catch {
                // A rejected abort must still join the original physical call.
                _ = try? await awaitBridgeWebKitMilestone(
                    "GO26 original document call join after rejected abort pane=\(closure.scope.pane) milestone=\(milestone) token=\(pending.token)"
                ) { try await pending.join() }
                throw failure
            }
        }
        let original = try? await awaitBridgeWebKitMilestone(
            "GO26 original document call join pane=\(closure.scope.pane) milestone=\(milestone) token=\(pending.token)"
        ) { try await pending.join() }
        if closure.reason.requiresPageAbort, pending.didAbort, original?.wasAborted != true {
            // Success/error may have removed its entry before the abort arrived.
            // Delete that early-abort tombstone only AFTER the original is joined.
            do {
                try await awaitBridgeWebKitMilestone(
                    "GO26 abort acknowledgement cleanup pane=\(closure.scope.pane) milestone=\(milestone) token=\(pending.token)"
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
    static func waitForDocumentSelector(
        _ page: WebPage, _ selector: String,
        closingSource: WebPageDocumentWaitClosingSource? = nil, milestone: String? = nil
    ) async throws {
        _ = try await waitForDocumentValue(
            page,
            reader: "return document.querySelector(selector) === null ? null : true;",
            arguments: ["selector": selector], milestone: milestone, closingSource: closingSource
        )
    }

    /// Suspends until the controller's bridge handshake has completed.
    ///
    /// `isBridgeReady` is a stored property of an `@Observable` type, so the
    /// transition is observable and needs no production seam.
    @MainActor
    static func waitForBridgeReady(_ controller: BridgePaneController) async {
        while !controller.isBridgeReady {
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
        arguments: [String: Any]
    ) async -> String? {
        guard let milestone else { return nil }
        let readback =
            (try? await page.callJavaScript(diagnosticBody, arguments: arguments))
            .map { String(describing: $0) } ?? "unavailable"
        return "\(milestone); last=\(readback)"
    }

    /// Parks on the page's own observation until `condition` holds.
    @MainActor
    private static func waitForPageChange(
        on page: WebPage,
        until condition: @escaping () -> Bool
    ) async {
        while !condition() {
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

struct WebPageDocumentWaitScope: Hashable, Sendable {
    let pane: String
    let requestId: String?
}

enum WebPageDocumentWaitCloseReason: Sendable {
    case bootstrap(BridgeProductSessionBootstrapFailureReason)
    case pageClosed
    case webContentProcessTerminated
    case navigationFailed(String)
    case navigationEnded
    case cancelled

    var description: String {
        switch self {
        case .bootstrap(let reason): "bootstrap \(reason.rawValue)"
        case .pageClosed: "pageClosed"
        case .webContentProcessTerminated: "webContentProcessTerminated"
        case .navigationFailed(let error): "navigation failed: \(error)"
        case .navigationEnded: "navigation stream ended"
        case .cancelled: "wait cancelled"
        }
    }

    var requiresPageAbort: Bool {
        if case .webContentProcessTerminated = self { return false }
        return true
    }
}

struct WebPageDocumentWaitClosure: Sendable {
    let scope: WebPageDocumentWaitScope
    let reason: WebPageDocumentWaitCloseReason

    func named(_ milestone: String) -> WebPageDocumentWaitOwnerFailure {
        WebPageDocumentWaitOwnerFailure(closure: self, milestone: milestone)
    }
}

struct WebPageDocumentWaitOwnerFailure: Error, Sendable, CustomStringConvertible {
    let closure: WebPageDocumentWaitClosure
    let milestone: String

    var description: String {
        "GO26 pane=\(closure.scope.pane) milestone=\(milestone) requestId=\(closure.scope.requestId ?? "none") reason=\(closure.reason.description)"
    }
}

/// Adapts existing owner announcements into one sticky, typed pane/request fact.
@MainActor
final class WebPageDocumentWaitClosingSource {
    let pane: String
    private(set) var firstClosure: WebPageDocumentWaitClosure?
    private let source: LocalFactSource<WebPageDocumentWaitScope, WebPageDocumentWaitCloseReason>
    let recorder: FactRecorder<WebPageDocumentWaitScope, WebPageDocumentWaitCloseReason>
    private var observers: [UUID: @MainActor (WebPageDocumentWaitClosure) -> Void] = [:]
    private var navigationTask: Task<Void, Never>?

    init(pane: String) throws {
        self.pane = pane
        source = LocalFactSource(
            vocabulary: .init(
                describeScope: { "pane=\($0.pane) requestId=\($0.requestId ?? "none")" },
                describeFact: { $0.description }, isClosing: { _, _ in true }))
        recorder = try source.attach()
    }

    func record(_ reason: WebPageDocumentWaitCloseReason, requestId: String? = nil) {
        guard firstClosure == nil else { return }
        let closure = WebPageDocumentWaitClosure(scope: .init(pane: pane, requestId: requestId), reason: reason)
        firstClosure = closure
        source.sink(closure.scope, closure.reason)
        for observer in observers.values { observer(closure) }
    }

    func observe(_ observer: @escaping @MainActor (WebPageDocumentWaitClosure) -> Void) -> UUID {
        let observationId = UUIDv7.generate()
        observers[observationId] = observer
        if let firstClosure { observer(firstClosure) }
        return observationId
    }

    func removeObservation(_ observationId: UUID) { observers.removeValue(forKey: observationId) }

    func observePage(_ page: WebPage) {
        precondition(navigationTask == nil)
        // Property access attaches the indefinite sequence synchronously, before loadApp.
        let navigations = page.navigations
        navigationTask = Task { @MainActor in
            do {
                for try await _ in navigations {}
                if !Task.isCancelled { record(.navigationEnded) }
            } catch {
                guard !Task.isCancelled else { return }
                switch error as? WebPage.NavigationError {
                case .some(.webContentProcessTerminated): record(.webContentProcessTerminated)
                case .some(.pageClosed): record(.pageClosed)
                default: record(.navigationFailed(String(describing: error)))
                }
            }
        }
    }

    func requireMountedApp(_ controller: BridgePaneController) async throws {
        await WebPageEventWaits.waitForNavigationToFinish(controller.page)
        try await WebPageEventWaits.waitForDocumentSelector(
            controller.page,
            "[data-testid=\"bridge-app-root\"]", closingSource: self, milestone: "bundled app mounted"
        )
        await WebPageEventWaits.waitForBridgeReady(controller)
        guard let installation = await controller.productSessionOwner.activeInstallation,
            await installation.session.waitUntilActive()
        else {
            throw BridgeProductWebKitTwoPaneJourneyTestSupport.JourneyError.conditionFailed(
                "bundled app native session did not activate")
        }
        let native = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(controller)
        guard native.lifecycle == "active" else {
            throw BridgeProductWebKitTwoPaneJourneyTestSupport.JourneyError.conditionFailed(
                "bundled app native session was not active")
        }
    }

    func activateReadyFileMode(
        _ controller: BridgePaneController,
        failure: String
    ) async throws {
        guard await BridgeProductWebKitCarrierTestSupport.activateFileMode(controller.page) else {
            throw BridgeProductWebKitTwoPaneJourneyTestSupport.JourneyError.conditionFailed(failure)
        }
        _ = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: """
                const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
                const count = Number(shell?.getAttribute('data-file-display-item-count') ?? '0');
                return shell?.getAttribute('data-file-display-status') === 'ready'
                  && count > 0 ? count : null;
                """, milestone: "File display ready with nonempty items", closingSource: self
        )
    }

    func finish() async throws {
        navigationTask?.cancel()
        await navigationTask?.value
        navigationTask = nil
        observers.removeAll()
        source.end()
        try await recorder.finish()
    }
}

private enum WebPageDocumentWaitWake: Sendable {
    case documentCompleted
    case closed(WebPageDocumentWaitClosure)
    case cancelled
}

@MainActor
private final class WebPageDocumentWaitCompletion {
    var result: Result<Any?, any Error>?
}

enum WebPageDocumentWaitEnvelope {
    case value(Any?)
    case aborted(token: String, reason: String)

    var wasAborted: Bool {
        if case .aborted = self { return true }
        return false
    }

    func value() throws -> Any? {
        switch self {
        case .value(let value): return value
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
        reader: String, arguments: [String: Any] = [:], diagnostic: String = "return null;",
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
                    Self.script(reader: reader, diagnostic: diagnostic), arguments: pageArguments,
                    contentWorld: contentWorld)
                let envelope = try #require(raw as? [String: Any], "GO26 missing tagged document result")
                try #require(envelope["token"] as? String == token, "GO26 document token mismatch")
                switch envelope["kind"] as? String {
                case "value": result = .success(.value(envelope["value"]))
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

    static func script(reader: String, diagnostic: String) -> String {
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
              const value = readDocumentValue();
              if (value === null || value === undefined) return false;
              finish({kind: 'value', value}); return true;
            } catch (error) {
              settled = true; cleanup(); reject(error); return true;
            }
          };
          try {
            // Diagnostic readers remain best effort, as in namedPageMilestone.
            try { (() => { \(diagnostic) })(); } catch (_) {}
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

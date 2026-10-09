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
    /// transient. A throw from the first evaluation propagates; a throw from a later
    /// one would be swallowed by the observer, so readers must be null-safe.
    @MainActor
    static func waitForDocumentValue(
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
                const readDocumentValue = () => { \(readerBody) };
                return await new Promise((resolve) => {
                  let observer = null;
                  const attempt = () => {
                    const value = readDocumentValue();
                    if (value === null || value === undefined) { return false; }
                    observer?.disconnect();
                    resolve(value);
                    return true;
                  };
                  if (attempt()) { return; }
                  observer = new MutationObserver(attempt);
                  observer.observe(document.documentElement, {
                    attributes: true,
                    characterData: true,
                    childList: true,
                    subtree: true
                  });
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
    static func waitForDocumentSelector(_ page: WebPage, _ selector: String) async throws {
        _ = try await waitForDocumentValue(
            page,
            reader: "return document.querySelector(selector) === null ? null : true;",
            arguments: ["selector": selector]
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

import AgentStudioTestSupport
import Foundation
import WebKit

@testable import AgentStudioBridge

extension BridgeProductWebKitTwoPaneJourneyTestSupport {
    /// Arms the W6 region observation before File catch-up can publish Updating.
    /// U13 renders the shared region indicator rather than the legacy status copy.
    ///
    /// A deadline here would be a verdict about machine speed on a page that
    /// renders no frames.
    static func armFileTreeUpdatingObservation(_ page: WebPage) async throws {
        _ = try await page.callJavaScript(
            """
            window.__bridgeTwoPaneStatusObservation = new Promise(resolve => {
              const capture = () => {
                const encodedSnapshot = (() => { \(positionSnapshotReaderBody) })();
                const snapshot = JSON.parse(encodedSnapshot);
                if (snapshot.activeMode !== 'file') return false;
                if (snapshot.fileTreePresentationState !== 'updating' || snapshot.reviewStatusText !== null) return false;
                resolve(encodedSnapshot);
                return true;
              };
              if (capture()) return;
              const observer = new MutationObserver(() => {
                if (capture()) observer.disconnect();
              });
              observer.observe(document.documentElement, {
                attributes: true,
                characterData: true,
                childList: true,
                subtree: true
              });
            });
            return true;
            """
        )
    }

    static func requireArmedStatus(_ page: WebPage) async throws
        -> BridgeProductWebKitTwoPanePositionSnapshot
    {
        do {
            let encoded = try await awaitBridgeWebKitMilestone("FiletreeUpdating") {
                try await page.callJavaScript("return await window.__bridgeTwoPaneStatusObservation;")
            }
            guard let encoded = encoded as? String,
                let data = encoded.data(using: .utf8)
            else {
                throw JourneyError.conditionFailed(
                    "matching active-surface status did not return its position snapshot"
                )
            }
            return try JSONDecoder().decode(
                BridgeProductWebKitTwoPanePositionSnapshot.self,
                from: data
            )
        } catch {
            throw JourneyError.conditionFailed(
                "armed active-surface updating chrome could not be read: \(error)"
            )
        }
    }

    /// Asserts, with one read, that neither surface is showing updating chrome.
    ///
    /// Every caller reaches this only after the owner's own barrier has been awaited
    /// (`requireHiddenFileRetirementBoundary`, `requireBlockedComparison`). This is a
    /// NEGATIVE claim, so it is read once: polling until the chrome disappears would
    /// accept a pane that showed "Updating…" it was never supposed to show.
    static func requireNoUpdatingStatus(
        _ page: WebPage
    ) async throws -> BridgeProductWebKitTwoPanePositionSnapshot {
        let observed = try await requirePositionSnapshot(page)
        guard observed.fileStatusText == nil, observed.reviewStatusText == nil else {
            let observedFileStatusText = observed.fileStatusText ?? "nil"
            let observedReviewStatusText = observed.reviewStatusText ?? "nil"
            throw JourneyError.conditionFailed(
                "loaded-hidden pane retained updating chrome "
                    + "(fileStatusText: \(observedFileStatusText), "
                    + "reviewStatusText: \(observedReviewStatusText))"
            )
        }
        return observed
    }

    static func requirePositionSnapshot(
        _ page: WebPage
    ) async throws -> BridgeProductWebKitTwoPanePositionSnapshot {
        guard let snapshot = try await positionSnapshot(page) else {
            throw JourneyError.conditionFailed("WebKit position snapshot was unavailable")
        }
        return snapshot
    }

    static func positionSnapshot(
        _ page: WebPage
    ) async throws -> BridgeProductWebKitTwoPanePositionSnapshot? {
        let encoded = try await page.callJavaScript(
            "return (() => { \(positionSnapshotReaderBody) })();"
        )
        guard let encoded = encoded as? String,
            let data = encoded.data(using: .utf8)
        else { return nil }
        return try JSONDecoder().decode(BridgeProductWebKitTwoPanePositionSnapshot.self, from: data)
    }

    static let positionSnapshotReaderBody =
        """
        const queryOpen = (root, selector) => {
          const direct = root.querySelector(selector);
          if (direct !== null) return direct;
          for (const element of root.querySelectorAll('*')) {
            if (element.shadowRoot === null) continue;
            const nested = queryOpen(element.shadowRoot, selector);
            if (nested !== null) return nested;
          }
          return null;
        };
        const fileHost = document.querySelector('[data-testid="bridge-viewer-mode-host-file"]');
        const reviewHost = document.querySelector('[data-testid="bridge-viewer-mode-host-review"]');
        const fileShell = fileHost?.querySelector('[data-testid="bridge-file-viewer-shell"]');
        const fileCanvas = fileHost?.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
        const reviewShell = reviewHost?.querySelector('[data-testid="review-viewer-shell"]');
        const fileTreeScroll = fileHost === null ? null : queryOpen(fileHost, '[data-file-tree-virtualized-scroll="true"]');
        const reviewTreeScroll = reviewHost === null ? null : queryOpen(reviewHost, '[data-file-tree-virtualized-scroll="true"]');
        const fileCodeScroll = fileHost?.querySelector('.bridge-code-view-scroll-owner');
        const reviewCodeScroll = reviewHost?.querySelector('.bridge-code-view-scroll-owner');
        const collapsedDirectory = reviewHost === null
          ? null
          : queryOpen(reviewHost, '[data-item-path="Sources/Group00"][aria-expanded]');
        const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
        return JSON.stringify({
          activeMode: activeHost?.getAttribute('data-bridge-viewer-mode-host') ?? null,
          comparisonStatusText: reviewHost?.querySelector('[data-testid="bridge-review-comparison-status-banner"]')?.textContent ?? null,
          fileCodeScrollTop: fileCodeScroll?.scrollTop ?? 0,
          fileRenderedPath: fileCanvas?.getAttribute('data-worktree-rendered-file-path') ?? null,
          fileSelectedPath: fileShell?.getAttribute('data-selected-display-path') ?? null,
          fileStatusText: fileHost?.querySelector('[data-testid="bridge-viewer-content-status"]')?.textContent ?? null,
          fileTreePresentationState: fileHost?.querySelector('[data-bridge-region="file-tree"]')?.getAttribute('data-presentation-state') ?? null,
          fileTreeScrollTop: fileTreeScroll?.scrollTop ?? 0,
          hasAppRoot: document.querySelector('[data-testid="bridge-app-root"]') !== null,
          reviewCodeScrollTop: reviewCodeScroll?.scrollTop ?? 0,
          reviewCollapsedDirectoryExpansion: collapsedDirectory?.getAttribute('aria-expanded') ?? null,
          reviewSelectedItemId: reviewHost?.querySelector('[data-testid="bridge-code-view-panel"]')?.getAttribute('data-selected-item-id') ?? null,
          reviewSelectedPath: reviewShell?.getAttribute('data-selected-display-path') ?? null,
          reviewStatusText: reviewHost?.querySelector('[data-testid="bridge-viewer-content-status"]')?.textContent ?? null,
          reviewTreeScrollTop: reviewTreeScroll?.scrollTop ?? 0
        });
        """

}

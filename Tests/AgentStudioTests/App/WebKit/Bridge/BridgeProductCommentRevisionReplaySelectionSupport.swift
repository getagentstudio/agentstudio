import Foundation
import WebKit

@testable import AgentStudioTestSupport

enum CommentRevisionReplaySelectionError: Error {
    case rowSelectionRejected(path: String)
}

@MainActor
func selectAllCommentReplayShareScope(_ page: WebPage) async throws {
    _ = try await WebPageEventWaits.waitForDocumentValue(
        page,
        reader: """
            const share = Array.from(document.querySelectorAll('[data-testid="worktree-annotation-share-mode"]'))
              .find(candidate => candidate.getClientRects().length !== 0);
            const button = Array.from(share?.querySelectorAll('button') ?? []).find(
              candidate => candidate.getAttribute('aria-label')?.startsWith('All comments, ')
            );
            if (!(button instanceof HTMLButtonElement) || button.disabled) return null;
            button.click();
            return true;
            """,
        milestone: "All comments scope selected"
    )
}

@MainActor
func selectReviewItemPath(_ page: WebPage, path: String) async throws {
    _ = try await WebPageEventWaits.waitForOpenShadowRootValue(
        page,
        reader: """
            const findPathButton = root => {
              if (root === null) return null;
              const directMatch = Array.from(root.querySelectorAll('button[data-item-path]')).find(
                candidate => candidate.getAttribute('data-item-path') === path
              );
              if (directMatch !== undefined) return directMatch;
              for (const element of root.querySelectorAll('*')) {
                if (element.shadowRoot === null) continue;
                const nestedMatch = findPathButton(element.shadowRoot);
                if (nestedMatch !== null) return nestedMatch;
              }
              return null;
            };
            const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
            const treePanel = activeHost?.querySelector('[data-testid="bridge-review-trees-panel"]');
            return findPathButton(treePanel)?.getAttribute('data-item-path') ?? null;
            """,
        arguments: ["path": path],
        milestone: "Review item row mounted",
        lastObservation:
            "return document.querySelector('[data-testid=\"bridge-review-trees-panel\"]')?.textContent ?? 'missing';"
    )

    let didSelectPath =
        try await page.callJavaScript(
            """
            const findPathButton = root => {
              if (root === null) return null;
              const directMatch = Array.from(root.querySelectorAll('button[data-item-path]')).find(
                candidate => candidate.getAttribute('data-item-path') === path
              );
              if (directMatch !== undefined) return directMatch;
              for (const element of root.querySelectorAll('*')) {
                if (element.shadowRoot === null) continue;
                const nestedMatch = findPathButton(element.shadowRoot);
                if (nestedMatch !== null) return nestedMatch;
              }
              return null;
            };
            const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
            const treePanel = activeHost?.querySelector('[data-testid="bridge-review-trees-panel"]');
            const button = findPathButton(treePanel);
            if (!(button instanceof HTMLButtonElement)) return false;
            button.click();
            return true;
            """,
            arguments: ["path": path]
        ) as? Bool ?? false
    guard didSelectPath else {
        throw CommentRevisionReplaySelectionError.rowSelectionRejected(path: path)
    }

    _ = try await WebPageEventWaits.waitForDocumentValue(
        page,
        reader: """
            const activeHost = document.querySelector('[data-bridge-viewer-mode-active="true"]');
            const shell = activeHost?.querySelector('[data-testid="review-viewer-shell"]');
            const codePanel = activeHost?.querySelector('[data-testid="bridge-code-view-panel"]');
            return shell?.getAttribute('data-selected-display-path') === path
              && shell?.getAttribute('data-selected-content-state') === 'ready'
              && Boolean(codePanel?.getAttribute('data-selected-item-id')) ? path : null;
            """,
        arguments: ["path": path],
        milestone: "Review item selected content rendered",
        lastObservation:
            "return document.querySelector('[data-testid=\"review-viewer-shell\"]')?.getAttribute('data-selected-display-path') ?? 'missing';"
    )
}

// Serializable page-side observed-state wait. The harness hang bound closes
// the page if an owner never publishes; there is no per-state speed budget.
export type BridgeStartupDOMFact =
	| { readonly kind: 'file.shell' | 'file.source' | 'file.metadata' | 'file.selection' }
	| { readonly kind: 'file.content' | 'file.visibleContent'; readonly path: string }
	| { readonly kind: 'review.shell' | 'review.metadata' | 'review.content' | 'handshake' };

export function observeBridgeStartupDOMFact(fact: BridgeStartupDOMFact): Promise<void> {
	return new Promise<void>((resolve): void => {
		const observedRoots = new Set<Node>();
		const observer = new MutationObserver(checkFact);
		function observeRoot(root: Document | ShadowRoot): void {
			if (observedRoots.has(root)) return;
			observedRoots.add(root);
			observer.observe(root, {
				attributes: true,
				childList: true,
				characterData: true,
				subtree: true,
			});
		}
		function checkFact(): void {
			// Only the content milestone reads renderer shadow text. Other facts
			// observe attributes without traversing the tree being measured.
			observeRoot(document);
			const fileShell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
			const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
			const contentPanel = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
			if (fact.kind === 'file.visibleContent')
				for (const renderer of contentPanel?.querySelectorAll('diffs-container') ?? []) {
					if (renderer.shadowRoot !== null) observeRoot(renderer.shadowRoot);
				}
			let published = false;
			switch (fact.kind) {
				case 'handshake':
					published = Number.isFinite(window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds);
					break;
				case 'file.shell':
					published = shellIsVisible(fileShell);
					break;
				case 'review.shell':
					published = shellIsVisible(reviewShell);
					break;
				case 'file.source':
					published = (fileShell?.getAttribute('data-file-display-source-id') ?? '').length > 0;
					break;
				case 'file.metadata': {
					const count = Number(
						fileShell?.getAttribute('data-worktree-metadata-file-row-count') ?? '0',
					);
					published = Number.isInteger(count) && count > 0;
					break;
				}
				case 'file.selection':
					published = (fileShell?.getAttribute('data-selected-display-path') ?? '').length > 0;
					break;
				case 'review.metadata':
					published =
						Number(reviewShell?.getAttribute('data-review-metadata-item-count') ?? '0') > 0;
					break;
				case 'review.content':
					published =
						reviewShell?.getAttribute('data-selected-display-path') !== null &&
						reviewShell?.getAttribute('data-selected-content-state') === 'ready';
					break;
				case 'file.content':
				case 'file.visibleContent': {
					published =
						contentPanel instanceof HTMLElement &&
						contentPanel.getAttribute('data-worktree-open-file-path') === fact.path &&
						contentPanel.getAttribute('data-worktree-open-file-state') === 'ready';
					if (published && fact.kind === 'file.visibleContent') {
						const lineCount =
							window.bridgeWorktreeVerifier.getBridgeFileViewerRenderedCodeLineCount();
						const text = window.bridgeWorktreeVerifier.getBridgeFileViewerRenderedCodeText();
						const fallbackText =
							contentPanel?.querySelector(
								'[data-testid="bridge-file-viewer-first-window-fallback"]',
							)?.textContent ?? '';
						published = (lineCount > 0 && text.trim().length > 0) || fallbackText.trim().length > 0;
					}
					break;
				}
			}
			if (!published) return;
			observer.disconnect();
			document.removeEventListener('__bridge_ready_ack', checkFact);
			document.removeEventListener('load', checkFact, true);
			resolve();
		}
		function shellIsVisible(shell: Element | null): boolean {
			if (shell === null) return false;
			const rectangle = shell.getBoundingClientRect();
			return (
				rectangle.width > 0 &&
				rectangle.height > 0 &&
				getComputedStyle(shell).visibility !== 'hidden'
			);
		}
		document.addEventListener('__bridge_ready_ack', checkFact);
		document.addEventListener('load', checkFact, true);
		checkFact();
	});
}

// Serializable DOM observation: initial read, then only mutation notifications.
// The existing journey owner cancels by event or destroys the page context.
export function observeReviewPaintReceipt(props: {
	readonly itemId: string;
}): Promise<{ readonly publicationId: string }> {
	return new Promise((resolve, reject): void => {
		const observedRoots = new Set<Document | ShadowRoot>();
		let observing = false;
		let settled = false;
		const observer = new MutationObserver(checkReceipt);
		const cancel = (event: Event): void => {
			if (!(event instanceof CustomEvent) || event.detail !== props.itemId) return;
			cleanup();
			reject(new Error('Review paint observation cancelled by journey owner.'));
		};
		const pageClosed = (): void => {
			cleanup();
			reject(new Error('Review paint observation page closed.'));
		};
		function cleanup(): void {
			settled = true;
			observer.disconnect();
			window.removeEventListener('__bridge_review_paint_cancel', cancel);
			window.removeEventListener('pagehide', pageClosed);
		}
		function observeRoot(root: Document | ShadowRoot): void {
			if (!observing || observedRoots.has(root)) return;
			observedRoots.add(root);
			observer.observe(root, {
				attributes: true,
				attributeFilter: [
					'data-bridge-code-view-item-id',
					'data-bridge-painted-publication-id',
					'data-bridge-painted-source-correlations',
				],
				childList: true,
				subtree: true,
			});
		}
		function queryHosts(root: Document | ShadowRoot): Element[] {
			observeRoot(root);
			const hosts = [...root.querySelectorAll('diffs-container')];
			for (const descendant of root.querySelectorAll('*')) {
				if (descendant.shadowRoot !== null) hosts.push(...queryHosts(descendant.shadowRoot));
			}
			return hosts;
		}
		function checkReceipt(): void {
			if (settled) return;
			for (const host of queryHosts(document)) {
				const marker =
					host.querySelector('[data-bridge-code-view-item-id]') ??
					host.shadowRoot?.querySelector('[data-bridge-code-view-item-id]');
				if (marker?.getAttribute('data-bridge-code-view-item-id') !== props.itemId) continue;
				const publicationId = host.getAttribute('data-bridge-painted-publication-id');
				const correlations = host.getAttribute('data-bridge-painted-source-correlations');
				if (publicationId === null || publicationId.length === 0 || correlations === null) continue;
				try {
					const parsed: unknown = JSON.parse(correlations);
					if (
						Array.isArray(parsed) &&
						parsed.some(
							(correlation): boolean =>
								typeof correlation === 'object' &&
								correlation !== null &&
								Reflect.get(correlation, 'semanticItemId') === props.itemId &&
								Reflect.get(correlation, 'publicationId') === publicationId,
						)
					) {
						cleanup();
						resolve({ publicationId });
						return;
					}
				} catch {}
			}
		}
		checkReceipt();
		if (settled) return;
		observing = true;
		window.addEventListener('__bridge_review_paint_cancel', cancel);
		window.addEventListener('pagehide', pageClosed);
		checkReceipt();
	});
}

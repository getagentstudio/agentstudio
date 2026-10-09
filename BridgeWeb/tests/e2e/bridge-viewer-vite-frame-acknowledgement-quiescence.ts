import type { Frame, Page, Request } from 'playwright';

import { settleBrowserFrames } from './bridge-viewer-vite-annotation-catalog-performance.ts';

export function observeSubscriptionReceiptQuiescence(page: Page): {
	readonly pendingAcknowledgementCount: () => number;
	readonly wait: () => Promise<void>;
} {
	const pendingRequestDocumentEpochs = new Map<Request, number>();
	let currentDocumentEpoch = 0;
	const pendingAcknowledgementCount = (): number => {
		let count = 0;
		for (const documentEpoch of pendingRequestDocumentEpochs.values()) {
			if (documentEpoch === currentDocumentEpoch) count += 1;
		}
		return count;
	};
	const isSubscriptionReceipt = (request: Request): boolean => {
		if (new URL(request.url()).pathname !== '/__bridge-product/command') return false;
		try {
			const body: unknown = request.postDataJSON();
			return (
				typeof body === 'object' &&
				body !== null &&
				Reflect.get(body, 'kind') === 'subscription.acknowledge'
			);
		} catch {
			return false;
		}
	};
	page.on('request', (request: Request): void => {
		if (isSubscriptionReceipt(request)) {
			pendingRequestDocumentEpochs.set(request, currentDocumentEpoch);
		}
	});
	const quiescenceWaiters: Array<() => void> = [];
	const releaseWaitersIfQuiescent = (): void => {
		if (pendingAcknowledgementCount() !== 0) return;
		for (const resolveWaiter of quiescenceWaiters.splice(0)) resolveWaiter();
	};
	const settleRequest = (request: Request): void => {
		pendingRequestDocumentEpochs.delete(request);
		releaseWaitersIfQuiescent();
	};
	page.on('requestfinished', settleRequest);
	page.on('requestfailed', settleRequest);
	// Why: these acknowledgements are issued by a dedicated Web Worker, and Playwright 1.61 detaches
	// the worker target on navigation without emitting a terminal event for its in-flight requests.
	// A destroyed document can no longer owe an acknowledgement, so quiescence is a claim about the
	// current document only; retiring the previous document's entries is what lets the map drain.
	page.on('framenavigated', (frame: Frame): void => {
		if (frame !== page.mainFrame()) return;
		currentDocumentEpoch += 1;
		for (const [request, documentEpoch] of pendingRequestDocumentEpochs) {
			if (documentEpoch !== currentDocumentEpoch) pendingRequestDocumentEpochs.delete(request);
		}
		releaseWaitersIfQuiescent();
	});
	/** Resolves on the observer's own terminal events, immediately when nothing is outstanding. */
	const whenQuiescent = async (): Promise<void> => {
		if (pendingAcknowledgementCount() === 0) return;
		await new Promise<void>((resolve): void => {
			quiescenceWaiters.push(resolve);
		});
	};

	return {
		pendingAcknowledgementCount,
		wait: async (): Promise<void> => {
			await whenQuiescent();
			// The remaining claim is "and no further acknowledgement started", which is the absence of a
			// future event and therefore not expressible without waiting some amount. Two animation
			// frames give the current document its rendering opportunities to start one, then the second
			// quiescence wait re-establishes the claim. This is the one wall-clock-ish wait left here.
			await settleBrowserFrames(page, 2);
			await whenQuiescent();
		},
	};
}

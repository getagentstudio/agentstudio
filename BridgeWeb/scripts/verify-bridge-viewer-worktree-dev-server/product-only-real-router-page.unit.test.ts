import type {
	Page,
	Request as PlaywrightRequest,
	Response as PlaywrightResponse,
} from 'playwright';
import { describe, expect, test } from 'vitest';

import type { BridgeViewerDocumentGenerations } from './product-only-real-router-document-generations.ts';
import {
	BridgeViewerRealRouterObserver,
	freshReviewInitialWindowRequiresTraversal,
	mountedHeaderOrderViolationForExpectedOrder,
	nextFreshReviewTraversalScrollTop,
} from './product-only-real-router-page.ts';
import { previousFreshReviewTraversalScrollTop } from './product-only-real-router-review-hydration-window.ts';

type PageEventName = 'request' | 'requestfailed' | 'requestfinished' | 'response';
type PageEventHandler = (event: unknown) => void;

describe('BridgeViewerRealRouterObserver', () => {
	test('records the scrub-safe product call method in failure transport evidence', () => {
		// Arrange
		const harness = makeObserverHarness();
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => 1),
		);
		const request = makeProductCallRequest('review.activeViewerMode.update');
		harness.emit('request', request);

		// Act / Assert
		expect(observer.failureTransportSnapshot().entries).toEqual([
			expect.objectContaining({
				callMethod: 'review.activeViewerMode.update',
				requestKind: 'product.call',
			}),
		]);
	});

	test('correlates only a strict typed unknown-read refusal for content credit', async () => {
		const harness = makeObserverHarness();
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => 1),
		);
		const matchingRequest = makeContentAcknowledgementRequest('content-request-matching');
		const foreignRequest = makeContentAcknowledgementRequest('content-request-foreign');
		harness.emit('request', matchingRequest);
		harness.emit('response', makeUnknownReadResponse(matchingRequest, 'content-request-matching'));
		harness.emit('request', foreignRequest);
		harness.emit('response', makeUnknownReadResponse(foreignRequest, 'content-request-other'));

		await observer.flushResponseParsers();
		expect(
			observer.productRouteTranscript().map((entry) => entry.contentUnknownReadRefusalCorrelated),
		).toEqual([true, false]);
	});

	test('retains scrubbed content lifecycle and unfinished request ordinals for a failed journey', () => {
		// Arrange
		const harness = makeObserverHarness();
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => 1),
		);
		const completedRequest = makeProductContentRequest('completed-request');
		const unfinishedRequest = makeProductContentRequest('unfinished-request');
		harness.emit('request', completedRequest);
		harness.emit('response', makeSuccessfulResponse(completedRequest));
		harness.emit('requestfinished', completedRequest);
		harness.emit('request', unfinishedRequest);

		// Act
		const snapshot = observer.failureTransportSnapshot();

		// Assert
		expect(snapshot.entries).toEqual([
			expect.objectContaining({
				contentKind: 'review.content',
				httpStatus: 200,
				ordinal: 1,
				path: '/__bridge-product/content',
				requestKind: 'content.open',
			}),
			expect.objectContaining({
				contentKind: 'review.content',
				httpStatus: null,
				ordinal: 2,
				path: '/__bridge-product/content',
				requestKind: 'content.open',
			}),
		]);
		expect(snapshot.unfinishedRequestOrdinals).toEqual([2]);
		expect(JSON.stringify(snapshot)).not.toContain('pane-session-secret');
		expect(JSON.stringify(snapshot)).not.toContain('worker-instance-secret');
	});

	test('waits for streaming request completion and one activity-stable browser frame', async () => {
		// Arrange
		const harness = makeObserverHarness();
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => 1),
		);
		const firstRequest = makeProductContentRequest('first-request');
		const secondRequest = makeProductContentRequest('second-request');
		let barrierResolved = false;

		harness.emit('request', firstRequest);
		harness.emit('response', makeSuccessfulResponse(firstRequest));

		// Act
		const barrier = observer.waitForAllProductResponses().then((): void => {
			barrierResolved = true;
		});
		await flushMicrotasks();

		// Assert
		expect(barrierResolved).toBe(false);

		// Act: completing the first body releases admission for a second request.
		harness.emit('requestfinished', firstRequest);
		await flushMicrotasks();
		expect(harness.pendingAnimationFrameCount()).toBe(1);
		harness.emit('request', secondRequest);
		harness.emit('response', makeSuccessfulResponse(secondRequest));
		harness.resolveNextAnimationFrame();
		await flushMicrotasks();

		// Assert: the activity checkpoint cannot hide the newly admitted body.
		expect(barrierResolved).toBe(false);

		// Act
		harness.emit('requestfinished', secondRequest);
		await flushMicrotasks();
		expect(harness.pendingAnimationFrameCount()).toBe(1);
		harness.resolveNextAnimationFrame();
		await barrier;

		// Assert
		expect(barrierResolved).toBe(true);
		expect(observer.productRouteTranscript().map((entry) => entry.httpStatus)).toEqual([200, 200]);
	});

	test('does not let an unfinished prior-document body block active-document quiescence', async () => {
		// Arrange
		const harness = makeObserverHarness();
		let documentGeneration = 1;
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => documentGeneration),
		);
		const priorDocumentRequest = makeProductContentRequest('prior-document-request');
		harness.emit('request', priorDocumentRequest);
		documentGeneration = 2;

		// Act
		const barrier = observer.waitForAllProductResponses();
		await flushMicrotasks();
		expect(harness.pendingAnimationFrameCount()).toBe(1);
		harness.resolveNextAnimationFrame();
		await barrier;

		// Assert
		expect(observer.productRouteTranscript()).toEqual([
			expect.objectContaining({ documentGeneration: 1, httpStatus: null }),
		]);
	});

	test('does not let a retired-document response parser failure poison the active journey', async () => {
		// Arrange
		const harness = makeObserverHarness();
		let documentGeneration = 1;
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => documentGeneration),
		);
		const retiredDocumentRequest = makeProductCallRequest('review.activeViewerMode.update');
		const retiredDocumentBody = makePendingStringPromise();
		harness.emit('request', retiredDocumentRequest);
		harness.emit(
			'response',
			makeSuccessfulCommandResponse(retiredDocumentRequest, retiredDocumentBody.promise),
		);

		// Act: navigation retires the response before Playwright can read its body.
		documentGeneration = 2;
		retiredDocumentBody.reject(new Error('Target page, context or browser has been closed'));
		await flushMicrotasks();

		// Assert
		await expect(observer.flushResponseParsers()).resolves.toBeUndefined();
		expect(observer.productRouteTranscript()).toEqual([
			expect.objectContaining({
				documentGeneration: 1,
				httpStatus: 200,
				responseKind: null,
			}),
		]);
	});

	test('still reports a response parser failure from the active document', async () => {
		// Arrange
		const harness = makeObserverHarness();
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => 1),
		);
		const activeDocumentRequest = makeProductCallRequest('review.activeViewerMode.update');
		const activeDocumentFailure = new Error('active document response body failed');
		harness.emit('request', activeDocumentRequest);
		harness.emit(
			'response',
			makeSuccessfulCommandResponse(activeDocumentRequest, Promise.reject(activeDocumentFailure)),
		);
		await flushMicrotasks();

		// Act / Assert
		await expect(observer.flushResponseParsers()).rejects.toBe(activeDocumentFailure);
	});

	test('treats a failed non-stream request without an HTTP response as terminal', async () => {
		// Arrange
		const harness = makeObserverHarness();
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => 1),
		);
		const cancelledContentRequest = makeProductContentRequest('cancelled-request');
		harness.emit('request', cancelledContentRequest);
		harness.emit('requestfailed', cancelledContentRequest);

		// Act
		const barrier = observer.waitForAllProductResponses();
		await flushMicrotasks();
		expect(harness.pendingAnimationFrameCount()).toBe(1);
		harness.resolveNextAnimationFrame();
		await barrier;

		// Assert
		expect(observer.failureTransportSnapshot()).toEqual({
			entries: [
				expect.objectContaining({
					httpStatus: null,
					requestKind: 'content.open',
					requestSettled: true,
				}),
			],
			unfinishedRequestOrdinals: [],
			unresolvedWaiters: [],
		});
	});

	test('completes legacy metadata only with the awaited generation’s own final window', async () => {
		// Arrange: generation 1 received a partial window and still has a final window in flight.
		const harness = makeObserverHarness();
		let documentGeneration = 1;
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => documentGeneration),
		);
		const oldPartialRequest = makeLegacyMetadataRequest();
		const oldFinalRequest = makeLegacyMetadataRequest();
		harness.emit('request', oldPartialRequest);
		harness.emit('response', makeLegacyMetadataResponse(oldPartialRequest, 'next-window'));
		harness.emit('request', oldFinalRequest);

		// Act: after the reload, generation 2 receives only a partial window, then the
		// old document's final window arrives.
		documentGeneration = 2;
		const newPartialRequest = makeLegacyMetadataRequest();
		harness.emit('request', newPartialRequest);
		harness.emit('response', makeLegacyMetadataResponse(newPartialRequest, 'next-window'));
		let completed = false;
		const completion = observer.waitForObservedLegacyMetadataCompletion().then((): void => {
			completed = true;
		});
		harness.emit('response', makeLegacyMetadataResponse(oldFinalRequest, null));
		await flushMicrotasks();

		// Assert: the old final window was parsed but settles nothing for generation 2
		// (settling removes the waiter synchronously), and the failure diagnostic
		// names the pending generation-2 waiter.
		expect(observer.legacyRouteTranscript().map((entry) => entry.finalWindow)).toEqual([
			false,
			true,
			false,
		]);
		expect(observer.failureTransportSnapshot().unresolvedWaiters).toContainEqual({
			documentGeneration: 2,
			name: 'legacy-metadata-completion',
		});

		// Act: generation 2's own final window arrives.
		const newFinalRequest = makeLegacyMetadataRequest();
		harness.emit('request', newFinalRequest);
		harness.emit('response', makeLegacyMetadataResponse(newFinalRequest, null));
		await completion;

		// Assert
		expect(completed).toBe(true);
		expect(observer.failureTransportSnapshot().unresolvedWaiters).toEqual([]);
	});

	test('does not wait on legacy metadata a previous generation received', async () => {
		// Arrange: only the old document received a (partial) legacy metadata window.
		const harness = makeObserverHarness();
		let documentGeneration = 1;
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => documentGeneration),
		);
		const oldPartialRequest = makeLegacyMetadataRequest();
		harness.emit('request', oldPartialRequest);
		harness.emit('response', makeLegacyMetadataResponse(oldPartialRequest, 'next-window'));
		await flushMicrotasks();
		documentGeneration = 2;

		// Act / Assert: the new document issued no legacy request, so nothing is awaited.
		await expect(observer.waitForObservedLegacyMetadataCompletion()).resolves.toBeUndefined();
		expect(observer.failureTransportSnapshot().unresolvedWaiters).toEqual([]);
	});

	test('settles a reload waiter only with a response to a request from the next page generation', async () => {
		// Arrange: the previous document sent a subscription receipt before the reload.
		const harness = makeObserverHarness();
		let documentGeneration = 1;
		const observer = new BridgeViewerRealRouterObserver(
			harness.page,
			documentGenerationsAt((): number => documentGeneration),
		);
		const staleAcknowledgementRequest = makeSubscriptionReceiptRequest();
		harness.emit('request', staleAcknowledgementRequest);
		const reloadJoin = observer.armReloadJoinWaiters();
		let settledAcknowledgement: PlaywrightResponse | null = null;
		const acknowledgement = reloadJoin.subscriptionReceipt.then(
			(response: PlaywrightResponse): PlaywrightResponse => {
				settledAcknowledgement = response;
				return response;
			},
		);

		// Act: the new document commits, then the previous document's response arrives first.
		documentGeneration = 2;
		harness.emit('response', makeSubscriptionReceiptResponse(staleAcknowledgementRequest));
		await flushMicrotasks();

		// Assert
		expect(settledAcknowledgement).toBeNull();
		expect(observer.failureTransportSnapshot().unresolvedWaiters).toContainEqual({
			documentGeneration: 2,
			name: 'subscription-receipt',
		});

		// Act: the new document's own acknowledgement arrives.
		const currentAcknowledgementRequest = makeSubscriptionReceiptRequest();
		const currentAcknowledgementResponse = makeSubscriptionReceiptResponse(
			currentAcknowledgementRequest,
		);
		harness.emit('request', currentAcknowledgementRequest);
		harness.emit('response', currentAcknowledgementResponse);

		// Assert
		await expect(acknowledgement).resolves.toBe(currentAcknowledgementResponse);
		expect(observer.failureTransportSnapshot().unresolvedWaiters).toEqual([
			{ documentGeneration: 2, name: 'file-metadata-open' },
			{ documentGeneration: 2, name: 'review-metadata-open' },
		]);
	});
});

describe('mountedHeaderOrderViolationForExpectedOrder', () => {
	test('accepts a sparse mounted viewport that preserves catalog order', () => {
		// Arrange
		const expectedItemIndexById = new Map([
			['review-item-1', 0],
			['review-item-2', 1],
			['review-item-3', 2],
			['review-item-4', 3],
		]);

		// Act
		const violation = mountedHeaderOrderViolationForExpectedOrder({
			expectedItemIndexById,
			mountedItemIds: ['review-item-1', 'review-item-3', 'review-item-4'],
		});

		// Assert
		expect(violation).toBeNull();
	});

	test('reports a mounted viewport whose DOM order contradicts the catalog', () => {
		// Arrange
		const expectedItemIndexById = new Map([
			['review-item-1', 0],
			['review-item-2', 1],
			['review-item-3', 2],
		]);

		// Act
		const violation = mountedHeaderOrderViolationForExpectedOrder({
			expectedItemIndexById,
			mountedItemIds: ['review-item-1', 'review-item-3', 'review-item-2'],
		});

		// Assert
		expect(violation).toEqual({
			expectedItemIndexes: [0, 2, 1],
			mountedItemIds: ['review-item-1', 'review-item-3', 'review-item-2'],
		});
	});
});

describe('nextFreshReviewTraversalScrollTop', () => {
	test('keeps every item geometry-visible during forward traversal with viewport overlap', () => {
		const observedIndexes = simulateReviewTraversal('forward');
		expect(observedIndexes).toEqual(Array.from({ length: 20 }, (_, index) => index));
	});

	test('falls back to bounded viewport progress when no host geometry is available', () => {
		// Arrange / Act
		const nextScrollTop = nextFreshReviewTraversalScrollTop({
			codeScroll: {
				clientHeight: 1_000,
				scrollHeight: 6_500,
				scrollTop: 5_000,
			},
		});

		// Assert
		expect(nextScrollTop).toBe(5_500);
	});
});

describe('freshReviewInitialWindowRequiresTraversal', () => {
	test('advances when one painted selected item fills the initial viewport', () => {
		expect(
			freshReviewInitialWindowRequiresTraversal({
				codeScroll: { clientHeight: 944, scrollHeight: 8_150, scrollTop: 0 },
				selectedItemId: 'selected-item',
				visibleItems: [
					{
						contentState: 'windowed',
						hostBottomOffset: 1_188,
						hostTopOffset: 0,
						itemId: 'selected-item',
						paintIdentity: 'painted-selected-item',
						renderedLineCount: 0,
					},
				],
			}),
		).toBe(true);
	});

	test('does not skip unpainted selected content or a visible non-selected item', () => {
		const base = {
			codeScroll: { clientHeight: 944, scrollHeight: 8_150, scrollTop: 0 },
			selectedItemId: 'selected-item',
		};
		const selectedItem = {
			contentState: 'windowed',
			hostBottomOffset: 1_188,
			hostTopOffset: 0,
			itemId: 'selected-item',
			paintIdentity: 'painted-selected-item' as string | null,
			renderedLineCount: 0,
		};

		expect(
			freshReviewInitialWindowRequiresTraversal({
				...base,
				visibleItems: [{ ...selectedItem, paintIdentity: null }],
			}),
		).toBe(false);
		expect(
			freshReviewInitialWindowRequiresTraversal({
				...base,
				visibleItems: [
					selectedItem,
					{
						...selectedItem,
						itemId: 'next-item',
						paintIdentity: 'painted-next-item',
					},
				],
			}),
		).toBe(false);
	});
});

describe('previousFreshReviewTraversalScrollTop', () => {
	test('keeps every item geometry-visible during reverse traversal with viewport overlap', () => {
		const observedIndexes = simulateReviewTraversal('backward');
		expect(observedIndexes).toEqual(Array.from({ length: 20 }, (_, index) => index));
	});

	test('falls back to bounded viewport progress when no host geometry is available', () => {
		// Arrange / Act
		const previousScrollTop = previousFreshReviewTraversalScrollTop({
			codeScroll: {
				clientHeight: 1_000,
				scrollTop: 5_000,
			},
		});

		// Assert
		expect(previousScrollTop).toBe(4_200);
	});
});

function simulateReviewTraversal(direction: 'forward' | 'backward'): number[] {
	const itemCount = 20;
	const itemHeight = 100;
	const clientHeight = 400;
	const scrollHeight = itemCount * itemHeight;
	const maximumScrollTop = scrollHeight - clientHeight;
	const observedIndexes = new Set<number>();
	let scrollTop = direction === 'forward' ? 0 : maximumScrollTop;
	for (let stepIndex = 0; stepIndex < itemCount * 2; stepIndex += 1) {
		const visibleIndexes = Array.from({ length: itemCount }, (_, index) => index).filter(
			(index) =>
				(index + 1) * itemHeight > scrollTop && index * itemHeight < scrollTop + clientHeight,
		);
		for (const index of visibleIndexes) observedIndexes.add(index);
		if (direction === 'forward' && scrollTop === maximumScrollTop) break;
		if (direction === 'backward' && scrollTop === 0) break;
		scrollTop =
			direction === 'forward'
				? nextFreshReviewTraversalScrollTop({
						codeScroll: { clientHeight, scrollHeight, scrollTop },
					})
				: previousFreshReviewTraversalScrollTop({
						codeScroll: { clientHeight, scrollTop },
					});
	}
	return [...observedIndexes].toSorted((left, right) => left - right);
}

// A page whose every request and worker belongs to the current generation, as
// the tests set it; the observer reads generations only through this seam.
function documentGenerationsAt(currentGeneration: () => number): BridgeViewerDocumentGenerations {
	return {
		currentGeneration,
		observedWorker: (workerUrl: string) => ({
			documentGeneration: currentGeneration(),
			scriptUrl: workerUrl,
		}),
		requestGeneration: (): number => currentGeneration(),
	};
}

function makeObserverHarness(): {
	readonly emit: (eventName: PageEventName, event: unknown) => void;
	readonly page: Page;
	readonly pendingAnimationFrameCount: () => number;
	readonly resolveNextAnimationFrame: () => void;
} {
	const eventHandlers = new Map<PageEventName, PageEventHandler[]>();
	// Playwright evaluates each waitForResponse predicate against every later
	// `response` event and settles the waiter with the first match.
	const responseWaiters: Array<{
		readonly predicate: (response: PlaywrightResponse) => boolean;
		readonly resolve: (response: PlaywrightResponse) => void;
	}> = [];
	const animationFrameResolvers: Array<() => void> = [];
	let activeFrameSettlement:
		| {
				settled: boolean;
				readonly waiters: Array<() => void>;
		  }
		| undefined;
	const pageShape = {
		evaluate: async (): Promise<void> => {
			const frameSettlement = { settled: false, waiters: [] as Array<() => void> };
			activeFrameSettlement = frameSettlement;
			animationFrameResolvers.push((): void => {
				frameSettlement.settled = true;
				for (const resolveWaiter of frameSettlement.waiters) resolveWaiter();
				frameSettlement.waiters.length = 0;
			});
		},
		on: (eventName: PageEventName, eventHandler: PageEventHandler): void => {
			const handlers = eventHandlers.get(eventName) ?? [];
			handlers.push(eventHandler);
			eventHandlers.set(eventName, handlers);
		},
		waitForResponse: async (
			predicate: (response: PlaywrightResponse) => boolean,
		): Promise<PlaywrightResponse> =>
			await new Promise<PlaywrightResponse>((resolve): void => {
				responseWaiters.push({ predicate, resolve });
			}),
		waitForFunction: async (): Promise<void> => {
			const frameSettlement = activeFrameSettlement;
			if (frameSettlement === undefined) {
				throw new Error('Frame settlement wait began before a frame was scheduled.');
			}
			if (frameSettlement.settled) return;
			await new Promise<void>((resolve): void => {
				frameSettlement.waiters.push(resolve);
			});
		},
	};

	return {
		emit: (eventName, event): void => {
			for (const eventHandler of eventHandlers.get(eventName) ?? []) eventHandler(event);
			if (eventName !== 'response') return;
			const response = event as PlaywrightResponse;
			for (const [waiterIndex, waiter] of [...responseWaiters.entries()].toReversed()) {
				if (!waiter.predicate(response)) continue;
				responseWaiters.splice(waiterIndex, 1);
				waiter.resolve(response);
			}
		},
		page: pageShape as unknown as Page,
		pendingAnimationFrameCount: (): number => animationFrameResolvers.length,
		resolveNextAnimationFrame: (): void => {
			const resolveAnimationFrame = animationFrameResolvers.shift();
			if (resolveAnimationFrame === undefined) {
				throw new Error('No pending animation frame to resolve.');
			}
			resolveAnimationFrame();
		},
	};
}

function makeProductCallRequest(method: string): PlaywrightRequest {
	return {
		method: (): string => 'POST',
		postData: (): string =>
			JSON.stringify({
				call: { method, request: null },
				kind: 'product.call',
				paneSessionId: 'pane-session-secret',
				workerInstanceId: 'worker-instance-secret',
			}),
		url: (): string => 'http://127.0.0.1:5173/__bridge-product/command',
	} as unknown as PlaywrightRequest;
}

function makeProductContentRequest(contentRequestId: string): PlaywrightRequest {
	return {
		method: (): string => 'POST',
		postData: (): string =>
			JSON.stringify({
				contentKind: 'review.content',
				contentRequestId,
				kind: 'content.open',
				paneSessionId: 'pane-session-secret',
				workerInstanceId: 'worker-instance-secret',
			}),
		url: (): string => 'http://127.0.0.1:5173/__bridge-product/content',
	} as unknown as PlaywrightRequest;
}

function makeContentAcknowledgementRequest(contentRequestId: string): PlaywrightRequest {
	return {
		method: (): string => 'POST',
		postData: (): string =>
			JSON.stringify({
				contentRequestId,
				kind: 'content.acknowledge',
				leaseId: 'lease-1',
				paneSessionId: 'pane-session-secret',
				receivedThroughContentSequence: 1,
				wireVersion: 2,
				workerInstanceId: 'worker-instance-secret',
			}),
		url: (): string => 'http://127.0.0.1:5173/__bridge-product/command',
	} as unknown as PlaywrightRequest;
}

function makeUnknownReadResponse(
	request: PlaywrightRequest,
	contentRequestId: string,
): PlaywrightResponse {
	const body = new TextEncoder().encode(
		JSON.stringify({
			contentRequestId,
			kind: 'content.acknowledgementRefused',
			leaseId: 'lease-1',
			paneSessionId: 'pane-session-secret',
			reason: 'unknownRead',
			receivedThroughContentSequence: 1,
			wireVersion: 2,
			workerInstanceId: 'worker-instance-secret',
		}),
	);
	return {
		body: async (): Promise<Uint8Array> => body,
		request: (): PlaywrightRequest => request,
		status: (): number => 404,
		url: (): string => request.url(),
	} as unknown as PlaywrightResponse;
}

function makeLegacyMetadataRequest(): PlaywrightRequest {
	return {
		method: (): string => 'GET',
		postData: (): null => null,
		url: (): string => 'http://127.0.0.1:5173/__bridge-worktree/review-metadata',
	} as unknown as PlaywrightRequest;
}

function makeLegacyMetadataResponse(
	request: PlaywrightRequest,
	nextWindowCursor: string | null,
): PlaywrightResponse {
	return {
		request: (): PlaywrightRequest => request,
		status: (): number => 200,
		text: async (): Promise<string> =>
			JSON.stringify({ nextWindowCursor, protocolFrame: { frameKind: 'window', sequence: 1 } }),
		url: (): string => request.url(),
	} as unknown as PlaywrightResponse;
}

function makeSubscriptionReceiptRequest(): PlaywrightRequest {
	return {
		method: (): string => 'POST',
		postData: (): string =>
			JSON.stringify({
				kind: 'subscription.acknowledge',
				domain: 'default',
				handle: 'handle-1',
				incarnation: 'incarnation-1',
				paneSessionId: 'pane-session-secret',
				receivedThroughDeliverySequence: 1,
				subscriptionId: 'subscription-1',
				wireVersion: 2,
				workerInstanceId: 'worker-instance-secret',
			}),
		url: (): string => 'http://127.0.0.1:5173/__bridge-product/command',
	} as unknown as PlaywrightRequest;
}

function makeSubscriptionReceiptResponse(request: PlaywrightRequest): PlaywrightResponse {
	return {
		request: (): PlaywrightRequest => request,
		status: (): number => 200,
		url: (): string => request.url(),
	} as unknown as PlaywrightResponse;
}

function makeSuccessfulResponse(request: PlaywrightRequest): PlaywrightResponse {
	return {
		request: (): PlaywrightRequest => request,
		status: (): number => 200,
	} as unknown as PlaywrightResponse;
}

function makeSuccessfulCommandResponse(
	request: PlaywrightRequest,
	body: Promise<string>,
): PlaywrightResponse {
	return {
		request: (): PlaywrightRequest => request,
		status: (): number => 200,
		text: async (): Promise<string> => await body,
	} as unknown as PlaywrightResponse;
}

function makePendingStringPromise(): {
	readonly promise: Promise<string>;
	readonly reject: (error: Error) => void;
} {
	let rejectPromise: (error: Error) => void = (): void => {
		throw new Error('Pending string promise rejector was not initialized.');
	};
	const promise = new Promise<string>((_resolve, reject): void => {
		rejectPromise = (error): void => reject(error);
	});
	return { promise, reject: rejectPromise };
}

async function flushMicrotasks(): Promise<void> {
	await Promise.resolve();
	await Promise.resolve();
	await Promise.resolve();
}

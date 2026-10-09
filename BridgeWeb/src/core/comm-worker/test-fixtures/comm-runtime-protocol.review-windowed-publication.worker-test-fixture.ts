import type { BridgeCommWorkerPort } from '../bridge-comm-worker-entry.js';
// oxlint-disable unicorn/require-post-message-target-origin -- DedicatedWorkerGlobalScope and MessagePort do not accept targetOrigin.
import { registerBridgeCommWorkerRuntimePortProtocol } from '../bridge-comm-worker-runtime-protocol.js';
import {
	makeIdleReviewMetadataSubscription,
	makeReviewProductTransport,
} from '../bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import type { BridgeProductBatchFrameSinks } from '../bridge-product-batch-frame-router.js';
import type { BridgeProductTransportSession } from '../bridge-product-transport.js';
import type { BridgeProductViewInstallation } from '../bridge-product-view-batch-receiver.js';

export type WindowedReviewBatchPart = {
	readonly begin?: BridgeProductViewInstallation['begin'];
	readonly final: boolean;
	readonly partIndex: number;
	readonly records: BridgeProductViewInstallation['records'];
};
export type WindowedReviewViewScopeRequest = Parameters<
	NonNullable<BridgeProductTransportSession['setViewScopeForSubscription']>
>[0];

export type WindowedReviewWorkerControlMessage =
	| { readonly controlPort: MessagePort; readonly kind: 'windowedReview.install' }
	| { readonly kind: 'windowedReview.batchPart.publish'; readonly part: WindowedReviewBatchPart };

export type WindowedReviewWorkerControlReceipt =
	| { readonly kind: 'windowedReview.installed' }
	| { readonly kind: 'windowedReview.batchPart.processed'; readonly partIndex: number }
	| { readonly kind: 'windowedReview.viewScope'; readonly request: WindowedReviewViewScopeRequest }
	| { readonly kind: 'windowedReview.failed'; readonly message: string };

interface WindowedReviewWorkerScope extends BridgeCommWorkerPort {
	readonly addEventListener: (
		type: 'message',
		listener: (event: MessageEvent<unknown>) => void,
	) => void;
}

declare const self: WindowedReviewWorkerScope;

self.addEventListener('message', (event: MessageEvent<unknown>): void => {
	if (!isWindowedReviewInstallMessage(event.data)) return;
	event.stopImmediatePropagation();
	installWindowedReviewRuntime(event.data.controlPort);
});

function installWindowedReviewRuntime(controlPort: MessagePort): void {
	let batchSinks: BridgeProductBatchFrameSinks | null = null;
	let begin: BridgeProductViewInstallation['begin'] | null = null;
	const stagedRecords: BridgeProductViewInstallation['records'][number][] = [];
	let nextPartIndex = 0;
	let pendingPart = Promise.resolve();
	const reviewSubscription = makeIdleReviewMetadataSubscription(
		'review-windowed-runtime-subscription',
	);
	controlPort.addEventListener('message', (event: MessageEvent<unknown>): void => {
		const message = event.data;
		if (!isWindowedReviewBatchPartMessage(message)) return;
		pendingPart = pendingPart
			.then(async (): Promise<void> => {
				const part = message.part;
				if (part.partIndex !== nextPartIndex) throw new Error('Review batch part order changed.');
				if (part.begin !== undefined) {
					if (begin !== null || part.partIndex !== 0) throw new Error('Review batch began twice.');
					begin = part.begin;
				}
				stagedRecords.push(...part.records);
				nextPartIndex += 1;
				if (part.final) {
					if (begin === null || batchSinks === null)
						throw new Error('Review batch sink was unavailable.');
					await batchSinks.install({
						certified: true,
						staleRecords: [],
						begin,
						domain: 'default',
						records: stagedRecords,
					});
				}
				controlPort.postMessage({
					kind: 'windowedReview.batchPart.processed',
					partIndex: part.partIndex,
				} satisfies WindowedReviewWorkerControlReceipt);
			})
			.catch((error: unknown): void => {
				controlPort.postMessage({
					kind: 'windowedReview.failed',
					message: error instanceof Error ? error.message : String(error),
				} satisfies WindowedReviewWorkerControlReceipt);
			});
	});
	controlPort.start();
	registerBridgeCommWorkerRuntimePortProtocol(self, {
		bridgeDemandRank: { lane: 'selected', priority: 0 },
		budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
		productTransport: makeReviewProductTransport({
			onBatchFrameSinks: (sinks): void => {
				batchSinks = sinks;
			},
			onViewScope: (request): void => {
				controlPort.postMessage({
					kind: 'windowedReview.viewScope',
					request,
				} satisfies WindowedReviewWorkerControlReceipt);
			},
			reviewSubscription,
			subscribedKinds: [],
		}),
	});
	controlPort.postMessage({
		kind: 'windowedReview.installed',
	} satisfies WindowedReviewWorkerControlReceipt);
}

function isWindowedReviewInstallMessage(
	value: unknown,
): value is Extract<
	WindowedReviewWorkerControlMessage,
	{ readonly kind: 'windowedReview.install' }
> {
	return (
		typeof value === 'object' &&
		value !== null &&
		'kind' in value &&
		value.kind === 'windowedReview.install' &&
		'controlPort' in value &&
		value.controlPort instanceof MessagePort
	);
}

function isWindowedReviewBatchPartMessage(
	value: unknown,
): value is Extract<
	WindowedReviewWorkerControlMessage,
	{ readonly kind: 'windowedReview.batchPart.publish' }
> {
	return (
		typeof value === 'object' &&
		value !== null &&
		'kind' in value &&
		value.kind === 'windowedReview.batchPart.publish' &&
		'part' in value
	);
}

import { describe, expect, test } from 'vitest';

import { encodeBridgeWorkerViewportCommand } from './bridge-comm-worker-protocol.js';
import {
	registerBridgeCommWorkerRuntimePortProtocol,
	type BridgeCommWorkerPreparationDrain,
} from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerReviewViewerMode,
	assertBridgeCommWorkerPreparationDrain,
	createBridgeWorkerSequenceCounter,
	createBridgeCommWorkerReviewProductTestSource,
	createDeferredReviewContentStream,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
	makeContentRequestDescriptor,
	makeRenderSemantics,
	makeWorkerReviewContentMetadata,
	openReviewContentFromDescriptorMap,
	type DeferredReviewContentStream,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { drainBridgeWorkerVisibleDemandRuntimeUntil } from './bridge-comm-worker-runtime-protocol.visible-demand.test-support.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';

describe('Bridge comm worker runtime Review demand rerun', () => {
	test('drops in-flight visible Review demand after source update and reruns current content', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const deferredStreamsByDescriptorId = new Map<string, DeferredReviewContentStream>();
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			createSequence: createBridgeWorkerSequenceCounter(401),
			openReviewContent: (descriptor, abortSignal) => {
				if (descriptor.descriptorId.endsWith('-4')) {
					const deferredStream = createDeferredReviewContentStream(descriptor);
					deferredStreamsByDescriptorId.set(descriptor.descriptorId, deferredStream);
					return deferredStream.stream;
				}
				return openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			pump: createWorkerContentPreparationPump({
				maxSliceMs: 8,
				now: () => clockMs,
			}),
			productTransport: reviewProductSource.productTransport,
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'visible-before-update');
		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						generation: 4,
						itemId: 'item-1',
						role: 'base',
						text: 'old base',
					}),
					makeContentRequestDescriptor({
						generation: 4,
						itemId: 'item-1',
						role: 'head',
						text: 'old head',
					}),
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			4,
		);
		await flushBridgeWorkerRuntimeContinuations();
		// The certified bank is complete. Visible demand, not a source-reset chunk,
		// starts the old content reads that the replacement must retire.
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-visible-before-update',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		const staleFirstDrain = assertBridgeCommWorkerPreparationDrain(scheduledDrains[0])();
		await flushBridgeWorkerRuntimeContinuations();
		expect(deferredStreamsByDescriptorId.size).toBe(2);
		scheduledDrains.length = 0;
		postedMessages.length = 0;

		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						generation: 5,
						itemId: 'item-1',
						role: 'base',
						text: 'fresh base',
					}),
					makeContentRequestDescriptor({
						generation: 5,
						itemId: 'item-1',
						role: 'head',
						text: 'fresh head',
					}),
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			6,
		);
		await flushBridgeWorkerRuntimeContinuations();

		for (const deferredStream of deferredStreamsByDescriptorId.values()) {
			deferredStream.resolve('old body');
		}
		await drainBridgeWorkerVisibleDemandRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						JSON.stringify(postedMessage.message).includes('fresh head'),
				),
			scheduledDrains,
			startIndex: 0,
		});
		await staleFirstDrain;

		const pierreJobMessages = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' ? [postedMessage.message] : [],
		);
		expect(pierreJobMessages).toHaveLength(1);
		expect(JSON.stringify(pierreJobMessages[0])).toContain('fresh head');
		expect(JSON.stringify(pierreJobMessages[0])).not.toContain('old head');
	});
});

import { describe, expect, test } from 'vitest';

import {
	encodeBridgeWorkerRenderDispositionCommand,
	encodeBridgeWorkerReviewInvalidateCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import type { BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import {
	assertBridgeCommWorkerPreparationDrain,
	createBridgeWorkerSequenceCounter,
	createDeferredReviewContentStream,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
	makeContentRequestDescriptor,
	makeRenderSemantics,
	makeWorkerReviewContentMetadata,
	openReviewContentFromDescriptorMap,
	reviewContentFixtureByDescriptorId,
	type DeferredReviewContentStream,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import {
	createTrackedBridgeWorkerReviewContentOpen,
	drainBridgeWorkerVisibleDemandRuntimeUntil,
	drainBridgeWorkerVisibleDemandRuntimeUntilQuiescent,
	registerBridgeRuntimeWithInitialReviewSource,
} from './bridge-comm-worker-runtime-protocol.visible-demand.test-support.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';
import { bridgeWorkerRenderDispositionReceiptSchema } from './bridge-worker-render-fulfillment.js';

describe('Bridge comm worker runtime visible demand protocol', () => {
	test('refreshes a ready visible Review item after source update changes content descriptors', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages, waitForMessage } = createRecordingBridgeCommWorkerPort();
		const pump = createWorkerContentPreparationPump({ maxSliceMs: 8, now: () => clockMs });
		const trackedContentOpen = createTrackedBridgeWorkerReviewContentOpen(
			openReviewContentFromDescriptorMap,
		);

		const reviewProductSource = await registerBridgeRuntimeWithInitialReviewSource(dispatch, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
			contentRequestDescriptors: [
				makeInexactContentRequestDescriptor({
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
			createSequence: createBridgeWorkerSequenceCounter(701),
			openReviewContent: trackedContentOpen.openContent,
			pump,
			renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-visible-ready-before-source-update',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
			}),
		);
		await drainBridgeWorkerVisibleDemandRuntimeUntilQuiescent({
			pendingContentCompletions: trackedContentOpen.pendingCompletions,
			pendingPreparationWorkIds: pump.getPendingWorkIds,
			scheduledDrains,
		});
		expect(
			postedMessages.filter(
				(postedMessage) => postedMessage.message.kind === 'reviewPierreRenderJob',
			),
		).toHaveLength(1);
		queueLatestReviewPublication(dispatch, postedMessages, 'ready-before-source-update');
		await flushBridgeWorkerRuntimeContinuations();

		const updatedCandidateReady = waitForMessage(
			(message): boolean => message.kind === 'reviewCandidateReady' && message.revision === 6,
		);
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
		await updatedCandidateReady;
		await drainBridgeWorkerVisibleDemandRuntimeUntilQuiescent({
			pendingContentCompletions: trackedContentOpen.pendingCompletions,
			pendingPreparationWorkIds: pump.getPendingWorkIds,
			scheduledDrains,
		});

		const pierreJobMessages = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' ? [postedMessage.message] : [],
		);
		expect(trackedContentOpen.openedDescriptorIds).toHaveLength(4);
		expect(pierreJobMessages).toHaveLength(2);
		expect(JSON.stringify(pierreJobMessages[1])).toContain('fresh head');
	});

	test('refreshes changed descriptor bounds without republishing identical semantic content', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages, waitForMessage } = createRecordingBridgeCommWorkerPort();
		const pump = createWorkerContentPreparationPump({ maxSliceMs: 8, now: () => clockMs });
		const trackedContentOpen = createTrackedBridgeWorkerReviewContentOpen(
			openReviewContentFromDescriptorMap,
		);
		const baseDescriptor = makeInexactContentRequestDescriptor({
			generation: 4,
			itemId: 'item-1',
			role: 'base',
			text: 'same base',
		});
		const headDescriptor = makeInexactContentRequestDescriptor({
			generation: 4,
			itemId: 'item-1',
			role: 'head',
			text: 'same head',
		});
		const updatedBaseDescriptor = {
			...makeContentRequestDescriptor({
				generation: 5,
				itemId: 'item-1',
				role: 'base',
				text: 'same base',
			}),
			contentDigest: baseDescriptor.contentDigest,
		};
		const updatedHeadDescriptor = {
			...makeContentRequestDescriptor({
				generation: 5,
				itemId: 'item-1',
				role: 'head',
				text: 'same head',
			}),
			contentDigest: headDescriptor.contentDigest,
		};

		const reviewProductSource = await registerBridgeRuntimeWithInitialReviewSource(dispatch, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
			contentRequestDescriptors: [baseDescriptor, headDescriptor],
			createSequence: createBridgeWorkerSequenceCounter(801),
			openReviewContent: trackedContentOpen.openContent,
			pump,
			renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-visible-before-byte-bound-source-update',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
			}),
		);
		await drainBridgeWorkerVisibleDemandRuntimeUntilQuiescent({
			pendingContentCompletions: trackedContentOpen.pendingCompletions,
			pendingPreparationWorkIds: pump.getPendingWorkIds,
			scheduledDrains,
		});
		expect(
			postedMessages.filter(
				(postedMessage) => postedMessage.message.kind === 'reviewPierreRenderJob',
			),
		).toHaveLength(1);
		queueLatestReviewPublication(dispatch, postedMessages, 'byte-bound-before-source-update');
		await flushBridgeWorkerRuntimeContinuations();

		const byteBoundCandidateReady = waitForMessage(
			(message): boolean => message.kind === 'reviewCandidateReady' && message.revision === 6,
		);
		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					{
						...updatedBaseDescriptor,
						declaredByteLength: 9,
						maximumBytes: 9,
						wholeByteLength: 9,
						window: { ...updatedBaseDescriptor.window, maximumBytes: 9 },
					},
					{
						...updatedHeadDescriptor,
						declaredByteLength: 9,
						maximumBytes: 9,
						wholeByteLength: 9,
						window: { ...updatedHeadDescriptor.window, maximumBytes: 9 },
					},
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			6,
		);
		await byteBoundCandidateReady;
		await drainBridgeWorkerVisibleDemandRuntimeUntilQuiescent({
			pendingContentCompletions: trackedContentOpen.pendingCompletions,
			pendingPreparationWorkIds: pump.getPendingWorkIds,
			scheduledDrains,
		});

		const pierreJobMessages = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' ? [postedMessage.message] : [],
		);
		expect(trackedContentOpen.openedDescriptorIds).toEqual([
			'descriptor-item-1-base-4',
			'descriptor-item-1-head-4',
			'descriptor-item-1-base-5',
			'descriptor-item-1-head-5',
		]);
		expect(pierreJobMessages).toHaveLength(1);
	});

	test('keeps source-update rerun sticky when viewport arrives before stale in-flight completion', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages, waitForMessage } = createRecordingBridgeCommWorkerPort();
		const deferredStreamsByDescriptorId = new Map<string, DeferredReviewContentStream>();

		const reviewProductSource = await registerBridgeRuntimeWithInitialReviewSource(dispatch, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
			contentRequestDescriptors: [
				makeInexactContentRequestDescriptor({
					generation: 4,
					itemId: 'item-1',
					role: 'base',
					text: 'ready base',
				}),
				makeContentRequestDescriptor({
					generation: 4,
					itemId: 'item-1',
					role: 'head',
					text: 'ready head',
				}),
			],
			createSequence: createBridgeWorkerSequenceCounter(801),
			openReviewContent: (descriptor, abortSignal) => {
				if (descriptor.descriptorId.endsWith('-5')) {
					const deferredStream = createDeferredReviewContentStream(descriptor);
					deferredStreamsByDescriptorId.set(descriptor.descriptorId, deferredStream);
					return deferredStream.stream;
				}
				return openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			pump: createWorkerContentPreparationPump({ maxSliceMs: 8, now: () => clockMs }),
			renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-visible-before-sticky-rerun',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(scheduledDrains).toEqual([]);
		queueLatestReviewPublication(dispatch, postedMessages, 'sticky-before-source-update');
		await flushBridgeWorkerRuntimeContinuations();

		const staleCandidateReady = waitForMessage(
			(message): boolean => message.kind === 'reviewCandidateReady' && message.revision === 6,
		);
		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						generation: 5,
						itemId: 'item-1',
						role: 'base',
						text: 'stale base',
					}),
					makeContentRequestDescriptor({
						generation: 5,
						itemId: 'item-1',
						role: 'head',
						text: 'stale head',
					}),
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			6,
		);
		await staleCandidateReady;
		await drainBridgeWorkerVisibleDemandRuntimeUntil({
			hasExpectedEvent: () => deferredStreamsByDescriptorId.size === 2,
			scheduledDrains,
			startIndex: 0,
		});
		expect(deferredStreamsByDescriptorId.size).toBe(2);
		const freshDrainStartIndex = scheduledDrains.length;

		const freshCandidateReady = waitForMessage(
			(message): boolean => message.kind === 'reviewCandidateReady' && message.revision === 7,
		);
		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						generation: 6,
						itemId: 'item-1',
						role: 'base',
						text: 'fresh base',
					}),
					makeContentRequestDescriptor({
						generation: 6,
						itemId: 'item-1',
						role: 'head',
						text: 'fresh head',
					}),
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			7,
		);
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-viewport-after-source-b',
				epoch: 8,
				surface: 'review',
				visibleItemIds: ['item-1'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
			}),
		);
		for (const deferredStream of deferredStreamsByDescriptorId.values()) {
			deferredStream.resolve('stale body');
		}
		await freshCandidateReady;
		await drainBridgeWorkerVisibleDemandRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						JSON.stringify(postedMessage.message).includes('fresh head'),
				),
			scheduledDrains,
			startIndex: freshDrainStartIndex,
		});

		const pierreJobMessages = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' ? [postedMessage.message] : [],
		);
		expect(pierreJobMessages).toHaveLength(2);
		expect(JSON.stringify(pierreJobMessages[1])).toContain('fresh head');
		expect(JSON.stringify(pierreJobMessages[1])).not.toContain('stale head');
	});

	test('clears ready visible Review paint when source update removes executable content', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();

		const reviewProductSource = await registerBridgeRuntimeWithInitialReviewSource(dispatch, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
			contentRequestDescriptors: [
				makeInexactContentRequestDescriptor({
					generation: 4,
					itemId: 'item-1',
					role: 'base',
					text: 'ready base',
				}),
				makeContentRequestDescriptor({
					generation: 4,
					itemId: 'item-1',
					role: 'head',
					text: 'ready head',
				}),
			],
			createSequence: createBridgeWorkerSequenceCounter(901),
			openReviewContent: openReviewContentFromDescriptorMap,
			pump: createWorkerContentPreparationPump({ maxSliceMs: 8, now: () => clockMs }),
			renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-visible-before-nonexecutable-source',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(scheduledDrains).toEqual([]);

		reviewProductSource.publishSource(
			{
				contentItems: [
					{
						...makeWorkerReviewContentMetadata({ itemId: 'item-1' }),
						availableContentRoles: [],
					},
				],
				contentRequestDescriptors: [],
				renderSemantics: [],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			6,
		);
		await flushBridgeWorkerRuntimeContinuations();

		const finalPatch = postedMessages
			.flatMap((postedMessage) =>
				postedMessage.message.kind === 'slicePatch' ? [postedMessage.message] : [],
			)
			.at(-1);
		expect(finalPatch).toMatchObject({
			kind: 'slicePatch',
			patches: [
				{ slice: 'rowPaint', operation: 'delete', itemId: 'item-1' },
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'item-1',
					payload: { state: 'stale' },
				},
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'item-1',
					payload: { state: 'unavailable' },
				},
			],
		});
		expect(scheduledDrains).toEqual([]);
	});

	test('clears ready visible Review paint when source update keeps only one required diff side', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();

		const reviewProductSource = await registerBridgeRuntimeWithInitialReviewSource(dispatch, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
			contentRequestDescriptors: [
				makeContentRequestDescriptor({
					generation: 4,
					itemId: 'item-1',
					role: 'base',
					text: 'ready base',
				}),
				makeContentRequestDescriptor({
					generation: 4,
					itemId: 'item-1',
					role: 'head',
					text: 'ready head',
				}),
			],
			createSequence: createBridgeWorkerSequenceCounter(951),
			openReviewContent: openReviewContentFromDescriptorMap,
			pump: createWorkerContentPreparationPump({ maxSliceMs: 8, now: () => clockMs }),
			renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-visible-before-one-sided-source',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(scheduledDrains).toEqual([]);

		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						generation: 5,
						itemId: 'item-1',
						role: 'head',
						text: 'head only',
					}),
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			6,
		);
		await flushBridgeWorkerRuntimeContinuations();

		const finalPatch = postedMessages
			.flatMap((postedMessage) =>
				postedMessage.message.kind === 'slicePatch' ? [postedMessage.message] : [],
			)
			.at(-1);
		expect(finalPatch).toMatchObject({
			kind: 'slicePatch',
			patches: [
				{ slice: 'rowPaint', operation: 'delete', itemId: 'item-1' },
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'item-1',
					payload: { state: 'stale' },
				},
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'item-1',
					payload: { state: 'unavailable' },
				},
			],
		});
		expect(scheduledDrains).toEqual([]);
	});

	test('keeps unrelated visible Review fetches current when source update changes one item', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const deferredStreamsByDescriptorId = new Map<string, DeferredReviewContentStream>();
		const fetchCallsByItemId = new Map<string, number>();

		const reviewProductSource = await registerBridgeRuntimeWithInitialReviewSource(dispatch, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			contentItems: [
				makeWorkerReviewContentMetadata({ itemId: 'item-1' }),
				makeWorkerReviewContentMetadata({ itemId: 'item-2' }),
			],
			contentRequestDescriptors: [
				makeContentRequestDescriptor({
					generation: 4,
					itemId: 'item-1',
					role: 'base',
					text: 'a old base',
				}),
				makeContentRequestDescriptor({
					generation: 4,
					itemId: 'item-1',
					role: 'head',
					text: 'a old head',
				}),
				makeContentRequestDescriptor({
					generation: 4,
					itemId: 'item-2',
					role: 'base',
					text: 'b base',
				}),
				makeContentRequestDescriptor({
					generation: 4,
					itemId: 'item-2',
					role: 'head',
					text: 'b head',
				}),
			],
			createSequence: createBridgeWorkerSequenceCounter(501),
			openReviewContent: (descriptor, abortSignal) => {
				fetchCallsByItemId.set(
					descriptor.itemId,
					(fetchCallsByItemId.get(descriptor.itemId) ?? 0) + 1,
				);
				if (descriptor.descriptorId.endsWith('-4')) {
					const deferredStream = createDeferredReviewContentStream(descriptor);
					deferredStreamsByDescriptorId.set(descriptor.descriptorId, deferredStream);
					return deferredStream.stream;
				}
				return openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			pump: createWorkerContentPreparationPump({ maxSliceMs: 8, now: () => clockMs }),
			renderSemantics: [
				makeRenderSemantics({ itemId: 'item-1' }),
				makeRenderSemantics({ itemId: 'item-2' }),
			],
			rows: [
				{ id: 'item-1', parentId: null, index: 0 },
				{ id: 'item-2', parentId: null, index: 1 },
			],
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-two-visible-before-update',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1', 'item-2'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 1,
				phase: 'settled',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(deferredStreamsByDescriptorId.size).toBe(4);
		expect(scheduledDrains).toEqual([]);

		reviewProductSource.publishSource(
			{
				contentItems: [
					makeWorkerReviewContentMetadata({ itemId: 'item-1' }),
					makeWorkerReviewContentMetadata({ itemId: 'item-2' }),
				],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						generation: 5,
						itemId: 'item-1',
						role: 'base',
						text: 'a fresh base',
					}),
					makeContentRequestDescriptor({
						generation: 5,
						itemId: 'item-1',
						role: 'head',
						text: 'a fresh head',
					}),
					makeContentRequestDescriptor({
						generation: 4,
						itemId: 'item-2',
						role: 'base',
						text: 'b base',
					}),
					makeContentRequestDescriptor({
						generation: 4,
						itemId: 'item-2',
						role: 'head',
						text: 'b head',
					}),
				],
				renderSemantics: [
					makeRenderSemantics({ itemId: 'item-1' }),
					makeRenderSemantics({ itemId: 'item-2' }),
				],
				rows: [
					{ id: 'item-1', parentId: null, index: 0 },
					{ id: 'item-2', parentId: null, index: 1 },
				],
			},
			6,
		);
		for (const [descriptorId, deferredStream] of deferredStreamsByDescriptorId) {
			const fixture = reviewContentFixtureByDescriptorId.get(descriptorId);
			if (fixture === undefined) {
				throw new Error(`Unexpected Review content descriptor ${descriptorId}.`);
			}
			deferredStream.resolve(fixture.text);
		}
		await drainBridgeWorkerVisibleDemandRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-1' &&
						JSON.stringify(postedMessage.message).includes('a fresh head'),
				),
			scheduledDrains,
			startIndex: 0,
		});

		const pierreJobItemIds = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob'
				? [postedMessage.message.job.itemId]
				: [],
		);
		expect(pierreJobItemIds).toEqual(['item-2', 'item-1']);
		expect(fetchCallsByItemId.get('item-1')).toBe(4);
		expect(fetchCallsByItemId.get('item-2')).toBe(2);
	});

	test('reruns an in-flight visible Review fetch after path-hint invalidation', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const deferredStreamsByDescriptorId = new Map<string, DeferredReviewContentStream>();

		await registerBridgeRuntimeWithInitialReviewSource(dispatch, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
			contentRequestDescriptors: [
				makeInexactContentRequestDescriptor({
					generation: 4,
					itemId: 'item-1',
					role: 'base',
					text: 'old base',
				}),
				makeInexactContentRequestDescriptor({
					generation: 4,
					itemId: 'item-1',
					role: 'head',
					text: 'old head',
				}),
			],
			createSequence: createBridgeWorkerSequenceCounter(601),
			openReviewContent: (descriptor, abortSignal) => {
				if (descriptor.descriptorId.endsWith('-4')) {
					const deferredStream = createDeferredReviewContentStream(descriptor);
					deferredStreamsByDescriptorId.set(descriptor.descriptorId, deferredStream);
					return deferredStream.stream;
				}
				return openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			pump: createWorkerContentPreparationPump({ maxSliceMs: 8, now: () => clockMs }),
			renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-visible-before-path-invalidate',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(deferredStreamsByDescriptorId.size).toBe(2);
		expect(scheduledDrains).toEqual([]);

		dispatch.message(
			encodeBridgeWorkerReviewInvalidateCommand({
				requestId: 'request-path-hint-invalidate',
				epoch: 6,
				itemIds: [],
				pathHints: ['Sources/App/item-1.swift'],
				reason: 'watchEvent',
				scope: 'items',
			}),
		);
		for (const [descriptorId, deferredStream] of deferredStreamsByDescriptorId) {
			deferredStream.resolve(descriptorId.includes('-base-') ? 'old base' : 'old head');
		}
		await flushBridgeWorkerRuntimeContinuations();
		expect(
			postedMessages.filter(
				(postedMessage) => postedMessage.message.kind === 'reviewPierreRenderJob',
			),
		).toEqual([]);
		deferredStreamsByDescriptorId.clear();
		const rerunDrain = assertBridgeCommWorkerPreparationDrain(scheduledDrains[0])();
		await flushBridgeWorkerRuntimeContinuations();
		expect(deferredStreamsByDescriptorId.size).toBe(2);
		for (const [descriptorId, deferredStream] of deferredStreamsByDescriptorId) {
			deferredStream.resolve(descriptorId.includes('-base-') ? 'fresh base' : 'fresh body');
		}
		await flushBridgeWorkerRuntimeContinuations();
		await drainBridgeWorkerVisibleDemandRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						JSON.stringify(postedMessage.message).includes('fresh body'),
				),
			scheduledDrains,
			startIndex: 1,
		});
		await rerunDrain;

		const pierreJobMessages = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' ? [postedMessage.message] : [],
		);
		expect(pierreJobMessages).toHaveLength(1);
		expect(JSON.stringify(pierreJobMessages[0])).toContain('fresh body');
	});

	test('drains every visible Review item when one settled window exceeds start concurrency', async () => {
		// Arrange
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const itemIds = Array.from({ length: 9 }, (_, index): string => `visible-item-${index + 1}`);
		await registerBridgeRuntimeWithInitialReviewSource(dispatch, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			contentItems: itemIds.map((itemId) => makeWorkerReviewContentMetadata({ itemId })),
			contentRequestDescriptors: itemIds.flatMap((itemId) => [
				makeContentRequestDescriptor({
					generation: 4,
					itemId,
					role: 'base',
					text: `${itemId} base`,
				}),
				makeContentRequestDescriptor({
					generation: 4,
					itemId,
					role: 'head',
					text: `${itemId} head`,
				}),
			]),
			createSequence: createBridgeWorkerSequenceCounter(901),
			openReviewContent: openReviewContentFromDescriptorMap,
			pump: createWorkerContentPreparationPump({ maxSliceMs: 8, now: () => clockMs }),
			renderSemantics: itemIds.map((itemId) => makeRenderSemantics({ itemId })),
			rows: itemIds.map((itemId, index) => ({ id: itemId, parentId: null, index })),
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});

		// Act
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-nine-visible-items',
				epoch: 5,
				surface: 'review',
				visibleItemIds: itemIds,
				firstVisibleIndex: 0,
				lastVisibleIndex: itemIds.length - 1,
				phase: 'settled',
			}),
		);
		await drainBridgeWorkerVisibleDemandRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.filter(
					(postedMessage) => postedMessage.message.kind === 'reviewPierreRenderJob',
				).length === itemIds.length,
			scheduledDrains,
			startIndex: 0,
		});

		// Assert
		const publishedItemIds = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob'
				? [postedMessage.message.job.itemId]
				: [],
		);
		expect(new Set(publishedItemIds)).toEqual(new Set(itemIds));
		expect(publishedItemIds).toHaveLength(itemIds.length);
	});
});

function queueLatestReviewPublication(
	dispatch: ReturnType<typeof createRecordingBridgeCommWorkerPort>['dispatch'],
	postedMessages: ReturnType<typeof createRecordingBridgeCommWorkerPort>['postedMessages'],
	requestLabel: string,
): void {
	const publication = postedMessages
		.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' ? [postedMessage.message] : [],
		)
		.at(-1);
	if (publication === undefined) throw new Error('Expected a Review publication to queue.');
	dispatch.message(
		encodeBridgeWorkerRenderDispositionCommand({
			epoch: publication.workerDerivationEpoch,
			receipts: [
				bridgeWorkerRenderDispositionReceiptSchema.parse({
					...publication.renderReceiptIdentity,
					disposition: 'queued',
					kind: 'render.disposition',
					receivedAtMilliseconds: 0,
				}),
			],
			requestId: `request-queue-${requestLabel}`,
		}),
	);
}

function makeInexactContentRequestDescriptor(
	props: Parameters<typeof makeContentRequestDescriptor>[0],
): ReturnType<typeof makeContentRequestDescriptor> {
	const descriptor = makeContentRequestDescriptor(props);
	return {
		...descriptor,
		declaredByteLength: null,
		maximumBytes: 512 * 1024,
		wholeByteLength: null,
		window: { ...descriptor.window, maximumBytes: 512 * 1024 },
	};
}

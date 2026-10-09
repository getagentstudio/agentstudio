import { afterEach, describe, expect, test, vi } from 'vitest';

import {
	encodeBridgeWorkerRenderDispositionCommand,
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import {
	registerBridgeCommWorkerRuntimePortProtocol,
	type BridgeCommWorkerPreparationDrain,
} from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerReviewViewerMode,
	assertBridgeCommWorkerPreparationDrain,
	createBridgeWorkerSequenceCounter,
	createBridgeCommWorkerReviewProductTestSource,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
	makeContentRequestDescriptor,
	makeRenderSemantics,
	makeWorkerReviewContentMetadata,
	openReviewContentFromDescriptorMap,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import type { BridgeProductContentStream } from './bridge-product-transport-contract.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';
import { bridgeWorkerRenderDispositionReceiptSchema } from './bridge-worker-render-fulfillment.js';

afterEach((): void => {
	vi.useRealTimers();
});

describe('Bridge comm worker runtime protocol Review preparation', () => {
	test('reissues selected Review preparation once after unexpected EOF', async () => {
		vi.useFakeTimers();
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch } = createRecordingBridgeCommWorkerPort();
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();
		let openCount = 0;
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			openReviewContent: (descriptor, abortSignal) => {
				openCount += 1;
				return openCount <= 2
					? unexpectedEOFReviewContentStream(descriptor.descriptorId)
					: openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			productTransport: reviewProductSource.productTransport,
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'selected-unexpected-eof');
		reviewProductSource.publishSource({
			contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
			contentRequestDescriptors: [
				makeContentRequestDescriptor({ itemId: 'item-1', role: 'base', text: 'base\n' }),
				makeContentRequestDescriptor({ itemId: 'item-1', role: 'head', text: 'head\n' }),
			],
			renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
			rows: [{ id: 'item-1', index: 0, parentId: null }],
		});
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 1,
				requestId: 'selected-unexpected-eof',
				selectedItemId: 'item-1',
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		for (let round = 0; round < 8 && scheduledDrains.length > 0; round += 1) {
			for (const drain of scheduledDrains.splice(0)) void drain();
			// oxlint-disable-next-line no-await-in-loop -- Each bounded round exposes event-scheduled follow-up drains.
			await flushBridgeWorkerRuntimeContinuations();
		}
		expect(openCount).toBe(2);
		await vi.advanceTimersByTimeAsync(499);
		await flushBridgeWorkerRuntimeContinuations();
		expect(openCount).toBe(2);
		await vi.runOnlyPendingTimersAsync();
		await flushBridgeWorkerRuntimeContinuations();
		for (let round = 0; round < 8; round += 1) {
			for (const drain of scheduledDrains.splice(0)) void drain();
			// oxlint-disable-next-line no-await-in-loop -- Each bounded round exposes retry-scheduled follow-up drains.
			await flushBridgeWorkerRuntimeContinuations();
			if (openCount >= 4) break;
		}
		expect(openCount).toBe(4);
		reviewProductSource.close();
	});

	test('selects the last item after an atomic 130-row Review bank', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const sourceRows = Array.from({ length: 130 }, (_unused, index) => ({
			id: `item-${index + 1}`,
			parentId: null,
			index,
		}));
		const sourceContentItems = sourceRows.map((row) =>
			makeWorkerReviewContentMetadata({ itemId: row.id }),
		);
		const sourceDescriptors = sourceRows.flatMap((row) => [
			makeContentRequestDescriptor({
				generation: 6,
				itemId: row.id,
				role: 'base',
				text: `old ${row.id}\n`,
			}),
			makeContentRequestDescriptor({
				generation: 6,
				itemId: row.id,
				role: 'head',
				text: `new ${row.id}\n`,
			}),
		]);
		const sourceSemantics = sourceRows.map((row) => makeRenderSemantics({ itemId: row.id }));
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			createSequence: createBridgeWorkerSequenceCounter(901),
			openReviewContent: openReviewContentFromDescriptorMap,
			productTransport: reviewProductSource.productTransport,
			pump: createWorkerContentPreparationPump({
				maxSliceMs: 8,
				now: () => clockMs,
			}),
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'selected-preempts-source-reset');

		reviewProductSource.publishSource(
			{
				contentItems: sourceContentItems,
				contentRequestDescriptors: sourceDescriptors,
				renderSemantics: sourceSemantics,
				rows: sourceRows,
			},
			6,
		);
		await flushBridgeWorkerRuntimeContinuations();

		expect(postedMessages.some(({ message }) => message.kind === 'reviewPierreRenderJob')).toBe(
			false,
		);
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select-during-source-reset',
				epoch: 7,
				surface: 'review',
				selectedItemId: 'item-130',
				selectedSource: 'user',
			}),
		);
		await drainBridgeWorkerRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-130',
				),
			scheduledDrains,
			startIndex: 0,
		});

		const pierreJobs = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' &&
			postedMessage.message.job.itemId === 'item-130'
				? [postedMessage.message.job]
				: [],
		);
		expect(pierreJobs).toHaveLength(1);
		expect(pierreJobs[0]?.itemId).toBe('item-130');
		expect(pierreJobs[0]?.contentHash).toContain('generation-6');
	});

	test('newer certified Review bank supplies selected content without an older continuation', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const sourceRows = Array.from({ length: 130 }, (_unused, index) => ({
			id: `item-${index + 1}`,
			parentId: null,
			index,
		}));
		const sourceSemantics = sourceRows.map((row) => makeRenderSemantics({ itemId: row.id }));
		const staleContentItems = sourceRows.map((row) =>
			row.id === 'item-130'
				? {
						...makeWorkerReviewContentMetadata({ itemId: row.id }),
						availableContentRoles: [],
					}
				: makeWorkerReviewContentMetadata({ itemId: row.id }),
		);
		const freshContentItems = sourceRows.map((row) =>
			makeWorkerReviewContentMetadata({ itemId: row.id }),
		);
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			createSequence: createBridgeWorkerSequenceCounter(951),
			openReviewContent: openReviewContentFromDescriptorMap,
			productTransport: reviewProductSource.productTransport,
			pump: createWorkerContentPreparationPump({
				maxSliceMs: 8,
				now: () => clockMs,
			}),
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'newer-source-reset');

		reviewProductSource.publishSource(
			{
				contentItems: staleContentItems,
				contentRequestDescriptors: sourceRows.flatMap((row) => [
					makeContentRequestDescriptor({
						generation: 6,
						itemId: row.id,
						role: 'base',
						text: `stale base ${row.id}\n`,
					}),
					makeContentRequestDescriptor({
						generation: 6,
						itemId: row.id,
						role: 'head',
						text: `stale head ${row.id}\n`,
					}),
				]),
				renderSemantics: sourceSemantics,
				rows: sourceRows,
			},
			6,
		);
		await flushBridgeWorkerRuntimeContinuations();
		reviewProductSource.publishSource(
			{
				contentItems: freshContentItems,
				contentRequestDescriptors: sourceRows.flatMap((row) => [
					makeContentRequestDescriptor({
						generation: 7,
						itemId: row.id,
						role: 'base',
						text: `fresh base ${row.id}\n`,
					}),
					makeContentRequestDescriptor({
						generation: 7,
						itemId: row.id,
						role: 'head',
						text: `fresh head ${row.id}\n`,
					}),
				]),
				renderSemantics: sourceSemantics,
				rows: sourceRows,
			},
			7,
		);
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select-after-overlap',
				epoch: 8,
				surface: 'review',
				selectedItemId: 'item-130',
				selectedSource: 'user',
			}),
		);
		await drainBridgeWorkerRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-130',
				),
			scheduledDrains,
			startIndex: 0,
		});

		const pierreJobs = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' &&
			postedMessage.message.job.itemId === 'item-130'
				? [postedMessage.message.job]
				: [],
		);
		expect(pierreJobs).toHaveLength(1);
		expect(pierreJobs[0]?.itemId).toBe('item-130');
		expect(pierreJobs[0]?.contentHash).toContain('generation-7');
	});

	test('later source reset chunk prepares selected demand that began without metadata', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const sourceRows = Array.from({ length: 130 }, (_unused, index) => ({
			id: `item-${index + 1}`,
			parentId: null,
			index,
		}));
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			createSequence: createBridgeWorkerSequenceCounter(971),
			openReviewContent: openReviewContentFromDescriptorMap,
			productTransport: reviewProductSource.productTransport,
			pump: createWorkerContentPreparationPump({
				maxSliceMs: 8,
				now: () => clockMs,
			}),
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'late-source-reset-chunk');

		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select-before-source-reset',
				epoch: 7,
				surface: 'review',
				selectedItemId: 'item-130',
				selectedSource: 'user',
			}),
		);
		reviewProductSource.publishSource(
			{
				contentItems: sourceRows.map((row) => makeWorkerReviewContentMetadata({ itemId: row.id })),
				contentRequestDescriptors: sourceRows.flatMap((row) => [
					makeContentRequestDescriptor({
						generation: 8,
						itemId: row.id,
						role: 'base',
						text: `base ${row.id}\n`,
					}),
					makeContentRequestDescriptor({
						generation: 8,
						itemId: row.id,
						role: 'head',
						text: `head ${row.id}\n`,
					}),
				]),
				renderSemantics: sourceRows.map((row) => makeRenderSemantics({ itemId: row.id })),
				rows: sourceRows,
			},
			8,
		);
		await flushBridgeWorkerRuntimeContinuations();
		await drainBridgeWorkerRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-130',
				),
			scheduledDrains,
			startIndex: 0,
		});

		expect(
			postedMessages.some(
				(postedMessage) =>
					postedMessage.message.kind === 'reviewPierreRenderJob' &&
					postedMessage.message.job.itemId === 'item-130',
			),
		).toBe(true);
		expect(
			postedMessages.some(
				(postedMessage) =>
					postedMessage.message.kind === 'reviewRenderPatch' &&
					postedMessage.message.patches.some(
						(patch) =>
							patch.slice === 'contentAvailability' &&
							patch.operation === 'upsert' &&
							patch.itemId === 'item-130' &&
							patch.payload.state === 'ready',
					),
			),
		).toBe(true);
	});

	test('source rollover re-demands already-ready selected content outside the viewport', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			createSequence: createBridgeWorkerSequenceCounter(976),
			openReviewContent: openReviewContentFromDescriptorMap,
			productTransport: reviewProductSource.productTransport,
			pump: createWorkerContentPreparationPump({
				maxSliceMs: 8,
				now: () => clockMs,
			}),
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'source-rollover');
		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						generation: 7,
						itemId: 'item-1',
						role: 'base',
						text: 'generation 7 base\n',
					}),
					makeContentRequestDescriptor({
						generation: 7,
						itemId: 'item-1',
						role: 'head',
						text: 'generation 7 head\n',
					}),
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			7,
		);
		await flushBridgeWorkerRuntimeContinuations();

		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select-generation-7',
				epoch: 7,
				surface: 'review',
				selectedItemId: 'item-1',
				selectedSource: 'user',
			}),
		);
		await drainBridgeWorkerRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.filter((message) => message.message.kind === 'reviewPierreRenderJob')
					.length === 1,
			scheduledDrains,
			startIndex: 0,
		});
		queueLatestReviewPublication(dispatch, postedMessages, 'selected-before-source-rollover');
		await flushBridgeWorkerRuntimeContinuations();
		const rolloverDrainStartIndex = scheduledDrains.length;

		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						generation: 8,
						itemId: 'item-1',
						role: 'base',
						text: 'generation 8 base\n',
					}),
					makeContentRequestDescriptor({
						generation: 8,
						itemId: 'item-1',
						role: 'head',
						text: 'generation 8 head\n',
					}),
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			8,
		);
		await flushBridgeWorkerRuntimeContinuations();
		await drainBridgeWorkerRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.filter((message) => message.message.kind === 'reviewPierreRenderJob')
					.length === 2,
			scheduledDrains,
			startIndex: rolloverDrainStartIndex,
		});

		const pierreJobs = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' ? [postedMessage.message.job] : [],
		);
		expect(pierreJobs).toHaveLength(2);
		expect(pierreJobs[1]?.contentHash).toContain('generation-8');
		expect(
			postedMessages.some(
				(postedMessage) =>
					postedMessage.message.kind === 'reviewRenderPatch' &&
					postedMessage.message.workerDerivationEpoch === 1 &&
					postedMessage.message.patches.some(
						(patch) =>
							patch.slice === 'contentAvailability' &&
							patch.operation === 'upsert' &&
							patch.itemId === 'item-1' &&
							patch.payload.state === 'ready',
					),
			),
		).toBe(true);
	});

	test('later source reset chunks schedule visible demand for newly eligible visible rows', async () => {
		const clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const sourceRows = Array.from({ length: 130 }, (_unused, index) => ({
			id: `item-${index + 1}`,
			parentId: null,
			index,
		}));
		const sourceContentItems = sourceRows.map((row) =>
			makeWorkerReviewContentMetadata({ itemId: row.id }),
		);
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			createSequence: createBridgeWorkerSequenceCounter(981),
			openReviewContent: openReviewContentFromDescriptorMap,
			productTransport: reviewProductSource.productTransport,
			pump: createWorkerContentPreparationPump({
				maxSliceMs: 8,
				now: () => clockMs,
			}),
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'late-visible-source-row');
		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						generation: 4,
						itemId: 'item-1',
						role: 'base',
						text: 'old base item-1\n',
					}),
					makeContentRequestDescriptor({
						generation: 4,
						itemId: 'item-1',
						role: 'head',
						text: 'old head item-1\n',
					}),
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			4,
		);
		await flushBridgeWorkerRuntimeContinuations();
		postedMessages.length = 0;

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-visible-before-late-source-row',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1', 'item-130'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 129,
				phase: 'settled',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(scheduledDrains).toHaveLength(1);

		reviewProductSource.publishSource(
			{
				contentItems: sourceContentItems,
				contentRequestDescriptors: sourceRows.flatMap((row) => [
					makeContentRequestDescriptor({
						generation: 6,
						itemId: row.id,
						role: 'base',
						text: `fresh base ${row.id}\n`,
					}),
					makeContentRequestDescriptor({
						generation: 6,
						itemId: row.id,
						role: 'head',
						text: `fresh head ${row.id}\n`,
					}),
				]),
				renderSemantics: sourceRows.map((row) => makeRenderSemantics({ itemId: row.id })),
				rows: sourceRows,
			},
			6,
		);
		await flushBridgeWorkerRuntimeContinuations();
		await drainBridgeWorkerRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-130',
				),
			scheduledDrains,
			startIndex: 0,
		});

		const pierreJobItemIds = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob'
				? [postedMessage.message.job.itemId]
				: [],
		);
		expect(pierreJobItemIds).toContain('item-1');
		expect(pierreJobItemIds).toContain('item-130');
	});

	test('schedules selected Review continuation before awaiting its completion', async () => {
		let clockMs = 0;
		let advanceClockPerRead = false;
		let createSequence = createBridgeWorkerSequenceCounter(41);
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			createSequence: (): number => createSequence(),
			openReviewContent: openReviewContentFromDescriptorMap,
			productTransport: reviewProductSource.productTransport,
			pump: createWorkerContentPreparationPump({
				maxSliceMs: 8,
				now: () => {
					const currentClockMs = clockMs;
					if (advanceClockPerRead) clockMs += 3;
					return currentClockMs;
				},
			}),
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'yielded-selected-preparation');
		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata()],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({ role: 'base', text: 'base body' }),
					makeContentRequestDescriptor({ role: 'head', text: 'head body' }),
				],
				renderSemantics: [makeRenderSemantics()],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			6,
		);
		await flushBridgeWorkerRuntimeContinuations();
		postedMessages.length = 0;
		createSequence = createBridgeWorkerSequenceCounter(41);

		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select',
				epoch: 7,
				surface: 'review',
				selectedItemId: 'item-1',
				selectedSource: 'user',
			}),
		);

		expect(scheduledDrains).toHaveLength(1);
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'slicePatch',
			'health',
		]);
		expect(postedMessages[0]?.transferList).toBeUndefined();
		expect(postedMessages[1]?.transferList).toBeUndefined();
		advanceClockPerRead = true;
		const firstDrainCompletion = assertBridgeCommWorkerPreparationDrain(scheduledDrains[0])();
		advanceClockPerRead = false;
		await flushBridgeWorkerRuntimeContinuations();
		const continuationScheduledBeforeAwait = scheduledDrains.length === 2;
		const continuationDrain = assertBridgeCommWorkerPreparationDrain(scheduledDrains[1]);
		const continuationDrainResult = await continuationDrain();
		const firstDrainResult = await firstDrainCompletion;
		const publishedReviewJob = postedMessages.find(
			({ message }) => message.kind === 'reviewPierreRenderJob' && message.job.itemId === 'item-1',
		)?.message;
		if (publishedReviewJob?.kind !== 'reviewPierreRenderJob') {
			throw new Error('Expected the selected Review render job.');
		}

		expect(continuationScheduledBeforeAwait).toBe(true);
		expect(firstDrainResult.completedIds).toEqual([]);
		expect(firstDrainResult.yielded).toBe(false);
		expect(continuationDrainResult.completedIds).toEqual([
			`review-content-ready:item-1:review-ledger:item-1:${publishedReviewJob.renderReceiptIdentity.publicationSequence}`,
		]);
		expect(continuationDrainResult.yielded).toBe(false);
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'slicePatch',
			'health',
			'reviewPierreRenderJob',
			'reviewRenderPatch',
		]);
		expect(postedMessages[2]?.transferList).toEqual([]);
		expect(postedMessages[2]?.message).toMatchObject({
			kind: 'reviewPierreRenderJob',
			job: {
				itemId: 'item-1',
				renderKind: 'reviewDiff',
				payload: {
					kind: 'codeViewDiffItem',
				},
			},
		});
		const pierreJobMessage = postedMessages[2]?.message;
		if (pierreJobMessage?.kind !== 'reviewPierreRenderJob') {
			throw new Error('Expected Pierre render job message.');
		}
		expect(pierreJobMessage.transferDescriptors).toEqual([
			{
				messageKind: 'reviewPierreRenderJob',
				fieldPath: ['job', 'payload'],
				byteLength: pierreJobMessage.job.payloadByteLength,
				mode: 'clone',
			},
		]);
		expect(postedMessages[3]?.message).toMatchObject({
			kind: 'reviewRenderPatch',
			publicationSequence: publishedReviewJob.renderReceiptIdentity.publicationSequence,
			workerDerivationEpoch: 1,
			patches: [
				{
					slice: 'rowPaint',
					operation: 'upsert',
					itemId: 'item-1',
				},
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'item-1',
					payload: { state: 'ready' },
				},
			],
		});
	});

	test('applies source update before first select when the runtime boots empty', async () => {
		let createSequence = createBridgeWorkerSequenceCounter(11);
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			createSequence: (): number => createSequence(),
			productTransport: reviewProductSource.productTransport,
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'empty-runtime-source-update');
		await flushBridgeWorkerRuntimeContinuations();
		postedMessages.length = 0;

		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata()],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({ role: 'base', text: 'base body' }),
					makeContentRequestDescriptor({ role: 'head', text: 'head body' }),
				],
				renderSemantics: [makeRenderSemantics()],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			1,
		);
		await flushBridgeWorkerRuntimeContinuations();
		createSequence = createBridgeWorkerSequenceCounter(11);
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select',
				epoch: 2,
				surface: 'review',
				selectedItemId: 'item-1',
				selectedSource: 'user',
			}),
		);

		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'reviewCandidateStarted',
			'reviewDisplayPatch',
			'reviewCandidateReady',
			'fileDisplayPatch',
			'slicePatch',
			'health',
		]);
		const selectionPatch = postedMessages.find(
			({ message }) => message.kind === 'slicePatch',
		)?.message;
		expect(selectionPatch).toMatchObject({
			kind: 'slicePatch',
			epoch: 2,
			sequence: 11,
			patches: [
				{
					slice: 'selection',
					operation: 'upsert',
					payload: { selectedItemId: 'item-1' },
				},
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'item-1',
					payload: { state: 'loading' },
				},
			],
		});
		expect(scheduledDrains).toHaveLength(1);
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

function unexpectedEOFReviewContentStream(
	descriptorId: string,
): BridgeProductContentStream<'review.content'> {
	return {
		contentKind: 'review.content',
		contentRequestId: `unexpected-eof-${descriptorId}`,
		frames: emptyReviewContentFrames(),
		terminal: Promise.resolve({
			code: 'internal',
			contentKind: 'review.content',
			descriptorId,
			kind: 'error',
			retryable: true,
			safeMessage: 'Unexpected EOF while reading Review content.',
		}),
	};
}

async function* emptyReviewContentFrames(): AsyncIterable<never> {}

async function waitBridgeWorkerRuntimeTaskBoundary(): Promise<void> {
	await new Promise<void>((resolve) => {
		setTimeout(resolve, 0);
	});
}

async function drainBridgeWorkerRuntimeUntil(props: {
	readonly hasExpectedEvent: () => boolean;
	readonly scheduledDrains: readonly BridgeCommWorkerPreparationDrain[];
	readonly startIndex: number;
}): Promise<void> {
	return drainBridgeWorkerRuntimeUntilAttempt({ ...props, attempt: 0 });
}

async function drainBridgeWorkerRuntimeUntilAttempt(props: {
	readonly attempt: number;
	readonly hasExpectedEvent: () => boolean;
	readonly scheduledDrains: readonly BridgeCommWorkerPreparationDrain[];
	readonly startIndex: number;
}): Promise<void> {
	if (props.hasExpectedEvent() || props.attempt >= 64) {
		return;
	}
	await flushBridgeWorkerRuntimeContinuations();
	if (props.startIndex >= props.scheduledDrains.length) {
		await waitBridgeWorkerRuntimeTaskBoundary();
		return drainBridgeWorkerRuntimeUntilAttempt({
			...props,
			attempt: props.attempt + 1,
		});
	}
	void assertBridgeCommWorkerPreparationDrain(props.scheduledDrains[props.startIndex])();
	return drainBridgeWorkerRuntimeUntilAttempt({
		...props,
		attempt: props.attempt + 1,
		startIndex: props.startIndex + 1,
	});
}

import { afterEach, describe, expect, test, vi } from 'vitest';

import {
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import { registerTestBridgeCommWorkerRuntimePortProtocol as registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.fixture.test-support.js';
import { type BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerReviewViewerMode,
	assertBridgeCommWorkerPreparationDrain,
	createBridgeWorkerSequenceCounter,
	createBridgeCommWorkerReviewProductTestSource as makeReviewProductTestSource,
	createRecordingBridgeCommWorkerPort,
	makeContentRequestDescriptor,
	makeRenderSemantics,
	makeWorkerReviewContentMetadata,
	openReviewContentFromDescriptorMap,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';
import {
	createReviewPreparationObservations as makeReviewPreparationObservations,
	cleanupReviewPreparationFixtures,
	type ReviewPreparationObservations,
	driveReviewPreparationUntil,
	requirePreparationContinuationBeforeDrainCompletion,
	queueLatestReviewPublication,
	unexpectedEOFReviewContentStream,
} from './comm-runtime-protocol.review-preparation.test-support.js';
import { BridgeProductTestFactRecorder } from './test-fixtures/bridge-product-test-fact-recorder.js';

const activeSources: ReturnType<typeof makeReviewProductTestSource>[] = [];
const activeObservations: ReviewPreparationObservations[] = [];

afterEach(async (): Promise<void> => {
	await cleanupReviewPreparationFixtures({
		sources: activeSources,
		observations: activeObservations,
		restore: (): void => {
			activeSources.length = 0;
			activeObservations.length = 0;
			try {
				vi.restoreAllMocks();
			} finally {
				vi.useRealTimers();
			}
		},
	});
});

function createBridgeCommWorkerReviewProductTestSource(): ReturnType<
	typeof makeReviewProductTestSource
> {
	const source = makeReviewProductTestSource();
	activeSources.push(source);
	return source;
}

function createReviewPreparationObservations(): ReviewPreparationObservations {
	const observations = makeReviewPreparationObservations();
	activeObservations.push(observations);
	return observations;
}

describe('Bridge comm worker runtime protocol Review preparation', () => {
	test('reissues selected Review preparation once after unexpected EOF', async () => {
		vi.useFakeTimers();
		const observations = createReviewPreparationObservations();
		let retryWasRegistered = false;
		const retryDeadlineFacts = new BridgeProductTestFactRecorder<'registered' | 'fired'>();
		const scheduleTimer = globalThis.setTimeout;
		const timerSpy = vi
			.spyOn(globalThis, 'setTimeout')
			.mockImplementation((callback, delay, ...arguments_) => {
				if (delay !== 500) return scheduleTimer(callback, delay, ...arguments_);
				retryWasRegistered = true;
				retryDeadlineFacts.record('registered');
				observations.retryDeadlineRegistered();
				return scheduleTimer((): void => {
					callback(...arguments_);
					retryDeadlineFacts.record('fired');
				}, delay);
			});
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort({
			beforePostMessage: observations.beforePostMessage,
		});
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();
		let openCount = 0;
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			openReviewContent: (descriptor, abortSignal) => {
				openCount += 1;
				observations.contentOpened(descriptor.descriptorId);
				return openCount <= 2
					? unexpectedEOFReviewContentStream(descriptor.descriptorId)
					: openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			productTransport: reviewProductSource.productTransport,
			schedulePreparationDrain: (drain): void => {
				observations.schedule(drain);
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
		await reviewProductSource.waitForSourceInstallation();
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 1,
				requestId: 'selected-unexpected-eof',
				selectedItemId: 'item-1',
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		await driveReviewPreparationUntil({
			label: 'reissues selected Review preparation once after unexpected EOF',
			hasExpectedEvent: (): boolean => retryWasRegistered,
			observations,
			startIndex: 0,
		});
		await retryDeadlineFacts.waitFor((fact): boolean => fact === 'registered');
		expect(openCount).toBe(2);
		const retryDrainStartIndex = observations.scheduledDrains.length;
		await vi.advanceTimersByTimeAsync(499);
		expect(openCount).toBe(2);
		await vi.advanceTimersByTimeAsync(1);
		await retryDeadlineFacts.waitFor((fact): boolean => fact === 'fired');
		await driveReviewPreparationUntil({
			label: 'reissues selected Review preparation once after unexpected EOF',
			hasExpectedEvent: (): boolean =>
				postedMessages.some(({ message }): boolean => message.kind === 'reviewPierreRenderJob'),
			observations,
			startIndex: retryDrainStartIndex,
		});
		expect(openCount).toBe(4);
		reviewProductSource.close();
		timerSpy.mockRestore();
		retryDeadlineFacts.close(new Error('Review retry clock observation closed.'));
	});

	test('selects the last item after an atomic 130-row Review bank', async () => {
		const clockMs = 0;
		const observations = createReviewPreparationObservations();
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort({
			beforePostMessage: observations.beforePostMessage,
		});
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
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
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
				observations.schedule(drain);
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
		await reviewProductSource.waitForSourceInstallation();

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
		await driveReviewPreparationUntil({
			label: 'selects the last item after an atomic 130-row Review bank',
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-130',
				),
			observations,
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
		const observations = createReviewPreparationObservations();
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort({
			beforePostMessage: observations.beforePostMessage,
		});
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
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
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
				observations.schedule(drain);
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
		await reviewProductSource.waitForSourceInstallation();
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
		await reviewProductSource.waitForSourceInstallation();
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select-after-overlap',
				epoch: 8,
				surface: 'review',
				selectedItemId: 'item-130',
				selectedSource: 'user',
			}),
		);
		await driveReviewPreparationUntil({
			label: 'newer certified Review bank supplies selected content without an older continuation',
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-130',
				),
			observations,
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
		const observations = createReviewPreparationObservations();
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort({
			beforePostMessage: observations.beforePostMessage,
		});
		const sourceRows = Array.from({ length: 130 }, (_unused, index) => ({
			id: `item-${index + 1}`,
			parentId: null,
			index,
		}));
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
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
				observations.schedule(drain);
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
		await reviewProductSource.waitForSourceInstallation();
		await driveReviewPreparationUntil({
			label: 'later source reset chunk prepares selected demand that began without metadata',
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-130',
				),
			observations,
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
		const observations = createReviewPreparationObservations();
		const scheduledDrains = observations.scheduledDrains;
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort({
			beforePostMessage: observations.beforePostMessage,
		});
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
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
				observations.schedule(drain);
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
		await reviewProductSource.waitForSourceInstallation();

		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select-generation-7',
				epoch: 7,
				surface: 'review',
				selectedItemId: 'item-1',
				selectedSource: 'user',
			}),
		);
		await driveReviewPreparationUntil({
			label: 'source rollover re-demands already-ready selected content outside the viewport',
			hasExpectedEvent: () =>
				postedMessages.filter((message) => message.message.kind === 'reviewPierreRenderJob')
					.length === 1,
			observations,
			startIndex: 0,
		});
		queueLatestReviewPublication(dispatch, postedMessages, 'selected-before-source-rollover');
		// Render-disposition admission is synchronous; no source was published here.
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
		await reviewProductSource.waitForSourceInstallation();
		await driveReviewPreparationUntil({
			label: 'source rollover re-demands already-ready selected content outside the viewport',
			hasExpectedEvent: () =>
				postedMessages.filter((message) => message.message.kind === 'reviewPierreRenderJob')
					.length === 2,
			observations,
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
		const observations = createReviewPreparationObservations();
		const scheduledDrains = observations.scheduledDrains;
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort({
			beforePostMessage: observations.beforePostMessage,
		});
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
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
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
				observations.schedule(drain);
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
		await reviewProductSource.waitForSourceInstallation();
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
		// Viewport admission is synchronous; this stimulus does not install a source.
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
		await reviewProductSource.waitForSourceInstallation();
		await driveReviewPreparationUntil({
			label: 'later source reset chunks schedule visible demand for newly eligible visible rows',
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-130',
				),
			observations,
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
		let firstDrainSettled = false;
		let settledAtContinuationSchedule: boolean | undefined;
		let clockMs = 0;
		let advanceClockPerRead = false;
		let createSequence = createBridgeWorkerSequenceCounter(41);
		const observations = createReviewPreparationObservations();
		const scheduledDrains = observations.scheduledDrains;
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort({
			beforePostMessage: observations.beforePostMessage,
		});
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			expectedRetainedRenderWakes: {
				count: 1,
				reason:
					'This worker-content case retains its Review publication or queued position without a terminal renderer receipt.',
			},
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
				if (scheduledDrains.length === 1) settledAtContinuationSchedule = firstDrainSettled;
				observations.schedule(drain);
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
		await reviewProductSource.waitForSourceInstallation();
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
		const firstDrainObservation = firstDrainCompletion.then(
			(): void => {
				firstDrainSettled = true;
			},
			(error: unknown): void => {
				observations.close(error instanceof Error ? error : new Error(String(error)));
			},
		);
		advanceClockPerRead = false;
		await requirePreparationContinuationBeforeDrainCompletion({
			firstDrainCompletion,
			observations,
			isContinuationScheduled: (fact): boolean =>
				fact.kind === 'drainScheduled' && fact.index === 1,
		});

		const continuationDrain = assertBridgeCommWorkerPreparationDrain(scheduledDrains[1]);
		const continuationDrainResult = await continuationDrain();
		const firstDrainResult = await firstDrainCompletion;
		await firstDrainObservation;
		const publishedReviewJob = postedMessages.find(
			({ message }) => message.kind === 'reviewPierreRenderJob' && message.job.itemId === 'item-1',
		)?.message;
		if (publishedReviewJob?.kind !== 'reviewPierreRenderJob') {
			throw new Error('Expected the selected Review render job.');
		}

		expect(
			settledAtContinuationSchedule,
			'Continuation must be scheduled before first drain settles.',
		).toBe(false);
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
		const observations = createReviewPreparationObservations();
		const scheduledDrains = observations.scheduledDrains;
		const { dispatch, postedMessages, waitForMessage } = createRecordingBridgeCommWorkerPort({
			beforePostMessage: observations.beforePostMessage,
		});
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
				observations.schedule(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'empty-runtime-source-update');
		await waitForMessage(
			(message): boolean =>
				message.kind === 'health' &&
				message.requestId === 'request-review-mode-empty-runtime-source-update',
		);
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
		await reviewProductSource.waitForSourceInstallation();
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

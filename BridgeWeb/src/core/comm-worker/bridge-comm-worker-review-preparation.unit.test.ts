import { describe, expect, test } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import type { BridgeCommWorkerPort } from './bridge-comm-worker-entry.js';
import { makeReviewPublicationIdentity } from './bridge-comm-worker-entry.test-support.js';
import { encodeBridgeWorkerSelectCommand } from './bridge-comm-worker-protocol.js';
import { enqueueSelectedBridgeWorkerReviewContentReadyPreparation } from './bridge-comm-worker-review-preparation.js';
import { registerTestBridgeCommWorkerRuntimePortProtocol as registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.fixture.test-support.js';
import { type BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerReviewViewerMode,
	assertBridgeCommWorkerPreparationDrain,
	createBridgeWorkerSequenceCounter,
	createBridgeCommWorkerReviewProductTestSource,
	createDeferredReviewContentStream,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
	makeContentRequestDescriptor,
	openReviewContentFromDescriptorMap,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { createBridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import type { BridgeProductContentStream } from './bridge-product-transport-contract.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';
import type {
	BridgeWorkerReviewContentMetadata,
	BridgeWorkerReviewContentRequestDescriptor,
	BridgeWorkerReviewRenderSemantics,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import { createSharedBridgeWorkerReviewContentResourceFetch } from './bridge-worker-review-content-fetch.js';

interface PostedBridgeWorkerPreparationMessage {
	readonly message: BridgeWorkerServerToMainMessage;
	readonly transferList: readonly Transferable[] | undefined;
}

describe('Bridge comm worker review preparation', () => {
	test('coalesces update and select into one Review Pierre job', async () => {
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
			createSequence: createBridgeWorkerSequenceCounter(1_001),
			openReviewContent: openReviewContentFromDescriptorMap,
			productTransport: reviewProductSource.productTransport,
			pump: createWorkerContentPreparationPump({
				maxSliceMs: 8,
				now: () => 0,
			}),
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'coalesced-source-rollover');

		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata()],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({ role: 'base', text: 'base body\n' }),
					makeContentRequestDescriptor({ role: 'head', text: 'head body\n' }),
				],
				renderSemantics: [makeRenderSemantics()],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			7,
		);
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select-during-rollover',
				epoch: 7,
				surface: 'review',
				selectedItemId: 'item-1',
				selectedSource: 'user',
			}),
		);

		let nextDrainIndex = 0;
		let settledPassCount = 0;
		const drainCompletions: Array<ReturnType<BridgeCommWorkerPreparationDrain>> = [];
		for (let attempt = 0; attempt < 20 && settledPassCount < 2; attempt += 1) {
			// oxlint-disable-next-line no-await-in-loop -- Each bounded pass exposes drains scheduled by the prior pass.
			await flushBridgeWorkerRuntimeContinuations();
			const nextDrain = scheduledDrains[nextDrainIndex];
			if (nextDrain === undefined) {
				settledPassCount += 1;
				continue;
			}
			settledPassCount = 0;
			nextDrainIndex += 1;
			drainCompletions.push(assertBridgeCommWorkerPreparationDrain(nextDrain)());
		}
		await Promise.all(drainCompletions);

		const reviewPierreJobs = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' ? [postedMessage.message.job] : [],
		);
		expect(
			reviewPierreJobs,
			'one source rollover plus one select must publish one Review Pierre job',
		).toHaveLength(1);
		expect(reviewPierreJobs[0]?.itemId).toBe('item-1');
	});

	test('enqueues selected review content-ready dispatch as selected-ranked preparation work', async () => {
		let clockMs = 0;
		const executionOrder: string[] = [];
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 1,
			now: () => clockMs,
		});
		pump.enqueue({
			id: 'background-visible-review-item',
			rank: 'background',
			runSlice: () => {
				executionOrder.push('background');
				clockMs += 2;
				return { complete: false };
			},
		});
		const store = createBridgeCommWorkerStore({
			surface: 'review',
			contentItems: [makeWorkerReviewContentMetadata()],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'item-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerReviewContentReadyPreparation({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			contentRequestDescriptors: [
				makeContentRequestDescriptor({ role: 'base', text: 'base content\n' }),
				makeContentRequestDescriptor({ role: 'head', text: 'head content\n' }),
			],
			epoch: 7,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			workerDerivationEpoch: 7,
			openContent: (descriptor, abortSignal): BridgeProductContentStream<'review.content'> => {
				executionOrder.push('selected-fetch');
				return openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			itemId: 'item-1',
			port: makePostedMessagePort(postedMessages),
			pump,
			renderSemantics: [makeRenderSemantics()],
			sequence: 12,
			store,
		});

		expect(postedMessages).toEqual([]);
		const runResult = pump.runUntilBudget();
		await flushBridgeWorkerPreparationContinuations();
		const completionCompletedIds: string[] = [];
		for (let drainIndex = 0; drainIndex < 16 && postedMessages.length === 0; drainIndex += 1) {
			completionCompletedIds.push(...pump.runUntilBudget().completedIds);
		}
		await preparation.completion;

		expect(runResult.completedIds).toEqual([]);
		expect(runResult.yielded).toBe(true);
		expect(completionCompletedIds).toContain(preparation.workId);
		expect(executionOrder.slice(0, 2)).toEqual(['selected-fetch', 'selected-fetch']);
		expect(executionOrder.filter((entry) => entry === 'background').length).toBeGreaterThanOrEqual(
			2,
		);
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'reviewPierreRenderJob',
			'reviewRenderPatch',
		]);
	});

	test('keeps post-fetch render-job preparation inside a pump continuation', async () => {
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		const deferredContent = [
			{
				descriptor: makeContentRequestDescriptor({ role: 'base', text: 'base content\n' }),
				text: 'base content\n',
			},
			{
				descriptor: makeContentRequestDescriptor({ role: 'head', text: 'head content\n' }),
				text: 'head content\n',
			},
		];
		const contentStreams = deferredContent.map(({ descriptor, text }) => ({
			descriptor,
			stream: createDeferredReviewContentStream(descriptor),
			text,
		}));
		const allContentStreams = [...contentStreams];
		const openedDescriptorRoles: BridgeWorkerReviewContentRequestDescriptor['role'][] = [];
		let drainRequestCount = 0;
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createBridgeCommWorkerStore({
			surface: 'review',
			contentItems: [makeWorkerReviewContentMetadata()],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'item-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerReviewContentReadyPreparation({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			contentRequestDescriptors: deferredContent.map(({ descriptor }) => descriptor),
			epoch: 7,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			workerDerivationEpoch: 7,
			openContent: (descriptor): BridgeProductContentStream<'review.content'> => {
				openedDescriptorRoles.push(descriptor.role);
				const contentStream = contentStreams.shift();
				if (contentStream === undefined) {
					throw new Error(`Unexpected Review content descriptor ${descriptor.descriptorId}.`);
				}
				if (contentStream.descriptor.descriptorId !== descriptor.descriptorId) {
					throw new Error(`Unexpected Review content descriptor ${descriptor.descriptorId}.`);
				}
				return contentStream.stream.stream;
			},
			itemId: 'item-1',
			port: makePostedMessagePort(postedMessages),
			pump,
			renderSemantics: [makeRenderSemantics()],
			requestPreparationDrain: () => {
				drainRequestCount += 1;
			},
			sequence: 12,
			store,
		});

		const firstRun = pump.runUntilBudget();

		expect(firstRun.completedIds).toEqual([]);
		expect(openedDescriptorRoles).toEqual(['base', 'head']);
		expect(postedMessages).toEqual([]);

		for (const contentStream of allContentStreams) {
			contentStream.stream.resolve(contentStream.text);
		}
		await flushBridgeWorkerPreparationContinuations();

		expect(postedMessages).toEqual([]);
		expect(drainRequestCount).toBe(1);
		expect(pump.getPendingWorkIds()).toEqual([preparation.workId]);

		const secondRun = pump.runUntilBudget();
		await preparation.completion;

		expect(secondRun.completedIds).toEqual([preparation.workId]);
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'reviewPierreRenderJob',
			'reviewRenderPatch',
		]);
	});

	test('drops stale selected review preparation before publishing content messages', async () => {
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		const openedDescriptorRoles: BridgeWorkerReviewContentRequestDescriptor['role'][] = [];
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createBridgeCommWorkerStore({
			surface: 'review',
			contentItems: [
				makeWorkerReviewContentMetadata('item-1'),
				makeWorkerReviewContentMetadata('item-2'),
			],
			rows: [
				{ id: 'item-1', parentId: null, index: 0 },
				{ id: 'item-2', parentId: null, index: 1 },
			],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'item-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerReviewContentReadyPreparation({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			contentRequestDescriptors: [
				makeContentRequestDescriptor({ role: 'base', text: 'base content' }),
				makeContentRequestDescriptor({ role: 'head', text: 'head content' }),
			],
			epoch: 7,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			workerDerivationEpoch: 7,
			openContent: (descriptor, abortSignal): BridgeProductContentStream<'review.content'> => {
				openedDescriptorRoles.push(descriptor.role);
				store.actions.applySelectedFact({ epoch: 8, itemId: 'item-2' });
				return openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			itemId: 'item-1',
			port: makePostedMessagePort(postedMessages),
			pump,
			renderSemantics: [makeRenderSemantics()],
			sequence: 12,
			store,
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});

		const runResult = pump.runUntilBudget();
		await flushBridgeWorkerPreparationContinuations();
		const completionRunResult = pump.runUntilBudget();
		await preparation.completion;

		expect(runResult.completedIds).toEqual([]);
		expect(completionRunResult.completedIds).toEqual([preparation.workId]);
		expect(openedDescriptorRoles).toEqual(['base', 'head']);
		expect(telemetrySamples).toContainEqual(
			expect.objectContaining({
				name: 'performance.bridge.web.selected_content_dropped',
				durationMilliseconds: null,
				stringAttributes: expect.objectContaining({
					'agentstudio.bridge.drop_reason': 'stale_after_fetch',
					'agentstudio.bridge.phase': 'selected_content_dropped',
					'agentstudio.bridge.result': 'dropped',
					'agentstudio.bridge.viewer': 'review',
				}),
			}),
		);
		expect(postedMessages).toEqual([]);
	});

	test('records stale selected review preparation before fetch starts', async () => {
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		const openedDescriptorRoles: BridgeWorkerReviewContentRequestDescriptor['role'][] = [];
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createBridgeCommWorkerStore({
			surface: 'review',
			contentItems: [
				makeWorkerReviewContentMetadata('item-1'),
				makeWorkerReviewContentMetadata('item-2'),
			],
			rows: [
				{ id: 'item-1', parentId: null, index: 0 },
				{ id: 'item-2', parentId: null, index: 1 },
			],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'item-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerReviewContentReadyPreparation({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			contentRequestDescriptors: [
				makeContentRequestDescriptor({ role: 'base', text: 'base content' }),
				makeContentRequestDescriptor({ role: 'head', text: 'head content' }),
			],
			epoch: 7,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			workerDerivationEpoch: 7,
			openContent: (descriptor, abortSignal): BridgeProductContentStream<'review.content'> => {
				openedDescriptorRoles.push(descriptor.role);
				return openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			itemId: 'item-1',
			port: makePostedMessagePort(postedMessages),
			pump,
			renderSemantics: [makeRenderSemantics()],
			sequence: 12,
			store,
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		store.actions.applySelectedFact({ epoch: 8, itemId: 'item-2' });
		store.actions.takePendingSlicePatchEvent({ epoch: 8, sequence: 13 });

		const runResult = pump.runUntilBudget();
		await preparation.completion;

		expect(runResult.completedIds).toEqual([preparation.workId]);
		expect(openedDescriptorRoles).toEqual([]);
		expectSelectedContentDroppedTelemetry(telemetrySamples, 'stale_before_fetch');
		expect(postedMessages).toEqual([]);
	});

	test('records stale selected review preparation after fetch before publish', async () => {
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		const deferredContent = [
			{
				descriptor: makeContentRequestDescriptor({ role: 'base', text: 'base content' }),
				text: 'base content',
			},
			{
				descriptor: makeContentRequestDescriptor({ role: 'head', text: 'head content' }),
				text: 'head content',
			},
		];
		const contentStreams = deferredContent.map(({ descriptor, text }) => ({
			descriptor,
			stream: createDeferredReviewContentStream(descriptor),
			text,
		}));
		const allContentStreams = [...contentStreams];
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createBridgeCommWorkerStore({
			surface: 'review',
			contentItems: [
				makeWorkerReviewContentMetadata('item-1'),
				makeWorkerReviewContentMetadata('item-2'),
			],
			rows: [
				{ id: 'item-1', parentId: null, index: 0 },
				{ id: 'item-2', parentId: null, index: 1 },
			],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'item-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerReviewContentReadyPreparation({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			contentRequestDescriptors: deferredContent.map(({ descriptor }) => descriptor),
			epoch: 7,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			workerDerivationEpoch: 7,
			openContent: (descriptor): BridgeProductContentStream<'review.content'> => {
				const contentStream = contentStreams.shift();
				if (contentStream === undefined) {
					throw new Error('Unexpected Review content open.');
				}
				if (contentStream.descriptor.descriptorId !== descriptor.descriptorId) {
					throw new Error(`Unexpected Review content descriptor ${descriptor.descriptorId}.`);
				}
				return contentStream.stream.stream;
			},
			itemId: 'item-1',
			port: makePostedMessagePort(postedMessages),
			pump,
			renderSemantics: [makeRenderSemantics()],
			sequence: 12,
			store,
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});

		const firstRun = pump.runUntilBudget();
		for (const contentStream of allContentStreams) {
			contentStream.stream.resolve(contentStream.text);
		}
		await flushBridgeWorkerPreparationContinuations();
		store.actions.applySelectedFact({ epoch: 8, itemId: 'item-2' });
		store.actions.takePendingSlicePatchEvent({ epoch: 8, sequence: 13 });
		const secondRun = pump.runUntilBudget();
		await preparation.completion;

		expect(firstRun.completedIds).toEqual([]);
		expect(secondRun.completedIds).toEqual([preparation.workId]);
		expectSelectedContentDroppedTelemetry(telemetrySamples, 'stale_before_publish');
		expect(postedMessages).toEqual([]);
	});

	test('rejects preparation completion when post-fetch publish throws', async () => {
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createBridgeCommWorkerStore({
			surface: 'review',
			contentItems: [makeWorkerReviewContentMetadata()],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'item-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerReviewContentReadyPreparation({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 1,
				maxWindowLines: 50,
			},
			contentRequestDescriptors: [
				makeContentRequestDescriptor({ role: 'base', text: 'base content\n' }),
				makeContentRequestDescriptor({ role: 'head', text: 'head content\n' }),
			],
			epoch: 7,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			workerDerivationEpoch: 7,
			openContent: (descriptor, abortSignal): BridgeProductContentStream<'review.content'> => {
				return openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			itemId: 'item-1',
			port: makeThrowingPostedMessagePort(),
			pump,
			renderSemantics: [makeRenderSemantics()],
			sequence: 12,
			store,
		});
		const completionResult = preparation.completion.then(
			() => null,
			(error: unknown) => error,
		);

		pump.runUntilBudget();
		await flushBridgeWorkerPreparationContinuations();
		pump.runUntilBudget();

		await expect(completionResult).resolves.toBeInstanceOf(Error);
	});

	test('does not publish or apply real 18,000-line Review preparation after its 8 ms slice deadline and resumes bounded output', async () => {
		const totalLineCount = 18_000;
		const largeContent = `${Array.from(
			{ length: totalLineCount },
			(_, lineIndex) => `line-${lineIndex.toString().padStart(5, '0')}`,
		).join('\n')}\n`;
		const contentRequestDescriptors = [
			makeContentRequestDescriptor({ role: 'base', text: largeContent }),
			makeContentRequestDescriptor({ role: 'head', text: largeContent }),
		];
		const openedDescriptorRoles: BridgeWorkerReviewContentRequestDescriptor['role'][] = [];
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		let drainRequestCount = 0;
		let expireDeadlineOnNextSliceCheck = false;
		let deadlineSliceClockReadCount = 0;
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 8,
			now: () => {
				if (!expireDeadlineOnNextSliceCheck) return 0;
				deadlineSliceClockReadCount += 1;
				return deadlineSliceClockReadCount <= 3 ? 0 : 9;
			},
		});
		const store = createBridgeCommWorkerStore({
			surface: 'review',
			contentItems: [
				{
					...makeWorkerReviewContentMetadata(),
					contentLineCountsByRole: { base: totalLineCount, head: totalLineCount },
					sizeBytes: new TextEncoder().encode(largeContent).byteLength * 2,
				},
			],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'item-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });
		const preparation = enqueueSelectedBridgeWorkerReviewContentReadyPreparation({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			contentRequestDescriptors,
			epoch: 7,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			workerDerivationEpoch: 7,
			openContent: (descriptor, abortSignal): BridgeProductContentStream<'review.content'> => {
				openedDescriptorRoles.push(descriptor.role);
				return openReviewContentFromDescriptorMap(descriptor, abortSignal);
			},
			itemId: 'item-1',
			port: makePostedMessagePort(postedMessages),
			pump,
			renderSemantics: [
				{
					...makeRenderSemantics(),
					contentLineCountsByRole: { base: totalLineCount, head: totalLineCount },
				},
			],
			requestPreparationDrain: () => {
				drainRequestCount += 1;
			},
			sequence: 12,
			store,
		});

		const fetchRun = pump.runUntilBudget();
		await flushBridgeWorkerPreparationContinuations();

		expect(fetchRun).toEqual({ completedIds: [], yielded: false });
		expect(openedDescriptorRoles).toEqual(['base', 'head']);
		expect(drainRequestCount).toBe(1);
		expect(pump.getPendingWorkIds()).toEqual([preparation.workId]);
		expect(postedMessages).toEqual([]);

		expireDeadlineOnNextSliceCheck = true;
		deadlineSliceClockReadCount = 0;
		const expiredSliceRun = pump.runUntilBudget();

		expect(
			postedMessages,
			'expired Review preparation slice must not publish render or state messages',
		).toEqual([]);
		expect(store.getState().availabilityByItemId.get('item-1')).toBe('loading');
		expect(store.getState().paintReadyByItemId.has('item-1')).toBe(false);
		expect(expiredSliceRun).toEqual({ completedIds: [], yielded: true });
		expect(pump.getPendingWorkIds()).toEqual([preparation.workId]);

		preparation.pause();
		expect(pump.getPendingWorkIds()).toEqual([]);

		expireDeadlineOnNextSliceCheck = false;
		deadlineSliceClockReadCount = 0;
		preparation.resume();
		expect(pump.getPendingWorkIds()).toEqual([preparation.workId]);
		const publishRun = pump.runUntilBudget();
		await preparation.completion;

		expect(publishRun).toEqual({ completedIds: [preparation.workId], yielded: false });
		expect(openedDescriptorRoles).toEqual(['base', 'head']);
		expect(drainRequestCount).toBe(2);
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'reviewPierreRenderJob',
			'reviewRenderPatch',
		]);
		const renderJobMessage = postedMessages[0]?.message;
		if (renderJobMessage?.kind !== 'reviewPierreRenderJob') {
			throw new Error('Expected bounded Review Pierre render job publication.');
		}
		expect(renderJobMessage.job.window).toEqual({
			endLine: 50,
			startLine: 1,
			totalLineCount,
		});
		expect(renderJobMessage.job.windowLineCount).toBe(50);
		expect(renderJobMessage.job.payloadByteLength).toBeLessThan(
			new TextEncoder().encode(largeContent).byteLength * 2,
		);
		const publishedJSON = JSON.stringify(postedMessages);
		expect(publishedJSON).toContain('line-00049');
		expect(publishedJSON).not.toContain('line-00050');
		expect(publishedJSON).not.toContain('line-17999');
		expect(publishedJSON).not.toMatch(/rootSnapshot|allRows|rowById|"package"/iu);
	});

	test('terminally cancels staged Review preparation without publication or state residue', async () => {
		const deferredContent = [
			{
				descriptor: makeContentRequestDescriptor({ role: 'base', text: 'base content\n' }),
				text: 'base content\n',
			},
			{
				descriptor: makeContentRequestDescriptor({ role: 'head', text: 'head content\n' }),
				text: 'head content\n',
			},
		];
		const contentStreams = deferredContent.map(({ descriptor, text }) => ({
			descriptor,
			stream: createDeferredReviewContentStream(descriptor),
			text,
		}));
		const allContentStreams = [...contentStreams];
		const openedDescriptorRoles: BridgeWorkerReviewContentRequestDescriptor['role'][] = [];
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		let completionSettlementCount = 0;
		let drainRequestCount = 0;
		let clockMs = 0;
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 8,
			now: () => clockMs,
		});
		const store = createBridgeCommWorkerStore({
			surface: 'review',
			contentItems: [makeWorkerReviewContentMetadata()],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'item-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });
		const preparation = enqueueSelectedBridgeWorkerReviewContentReadyPreparation({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			contentRequestDescriptors: deferredContent.map(({ descriptor }) => descriptor),
			epoch: 7,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			workerDerivationEpoch: 7,
			openContent: (descriptor): BridgeProductContentStream<'review.content'> => {
				openedDescriptorRoles.push(descriptor.role);
				const contentStream = contentStreams.shift();
				if (contentStream === undefined) {
					throw new Error('Unexpected Review content open.');
				}
				if (contentStream.descriptor.descriptorId !== descriptor.descriptorId) {
					throw new Error(`Unexpected Review content descriptor ${descriptor.descriptorId}.`);
				}
				return contentStream.stream.stream;
			},
			itemId: 'item-1',
			port: makePostedMessagePort(postedMessages),
			pump,
			renderSemantics: [makeRenderSemantics()],
			requestPreparationDrain: () => {
				drainRequestCount += 1;
			},
			sequence: 12,
			store,
		});
		void preparation.completion.then(
			(): void => {
				completionSettlementCount += 1;
			},
			(): void => {
				completionSettlementCount += 1;
			},
		);

		const fetchRun = pump.runUntilBudget();
		for (const contentStream of allContentStreams) {
			contentStream.stream.resolve(contentStream.text);
		}
		await flushBridgeWorkerPreparationContinuations();
		pump.enqueue({
			id: 'cancellation-deadline-sentinel',
			rank: 'background',
			runSlice: () => {
				clockMs += 9;
				return { complete: true };
			},
		});
		const planningRun = pump.runUntilBudget();
		preparation.cancel();
		preparation.cancel();
		await flushBridgeWorkerPreparationContinuations();
		await preparation.completion;

		expect(fetchRun).toEqual({ completedIds: [], yielded: false });
		expect(planningRun.yielded).toBe(true);
		expect(openedDescriptorRoles).toEqual(['base', 'head']);
		expect(completionSettlementCount).toBe(1);
		expect(pump.getPendingWorkIds()).toEqual([]);
		expect(store.getState().availabilityByItemId.get('item-1')).toBe('loading');
		expect(store.getState().paintReadyByItemId.has('item-1')).toBe(false);
		preparation.resume();

		expect(completionSettlementCount).toBe(1);
		expect(drainRequestCount).toBe(1);
		expect(postedMessages).toEqual([]);
		expect(pump.getPendingWorkIds()).toEqual([]);
	});

	test('pauses pending Review response starts and resumes the same content streams', async () => {
		const deferredContent = [
			{
				descriptor: makeContentRequestDescriptor({ role: 'base', text: 'base content\n' }),
				text: 'base content\n',
			},
			{
				descriptor: makeContentRequestDescriptor({ role: 'head', text: 'head content\n' }),
				text: 'head content\n',
			},
		];
		let pauseBeforeStartCount = 0;
		let resumeBeforeStartCount = 0;
		const contentStreams = deferredContent.map(({ descriptor, text }) => {
			const deferredStream = createDeferredReviewContentStream(descriptor);
			return {
				deferredStream,
				descriptor,
				stream: {
					...deferredStream.stream,
					responseStartControl: {
						pauseBeforeStart: (): void => {
							pauseBeforeStartCount += 1;
						},
						resumeBeforeStart: (): void => {
							resumeBeforeStartCount += 1;
						},
					},
				},
				text,
			};
		});
		const remainingContentStreams = [...contentStreams];
		const fetchReviewContentResource = createSharedBridgeWorkerReviewContentResourceFetch({
			openContent: (): BridgeProductContentStream<'review.content'> => {
				const contentStream = remainingContentStreams.shift();
				if (contentStream === undefined) throw new Error('Unexpected Review content open.');
				return contentStream.stream;
			},
		});
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createBridgeCommWorkerStore({
			surface: 'review',
			contentItems: [makeWorkerReviewContentMetadata()],
			rows: [{ id: 'item-1', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'item-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });
		const preparation = enqueueSelectedBridgeWorkerReviewContentReadyPreparation({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			contentRequestDescriptors: deferredContent.map(({ descriptor }) => descriptor),
			epoch: 7,
			fetchReviewContentResource,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			workerDerivationEpoch: 7,
			itemId: 'item-1',
			port: makePostedMessagePort([]),
			pump,
			renderSemantics: [makeRenderSemantics()],
			sequence: 12,
			store,
		});
		pump.runUntilBudget();

		preparation.pause();
		preparation.resume();

		expect(pauseBeforeStartCount).toBe(2);
		expect(resumeBeforeStartCount).toBe(2);
		for (const contentStream of contentStreams) {
			contentStream.deferredStream.resolve(contentStream.text);
		}
		await flushBridgeWorkerPreparationContinuations();
		pump.runUntilBudget();
		await preparation.completion;
	});

	test('skips enqueue when selected content is no longer current or demand eligible', async () => {
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createBridgeCommWorkerStore({
			surface: 'review',
			contentItems: [],
			rows: [{ id: 'item-without-metadata', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'item-without-metadata' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerReviewContentReadyPreparation({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			contentRequestDescriptors: [],
			epoch: 7,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			workerDerivationEpoch: 7,
			itemId: 'item-without-metadata',
			port: makePostedMessagePort([]),
			pump,
			renderSemantics: [],
			sequence: 12,
			store,
		});

		await preparation.completion;

		expect(preparation.enqueued).toBe(false);
		expect(pump.getPendingWorkIds()).toEqual([]);
	});
});

async function flushBridgeWorkerPreparationContinuations(): Promise<void> {
	await Array.from({ length: 50 }).reduce<Promise<void>>(
		(previousFlush) => previousFlush.then(() => Promise.resolve()),
		Promise.resolve(),
	);
}

function expectSelectedContentDroppedTelemetry(
	telemetrySamples: readonly BridgeTelemetrySample[],
	dropReason: string,
): void {
	expect(telemetrySamples).toContainEqual(
		expect.objectContaining({
			name: 'performance.bridge.web.selected_content_dropped',
			durationMilliseconds: null,
			stringAttributes: expect.objectContaining({
				'agentstudio.bridge.drop_reason': dropReason,
				'agentstudio.bridge.phase': 'selected_content_dropped',
				'agentstudio.bridge.result': 'dropped',
				'agentstudio.bridge.transport': 'content',
				'agentstudio.bridge.viewer': 'review',
			}),
		}),
	);
}

function makePostedMessagePort(
	postedMessages: PostedBridgeWorkerPreparationMessage[],
): BridgeCommWorkerPort {
	return {
		postMessage: (
			message: BridgeWorkerServerToMainMessage,
			transferList?: Transferable[],
		): void => {
			postedMessages.push({ message, transferList });
		},
		addEventListener: (): void => {},
	};
}

function makeThrowingPostedMessagePort(): BridgeCommWorkerPort {
	return {
		postMessage: (): void => {
			throw new Error('publish failed');
		},
		addEventListener: (): void => {},
	};
}

function makeWorkerReviewContentMetadata(itemId = 'item-1'): BridgeWorkerReviewContentMetadata {
	return {
		itemId,
		path: `Sources/App/${itemId}.swift`,
		language: 'swift',
		cacheKey: `${itemId}:base|${itemId}:head`,
		sizeBytes: 1024,
		availableContentRoles: ['base', 'head'],
		contentLineCountsByRole: { base: 100, head: 80 },
	};
}

function makeRenderSemantics(): BridgeWorkerReviewRenderSemantics {
	return {
		itemId: 'item-1',
		itemKind: 'diff',
		changeKind: 'modified',
		displayPath: 'Sources/App/item-1.swift',
		basePath: 'Sources/App/item-1.swift',
		headPath: 'Sources/App/item-1.swift',
		language: 'swift',
		contentLineCountsByRole: { base: 100, head: 80 },
	};
}

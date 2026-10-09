import { describe, expect, test } from 'vitest';

import {
	encodeBridgeWorkerActiveViewerModeUpdateCommand,
	encodeBridgeWorkerMarkFileViewedCommand,
	encodeBridgeWorkerMetadataInterestUpdateCommand,
	encodeBridgeWorkerReviewIntakeReadyCommand,
	encodeBridgeWorkerReviewComparisonUpdateCommand,
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
import { drainBridgeWorkerVisibleDemandRuntimeUntil } from './bridge-comm-worker-runtime-protocol.visible-demand.test-support.js';
import type { BridgeProductControlCommand } from './bridge-product-control-contracts.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';

describe('Bridge comm worker runtime protocol', () => {
	test('opens Review metadata through worker-owned intake readiness', async () => {
		// Arrange
		const sentCommands: BridgeProductControlCommand[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			sendProductControl: async (command): Promise<void> => {
				sentCommands.push(command);
			},
		});

		// Act
		dispatch.message(
			encodeBridgeWorkerReviewIntakeReadyCommand({
				requestId: 'request-review-intake-ready',
				epoch: 1,
				reason: 'bridge-ready',
				streamId: 'review:pane-1',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(sentCommands).toEqual([
			{
				method: 'bridge.intakeReady',
				params: {
					protocolId: 'review',
					reason: 'bridge-ready',
					streamId: 'review:pane-1',
				},
			},
		]);
		expect(postedMessages.map((postedMessage) => postedMessage.message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-review-intake-ready',
				status: 'ready',
			}),
		);
	});

	test('sends markFileViewed through worker-owned product control', async () => {
		const sentCommands: BridgeProductControlCommand[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const productControlCompletion = createDeferredVoid();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			sendProductControl: async (command): Promise<void> => {
				sentCommands.push(command);
				await productControlCompletion.promise;
			},
		});

		dispatch.message(
			encodeBridgeWorkerMarkFileViewedCommand({
				requestId: 'request-mark-viewed',
				epoch: 3,
				fileId: 'item-1',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expect(sentCommands).toEqual([
			{
				method: 'review.markFileViewed',
				params: { fileId: 'item-1' },
			},
		]);
		expect(postedMessages.map((postedMessage) => postedMessage.message)).not.toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-mark-viewed',
				status: 'ready',
			}),
		);
		productControlCompletion.resolve();
		await flushBridgeWorkerRuntimeContinuations();

		expect(postedMessages.map((postedMessage) => postedMessage.message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-mark-viewed',
				status: 'ready',
			}),
		);
	});

	test('acknowledges a Review comparison update only after product control completes', async () => {
		const sentCommands: BridgeProductControlCommand[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const productControlCompletion = createDeferredVoid();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			sendProductControl: async (command): Promise<void> => {
				sentCommands.push(command);
				await productControlCompletion.promise;
			},
		});

		dispatch.message(
			encodeBridgeWorkerReviewComparisonUpdateCommand({
				epoch: 3,
				requestId: 'request-comparison-update',
				target: { basis: 'commonCommit', kind: 'branch', name: 'feature/review' },
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expect(sentCommands).toEqual([
			{
				method: 'review.comparison.update',
				params: {
					target: { basis: 'commonCommit', kind: 'branch', name: 'feature/review' },
				},
			},
		]);
		expect(postedMessages.map(({ message }) => message)).not.toContainEqual(
			expect.objectContaining({ requestId: 'request-comparison-update', status: 'ready' }),
		);
		productControlCompletion.resolve();
		await flushBridgeWorkerRuntimeContinuations();
		expect(postedMessages.map(({ message }) => message)).toContainEqual(
			expect.objectContaining({ requestId: 'request-comparison-update', status: 'ready' }),
		);
	});

	test('reports degraded health when markFileViewed product control fails', async () => {
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			sendProductControl: async (): Promise<void> => {
				throw new Error('scheme down');
			},
		});

		dispatch.message(
			encodeBridgeWorkerMarkFileViewedCommand({
				requestId: 'request-mark-viewed',
				epoch: 3,
				fileId: 'item-1',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expect(postedMessages.map((postedMessage) => postedMessage.message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-mark-viewed',
				status: 'degraded',
				message: 'Bridge comm worker failed to forward review.markFileViewed.',
			}),
		);
		expect(postedMessages.map((postedMessage) => postedMessage.message)).not.toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-mark-viewed',
				status: 'ready',
			}),
		);
	});

	test('does not send rejected markFileViewed product control', async () => {
		const sentCommands: BridgeProductControlCommand[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			sendProductControl: async (command): Promise<void> => {
				sentCommands.push(command);
			},
		});

		dispatch.message(
			encodeBridgeWorkerMarkFileViewedCommand({
				requestId: 'request-current',
				epoch: 3,
				fileId: 'item-1',
			}),
		);
		dispatch.message(
			encodeBridgeWorkerMarkFileViewedCommand({
				requestId: 'request-stale',
				epoch: 2,
				fileId: 'item-1',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expect(sentCommands).toEqual([
			{
				method: 'review.markFileViewed',
				params: { fileId: 'item-1' },
			},
		]);
		expect(postedMessages.map((postedMessage) => postedMessage.message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-stale',
				status: 'degraded',
				message: 'Bridge comm worker rejected stale epoch 2 after 3.',
			}),
		);
	});

	test('commits the newest worker-owned Review role before native open and ignores caller roles', async () => {
		// Arrange
		let clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const openedDescriptorIds: string[] = [];
		const firstInterestCommit = createDeferredVoid();
		const secondInterestCommit = createDeferredVoid();
		let viewScopeCount = 0;
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource({
			setViewScopeForSubscription: async (): Promise<{
				kind: 'accepted';
				scopeRevision: number;
			}> => {
				viewScopeCount += 1;
				const scopeCount = viewScopeCount;
				if (scopeCount === 1) await firstInterestCommit.promise;
				else if (scopeCount === 2) await secondInterestCommit.promise;
				return { kind: 'accepted', scopeRevision: scopeCount };
			},
		});
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			createSequence: createBridgeWorkerSequenceCounter(301),
			openReviewContent: (descriptor, signal) => {
				openedDescriptorIds.push(descriptor.descriptorId);
				return openReviewContentFromDescriptorMap(descriptor, signal);
			},
			productTransport: reviewProductSource.productTransport,
			pump: createWorkerContentPreparationPump({ maxSliceMs: 8, now: () => clockMs }),
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'worker-owned-interest');
		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata()],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({ role: 'base', text: 'interest base' }),
					makeContentRequestDescriptor({ role: 'head', text: 'interest head' }),
				],
				renderSemantics: [makeRenderSemantics()],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			4,
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(reviewProductSource.viewScopes).toEqual([]);

		// Act: promote before the first snapshot commits, then start content work.
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: 5,
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
				requestId: 'request-promote-before-native-open',
				surface: 'review',
				visibleItemIds: ['item-1'],
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(reviewProductSource.viewScopes.map(({ scope }) => scope)).toEqual([
			{ kind: 'review', interests: [{ itemIds: ['item-1'], lane: 'visible' }] },
		]);
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 5,
				requestId: 'request-select-before-native-open',
				selectedItemId: 'item-1',
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		dispatch.message(
			encodeBridgeWorkerMetadataInterestUpdateCommand({
				epoch: 5,
				request: {
					itemIds: ['forged-caller-item'],
					lane: 'idle',
					protocol: 'review',
				},
				requestId: 'request-await-worker-interest',
			}),
		);
		clockMs += 1;
		await flushBridgeWorkerRuntimeContinuations();

		// Assert: neither the native open nor command acknowledgement can overtake the newest role.
		expect(openedDescriptorIds).toEqual([]);
		expect(postedMessages.map(({ message }) => message)).not.toContainEqual(
			expect.objectContaining({ requestId: 'request-await-worker-interest', status: 'ready' }),
		);
		firstInterestCommit.resolve();
		await flushBridgeWorkerRuntimeContinuations();
		expect(reviewProductSource.viewScopes.map(({ scope }) => scope)).toEqual([
			{ kind: 'review', interests: [{ itemIds: ['item-1'], lane: 'visible' }] },
			{ kind: 'review', interests: [{ itemIds: ['item-1'], lane: 'foreground' }] },
		]);
		expect(openedDescriptorIds).toEqual([]);
		secondInterestCommit.resolve();
		await drainBridgeWorkerVisibleDemandRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(({ message }) => message.kind === 'reviewPierreRenderJob'),
			scheduledDrains,
			startIndex: 0,
		});
		await flushBridgeWorkerRuntimeContinuations();
		expect(openedDescriptorIds).toHaveLength(2);
		expect(
			reviewProductSource.viewScopes
				.flatMap(({ scope }) => (scope.kind === 'review' ? scope.interests : []))
				.flatMap(({ itemIds }) => itemIds),
		).not.toContain('forged-caller-item');
		expect(postedMessages.map(({ message }) => message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-await-worker-interest',
				status: 'ready',
			}),
		);
		reviewProductSource.close();
	});

	test('sends activeViewerModeUpdate through worker-owned product control', async () => {
		const sentCommands: BridgeProductControlCommand[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const productControlCompletion = createDeferredVoid();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			sendProductControl: async (command): Promise<void> => {
				sentCommands.push(command);
				await productControlCompletion.promise;
			},
		});

		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				requestId: 'request-active-viewer-mode',
				epoch: 3,
				update: {
					sessionId: 'active-viewer-session',
					sequence: 4,
					mode: 'review',
					activeSource: {
						protocol: 'review',
						streamId: 'review:pane-1',
						generation: 5,
					},
					nativeSelectionRequestId: null,
				},
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expect(sentCommands).toEqual([
			{
				method: 'bridge.activeViewerMode.update',
				params: {
					sessionId: 'active-viewer-session',
					sequence: 4,
					mode: 'review',
					activeSource: {
						protocol: 'review',
						streamId: 'review:pane-1',
						generation: 5,
					},
					nativeSelectionRequestId: null,
				},
			},
		]);
		expect(postedMessages.map((postedMessage) => postedMessage.message)).not.toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-active-viewer-mode',
				status: 'ready',
			}),
		);
		productControlCompletion.resolve();
		await flushBridgeWorkerRuntimeContinuations();

		expect(postedMessages.map((postedMessage) => postedMessage.message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-active-viewer-mode',
				status: 'ready',
			}),
		);
	});

	test('reports degraded health when activeViewerModeUpdate product control fails', async () => {
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			sendProductControl: async (): Promise<void> => {
				throw new Error('scheme down');
			},
		});

		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				requestId: 'request-active-viewer-mode',
				epoch: 3,
				update: {
					sessionId: 'active-viewer-session',
					sequence: 4,
					mode: 'file',
					activeSource: null,
					nativeSelectionRequestId: null,
				},
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expect(postedMessages.map((postedMessage) => postedMessage.message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-active-viewer-mode',
				status: 'degraded',
				message: 'Bridge comm worker failed to forward bridge.activeViewerMode.update.',
				deliveryStatus: 'unknownAfterDispatch',
			}),
		);
		expect(postedMessages.map((postedMessage) => postedMessage.message)).not.toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-active-viewer-mode',
				status: 'ready',
			}),
		);
	});

	test('starts visible Review demand from viewport membership through the worker executor', async () => {
		let clockMs = 0;
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
			createSequence: createBridgeWorkerSequenceCounter(101),
			openReviewContent: openReviewContentFromDescriptorMap,
			pump: createWorkerContentPreparationPump({
				maxSliceMs: 8,
				now: () => clockMs,
			}),
			productTransport: reviewProductSource.productTransport,
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'visible-viewport');
		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata()],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({ role: 'base', text: 'visible base' }),
					makeContentRequestDescriptor({ role: 'head', text: 'visible head' }),
				],
				renderSemantics: [makeRenderSemantics()],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			4,
		);
		await flushBridgeWorkerRuntimeContinuations();
		postedMessages.length = 0;

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-visible-viewport',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
			}),
		);

		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'slicePatch',
			'health',
		]);
		expect(scheduledDrains).toHaveLength(1);
		clockMs += 1;

		await drainBridgeWorkerVisibleDemandRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) => postedMessage.message.kind === 'reviewPierreRenderJob',
				),
			scheduledDrains,
			startIndex: 0,
		});
		const publishedReviewJob = postedMessages.find(
			({ message }) => message.kind === 'reviewPierreRenderJob' && message.job.itemId === 'item-1',
		)?.message;
		if (publishedReviewJob?.kind !== 'reviewPierreRenderJob') {
			throw new Error('Expected the visible Review render job.');
		}
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'slicePatch',
			'health',
			'reviewPierreRenderJob',
			'reviewRenderPatch',
		]);
		expect(postedMessages[2]?.message).toMatchObject({
			kind: 'reviewPierreRenderJob',
			job: {
				itemId: 'item-1',
				bridgeDemandRank: { lane: 'visible', priority: 1 },
				budgetClass: 'visible',
			},
		});
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

	test('starts visible Review demand after source update repairs an existing viewport', async () => {
		let clockMs = 0;
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
			createSequence: createBridgeWorkerSequenceCounter(201),
			openReviewContent: openReviewContentFromDescriptorMap,
			pump: createWorkerContentPreparationPump({
				maxSliceMs: 8,
				now: () => clockMs,
			}),
			productTransport: reviewProductSource.productTransport,
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
		});
		await flushBridgeWorkerRuntimeContinuations();
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'visible-before-source');
		await flushBridgeWorkerRuntimeContinuations();
		postedMessages.length = 0;

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-visible-before-source',
				epoch: 5,
				surface: 'review',
				visibleItemIds: ['item-1'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
			}),
		);
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'slicePatch',
			'health',
		]);
		expect(scheduledDrains).toEqual([]);

		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata()],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({ role: 'base', text: 'source repair base' }),
					makeContentRequestDescriptor({ role: 'head', text: 'source repair head' }),
				],
				renderSemantics: [makeRenderSemantics()],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			6,
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'slicePatch',
			'health',
			'reviewCandidateStarted',
			'reviewDisplayPatch',
			'reviewCandidateReady',
			'fileDisplayPatch',
		]);
		expect(scheduledDrains).toHaveLength(1);
		clockMs += 1;

		const firstDrainCompletion = assertBridgeCommWorkerPreparationDrain(scheduledDrains[0])();
		await flushBridgeWorkerRuntimeContinuations();
		expect(scheduledDrains).toHaveLength(2);
		const secondDrainResult = await assertBridgeCommWorkerPreparationDrain(scheduledDrains[1])();
		const firstDrainResult = await firstDrainCompletion;

		expect(firstDrainResult.completedIds).toEqual([]);
		const publishedReviewJob = postedMessages.find(
			({ message }) => message.kind === 'reviewPierreRenderJob' && message.job.itemId === 'item-1',
		)?.message;
		if (publishedReviewJob?.kind !== 'reviewPierreRenderJob') {
			throw new Error('Expected the visible Review render job after source repair.');
		}
		expect(secondDrainResult.completedIds).toEqual([
			`review-content-ready:item-1:review-ledger:item-1:${publishedReviewJob.renderReceiptIdentity.publicationSequence}`,
		]);
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'slicePatch',
			'health',
			'reviewCandidateStarted',
			'reviewDisplayPatch',
			'reviewCandidateReady',
			'fileDisplayPatch',
			'reviewPierreRenderJob',
			'reviewRenderPatch',
		]);
		expect(
			postedMessages.find(({ message }) => message.kind === 'reviewPierreRenderJob')?.message,
		).toMatchObject({
			kind: 'reviewPierreRenderJob',
			job: {
				itemId: 'item-1',
				bridgeDemandRank: { lane: 'visible', priority: 1 },
				budgetClass: 'visible',
			},
		});
		expect(
			postedMessages.find(
				({ message }) =>
					message.kind === 'reviewRenderPatch' &&
					message.publicationSequence ===
						publishedReviewJob.renderReceiptIdentity.publicationSequence,
			)?.message,
		).toMatchObject({
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

	test('skips ready visible Review demand when viewport adds cold content', async () => {
		let clockMs = 0;
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const fetchCallsByItemId = new Map<string, number>();
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			createSequence: createBridgeWorkerSequenceCounter(301),
			openReviewContent: (descriptor, abortSignal) => {
				fetchCallsByItemId.set(
					descriptor.itemId,
					(fetchCallsByItemId.get(descriptor.itemId) ?? 0) + 1,
				);
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
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'ready-visible');
		reviewProductSource.publishSource(
			{
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						itemId: 'item-1',
						role: 'base',
						text: 'ready base',
					}),
					makeContentRequestDescriptor({
						itemId: 'item-1',
						role: 'head',
						text: 'ready head',
					}),
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', parentId: null, index: 0 }],
			},
			4,
		);
		await flushBridgeWorkerRuntimeContinuations();
		await drainBridgeWorkerVisibleDemandRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-1',
				),
			scheduledDrains,
			startIndex: 0,
		});
		const coldDrainStartIndex = scheduledDrains.length;
		postedMessages.length = 0;

		reviewProductSource.publishSource(
			{
				contentItems: [
					makeWorkerReviewContentMetadata({ itemId: 'item-1' }),
					makeWorkerReviewContentMetadata({ itemId: 'item-2' }),
				],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({
						itemId: 'item-1',
						role: 'base',
						text: 'ready base',
					}),
					makeContentRequestDescriptor({
						itemId: 'item-1',
						role: 'head',
						text: 'ready head',
					}),
					makeContentRequestDescriptor({
						itemId: 'item-2',
						role: 'base',
						text: 'cold base',
					}),
					makeContentRequestDescriptor({
						itemId: 'item-2',
						role: 'head',
						text: 'cold head',
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
			5,
		);
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				requestId: 'request-cold-visible',
				epoch: 6,
				surface: 'review',
				visibleItemIds: ['item-1', 'item-2'],
				firstVisibleIndex: 0,
				lastVisibleIndex: 1,
				phase: 'settled',
			}),
		);
		clockMs += 1;
		await drainBridgeWorkerVisibleDemandRuntimeUntil({
			hasExpectedEvent: () =>
				postedMessages.some(
					(postedMessage) =>
						postedMessage.message.kind === 'reviewPierreRenderJob' &&
						postedMessage.message.job.itemId === 'item-2',
				),
			scheduledDrains,
			startIndex: coldDrainStartIndex,
		});

		const pierreJobItemIds = postedMessages.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob'
				? [postedMessage.message.job.itemId]
				: [],
		);
		expect(pierreJobItemIds).toEqual(['item-2']);
		expect(fetchCallsByItemId.get('item-1')).toBe(2);
		expect(fetchCallsByItemId.get('item-2')).toBe(2);
	});
});

function createDeferredVoid(): { readonly promise: Promise<void>; readonly resolve: () => void } {
	let resolvePromise: (() => void) | null = null;
	const promise = new Promise<void>((resolve): void => {
		resolvePromise = resolve;
	});
	return {
		promise,
		resolve: (): void => {
			if (resolvePromise === null) {
				throw new Error('Deferred promise resolver was not initialized.');
			}
			resolvePromise();
		},
	};
}

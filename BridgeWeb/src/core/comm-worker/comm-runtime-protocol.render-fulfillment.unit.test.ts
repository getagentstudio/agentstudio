import { afterEach, describe, expect, test } from 'vitest';

import {
	encodeBridgeWorkerRenderDispositionCommand,
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';
import {
	registerBridgeCommWorkerRuntimePortProtocol,
	type BridgeCommWorkerPreparationDrain,
} from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerReviewViewerMode,
	createBridgeCommWorkerReviewProductTestSource,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
	makeContentRequestDescriptor,
	makeRenderSemantics,
	makeWorkerReviewContentMetadata,
	openReviewContentFromDescriptorMap,
	type BridgeCommWorkerReviewProductTestSource,
	type PostedBridgeWorkerRuntimeMessage,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';
import type {
	BridgeWorkerHealthEvent,
	BridgeWorkerReviewPierreRenderJobEvent,
} from './bridge-worker-contracts.js';
import {
	bridgeWorkerRenderDispositionReceiptSchema,
	type BridgeWorkerRenderDisposition,
	type BridgeWorkerRenderDispositionReceipt,
	type BridgeWorkerRenderReceiptIdentity,
} from './bridge-worker-render-fulfillment.js';

const reviewItemId = 'review-render-fulfillment-item';
const reviewIntentEpoch = 7;
const runtimePaneSessionId = 'pane-session-render-fulfillment';
const runtimeWorkerInstanceId = 'worker-instance-render-fulfillment';
const openReviewProductSources = new Set<BridgeCommWorkerReviewProductTestSource>();

afterEach((): void => {
	for (const reviewProductSource of openReviewProductSources) {
		reviewProductSource.close();
	}
	openReviewProductSources.clear();
});

describe('Bridge comm worker runtime render fulfillment', () => {
	test('admits a production-stamped Review disposition after intent advances beyond derivation', async () => {
		// Arrange
		const harness = await createReviewRenderPublicationHarness();
		const publication = harness.publication;
		expect(reviewIntentEpoch).toBeGreaterThan(publication.workerDerivationEpoch);

		// Act
		dispatchDisposition(harness, {
			disposition: 'queued',
			epoch: publication.workerDerivationEpoch,
			identity: publication.renderReceiptIdentity,
			requestId: 'request-production-stamped-queued',
		});

		// Assert
		expectHealthForRequest(
			harness.postedMessages,
			'request-production-stamped-queued',
		).toMatchObject({ status: 'ready' });
	});

	test('applies an ordered queued applied painted batch with one worker acknowledgement', async () => {
		const harness = await createReviewRenderPublicationHarness();
		const identity = harness.publication.renderReceiptIdentity;

		harness.dispatch.message(
			encodeBridgeWorkerRenderDispositionCommand({
				epoch: identity.workerDerivationEpoch,
				receipts: (['queued', 'applied', 'painted'] as const).map((disposition) =>
					makeDispositionReceipt({ disposition, identity }),
				),
				requestId: 'request-ordered-render-disposition-batch',
			}),
		);

		expectHealthForRequest(
			harness.postedMessages,
			'request-ordered-render-disposition-batch',
		).toMatchObject({ status: 'ready' });
		expect(
			harness.postedMessages.filter(
				({ message }) =>
					message.kind === 'health' &&
					message.requestId === 'request-ordered-render-disposition-batch',
			),
		).toHaveLength(1);
	});

	test('keeps Review ready, published, queued, and applied intermediate until matching painted residency', async () => {
		// Arrange
		const harness = await createReviewRenderPublicationHarness();
		const publication = harness.publication;
		expect(publication.renderReceiptIdentity).toMatchObject({
			itemId: reviewItemId,
			paneSessionId: runtimePaneSessionId,
			surface: 'review',
			workerInstanceId: runtimeWorkerInstanceId,
			workerDerivationEpoch: publication.workerDerivationEpoch,
		});
		expect(publication.renderReceiptIdentity.publicationSequence).toBe(
			publication.publicationSequence,
		);
		expect(
			harness.postedMessages.some(
				({ message }) =>
					message.kind === 'reviewRenderPatch' &&
					message.patches.some(
						(patch) =>
							patch.slice === 'contentAvailability' &&
							patch.operation === 'upsert' &&
							patch.itemId === reviewItemId &&
							patch.payload.state === 'ready',
					),
			),
		).toBe(true);

		// Act / Assert: content ready and publication alone are not painted fulfillment.
		dispatchDisposition(harness, {
			disposition: 'painted',
			identity: publication.renderReceiptIdentity,
			requestId: 'request-painted-before-queued',
		});
		expectHealthForRequest(harness.postedMessages, 'request-painted-before-queued').toMatchObject({
			status: 'degraded',
			message: 'Bridge render disposition did not match a current worker publication.',
		});

		dispatchDisposition(harness, {
			disposition: 'queued',
			identity: publication.renderReceiptIdentity,
			requestId: 'request-queued',
		});
		expectHealthForRequest(harness.postedMessages, 'request-queued').toMatchObject({
			status: 'ready',
		});

		dispatchDisposition(harness, {
			disposition: 'painted',
			identity: publication.renderReceiptIdentity,
			requestId: 'request-painted-before-applied',
		});
		expectHealthForRequest(harness.postedMessages, 'request-painted-before-applied').toMatchObject({
			status: 'degraded',
			message: 'Bridge render disposition did not match a current worker publication.',
		});

		dispatchDisposition(harness, {
			disposition: 'applied',
			identity: publication.renderReceiptIdentity,
			requestId: 'request-applied',
		});
		expectHealthForRequest(harness.postedMessages, 'request-applied').toMatchObject({
			status: 'ready',
		});

		dispatchDisposition(harness, {
			disposition: 'painted',
			identity: publication.renderReceiptIdentity,
			requestId: 'request-painted',
		});
		expectHealthForRequest(harness.postedMessages, 'request-painted').toMatchObject({
			status: 'ready',
		});

		// A semantic duplicate under a fresh transport request id is idempotent.
		dispatchDisposition(harness, {
			disposition: 'painted',
			identity: publication.renderReceiptIdentity,
			requestId: 'request-painted-semantic-duplicate',
		});
		expectHealthForRequest(
			harness.postedMessages,
			'request-painted-semantic-duplicate',
		).toMatchObject({ status: 'ready' });

		// Painted is terminal: an earlier intermediate disposition cannot reopen the attempt.
		dispatchDisposition(harness, {
			disposition: 'queued',
			identity: publication.renderReceiptIdentity,
			requestId: 'request-queued-after-painted',
		});
		expectHealthForRequest(harness.postedMessages, 'request-queued-after-painted').toMatchObject({
			status: 'degraded',
		});
	});

	test('rejects hostile File and mismatched Review receipts without cross-surface mutation', async () => {
		// Arrange
		const harness = await createReviewRenderPublicationHarness();
		const reviewIdentity = harness.publication.renderReceiptIdentity;

		// Act / Assert: changing only the surface must route to the isolated File registry.
		dispatchDisposition(harness, {
			disposition: 'queued',
			identity: { ...reviewIdentity, surface: 'file' },
			requestId: 'request-cross-surface-file-receipt',
		});
		expectHealthForRequest(
			harness.postedMessages,
			'request-cross-surface-file-receipt',
		).toMatchObject({
			requestId: 'request-cross-surface-file-receipt',
			status: 'degraded',
		});

		dispatchDisposition(harness, {
			disposition: 'queued',
			identity: { ...reviewIdentity, workerInstanceId: 'worker-instance-hostile' },
			requestId: 'request-mismatched-review-receipt',
		});
		expectHealthForRequest(
			harness.postedMessages,
			'request-mismatched-review-receipt',
		).toMatchObject({
			requestId: 'request-mismatched-review-receipt',
			status: 'degraded',
		});

		// Both hostile commands left Review published, and the listener remains usable.
		dispatchDisposition(harness, {
			disposition: 'queued',
			identity: reviewIdentity,
			requestId: 'request-valid-review-after-hostile',
		});
		expectHealthForRequest(
			harness.postedMessages,
			'request-valid-review-after-hostile',
		).toMatchObject({
			requestId: 'request-valid-review-after-hostile',
			status: 'ready',
		});
	});

	test('does not release a held Review position when its correlated response post throws', async () => {
		const requestId = 'request-review-queued-response-post-throws';
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort({
			beforePostMessage: (message): void => {
				if (message.kind === 'health' && message.requestId === requestId) {
					throw new Error('injected Review correlated response failure');
				}
			},
		});
		const itemIds = Array.from({ length: 13 }, (_, index) => `review-held-${index + 1}`);
		const source = makeReviewRuntimeSourceForItems(itemIds);
		const reviewProductSource = await registerRuntimeWithInitialReviewSource(dispatch, {
			...source,
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			openReviewContent: openReviewContentFromDescriptorMap,
			pump: createWorkerContentPreparationPump({ maxSliceMs: 8, now: () => 0 }),
			renderFulfillmentContext: {
				paneSessionId: runtimePaneSessionId,
				workerInstanceId: runtimeWorkerInstanceId,
			},
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		openReviewProductSources.add(reviewProductSource);
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: reviewIntentEpoch,
				firstVisibleIndex: 0,
				lastVisibleIndex: itemIds.length - 1,
				phase: 'settled',
				requestId: 'request-review-fill-existing-positions',
				surface: 'review',
				visibleItemIds: itemIds,
			}),
		);
		await driveScheduledPreparationRounds({
			nextDrainIndex: 0,
			remainingRounds: 64,
			scheduledDrains,
		});
		const publicationsBeforeFailure = postedMessages.flatMap(({ message }) =>
			message.kind === 'reviewPierreRenderJob' ? [message] : [],
		);
		expect(publicationsBeforeFailure).toHaveLength(12);
		const firstPublication = publicationsBeforeFailure[0];
		if (firstPublication === undefined) throw new Error('Expected a held Review publication.');
		const drainCountBeforeFailure = scheduledDrains.length;

		expect((): void => {
			dispatchDisposition(
				{ dispatch },
				{
					disposition: 'queued',
					identity: firstPublication.renderReceiptIdentity,
					requestId,
				},
			);
		}).toThrow('injected Review correlated response failure');
		await driveScheduledPreparationRounds({
			nextDrainIndex: drainCountBeforeFailure,
			scheduledDrains,
		});

		expect(
			postedMessages.filter(({ message }) => message.kind === 'reviewPierreRenderJob'),
		).toHaveLength(12);
		expect(scheduledDrains).toHaveLength(drainCountBeforeFailure);
	});

	test('re-demands a ready visible Review publication after matching terminal rejection', async () => {
		// Arrange
		const scheduledWakes: TestScheduledRenderFulfillmentWake[] = [];
		const harness = await createReviewRenderPublicationHarness(
			'visible',
			() => 0,
			(delayMilliseconds, wake): (() => void) => {
				const scheduledWake = { active: true, delayMilliseconds, wake };
				scheduledWakes.push(scheduledWake);
				return (): void => {
					scheduledWake.active = false;
				};
			},
		);
		const firstPublication = harness.publication;
		const nextDrainIndex = harness.scheduledDrains.length;

		// Act
		harness.dispatch.message(
			encodeBridgeWorkerRenderDispositionCommand({
				epoch: reviewIntentEpoch,
				receipts: [
					bridgeWorkerRenderDispositionReceiptSchema.parse({
						...firstPublication.renderReceiptIdentity,
						disposition: 'rejected',
						kind: 'render.disposition',
						reason: 'stale_attempt',
						receivedAtMilliseconds: 0,
						retryAtMilliseconds: 0,
					}),
				],
				requestId: 'request-reject-visible-publication',
			}),
		);
		expectHealthForRequest(
			harness.postedMessages,
			'request-reject-visible-publication',
		).toMatchObject({ status: 'ready' });
		await driveScheduledPreparationRounds({
			nextDrainIndex,
			scheduledDrains: harness.scheduledDrains,
		});

		// Assert: readiness cannot suppress retry while fulfillment remains desired.
		const publications = harness.postedMessages.flatMap(({ message }) =>
			message.kind === 'reviewPierreRenderJob' ? [message] : [],
		);
		expect(publications).toHaveLength(2);
		expect(publications[1]?.renderReceiptIdentity).toMatchObject({
			publicationId: firstPublication.renderReceiptIdentity.publicationId,
			submissionId: firstPublication.renderReceiptIdentity.submissionId,
		});
		expect(publications[1]?.renderReceiptIdentity.attemptId).not.toBe(
			firstPublication.renderReceiptIdentity.attemptId,
		);
		const secondPublication = publications[1];
		if (secondPublication === undefined) {
			throw new Error('Expected the rejection retry publication.');
		}
		dispatchDisposition(harness, {
			disposition: 'queued',
			identity: secondPublication.renderReceiptIdentity,
			requestId: 'request-queued-after-rejection-retry',
		});
		dispatchDisposition(harness, {
			disposition: 'applied',
			identity: secondPublication.renderReceiptIdentity,
			requestId: 'request-applied-after-rejection-retry',
		});
		dispatchDisposition(harness, {
			disposition: 'painted',
			identity: secondPublication.renderReceiptIdentity,
			requestId: 'request-painted-after-rejection-retry',
		});
		expect(scheduledWakes.every((scheduledWake) => !scheduledWake.active)).toBe(true);
	});

	test('re-demands a visible Review publication after its receipt lease expires', async () => {
		// Arrange
		let nowMilliseconds = 0;
		const scheduledWakes: TestScheduledRenderFulfillmentWake[] = [];
		const harness = await createReviewRenderPublicationHarness(
			'visible',
			() => nowMilliseconds,
			(delayMilliseconds, wake): (() => void) => {
				const scheduledWake = { active: true, delayMilliseconds, wake };
				scheduledWakes.push(scheduledWake);
				return (): void => {
					scheduledWake.active = false;
				};
			},
		);
		const firstPublication = harness.publication;
		const nextDrainIndex = harness.scheduledDrains.length;
		expect(scheduledWakes).toMatchObject([{ active: true, delayMilliseconds: 5_000 }]);

		// Act: no disposition and no second viewport command arrive.
		nowMilliseconds = 5_000;
		runScheduledRenderFulfillmentWake(scheduledWakes[0]);
		expect(scheduledWakes[1]).toMatchObject({ active: true, delayMilliseconds: 25 });
		nowMilliseconds = 5_025;
		runScheduledRenderFulfillmentWake(scheduledWakes[1]);
		await driveScheduledPreparationRounds({
			nextDrainIndex,
			scheduledDrains: harness.scheduledDrains,
		});

		// Assert
		const publications = harness.postedMessages.flatMap(({ message }) =>
			message.kind === 'reviewPierreRenderJob' ? [message] : [],
		);
		expect(publications).toHaveLength(2);
		expect(publications[1]?.renderReceiptIdentity).toMatchObject({
			publicationId: firstPublication.renderReceiptIdentity.publicationId,
			submissionId: firstPublication.renderReceiptIdentity.submissionId,
		});
		expect(publications[1]?.renderReceiptIdentity.attemptId).not.toBe(
			firstPublication.renderReceiptIdentity.attemptId,
		);

		const secondPublication = publications[1];
		if (secondPublication === undefined) {
			throw new Error('Expected the lease-expiry retry publication.');
		}
		dispatchDisposition(harness, {
			disposition: 'queued',
			identity: secondPublication.renderReceiptIdentity,
			requestId: 'request-queued-after-lease-retry',
		});
		dispatchDisposition(harness, {
			disposition: 'applied',
			identity: secondPublication.renderReceiptIdentity,
			requestId: 'request-applied-after-lease-retry',
		});
		dispatchDisposition(harness, {
			disposition: 'painted',
			identity: secondPublication.renderReceiptIdentity,
			requestId: 'request-painted-after-lease-retry',
		});
		expect(scheduledWakes.every((scheduledWake) => !scheduledWake.active)).toBe(true);
	});
});

interface TestScheduledRenderFulfillmentWake {
	active: boolean;
	readonly delayMilliseconds: number;
	readonly wake: () => void;
}

interface ReviewRenderPublicationHarness {
	readonly dispatch: ReturnType<typeof createRecordingBridgeCommWorkerPort>['dispatch'];
	readonly postedMessages: PostedBridgeWorkerRuntimeMessage[];
	readonly publication: BridgeWorkerReviewPierreRenderJobEvent;
	readonly scheduledDrains: BridgeCommWorkerPreparationDrain[];
}

async function createReviewRenderPublicationHarness(
	demand: 'selected' | 'visible' = 'selected',
	now?: () => number,
	scheduleRenderFulfillmentWake?: (delayMilliseconds: number, wake: () => void) => () => void,
): Promise<ReviewRenderPublicationHarness> {
	const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
	const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
	const source = makeReviewRuntimeSource();
	const reviewProductSource = await registerRuntimeWithInitialReviewSource(dispatch, {
		...source,
		bridgeDemandRank: { lane: 'selected', priority: 0 },
		budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
		openReviewContent: openReviewContentFromDescriptorMap,
		...(now === undefined ? {} : { now }),
		pump: createWorkerContentPreparationPump({ maxSliceMs: 8, now: now ?? (() => 0) }),
		renderFulfillmentContext: {
			paneSessionId: runtimePaneSessionId,
			workerInstanceId: runtimeWorkerInstanceId,
		},
		schedulePreparationDrain: (drain): void => {
			scheduledDrains.push(drain);
		},
		...(scheduleRenderFulfillmentWake === undefined ? {} : { scheduleRenderFulfillmentWake }),
	});
	openReviewProductSources.add(reviewProductSource);
	if (demand === 'selected') {
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: reviewIntentEpoch,
				requestId: 'request-select-review-render-fulfillment',
				selectedItemId: reviewItemId,
				selectedSource: 'user',
				surface: 'review',
			}),
		);
	} else {
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: reviewIntentEpoch,
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
				requestId: 'request-visible-review-render-fulfillment',
				surface: 'review',
				visibleItemIds: [reviewItemId],
			}),
		);
	}
	const publication = await drainUntilReviewPublication({
		postedMessages,
		scheduledDrains,
	});
	return { dispatch, postedMessages, publication, scheduledDrains };
}

function runScheduledRenderFulfillmentWake(
	scheduledWake: TestScheduledRenderFulfillmentWake | undefined,
): void {
	if (scheduledWake === undefined || !scheduledWake.active) {
		throw new Error('Expected an active Review render-fulfillment wake.');
	}
	scheduledWake.active = false;
	scheduledWake.wake();
}

function makeReviewRuntimeSource(): BridgeCommWorkerReviewRuntimeSource {
	return {
		contentItems: [makeWorkerReviewContentMetadata({ itemId: reviewItemId })],
		contentRequestDescriptors: [
			makeContentRequestDescriptor({
				itemId: reviewItemId,
				role: 'base',
				text: 'let baseValue = 1;\n',
			}),
			makeContentRequestDescriptor({
				itemId: reviewItemId,
				role: 'head',
				text: 'let headValue = 2;\n',
			}),
		],
		renderSemantics: [makeRenderSemantics({ itemId: reviewItemId })],
		reviewPublicationIdentity: null,
		rows: [{ id: reviewItemId, index: 0, parentId: null }],
	};
}

function makeReviewRuntimeSourceForItems(
	itemIds: readonly string[],
): BridgeCommWorkerReviewRuntimeSource {
	return {
		contentItems: itemIds.map((itemId) => makeWorkerReviewContentMetadata({ itemId })),
		contentRequestDescriptors: itemIds.flatMap((itemId) => [
			makeContentRequestDescriptor({ itemId, role: 'base', text: `${itemId} base\n` }),
			makeContentRequestDescriptor({ itemId, role: 'head', text: `${itemId} head\n` }),
		]),
		renderSemantics: itemIds.map((itemId) => makeRenderSemantics({ itemId })),
		reviewPublicationIdentity: null,
		rows: itemIds.map((itemId, index) => ({ id: itemId, index, parentId: null })),
	};
}

async function registerRuntimeWithInitialReviewSource(
	dispatch: {
		readonly message: (data: unknown) => void;
		readonly port: Parameters<typeof registerBridgeCommWorkerRuntimePortProtocol>[0];
	},
	props: Parameters<typeof registerBridgeCommWorkerRuntimePortProtocol>[1] &
		BridgeCommWorkerReviewRuntimeSource,
): Promise<BridgeCommWorkerReviewProductTestSource> {
	const {
		contentItems,
		contentRequestDescriptors,
		renderSemantics,
		rows,
		schedulePreparationDrain,
		...runtimeProps
	} = props;
	if (schedulePreparationDrain === undefined) {
		throw new Error('Expected a render-fulfillment preparation scheduler.');
	}
	const initializationDrains: BridgeCommWorkerPreparationDrain[] = [];
	let isInitializingSource = true;
	const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();
	registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
		...runtimeProps,
		productTransport: reviewProductSource.productTransport,
		schedulePreparationDrain: (drain): void => {
			if (isInitializingSource) {
				initializationDrains.push(drain);
				return;
			}
			schedulePreparationDrain(drain);
		},
	});
	activateBridgeCommWorkerReviewViewerMode(dispatch, 'initial-render-fulfillment-source');
	reviewProductSource.publishSource(
		{ contentItems, contentRequestDescriptors, renderSemantics, rows },
		4,
	);
	await flushBridgeWorkerRuntimeContinuations();
	isInitializingSource = false;
	for (const drain of initializationDrains) schedulePreparationDrain(drain);
	return reviewProductSource;
}

async function drainUntilReviewPublication(props: {
	readonly postedMessages: PostedBridgeWorkerRuntimeMessage[];
	readonly scheduledDrains: BridgeCommWorkerPreparationDrain[];
}): Promise<BridgeWorkerReviewPierreRenderJobEvent> {
	return drainUntilReviewPublicationAttempt({ ...props, nextDrainIndex: 0, remainingRounds: 16 });
}

async function drainUntilReviewPublicationAttempt(props: {
	readonly nextDrainIndex: number;
	readonly postedMessages: PostedBridgeWorkerRuntimeMessage[];
	readonly remainingRounds: number;
	readonly scheduledDrains: BridgeCommWorkerPreparationDrain[];
}): Promise<BridgeWorkerReviewPierreRenderJobEvent> {
	const publication = props.postedMessages.find(
		(
			postedMessage,
		): postedMessage is PostedBridgeWorkerRuntimeMessage & {
			readonly message: BridgeWorkerReviewPierreRenderJobEvent;
		} => postedMessage.message.kind === 'reviewPierreRenderJob',
	)?.message;
	if (publication !== undefined) return publication;
	if (props.remainingRounds === 0) {
		throw new Error('Expected a bounded Review Pierre render publication.');
	}
	await flushBridgeWorkerRuntimeContinuations();
	const drainsForRound = props.scheduledDrains.slice(props.nextDrainIndex);
	if (drainsForRound.length === 0) {
		return drainUntilReviewPublicationAttempt({
			...props,
			remainingRounds: props.remainingRounds - 1,
		});
	}
	for (const drain of drainsForRound) {
		void drain();
	}
	return drainUntilReviewPublicationAttempt({
		...props,
		nextDrainIndex: props.nextDrainIndex + drainsForRound.length,
		remainingRounds: props.remainingRounds - 1,
	});
}

async function driveScheduledPreparationRounds(props: {
	readonly nextDrainIndex: number;
	readonly scheduledDrains: BridgeCommWorkerPreparationDrain[];
	readonly remainingRounds?: number;
}): Promise<void> {
	const remainingRounds = props.remainingRounds ?? 16;
	if (remainingRounds === 0) return;
	await flushBridgeWorkerRuntimeContinuations();
	const drainsForRound = props.scheduledDrains.slice(props.nextDrainIndex);
	if (drainsForRound.length === 0) return;
	for (const drain of drainsForRound) {
		void drain();
	}
	return driveScheduledPreparationRounds({
		nextDrainIndex: props.nextDrainIndex + drainsForRound.length,
		remainingRounds: remainingRounds - 1,
		scheduledDrains: props.scheduledDrains,
	});
}

function dispatchDisposition(
	harness: Pick<ReviewRenderPublicationHarness, 'dispatch'>,
	props: {
		readonly disposition: Extract<BridgeWorkerRenderDisposition, 'queued' | 'applied' | 'painted'>;
		readonly epoch?: number;
		readonly identity: BridgeWorkerRenderReceiptIdentity;
		readonly requestId: string;
	},
): void {
	harness.dispatch.message(
		encodeBridgeWorkerRenderDispositionCommand({
			epoch: props.epoch ?? reviewIntentEpoch,
			receipts: [makeDispositionReceipt(props)],
			requestId: props.requestId,
		}),
	);
}

function makeDispositionReceipt(props: {
	readonly disposition: Extract<BridgeWorkerRenderDisposition, 'queued' | 'applied' | 'painted'>;
	readonly identity: BridgeWorkerRenderReceiptIdentity;
}): BridgeWorkerRenderDispositionReceipt {
	return bridgeWorkerRenderDispositionReceiptSchema.parse({
		...props.identity,
		disposition: props.disposition,
		kind: 'render.disposition',
		receivedAtMilliseconds: 0,
	});
}

function expectHealthForRequest(
	postedMessages: readonly PostedBridgeWorkerRuntimeMessage[],
	requestId: string,
): ReturnType<typeof expect<BridgeWorkerHealthEvent>> {
	const healthMessages = postedMessages.flatMap(({ message }) =>
		message.kind === 'health' && message.requestId === requestId ? [message] : [],
	);
	expect(healthMessages).toHaveLength(1);
	const healthMessage = healthMessages[0];
	if (healthMessage === undefined) {
		throw new Error(`Expected correlated health for ${requestId}.`);
	}
	return expect(healthMessage);
}

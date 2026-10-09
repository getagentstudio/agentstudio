import { uuidv7 } from 'uuidv7';
import { describe, expect, test } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import {
	encodeBridgeWorkerMetadataInterestUpdateCommand,
	encodeBridgeWorkerReviewPublicationInstallAdmitCommand,
	encodeBridgeWorkerReviewPublicationInstalledCommand,
} from './bridge-comm-worker-protocol.js';
import {
	registerBridgeCommWorkerRuntimePortProtocol,
	type BridgeCommWorkerPreparationDrain,
} from './bridge-comm-worker-runtime-protocol.js';
import {
	createReviewBatchSinkCapture,
	makeReviewTestBatch,
	makeReviewProductTransport,
} from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import {
	activateBridgeCommWorkerReviewViewerMode,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import {
	BridgeProductBoundedAsyncQueue,
	createBridgeProductDeferred,
} from './bridge-product-async-queue.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import {
	bridgeProductReviewAnnotationMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import type { BridgeProductMetadataApplicationSubscription } from './bridge-product-transport-contract.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';

type ReviewAnnotationMetadataProtocol =
	typeof bridgeProductReviewAnnotationMetadataApplicationProtocol;
type ReviewAnnotationMetadataSubscription =
	BridgeProductMetadataApplicationSubscription<ReviewAnnotationMetadataProtocol>;
type ReviewMetadataProtocol = typeof bridgeProductReviewMetadataApplicationProtocol;
type ReviewMetadataSubscription =
	BridgeProductMetadataApplicationSubscription<ReviewMetadataProtocol>;

describe('Bridge comm worker Review product source projection', () => {
	test('keeps the latest certified Review displayed through predecessor acknowledgment', async () => {
		// Arrange
		const reviewBatches = createReviewBatchSinkCapture();
		const reviewMetadataEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const appliedCallStarted = createBridgeProductDeferred<void>();
		const appliedCallCompletion = createBridgeProductDeferred<void>();
		const subscribedKinds: string[] = [];
		const reviewSubscription: ReviewMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events: reviewMetadataEvents,
			subscriptionId: 'review-successor-re-exposure',
			subscriptionKind: 'review.metadata',
		};
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeReviewProductTransport({
				onBatchFrameSinks: reviewBatches.onBatchFrameSinks,
				onCall: async (method): Promise<unknown> => {
					if (method !== 'review.publication.applied') {
						return { reason: 'notConfigured', status: 'unavailable' };
					}
					appliedCallStarted.resolve();
					await appliedCallCompletion.promise;
					return null;
				},
				reviewSubscription,
				subscribedKinds,
			}),
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'successor-re-exposure');
		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewSubscription.subscriptionId,
			}),
		);
		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewSubscription.subscriptionId,
				generation: 8,
				packageId: 'package-2',
				publicationId: '00000000-0000-7000-8000-000000000012',
				revision: 12,
				sourceIdentity: 'source-2',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		const initialDisplayCount = messageCount(postedMessages, 'reviewDisplayPatch');
		expect(initialDisplayCount).toBe(2);

		// Act
		dispatch.message(
			encodeBridgeWorkerReviewPublicationInstalledCommand({
				epoch: 1,
				packageId: initialReviewPublication.packageId,
				publicationId: initialReviewPublication.publicationId,
				requestId: 'review-predecessor-installed',
				reviewGeneration: initialReviewPublication.generation,
				revision: initialReviewPublication.revision,
				sourceIdentity: initialReviewPublication.sourceIdentity,
			}),
		);
		await appliedCallStarted.promise;
		await flushBridgeWorkerRuntimeContinuations();

		// Assert: acknowledging B does not replace the already certified C.
		expect(messageCount(postedMessages, 'reviewDisplayPatch')).toBe(initialDisplayCount);

		// Act
		appliedCallCompletion.resolve();
		await flushBridgeWorkerRuntimeContinuations();

		// The installed completion re-exposes C with its certified display bank.
		expect(messageCount(postedMessages, 'reviewDisplayPatch')).toBe(initialDisplayCount + 1);
		const messageKinds = postedMessages.map(({ message }) => ({
			kind: message.kind,
			requestId: 'requestId' in message ? message.requestId : null,
		}));
		const reExposedDisplayIndex = messageKinds.findLastIndex(
			({ kind }): boolean => kind === 'reviewDisplayPatch',
		);
		const installedReadyIndex = messageKinds.findIndex(
			({ requestId }): boolean => requestId === 'review-predecessor-installed',
		);
		expect(reExposedDisplayIndex).toBeLessThan(installedReadyIndex);
	});

	test('preserves the certified successor across failed admission terminals', async () => {
		// Arrange
		const reviewBatches = createReviewBatchSinkCapture();
		const reviewMetadataEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const reviewSubscription: ReviewMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events: reviewMetadataEvents,
			subscriptionId: 'review-successor-admission-failure',
			subscriptionKind: 'review.metadata',
		};
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeReviewProductTransport({
				onBatchFrameSinks: reviewBatches.onBatchFrameSinks,
				onCall: (method): null => {
					if (method === 'review.publication.install.admit') {
						throw new Error('injected admission transport failure');
					}
					return null;
				},
				reviewSubscription,
				subscribedKinds: [],
			}),
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'successor-admission-failure');
		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewSubscription.subscriptionId,
			}),
		);
		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewSubscription.subscriptionId,
				generation: 8,
				packageId: 'package-2',
				publicationId: '00000000-0000-7000-8000-000000000012',
				revision: 12,
				sourceIdentity: 'source-2',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(installedPredecessorCommand('review-predecessor-applied-before-failure'));
		await flushBridgeWorkerRuntimeContinuations();
		const displayCountBeforeFailure = messageCount(postedMessages, 'reviewDisplayPatch');

		// Act
		const failedAdmission = successorAdmissionCommand('review-successor-admission-failed');
		dispatch.message(failedAdmission);
		await flushBridgeWorkerRuntimeContinuations();

		// The failed admission re-exposes the certified bank for Main's recovered slot.
		expect(messageCount(postedMessages, 'reviewDisplayPatch')).toBe(displayCountBeforeFailure + 1);
		const messageKinds = postedMessages.map(({ message }) => ({
			kind: message.kind,
			requestId: 'requestId' in message ? message.requestId : null,
		}));
		const failureIndex = messageKinds.findIndex(
			({ requestId }): boolean => requestId === failedAdmission.requestId,
		);
		expect(failureIndex).toBeGreaterThanOrEqual(0);

		// Act: a repeated transport failure cannot create an unbounded retry loop.
		dispatch.message(successorAdmissionCommand('review-successor-admission-failed-again'));
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(messageCount(postedMessages, 'reviewDisplayPatch')).toBe(displayCountBeforeFailure + 1);
	});

	test('activates Review annotation projection from accepted metadata without a fabricated active source', async () => {
		// Arrange
		const calledMethods: string[] = [];
		const reviewAnnotationEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const reviewBatches = createReviewBatchSinkCapture();
		const reviewMetadataEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const reviewProjectionSourceGenerations: number[] = [];
		const reviewProjectionQueryStarted = createBridgeProductDeferred<void>();
		const subscribedKinds: string[] = [];
		const reviewAnnotationSubscription: ReviewAnnotationMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events: reviewAnnotationEvents,
			subscriptionId: 'review-annotations-no-fabricated-source',
			subscriptionKind: 'review.annotations',
		};
		const reviewMetadataSubscription: ReviewMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events: reviewMetadataEvents,
			subscriptionId: 'review-metadata-no-fabricated-source',
			subscriptionKind: 'review.metadata',
		};
		const { dispatch } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeReviewProductTransport({
				onBatchFrameSinks: reviewBatches.onBatchFrameSinks,
				calledMethods,
				onCalledMethod: (method, request): void => {
					if (method === 'review.annotations.projection.query') {
						if (
							typeof request !== 'object' ||
							request === null ||
							!('sourceGeneration' in request) ||
							typeof request.sourceGeneration !== 'number'
						) {
							throw new Error('Review annotation query requires an exact source generation.');
						}
						reviewProjectionSourceGenerations.push(request.sourceGeneration);
						reviewProjectionQueryStarted.resolve();
					}
				},
				reviewAnnotationSubscription,
				reviewSubscription: reviewMetadataSubscription,
				subscribedKinds,
			}),
		});

		// Act
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'annotation-metadata-source');
		await flushBridgeWorkerRuntimeContinuations();
		await reviewBatches.install(
			makeEmptyReviewAnnotationBatch(reviewAnnotationSubscription.subscriptionId),
		);
		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewMetadataSubscription.subscriptionId,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(reviewProjectionSourceGenerations).toEqual([]);
		dispatch.message(
			encodeBridgeWorkerReviewPublicationInstalledCommand({
				epoch: 1,
				packageId: initialReviewPublication.packageId,
				publicationId: initialReviewPublication.publicationId,
				requestId: 'review-publication-installed',
				reviewGeneration: initialReviewPublication.generation,
				revision: initialReviewPublication.revision,
				sourceIdentity: initialReviewPublication.sourceIdentity,
			}),
		);
		await reviewProjectionQueryStarted.promise;

		// Assert
		expect(calledMethods).toContain('review.annotations.projection.query');
		expect(reviewProjectionSourceGenerations).toEqual([initialReviewPublication.generation]);
	});

	test('projects typed Review subscription snapshots into worker-owned source truth', async () => {
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const reviewBatches = createReviewBatchSinkCapture();
		const events = new BridgeProductBoundedAsyncQueue<never>(1);
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const subscribedKinds: string[] = [];
		const reviewSubscription: ReviewMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'review-subscription-1',
			subscriptionKind: 'review.metadata',
		};
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeReviewProductTransport({
				reviewSubscription,
				subscribedKinds,
				onBatchFrameSinks: reviewBatches.onBatchFrameSinks,
			}),
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'source-truth');

		dispatch.message(
			encodeBridgeWorkerMetadataInterestUpdateCommand({
				epoch: 1,
				request: {
					generation: 7,
					itemIds: ['item-1'],
					lane: 'foreground',
					loaded_by: 'foreground',
					protocol: 'review',
					streamId: 'review-stream-1',
				},
				requestId: 'request-review-interest-1',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(subscribedKinds).toEqual(['file.annotations', 'review.annotations', 'review.metadata']);
		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewSubscription.subscriptionId,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expect(scheduledDrains).toHaveLength(0);
		const reviewDisplayEvents = postedMessages
			.map(({ message }) => message as unknown as Readonly<Record<string, unknown>>)
			.filter((message) => message['kind'] === 'reviewDisplayPatch');
		expect(reviewDisplayEvents).toHaveLength(1);
		expect(reviewDisplayEvents[0]).toMatchObject({
			epoch: 1,
			kind: 'reviewDisplayPatch',
			reviewPublicationIdentity: {
				packageId: 'package-1',
				publicationId: '00000000-0000-7000-8000-000000000011',
				reviewGeneration: 7,
				revision: 11,
				sourceIdentity: 'source-1',
			},
			patches: [
				{
					operation: 'upsert',
					payload: {
						metadataWindowIdentity: JSON.stringify([
							'bridge-review-metadata-window-v1',
							'source-1',
							7,
							'00000000-0000-7000-8000-000000000011',
							11,
						]),
						status: 'ready',
						totalItemCount: 1,
						totalTreeRowCount: 2,
					},
					slice: 'reviewSource',
				},
				expect.objectContaining({ operation: 'replace', slice: 'reviewComparison' }),
				expect.objectContaining({ operation: 'batch', slice: 'reviewItem' }),
				expect.objectContaining({ operation: 'batch', slice: 'reviewTree' }),
			],
			projectionRevision: 1,
			surface: 'review',
		});
		expect(JSON.stringify(reviewDisplayEvents)).not.toMatch(
			/"(?:capability|resourceUrl|contents|contentBody|sourceBytes)"/i,
		);
	});

	test('publishes a ready empty Review source when the snapshot has no changed files', async () => {
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const reviewBatches = createReviewBatchSinkCapture();
		const reviewMetadataEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const reviewSubscription: ReviewMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events: reviewMetadataEvents,
			subscriptionId: 'review-empty-source-subscription',
			subscriptionKind: 'review.metadata',
		};
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeReviewProductTransport({
				onBatchFrameSinks: reviewBatches.onBatchFrameSinks,
				reviewSubscription,
				subscribedKinds: [],
			}),
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'empty-source');

		dispatch.message(
			encodeBridgeWorkerMetadataInterestUpdateCommand({
				epoch: 1,
				request: {
					generation: 1,
					itemIds: [],
					lane: 'foreground',
					loaded_by: 'foreground',
					protocol: 'review',
					streamId: 'review-stream-empty-source',
				},
				requestId: 'request-review-interest-empty-source',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewSubscription.subscriptionId,
				generation: 1,
				packageId: 'review-product-test-package',
				publicationId: '00000000-0000-7000-8000-000000000007',
				revision: 7,
				sourceIdentity: 'review-product-test-source',
				itemCount: 0,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		const reviewDisplayEvents = postedMessages
			.map(({ message }) => message as unknown as Readonly<Record<string, unknown>>)
			.filter((message) => message['kind'] === 'reviewDisplayPatch');
		expect(scheduledDrains).toHaveLength(0);
		expect(reviewDisplayEvents).toHaveLength(1);
		expect(reviewDisplayEvents[0]).toMatchObject({
			kind: 'reviewDisplayPatch',
			reviewPublicationIdentity: {
				packageId: 'review-product-test-package',
				publicationId: '00000000-0000-7000-8000-000000000007',
				reviewGeneration: 1,
				revision: 7,
				sourceIdentity: 'review-product-test-source',
			},
			patches: [
				{
					operation: 'upsert',
					payload: {
						status: 'ready',
						totalItemCount: 0,
						totalTreeRowCount: 0,
					},
					slice: 'reviewSource',
				},
				{ operation: 'replace', payload: null, slice: 'reviewComparison' },
				{
					operation: 'batch',
					payload: { items: [], operations: [], reset: true },
					slice: 'reviewItem',
				},
				{
					operation: 'batch',
					payload: { reset: true, windows: [{ rows: [] }] },
					slice: 'reviewTree',
				},
			],
			epoch: 1,
			surface: 'review',
		});
		reviewMetadataEvents.close(true);
	});
});

const initialReviewPublication = {
	generation: 7,
	packageId: 'package-1',
	publicationId: '00000000-0000-7000-8000-000000000011',
	revision: 11,
	sourceIdentity: 'source-1',
} as const;

const successorReviewPublication = {
	generation: 8,
	packageId: 'package-2',
	publicationId: '00000000-0000-7000-8000-000000000012',
	revision: 12,
	sourceIdentity: 'source-2',
} as const;

function installedPredecessorCommand(
	requestId: string,
): ReturnType<typeof encodeBridgeWorkerReviewPublicationInstalledCommand> {
	return encodeBridgeWorkerReviewPublicationInstalledCommand({
		epoch: 1,
		packageId: initialReviewPublication.packageId,
		publicationId: initialReviewPublication.publicationId,
		requestId,
		reviewGeneration: initialReviewPublication.generation,
		revision: initialReviewPublication.revision,
		sourceIdentity: initialReviewPublication.sourceIdentity,
	});
}

function successorAdmissionCommand(
	requestId: string,
): ReturnType<typeof encodeBridgeWorkerReviewPublicationInstallAdmitCommand> {
	return encodeBridgeWorkerReviewPublicationInstallAdmitCommand({
		candidatePublicationId: successorReviewPublication.publicationId,
		epoch: 1,
		expectedDisplayedPublicationId: initialReviewPublication.publicationId,
		requestId,
	});
}

function messageCount(
	postedMessages: ReturnType<typeof createRecordingBridgeCommWorkerPort>['postedMessages'],
	kind: string,
): number {
	return postedMessages.filter(({ message }): boolean => message.kind === kind).length;
}

function makeEmptyReviewAnnotationBatch(subscriptionId: string): BridgeProductViewInstallation {
	const begin = bridgeProductBatchFrameSchema.parse({
		...sessionCorpus.transportV2.batchFrames[0],
		batchId: uuidv7(),
		publicationId: undefined,
		scope: { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' },
		subscriptionId,
		subscriptionKind: 'review.annotations',
		targetRevision: 1,
	});
	if (begin.kind !== 'subscription.batchBegin') throw new Error('Comment batch begin missing.');
	return { certified: true, staleRecords: [], begin, domain: 'default', records: [] };
}

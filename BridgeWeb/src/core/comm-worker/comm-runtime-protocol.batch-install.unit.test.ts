import { describe, expect, test } from 'vitest';

import commentCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-comment-catalog-record-corpus.json' with { type: 'json' };
import fileCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import reviewCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { encodeBridgeWorkerSelectCommand } from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerFileViewerMode,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import type { FileMetadataSubscription } from './bridge-comm-worker-runtime-protocol.test-support.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import { makeFileProductTestTransport } from './comm-runtime-protocol.file-product.test-support.js';

describe('live worker typed batch sink', () => {
	test('an installed File bank reaches the existing runtime and display owners', async () => {
		let sinks: BridgeProductBatchFrameSinks | null = null;
		let reviewWarmupCount = 0;
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events: new BridgeProductBoundedAsyncQueue<never>(16),
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		};
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			productTransport: makeFileProductTestTransport({
				onBatchFrameSinks: (installed): void => {
					sinks = installed;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (): void => {},
				onReviewWarmup: (): void => {
					reviewWarmupCount += 1;
				},
				subscription,
			}),
		});
		activateBridgeCommWorkerFileViewerMode(dispatch, 'typed-file-batch');
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 1,
				requestId: 'select-typed-file-batch',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		const fixture = sessionCorpus.transportV2.batchFrames[0];
		const begin = bridgeProductBatchFrameSchema.parse({
			...fixture,
			publicationId: undefined,
			scope: { kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] },
			subscriptionKind: 'file.metadata',
			targetRevision: 4,
		});
		if (begin.kind !== 'subscription.batchBegin') throw new Error('File batch begin missing.');
		const installation: BridgeProductViewInstallation = {
			certified: true,
			staleRecords: [],
			begin,
			domain: 'default',
			records: [
				...fileCorpus.rows.map(({ recordKey, row }) => ({
					key: recordKey,
					revision: 1,
					value: row,
				})),
				{ key: 'member-status', revision: 1, value: fileCorpus.memberStatuses[0]?.record },
			],
		};
		if (sinks === null) throw new Error('Typed batch sink was not registered.');
		await (sinks as BridgeProductBatchFrameSinks).install(installation);
		await flushBridgeWorkerRuntimeContinuations();
		const displayPatches = postedMessages
			.map((posted) => posted.message)
			.filter((message) => message.kind === 'fileDisplayPatch')
			.flatMap((message) => message.patches);
		expect(
			displayPatches.some(
				(patch) => patch.slice === 'fileTree' && patch.operation === 'replacementCommit',
			),
		).toBe(true);
		expect(reviewWarmupCount).toBe(1);
	});

	test('an empty ready Review bank reaches the main display as one no-changes publication', async () => {
		const sinkCapture: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events: new BridgeProductBoundedAsyncQueue<never>(16),
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		};
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			productTransport: makeFileProductTestTransport({
				onBatchFrameSinks: (sinks): void => {
					sinkCapture.current = sinks;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (): void => {},
				subscription,
			}),
		});
		const emptyPublication = reviewCorpus.records[1];
		const completePublication = reviewCorpus.records[2]?.record;
		if (
			emptyPublication === undefined ||
			completePublication?.recordKind !== 'publication' ||
			completePublication.displayed === null ||
			completePublication.displayed === undefined
		)
			throw new Error('Complete empty Review fixture missing.');
		const publication = {
			...emptyPublication,
			record: {
				...emptyPublication.record,
				displayed: {
					...completePublication.displayed,
					publicationId: emptyPublication.record.publicationId,
					revision: emptyPublication.record.revision,
					summary: {
						additions: 0,
						deletions: 0,
						filesChanged: 0,
						hiddenFileCount: 0,
						visibleFileCount: 0,
					},
				},
			},
		};
		if (
			publication?.record.recordKind !== 'publication' ||
			publication.record.revision === undefined
		)
			throw new Error('Empty Review publication fixture missing.');
		const begin = bridgeProductBatchFrameSchema.parse({
			...sessionCorpus.transportV2.batchFrames[0],
			publicationId: publication.record.publicationId,
			targetRevision: publication.record.revision,
		});
		if (begin.kind !== 'subscription.batchBegin') throw new Error('Review batch begin missing.');
		if (sinkCapture.current === null) throw new Error('Typed batch sink was not registered.');
		await sinkCapture.current.install({
			certified: true,
			staleRecords: [],
			begin,
			domain: 'default',
			records: [
				{
					key: publication.recordKey,
					revision: publication.record.revision,
					value: publication.record,
				},
			],
		});
		const reviewEvents = postedMessages
			.map((posted) => posted.message)
			.filter((message) => message.kind === 'reviewDisplayPatch');
		expect(reviewEvents).toHaveLength(1);
		expect(reviewEvents[0]?.patches.find((patch) => patch.slice === 'reviewSource')).toMatchObject({
			operation: 'upsert',
			payload: {
				packageId: completePublication.displayed.packageId,
				status: 'ready',
				totalItemCount: 0,
				totalTreeRowCount: 0,
			},
			slice: 'reviewSource',
		});
		expect(postedMessages.map(({ message }) => message.kind)).toEqual(
			expect.arrayContaining(['reviewCandidateStarted', 'reviewCandidateReady']),
		);
	});

	test('a Comment bank reaches catalog staging without an operation identity', async () => {
		const sinkCapture: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events: new BridgeProductBoundedAsyncQueue<never>(16),
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		};
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			productTransport: makeFileProductTestTransport({
				onBatchFrameSinks: (sinks): void => {
					sinkCapture.current = sinks;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (): void => {},
				subscription,
			}),
		});
		const begin = bridgeProductBatchFrameSchema.parse({
			...sessionCorpus.transportV2.batchFrames[0],
			publicationId: undefined,
			scope: { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' },
			subscriptionId: 'file.annotations-idle-test-subscription',
			subscriptionKind: 'file.annotations',
			targetRevision: 4,
		});
		if (begin.kind !== 'subscription.batchBegin') throw new Error('Comment batch begin missing.');
		if (sinkCapture.current === null) throw new Error('Typed batch sink was not registered.');
		await sinkCapture.current.install({
			certified: true,
			staleRecords: [],
			begin,
			domain: 'default',
			records: [
				...new Map(
					commentCorpus.records.map(({ recordKey, record }) => [
						recordKey,
						{
							key: recordKey,
							revision: record.revision,
							value: record,
						},
					]),
				).values(),
			],
		});
		const staging = postedMessages
			.map((posted) => posted.message)
			.filter((message) => message.kind === 'annotationCatalogStaging');
		expect(staging.length).toBeGreaterThan(0);
		expect(staging[0]).not.toHaveProperty('operationCorrelationId');
	});
});

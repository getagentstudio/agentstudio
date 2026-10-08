import { describe, expect, test } from 'vitest';

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
	activateBridgeCommWorkerFileViewerModeAndFlush,
	createBridgeCommWorkerReviewProductTestSource,
	createBridgeWorkerSequenceCounter,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
	makeContentRequestDescriptor,
	makeRenderSemantics,
	makeWorkerReviewContentMetadata,
	openReviewContentFromDescriptorMap,
	type BridgeCommWorkerReviewProductTestSourceInput,
	type FileMetadataSubscription,
	type PostedBridgeWorkerRuntimeMessage,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import { bridgeProductFileBatchRowSchema } from './bridge-product-file-batch-row-contracts.js';
import {
	BRIDGE_PRODUCT_FILE_MEMBER_STATUS_KEY,
	bridgeProductFileMemberStatusRecordSchema,
} from './bridge-product-file-member-status-contracts.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import type {
	BridgeWorkerFilePierreRenderJobEvent,
	BridgeWorkerReviewPierreRenderJobEvent,
} from './bridge-worker-contracts.js';
import { bridgeWorkerRenderDispositionReceiptSchema } from './bridge-worker-render-fulfillment.js';
import {
	drainFilePreparationUntilIdle,
	fileViewProductTestBudget,
	makeFileBatchInstallation,
	makeFileProductTestTransport,
} from './comm-runtime-protocol.file-product.test-support.js';

describe('Bridge comm worker existing File owner backpressure', () => {
	test('keeps B waiting through A queued and applied, then starts B after A painted', async () => {
		const harness = await createFileBackpressureHarness();
		const publicationA = requireFilePublication(harness.postedMessages, 0);

		selectFile(harness, 2, 'selection-b');
		await flushBridgeWorkerRuntimeContinuations();
		expect(filePublications(harness.postedMessages)).toHaveLength(1);

		dispatchFileDisposition(harness, publicationA, 'queued', 'a-queued');
		dispatchFileDisposition(harness, publicationA, 'applied', 'a-applied');
		await drainFilePreparationUntilIdle(harness.scheduledDrains);
		expect(filePublications(harness.postedMessages)).toHaveLength(1);

		dispatchFileDisposition(harness, publicationA, 'painted', 'a-painted');
		await drainFilePreparationUntilIdle(harness.scheduledDrains);

		const publicationB = requireFilePublication(harness.postedMessages, 1);
		expect(publicationB.renderReceiptIdentity.operationCorrelationId).not.toBe(
			publicationA.renderReceiptIdentity.operationCorrelationId,
		);
	});

	test('applies no File owner effect when the correlated response post throws', async () => {
		const harness = await createFileBackpressureHarness('throw-response');
		const publicationA = requireFilePublication(harness.postedMessages, 0);
		selectFile(harness, 2, 'selection-b-after-throw');
		await flushBridgeWorkerRuntimeContinuations();

		expect((): void => {
			dispatchFileDisposition(harness, publicationA, 'painted', 'throw-response');
		}).toThrow('injected correlated response failure');
		await drainFilePreparationUntilIdle(harness.scheduledDrains);

		expect(filePublications(harness.postedMessages)).toHaveLength(1);
	});

	test.each(['rejected', 'superseded'] as const)(
		'starts waiting File B after A is terminally %s',
		async (disposition) => {
			const harness = await createFileBackpressureHarness();
			const publicationA = requireFilePublication(harness.postedMessages, 0);
			selectFile(harness, 2, `selection-b-after-${disposition}`);
			await flushBridgeWorkerRuntimeContinuations();

			dispatchTerminalFileDisposition(harness, publicationA, disposition);
			await drainFilePreparationUntilIdle(harness.scheduledDrains);

			expect(filePublications(harness.postedMessages)).toHaveLength(2);
		},
	);

	test('retires source-bound File A before admitting B and ignores A late receipt', async () => {
		const harness = await createFileBackpressureHarness();
		const publicationA = requireFilePublication(harness.postedMessages, 0);

		await pushReplacementFileSource(harness);
		await flushBridgeWorkerRuntimeContinuations();
		dispatchFileDisposition(harness, publicationA, 'queued', 'a-queued-after-source-b');
		await drainFilePreparationUntilIdle(harness.scheduledDrains);

		const publicationB = requireFilePublication(harness.postedMessages, 1);
		expect(publicationB.renderReceiptIdentity.operationCorrelationId).not.toBe(
			publicationA.renderReceiptIdentity.operationCorrelationId,
		);
	});
});

describe('Bridge comm worker existing Review owner backpressure', () => {
	test('releases twelve source-A positions from their exact late receipts before publishing B', async () => {
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();
		const itemIds = Array.from({ length: 12 }, (_unused, index) => `item-${index + 1}`);

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			createSequence: createBridgeWorkerSequenceCounter(1_000),
			openReviewContent: openReviewContentFromDescriptorMap,
			productTransport: reviewProductSource.productTransport,
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'source-replacement-backpressure');
		reviewProductSource.publishSource(reviewSource(itemIds, 1), 1);
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: 1,
				firstVisibleIndex: 0,
				lastVisibleIndex: itemIds.length - 1,
				phase: 'settled',
				requestId: 'request-source-a-visible',
				surface: 'review',
				visibleItemIds: itemIds,
			}),
		);
		await drainReviewPreparationUntilPublicationCount({
			expectedCount: 12,
			postedMessages,
			scheduledDrains,
		});
		const sourceAPublications = reviewPublications(postedMessages);
		expect(sourceAPublications).toHaveLength(12);

		reviewProductSource.publishReplacementSource(reviewSource(itemIds, 2), 2);
		await flushBridgeWorkerRuntimeContinuations();
		dispatchReviewQueuedBatch(dispatch, sourceAPublications);
		await drainReviewPreparationUntilPublicationCount({
			expectedCount: 24,
			postedMessages,
			scheduledDrains,
		});

		const allPublications = reviewPublications(postedMessages);
		expect(allPublications).toHaveLength(24);
		expect(
			allPublications
				.slice(12)
				.every((publication) => publication.job.contentHash.includes('generation-2')),
		).toBe(true);
		reviewProductSource.close();
	});
});

interface FileBackpressureHarness {
	readonly dispatch: ReturnType<typeof createRecordingBridgeCommWorkerPort>['dispatch'];
	readonly batchSinks: BridgeProductBatchFrameSinks;
	readonly postedMessages: PostedBridgeWorkerRuntimeMessage[];
	readonly scheduledDrains: BridgeCommWorkerPreparationDrain[];
}

async function createFileBackpressureHarness(
	throwForRequestId?: string,
): Promise<FileBackpressureHarness> {
	const events = new BridgeProductBoundedAsyncQueue<never>(64);
	const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
	const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
	const subscription: FileMetadataSubscription = {
		cancel: async (): Promise<void> => {},
		events,
		subscriptionId: 'file-subscription-existing-owner-backpressure',
		subscriptionKind: 'file.metadata',
	};
	const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort({
		beforePostMessage: (message): void => {
			if (message.kind === 'health' && message.requestId === throwForRequestId) {
				throw new Error('injected correlated response failure');
			}
		},
	});
	registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
		bridgeDemandRank: { lane: 'selected', priority: 0 },
		budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
		fileViewBudget: fileViewProductTestBudget,
		productTransport: makeFileProductTestTransport({
			onBatchFrameSinks: (sinks): void => {
				batchSinks.current = sinks;
			},
			onDiscoverSource: (): void => {},
			onOpenDescriptor: (): void => {},
			subscription,
		}),
		schedulePreparationDrain: (drain): void => {
			scheduledDrains.push(drain);
		},
	});
	await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'existing-owner-backpressure');
	if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
	await batchSinks.current.install(makeFileBatchInstallation('open', subscription.subscriptionId));
	await flushBridgeWorkerRuntimeContinuations();
	const harness = { batchSinks: batchSinks.current, dispatch, postedMessages, scheduledDrains };
	selectFile(harness, 1, 'selection-a');
	await drainFilePreparationUntilIdle(scheduledDrains);
	requireFilePublication(postedMessages, 0);
	return harness;
}

async function pushReplacementFileSource(harness: FileBackpressureHarness): Promise<void> {
	const installation = makeFileBatchInstallation(
		'open',
		'file-subscription-existing-owner-backpressure',
		{
			revision: 5,
		},
	);
	const replacementSource = {
		...bridgeProductFileMemberStatusRecordSchema.parse(
			installation.records.find((record) => record.key === BRIDGE_PRODUCT_FILE_MEMBER_STATUS_KEY)
				?.value,
		).source,
		sourceCursor: 'source-cursor-2',
		sourceId: 'source-2',
		subscriptionGeneration: 12,
	};
	const replacementRecords: Array<BridgeProductViewInstallation['records'][number]> = [];
	for (const record of installation.records) {
		if (record.key === BRIDGE_PRODUCT_FILE_MEMBER_STATUS_KEY) {
			const status = bridgeProductFileMemberStatusRecordSchema.parse(record.value);
			replacementRecords.push({ ...record, value: { ...status, source: replacementSource } });
			continue;
		}
		const row = bridgeProductFileBatchRowSchema.parse(record.value);
		if (row.kind !== 'file' || row.readDescriptor === null) {
			replacementRecords.push(record);
			continue;
		}
		const descriptor = { ...row.readDescriptor, source: replacementSource };
		const outcome = row.descriptorOutcome;
		if (outcome?.availability.availabilityKind !== 'available') {
			throw new Error('Expected available replacement File descriptor.');
		}
		replacementRecords.push({
			...record,
			value: {
				...row,
				descriptorOutcome: {
					...outcome,
					availability: { ...outcome.availability, contentDescriptor: descriptor },
					source: replacementSource,
				},
				readDescriptor: descriptor,
			},
		});
	}
	const replacementInstallation: BridgeProductViewInstallation = {
		...installation,
		records: replacementRecords,
	};
	await harness.batchSinks.install(replacementInstallation);
}

function reviewSource(
	itemIds: readonly string[],
	generation: number,
): BridgeCommWorkerReviewProductTestSourceInput {
	return {
		contentItems: itemIds.map((itemId) => makeWorkerReviewContentMetadata({ itemId })),
		contentRequestDescriptors: itemIds.flatMap((itemId) => [
			makeContentRequestDescriptor({
				generation,
				itemId,
				role: 'base',
				text: `generation ${generation} base ${itemId}\n`,
			}),
			makeContentRequestDescriptor({
				generation,
				itemId,
				role: 'head',
				text: `generation ${generation} head ${itemId}\n`,
			}),
		]),
		renderSemantics: itemIds.map((itemId) => makeRenderSemantics({ itemId })),
		rows: itemIds.map((itemId, index) => ({ id: itemId, index, parentId: null })),
	};
}

async function drainReviewPreparationUntilPublicationCount(props: {
	readonly expectedCount: number;
	readonly postedMessages: readonly PostedBridgeWorkerRuntimeMessage[];
	readonly scheduledDrains: BridgeCommWorkerPreparationDrain[];
}): Promise<void> {
	const drainCompletions: Array<ReturnType<BridgeCommWorkerPreparationDrain>> = [];
	for (let round = 0; round < 32; round += 1) {
		const drains = props.scheduledDrains.splice(0);
		drainCompletions.push(...drains.map((drain) => drain()));
		// oxlint-disable-next-line no-await-in-loop -- Each bounded round exposes event-scheduled follow-up drains.
		await flushBridgeWorkerRuntimeContinuations();
		if (
			reviewPublications(props.postedMessages).length >= props.expectedCount &&
			props.scheduledDrains.length === 0
		) {
			// oxlint-disable-next-line no-await-in-loop -- The bounded success branch joins all cooperative drains before returning.
			await Promise.all(drainCompletions);
			// oxlint-disable-next-line no-await-in-loop -- One final microtask flush observes drain completions before returning.
			await flushBridgeWorkerRuntimeContinuations();
			return;
		}
	}
	throw new Error(`Expected ${props.expectedCount} Review publications.`);
}

function dispatchReviewQueuedBatch(
	dispatch: ReturnType<typeof createRecordingBridgeCommWorkerPort>['dispatch'],
	publications: readonly BridgeWorkerReviewPierreRenderJobEvent[],
): void {
	const firstPublication = publications[0];
	if (firstPublication === undefined) throw new Error('Expected Review publications to queue.');
	dispatch.message(
		encodeBridgeWorkerRenderDispositionCommand({
			epoch: firstPublication.workerDerivationEpoch,
			receipts: publications.map((publication) =>
				bridgeWorkerRenderDispositionReceiptSchema.parse({
					...publication.renderReceiptIdentity,
					disposition: 'queued',
					kind: 'render.disposition',
					receivedAtMilliseconds: 0,
				}),
			),
			requestId: 'request-source-a-queued-after-source-b',
		}),
	);
}

function reviewPublications(
	postedMessages: readonly PostedBridgeWorkerRuntimeMessage[],
): readonly BridgeWorkerReviewPierreRenderJobEvent[] {
	return postedMessages.flatMap(({ message }) =>
		message.kind === 'reviewPierreRenderJob' ? [message] : [],
	);
}

function selectFile(harness: FileBackpressureHarness, epoch: number, requestLabel: string): void {
	harness.dispatch.message(
		encodeBridgeWorkerSelectCommand({
			epoch,
			requestId: `request-${requestLabel}`,
			selectedItemId: 'file-1',
			selectedSource: 'user',
			surface: 'fileView',
		}),
	);
}

function dispatchFileDisposition(
	harness: FileBackpressureHarness,
	publication: BridgeWorkerFilePierreRenderJobEvent,
	disposition: 'queued' | 'applied' | 'painted',
	requestId: string,
): void {
	harness.dispatch.message(
		encodeBridgeWorkerRenderDispositionCommand({
			epoch: publication.workerDerivationEpoch,
			receipts: [
				bridgeWorkerRenderDispositionReceiptSchema.parse({
					...publication.renderReceiptIdentity,
					disposition,
					kind: 'render.disposition',
					receivedAtMilliseconds: 0,
				}),
			],
			requestId,
		}),
	);
}

function dispatchTerminalFileDisposition(
	harness: FileBackpressureHarness,
	publication: BridgeWorkerFilePierreRenderJobEvent,
	disposition: 'rejected' | 'superseded',
): void {
	harness.dispatch.message(
		encodeBridgeWorkerRenderDispositionCommand({
			epoch: publication.workerDerivationEpoch,
			receipts: [
				bridgeWorkerRenderDispositionReceiptSchema.parse({
					...publication.renderReceiptIdentity,
					disposition,
					kind: 'render.disposition',
					reason: 'stale_attempt',
					receivedAtMilliseconds: 0,
					retryAtMilliseconds: 0,
				}),
			],
			requestId: `request-a-${disposition}`,
		}),
	);
}

function filePublications(
	postedMessages: readonly PostedBridgeWorkerRuntimeMessage[],
): readonly BridgeWorkerFilePierreRenderJobEvent[] {
	return postedMessages.flatMap(({ message }) =>
		message.kind === 'filePierreRenderJob' ? [message] : [],
	);
}

function requireFilePublication(
	postedMessages: readonly PostedBridgeWorkerRuntimeMessage[],
	index: number,
): BridgeWorkerFilePierreRenderJobEvent {
	const publication = filePublications(postedMessages)[index];
	if (publication === undefined) throw new Error(`Expected File publication ${index + 1}.`);
	return publication;
}

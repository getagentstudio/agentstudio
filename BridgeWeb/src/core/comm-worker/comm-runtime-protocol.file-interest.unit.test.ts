import { describe, expect, test } from 'vitest';

import {
	encodeBridgeWorkerFileDisplayResyncCommand,
	encodeBridgeWorkerSelectCommand,
} from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerFileViewerModeAndFlush,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
	type FileMetadataSubscription,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import type { BridgeWorkerFileDisplayPatchEvent } from './bridge-worker-contracts.js';
import {
	makeFileBatchInstallation,
	makeFileProductTestTransport as makeProductTransport,
} from './comm-runtime-protocol.file-product.test-support.js';

describe('Bridge comm worker File interest after typed installation', () => {
	test('reports File interest failure without resetting the stream and retries on later source progress', async () => {
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const updatedInterests: unknown[] = [];
		let updateAttemptCount = 0;
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-interest-failure',
			subscriptionKind: 'file.metadata',
		};
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeProductTransport({
				onBatchFrameSinks: (sinks): void => {
					batchSinks.current = sinks;
				},
				onDiscoverSource: (): void => {},
				onFileScope: (scope): void => {
					updateAttemptCount += 1;
					if (updateAttemptCount === 1) throw new Error('scope admission failed');
					updatedInterests.push({ interests: scope.interests, pathScope: scope.pathScope });
				},
				onOpenDescriptor: (): void => {},
				subscription,
			}),
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'interest-failure');
		if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', subscription.subscriptionId, {
				revision: 1,
				withDescriptor: false,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 2,
				requestId: 'request-select-interest-failure',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(updateAttemptCount).toBe(1);

		await batchSinks.current.install(
			makeFileBatchInstallation('open', subscription.subscriptionId, {
				revision: 2,
				withDescriptor: false,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expect(postedMessages.map(({ message }) => message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				message: 'Bridge File metadata interest update failed.',
				status: 'degraded',
			}),
		);
		expect(updateAttemptCount).toBe(2);
		expect(updatedInterests).toEqual([
			{
				interests: [{ lane: 'foreground', paths: ['src/a.ts'] }],
				pathScope: [],
			},
		]);
		expect(postedMessages.map(({ message }) => message)).not.toContainEqual(
			expect.objectContaining({
				message: 'Bridge File metadata subscription failed.',
			}),
		);
		const fileDisplayEvents = postedMessages
			.map(({ message }) => message)
			.filter(
				(message): message is BridgeWorkerFileDisplayPatchEvent =>
					message.kind === 'fileDisplayPatch',
			);
		expect(fileDisplayEvents).toHaveLength(3);
		const fileDisplaySequences = fileDisplayEvents.map((event) => event.sequence);
		expect(new Set(fileDisplaySequences).size).toBe(fileDisplaySequences.length);
		expect(fileDisplaySequences).toEqual(
			fileDisplaySequences.toSorted((left, right) => left - right),
		);
		expect(fileDisplayEvents.map((event) => event.projectionRevision)).toEqual([1, 2, 3]);
		expect(fileDisplayEvents[2]?.patches).toContainEqual(
			expect.objectContaining({ operation: 'upsert', slice: 'fileQuery' }),
		);
		expect(fileDisplayEvents[2]?.patches).toContainEqual(
			expect.objectContaining({ operation: 'replacementCommit', slice: 'fileTree' }),
		);
		expect(fileDisplaySequences[2]).toBeGreaterThan(fileDisplaySequences[1] ?? -1);
	});

	test('replays authoritative File display state at the active worker derivation epoch', async () => {
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-resync',
			subscriptionKind: 'file.metadata',
		};
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeProductTransport({
				onBatchFrameSinks: (sinks): void => {
					batchSinks.current = sinks;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (): void => {},
				subscription,
			}),
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'display-resync');
		if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', subscription.subscriptionId),
		);
		await flushBridgeWorkerRuntimeContinuations();
		const messagesBeforeResync = postedMessages.length;
		const lastProjectionRevision = Math.max(
			...postedMessages.flatMap(({ message }): readonly number[] =>
				message.kind === 'fileDisplayPatch' ? [message.projectionRevision] : [],
			),
		);

		dispatch.message(
			encodeBridgeWorkerFileDisplayResyncCommand({
				epoch: 99,
				reason: 'acknowledgementTimeout',
				requestId: 'request-file-display-resync',
				transactionId: 'file-query-7',
			}),
		);

		const resyncEvents = postedMessages
			.slice(messagesBeforeResync)
			.map(({ message }) => message)
			.filter(
				(message): message is BridgeWorkerFileDisplayPatchEvent =>
					message.kind === 'fileDisplayPatch',
			);
		expect(resyncEvents.length).toBeGreaterThan(0);
		expect(resyncEvents.every((event) => event.epoch === 1)).toBe(true);
		expect(resyncEvents[0]?.projectionRevision).toBeGreaterThan(lastProjectionRevision);
		const patches = resyncEvents.flatMap((event) => event.patches);
		expect(patches.slice(0, 3)).toEqual([
			{
				operation: 'reset',
				payload: { sourceGeneration: 11, sourceId: 'source-1' },
				slice: 'fileTree',
			},
			{ operation: 'reset', slice: 'fileItem' },
			{ operation: 'reset', slice: 'fileStatus' },
		]);
		expect(patches).toContainEqual(
			expect.objectContaining({ itemId: 'file-1', slice: 'fileItem' }),
		);
		expect(patches).toContainEqual(expect.objectContaining({ slice: 'fileQuery' }));
		expect(patches).toContainEqual(expect.objectContaining({ slice: 'fileTree' }));
	});
});

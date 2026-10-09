import { describe, expect, test } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import {
	encodeBridgeWorkerActiveViewerModeUpdateCommand,
	encodeBridgeWorkerRenderDispositionCommand,
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import {
	registerBridgeCommWorkerRuntimePortProtocol,
	type BridgeCommWorkerPreparationDrain,
} from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerFileViewerMode,
	activateBridgeCommWorkerFileViewerModeAndFlush,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
	type FileMetadataSubscription,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import type { BridgeProductPanePresentationFrame } from './bridge-product-transport.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';
import { parseBridgeWorkerFileDisplayPatchEvent } from './bridge-worker-contract-parsers.js';
import type {
	BridgeWorkerFileDisplayPatchEvent,
	BridgeWorkerFilePierreRenderJobEvent,
	BridgeWorkerFileRenderPatchEvent,
} from './bridge-worker-contracts.js';
import { bridgeWorkerRenderDispositionReceiptSchema } from './bridge-worker-render-fulfillment.js';
import {
	drainFilePreparationUntilIdle,
	fileViewProductTestBudget,
	makeFilePanePresentationFrame,
	makeFileBatchInstallation,
	makeFileProductTestTransport as makeProductTransport,
	makeReviewBatchInstallation,
	requireFilePanePresentationSink,
} from './comm-runtime-protocol.file-product.test-support.js';

describe('Bridge comm worker File product runtime', () => {
	test('records whether File select resolved a worker-owned metadata path', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-select-path-telemetry',
			subscriptionKind: 'file.metadata',
		};
		const { dispatch } = createRecordingBridgeCommWorkerPort();
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
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'selected-path-telemetry');

		// Act
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 1,
				requestId: 'request-select-before-file-path',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', subscription.subscriptionId),
		);
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 2,
				requestId: 'request-select-after-file-path',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: 3,
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
				requestId: 'request-viewport-after-file-path',
				surface: 'fileView',
				visibleItemIds: ['file-1'],
			}),
		);

		// Assert
		const messageHandlerSamples = telemetrySamples.filter(
			(sample): boolean =>
				sample.name === 'performance.bridge.worker.task' &&
				sample.stringAttributes['agentstudio.bridge.worker.task_kind'] === 'message_handler',
		);
		const fileSelectSamples = messageHandlerSamples.filter(
			(sample): boolean =>
				sample.stringAttributes['agentstudio.bridge.worker.command'] === 'select',
		);
		expect(
			fileSelectSamples.map(
				(sample) =>
					sample.booleanAttributes[
						'agentstudio.bridge.worker.file_metadata_selected_path_resolved'
					],
			),
		).toEqual([false, true]);
		const viewportSample = messageHandlerSamples.find(
			(sample) => sample.stringAttributes['agentstudio.bridge.worker.command'] === 'viewport',
		);
		expect(viewportSample).toBeDefined();
		expect(viewportSample?.booleanAttributes).not.toHaveProperty(
			'agentstudio.bridge.worker.file_metadata_selected_path_resolved',
		);
	});

	test('default scheduler opens selected File content after sustained viewport churn', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const openedDescriptorIds: string[] = [];
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-default-scheduler',
			subscriptionKind: 'file.metadata',
		};
		const { dispatch } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			fileViewBudget: fileViewProductTestBudget,
			productTransport: makeProductTransport({
				onBatchFrameSinks: (sinks): void => {
					batchSinks.current = sinks;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (descriptorId): void => {
					openedDescriptorIds.push(descriptorId);
				},
				subscription,
			}),
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'default-scheduler');
		if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', subscription.subscriptionId),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(openedDescriptorIds).toEqual([]);

		// Act
		for (let viewportIndex = 0; viewportIndex < 64; viewportIndex += 1) {
			dispatch.message(
				encodeBridgeWorkerViewportCommand({
					epoch: viewportIndex + 1,
					firstVisibleIndex: 0,
					lastVisibleIndex: 0,
					phase: viewportIndex === 63 ? 'settled' : 'momentum',
					requestId: `request-default-scheduler-viewport-${viewportIndex}`,
					surface: 'fileView',
					visibleItemIds: ['file-1'],
				}),
			);
		}
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 65,
				requestId: 'request-default-scheduler-select',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(openedDescriptorIds).toEqual(['file-descriptor-1']);
	});

	test('keeps File content demand eligible after concurrent Review source acceptance', async () => {
		// Arrange
		const fileEvents = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const openedDescriptorIds: string[] = [];
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const fileSubscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events: fileEvents,
			subscriptionId: 'file-subscription-cross-surface-store-isolation',
			subscriptionKind: 'file.metadata',
		};
		const { dispatch } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			fileViewBudget: fileViewProductTestBudget,
			productTransport: makeProductTransport({
				onBatchFrameSinks: (sinks): void => {
					batchSinks.current = sinks;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (descriptorId): void => {
					openedDescriptorIds.push(descriptorId);
				},
				subscription: fileSubscription,
			}),
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		await flushBridgeWorkerRuntimeContinuations();
		activateBridgeCommWorkerFileViewerMode(dispatch, 'cross-surface-store-isolation');
		if (batchSinks.current === null) throw new Error('Product batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', fileSubscription.subscriptionId),
		);
		await flushBridgeWorkerRuntimeContinuations();
		await batchSinks.current.install(
			makeReviewBatchInstallation('open', 'review-subscription-for-file-runtime-test'),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(scheduledDrains).toHaveLength(0);

		// Act
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 1,
				requestId: 'request-select-file-after-review-source-acceptance',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		const pendingDrainCompletions: ReturnType<BridgeCommWorkerPreparationDrain>[] = [];
		while (scheduledDrains.length > 0) {
			const drain = scheduledDrains.shift();
			if (drain === undefined) break;
			pendingDrainCompletions.push(drain());
			await flushBridgeWorkerRuntimeContinuations();
		}
		await Promise.all(pendingDrainCompletions);

		// Assert
		expect(
			openedDescriptorIds,
			'FILE_REVIEW_STORE_ISOLATION_FAILED: Review source acceptance removed demand-eligible File metadata.',
		).toEqual(['file-descriptor-1']);
	});

	test('installs a File batch and opens demanded content without a main relay', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const updatedInterests: unknown[] = [];
		const openedDescriptorIds: string[] = [];
		const operationLifecycleSamples: BridgeTelemetrySample[] = [];
		let sourceDiscoveryCount = 0;
		const createdSequences: number[] = [];
		let nextSequence = 100;
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		};
		const productTransport = makeProductTransport({
			onBatchFrameSinks: (sinks): void => {
				batchSinks.current = sinks;
			},
			onDiscoverSource: (): void => {
				sourceDiscoveryCount += 1;
			},
			onOpenDescriptor: (descriptorId): void => {
				openedDescriptorIds.push(descriptorId);
			},
			onFileScope: (scope): void => {
				updatedInterests.push({ interests: scope.interests, pathScope: scope.pathScope });
			},
			subscription,
		});
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			createSequence: (): number => {
				const sequence = nextSequence;
				nextSequence += 1;
				createdSequences.push(sequence);
				return sequence;
			},
			fileViewBudget: fileViewProductTestBudget,
			productTransport,
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
			telemetryClient: {
				record: (sample): void => {
					operationLifecycleSamples.push(sample);
				},
			},
		});

		// Act
		activateBridgeCommWorkerFileViewerMode(dispatch, 'main-relay-hard-cut');
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 1,
				requestId: 'request-select-file-1',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', subscription.subscriptionId),
		);
		await flushBridgeWorkerRuntimeContinuations();
		const firstDrain = scheduledDrains.shift();
		if (firstDrain === undefined) throw new Error('Expected selected File preparation drain.');
		const firstDrainCompletion = firstDrain();
		await flushBridgeWorkerRuntimeContinuations();
		const secondDrain = scheduledDrains.shift();
		if (secondDrain === undefined) throw new Error('Expected resumed File preparation drain.');
		await secondDrain();
		await firstDrainCompletion;
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(updatedInterests).toEqual([
			{
				interests: [{ lane: 'foreground', paths: ['src/a.ts'] }],
				pathScope: [],
			},
		]);
		expect(openedDescriptorIds).toEqual(['file-descriptor-1']);
		expect(sourceDiscoveryCount).toBe(1);
		expect(postedMessages.map(({ message }) => message.kind)).toContain('filePierreRenderJob');
		expect(postedMessages.map(({ message }) => message.kind)).toContain('fileRenderPatch');
		const fileRenderPublications = postedMessages
			.map(({ message }) => message)
			.filter(
				(
					message,
				): message is BridgeWorkerFilePierreRenderJobEvent | BridgeWorkerFileRenderPatchEvent =>
					message.kind === 'filePierreRenderJob' ||
					(message.kind === 'fileRenderPatch' &&
						message.patches.some((patch): boolean => patch.slice !== 'panelChrome')),
			);
		expect(fileRenderPublications).toHaveLength(2);
		expect(
			fileRenderPublications.every(
				(publication) => publication.surface === 'file' && publication.workerDerivationEpoch === 1,
			),
		).toBe(true);
		const fileRenderPublicationSequences = fileRenderPublications.map(
			(publication) => publication.publicationSequence,
		);
		expect(new Set(fileRenderPublicationSequences).size).toBe(1);
		expect(
			fileRenderPublicationSequences.every((sequence) => createdSequences.includes(sequence)),
		).toBe(true);
		const fileDisplayPatchEvents = postedMessages
			.filter(
				(
					posted,
				): posted is typeof posted & { readonly message: BridgeWorkerFileDisplayPatchEvent } =>
					posted.message.kind === 'fileDisplayPatch',
			)
			.map(({ message }) => parseBridgeWorkerFileDisplayPatchEvent(message));
		expect(fileDisplayPatchEvents).toHaveLength(3);
		expect(fileDisplayPatchEvents.map((event) => event.epoch)).toEqual([1, 1, 1]);
		expect(fileDisplayPatchEvents.map((event) => event.projectionRevision)).toEqual([1, 2, 3]);
		const fileDisplaySequences = fileDisplayPatchEvents.map((event) => event.sequence);
		expect(fileDisplaySequences).toEqual(
			fileDisplaySequences.toSorted((left, right) => left - right),
		);
		expect(fileDisplaySequences.every((sequence) => createdSequences.includes(sequence))).toBe(
			true,
		);
		expect(fileDisplayPatchEvents[0]).toMatchObject({
			kind: 'fileDisplayPatch',
			patches: expect.arrayContaining([
				{
					operation: 'reset',
					payload: { sourceGeneration: 11, sourceId: 'source-1' },
					slice: 'fileTree',
				},
				{ operation: 'reset', slice: 'fileItem' },
				{ operation: 'reset', slice: 'fileStatus' },
			]),
			surface: 'fileView',
		});
		expect(JSON.stringify(fileDisplayPatchEvents[2])).not.toMatch(
			/contentDescriptor|descriptorId|expectedSha256|sourceCursor|leaseId/,
		);
		expect(
			postedMessages.find(({ message }) => message.kind === 'filePierreRenderJob')?.message,
		).toMatchObject({
			job: {
				itemId: 'file-1',
				payload: { item: { file: { contents: 'abc' } }, kind: 'codeViewFileItem' },
				renderKind: 'fileText',
			},
			kind: 'filePierreRenderJob',
			surface: 'file',
			workerDerivationEpoch: 1,
		});
		const fileRenderPublication = postedMessages.find(
			(
				posted,
			): posted is typeof posted & { readonly message: BridgeWorkerFilePierreRenderJobEvent } =>
				posted.message.kind === 'filePierreRenderJob',
		)?.message;
		if (fileRenderPublication === undefined) {
			throw new Error('Expected the selected File render publication.');
		}
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: 2,
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
				requestId: 'request-advance-file-intent-after-publication',
				surface: 'fileView',
				visibleItemIds: ['file-1'],
			}),
		);
		dispatch.message(
			encodeBridgeWorkerRenderDispositionCommand({
				epoch: fileRenderPublication.workerDerivationEpoch,
				receipts: [
					bridgeWorkerRenderDispositionReceiptSchema.parse({
						...fileRenderPublication.renderReceiptIdentity,
						disposition: 'queued',
						kind: 'render.disposition',
						receivedAtMilliseconds: 0,
					}),
				],
				requestId: 'request-production-stamped-file-queued',
			}),
		);
		for (const disposition of ['applied', 'painted'] as const) {
			dispatch.message(
				encodeBridgeWorkerRenderDispositionCommand({
					epoch: fileRenderPublication.workerDerivationEpoch,
					receipts: [
						bridgeWorkerRenderDispositionReceiptSchema.parse({
							...fileRenderPublication.renderReceiptIdentity,
							disposition,
							kind: 'render.disposition',
							receivedAtMilliseconds: 0,
						}),
					],
					requestId: `request-production-stamped-file-${disposition}`,
				}),
			);
		}
		expect(
			postedMessages.find(
				({ message }) =>
					message.kind === 'health' &&
					message.requestId === 'request-production-stamped-file-queued',
			)?.message,
		).toMatchObject({ status: 'ready' });
		const selectedOperationSamples = operationLifecycleSamples.filter(
			(sample) => sample.name === 'performance.bridge.web.operation_lifecycle',
		);
		const operationCorrelationIds = new Set(
			selectedOperationSamples.map(
				(sample) => sample.stringAttributes['agentstudio.bridge.operation.id'],
			),
		);
		expect(operationCorrelationIds.size).toBe(1);
		expect([...operationCorrelationIds][0]).toMatch(/^[0-9a-f]{64}$/);
		expect(
			selectedOperationSamples.map((sample) => sample.stringAttributes['agentstudio.bridge.phase']),
		).toEqual([
			'worker_application_started',
			'file_content_operation_started',
			'file_descriptor_wait_started',
			'file_descriptor_wait_terminal',
			'content_operation_started',
			'content_operation_terminal',
			'render_operation_started',
			'main_thread_install_started',
			'paint_fulfillment_started',
			'main_thread_install_terminal',
			'render_operation_terminal',
			'paint_fulfillment_terminal',
			'file_content_operation_terminal',
			'worker_application_terminal',
		]);
		expect(
			selectedOperationSamples.every(
				(sample) => sample.numericAttributes['agentstudio.bridge.stage.attempt'] === 0,
			),
		).toBe(true);
	});

	test('releases background Review warm-up once after the selected File descriptor', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		let reviewWarmupCount = 0;
		const { dispatch } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeProductTransport({
				onBatchFrameSinks: (sinks): void => {
					batchSinks.current = sinks;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (): void => {},
				onReviewWarmup: (): void => {
					reviewWarmupCount += 1;
				},
				subscription: {
					cancel: async (): Promise<void> => {},
					events,
					subscriptionId: 'file-subscription-review-warmup',
					subscriptionKind: 'file.metadata',
				},
			}),
		});
		activateBridgeCommWorkerFileViewerMode(dispatch, 'review-warmup');
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 1,
				requestId: 'request-select-review-warmup-file',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		// Act / Assert
		if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', 'file-subscription-review-warmup', {
				revision: 1,
				withDescriptor: false,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(reviewWarmupCount).toBe(0);

		await batchSinks.current.install(
			makeFileBatchInstallation('open', 'file-subscription-review-warmup', { revision: 2 }),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(reviewWarmupCount).toBe(1);

		await batchSinks.current.install(
			makeFileBatchInstallation('open', 'file-subscription-review-warmup', { revision: 3 }),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(reviewWarmupCount).toBe(1);
	});

	test('releases background Review warm-up for an empty File tree', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		let reviewWarmupCount = 0;
		const { dispatch } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeProductTransport({
				onBatchFrameSinks: (sinks): void => {
					batchSinks.current = sinks;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (): void => {},
				onReviewWarmup: (): void => {
					reviewWarmupCount += 1;
				},
				subscription: {
					cancel: async (): Promise<void> => {},
					events,
					subscriptionId: 'file-subscription-empty-review-warmup',
					subscriptionKind: 'file.metadata',
				},
			}),
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'empty-review-warmup');

		// Act
		if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', 'file-subscription-empty-review-warmup', {
				emptyTree: true,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(reviewWarmupCount).toBe(1);
	});

	test('does not replay completed File preparation when native foreground returns to Review', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const openedDescriptorIds: string[] = [];
		const pump = createWorkerContentPreparationPump({ maxSliceMs: 8 });
		let panePresentationSink: ((frame: BridgeProductPanePresentationFrame) => void) | null = null;
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			fileViewBudget: fileViewProductTestBudget,
			pump,
			productTransport: makeProductTransport({
				onBatchFrameSinks: (sinks): void => {
					batchSinks.current = sinks;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (descriptorId): void => {
					openedDescriptorIds.push(descriptorId);
				},
				onPanePresentationSink: (sink): void => {
					panePresentationSink = sink;
				},
				subscription: {
					cancel: async (): Promise<void> => {},
					events,
					subscriptionId: 'file-subscription-completed-foreground-return',
					subscriptionKind: 'file.metadata',
				},
			}),
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		await flushBridgeWorkerRuntimeContinuations();
		if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', 'file-subscription-completed-foreground-return'),
		);
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				epoch: 1,
				requestId: 'request-file-mode-before-completed-preparation',
				update: {
					activeSource: null,
					mode: 'file',
					nativeSelectionRequestId: null,
					sequence: 1,
					sessionId: 'file-completed-foreground-return-session',
				},
			}),
		);
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 2,
				requestId: 'request-file-completed-foreground-return-selection',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		await drainFilePreparationUntilIdle(scheduledDrains);
		expect(openedDescriptorIds).toEqual(['file-descriptor-1']);

		// Act
		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				epoch: 3,
				requestId: 'request-review-mode-before-file-foreground-return',
				update: {
					activeSource: null,
					mode: 'review',
					nativeSelectionRequestId: null,
					sequence: 2,
					sessionId: 'file-completed-foreground-return-session',
				},
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		const messageCountBeforeNativeCycle = postedMessages.length;
		requireFilePanePresentationSink(panePresentationSink)(
			makeFilePanePresentationFrame(2, 'loadedHidden'),
		);
		requireFilePanePresentationSink(panePresentationSink)(
			makeFilePanePresentationFrame(3, 'foreground'),
		);
		const pendingWorkIdsAfterNativeCycle = pump.getPendingWorkIds();
		pump.runUntilBudget();
		await flushBridgeWorkerRuntimeContinuations();
		await drainFilePreparationUntilIdle(scheduledDrains);

		// Assert
		expect(pendingWorkIdsAfterNativeCycle).toEqual([]);
		expect(openedDescriptorIds).toEqual(['file-descriptor-1']);
		expect(
			postedMessages
				.slice(messageCountBeforeNativeCycle)
				.map(({ message }) => message)
				.filter(
					(message) =>
						message.kind === 'filePierreRenderJob' ||
						(message.kind === 'fileRenderPatch' &&
							message.patches.some((patch): boolean => patch.slice !== 'panelChrome')),
				),
		).toEqual([]);
	});

	test('reports File source discovery transport failure without synthesizing unavailable', async () => {
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		let subscriptionCount = 0;
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeProductTransport({
				discoveryError: new Error('current File source call failed'),
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (): void => {},
				onSubscribe: (): void => {
					subscriptionCount += 1;
				},
				subscription: {
					cancel: async (): Promise<void> => {},
					events,
					subscriptionId: 'file-subscription-discovery-failure',
					subscriptionKind: 'file.metadata',
				},
			}),
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'discovery-failure');

		expect(subscriptionCount).toBe(0);
		expect(postedMessages.map(({ message }) => message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				message: 'Bridge File metadata subscription failed.',
				status: 'degraded',
			}),
		);
	});

	test('marks retained File metadata failed without publishing empty source truth after stream failure', async () => {
		// Arrange: the complete File tree is already authoritative before transport fails.
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		let reviewWarmupCount = 0;
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
				onReviewWarmup: (): void => {
					reviewWarmupCount += 1;
				},
				subscription: {
					cancel: async (): Promise<void> => {},
					events,
					subscriptionId: 'file-subscription-runtime-failure',
					subscriptionKind: 'file.metadata',
				},
			}),
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'metadata-failure');
		if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', 'file-subscription-runtime-failure'),
		);
		await flushBridgeWorkerRuntimeContinuations();

		const messageCountBeforeFailure = postedMessages.length;
		// Act
		events.fail(new Error('metadata stream failed'), true);
		await flushBridgeWorkerRuntimeContinuations();

		// Assert: loss of delivery is not evidence that files or rendered content were deleted.
		const fileDisplayEvents = postedMessages
			.slice(messageCountBeforeFailure)
			.map(({ message }) => message)
			.filter((message) => message.kind === 'fileDisplayPatch');
		expect(fileDisplayEvents.at(-1)).toMatchObject({
			epoch: 1,
			patches: [{ operation: 'upsert', payload: { state: 'failed' }, slice: 'fileStatus' }],
		});
		expect(
			postedMessages
				.slice(messageCountBeforeFailure)
				.flatMap(({ message }) => (message.kind === 'fileRenderPatch' ? message.patches : [])),
		).not.toContainEqual({ operation: 'reset', slice: 'contentAvailability' });
		expect(postedMessages.map(({ message }) => message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				message: 'Bridge File metadata subscription failed.',
				status: 'degraded',
			}),
		);
		expect(reviewWarmupCount).toBe(1);
	});

	test('prepares a selected File when a recovered delta installs after the metadata epoch failed', async () => {
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const openedDescriptorIds: string[] = [];
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-recovered-delta',
			subscriptionKind: 'file.metadata',
		};
		const { dispatch } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			fileViewBudget: fileViewProductTestBudget,
			productTransport: makeProductTransport({
				onBatchFrameSinks: (sinks): void => {
					batchSinks.current = sinks;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (descriptorId): void => {
					openedDescriptorIds.push(descriptorId);
				},
				subscription,
			}),
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'recovered-delta');
		if (batchSinks.current === null) throw new Error('File batch sinks were not installed.');
		await batchSinks.current.install(
			makeFileBatchInstallation('open', subscription.subscriptionId, {
				revision: 1,
				withDescriptor: false,
			}),
		);
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 1,
				requestId: 'select-before-recovered-delta',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		events.fail(new Error('metadata stream failed'), true);
		await flushBridgeWorkerRuntimeContinuations();

		await batchSinks.current.install(
			makeFileBatchInstallation('open', subscription.subscriptionId, { revision: 2 }),
		);
		await drainFilePreparationUntilIdle(scheduledDrains);

		expect(openedDescriptorIds).toEqual(['file-descriptor-1']);
	});
});

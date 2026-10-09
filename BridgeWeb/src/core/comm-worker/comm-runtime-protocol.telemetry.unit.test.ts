import { describe, expect, test } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import { encodeBridgeWorkerSelectCommand } from './bridge-comm-worker-protocol.js';
import {
	registerBridgeCommWorkerRuntimePortProtocol,
	type BridgeCommWorkerPreparationDrain,
} from './bridge-comm-worker-runtime-protocol.js';
import type { ReviewMetadataSubscription } from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import {
	activateBridgeCommWorkerFileViewerModeAndFlush,
	activateBridgeCommWorkerReviewViewerMode,
	assertBridgeCommWorkerPreparationDrain,
	createIdleWorktreeAnnotationSubscription,
	createDeferredReviewContentStream,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
	makeContentRequestDescriptor,
	type FileMetadataSubscription,
	type DeferredReviewContentStream,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import type {
	BridgeProductPanePresentationFrame,
	BridgeProductTransportSession,
} from './bridge-product-transport.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';
import type { BridgeWorkerReviewContentRequestDescriptor } from './bridge-worker-contracts.js';
import { makeReviewBatchInstallation } from './comm-runtime-protocol.file-product.test-support.js';

const currentFileSourceConfiguration = {
	cwdScope: null,
	freshness: 'live',
	includeStatuses: true,
	repoId: '00000000-0000-4000-8000-000000000001',
	rootPathToken: 'telemetry-root-token',
	worktreeId: '00000000-0000-4000-8000-000000000002',
} as const;

describe('Bridge comm worker runtime protocol telemetry', () => {
	test('records unavailable as the sole terminal outcome of initial File source discovery', async () => {
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const reviewMetadataEvents = new BridgeProductBoundedAsyncQueue<never>(8);
		const { dispatch } = createRecordingBridgeCommWorkerPort();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			productTransport: makeTelemetryReviewProductTransport({
				deferredStreamsByDescriptorId: new Map(),
				fileSourceDiscovery: async () => ({
					reason: 'no-file-source-authority',
					status: 'unavailable',
				}),
				reviewMetadataEvents,
			}),
			schedulePreparationDrain: (): void => {},
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'unavailable-telemetry');

		const discoverySamples = telemetrySamples.filter(
			(sample) =>
				sample.stringAttributes['agentstudio.bridge.worker.command'] === 'fileSourceDiscovery',
		);
		expect(discoverySamples).toHaveLength(1);
		expect(discoverySamples).toContainEqual(
			expect.objectContaining({
				name: 'performance.bridge.worker.task',
				stringAttributes: expect.objectContaining({
					'agentstudio.bridge.phase': 'worker_task',
					'agentstudio.bridge.result': 'unavailable',
					'agentstudio.bridge.worker.command': 'fileSourceDiscovery',
					'agentstudio.bridge.worker.task_kind': 'product_control',
				}),
			}),
		);
	});

	test('maps available File source discovery to the accepted success result', async () => {
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const reviewMetadataEvents = new BridgeProductBoundedAsyncQueue<never>(8);
		const { dispatch } = createRecordingBridgeCommWorkerPort();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			productTransport: makeTelemetryReviewProductTransport({
				deferredStreamsByDescriptorId: new Map(),
				fileSourceDiscovery: async () => ({
					source: currentFileSourceConfiguration,
					status: 'available',
				}),
				reviewMetadataEvents,
			}),
			schedulePreparationDrain: (): void => {},
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'available-telemetry');

		const discoverySamples = telemetrySamples.filter(
			(sample) =>
				sample.stringAttributes['agentstudio.bridge.worker.command'] === 'fileSourceDiscovery',
		);
		expect(discoverySamples).toHaveLength(1);
		expect(discoverySamples[0]?.stringAttributes['agentstudio.bridge.result']).toBe('success');
	});

	test('records a failed terminal outcome when File source discovery throws', async () => {
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const reviewMetadataEvents = new BridgeProductBoundedAsyncQueue<never>(8);
		const { dispatch } = createRecordingBridgeCommWorkerPort();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			productTransport: makeTelemetryReviewProductTransport({
				deferredStreamsByDescriptorId: new Map(),
				fileSourceDiscovery: async (): Promise<never> => {
					throw new Error('Expected File source discovery failure.');
				},
				reviewMetadataEvents,
			}),
			schedulePreparationDrain: (): void => {},
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		await activateBridgeCommWorkerFileViewerModeAndFlush(dispatch, 'failed-telemetry');

		const discoverySamples = telemetrySamples.filter(
			(sample) =>
				sample.stringAttributes['agentstudio.bridge.worker.command'] === 'fileSourceDiscovery',
		);
		expect(discoverySamples).toHaveLength(1);
		expect(discoverySamples[0]?.stringAttributes['agentstudio.bridge.result']).toBe('failed');
	});

	test('records command queue wait and handler duration from typed dispatch timestamp', () => {
		const clockReadings = [18, 22];
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const { dispatch } = createRecordingBridgeCommWorkerPort();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			now: () => {
				const value = clockReadings.shift();
				if (value === undefined) {
					throw new Error('Unexpected runtime clock read.');
				}
				return value;
			},
			schedulePreparationDrain: (): void => {},
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});

		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 3,
				issuedAtMilliseconds: 10,
				requestId: 'request-select',
				selectedItemId: 'item-1',
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		expect(telemetrySamples).toContainEqual(
			expect.objectContaining({
				name: 'performance.bridge.worker.task',
				durationMilliseconds: 4,
				stringAttributes: expect.objectContaining({
					'agentstudio.bridge.result': 'success',
					'agentstudio.bridge.worker.command': 'select',
					'agentstudio.bridge.worker.lane': 'selected',
					'agentstudio.bridge.worker.task_kind': 'message_handler',
				}),
				numericAttributes: expect.objectContaining({
					'agentstudio.bridge.worker.handler_duration_ms': 4,
					'agentstudio.bridge.worker.queue_wait_ms': 8,
				}),
			}),
		);
	});

	test('does not report a stale selected drop when an in-flight preparation is demoted', async () => {
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const reviewMetadataEvents = new BridgeProductBoundedAsyncQueue<never>(8);
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const batchSinks: { current: BridgeProductBatchFrameSinks | null } = { current: null };
		const deferredStreamsByDescriptorId = new Map<string, DeferredReviewContentStream>();
		const baseDescriptor = makeContentRequestDescriptor({
			itemId: 'item-1',
			role: 'base',
			text: 'base content\n',
		});
		const headDescriptor = makeContentRequestDescriptor({
			itemId: 'item-1',
			role: 'head',
			text: 'head content\n',
		});

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			productTransport: makeTelemetryReviewProductTransport({
				deferredStreamsByDescriptorId,
				onBatchFrameSinks: (sinks): void => {
					batchSinks.current = sinks;
				},
				reviewMetadataEvents,
			}),
			schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
				scheduledDrains.push(drain);
			},
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'stale-selected-telemetry');
		await flushBridgeWorkerRuntimeContinuations();
		if (batchSinks.current === null) throw new Error('Review batch sink was not installed.');
		const baseSource = reviewContentSourceFromDescriptor(baseDescriptor);
		const headSource = reviewContentSourceFromDescriptor(headDescriptor);
		const installation = makeReviewBatchInstallation('open', 'telemetry-review-subscription');
		await batchSinks.current.install({
			...installation,
			records: installation.records.map((record) => {
				const value = bridgeProductReviewBatchRecordSchema.parse(record.value);
				if (value.recordKind !== 'item') return record;
				return {
					...record,
					key: 'item-1',
					value: bridgeProductReviewBatchRecordSchema.parse({
						...value,
						itemId: 'item-1',
						contentByRole: {
							...value.contentByRole,
							base: {
								state: 'available',
								source: {
									...baseSource,
									packageId: 'review-package-1',
									reviewGeneration: 7,
									sourceIdentity: 'review-query-1',
								},
							},
							head: {
								state: 'available',
								source: {
									...headSource,
									packageId: 'review-package-1',
									reviewGeneration: 7,
									sourceIdentity: 'review-query-1',
								},
							},
						},
						contentHashesByRole: {
							...value.contentHashesByRole,
							base: baseDescriptor.contentDigest.value,
							head: headDescriptor.contentDigest.value,
						},
						extentByRole: { ...value.extentByRole, base: 1, head: 1 },
					}),
				};
			}),
		});
		await flushBridgeWorkerRuntimeContinuations();

		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 7,
				requestId: 'request-select-item-1',
				selectedItemId: 'item-1',
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		const firstDrain = assertBridgeCommWorkerPreparationDrain(scheduledDrains.shift())();

		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 8,
				requestId: 'request-select-item-2',
				selectedItemId: 'item-2',
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		deferredStreamsByDescriptorId.get(baseDescriptor.descriptorId)?.resolve('base content\n');
		deferredStreamsByDescriptorId.get(headDescriptor.descriptorId)?.resolve('head content\n');
		await flushBridgeWorkerRuntimeContinuations();
		await drainScheduledPreparation(scheduledDrains);
		await firstDrain;

		expect(
			telemetrySamples.some(
				(sample) => sample.name === 'performance.bridge.web.selected_content_dropped',
			),
		).toBe(false);
		expect(
			postedMessages.filter(
				(postedMessage) => postedMessage.message.kind === 'reviewPierreRenderJob',
			),
		).toHaveLength(1);
	});
});

function makeTelemetryReviewProductTransport(props: {
	readonly deferredStreamsByDescriptorId: Map<string, DeferredReviewContentStream>;
	readonly fileSourceDiscovery?: () => Promise<unknown>;
	readonly onBatchFrameSinks?: (sinks: BridgeProductBatchFrameSinks) => void;
	readonly reviewMetadataEvents: BridgeProductBoundedAsyncQueue<never>;
}): BridgeProductTransportSession {
	let fileWorkerDerivationEpoch = 0;
	let reviewWorkerDerivationEpoch = 0;
	let nextScopeRevision = 0;
	const fileMetadataEvents = new BridgeProductBoundedAsyncQueue<never>(8);
	const fileSubscription: FileMetadataSubscription = {
		cancel: async (): Promise<void> => {},
		events: fileMetadataEvents,
		subscriptionId: 'telemetry-file-subscription',
		subscriptionKind: 'file.metadata',
	};
	const reviewSubscription: ReviewMetadataSubscription = {
		cancel: async (): Promise<void> => {},
		events: props.reviewMetadataEvents,
		subscriptionId: 'telemetry-review-subscription',
		subscriptionKind: 'review.metadata',
	};
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			if (surface === 'file') fileWorkerDerivationEpoch += 1;
			if (surface === 'review') reviewWorkerDerivationEpoch += 1;
			return surface === 'review' ? reviewWorkerDerivationEpoch : fileWorkerDerivationEpoch;
		},
		call: async (...arguments_): Promise<never> => {
			const [method] = arguments_;
			if (
				method === 'file.activeViewerMode.update' ||
				method === 'review.activeViewerMode.update'
			) {
				return null as never;
			}
			if (method === 'file.source.current' && props.fileSourceDiscovery !== undefined) {
				return (await props.fileSourceDiscovery()) as never;
			}
			throw new Error(`Unexpected product call in Review telemetry test: ${method}.`);
		},
		openContent: (descriptor) => {
			if (descriptor.contentKind !== 'review.content') {
				throw new Error(`Unexpected product content kind ${descriptor.contentKind}.`);
			}
			const deferredStream = createDeferredReviewContentStream(descriptor);
			props.deferredStreamsByDescriptorId.set(descriptor.descriptorId, deferredStream);
			// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The content-kind guard above closes this test transport to Review streams.
			return deferredStream.stream as never;
		},
		setBatchFrameSinks: (sinks): void => props.onBatchFrameSinks?.(sinks),
		setViewScopeForSubscription: async () => ({
			kind: 'accepted',
			scopeRevision: ++nextScopeRevision,
		}),
		setPanePresentationFrameSink: (
			sink: (frame: BridgeProductPanePresentationFrame) => void,
		): void => {
			sink({
				fileRefreshFailure: null,
				presentationRevision: 1,
				kind: 'pane.presentation',

				operationCorrelationId: null,
				metadataStreamId: 'telemetry-review-metadata-stream',
				nativeActivity: 'foreground',
				paneSessionId: 'telemetry-review-pane-session',
				refreshingLanes: [],
				reviewComparison: null,
				streamSequence: 1,
				wireVersion: 2,
				workerInstanceId: 'telemetry-review-worker-instance',
			});
		},
		subscribe: (...arguments_): never => {
			const [{ kind: subscriptionKind }] = arguments_;
			if (subscriptionKind === 'file.annotations' || subscriptionKind === 'review.annotations') {
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The generic fixture closes over the requested annotation subscription kind.
				return createIdleWorktreeAnnotationSubscription(arguments_[0]) as never;
			}
			// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The closed subscription-kind branch selects the matching typed test subscription.
			return (
				subscriptionKind === 'file.metadata' ? fileSubscription : reviewSubscription
			) as never;
		},
		workerDerivationEpoch: (surface): number =>
			surface === 'review' ? reviewWorkerDerivationEpoch : fileWorkerDerivationEpoch,
	};
}

function reviewContentSourceFromDescriptor(
	descriptor: BridgeWorkerReviewContentRequestDescriptor,
): Pick<
	BridgeWorkerReviewContentRequestDescriptor,
	| 'contentDigest'
	| 'contentKind'
	| 'descriptorId'
	| 'encoding'
	| 'endpointId'
	| 'handleId'
	| 'isBinary'
	| 'itemId'
	| 'language'
	| 'mimeType'
	| 'packageId'
	| 'reviewGeneration'
	| 'role'
	| 'sourceIdentity'
	| 'wholeByteLength'
> {
	return {
		contentDigest: descriptor.contentDigest,
		contentKind: descriptor.contentKind,
		descriptorId: descriptor.descriptorId,
		encoding: descriptor.encoding,
		endpointId: descriptor.endpointId,
		handleId: descriptor.handleId,
		isBinary: descriptor.isBinary,
		itemId: descriptor.itemId,
		language: descriptor.language,
		mimeType: descriptor.mimeType,
		packageId: descriptor.packageId,
		reviewGeneration: descriptor.reviewGeneration,
		role: descriptor.role,
		sourceIdentity: descriptor.sourceIdentity,
		wholeByteLength: descriptor.wholeByteLength,
	};
}

async function drainScheduledPreparation(
	scheduledDrains: BridgeCommWorkerPreparationDrain[],
): Promise<void> {
	for (let round = 0; round < 8; round += 1) {
		const drain = scheduledDrains.shift();
		if (drain === undefined) return;
		// oxlint-disable-next-line no-await-in-loop -- Each drain may schedule the next bounded preparation slice.
		await drain();
		// oxlint-disable-next-line no-await-in-loop -- Continuations expose any next preparation slice deterministically.
		await flushBridgeWorkerRuntimeContinuations();
	}
	throw new Error('Expected Review preparation drains to settle within eight rounds.');
}

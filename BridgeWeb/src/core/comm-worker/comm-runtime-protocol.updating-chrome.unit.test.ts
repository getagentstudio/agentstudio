import { describe, expect, test } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import noSourceAttempt from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-comparison-attempt-no-source.json' with { type: 'json' };
import { makeReviewPublicationIdentity } from './bridge-comm-worker-entry.test-support.js';
import {
	encodeBridgeWorkerActiveViewerModeUpdateCommand,
	encodeBridgeWorkerReviewComparisonTargetsQueryCommand,
} from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import type { ReviewMetadataSubscription } from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import {
	createIdleWorktreeAnnotationSubscription,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
	type FileMetadataSubscription,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { publishBridgeCommWorkerUpdatingChrome } from './bridge-comm-worker-updating-chrome.js';
import { createBridgeMainRenderSnapshotStore } from './bridge-main-render-snapshot-store.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import type { BridgeProductReviewComparisonTargetsContentDescriptor } from './bridge-product-content-contracts.js';
import type { BridgeProductMetadataApplicationProtocolIdentity } from './bridge-product-metadata-application-protocol.js';
import { bridgeProductReviewComparisonPresentationSchema } from './bridge-product-review-comparison-presentation-contracts.js';
import type { BridgeProductContentStream } from './bridge-product-transport-contract.js';
import type {
	BridgeProductPanePresentationFrame,
	BridgeProductTransportSession,
} from './bridge-product-transport.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';
import type {
	BridgeWorkerPanelChromePatchPayload,
	BridgeWorkerServerToMainMessage,
	BridgeWorkerServerToMainWireMessage,
} from './bridge-worker-contracts.js';
import {
	makeFileBatchInstallation,
	makeReviewBatchInstallation,
} from './comm-runtime-protocol.file-product.test-support.js';

describe('Bridge comm worker updating panel chrome', () => {
	test('certified no-source reaches panel chrome before a Review epoch or publication exists', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const comparison = bridgeProductReviewComparisonPresentationSchema.parse({
			activeTarget: null,
			attempt: noSourceAttempt,
			displayedSnapshot: { status: 'none' },
			repositoryDefaultTarget: null,
		});
		publishBridgeCommWorkerUpdatingChrome({
			activeFileWorkerDerivationEpoch: null,
			activeReviewSourceIdentity: null,
			activeReviewWorkerDerivationEpoch: null,
			activeReviewPublicationIdentity: null,
			activeViewerMode: null,
			createSequence: (): number => 1,
			previousPublicationIdentity: undefined,
			previousReviewComparison: null,
			presentation: {
				fileRefreshFailure: null,
				nativeActivity: 'foreground',
				presentationRevision: 1,
				refreshingLanes: [],
				reviewComparison: comparison,
				workAdmissionGeneration: 1,
			},
			publish: (): void => {
				throw new Error('No-source must not manufacture a package publication');
			},
			publishCertifiedNoSourceComparison: (certifiedComparison): void => {
				store.applyWorkerPatch({
					slice: 'panelChrome',
					operation: 'upsert',
					payload: { reviewComparison: certifiedComparison },
				});
			},
			surface: 'review',
			telemetryClient: undefined,
		});
		expect(store.getSnapshot().panelChromeSlice.reviewComparison).toEqual(comparison);
	});

	test('publishes Review chrome only when it can carry exact publication lineage', () => {
		const published: BridgeWorkerServerToMainWireMessage[] = [];
		const common = {
			publishCertifiedNoSourceComparison: (): void => {
				throw new Error('Non-noSource state must retain its publication gate');
			},
			activeFileWorkerDerivationEpoch: null,
			activeReviewSourceIdentity: null,
			activeReviewWorkerDerivationEpoch: 7,
			activeViewerMode: 'review' as const,
			createSequence: (): number => 11,
			previousPublicationIdentity: undefined,
			previousReviewComparison: null,
			presentation: {
				fileRefreshFailure: null,
				nativeActivity: 'foreground' as const,
				presentationRevision: 3,
				refreshingLanes: ['review' as const],
				reviewComparison: null,
				workAdmissionGeneration: 1,
			},
			publish: (message: BridgeWorkerServerToMainWireMessage): void => {
				published.push(message);
			},
			surface: 'review' as const,
			telemetryClient: undefined,
		};

		publishBridgeCommWorkerUpdatingChrome({
			...common,
			activeReviewPublicationIdentity: null,
		});
		const identity = makeReviewPublicationIdentity();
		publishBridgeCommWorkerUpdatingChrome({
			...common,
			activeReviewPublicationIdentity: identity,
		});

		expect(published).toEqual([
			expect.objectContaining({
				kind: 'reviewRenderPatch',
				reviewPublicationIdentity: identity,
			}),
		]);
	});

	test('projects typed File refresh failure into retained unavailable chrome', () => {
		// Arrange
		const published: BridgeWorkerServerToMainWireMessage[] = [];

		// Act
		publishBridgeCommWorkerUpdatingChrome({
			publishCertifiedNoSourceComparison: (): void => {
				throw new Error('File state must not use the Review no-source path');
			},
			activeFileWorkerDerivationEpoch: 7,
			activeReviewPublicationIdentity: null,
			activeReviewSourceIdentity: null,
			activeReviewWorkerDerivationEpoch: null,
			activeViewerMode: 'file',
			createSequence: (): number => 11,
			previousPublicationIdentity: undefined,
			previousReviewComparison: null,
			presentation: {
				fileRefreshFailure: { failureKind: 'fileSourceUnavailable', retryable: true },
				nativeActivity: 'foreground',
				presentationRevision: 3,
				refreshingLanes: [],
				reviewComparison: null,
				workAdmissionGeneration: 1,
			},
			publish: (message): void => {
				published.push(message);
			},
			surface: 'file',
			telemetryClient: undefined,
		});

		// Assert
		expect(published).toContainEqual(
			expect.objectContaining({
				kind: 'fileRenderPatch',
				patches: [
					{
						operation: 'upsert',
						payload: {
							fileRefreshFailure: {
								failureKind: 'fileSourceUnavailable',
								retryable: true,
							},
							message: 'Files unavailable',
						},
						slice: 'panelChrome',
					},
				],
			}),
		);
	});

	test('preserves a settled comparison-target query when native foreground is lost', async () => {
		// Arrange — retaining the completed request id makes foreground loss publish a false failure.
		const fileEvents = new BridgeProductBoundedAsyncQueue<never>(16);
		const reviewEvents = new BridgeProductBoundedAsyncQueue<never>(16);
		const presentation = createPanePresentationTestTransport({
			fileEvents,
			reviewEvents,
			supportsComparisonTargetContent: true,
		});
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: presentation.productTransport,
			sendProductControl: async (command): Promise<unknown> =>
				command.method === 'review.comparisonTargets.query'
					? { descriptor: comparisonTargetsDescriptor() }
					: null,
		});
		await flushBridgeWorkerRuntimeContinuations();
		presentation.publish({
			nativeActivity: 'foreground',
			presentationRevision: 1,
			refreshingLanes: [],
		});
		dispatch.message(
			encodeBridgeWorkerReviewComparisonTargetsQueryCommand({
				epoch: 1,
				requestId: 'comparison-targets-settled-before-foreground-loss',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		// Act
		presentation.publish({
			nativeActivity: 'loadedHidden',
			presentationRevision: 2,
			refreshingLanes: [],
		});
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		const queryEvents = postedMessages
			.map(({ message }) => message)
			.filter(
				(message) =>
					message.kind === 'reviewComparisonTargetsQuery' &&
					message.requestId === 'comparison-targets-settled-before-foreground-loss',
			);
		expect(queryEvents).toEqual([expect.objectContaining({ status: 'empty' })]);
	});

	test('settles the current comparison-target query when native foreground is lost', async () => {
		// Arrange
		const fileEvents = new BridgeProductBoundedAsyncQueue<never>(16);
		const reviewEvents = new BridgeProductBoundedAsyncQueue<never>(16);
		const presentation = createPanePresentationTestTransport({ fileEvents, reviewEvents });
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		let resolveQuery!: (result: unknown) => void;
		const queryResult = new Promise<unknown>((resolve): void => {
			resolveQuery = resolve;
		});
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: presentation.productTransport,
			sendProductControl: async (command): Promise<unknown> =>
				command.method === 'review.comparisonTargets.query' ? queryResult : null,
		});
		await flushBridgeWorkerRuntimeContinuations();
		presentation.publish({
			nativeActivity: 'foreground',
			presentationRevision: 1,
			refreshingLanes: [],
		});
		dispatch.message(
			encodeBridgeWorkerReviewComparisonTargetsQueryCommand({
				epoch: 1,
				requestId: 'comparison-targets-before-foreground-loss',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		// Act
		presentation.publish({
			nativeActivity: 'loadedHidden',
			presentationRevision: 2,
			refreshingLanes: [],
		});
		resolveQuery({ descriptor: null });
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		const queryEvents = postedMessages
			.map(({ message }) => message)
			.filter(
				(message) =>
					message.kind === 'reviewComparisonTargetsQuery' &&
					message.requestId === 'comparison-targets-before-foreground-loss',
			);
		expect(queryEvents).toEqual([expect.objectContaining({ status: 'failed' })]);
	});

	test('reopens failed File metadata after the coalesced native File refresh settles', async () => {
		// Arrange — removing refresh-settlement recovery makes this test fail.
		const firstFileEvents = new BridgeProductBoundedAsyncQueue<never>(16);
		const replacementFileEvents = new BridgeProductBoundedAsyncQueue<never>(16);
		const reviewEvents = new BridgeProductBoundedAsyncQueue<never>(16);
		const presentation = createPanePresentationTestTransport({
			fileEvents: firstFileEvents,
			replacementFileEvents,
			reviewEvents,
		});
		const { dispatch } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: presentation.productTransport,
		});
		dispatch.message(activeViewerModeUpdateCommand('file', 1));
		await flushBridgeWorkerRuntimeContinuations();
		firstFileEvents.fail(new Error('construction invalidated'), true);
		await flushBridgeWorkerRuntimeContinuations();

		// Act
		presentation.publish({
			presentationRevision: 1,
			nativeActivity: 'foreground',
			refreshingLanes: ['file'],
		});
		presentation.publish({
			presentationRevision: 2,
			nativeActivity: 'foreground',
			refreshingLanes: [],
		});
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(presentation.fileSubscriptionCount()).toBe(2);
	});

	test('keeps Review refresh chrome classifier-owned while File retains updating state', async () => {
		// Arrange
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const fileEvents = new BridgeProductBoundedAsyncQueue<never>(16);
		const reviewEvents = new BridgeProductBoundedAsyncQueue<never>(16);
		const presentation = createPanePresentationTestTransport({ fileEvents, reviewEvents });
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: presentation.productTransport,
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		dispatch.message(activeViewerModeUpdateCommand('review', 1));
		await flushBridgeWorkerRuntimeContinuations();
		await presentation.installFileBatch();
		await presentation.installReviewBatch();
		await flushBridgeWorkerRuntimeContinuations();
		postedMessages.length = 0;

		// Act
		presentation.publish({
			presentationRevision: 1,
			nativeActivity: 'foreground',
			refreshingLanes: ['file', 'review'],
		});

		// Assert
		expect(panelChromePublications(postedMessages)).toEqual([
			{ kind: 'reviewRenderPatch', operation: 'reset', payload: null, surface: 'review' },
		]);
		expect(telemetrySamples).toEqual(
			expect.arrayContaining([
				expect.objectContaining({
					name: 'performance.bridge.web.pane_presentation',
					stringAttributes: expect.objectContaining({
						'agentstudio.bridge.comparison.attempt.status': 'absent',
						'agentstudio.bridge.phase': 'pane_presentation_applied',
						'agentstudio.bridge.result': 'success',
					}),
					numericAttributes: expect.objectContaining({
						'agentstudio.bridge.presentation.revision': 1,
					}),
				}),
			]),
		);

		// Act
		const publicationCountBeforeReplay = panelChromePublications(postedMessages).length;
		presentation.publish({
			presentationRevision: 1,
			nativeActivity: 'foreground',
			refreshingLanes: ['file', 'review'],
		});

		// Assert
		expect(panelChromePublications(postedMessages)).toHaveLength(publicationCountBeforeReplay);

		// Act
		postedMessages.length = 0;
		dispatch.message(activeViewerModeUpdateCommand('file', 2));
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		const fileModePublications = panelChromePublications(postedMessages);
		expect(fileModePublications).toHaveLength(1);
		expect(fileModePublications).toEqual(
			expect.arrayContaining([
				{
					kind: 'fileRenderPatch',
					operation: 'upsert',
					payload: { fileRefreshFailure: null, isLoading: true, message: 'Updating files…' },
					surface: 'file',
				},
			]),
		);
		expect(panelChromeStateAfterPublications(fileModePublications)).toEqual({
			file: { fileRefreshFailure: null, isLoading: true, message: 'Updating files…' },
			review: null,
		});

		// Act
		postedMessages.length = 0;
		presentation.publish({
			presentationRevision: 2,
			nativeActivity: 'foreground',
			refreshingLanes: [],
		});

		// Assert
		expect(panelChromePublications(postedMessages)).toEqual([
			{
				kind: 'fileRenderPatch',
				operation: 'reset',
				payload: null,
				surface: 'file',
			},
		]);

		// Arrange
		presentation.publish({
			presentationRevision: 3,
			nativeActivity: 'foreground',
			refreshingLanes: ['file'],
		});
		postedMessages.length = 0;

		// Act
		presentation.publish({
			presentationRevision: 4,
			nativeActivity: 'loadedHidden',
			refreshingLanes: ['file', 'review'],
		});

		// Assert
		const hiddenPublications = panelChromePublications(postedMessages);
		expect(hiddenPublications).toEqual([
			{
				kind: 'fileRenderPatch',
				operation: 'reset',
				payload: null,
				surface: 'file',
			},
		]);
		expect(hiddenPublications).not.toContainEqual(expect.objectContaining({ operation: 'upsert' }));

		postedMessages.length = 0;
		const reviewComparison = {
			activeTarget: { basis: 'commonCommit', kind: 'branch', name: 'feature/review' },
			attempt: { reviewGeneration: 6, status: 'pending' },
			displayedSnapshot: {
				packageId: 'package-predecessor',
				reviewGeneration: 5,
				revision: 2,
				status: 'stale',
			},
			repositoryDefaultTarget: null,
		} as const;
		presentation.publish({
			nativeActivity: 'foreground',
			presentationRevision: 5,
			refreshingLanes: [],
			reviewComparison,
		});

		expect(panelChromePublications(postedMessages)).toContainEqual({
			kind: 'reviewRenderPatch',
			operation: 'upsert',
			payload: { reviewComparison },
			surface: 'review',
		});
	});
});

interface PanePresentationPublicationProps {
	readonly presentationRevision: number;
	readonly nativeActivity: BridgeProductPanePresentationFrame['nativeActivity'];
	readonly refreshingLanes: BridgeProductPanePresentationFrame['refreshingLanes'];
	readonly reviewComparison?: BridgeProductPanePresentationFrame['reviewComparison'];
}

interface PanelChromePublication {
	readonly kind: 'fileRenderPatch' | 'reviewRenderPatch';
	readonly operation: 'reset' | 'upsert';
	readonly payload: BridgeWorkerPanelChromePatchPayload | null;
	readonly surface: 'file' | 'review';
}

function createPanePresentationTestTransport(props: {
	readonly fileEvents: BridgeProductBoundedAsyncQueue<never>;
	readonly replacementFileEvents?: BridgeProductBoundedAsyncQueue<never>;
	readonly reviewEvents: BridgeProductBoundedAsyncQueue<never>;
	readonly supportsComparisonTargetContent?: boolean;
}): {
	readonly productTransport: BridgeProductTransportSession;
	readonly fileSubscriptionCount: () => number;
	readonly installFileBatch: () => Promise<void>;
	readonly installReviewBatch: () => Promise<void>;
	readonly publish: (publication: PanePresentationPublicationProps) => void;
} {
	let fileEpoch = 0;
	let fileSubscriptionCount = 0;
	let reviewEpoch = 0;
	let panePresentationSink: ((frame: BridgeProductPanePresentationFrame) => void) | null = null;
	let batchSinks: BridgeProductBatchFrameSinks | null = null;
	const fileSubscriptions: readonly FileMetadataSubscription[] = [
		{
			cancel: async (): Promise<void> => {},
			events: props.fileEvents,
			subscriptionId: 'file-subscription-updating-chrome',
			subscriptionKind: 'file.metadata',
		},
		{
			cancel: async (): Promise<void> => {},
			events: props.replacementFileEvents ?? props.fileEvents,
			subscriptionId: 'file-subscription-updating-chrome-replacement',
			subscriptionKind: 'file.metadata',
		},
	];
	const reviewSubscription: ReviewMetadataSubscription = {
		cancel: async (): Promise<void> => {},
		events: props.reviewEvents,
		subscriptionId: 'review-subscription-updating-chrome',
		subscriptionKind: 'review.metadata',
	};
	const productTransport: BridgeProductTransportSession = {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			if (surface === 'file') fileEpoch += 1;
			if (surface === 'review') reviewEpoch += 1;
			return surface === 'file' ? fileEpoch : reviewEpoch;
		},
		call: async (...arguments_): Promise<never> => {
			const [method] = arguments_;
			if (
				method === 'file.activeViewerMode.update' ||
				method === 'review.activeViewerMode.update'
			) {
				return null as never;
			}
			if (method === 'file.source.current') {
				return { source: currentFileSourceConfiguration, status: 'available' } as never;
			}
			if (method === 'review.publication.applied') return null as never;
			throw new Error(`Unexpected updating-chrome product call ${method}.`);
		},
		openContent: (descriptor): never => {
			if (
				props.supportsComparisonTargetContent === true &&
				descriptor.contentKind === 'review.comparisonTargets'
			) {
				return comparisonTargetsContentStream(descriptor) as never;
			}
			throw new Error(`Unexpected updating-chrome content open ${descriptor.contentKind}.`);
		},
		setPanePresentationFrameSink: (sink): void => {
			panePresentationSink = sink;
		},
		setBatchFrameSinks: (sinks): void => {
			batchSinks = sinks;
		},
		subscribe: ((protocol: BridgeProductMetadataApplicationProtocolIdentity): never => {
			const subscriptionKind = protocol.kind;
			if (subscriptionKind === 'file.annotations' || subscriptionKind === 'review.annotations') {
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The generic fixture closes over the requested annotation subscription kind.
				return createIdleWorktreeAnnotationSubscription(protocol) as never;
			}
			if (subscriptionKind !== 'file.metadata') return reviewSubscription as never;
			const subscription = fileSubscriptions[fileSubscriptionCount];
			if (subscription === undefined) {
				throw new Error('Unexpected third File metadata subscription.');
			}
			fileSubscriptionCount += 1;
			return subscription as never;
		}) as BridgeProductTransportSession['subscribe'],
		workerDerivationEpoch: (surface): number => (surface === 'file' ? fileEpoch : reviewEpoch),
	};
	return {
		fileSubscriptionCount: (): number => fileSubscriptionCount,
		installFileBatch: async (): Promise<void> => {
			if (batchSinks === null) throw new Error('File batch sinks were not installed.');
			await batchSinks.install(
				makeFileBatchInstallation('open', 'file-subscription-updating-chrome'),
			);
		},
		installReviewBatch: async (): Promise<void> => {
			if (batchSinks === null) throw new Error('Review batch sinks were not installed.');
			await batchSinks.install(
				makeReviewBatchInstallation('open', 'review-subscription-updating-chrome'),
			);
		},
		productTransport,
		publish: (publication): void => {
			if (panePresentationSink === null) {
				throw new Error('Expected Bridge pane presentation sink registration.');
			}
			panePresentationSink({
				...publication,
				fileRefreshFailure: null,
				kind: 'pane.presentation',

				operationCorrelationId: null,
				metadataStreamId: 'metadata-stream-updating-chrome',
				paneSessionId: 'pane-session-updating-chrome',
				reviewComparison: publication.reviewComparison ?? null,
				streamSequence: publication.presentationRevision,
				wireVersion: 2,
				workerInstanceId: 'worker-instance-updating-chrome',
			});
		},
	};
}

function comparisonTargetsDescriptor(): BridgeProductReviewComparisonTargetsContentDescriptor {
	return {
		contentKind: 'review.comparisonTargets',
		descriptorId: 'comparison-targets-updating-chrome',
		maximumBytes: 1024 * 1024,
	};
}

function comparisonTargetsContentStream(
	descriptor: BridgeProductReviewComparisonTargetsContentDescriptor,
): BridgeProductContentStream<'review.comparisonTargets'> {
	const bytes = new TextEncoder().encode(
		JSON.stringify({
			branches: [],
			capturedAtUnixMilliseconds: 1_700_000_000_000,
			cutoffUnixMilliseconds: 1_697_408_000_000,
			currentTarget: null,
			defaultTarget: null,
			isTruncated: false,
		}),
	);
	return {
		contentKind: 'review.comparisonTargets',
		contentRequestId: 'comparison-targets-updating-chrome-content',
		frames: emptyComparisonTargetFrames(),
		terminal: Promise.resolve({
			bytes: bytes.buffer,
			contentKind: 'review.comparisonTargets',
			descriptorId: descriptor.descriptorId,
			endOfSource: true,
			kind: 'complete',
			observedByteLength: bytes.byteLength,
			observedSha256: 'a'.repeat(64),
		}),
	};
}

async function* emptyComparisonTargetFrames(): AsyncIterable<never> {}

function activeViewerModeUpdateCommand(mode: 'file' | 'review', sequence: number): unknown {
	return encodeBridgeWorkerActiveViewerModeUpdateCommand({
		epoch: sequence,
		requestId: `request-updating-chrome-${mode}-${sequence}`,
		update: {
			activeSource: null,
			mode,
			nativeSelectionRequestId: null,
			sequence,
			sessionId: 'updating-chrome-session',
		},
	});
}

function panelChromePublications(
	messages: readonly { readonly message: BridgeWorkerServerToMainMessage }[],
): readonly PanelChromePublication[] {
	return messages.flatMap(({ message }): readonly PanelChromePublication[] => {
		if (message.kind !== 'fileRenderPatch' && message.kind !== 'reviewRenderPatch') return [];
		return message.patches.flatMap((patch): readonly PanelChromePublication[] => {
			if (patch.slice !== 'panelChrome' || patch.operation === 'delete') return [];
			return [
				{
					kind: message.kind,
					operation: patch.operation,
					payload: patch.operation === 'upsert' ? patch.payload : null,
					surface: message.surface,
				},
			];
		});
	});
}

function panelChromeStateAfterPublications(
	publications: readonly PanelChromePublication[],
): Readonly<Record<'file' | 'review', PanelChromePublication['payload']>> {
	const state: Record<'file' | 'review', PanelChromePublication['payload']> = {
		file: null,
		review: null,
	};
	for (const publication of publications) {
		state[publication.surface] = publication.operation === 'upsert' ? publication.payload : null;
	}
	return state;
}

const fileSource = {
	repoId: '00000000-0000-4000-8000-000000000001',
	rootRevisionToken: 'root-revision-updating-chrome',
	sourceCursor: 'source-cursor-updating-chrome',
	sourceId: 'file-source-updating-chrome',
	subscriptionGeneration: 1,
	worktreeId: '00000000-0000-4000-8000-000000000002',
} as const;

const currentFileSourceConfiguration = {
	cwdScope: null,
	freshness: 'live',
	includeStatuses: true,
	repoId: fileSource.repoId,
	rootPathToken: 'root-token-updating-chrome',
	worktreeId: fileSource.worktreeId,
} as const;

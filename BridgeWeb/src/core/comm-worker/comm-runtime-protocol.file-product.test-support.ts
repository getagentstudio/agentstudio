import { uuidv7 } from 'uuidv7';
import { expect } from 'vitest';

import fileCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import reviewCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import type { BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import type { ReviewMetadataSubscription } from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import {
	createIdleWorktreeAnnotationSubscription,
	flushBridgeWorkerRuntimeContinuations,
	type FileMetadataSubscription,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductMetadataApplicationProtocolIdentity } from './bridge-product-metadata-application-protocol.js';
import type {
	BridgeProductPanePresentationFrame,
	BridgeProductTransportSession,
} from './bridge-product-transport.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';

export function makeFileBatchInstallation(
	snapshotCause: import('./bridge-product-batch-wire-contracts.js').BridgeProductSnapshotCause,
	subscriptionId: string,
	options: {
		readonly emptyTree?: boolean;
		readonly revision?: number;
		readonly withDescriptor?: boolean;
	} = {},
): BridgeProductViewInstallation {
	const revision = options.revision ?? 4;
	const begin = bridgeProductBatchFrameSchema.parse({
		...sessionCorpus.transportV2.batchFrames[0],
		snapshotCause,
		batchId: uuidv7(),
		publicationId: undefined,
		scope: { kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] },
		subscriptionId,
		subscriptionKind: 'file.metadata',
		targetRevision: revision,
	});
	if (begin.kind !== 'subscription.batchBegin') throw new Error('File batch begin missing.');
	return {
		certified: true,
		staleRecords: [],
		begin,
		domain: 'default',
		records: [
			...(options.emptyTree === true ? [] : fileCorpus.rows).map(({ recordKey, row }) => ({
				key: recordKey,
				revision,
				value:
					options.withDescriptor === false
						? { ...row, descriptorOutcome: null, readDescriptor: null }
						: row,
			})),
			{ key: 'member-status', revision, value: fileCorpus.memberStatuses[0]?.record },
		],
	};
}

export function makeReviewBatchInstallation(
	snapshotCause: import('./bridge-product-batch-wire-contracts.js').BridgeProductSnapshotCause,
	subscriptionId: string,
): BridgeProductViewInstallation {
	const publication = reviewCorpus.records[2];
	const item = reviewCorpus.records[0];
	if (
		publication?.record.recordKind !== 'publication' ||
		publication.record.revision === undefined ||
		item?.record.recordKind !== 'item'
	) {
		throw new Error('Review batch fixture is incomplete.');
	}
	const begin = bridgeProductBatchFrameSchema.parse({
		...sessionCorpus.transportV2.batchFrames[0],
		snapshotCause,
		batchId: uuidv7(),
		publicationId: publication.record.publicationId,
		scope: { kind: 'review', interests: [] },
		subscriptionId,
		subscriptionKind: 'review.metadata',
		targetRevision: publication.record.revision,
	});
	if (begin.kind !== 'subscription.batchBegin') throw new Error('Review batch begin missing.');
	return {
		certified: true,
		staleRecords: [],
		begin,
		domain: 'default',
		records: [
			{ key: item.recordKey, revision: publication.record.revision, value: item.record },
			{
				key: publication.recordKey,
				revision: publication.record.revision,
				value: publication.record,
			},
		],
	};
}

export const fileProductTestSource = {
	repoId: '00000000-0000-4000-8000-000000000001',
	rootRevisionToken: 'root-revision-1',
	sourceCursor: 'source-cursor-1',
	sourceId: 'file-source-1',
	subscriptionGeneration: 3,
	worktreeId: '00000000-0000-4000-8000-000000000002',
} as const;

export const fileViewProductTestBudget = {
	className: 'interactive',
	maxBytes: 2 * 1024 * 1024,
	maxWindowLines: 10_000,
} as const;

export function makeFileProductTestTransport(props: {
	readonly discoveryError?: Error;
	readonly onDiscoverSource: () => void;
	readonly onBatchFrameSinks?: (sinks: BridgeProductBatchFrameSinks) => void;
	readonly onFileScope?: (scope: {
		readonly interests: readonly { readonly lane: string; readonly paths: readonly string[] }[];
		readonly pathScope: readonly string[];
	}) => void;
	readonly onOpenDescriptor: (descriptorId: string) => void;
	readonly onPanePresentationSink?: (
		sink: (frame: BridgeProductPanePresentationFrame) => void,
	) => void;
	readonly onSubscribe?: () => void;
	readonly onReviewWarmup?: () => void;
	readonly subscription: FileMetadataSubscription;
}): BridgeProductTransportSession {
	let fileEpoch = 0;
	let reviewEpoch = 0;
	let nextScopeRevision = 0;
	const reviewEvents = new BridgeProductBoundedAsyncQueue<never>(64);
	const reviewSubscription: ReviewMetadataSubscription = {
		cancel: async (): Promise<void> => {},
		events: reviewEvents,
		subscriptionId: 'review-subscription-for-file-runtime-test',
		subscriptionKind: 'review.metadata',
	};
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			if (surface === 'file') fileEpoch += 1;
			if (surface === 'review') reviewEpoch += 1;
			return surface === 'file' ? fileEpoch : reviewEpoch;
		},
		call: async (...arguments_): Promise<never> => {
			const [method] = arguments_;
			if (method === 'file.activeViewerMode.update') return null as never;
			if (method === 'review.intake.ready') {
				props.onReviewWarmup?.();
				return null as never;
			}
			if (method !== 'file.source.current') throw new Error('Unexpected product call.');
			if (props.discoveryError !== undefined) throw props.discoveryError;
			props.onDiscoverSource();
			// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The generic call fixture returns the exact File discovery branch requested above.
			return {
				source: currentFileSourceConfiguration,
				status: 'available',
			} as never;
		},
		openContent: (descriptor): never => {
			props.onOpenDescriptor(descriptor.descriptorId);
			const isBatchFixtureDescriptor =
				descriptor.descriptorId === 'file-descriptor-1' ||
				descriptor.descriptorId === 'file-descriptor-successor';
			const bytes = new TextEncoder().encode(
				isBatchFixtureDescriptor ? 'abc' : 'file body\n',
			).buffer;
			// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The fixture returns the exact File content stream requested above.
			return {
				contentKind: 'file.content',
				contentRequestId: 'content-request-1',
				frames: emptyFrames(),
				terminal: Promise.resolve({
					bytes,
					contentKind: 'file.content',
					descriptorId: descriptor.descriptorId,
					kind: 'complete',
					observedSha256: isBatchFixtureDescriptor
						? 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
						: '94dda0ed4b1c44a08e3ef62b978ddd97258b6e3016696ea645e176730091e885',
				}),
			} as never;
		},
		setPanePresentationFrameSink: (
			sink: (frame: BridgeProductPanePresentationFrame) => void,
		): void => {
			props.onPanePresentationSink?.(sink);
			sink(makeFilePanePresentationFrame(1, 'foreground'));
		},
		setBatchFrameSinks: (sinks): void => props.onBatchFrameSinks?.(sinks),
		setViewScopeForSubscription: async ({ scope }) => {
			if (scope.kind === 'file') props.onFileScope?.(scope);
			return { kind: 'accepted', scopeRevision: ++nextScopeRevision };
		},
		// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The fixture closes over the supported File/Review subscription variants.
		subscribe: ((protocol: BridgeProductMetadataApplicationProtocolIdentity): never => {
			const subscriptionKind = protocol.kind;
			if (subscriptionKind === 'file.annotations' || subscriptionKind === 'review.annotations') {
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The branch closes over the requested annotation subscription kind.
				return createIdleWorktreeAnnotationSubscription(protocol) as never;
			}
			if (subscriptionKind === 'review.metadata') {
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The branch closes over Review metadata.
				return reviewSubscription as never;
			}
			props.onSubscribe?.();
			// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The remaining admitted branch is File metadata.
			return props.subscription as never;
		}) as BridgeProductTransportSession['subscribe'],
		workerDerivationEpoch: (surface): number => (surface === 'file' ? fileEpoch : reviewEpoch),
	};
}

export function requireFilePanePresentationSink(
	sink: ((frame: BridgeProductPanePresentationFrame) => void) | null,
): (frame: BridgeProductPanePresentationFrame) => void {
	if (sink === null) throw new Error('Expected Bridge File pane presentation sink registration.');
	return sink;
}

export function makeFilePanePresentationFrame(
	presentationRevision: number,
	nativeActivity: BridgeProductPanePresentationFrame['nativeActivity'],
): BridgeProductPanePresentationFrame {
	return {
		fileRefreshFailure: null,
		presentationRevision,
		kind: 'pane.presentation',

		operationCorrelationId: null,
		metadataStreamId: 'file-product-test-metadata-stream',
		nativeActivity,
		paneSessionId: 'file-product-test-pane-session',
		refreshingLanes: [],
		reviewComparison: null,
		streamSequence: presentationRevision,
		wireVersion: 2,
		workerInstanceId: 'file-product-test-worker-instance',
	};
}

export async function drainFilePreparationUntilIdle(
	scheduledDrains: BridgeCommWorkerPreparationDrain[],
): Promise<void> {
	const drainCompletions: Array<ReturnType<BridgeCommWorkerPreparationDrain>> = [];
	for (let drainRound = 0; drainRound < 16; drainRound += 1) {
		const drainsForRound = scheduledDrains.splice(0);
		if (drainsForRound.length > 0) {
			drainCompletions.push(...drainsForRound.map((drain) => drain()));
		}
		// oxlint-disable-next-line no-await-in-loop -- Each bounded round exposes event-scheduled continuation drains.
		await flushBridgeWorkerRuntimeContinuations();
		if (scheduledDrains.length === 0) break;
	}
	expect(scheduledDrains).toEqual([]);
	await Promise.all(drainCompletions);
	await flushBridgeWorkerRuntimeContinuations();
}

const currentFileSourceConfiguration = {
	cwdScope: null,
	freshness: 'live',
	includeStatuses: true,
	repoId: fileProductTestSource.repoId,
	rootPathToken: 'root-token-1',
	worktreeId: fileProductTestSource.worktreeId,
} as const;

async function* emptyFrames(): AsyncIterable<never> {}

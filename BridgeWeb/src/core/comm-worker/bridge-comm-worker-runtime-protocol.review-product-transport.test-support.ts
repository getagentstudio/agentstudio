import { uuidv7 } from 'uuidv7';

import reviewCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { makeReviewPanePresentationFrame } from './bridge-comm-worker-runtime-protocol.review-product-pane-presentation.test-support.js';
import {
	createIdleWorktreeAnnotationSubscription,
	makeImmediateReviewContentStream,
} from './bridge-comm-worker-runtime-protocol.worker-test-support.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import {
	bridgeProductReviewAnnotationMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import type { BridgeProductMetadataApplicationSubscription } from './bridge-product-transport-contract.js';
import type {
	BridgeProductPanePresentationFrame,
	BridgeProductTransportSession,
} from './bridge-product-transport.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';

type ReviewAnnotationMetadataSubscription = BridgeProductMetadataApplicationSubscription<
	typeof bridgeProductReviewAnnotationMetadataApplicationProtocol
>;
export type ReviewMetadataSubscription = BridgeProductMetadataApplicationSubscription<
	typeof bridgeProductReviewMetadataApplicationProtocol
>;
type ReviewViewScopeRequest = Parameters<
	NonNullable<BridgeProductTransportSession['setViewScopeForSubscription']>
>[0];

export function makeIdleReviewMetadataSubscription(
	subscriptionId: string,
): ReviewMetadataSubscription {
	return {
		cancel: async (): Promise<void> => {},
		events: new BridgeProductBoundedAsyncQueue<never>(1),
		subscriptionId,
		subscriptionKind: 'review.metadata',
	};
}

export function createReviewBatchSinkCapture(): {
	readonly onBatchFrameSinks: (sinks: BridgeProductBatchFrameSinks) => void;
	readonly install: (batch: BridgeProductViewInstallation) => Promise<void>;
} {
	let currentSinks: BridgeProductBatchFrameSinks | null = null;
	return {
		onBatchFrameSinks: (sinks): void => {
			currentSinks = sinks;
		},
		install: async (batch): Promise<void> => {
			if (currentSinks === null) throw new Error('Review batch sinks were not installed.');
			await currentSinks.install(batch);
		},
	};
}

export function makeReviewTestBatch(props: {
	readonly snapshotCause: import('./bridge-product-batch-wire-contracts.js').BridgeProductSnapshotCause;
	readonly subscriptionId: string;
	readonly revision?: number;
	readonly generation?: number;
	readonly packageId?: string;
	readonly publicationId?: string;
	readonly sourceIdentity?: string;
	readonly itemId?: string;
	readonly itemCount?: 0 | 1;
	readonly withContent?: boolean;
	readonly desiredStatus?: 'ready' | 'updating' | 'failedRetryable' | 'failedPermanent';
	readonly withoutDisplayed?: boolean;
}): BridgeProductViewInstallation {
	const revision = props.revision ?? 11;
	const generation = props.generation ?? 7;
	const packageId = props.packageId ?? 'package-1';
	const publicationId = props.publicationId ?? '00000000-0000-7000-8000-000000000011';
	const sourceIdentity = props.sourceIdentity ?? 'source-1';
	const itemId = props.itemId ?? 'item-1';
	const itemFixture = bridgeProductReviewBatchRecordSchema.parse(reviewCorpus.records[0]?.record);
	const publicationFixture = bridgeProductReviewBatchRecordSchema.parse(
		reviewCorpus.records[2]?.record,
	);
	if (
		itemFixture.recordKind !== 'item' ||
		publicationFixture.recordKind !== 'publication' ||
		publicationFixture.displayed === null
	)
		throw new Error('Review batch corpus lacks the typed item and displayed publication.');
	const headFixture = itemFixture.contentByRole.head;
	if (headFixture.state !== 'available') throw new Error('Review batch corpus lacks head content.');
	const headSource = {
		...headFixture.source,
		itemId,
		packageId,
		reviewGeneration: generation,
		sourceIdentity,
	};
	const item = bridgeProductReviewBatchRecordSchema.parse({
		...itemFixture,
		itemId,
		parentPath: 'Sources',
		basePath: 'Sources/App.swift',
		headPath: 'Sources/App.swift',
		changeKind: 'modified',
		contentByRole:
			props.withContent === true
				? {
						base: {
							state: 'available',
							source: {
								...headSource,
								descriptorId: 'review-descriptor-item-1-base',
								endpointId: 'base',
								handleId: 'review-handle-item-1-base',
								role: 'base',
							},
						},
						diff: { state: 'absent' },
						file: { state: 'absent' },
						head: {
							state: 'available',
							source: {
								...headSource,
								descriptorId: 'review-descriptor-item-1-head',
								endpointId: 'head',
								handleId: 'review-handle-item-1-head',
							},
						},
					}
				: {
						base: { state: 'absent' },
						diff: { state: 'absent' },
						file: { state: 'absent' },
						head: { state: 'absent' },
					},
		extentByRole:
			props.withContent === true
				? { base: 1, diff: null, file: null, head: 1 }
				: { base: null, diff: null, file: null, head: null },
	});
	const publication = bridgeProductReviewBatchRecordSchema.parse({
		...publicationFixture,
		desired: { reviewComparison: null, status: props.desiredStatus ?? 'ready' },
		displayed:
			props.withoutDisplayed === true
				? null
				: {
						...publicationFixture.displayed,
						generation,
						packageId,
						publicationId,
						query: { ...publicationFixture.displayed.query, queryId: sourceIdentity },
						revision,
						summary: {
							additions: props.itemCount === 0 ? 0 : 1,
							deletions: props.itemCount === 0 ? 0 : 1,
							filesChanged: props.itemCount === 0 ? 0 : 1,
							hiddenFileCount: 0,
							visibleFileCount: props.itemCount === 0 ? 0 : 1,
						},
					},
		publicationId,
		revision,
	});
	const begin = bridgeProductBatchFrameSchema.parse({
		...sessionCorpus.transportV2.batchFrames[0],
		snapshotCause: props.snapshotCause,
		batchId: uuidv7(),
		publicationId,
		scope: { kind: 'review', interests: [] },
		subscriptionId: props.subscriptionId,
		subscriptionKind: 'review.metadata',
		targetRevision: revision,
	});
	if (begin.kind !== 'subscription.batchBegin') throw new Error('Review batch begin missing.');
	return {
		certified: true,
		staleRecords: [],
		begin,
		domain: 'default',
		records: [
			...(props.itemCount === 0 ? [] : [{ key: itemId, revision, value: item }]),
			{ key: 'publication', revision, value: publication },
		],
	};
}

export function makeReviewProductTransport(props: {
	readonly calledMethods?: string[];
	readonly initialReviewEpoch?: number;
	readonly onPanePresentationSink?: (
		sink: (frame: BridgeProductPanePresentationFrame) => void,
	) => void;
	readonly onCalledMethod?: ((method: string, request: unknown) => void) | undefined;
	readonly onCall?: ((method: string, request: unknown) => unknown) | undefined;
	readonly openedContentKinds?: string[];
	readonly reviewSubscription: ReviewMetadataSubscription;
	readonly onBatchFrameSinks?: (sinks: BridgeProductBatchFrameSinks) => void;
	readonly reviewAnnotationSubscription?: ReviewAnnotationMetadataSubscription;
	readonly subscribedKinds: string[];
	readonly viewScopes?: ReviewViewScopeRequest[];
	readonly onViewScope?: (request: ReviewViewScopeRequest) => void;
}): BridgeProductTransportSession {
	let reviewEpoch = props.initialReviewEpoch ?? 0;
	const scopeRevisionBySubscriptionId = new Map<string, number>();
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			if (surface === 'review') reviewEpoch += 1;
			return surface === 'review' ? reviewEpoch : 0;
		},
		call: async (...arguments_): Promise<never> => {
			const [method, request] = arguments_;
			props.calledMethods?.push(method);
			props.onCalledMethod?.(method, request);
			if (props.onCall !== undefined) {
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The test callback supplies the result for its exact product-call fixture.
				return (await props.onCall(method, request)) as never;
			}
			return { reason: 'notConfigured', status: 'unavailable' } as never;
		},
		openContent: (descriptor) => {
			if (descriptor.contentKind !== 'review.content') {
				throw new Error(`Unexpected product content kind ${descriptor.contentKind}.`);
			}
			props.openedContentKinds?.push(descriptor.contentKind);
			return makeImmediateReviewContentStream(descriptor, 'hello world\n') as never;
		},
		setBatchFrameSinks: (sinks): void => props.onBatchFrameSinks?.(sinks),
		setViewScopeForSubscription: async (
			request,
		): Promise<{ kind: 'accepted'; scopeRevision: number }> => {
			props.viewScopes?.push(request);
			props.onViewScope?.(request);
			const scopeRevision = (scopeRevisionBySubscriptionId.get(request.subscriptionId) ?? 0) + 1;
			scopeRevisionBySubscriptionId.set(request.subscriptionId, scopeRevision);
			return { kind: 'accepted', scopeRevision };
		},
		setPanePresentationFrameSink: (sink): void => {
			props.onPanePresentationSink?.(sink);
			sink(makeReviewPanePresentationFrame(1, 'foreground'));
		},
		subscribe: (...arguments_): never => {
			const [{ kind: subscriptionKind }] = arguments_;
			props.subscribedKinds.push(subscriptionKind);
			if (subscriptionKind === 'review.annotations' && props.reviewAnnotationSubscription) {
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The optional Review annotation fixture matches the narrowed subscription branch.
				return props.reviewAnnotationSubscription as never;
			}
			if (subscriptionKind === 'file.annotations' || subscriptionKind === 'review.annotations') {
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- Generic transport fixtures close over the requested annotation subscription kind.
				return createIdleWorktreeAnnotationSubscription(arguments_[0]) as never;
			}
			if (subscriptionKind !== 'review.metadata') {
				throw new Error(`Unexpected product subscription ${subscriptionKind}.`);
			}
			return props.reviewSubscription as never;
		},
		workerDerivationEpoch: (surface): number => (surface === 'review' ? reviewEpoch : 0),
	};
}

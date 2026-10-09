import { uuidv7 } from 'uuidv7';
import { expect } from 'vitest';

import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import type { BridgeCommWorkerPort } from './bridge-comm-worker-entry.js';
import { encodeBridgeWorkerActiveViewerModeUpdateCommand } from './bridge-comm-worker-protocol.js';
import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';
import type { BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import {
	completedReviewContentTerminal,
	createIdleWorktreeAnnotationSubscription,
	emptyReviewContentFrames,
	makeImmediateReviewContentStream,
} from './bridge-comm-worker-runtime-protocol.worker-test-support.js';
import {
	BridgeProductBoundedAsyncQueue,
	createBridgeProductDeferred,
} from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import {
	bridgeProductFileMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import type {
	BridgeProductContentStream,
	BridgeProductMetadataApplicationSubscription,
} from './bridge-product-transport-contract.js';
import type {
	BridgeProductPanePresentationFrame,
	BridgeProductTransportSession,
} from './bridge-product-transport.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';
import type {
	BridgeWorkerFileViewContentMetadata,
	BridgeWorkerReviewContentMetadata,
	BridgeWorkerReviewContentRequestDescriptor,
	BridgeWorkerReviewRenderSemantics,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import type { BridgeWorkerReviewContentOpen } from './bridge-worker-review-content-fetch.js';

export {
	createIdleWorktreeAnnotationSubscription,
	makeImmediateReviewContentStream,
} from './bridge-comm-worker-runtime-protocol.worker-test-support.js';

export interface PostedBridgeWorkerRuntimeMessage {
	readonly message: BridgeWorkerServerToMainMessage;
	readonly transferList: readonly Transferable[] | undefined;
}

export const reviewContentFixtureByDescriptorId = new Map<
	string,
	{ readonly itemId: string; readonly text: string }
>();
const pendingReviewBatchInstalls = new Set<Promise<void>>();

export type FileMetadataSubscription = BridgeProductMetadataApplicationSubscription<
	typeof bridgeProductFileMetadataApplicationProtocol
>;

export function createRecordingBridgeCommWorkerPort(
	props: {
		readonly beforePostMessage?: (message: BridgeWorkerServerToMainMessage) => void;
	} = {},
): {
	readonly dispatch: {
		readonly message: (data: unknown) => void;
		readonly port: BridgeCommWorkerPort;
	};
	readonly postedMessages: PostedBridgeWorkerRuntimeMessage[];
	readonly waitForMessage: (
		predicate: (message: BridgeWorkerServerToMainMessage) => boolean,
	) => Promise<BridgeWorkerServerToMainMessage>;
} {
	const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
	const messageWaiters: Array<{
		readonly deferred: ReturnType<
			typeof createBridgeProductDeferred<BridgeWorkerServerToMainMessage>
		>;
		readonly predicate: (message: BridgeWorkerServerToMainMessage) => boolean;
	}> = [];
	let listener: ((event: MessageEvent<unknown>) => void) | null = null;
	return {
		dispatch: {
			message: (data: unknown): void => {
				if (listener === null) {
					throw new Error('Bridge comm worker port listener was not registered.');
				}
				listener(new MessageEvent('message', { data }));
			},
			port: {
				postMessage: (
					message: BridgeWorkerServerToMainMessage,
					transferList?: Transferable[],
				): void => {
					props.beforePostMessage?.(message);
					postedMessages.push({ message, transferList });
					for (let waiterIndex = messageWaiters.length - 1; waiterIndex >= 0; waiterIndex -= 1) {
						const waiter = messageWaiters[waiterIndex];
						if (waiter === undefined) continue;
						if (!waiter.predicate(message)) continue;
						messageWaiters.splice(waiterIndex, 1);
						waiter.deferred.resolve(message);
					}
				},
				addEventListener: (
					type: 'message',
					nextListener: (event: MessageEvent<unknown>) => void,
				): void => {
					expect(type).toBe('message');
					listener = nextListener;
				},
				start: (): void => {},
			},
		},
		postedMessages,
		waitForMessage: (predicate): Promise<BridgeWorkerServerToMainMessage> => {
			const existing = postedMessages.find(({ message }) => predicate(message));
			if (existing !== undefined) return Promise.resolve(existing.message);
			const deferred = createBridgeProductDeferred<BridgeWorkerServerToMainMessage>();
			messageWaiters.push({ deferred, predicate });
			return deferred.promise;
		},
	};
}

export function createBridgeWorkerSequenceCounter(firstSequence: number): () => number {
	let nextSequence = firstSequence;
	return (): number => {
		const sequence = nextSequence;
		nextSequence += 1;
		return sequence;
	};
}

export function activateBridgeCommWorkerFileViewerMode(
	dispatch: { readonly message: (data: unknown) => void },
	requestLabel: string,
): void {
	dispatch.message(
		encodeBridgeWorkerActiveViewerModeUpdateCommand({
			epoch: 1,
			requestId: `request-file-mode-${requestLabel}`,
			update: {
				activeSource: null,
				mode: 'file',
				nativeSelectionRequestId: null,
				sequence: 1,
				sessionId: `file-mode-${requestLabel}-session`,
			},
		}),
	);
}

export async function activateBridgeCommWorkerFileViewerModeAndFlush(
	dispatch: { readonly message: (data: unknown) => void },
	requestLabel: string,
): Promise<void> {
	activateBridgeCommWorkerFileViewerMode(dispatch, requestLabel);
	await flushBridgeWorkerRuntimeContinuations();
}

export function activateBridgeCommWorkerReviewViewerMode(
	dispatch: { readonly message: (data: unknown) => void },
	requestLabel: string,
): void {
	dispatch.message(
		encodeBridgeWorkerActiveViewerModeUpdateCommand({
			epoch: 1,
			requestId: `request-review-mode-${requestLabel}`,
			update: {
				activeSource: null,
				mode: 'review',
				nativeSelectionRequestId: null,
				sequence: 1,
				sessionId: `review-mode-${requestLabel}-session`,
			},
		}),
	);
}

export function assertBridgeCommWorkerPreparationDrain(
	drain: BridgeCommWorkerPreparationDrain | undefined,
): BridgeCommWorkerPreparationDrain {
	if (drain === undefined) {
		throw new Error('Expected scheduled bridge comm worker preparation drain.');
	}
	return drain;
}

export async function flushBridgeWorkerRuntimeContinuations(): Promise<void> {
	await Promise.all(pendingReviewBatchInstalls);
	await Array.from({ length: 50 }).reduce<Promise<void>>(
		(previousFlush) => previousFlush.then(() => Promise.resolve()),
		Promise.resolve(),
	);
}

export interface BridgeCommWorkerReviewProductTestSource {
	readonly close: () => void;
	readonly productTransport: BridgeProductTransportSession;
	readonly viewScopes: ReviewViewScopeRequest[];
	readonly publishReplacementSource: (
		source: BridgeCommWorkerReviewProductTestSourceInput,
		revision?: number,
	) => void;
	readonly publishSource: (
		source: BridgeCommWorkerReviewProductTestSourceInput,
		revision?: number,
	) => void;
}

export type BridgeCommWorkerReviewProductTestSourceInput = Omit<
	BridgeCommWorkerReviewRuntimeSource,
	'reviewPublicationIdentity'
>;

type ReviewMetadataSubscription = BridgeProductMetadataApplicationSubscription<
	typeof bridgeProductReviewMetadataApplicationProtocol
>;
type ReviewViewScopeRequest = Parameters<
	NonNullable<BridgeProductTransportSession['setViewScopeForSubscription']>
>[0];
type ReviewViewScopeSettlement = Awaited<
	ReturnType<NonNullable<BridgeProductTransportSession['setViewScopeForSubscription']>>
>;

export function createBridgeCommWorkerReviewProductTestSource(
	props: {
		readonly setViewScopeForSubscription?: (
			request: ReviewViewScopeRequest,
		) => Promise<ReviewViewScopeSettlement>;
	} = {},
): BridgeCommWorkerReviewProductTestSource {
	let currentWorkerDerivationEpoch = 0;
	let currentRevision = 0;
	let batchSinks: BridgeProductBatchFrameSinks | null = null;
	let closed = false;
	const lifecycleEvents = new BridgeProductBoundedAsyncQueue<never>(1);
	const viewScopes: ReviewViewScopeRequest[] = [];
	const scopeRevisionBySubscriptionId = new Map<string, number>();
	const subscription: ReviewMetadataSubscription = {
		cancel: async (): Promise<void> => {
			closed = true;
			lifecycleEvents.close(true);
		},
		events: lifecycleEvents,
		subscriptionId: 'review-product-test-subscription',
		subscriptionKind: 'review.metadata',
	};
	const productTransport: BridgeProductTransportSession = {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			if (surface === 'review') currentWorkerDerivationEpoch += 1;
			return surface === 'review' ? currentWorkerDerivationEpoch : 0;
		},
		call: async (...arguments_): Promise<never> => {
			const [method] = arguments_;
			if (method === 'file.source.current') {
				return { reason: 'review-product-test-source', status: 'unavailable' } as never;
			}
			if (method === 'review.publication.applied') return null as never;
			return undefined as never;
		},
		openContent: (): never => {
			throw new Error(
				'Review product test source requires the test to provide its content-open seam.',
			);
		},
		setBatchFrameSinks: (sinks): void => {
			batchSinks = sinks;
		},
		setViewScopeForSubscription: async (request): Promise<ReviewViewScopeSettlement> => {
			viewScopes.push(request);
			if (props.setViewScopeForSubscription !== undefined) {
				return await props.setViewScopeForSubscription(request);
			}
			const scopeRevision = (scopeRevisionBySubscriptionId.get(request.subscriptionId) ?? 0) + 1;
			scopeRevisionBySubscriptionId.set(request.subscriptionId, scopeRevision);
			return { kind: 'accepted', scopeRevision };
		},
		setPanePresentationFrameSink: (
			sink: (frame: BridgeProductPanePresentationFrame) => void,
		): void => {
			sink({
				fileRefreshFailure: null,
				presentationRevision: 1,
				kind: 'pane.presentation',
				operationCorrelationId: null,
				metadataStreamId: 'review-product-test-metadata-stream',
				nativeActivity: 'foreground',
				paneSessionId: 'review-product-test-pane-session',
				refreshingLanes: [],
				reviewComparison: null,
				streamSequence: 1,
				wireVersion: 2,
				workerInstanceId: 'review-product-test-worker-instance',
			});
		},
		subscribe: (...arguments_): never => {
			const [{ kind: subscriptionKind }] = arguments_;
			if (subscriptionKind === 'file.annotations' || subscriptionKind === 'review.annotations') {
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- Generic transport fixtures close over the requested annotation subscription kind.
				return createIdleWorktreeAnnotationSubscription(arguments_[0]) as never;
			}
			if (subscriptionKind !== 'review.metadata') {
				throw new Error(`Unexpected product subscription ${subscriptionKind}.`);
			}
			return subscription as never;
		},
		workerDerivationEpoch: (surface): number =>
			surface === 'review' ? currentWorkerDerivationEpoch : 0,
	};
	return {
		close: (): void => {
			closed = true;
			lifecycleEvents.close(true);
		},
		productTransport,
		viewScopes,
		publishReplacementSource: publishSource,
		publishSource,
	};

	function publishSource(
		source: BridgeCommWorkerReviewProductTestSourceInput,
		revision?: number,
	): void {
		if (closed) throw new Error('Review product test source is closed.');
		if (batchSinks === null) throw new Error('Review batch sinks were not installed.');
		const nextRevision = Math.max(currentRevision + 1, revision ?? currentRevision + 1);
		const batch = reviewProductBatchFromRuntimeSource(
			'open',
			source,
			nextRevision,
			subscription.subscriptionId,
		);
		const installedSinks = batchSinks;
		const installation = Promise.resolve().then(async (): Promise<void> => {
			if (closed) return;
			await installedSinks.install(batch);
		});
		pendingReviewBatchInstalls.add(installation);
		void installation.then(
			(): void => {
				pendingReviewBatchInstalls.delete(installation);
			},
			(): void => {
				pendingReviewBatchInstalls.delete(installation);
			},
		);
		currentRevision = nextRevision;
	}
}

function reviewProductBatchFromRuntimeSource(
	snapshotCause: import('./bridge-product-batch-wire-contracts.js').BridgeProductSnapshotCause,
	source: BridgeCommWorkerReviewProductTestSourceInput,
	revision: number,
	subscriptionId: string,
): BridgeProductViewInstallation {
	const generation = 1;
	const packageId = 'review-product-test-package';
	const publicationId = reviewProductTestPublicationId(revision);
	const sourceIdentity = 'review-product-test-source';
	const semanticsByItemId = new Map(
		source.renderSemantics.map((semantics) => [semantics.itemId, semantics]),
	);
	const rowsById = new Map(source.rows.map((row) => [row.id, row]));
	const items = orderedReviewRuntimeContentItems(source).map((contentItem) => {
		const semantics = semanticsByItemId.get(contentItem.itemId);
		const displayPath = semantics?.displayPath ?? contentItem.path;
		const contentByRole = Object.fromEntries(
			(['base', 'diff', 'file', 'head'] as const).map((role) => {
				const descriptor = source.contentRequestDescriptors.find(
					(candidate) => candidate.itemId === contentItem.itemId && candidate.role === role,
				);
				return [
					role,
					descriptor === undefined
						? { state: 'absent' }
						: {
								state: 'available',
								source: {
									contentDigest: descriptor.contentDigest,
									contentKind: 'review.content',
									descriptorId: descriptor.descriptorId,
									encoding: descriptor.encoding,
									endpointId: descriptor.endpointId,
									handleId: descriptor.handleId,
									isBinary: descriptor.isBinary,
									itemId: descriptor.itemId,
									language: descriptor.language,
									mimeType: descriptor.mimeType,
									packageId,
									reviewGeneration: generation,
									role: descriptor.role,
									sourceIdentity,
									wholeByteLength: descriptor.wholeByteLength,
								},
							},
				];
			}),
		);
		const contentHashesByRole = Object.fromEntries(
			source.contentRequestDescriptors
				.filter((descriptor) => descriptor.itemId === contentItem.itemId)
				.map((descriptor) => [descriptor.role, descriptor.contentDigest.value]),
		);
		const pathSegments = displayPath.split('/');
		const parentPath = pathSegments.length > 1 ? pathSegments.slice(0, -1).join('/') : null;
		return bridgeProductReviewBatchRecordSchema.parse({
			additions: 0,
			basePath: semantics?.basePath ?? displayPath,
			changeKind: semantics?.changeKind ?? 'modified',
			contentByRole,
			contentHashesByRole,
			deletions: 0,
			extentByRole: {
				base: source.contentRequestDescriptors.some(
					(descriptor) => descriptor.itemId === contentItem.itemId && descriptor.role === 'base',
				)
					? (contentItem.contentLineCountsByRole.base ?? null)
					: null,
				diff: source.contentRequestDescriptors.some(
					(descriptor) => descriptor.itemId === contentItem.itemId && descriptor.role === 'diff',
				)
					? (contentItem.contentLineCountsByRole.diff ?? null)
					: null,
				file: source.contentRequestDescriptors.some(
					(descriptor) => descriptor.itemId === contentItem.itemId && descriptor.role === 'file',
				)
					? (contentItem.contentLineCountsByRole.file ?? null)
					: null,
				head: source.contentRequestDescriptors.some(
					(descriptor) => descriptor.itemId === contentItem.itemId && descriptor.role === 'head',
				)
					? (contentItem.contentLineCountsByRole.head ?? null)
					: null,
			},
			extension: reviewProductTestPathExtension(displayPath),
			fileClass: 'source',
			headPath: semantics?.headPath ?? displayPath,
			isHiddenByDefault: false,
			itemId: contentItem.itemId,
			language: contentItem.language,
			mimeTypes: ['text/plain'],
			parentPath,
			provenance: { agentSessionIds: [], operationIds: [], promptIds: [] },
			recordKind: 'item',
			reviewPriority: 'normal',
			reviewState: 'unreviewed',
			sortKey: rowsById.get(contentItem.itemId)?.index ?? 0,
		});
	});
	const publication = bridgeProductReviewBatchRecordSchema.parse({
		desired: { reviewComparison: null, status: 'ready' },
		displayed: {
			baseEndpoint: {
				createdAtUnixMilliseconds: 1,
				endpointId: 'review-product-test-base',
				kind: 'gitRef',
				label: 'base',
				providerIdentity: 'review-product-test-provider',
				repoId: 'review-product-test-repo',
				worktreeId: 'review-product-test-worktree',
			},
			comparisonOrigin: null,
			generation,
			headEndpoint: {
				createdAtUnixMilliseconds: 1,
				endpointId: 'review-product-test-head',
				kind: 'workingTree',
				label: 'head',
				providerIdentity: 'review-product-test-provider',
				repoId: 'review-product-test-repo',
				worktreeId: 'review-product-test-worktree',
			},
			packageId,
			publicationId,
			query: {
				baseEndpointId: 'review-product-test-base',
				comparisonSemantics: 'threeDot',
				fileTarget: null,
				grouping: { kind: 'folder' },
				headEndpointId: 'review-product-test-head',
				pathScope: [],
				provenanceFilter: {
					agentSessionIds: [],
					operationIds: [],
					paneIds: [],
					promptIds: [],
					sourceKinds: [],
				},
				queryId: sourceIdentity,
				queryKind: 'compare',
				repoId: 'review-product-test-repo',
				viewFilter: {
					changeKinds: [],
					excludedExtensions: [],
					excludedFileClasses: [],
					excludedPathGlobs: [],
					includedExtensions: [],
					includedFileClasses: [],
					includedPathGlobs: [],
					reviewStates: [],
					showBinaryFiles: true,
					showHiddenFiles: false,
					showLargeFiles: true,
				},
				worktreeId: 'review-product-test-worktree',
			},
			reviewComparison: null,
			reviewedSubjectLabel: null,
			revision,
			summary: {
				additions: 0,
				deletions: 0,
				filesChanged: items.length,
				hiddenFileCount: 0,
				visibleFileCount: items.length,
			},
		},
		publicationId,
		classifiedRefreshImpact: null,
		recordKind: 'publication',
		revision,
	});
	if (
		publication.recordKind !== 'publication' ||
		items.some((item) => item.recordKind !== 'item')
	) {
		throw new Error('Expected typed Review publication and item records.');
	}
	const begin = bridgeProductBatchFrameSchema.parse({
		...sessionCorpus.transportV2.batchFrames[0],
		snapshotCause,
		batchId: uuidv7(),
		publicationId,
		scope: { kind: 'review', interests: [] },
		subscriptionId,
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
			...items.map((item) => {
				if (item.recordKind !== 'item') throw new Error('Expected Review item record.');
				return { key: item.itemId, revision, value: item };
			}),
			{ key: 'publication', revision, value: publication },
		],
	};
}

function reviewProductTestPublicationId(revision: number): string {
	const revisionSuffix = revision.toString(16).padStart(12, '0').slice(-12);
	return `00000000-0000-7000-8000-${revisionSuffix}`;
}

function orderedReviewRuntimeRows(
	source: BridgeCommWorkerReviewProductTestSourceInput,
): BridgeCommWorkerReviewRuntimeSource['rows'] {
	return source.rows.toSorted((left, right) => left.index - right.index);
}

function orderedReviewRuntimeContentItems(
	source: BridgeCommWorkerReviewProductTestSourceInput,
): BridgeCommWorkerReviewRuntimeSource['contentItems'] {
	const contentItemsById = new Map(source.contentItems.map((item) => [item.itemId, item]));
	const orderedItemIds = orderedReviewRuntimeRows(source).flatMap((row) =>
		contentItemsById.has(row.id) ? [row.id] : [],
	);
	for (const contentItem of source.contentItems) {
		if (!orderedItemIds.includes(contentItem.itemId)) orderedItemIds.push(contentItem.itemId);
	}
	return orderedItemIds.flatMap((itemId) => {
		const contentItem = contentItemsById.get(itemId);
		return contentItem === undefined ? [] : [contentItem];
	});
}

function reviewProductTestPathExtension(path: string): string | null {
	const fileName = path.split('/').at(-1) ?? path;
	const extensionSeparatorIndex = fileName.lastIndexOf('.');
	return extensionSeparatorIndex <= 0 || extensionSeparatorIndex === fileName.length - 1
		? null
		: fileName.slice(extensionSeparatorIndex + 1);
}

export interface DeferredReviewContentStream {
	readonly stream: BridgeProductContentStream<'review.content'>;
	readonly resolve: (text: string) => void;
}

export function createDeferredReviewContentStream(
	descriptor: BridgeWorkerReviewContentRequestDescriptor,
): DeferredReviewContentStream {
	let resolveTerminal: ((text: string) => void) | null = null;
	const terminal: BridgeProductContentStream<'review.content'>['terminal'] = new Promise(
		(resolve) => {
			resolveTerminal = (text: string): void => {
				resolve(completedReviewContentTerminal(descriptor, text));
			};
		},
	);
	return {
		stream: {
			contentKind: 'review.content',
			contentRequestId: `content-request-${descriptor.descriptorId}`,
			frames: emptyReviewContentFrames(),
			terminal,
		},
		resolve: (text: string): void => {
			if (resolveTerminal === null) {
				throw new Error('Deferred Review content resolver was not initialized.');
			}
			resolveTerminal(text);
		},
	};
}

export const openReviewContentFromDescriptorMap: BridgeWorkerReviewContentOpen = (descriptor) => {
	const fixture = reviewContentFixtureByDescriptorId.get(descriptor.descriptorId);
	if (fixture === undefined) {
		throw new Error(`Unexpected Review content descriptor ${descriptor.descriptorId}.`);
	}
	return makeImmediateReviewContentStream(descriptor, fixture.text);
};

export function makeWorkerReviewContentMetadata(
	props: { readonly itemId?: string } = {},
): BridgeWorkerReviewContentMetadata {
	const itemId = props.itemId ?? 'item-1';
	return {
		itemId,
		path: `Sources/App/${itemId}.swift`,
		language: 'swift',
		cacheKey: `${itemId}:base|${itemId}:head`,
		sizeBytes: 1024,
		availableContentRoles: ['base', 'head'],
		contentLineCountsByRole: { base: 100, head: 80 },
	};
}

export function makeWorkerFileViewContentMetadata(): BridgeWorkerFileViewContentMetadata {
	return {
		metadataKind: 'fileView',
		itemId: 'file-1',
		path: 'Sources/App/file-1.swift',
		language: 'swift',
		cacheKey: 'file-view:metadata-cache:file-1',
		sizeBytes: 128,
		descriptorId: 'descriptor-file-1',
		contentHash: 'sha256:file-1',
		encoding: 'utf-8',
		endsMidLine: false,
		endsWithNewline: true,
		virtualizedExtentKind: 'exactLineCount',
		payloadByteCount: 128,
		payloadLineCount: 1,
		totalLineCount: 1,
		truncationKind: 'none',
		isBinary: false,
		canFetchContent: true,
	};
}

export function makeRenderSemantics(
	props: { readonly itemId?: string } = {},
): BridgeWorkerReviewRenderSemantics {
	const itemId = props.itemId ?? 'item-1';
	return {
		itemId,
		itemKind: 'diff',
		changeKind: 'modified',
		displayPath: `Sources/App/${itemId}.swift`,
		basePath: `Sources/App/${itemId}.swift`,
		headPath: `Sources/App/${itemId}.swift`,
		language: 'swift',
		contentLineCountsByRole: { base: 100, head: 80 },
	};
}

export function makeContentRequestDescriptor(props: {
	readonly generation?: number;
	readonly itemId?: string;
	readonly role: BridgeWorkerReviewContentRequestDescriptor['role'];
	readonly text: string;
}): BridgeWorkerReviewContentRequestDescriptor {
	const generation = props.generation ?? 4;
	const itemId = props.itemId ?? 'item-1';
	const textByteLength = new TextEncoder().encode(props.text).byteLength;
	const maximumBytes = Math.max(textByteLength, 1);
	const descriptor: BridgeWorkerReviewContentRequestDescriptor = {
		contentDigest: {
			algorithm: 'fixture-preview',
			authority: 'provisional',
			value: `sha256:${itemId}:${props.role}:generation-${generation}`,
		},
		contentKind: 'review.content',
		declaredByteLength: textByteLength,
		descriptorId: `descriptor-${itemId}-${props.role}-${generation}`,
		encoding: 'utf-8',
		endpointId: `endpoint-${itemId}`,
		expectedSha256: null,
		handleId: `handle-${itemId}-${props.role}`,
		isBinary: false,
		itemId,
		language: 'swift',
		maximumBytes,
		mimeType: 'text/plain',
		packageId: `package-${itemId}-${generation}`,
		reviewGeneration: generation,
		role: props.role,
		sourceIdentity: `source-${itemId}-${generation}`,
		wholeByteLength: textByteLength,
		window: { kind: 'byteRange', maximumBytes, startByte: 0 },
	};
	reviewContentFixtureByDescriptorId.set(descriptor.descriptorId, { itemId, text: props.text });
	return descriptor;
}

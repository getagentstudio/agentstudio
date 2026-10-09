import { createHash } from 'node:crypto';

import { uuidv7 as generateUuidv7 } from 'uuidv7';
import { vi } from 'vitest';

import type { BridgeTelemetrySample } from '../../../foundation/telemetry/bridge-telemetry-event.js';
import sessionCorpus from '../../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import {
	BridgeCommWorkerAnnotationProjectionQueryController,
	type BridgeCommWorkerAnnotationProjectionPublication,
	type BridgeCommWorkerAnnotationProjectionTransport,
} from '../bridge-comm-worker-annotation-projection-query-controller.js';
import { BridgeProductBoundedAsyncQueue } from '../bridge-product-async-queue.js';
import { bridgeProductBatchFrameSchema } from '../bridge-product-batch-wire-contracts.js';
import { installBridgeProductCommentBatch } from '../bridge-product-comment-batch-installer.js';
import {
	bridgeProductCommentCatalogRecordKey,
	bridgeProductCommentCatalogRecordSchema,
} from '../bridge-product-comment-catalog-record-contracts.js';
import {
	bridgeProductFileAnnotationMetadataApplicationProtocol,
	bridgeProductReviewAnnotationMetadataApplicationProtocol,
} from '../bridge-product-metadata-application-registry.js';
import type {
	BridgeProductContentStream,
	BridgeProductMetadataApplicationSubscription,
} from '../bridge-product-transport-contract.js';
import type { BridgeProductViewInstallation } from '../bridge-product-view-batch-receiver.js';
import type { BridgeProductWorktreeAnnotationCatalogEntry } from '../bridge-product-worktree-annotation-contracts.js';
import type {
	BridgeProductAnnotationProjectionContentDescriptor,
	BridgeProductAnnotationProjectionQueryRequest,
} from '../bridge-product-worktree-annotation-projection-query-contracts.js';
import { bridgeProductAnnotationProjectionContentDescriptorSchema } from '../bridge-product-worktree-annotation-projection-query-contracts.js';

export const worktreeId = 'worktree-annotations-1';
export const sessionId = uuidv7(1);
const threadId = uuidv7(2);

export interface MutableProjectionPage {
	descriptor: BridgeProductAnnotationProjectionContentDescriptor;
	readonly bytes: Uint8Array<ArrayBuffer>;
}

export interface TestNotificationQueue {
	readonly close: () => void;
	readonly installCatalog: (revision: number, semanticRevision?: number) => void;
	readonly setCatalogReceiver: (
		receiver: (catalog: ReturnType<typeof installBridgeProductCommentBatch>) => void,
	) => void;
	readonly subscription: AnnotationMetadataSubscription;
}

type AnnotationMetadataProtocol =
	| typeof bridgeProductFileAnnotationMetadataApplicationProtocol
	| typeof bridgeProductReviewAnnotationMetadataApplicationProtocol;
type AnnotationMetadataSubscription =
	BridgeProductMetadataApplicationSubscription<AnnotationMetadataProtocol>;

export interface AnnotationProjectionTestHarness {
	readonly catalogAuthorityRetirements: boolean[];
	readonly controller: BridgeCommWorkerAnnotationProjectionQueryController;
	readonly failures: unknown[];
	readonly notifications: TestNotificationQueue;
	readonly publications: Array<{
		readonly contentSessionIds: readonly string[];
		readonly reviewPublicationIdentity?:
			| Extract<
					BridgeCommWorkerAnnotationProjectionPublication['state'],
					{ readonly kind: 'ready' }
			  >['reviewPublicationIdentity']
			| undefined;
		readonly snapshot: Extract<
			BridgeCommWorkerAnnotationProjectionPublication['state'],
			{ readonly kind: 'ready' }
		>['snapshot'];
		readonly surface: BridgeCommWorkerAnnotationProjectionPublication['surface'];
	}>;
	readonly querySourceGenerations: number[];
	readonly querySessionIds: string[][];
	readonly scopeUpdates: Array<{
		readonly sessionIds: readonly string[];
		readonly subscriptionId: string;
		readonly worktreeId: string;
	}>;
	readonly sourceAuthorityStalePublications: Array<{
		readonly currentSourceGeneration: number;
		readonly requestedSourceGeneration: number;
		readonly surface: 'file' | 'review';
	}>;
	readonly statuses: Array<BridgeCommWorkerAnnotationProjectionPublication['state']['kind']>;
	readonly subscriptionCount: () => number;
	readonly telemetrySamples: BridgeTelemetrySample[];
}

export async function createHarness(props: {
	readonly notificationQueues?: readonly TestNotificationQueue[];
	readonly pages: readonly MutableProjectionPage[];
	readonly queryOverride?: (
		request: BridgeProductAnnotationProjectionQueryRequest,
		signal: AbortSignal,
	) => Promise<unknown>;
	readonly terminalKind?: 'complete' | 'error';
	readonly surface?: 'file' | 'review';
	readonly scopeUpdateOverride?: (
		scope: Parameters<BridgeCommWorkerAnnotationProjectionTransport['setScope']>[0],
	) => Promise<void>;
}): Promise<AnnotationProjectionTestHarness> {
	const surface = props.surface ?? 'file';
	const notifications = createNotificationQueue(surface);
	const notificationQueues = props.notificationQueues ?? [notifications];
	let observedSubscriptionCount = 0;
	const publications: AnnotationProjectionTestHarness['publications'] = [];
	const failures: unknown[] = [];
	const catalogAuthorityRetirements: boolean[] = [];
	const statuses: AnnotationProjectionTestHarness['statuses'] = [];
	const querySourceGenerations: number[] = [];
	const querySessionIds: string[][] = [];
	const scopeUpdates: AnnotationProjectionTestHarness['scopeUpdates'] = [];
	const sourceAuthorityStalePublications: AnnotationProjectionTestHarness['sourceAuthorityStalePublications'] =
		[];
	const telemetrySamples: BridgeTelemetrySample[] = [];
	const pageByCursor = new Map<string | null, MutableProjectionPage>();
	for (const page of props.pages) {
		const cursor =
			page.descriptor.page.pageOrdinal === 0 ? null : `cursor-${page.descriptor.page.pageOrdinal}`;
		pageByCursor.set(cursor, page);
	}
	const transport: BridgeCommWorkerAnnotationProjectionTransport = {
		callProjection: async (_surface, request, signal): Promise<unknown> => {
			querySourceGenerations.push(request.sourceGeneration);
			querySessionIds.push([...request.sessionIds]);
			const result =
				props.queryOverride !== undefined
					? await props.queryOverride(request, signal)
					: { descriptor: pageByCursor.get(request.cursor)?.descriptor, kind: 'content' };
			if (result === null || typeof result !== 'object' || !('descriptor' in result)) return result;
			const parsedDescriptor = bridgeProductAnnotationProjectionContentDescriptorSchema.safeParse(
				result.descriptor,
			);
			if (!parsedDescriptor.success) return result;
			return {
				...result,
				descriptor: {
					...parsedDescriptor.data,
					page: {
						...parsedDescriptor.data.page,
						operationCorrelationId: request.operationCorrelationId,
					},
				},
			};
		},
		openContent: (descriptor): BridgeProductContentStream<'annotation.projection'> => {
			const page = props.pages.find(
				(candidate) => candidate.descriptor.descriptorId === descriptor.descriptorId,
			);
			if (page === undefined) throw new Error('Unknown annotation projection descriptor.');
			return makeContentStream(page, props.terminalKind ?? 'complete');
		},
		subscribe: () => {
			const subscription = notificationQueues[observedSubscriptionCount]?.subscription;
			observedSubscriptionCount += 1;
			if (subscription === undefined) throw new Error('Unexpected annotation subscription reopen.');
			return subscription;
		},
		setScope: async (scope): Promise<void> => {
			scopeUpdates.push({
				sessionIds: [...scope.sessionIds],
				subscriptionId: scope.subscriptionId,
				worktreeId: scope.worktreeId,
			});
			await props.scopeUpdateOverride?.(scope);
		},
	};
	const controller = new BridgeCommWorkerAnnotationProjectionQueryController({
		onConvergence: ({ state, surface: publicationSurface }): void => {
			statuses.push(state.kind);
			if (state.kind === 'ready') {
				publications.push({
					contentSessionIds: state.contentSessionIds,
					...('reviewPublicationIdentity' in state
						? { reviewPublicationIdentity: state.reviewPublicationIdentity }
						: {}),
					snapshot: state.snapshot,
					surface: publicationSurface,
				});
			} else if (state.kind === 'unavailable') {
				failures.push(state.error);
				catalogAuthorityRetirements.push(state.catalogAuthorityRetired);
			}
		},
		onSourceAuthorityStale: (publication): void => {
			sourceAuthorityStalePublications.push(publication);
		},
		surface,
		telemetryClient: {
			record: (sample): void => {
				telemetrySamples.push(sample);
			},
		},
		transport,
	});
	for (const catalogSubscription of notificationQueues) {
		catalogSubscription.setCatalogReceiver((catalog): void => {
			controller.acceptInstalledCatalog(catalog);
		});
	}
	return {
		catalogAuthorityRetirements,
		controller,
		failures,
		notifications,
		publications,
		querySourceGenerations,
		querySessionIds,
		scopeUpdates,
		sourceAuthorityStalePublications,
		statuses,
		subscriptionCount: (): number => observedSubscriptionCount,
		telemetrySamples,
	};
}

export function createNotificationQueue(
	surface: 'file' | 'review',
	authority?: { readonly subscriptionId: string; readonly worktreeId: string },
): TestNotificationQueue {
	const events = new BridgeProductBoundedAsyncQueue<never>(1);
	let catalogReceiver:
		| ((catalog: ReturnType<typeof installBridgeProductCommentBatch>) => void)
		| null = null;
	const base = {
		cancel: vi.fn(async (): Promise<void> => {
			events.close(true);
		}),
		events,
	};
	const subscription: AnnotationMetadataSubscription =
		surface === 'file'
			? {
					...base,
					subscriptionId: authority?.subscriptionId ?? 'file-annotation-notifications',
					subscriptionKind: 'file.annotations',
				}
			: {
					...base,
					subscriptionId: authority?.subscriptionId ?? 'review-annotation-notifications',
					subscriptionKind: 'review.annotations',
				};
	return {
		close: (): void => {
			events.close(true);
		},
		installCatalog: (revision, semanticRevision = 1): void => {
			if (catalogReceiver === null) throw new Error('Comment catalog receiver was not installed.');
			const installation = makeCommentCatalogInstallation({
				snapshotCause: 'open',
				entries: [{ kind: 'session', semanticRevision, sessionId }],
				revision,
				subscriptionId: subscription.subscriptionId,
				subscriptionKind: subscription.subscriptionKind,
				worktreeId: authority?.worktreeId ?? worktreeId,
			});
			catalogReceiver(
				installBridgeProductCommentBatch(installation, {
					subscriptionId: subscription.subscriptionId,
					workerDerivationEpoch: 1,
					worktreeId: authority?.worktreeId ?? worktreeId,
				}),
			);
		},
		setCatalogReceiver: (receiver): void => {
			catalogReceiver = receiver;
		},
		subscription,
	};
}

export async function makeProjectionPages(
	messageCount: number,
	sourceGeneration: number,
	maximumPageBytes = 2 * 1024 * 1024,
	surface: 'file' | 'review' = 'file',
): Promise<MutableProjectionPage[]> {
	const records: Uint8Array<ArrayBuffer>[] = [];
	const header = {
		header: {
			expectedMessageCount: messageCount,
			expectedSessionCount: 1,
			expectedThreadCount: 1,
			projectionRevision: sourceGeneration,
			recoveryStatus: 'available',
			sessions: [
				{
					completedAtUnixMilliseconds: null,
					createdAtUnixMilliseconds: 1,
					eligibleMessageCount: messageCount,
					eligibleWithoutInlinePlacementCount: 0,
					lifecycle: 'living',
					semanticRevision: sourceGeneration,
					sessionId,
					sourceRelationship: 'applicable',
					updatedAtUnixMilliseconds: 2,
				},
			],
			sourceGeneration,
			worktreeId,
		},
		kind: 'header',
	};
	records.push(encodeRecord(header));
	for (let ordinal = 0; ordinal < messageCount; ordinal += 1) {
		records.push(
			encodeRecord({
				kind: 'message',
				message: {
					context: {
						diffSide: 'additions',
						endLine: 12,
						path: 'Sources/App.swift',
						placement: 'exact',
						resolution: 'open',
						scope: 'located',
						sourceIdentity: 'source-1',
						sourceRole: 'file',
						startLine: 10,
						threadId,
					},
					message: {
						attentionState: 'not_applicable',
						authorKind: 'human',
						createdAtUnixMilliseconds: ordinal + 3,
						draft: null,
						handled: false,
						messageId: uuidv7(ordinal + 100),
						messageRevision: 1,
						ordinal,
						savedBody: messageCount > 100 ? 'x'.repeat(16_000) : `message-${ordinal}`,
						savedRevision: 1,
						sessionId,
						sessionRevision: sourceGeneration,
						status: 'locked',
						threadId,
						threadRevision: 1,
					},
				},
			}),
		);
	}
	const pageRecords: Uint8Array<ArrayBuffer>[][] = [[]];
	let currentPageBytes = 0;
	for (const record of records) {
		if (currentPageBytes > 0 && currentPageBytes + record.byteLength > maximumPageBytes) {
			pageRecords.push([]);
			currentPageBytes = 0;
		}
		pageRecords.at(-1)?.push(record);
		currentPageBytes += record.byteLength;
	}
	const pages = pageRecords.map((page) => concatenate(page));
	const aggregateSha256 = createHash('sha256').update(concatenate(pages)).digest('hex');
	return pages.map((bytes, pageOrdinal) => ({
		bytes,
		descriptor: {
			contentKind: 'annotation.projection',
			descriptorId: `projection-${sourceGeneration}-${pageOrdinal}`,
			maximumBytes: bytes.byteLength,
			page: {
				aggregateSha256,
				expectedMessageCount: messageCount,
				expectedPageCount: pages.length,
				expectedSessionCount: 1,
				expectedThreadCount: 1,
				isLastPage: pageOrdinal === pages.length - 1,
				nextCursor: pageOrdinal === pages.length - 1 ? null : `cursor-${pageOrdinal + 1}`,
				operationCorrelationId: 'a'.repeat(64),
				pageOrdinal,
				projectionRevision: sourceGeneration,
				snapshotId: uuidv7(sourceGeneration + 10_000),
				sourceGeneration,
			},
			surface,
		},
	}));
}

function makeContentStream(
	page: MutableProjectionPage,
	terminalKind: 'complete' | 'error',
): BridgeProductContentStream<'annotation.projection'> {
	return {
		contentKind: 'annotation.projection',
		contentRequestId: `request-${page.descriptor.descriptorId}`,
		frames: { async *[Symbol.asyncIterator]() {} },
		terminal:
			terminalKind === 'complete'
				? Promise.resolve({
						bytes: page.bytes.buffer,
						contentKind: 'annotation.projection',
						descriptorId: page.descriptor.descriptorId,
						endOfSource: true,
						kind: 'complete',
						observedByteLength: page.bytes.byteLength,
						observedSha256: createHash('sha256').update(page.bytes).digest('hex'),
					})
				: Promise.resolve({
						code: 'internal',
						contentKind: 'annotation.projection',
						descriptorId: page.descriptor.descriptorId,
						kind: 'error',
						retryable: true,
						safeMessage: 'projection unavailable',
					}),
	};
}

function encodeRecord(record: unknown): Uint8Array<ArrayBuffer> {
	return new TextEncoder().encode(`${JSON.stringify(record)}\n`);
}

function concatenate(chunks: readonly Uint8Array<ArrayBuffer>[]): Uint8Array<ArrayBuffer> {
	const result = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0));
	let offset = 0;
	for (const chunk of chunks) {
		result.set(chunk, offset);
		offset += chunk.byteLength;
	}
	return result;
}

export function installSessionCatalog(
	comments: TestNotificationQueue,
	revision: number,
	semanticRevision = 1,
): void {
	comments.installCatalog(revision, semanticRevision);
}

export function makeCommentCatalogInstallation(props: {
	readonly snapshotCause: import('../bridge-product-batch-wire-contracts.js').BridgeProductSnapshotCause;
	readonly entries: readonly BridgeProductWorktreeAnnotationCatalogEntry[];
	readonly revision: number;
	readonly subscriptionId: string;
	readonly subscriptionKind: 'file.annotations' | 'review.annotations';
	readonly worktreeId: string;
}): BridgeProductViewInstallation {
	const begin = bridgeProductBatchFrameSchema.parse({
		...sessionCorpus.transportV2.batchFrames[0],
		snapshotCause: props.snapshotCause,
		batchId: generateUuidv7(),
		publicationId: undefined,
		scope: { kind: 'comment', sessionIds: [], worktreeId: props.worktreeId },
		subscriptionId: props.subscriptionId,
		subscriptionKind: props.subscriptionKind,
		targetRevision: props.revision,
	});
	if (begin.kind !== 'subscription.batchBegin') throw new Error('Comment batch begin missing.');
	return {
		certified: true,
		staleRecords: [],
		begin,
		domain: 'default',
		records: props.entries.map((entry) => {
			const record = bridgeProductCommentCatalogRecordSchema.parse({
				entry,
				revision: props.revision,
			});
			return {
				key: bridgeProductCommentCatalogRecordKey(record),
				revision: record.revision,
				value: record,
			};
		}),
	};
}

export function uuidv7(value: number): string {
	return `00000000-0000-7000-8000-${value.toString().padStart(12, '0')}`;
}

export function deferred<TResult>(): {
	readonly promise: Promise<TResult>;
	readonly resolve: (value: TResult) => void;
} {
	let resolvePromise!: (value: TResult) => void;
	const promise = new Promise<TResult>((resolve): void => {
		resolvePromise = resolve;
	});
	return { promise, resolve: resolvePromise };
}

export async function flushMicrotasks(): Promise<void> {
	await Promise.resolve();
	await Promise.resolve();
}

export async function flushTaskQueue(): Promise<void> {
	await new Promise<void>((resolve): void => {
		const channel = new MessageChannel();
		channel.port1.addEventListener(
			'message',
			(): void => {
				channel.port1.close();
				channel.port2.close();
				resolve();
			},
			{ once: true },
		);
		channel.port1.start();
		channel.port2.postMessage(null);
	});
}

export async function flushTaskQueueUntil(predicate: () => boolean): Promise<void> {
	for (let turn = 0; turn < 10; turn += 1) {
		if (predicate()) return;
		// eslint-disable-next-line no-await-in-loop -- Each turn waits for the exact queued task boundary.
		await flushTaskQueue();
	}
	throw new Error('Expected queued annotation projection work to reach its boundary.');
}

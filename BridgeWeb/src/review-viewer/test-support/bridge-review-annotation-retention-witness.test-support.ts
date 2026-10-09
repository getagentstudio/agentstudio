import type { BridgeProductWorktreeAnnotationOperation } from '../../core/comm-worker/bridge-product-call-contracts.js';
import type { BridgeProductWorktreeAnnotationCatalogEntry } from '../../core/comm-worker/bridge-product-worktree-annotation-contracts.js';
import type { BridgeWorkerServerToMainMessage } from '../../core/comm-worker/bridge-worker-contracts.js';
import type { BridgeWorkerRpcCommandInput } from '../../core/comm-worker/bridge-worker-rpc-client.js';
import { WorktreeAnnotationBrowserCommandReceiptFixture } from '../../worktree-annotations/worktree-annotation-browser-command-receipt-fixture.js';
import {
	annotationHeadThreadId,
	annotationSessionId,
	annotationSessionSummary,
} from '../../worktree-annotations/worktree-annotation-browser-test-support.js';
import type {
	WorktreeAnnotationCommandOutcome,
	WorktreeAnnotationMessageEntry,
	WorktreeAnnotationThreadContext,
} from '../../worktree-annotations/worktree-annotation-surface-client.js';
import type { BridgeReviewRecoveryWitnessHarness } from './bridge-viewer-browser.recovery-witness.test-support.js';

type AnnotationCommandInput = Extract<
	BridgeWorkerRpcCommandInput,
	{ readonly command: 'annotationCommand' }
>;
interface AnnotationCommandRequest {
	readonly command: AnnotationCommandInput;
	readonly requestId: string;
}
type AnnotationMessageReceipt = Extract<
	NonNullable<WorktreeAnnotationCommandOutcome['receipt']>,
	{ readonly kind: 'message' }
>;
export interface BridgeReviewAnnotationRetentionWitness {
	readonly pendingCommandCount: (
		operationKind: BridgeProductWorktreeAnnotationOperation['kind'],
	) => number;
	readonly publishCleanupCatalog: () => void;
	readonly publishExactProjectionWithLargeCatalog: (cloneCount: number) => void;
	readonly settleNextCommitted: (
		operationKind: BridgeProductWorktreeAnnotationOperation['kind'],
	) => AnnotationMessageReceipt;
	readonly settleNextControlCommitted: (operationKind: 'session.discover') => void;
}

interface ProjectedThread {
	readonly context: WorktreeAnnotationThreadContext;
	readonly messages: readonly WorktreeAnnotationMessageEntry[];
}

export function createBridgeReviewAnnotationRetentionWitness(
	harness: BridgeReviewRecoveryWitnessHarness,
): BridgeReviewAnnotationRetentionWitness {
	const workerEventSeam = harness.workerEventSeam;
	const receiptFixture = new WorktreeAnnotationBrowserCommandReceiptFixture(annotationHeadThreadId);
	const settledRequestIds = new Set<string>();
	const projectedThreadsById = new Map<string, ProjectedThread>();
	let catalogRevision = 0;
	let sessionRevision = 0;

	const publishCatalog = (cloneCount: number): void => {
		catalogRevision += 1;
		const rootThread = projectedThreadsById.get(annotationHeadThreadId);
		if (rootThread === undefined) {
			throw new Error('Review annotation retention witness requires a committed root thread.');
		}
		const entries = [
			{
				kind: 'session' as const,
				semanticRevision: sessionRevision,
				sessionId: annotationSessionId,
			},
			{
				createdOrdinal: 0,
				kind: 'thread' as const,
				scope: rootThread.context.scope,
				sessionId: annotationSessionId,
				threadId: rootThread.context.threadId,
			},
			...rootThread.messages.map((message) => ({
				kind: 'message' as const,
				messageId: message.messageId,
				ordinal: message.ordinal,
				threadId: rootThread.context.threadId,
			})),
			...largeCompletedCatalogEntries(cloneCount),
		];
		const transferId = `review-annotation-retention-catalog-${catalogRevision}`;
		const common = {
			authority: {
				subscriptionId: 'review-annotation-retention-subscription',
				workerDerivationEpoch: 1,
				worktreeId: 'worktree-1',
			},
			direction: 'serverWorkerToMain' as const,
			kind: 'annotationCatalogStaging' as const,
			operationCorrelationId: 'a'.repeat(64),
			surface: 'review' as const,
			transferDescriptors: [],
			wireVersion: 1 as const,
		};
		workerEventSeam.publish({
			...common,
			transfer: {
				catalogRevision,
				expectedEntryCount: entries.length,
				kind: 'catalog.begin',
				transferId,
			},
		});
		for (let windowStart = 0; windowStart < entries.length; windowStart += 256) {
			workerEventSeam.publish({
				...common,
				transfer: {
					catalogRevision,
					entries: entries.slice(windowStart, windowStart + 256),
					kind: 'catalog.window',
					transferId,
					windowOrdinal: windowStart / 256,
				},
			});
		}
		workerEventSeam.publish({
			...common,
			transfer: {
				catalogRevision,
				entryCount: entries.length,
				kind: 'catalog.commit',
				transferId,
				windowCount: Math.ceil(entries.length / 256),
			},
		});
	};

	return {
		pendingCommandCount: (operationKind): number =>
			workerEventSeam
				.sentRequests()
				.filter(
					(request): boolean =>
						request.command.command === 'annotationCommand' &&
						request.command.operation.kind === operationKind &&
						!settledRequestIds.has(request.requestId),
				).length,
		publishCleanupCatalog: (): void => publishCatalog(0),
		publishExactProjectionWithLargeCatalog: (cloneCount): void => {
			publishCatalog(cloneCount);
			const publicationIdentity = workerEventSeam.activeReviewPublicationIdentity();
			const threads = [...projectedThreadsById.values()];
			workerEventSeam.publish({
				direction: 'serverWorkerToMain',
				kind: 'annotationProjectionConvergence',
				operationCorrelationId: 'a'.repeat(64),
				state: {
					contentSessionIds: [annotationSessionId],
					kind: 'ready',
					stageAttempt: 0,
					reviewPublicationIdentity: {
						packageId: publicationIdentity.packageId,
						publicationId: publicationIdentity.publicationId,
						reviewGeneration: publicationIdentity.reviewGeneration,
						revision: publicationIdentity.revision,
						sourceIdentity: publicationIdentity.sourceIdentity,
					},
					snapshot: {
						expectedMessageCount: threads.reduce(
							(messageCount, thread): number => messageCount + thread.messages.length,
							0,
						),
						expectedSessionCount: 1,
						expectedThreadCount: threads.length,
						projectionRevision: sessionRevision,
						recoveryStatus: 'available',
						sessions: [
							annotationSessionSummary({
								revision: sessionRevision,
								sessionId: annotationSessionId,
							}),
						],
						sourceGeneration: sessionRevision,
						threads,
						worktreeId: 'worktree-1',
					},
				},
				surface: 'review',
				transferDescriptors: [],
				wireVersion: 1,
			});
		},
		settleNextCommitted: (operationKind): AnnotationMessageReceipt => {
			const pendingRequest = nextAnnotationCommandRequest({
				operationKind,
				sentRequests: workerEventSeam.sentRequests(),
				settledRequestIds,
			});
			settledRequestIds.add(pendingRequest.requestId);
			sessionRevision += 1;
			const receipt = receiptFixture.receiptForCommittedOperation({
				committedSessionId: annotationSessionId,
				committedSessionRevision: sessionRevision,
				operation: pendingRequest.command.operation,
				projectedThreadsById,
			});
			if (receipt?.kind !== 'message') {
				throw new Error(`Expected a message receipt for ${operationKind}.`);
			}
			recordProjectedMessageReceipt(projectedThreadsById, receipt);
			workerEventSeam.publish(
				annotationCommandAcceptedMessage({
					receipt,
					requestId: pendingRequest.requestId,
				}),
			);
			return receipt;
		},
		settleNextControlCommitted: (operationKind): void => {
			const pendingRequest = nextAnnotationCommandRequest({
				operationKind,
				sentRequests: workerEventSeam.sentRequests(),
				settledRequestIds,
			});
			settledRequestIds.add(pendingRequest.requestId);
			sessionRevision += 1;
			const receipt = receiptFixture.receiptForCommittedOperation({
				committedSessionId: annotationSessionId,
				committedSessionRevision: sessionRevision,
				operation: pendingRequest.command.operation,
				projectedThreadsById,
			});
			if (receipt !== undefined) {
				throw new Error(`Expected no message receipt for ${operationKind}.`);
			}
			workerEventSeam.publish(
				annotationCommandAcceptedMessage({
					requestId: pendingRequest.requestId,
				}),
			);
		},
	};
}

function nextAnnotationCommandRequest(props: {
	readonly operationKind: BridgeProductWorktreeAnnotationOperation['kind'];
	readonly sentRequests: readonly {
		readonly command: BridgeWorkerRpcCommandInput;
		readonly requestId: string;
	}[];
	readonly settledRequestIds: ReadonlySet<string>;
}): AnnotationCommandRequest {
	const request = props.sentRequests.find(
		(candidate): candidate is AnnotationCommandRequest =>
			candidate.command.command === 'annotationCommand' &&
			candidate.command.operation.kind === props.operationKind &&
			!props.settledRequestIds.has(candidate.requestId),
	);
	if (request === undefined) {
		throw new Error(`No pending ${props.operationKind} annotation command exists.`);
	}
	return request;
}

function annotationCommandAcceptedMessage(props: {
	readonly receipt?: AnnotationMessageReceipt;
	readonly requestId: string;
}): BridgeWorkerServerToMainMessage {
	return {
		direction: 'serverWorkerToMain',
		kind: 'annotationCommandAccepted',
		outcome: {
			...(props.receipt === undefined ? {} : { receipt: props.receipt }),
			requestId: `product-${props.requestId}`,
			sessionId: annotationSessionId,
			status: { kind: 'committed' },
			surface: 'review',
		},
		productRequestId: `product-${props.requestId}`,
		requestId: props.requestId,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

function recordProjectedMessageReceipt(
	threadsById: Map<string, ProjectedThread>,
	receipt: AnnotationMessageReceipt,
): void {
	const current = threadsById.get(receipt.context.threadId);
	const messages = [...(current?.messages ?? [])].filter(
		(message): boolean => message.messageId !== receipt.message.messageId,
	);
	messages.push(receipt.message);
	threadsById.set(receipt.context.threadId, {
		context: { ...receipt.context, placement: 'exact' },
		messages: messages.toSorted((left, right): number => left.ordinal - right.ordinal),
	});
}

function largeCompletedCatalogEntries(
	cloneCount: number,
): readonly BridgeProductWorktreeAnnotationCatalogEntry[] {
	if (cloneCount === 0) return [];
	const sessionId = annotationFixtureId(8_000);
	const threadId = annotationFixtureId(8_001);
	return [
		{ kind: 'session', semanticRevision: 1, sessionId },
		{ createdOrdinal: 0, kind: 'thread', scope: 'located', sessionId, threadId },
		...Array.from({ length: cloneCount }, (_, messageIndex) => ({
			kind: 'message' as const,
			messageId: annotationFixtureId(9_000 + messageIndex),
			ordinal: messageIndex,
			threadId,
		})),
	];
}

function annotationFixtureId(identity: number): string {
	return `00000000-0000-7000-8000-${String(identity).padStart(12, '0')}`;
}

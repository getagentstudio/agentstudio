import type { z } from 'zod';

import {
	type BridgeCommWorkerAnnotationCatalog,
	type BridgeCommWorkerAnnotationCatalogApplicatorResult,
} from '../core/comm-worker/bridge-comm-worker-annotation-catalog-applicator.js';
import type { BridgeWorkerAnnotationProjectionSnapshot } from '../core/comm-worker/bridge-comm-worker-annotation-projection-decoder.js';
import {
	bridgeProductWorktreeAnnotationCommandOutcomeSchema,
	bridgeProductWorktreeAnnotationOutputHistorySummarySchema,
} from '../core/comm-worker/bridge-product-worktree-annotation-contracts.js';
import type { BridgeWorkerAnnotationCatalogStagingEvent } from '../core/comm-worker/bridge-worker-annotation-contracts.js';
import { WorktreeAnnotationCatalogStaging } from './worktree-annotation-catalog-staging.js';

export type WorktreeAnnotationCommandOutcome = z.infer<
	typeof bridgeProductWorktreeAnnotationCommandOutcomeSchema
>;
type WorktreeAnnotationCommandReceipt = NonNullable<WorktreeAnnotationCommandOutcome['receipt']>;
type WorktreeAnnotationMessageReceipt = Extract<
	WorktreeAnnotationCommandReceipt,
	{ readonly kind: 'message' }
>;
type WorktreeAnnotationMessageRemovedReceipt = Extract<
	WorktreeAnnotationCommandReceipt,
	{ readonly kind: 'message_removed' }
>;
export type WorktreeAnnotationSessionSummary =
	BridgeWorkerAnnotationProjectionSnapshot['sessions'][number];
export type WorktreeAnnotationMessageEntry =
	BridgeWorkerAnnotationProjectionSnapshot['threads'][number]['messages'][number];
export type WorktreeAnnotationThreadContext =
	BridgeWorkerAnnotationProjectionSnapshot['threads'][number]['context'];

export type WorktreeAnnotationOutputHistorySummary = z.infer<
	typeof bridgeProductWorktreeAnnotationOutputHistorySummarySchema
>;

export interface WorktreeAnnotationThreadProjection {
	readonly context: WorktreeAnnotationThreadContext;
	readonly messages: readonly WorktreeAnnotationMessageEntry[];
}

export type WorktreeAnnotationCommandConfirmedThreadContext =
	WorktreeAnnotationMessageReceipt['context'] & {
		readonly placement: 'command_confirmed';
	};

export interface WorktreeAnnotationCommandConfirmedThreadProjection {
	readonly context: WorktreeAnnotationCommandConfirmedThreadContext;
	readonly messages: readonly WorktreeAnnotationMessageEntry[];
}

export type WorktreeAnnotationInlineThreadProjection =
	| WorktreeAnnotationThreadProjection
	| WorktreeAnnotationCommandConfirmedThreadProjection;

export interface WorktreeAnnotationReviewApplication {
	readonly affectedItemIds: readonly string[] | null;
	readonly applicationId: number;
	readonly changedThreadOwnerContexts: readonly WorktreeAnnotationThreadContext[];
}

export interface WorktreeAnnotationProjectionSnapshot {
	readonly commandConfirmedThreads: readonly WorktreeAnnotationCommandConfirmedThreadProjection[];
	readonly commandOutcomes: readonly WorktreeAnnotationCommandOutcome[];
	readonly outputHistory: readonly WorktreeAnnotationOutputHistorySummary[];
	readonly operationCorrelationId: string | null;
	readonly presentationRevision: number;
	readonly readStatus:
		| { readonly kind: 'unknown' }
		| { readonly kind: 'ready' }
		| { readonly kind: 'refreshing' }
		| { readonly kind: 'unavailable'; readonly retryable: boolean };
	readonly recoveryStatus: 'available' | 'recovered_degraded' | 'unavailable';
	readonly reviewAnnotationApplication: WorktreeAnnotationReviewApplication | null;
	readonly revision: number | null;
	readonly sessions: readonly WorktreeAnnotationSessionSummary[];
	readonly sourceGeneration: number;
	readonly threads: readonly WorktreeAnnotationThreadProjection[];
	readonly unreconciledCommandReceiptSessionIds: readonly string[];
	readonly worktreeId: string | null;
}

export type WorktreeAnnotationCatalogProjection =
	| { readonly kind: 'unknown' }
	| {
			readonly catalog: BridgeCommWorkerAnnotationCatalog;
			readonly kind: 'current' | 'stale';
	  };

export const emptyWorktreeAnnotationProjectionSnapshot: WorktreeAnnotationProjectionSnapshot = {
	commandConfirmedThreads: [],
	commandOutcomes: [],
	outputHistory: [],
	operationCorrelationId: null,
	presentationRevision: 0,
	readStatus: { kind: 'unknown' },
	recoveryStatus: 'available',
	reviewAnnotationApplication: null,
	revision: null,
	sessions: [],
	sourceGeneration: 0,
	threads: [],
	unreconciledCommandReceiptSessionIds: [],
	worktreeId: null,
};

export class WorktreeAnnotationProjectionStore {
	#catalogProjection: WorktreeAnnotationCatalogProjection = { kind: 'unknown' };
	readonly #catalogStaging = new WorktreeAnnotationCatalogStaging();
	readonly #completeContentRevisionBySessionId = new Map<string, number>();
	readonly #commandConfirmedMessagesById = new Map<string, WorktreeAnnotationMessageReceipt>();
	readonly #commandConfirmedRemovalsByMessageId = new Map<
		string,
		WorktreeAnnotationMessageRemovedReceipt
	>();
	readonly #removedMessageIds = new Set<string>();
	readonly #listeners = new Set<() => void>();
	#pendingReviewAnnotationApplication: WorktreeAnnotationReviewApplication | null = null;
	#snapshot = emptyWorktreeAnnotationProjectionSnapshot;
	#sourceGeneration = -1;

	getSnapshot = (): WorktreeAnnotationProjectionSnapshot => this.#snapshot;

	getServerSnapshot = (): WorktreeAnnotationProjectionSnapshot => this.#snapshot;

	getCatalogSnapshot = (): WorktreeAnnotationCatalogProjection => this.#catalogProjection;

	subscribe = (listener: () => void): (() => void) => {
		this.#listeners.add(listener);
		return (): void => {
			this.#listeners.delete(listener);
		};
	};

	apply(props: {
		readonly contentSessionIds: readonly string[] | undefined;
		readonly expectedContentSessionIds: readonly string[];
		readonly operationCorrelationId: string;
		readonly reviewAnnotationApplication: {
			readonly affectedItemIds: readonly string[] | null;
			readonly applicationId: number;
		} | null;
		readonly snapshot: BridgeWorkerAnnotationProjectionSnapshot;
	}): boolean {
		const snapshot = props.snapshot;
		const catalogProjection = this.#catalogProjection;
		if (catalogProjection.kind !== 'current') return false;
		if (snapshot.worktreeId !== catalogProjection.catalog.authority.worktreeId) return false;
		if (
			snapshot.sessions.some(
				(session) => !catalogProjection.catalog.sessionsById.has(session.sessionId),
			)
		) {
			return false;
		}
		if (
			props.contentSessionIds?.some(
				(sessionId) => !catalogProjection.catalog.sessionsById.has(sessionId),
			)
		) {
			return false;
		}
		if (
			props.contentSessionIds !== undefined &&
			!annotationProjectionContentMatchesCatalog(
				catalogProjection.catalog,
				snapshot.threads,
				props.contentSessionIds,
			)
		) {
			return false;
		}
		const currentRevision = this.#snapshot.revision ?? -1;
		if (snapshot.projectionRevision < currentRevision) return false;
		if (
			snapshot.projectionRevision === currentRevision &&
			snapshot.sourceGeneration < this.#sourceGeneration
		) {
			return false;
		}
		this.#sourceGeneration = snapshot.sourceGeneration;
		const installsControlOnly = props.contentSessionIds?.length === 0;
		const mergedThreads = installsControlOnly
			? this.#snapshot.threads
			: mergeAnnotationContentThreads({
					catalog: catalogProjection.catalog,
					currentThreads: this.#snapshot.threads,
					incomingThreads: snapshot.threads,
					requestedSessionIds: props.contentSessionIds,
				});
		const serverThreads = annotationThreadProjectionsSemanticallyMatch(
			this.#snapshot.threads,
			mergedThreads,
		)
			? this.#snapshot.threads
			: mergedThreads;
		this.#recordCompleteContentRevisions(props.contentSessionIds, snapshot.sessions);
		const receiptReconciliation = reconcileCommandConfirmedReceipts({
			commandConfirmedMessagesById: this.#commandConfirmedMessagesById,
			commandConfirmedRemovalsByMessageId: this.#commandConfirmedRemovalsByMessageId,
			completeContentRevisionBySessionId: this.#completeContentRevisionBySessionId,
			threads: serverThreads,
		});
		const threads = suppressCommandConfirmedRemovals(
			serverThreads,
			this.#commandConfirmedRemovalsByMessageId,
		);
		if (props.reviewAnnotationApplication !== null) {
			this.#pendingReviewAnnotationApplication = mergeReviewAnnotationApplication({
				current: this.#pendingReviewAnnotationApplication,
				incoming: {
					...props.reviewAnnotationApplication,
					changedThreadOwnerContexts: changedAnnotationThreadOwnerContexts(
						this.#snapshot.threads,
						threads,
					),
				},
			});
		}
		this.#publish({
			commandConfirmedThreads: commandConfirmedThreads(
				this.#commandConfirmedMessagesById.values(),
				this.#snapshot.commandConfirmedThreads,
			),
			commandOutcomes: this.#snapshot.commandOutcomes,
			outputHistory: this.#snapshot.outputHistory,
			operationCorrelationId: props.operationCorrelationId,
			readStatus:
				receiptReconciliation === 'contradictory'
					? { kind: 'unavailable', retryable: true }
					: (installsControlOnly && props.expectedContentSessionIds.length > 0) ||
						  this.#hasIncompleteSessionContent(props.expectedContentSessionIds)
						? { kind: 'refreshing' }
						: { kind: 'ready' },
			recoveryStatus: snapshot.recoveryStatus,
			reviewAnnotationApplication: this.#pendingReviewAnnotationApplication,
			revision: snapshot.projectionRevision,
			sessions: snapshot.sessions,
			sourceGeneration: snapshot.sourceGeneration,
			threads,
			unreconciledCommandReceiptSessionIds: unreconciledCommandReceiptSessionIds(
				this.#commandConfirmedMessagesById.values(),
				this.#commandConfirmedRemovalsByMessageId.values(),
			),
			worktreeId: snapshot.worktreeId,
		});
		return true;
	}

	acknowledgeReviewAnnotationApplication(applicationId: number): boolean {
		if (this.#pendingReviewAnnotationApplication?.applicationId !== applicationId) return false;
		this.#pendingReviewAnnotationApplication = null;
		this.#publish({ ...this.#snapshot, reviewAnnotationApplication: null });
		return true;
	}

	discardPendingReviewAnnotationApplication(): void {
		if (this.#pendingReviewAnnotationApplication === null) return;
		this.#pendingReviewAnnotationApplication = null;
		this.#publish({ ...this.#snapshot, reviewAnnotationApplication: null });
	}

	applyCatalogStaging(
		event: BridgeWorkerAnnotationCatalogStagingEvent,
	): BridgeCommWorkerAnnotationCatalogApplicatorResult {
		const authorityReplaced = this.#catalogStaging.replaceExpectedAuthority(event.authority);
		if (authorityReplaced && this.#catalogProjection.kind === 'current') {
			this.#completeContentRevisionBySessionId.clear();
			this.#catalogProjection = { ...this.#catalogProjection, kind: 'stale' };
			this.#publish({ ...this.#snapshot, readStatus: { kind: 'refreshing' } });
		}
		const result = this.#catalogStaging.accept(event);
		if (result.status !== 'completed') return result;
		for (const sessionId of this.#completeContentRevisionBySessionId.keys()) {
			if (!result.catalog.sessionsById.has(sessionId)) {
				this.#completeContentRevisionBySessionId.delete(sessionId);
			}
		}
		this.#catalogProjection = { catalog: result.catalog, kind: 'current' };
		this.#publish({
			...this.#snapshot,
			outputHistory: this.#snapshot.outputHistory.filter((summary) =>
				result.catalog.sessionsById.has(summary.sessionId),
			),
			readStatus: { kind: 'refreshing' },
			reviewAnnotationApplication: this.#pendingReviewAnnotationApplication,
			threads: this.#snapshot.threads.filter((thread) => {
				const sessionId = annotationThreadSessionId(result.catalog, thread);
				return sessionId !== null && result.catalog.sessionsById.has(sessionId);
			}),
		});
		return result;
	}

	prepareForWorkerReplacement(): void {
		this.#catalogStaging.retireExpectedAuthority();
		this.#completeContentRevisionBySessionId.clear();
		this.#pendingReviewAnnotationApplication = null;
		if (this.#catalogProjection.kind !== 'current') return;
		this.#catalogProjection = { ...this.#catalogProjection, kind: 'stale' };
		this.#publish({
			...this.#snapshot,
			readStatus: { kind: 'refreshing' },
			reviewAnnotationApplication: null,
		});
	}

	markRefreshing(): void {
		if (this.#snapshot.readStatus.kind === 'refreshing') return;
		this.#publish({ ...this.#snapshot, readStatus: { kind: 'refreshing' } });
	}

	markSessionDemanded(sessionId: string): void {
		if (this.#hasIncompleteSessionContent([sessionId])) this.markRefreshing();
	}

	#hasIncompleteSessionContent(sessionIds: readonly string[]): boolean {
		const catalog = this.#catalogProjection;
		if (catalog.kind !== 'current') return true;
		return sessionIds.some((sessionId): boolean => {
			const session = catalog.catalog.sessionsById.get(sessionId);
			return (
				session !== undefined &&
				(this.#completeContentRevisionBySessionId.get(sessionId) ?? -1) < session.semanticRevision
			);
		});
	}

	markUnavailable(retryable: boolean): void {
		if (
			this.#snapshot.readStatus.kind === 'unavailable' &&
			this.#snapshot.readStatus.retryable === retryable
		) {
			return;
		}
		this.#publish({
			...this.#snapshot,
			readStatus: { kind: 'unavailable', retryable },
		});
	}

	recordCommandOutcome(outcome: WorktreeAnnotationCommandOutcome): void {
		if (outcome.status.kind === 'committed' && outcome.receipt !== undefined) {
			this.#recordCommandReceipt(outcome.receipt);
		}
		const receiptReconciliation = reconcileCommandConfirmedReceipts({
			commandConfirmedMessagesById: this.#commandConfirmedMessagesById,
			commandConfirmedRemovalsByMessageId: this.#commandConfirmedRemovalsByMessageId,
			completeContentRevisionBySessionId: this.#completeContentRevisionBySessionId,
			threads: this.#snapshot.threads,
		});
		const retainedOutcomes = this.#snapshot.commandOutcomes.filter(
			(candidate) => candidate.requestId !== outcome.requestId,
		);
		this.#publish({
			...this.#snapshot,
			commandConfirmedThreads: commandConfirmedThreads(
				this.#commandConfirmedMessagesById.values(),
				this.#snapshot.commandConfirmedThreads,
			),
			commandOutcomes: [...retainedOutcomes, outcome].slice(-128),
			readStatus:
				receiptReconciliation === 'contradictory'
					? { kind: 'unavailable', retryable: true }
					: this.#snapshot.readStatus,
			threads: suppressCommandConfirmedRemovals(
				this.#snapshot.threads,
				this.#commandConfirmedRemovalsByMessageId,
			),
			unreconciledCommandReceiptSessionIds: unreconciledCommandReceiptSessionIds(
				this.#commandConfirmedMessagesById.values(),
				this.#commandConfirmedRemovalsByMessageId.values(),
			),
		});
	}

	replaceOutputHistory(outputHistory: readonly WorktreeAnnotationOutputHistorySummary[]): void {
		this.#publish({ ...this.#snapshot, outputHistory });
	}

	replaceOutputHistoryForSession(
		sessionId: string,
		outputHistory: readonly WorktreeAnnotationOutputHistorySummary[],
	): void {
		const retainedHistory = this.#snapshot.outputHistory.filter(
			(summary) => summary.sessionId !== sessionId,
		);
		const matchingHistory = outputHistory.filter((summary) => summary.sessionId === sessionId);
		this.#publish({
			...this.#snapshot,
			outputHistory: [...retainedHistory, ...matchingHistory],
		});
	}

	#recordCommandReceipt(receipt: WorktreeAnnotationCommandReceipt): void {
		if (receipt.kind === 'message_removed') {
			const currentMessage = this.#commandConfirmedMessagesById.get(receipt.messageId);
			if (
				currentMessage !== undefined &&
				receipt.removedMessageRevision < currentMessage.message.messageRevision
			) {
				return;
			}
			const currentRemoval = this.#commandConfirmedRemovalsByMessageId.get(receipt.messageId);
			if (
				currentRemoval === undefined ||
				receipt.removedMessageRevision > currentRemoval.removedMessageRevision ||
				(receipt.removedMessageRevision === currentRemoval.removedMessageRevision &&
					receipt.sessionRevision >= currentRemoval.sessionRevision)
			) {
				this.#commandConfirmedRemovalsByMessageId.set(receipt.messageId, receipt);
				this.#commandConfirmedMessagesById.delete(receipt.messageId);
				this.#removedMessageIds.add(receipt.messageId);
			}
			return;
		}
		if (this.#removedMessageIds.has(receipt.message.messageId)) return;
		const currentMessage = this.#commandConfirmedMessagesById.get(receipt.message.messageId);
		if (
			currentMessage === undefined ||
			receipt.message.messageRevision > currentMessage.message.messageRevision ||
			(receipt.message.messageRevision === currentMessage.message.messageRevision &&
				receipt.message.sessionRevision >= currentMessage.message.sessionRevision &&
				receipt.message.threadRevision >= currentMessage.message.threadRevision)
		) {
			this.#commandConfirmedMessagesById.set(receipt.message.messageId, receipt);
		}
	}

	#recordCompleteContentRevisions(
		contentSessionIds: readonly string[] | undefined,
		sessions: readonly WorktreeAnnotationSessionSummary[],
	): void {
		const completeSessionIds = contentSessionIds ?? sessions.map((session) => session.sessionId);
		const revisionBySessionId = new Map(
			sessions.map((session) => [session.sessionId, session.semanticRevision] as const),
		);
		for (const sessionId of completeSessionIds) {
			const semanticRevision = revisionBySessionId.get(sessionId);
			if (semanticRevision !== undefined) {
				this.#completeContentRevisionBySessionId.set(sessionId, semanticRevision);
			}
		}
	}

	#publish(snapshot: Omit<WorktreeAnnotationProjectionSnapshot, 'presentationRevision'>): void {
		this.#snapshot = {
			...snapshot,
			presentationRevision: this.#snapshot.presentationRevision + 1,
			reviewAnnotationApplication: this.#pendingReviewAnnotationApplication,
		};
		for (const listener of this.#listeners) listener();
	}
}

function commandConfirmedThreads(
	receipts: IterableIterator<WorktreeAnnotationMessageReceipt>,
	previousThreads: readonly WorktreeAnnotationCommandConfirmedThreadProjection[],
): readonly WorktreeAnnotationCommandConfirmedThreadProjection[] {
	const threadsById = new Map<string, WorktreeAnnotationCommandConfirmedThreadProjection>();
	for (const receipt of receipts) {
		const current = threadsById.get(receipt.context.threadId);
		const messages = [...(current?.messages ?? []), receipt.message].toSorted(
			(left, right): number => left.ordinal - right.ordinal,
		);
		threadsById.set(receipt.context.threadId, {
			context: { ...receipt.context, placement: 'command_confirmed' },
			messages,
		});
	}
	const nextThreads = [...threadsById.values()].toSorted(compareAnnotationThreads);
	return annotationThreadProjectionsSemanticallyMatch(previousThreads, nextThreads)
		? previousThreads
		: nextThreads;
}

function unreconciledCommandReceiptSessionIds(
	messageReceipts: IterableIterator<WorktreeAnnotationMessageReceipt>,
	removalReceipts: IterableIterator<WorktreeAnnotationMessageRemovedReceipt>,
): readonly string[] {
	return [
		...new Set([
			...[...messageReceipts].map((receipt) => receipt.message.sessionId),
			...[...removalReceipts].map((receipt) => receipt.sessionId),
		]),
	].toSorted();
}

function suppressCommandConfirmedRemovals(
	threads: readonly WorktreeAnnotationThreadProjection[],
	removalsByMessageId: ReadonlyMap<string, WorktreeAnnotationMessageRemovedReceipt>,
): readonly WorktreeAnnotationThreadProjection[] {
	if (removalsByMessageId.size === 0) return threads;
	return threads.flatMap((thread): readonly WorktreeAnnotationThreadProjection[] => {
		const messages = thread.messages.filter((message) => {
			const removal = removalsByMessageId.get(message.messageId);
			return removal === undefined || message.messageRevision > removal.removedMessageRevision;
		});
		return messages.length === 0 ? [] : [{ ...thread, messages }];
	});
}

function reconcileCommandConfirmedReceipts(props: {
	readonly commandConfirmedMessagesById: Map<string, WorktreeAnnotationMessageReceipt>;
	readonly commandConfirmedRemovalsByMessageId: Map<
		string,
		WorktreeAnnotationMessageRemovedReceipt
	>;
	readonly completeContentRevisionBySessionId: ReadonlyMap<string, number>;
	readonly threads: readonly WorktreeAnnotationThreadProjection[];
}): 'consistent' | 'contradictory' {
	const projectedMessageById = new Map(
		props.threads
			.flatMap((thread) => thread.messages)
			.map((message) => [message.messageId, message]),
	);
	let result: 'consistent' | 'contradictory' = 'consistent';
	for (const [messageId, receipt] of props.commandConfirmedMessagesById) {
		const projectedMessage = projectedMessageById.get(messageId);
		const containingRevisionsAreCurrent =
			projectedMessage !== undefined &&
			projectedMessage.sessionRevision >= receipt.message.sessionRevision &&
			projectedMessage.threadRevision >= receipt.message.threadRevision;
		if (
			projectedMessage !== undefined &&
			projectedMessage.messageRevision > receipt.message.messageRevision &&
			containingRevisionsAreCurrent
		) {
			props.commandConfirmedMessagesById.delete(messageId);
			continue;
		}
		const sessionRevision = props.completeContentRevisionBySessionId.get(receipt.message.sessionId);
		if (sessionRevision === undefined || sessionRevision < receipt.message.sessionRevision)
			continue;
		if (
			projectedMessage !== undefined &&
			projectedMessage.messageRevision === receipt.message.messageRevision &&
			containingRevisionsAreCurrent &&
			worktreeAnnotationMessagesSemanticallyMatch(projectedMessage, receipt.message)
		) {
			props.commandConfirmedMessagesById.delete(messageId);
			continue;
		}
		if (sessionRevision > receipt.message.sessionRevision) {
			// Complete content at a newer session revision already includes this commit
			// and whatever changed it since, possibly from another surface or pane.
			props.commandConfirmedMessagesById.delete(messageId);
			continue;
		}
		result = 'contradictory';
	}
	for (const [messageId, removal] of props.commandConfirmedRemovalsByMessageId) {
		const sessionRevision = props.completeContentRevisionBySessionId.get(removal.sessionId);
		if (sessionRevision === undefined || sessionRevision < removal.sessionRevision) continue;
		if (!projectedMessageById.has(messageId) || sessionRevision > removal.sessionRevision) {
			props.commandConfirmedRemovalsByMessageId.delete(messageId);
			continue;
		}
		result = 'contradictory';
	}
	return result;
}

function worktreeAnnotationMessagesSemanticallyMatch(
	left: WorktreeAnnotationMessageEntry,
	right: WorktreeAnnotationMessageEntry,
): boolean {
	return (
		left.attentionState === right.attentionState &&
		left.authorKind === right.authorKind &&
		left.createdAt === right.createdAt &&
		worktreeAnnotationDraftsSemanticallyMatch(left.draft, right.draft) &&
		left.handled === right.handled &&
		left.messageId === right.messageId &&
		left.messageRevision === right.messageRevision &&
		left.ordinal === right.ordinal &&
		left.savedBody === right.savedBody &&
		left.savedRevision === right.savedRevision &&
		left.sessionId === right.sessionId &&
		left.status === right.status &&
		left.threadId === right.threadId
	);
}

function worktreeAnnotationDraftsSemanticallyMatch(
	left: WorktreeAnnotationMessageEntry['draft'],
	right: WorktreeAnnotationMessageEntry['draft'],
): boolean {
	return (
		left === right ||
		(left !== null &&
			right !== null &&
			left.activeEditToken === right.activeEditToken &&
			left.body === right.body &&
			left.revision === right.revision)
	);
}

function changedAnnotationThreadOwnerContexts(
	previousThreads: readonly WorktreeAnnotationThreadProjection[],
	currentThreads: readonly WorktreeAnnotationThreadProjection[],
): readonly WorktreeAnnotationThreadContext[] {
	const previousByThreadId = new Map(
		previousThreads.map((thread) => [thread.context.threadId, thread] as const),
	);
	const currentByThreadId = new Map(
		currentThreads.map((thread) => [thread.context.threadId, thread] as const),
	);
	const changedOwnerContexts: WorktreeAnnotationThreadContext[] = [];
	const threadIds = new Set([...previousByThreadId.keys(), ...currentByThreadId.keys()]);
	for (const threadId of [...threadIds].toSorted()) {
		const previousThread = previousByThreadId.get(threadId);
		const currentThread = currentByThreadId.get(threadId);
		if (
			previousThread !== undefined &&
			currentThread !== undefined &&
			worktreeAnnotationThreadSemanticIdentity(previousThread) ===
				worktreeAnnotationThreadSemanticIdentity(currentThread)
		) {
			continue;
		}
		if (previousThread !== undefined) changedOwnerContexts.push(previousThread.context);
		if (currentThread !== undefined) changedOwnerContexts.push(currentThread.context);
	}
	return changedOwnerContexts;
}

function mergeReviewAnnotationApplication(props: {
	readonly current: WorktreeAnnotationReviewApplication | null;
	readonly incoming: WorktreeAnnotationReviewApplication;
}): WorktreeAnnotationReviewApplication {
	if (props.current === null) return props.incoming;
	return {
		affectedItemIds:
			props.current.affectedItemIds === null || props.incoming.affectedItemIds === null
				? null
				: [...new Set([...props.current.affectedItemIds, ...props.incoming.affectedItemIds])],
		applicationId: props.incoming.applicationId,
		changedThreadOwnerContexts: uniqueAnnotationThreadOwnerContexts([
			...props.current.changedThreadOwnerContexts,
			...props.incoming.changedThreadOwnerContexts,
		]),
	};
}

function uniqueAnnotationThreadOwnerContexts(
	contexts: readonly WorktreeAnnotationThreadContext[],
): readonly WorktreeAnnotationThreadContext[] {
	const byIdentity = new Map<string, WorktreeAnnotationThreadContext>();
	for (const context of contexts) byIdentity.set(JSON.stringify(context), context);
	return [...byIdentity.values()];
}

export function worktreeAnnotationThreadSemanticIdentity(
	thread: WorktreeAnnotationInlineThreadProjection,
): string {
	const context = thread.context;
	return JSON.stringify([
		context.scope,
		context.threadId,
		context.sourceRole,
		context.sourceIdentity,
		context.path,
		context.placement,
		context.resolution,
		context.diffSide,
		context.startLine,
		context.endLine,
		thread.messages.map((message) => [
			message.messageId,
			message.ordinal,
			message.authorKind,
			message.createdAt,
			message.attentionState,
			message.handled,
			message.messageRevision,
			message.savedRevision,
			message.draft?.revision ?? null,
			message.draft?.activeEditToken ?? null,
			message.sessionId,
			message.sessionRevision,
			message.status,
			message.threadId,
			message.threadRevision,
		]),
	]);
}

function annotationThreadProjectionsSemanticallyMatch(
	left: readonly WorktreeAnnotationInlineThreadProjection[],
	right: readonly WorktreeAnnotationInlineThreadProjection[],
): boolean {
	return (
		left.length === right.length &&
		left.every((thread, index): boolean => {
			const rightThread = right[index];
			return (
				rightThread !== undefined &&
				worktreeAnnotationThreadSemanticIdentity(thread) ===
					worktreeAnnotationThreadSemanticIdentity(rightThread) &&
				thread.messages.length === rightThread.messages.length &&
				thread.messages.every((message, messageIndex): boolean => {
					const rightMessage = rightThread.messages[messageIndex];
					return (
						rightMessage !== undefined &&
						worktreeAnnotationMessagesSemanticallyMatch(message, rightMessage)
					);
				})
			);
		})
	);
}

function compareAnnotationThreads(
	left: WorktreeAnnotationInlineThreadProjection,
	right: WorktreeAnnotationInlineThreadProjection,
): number {
	const leftKey = [
		left.context.path,
		left.context.startLine,
		left.context.endLine,
		left.context.threadId,
	];
	const rightKey = [
		right.context.path,
		right.context.startLine,
		right.context.endLine,
		right.context.threadId,
	];
	return JSON.stringify(leftKey).localeCompare(JSON.stringify(rightKey));
}

function mergeAnnotationContentThreads(props: {
	readonly catalog: BridgeCommWorkerAnnotationCatalog;
	readonly currentThreads: readonly WorktreeAnnotationThreadProjection[];
	readonly incomingThreads: readonly WorktreeAnnotationThreadProjection[];
	readonly requestedSessionIds: readonly string[] | undefined;
}): readonly WorktreeAnnotationThreadProjection[] {
	if (props.requestedSessionIds === undefined) {
		return props.incomingThreads.toSorted(compareAnnotationThreads);
	}
	const requestedSessionIds = new Set(props.requestedSessionIds);
	const retainedThreads = props.currentThreads.filter((thread) => {
		const sessionId = annotationThreadSessionId(props.catalog, thread);
		return sessionId !== null && !requestedSessionIds.has(sessionId);
	});
	return [...retainedThreads, ...props.incomingThreads].toSorted(compareAnnotationThreads);
}

function annotationThreadSessionId(
	catalog: BridgeCommWorkerAnnotationCatalog,
	thread: WorktreeAnnotationThreadProjection,
): string | null {
	return (
		catalog.threadsById.get(thread.context.threadId)?.sessionId ??
		thread.messages[0]?.sessionId ??
		null
	);
}

function annotationProjectionContentMatchesCatalog(
	catalog: BridgeCommWorkerAnnotationCatalog,
	threads: readonly WorktreeAnnotationThreadProjection[],
	contentSessionIds: readonly string[],
): boolean {
	const demandedSessionIds = new Set(contentSessionIds);
	for (const thread of threads) {
		const catalogThread = catalog.threadsById.get(thread.context.threadId);
		if (catalogThread === undefined || !demandedSessionIds.has(catalogThread.sessionId))
			return false;
		for (const message of thread.messages) {
			const catalogMessage = catalog.messagesById.get(message.messageId);
			if (
				catalogMessage === undefined ||
				catalogMessage.threadId !== thread.context.threadId ||
				message.threadId !== thread.context.threadId ||
				message.sessionId !== catalogThread.sessionId
			) {
				return false;
			}
		}
	}
	return true;
}

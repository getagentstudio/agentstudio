import { describe, expect, test } from 'vitest';

import type { BridgeCommWorkerAnnotationCatalog } from '../core/comm-worker/bridge-comm-worker-annotation-catalog-applicator.js';
import type { BridgeWorkerAnnotationProjectionSnapshot } from '../core/comm-worker/bridge-comm-worker-annotation-projection-decoder.js';
import { bridgeCommWorkerAnnotationCatalogStagingEvents } from '../core/comm-worker/bridge-comm-worker-annotation-runtime-events.js';
import type { BridgeWorkerAnnotationCatalogStagingEvent } from '../core/comm-worker/bridge-worker-annotation-contracts.js';
import { makeBridgeReviewPackage } from '../foundation/review-package/bridge-review-package-test-support.js';
import { reviewAnnotationApplicationItemIds } from '../review-viewer/code-view/use-bridge-code-view-worktree-annotations.js';
import { WorktreeAnnotationProjectionStore } from './worktree-annotation-projection-store.js';
import type {
	WorktreeAnnotationCommandOutcome,
	WorktreeAnnotationThreadContext,
} from './worktree-annotation-surface-client.js';

describe('WorktreeAnnotationProjectionStore read convergence', () => {
	test('starts without a pending Review annotation application', () => {
		const store = new WorktreeAnnotationProjectionStore();

		expect(store.getSnapshot().reviewAnnotationApplication).toBeNull();
	});

	test('starts unknown until the first complete projection installs', () => {
		const store = new WorktreeAnnotationProjectionStore();

		expect(store.getSnapshot()).toMatchObject({
			commandConfirmedThreads: [],
			readStatus: { kind: 'unknown' },
			revision: null,
			sessions: [],
			threads: [],
			worktreeId: null,
		});
	});

	test('preserves empty and unchanged command-confirmed thread identities', () => {
		const store = readyStore();
		const initialEmptyThreads = store.getSnapshot().commandConfirmedThreads;

		applyProjection(store, snapshot(1, 1));
		expect(store.getSnapshot().commandConfirmedThreads).toBe(initialEmptyThreads);

		const outcome = committedMessageOutcome({
			message: annotationMessageEntry({ body: 'Stable body', messageRevision: 3 }),
		});
		store.recordCommandOutcome(outcome);
		const initialCommittedThreads = store.getSnapshot().commandConfirmedThreads;

		store.recordCommandOutcome(outcome);
		expect(store.getSnapshot().commandConfirmedThreads).toBe(initialCommittedThreads);
	});

	test('publishes command-confirmed body, source, and removal changes', () => {
		const store = readyStore();
		let publicationCount = 0;
		store.subscribe((): void => {
			publicationCount += 1;
		});
		const initialMessage = annotationMessageEntry({ body: 'Initial body', messageRevision: 3 });
		store.recordCommandOutcome(committedMessageOutcome({ message: initialMessage }));
		let previousThreads = store.getSnapshot().commandConfirmedThreads;

		const changedSavedMessage = { ...initialMessage, savedBody: 'Changed saved body' };
		store.recordCommandOutcome(committedMessageOutcome({ message: changedSavedMessage }));
		expect(store.getSnapshot().commandConfirmedThreads).not.toBe(previousThreads);
		expect(store.getSnapshot().commandConfirmedThreads[0]?.messages[0]?.savedBody).toBe(
			'Changed saved body',
		);
		previousThreads = store.getSnapshot().commandConfirmedThreads;

		const changedDraftMessage = {
			...initialMessage,
			draft: { activeEditToken: 'edit-token', body: 'Changed draft body', revision: 1 },
			savedBody: null,
			savedRevision: null,
		};
		store.recordCommandOutcome(committedMessageOutcome({ message: changedDraftMessage }));
		expect(store.getSnapshot().commandConfirmedThreads).not.toBe(previousThreads);
		expect(store.getSnapshot().commandConfirmedThreads[0]?.messages[0]?.draft?.body).toBe(
			'Changed draft body',
		);
		previousThreads = store.getSnapshot().commandConfirmedThreads;

		const changedDraftBodyOnlyMessage = {
			...changedDraftMessage,
			draft: { ...changedDraftMessage.draft, body: 'Changed draft body only' },
		};
		store.recordCommandOutcome(committedMessageOutcome({ message: changedDraftBodyOnlyMessage }));
		expect(store.getSnapshot().commandConfirmedThreads).not.toBe(previousThreads);
		expect(store.getSnapshot().commandConfirmedThreads[0]?.messages[0]?.draft?.body).toBe(
			'Changed draft body only',
		);
		previousThreads = store.getSnapshot().commandConfirmedThreads;

		store.recordCommandOutcome(
			committedMessageOutcome({
				context: { ...annotationThreadContext, sourceIdentity: 'source-2' },
				message: changedDraftBodyOnlyMessage,
			}),
		);
		expect(store.getSnapshot().commandConfirmedThreads).not.toBe(previousThreads);
		expect(store.getSnapshot().commandConfirmedThreads[0]?.context.sourceIdentity).toBe('source-2');
		previousThreads = store.getSnapshot().commandConfirmedThreads;

		store.recordCommandOutcome(committedRemovalOutcome({ threadRevision: null }));
		expect(store.getSnapshot().commandConfirmedThreads).not.toBe(previousThreads);
		expect(store.getSnapshot().commandConfirmedThreads).toEqual([]);
		expect(publicationCount).toBe(6);
	});

	test('retains a canonical message over stale projection and reconciles an equal revision', () => {
		const store = readyStore();
		const receiptOutcome = committedMessageOutcome({
			message: annotationMessageEntry({ body: 'Command-confirmed body', messageRevision: 3 }),
		});
		store.recordCommandOutcome(receiptOutcome);
		store.recordCommandOutcome(receiptOutcome);

		expect(store.getSnapshot().commandConfirmedThreads).toMatchObject([
			{
				context: { placement: 'command_confirmed' },
				messages: [{ savedBody: 'Command-confirmed body' }],
			},
		]);
		expect(store.getSnapshot().commandConfirmedThreads[0]?.messages).toHaveLength(1);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([
			'01890abc-def0-7abc-8def-0123456789ab',
		]);

		applyProjection(
			store,
			projectionWithMessage(annotationMessageEntry({ body: 'Stale body', messageRevision: 2 }), 2),
		);
		expect(store.getSnapshot().commandConfirmedThreads[0]?.messages[0]?.savedBody).toBe(
			'Command-confirmed body',
		);

		applyProjection(
			store,
			projectionWithMessage(
				annotationMessageEntry({ body: 'Command-confirmed body', messageRevision: 3 }),
				3,
			),
		);
		expect(store.getSnapshot().commandConfirmedThreads).toEqual([]);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([]);
	});

	test('keeps a contradictory same-revision receipt visible and marks convergence unavailable', () => {
		const store = readyStore();
		store.recordCommandOutcome(
			committedMessageOutcome({
				message: annotationMessageEntry({ body: 'Committed body', messageRevision: 3 }),
			}),
		);

		applyProjection(
			store,
			projectionWithMessage(
				annotationMessageEntry({ body: 'Contradictory body', messageRevision: 3 }),
				3,
			),
		);

		expect(store.getSnapshot().readStatus).toEqual({ kind: 'unavailable', retryable: true });
		expect(store.getSnapshot().commandConfirmedThreads[0]?.messages[0]?.savedBody).toBe(
			'Committed body',
		);
	});

	test('complete content at a newer session revision supersedes a contradicted message receipt', () => {
		// Arrange: this pane committed the message; another actor later removed it.
		const store = readyStore();
		store.recordCommandOutcome(
			committedMessageOutcome({
				message: annotationMessageEntry({ body: 'Committed here', messageRevision: 3 }),
			}),
		);

		// Act
		applyProjection(store, projectionWithNoMessages(5));

		// Assert: server authority wins without latching Updates unavailable.
		expect(store.getSnapshot().readStatus).toEqual({ kind: 'ready' });
		expect(store.getSnapshot().commandConfirmedThreads).toEqual([]);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([]);
	});

	test('does not retain a late message receipt already superseded by newer complete content', () => {
		// Arrange
		const store = readyStore();
		applyProjection(store, projectionWithNoMessages(5));

		// Act
		store.recordCommandOutcome(
			committedMessageOutcome({ message: annotationMessageEntry({ messageRevision: 3 }) }),
		);

		// Assert
		expect(store.getSnapshot().readStatus).toEqual({ kind: 'ready' });
		expect(store.getSnapshot().commandConfirmedThreads).toEqual([]);
	});

	test('complete content at a newer session revision supersedes a contradicted removal receipt', () => {
		// Arrange: this pane removed the message; newer server content still holds it.
		const store = readyStore();
		store.recordCommandOutcome(committedRemovalOutcome({ threadRevision: null }));
		const restoredMessage = annotationMessageEntry({ body: 'Restored', messageRevision: 3 });

		// Act
		applyProjection(store, projectionWithMessage(restoredMessage, 5));

		// Assert
		expect(store.getSnapshot().readStatus).toEqual({ kind: 'ready' });
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([]);
		expect(store.getSnapshot().threads[0]?.messages[0]?.savedBody).toBe('Restored');
	});

	test('suppresses a removed message from stale projections until an absent current projection reconciles', () => {
		const store = readyStore();
		applyProjection(
			store,
			projectionWithMessage(annotationMessageEntry({ messageRevision: 2 }), 2),
		);
		store.recordCommandOutcome(committedRemovalOutcome({ threadRevision: null }));

		expect(store.getSnapshot().threads).toEqual([]);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([
			'01890abc-def0-7abc-8def-0123456789ab',
		]);

		applyProjection(store, projectionWithNoMessages(4));
		expect(store.getSnapshot().threads).toEqual([]);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([]);
	});

	test('removes only the tombstoned message while retaining its surviving thread', () => {
		const store = readyStore();
		const removedMessage = annotationMessageEntry({ messageRevision: 2 });
		const survivingMessage = {
			...annotationMessageEntry({ body: 'Surviving reply', messageRevision: 2 }),
			messageId: '01890abc-def0-7abc-8def-012345678903',
			ordinal: 1,
		};
		const projection = projectionWithMessage(removedMessage, 2);
		applyProjection(store, {
			...projection,
			expectedMessageCount: 2,
			threads: [{ context: annotationThreadContext, messages: [removedMessage, survivingMessage] }],
		});

		store.recordCommandOutcome(committedRemovalOutcome({ threadRevision: 5 }));

		expect(store.getSnapshot().threads).toMatchObject([
			{ messages: [{ messageId: survivingMessage.messageId, savedBody: 'Surviving reply' }] },
		]);
	});

	test('does not resurrect a tombstoned identity from a delayed older message receipt', () => {
		const store = readyStore();
		store.recordCommandOutcome(committedRemovalOutcome({ threadRevision: null }));

		store.recordCommandOutcome(
			committedMessageOutcome({ message: annotationMessageEntry({ messageRevision: 2 }) }),
		);

		expect(store.getSnapshot().commandConfirmedThreads).toEqual([]);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([
			'01890abc-def0-7abc-8def-0123456789ab',
		]);
	});

	test('keeps a reconciled tombstone identity terminal against later message replay', () => {
		const store = readyStore();
		store.recordCommandOutcome(committedRemovalOutcome({ threadRevision: null }));
		applyProjection(store, projectionWithNoMessages(4));

		store.recordCommandOutcome(
			committedMessageOutcome({ message: annotationMessageEntry({ messageRevision: 2 }) }),
		);

		expect(store.getSnapshot().commandConfirmedThreads).toEqual([]);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([]);
	});

	test('does not let a delayed older tombstone erase a newer message receipt', () => {
		const store = readyStore();
		store.recordCommandOutcome(
			committedMessageOutcome({ message: annotationMessageEntry({ messageRevision: 5 }) }),
		);

		store.recordCommandOutcome(
			committedRemovalOutcome({ removedMessageRevision: 4, threadRevision: 5 }),
		);

		expect(store.getSnapshot().commandConfirmedThreads[0]?.messages[0]?.messageRevision).toBe(5);
	});

	test('reconciles message-owned equality across newer containing session and thread revisions', () => {
		const store = readyStore();
		const firstMessage = annotationMessageEntry({ body: 'First current body', messageRevision: 3 });
		const secondMessage = {
			...annotationMessageEntry({ body: 'Second current body', messageRevision: 1 }),
			messageId: '01890abc-def0-7abc-8def-012345678903',
			ordinal: 1,
			sessionRevision: 5,
			threadRevision: 3,
		};
		store.recordCommandOutcome(committedMessageOutcome({ message: firstMessage }));
		store.recordCommandOutcome(committedMessageOutcome({ message: secondMessage }));
		const currentFirstMessage = { ...firstMessage, sessionRevision: 5, threadRevision: 3 };
		const projection = projectionWithMessage(currentFirstMessage, 5);

		applyProjection(store, {
			...projection,
			expectedMessageCount: 2,
			threads: [
				{ context: annotationThreadContext, messages: [currentFirstMessage, secondMessage] },
			],
		});

		expect(store.getSnapshot().commandConfirmedThreads).toEqual([]);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([]);
		expect(store.getSnapshot().readStatus).toEqual({ kind: 'ready' });
	});

	test('does not reconcile missing message content from a control-only projection', () => {
		const store = readyStore();
		store.recordCommandOutcome(
			committedMessageOutcome({ message: annotationMessageEntry({ messageRevision: 3 }) }),
		);

		store.apply({
			contentSessionIds: [],
			expectedContentSessionIds: ['01890abc-def0-7abc-8def-0123456789ab'],
			operationCorrelationId: 'a'.repeat(64),
			reviewAnnotationApplication: null,
			snapshot: projectionWithNoMessages(4),
		});

		expect(store.getSnapshot().commandConfirmedThreads).toHaveLength(1);
		expect(store.getSnapshot().readStatus).toEqual({ kind: 'refreshing' });
	});

	test('does not retain a message receipt already covered by complete installed content', () => {
		const store = readyStore();
		const currentMessage = annotationMessageEntry({
			body: 'Projection arrived first',
			messageRevision: 3,
		});
		applyProjection(store, projectionWithMessage(currentMessage, 3));

		store.recordCommandOutcome(committedMessageOutcome({ message: currentMessage }));

		expect(store.getSnapshot().commandConfirmedThreads).toEqual([]);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([]);
		expect(store.getSnapshot().readStatus).toEqual({ kind: 'ready' });
	});

	test('does not retain a removal receipt already covered by complete installed absence', () => {
		const store = readyStore();
		applyProjection(store, projectionWithNoMessages(4));

		store.recordCommandOutcome(committedRemovalOutcome({ threadRevision: null }));

		expect(store.getSnapshot().commandConfirmedThreads).toEqual([]);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([]);
		expect(store.getSnapshot().readStatus).toEqual({ kind: 'ready' });
	});

	test('does not let a newer control-only summary authorize message absence', () => {
		const store = readyStore();
		applyProjection(store, projectionWithNoMessages(2));
		store.apply({
			contentSessionIds: [],
			expectedContentSessionIds: ['01890abc-def0-7abc-8def-0123456789ab'],
			operationCorrelationId: 'b'.repeat(64),
			reviewAnnotationApplication: null,
			snapshot: projectionWithNoMessages(4),
		});

		store.recordCommandOutcome(committedRemovalOutcome({ threadRevision: null }));

		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([
			'01890abc-def0-7abc-8def-0123456789ab',
		]);
	});

	test('does not reconcile a late receipt against content from retired worker authority', () => {
		const store = readyStore();
		const currentMessage = annotationMessageEntry({ messageRevision: 3 });
		applyProjection(store, projectionWithMessage(currentMessage, 3));
		store.prepareForWorkerReplacement();

		store.recordCommandOutcome(committedMessageOutcome({ message: currentMessage }));

		expect(store.getSnapshot().commandConfirmedThreads).toHaveLength(1);
		expect(store.getSnapshot().unreconciledCommandReceiptSessionIds).toEqual([
			'01890abc-def0-7abc-8def-0123456789ab',
		]);
	});

	test('retains the last complete projection while refreshing and unavailable', () => {
		const store = new WorktreeAnnotationProjectionStore();
		for (const phase of ['catalog.begin', 'catalog.window', 'catalog.commit'] as const) {
			store.applyCatalogStaging(catalogStaging(phase, 1));
		}
		const complete = snapshot(4, 7);
		applyProjection(store, complete);

		store.markRefreshing();
		expect(store.getSnapshot()).toMatchObject({
			readStatus: { kind: 'refreshing' },
			revision: 4,
			threads: complete.threads,
		});

		store.markUnavailable(true);

		expect(store.getSnapshot()).toMatchObject({
			readStatus: { kind: 'unavailable', retryable: true },
			revision: 4,
			threads: complete.threads,
		});

		applyProjection(store, snapshot(5, 8));
		expect(store.getSnapshot().readStatus).toEqual({ kind: 'ready' });
		expect(store.getSnapshot().revision).toBe(5);
	});

	test('publishes bounded Review item scope and both owners of a semantic thread change', () => {
		const store = new WorktreeAnnotationProjectionStore();
		for (const phase of ['catalog.begin', 'catalog.window', 'catalog.commit'] as const) {
			store.applyCatalogStaging(catalogStaging(phase, 1));
		}
		const previous = snapshot(4, 7);
		const previousThread = {
			context: {
				diffSide: 'additions' as const,
				endLine: 8,
				path: 'Sources/Old.swift',
				placement: 'exact' as const,
				resolution: 'open' as const,
				scope: 'located' as const,
				sourceIdentity: 'head-old',
				sourceRole: 'review_head' as const,
				startLine: 7,
				threadId: '00000000-0000-7000-8000-000000000012',
			},
			messages: [],
		};
		store.apply({
			contentSessionIds: undefined,
			expectedContentSessionIds: [],
			operationCorrelationId: 'a'.repeat(64),
			reviewAnnotationApplication: null,
			snapshot: { ...previous, expectedThreadCount: 1, threads: [previousThread] },
		});
		const currentThread = {
			...previousThread,
			context: {
				...previousThread.context,
				path: 'Sources/New.swift',
				sourceIdentity: 'head-new',
			},
		};

		store.apply({
			contentSessionIds: undefined,
			expectedContentSessionIds: [],
			operationCorrelationId: 'b'.repeat(64),
			reviewAnnotationApplication: { affectedItemIds: ['item-new'], applicationId: 1 },
			snapshot: {
				...snapshot(5, 8),
				expectedThreadCount: 1,
				threads: [currentThread],
			},
		});

		expect(store.getSnapshot().reviewAnnotationApplication).toEqual({
			affectedItemIds: ['item-new'],
			applicationId: 1,
			changedThreadOwnerContexts: [previousThread.context, currentThread.context],
		});
	});

	test('does not report thread owners when the complete semantic projection is equal', () => {
		const store = new WorktreeAnnotationProjectionStore();
		for (const phase of ['catalog.begin', 'catalog.window', 'catalog.commit'] as const) {
			store.applyCatalogStaging(catalogStaging(phase, 1));
		}
		const complete = snapshot(4, 7);
		store.apply({
			contentSessionIds: undefined,
			expectedContentSessionIds: [],
			operationCorrelationId: 'a'.repeat(64),
			reviewAnnotationApplication: null,
			snapshot: complete,
		});

		store.apply({
			contentSessionIds: undefined,
			expectedContentSessionIds: [],
			operationCorrelationId: 'b'.repeat(64),
			reviewAnnotationApplication: { affectedItemIds: [], applicationId: 1 },
			snapshot: { ...complete, projectionRevision: 5 },
		});

		expect(store.getSnapshot().reviewAnnotationApplication).toEqual({
			affectedItemIds: [],
			applicationId: 1,
			changedThreadOwnerContexts: [],
		});
	});

	test('stops exposing an acknowledged Review annotation application', () => {
		const store = new WorktreeAnnotationProjectionStore();
		for (const phase of ['catalog.begin', 'catalog.window', 'catalog.commit'] as const) {
			store.applyCatalogStaging(catalogStaging(phase, 1));
		}
		store.apply({
			contentSessionIds: undefined,
			expectedContentSessionIds: [],
			operationCorrelationId: 'a'.repeat(64),
			reviewAnnotationApplication: { affectedItemIds: ['item-source'], applicationId: 1 },
			snapshot: snapshot(4, 7),
		});
		const presentationRevisionBeforeAcknowledgement = store.getSnapshot().presentationRevision;

		expect(store.acknowledgeReviewAnnotationApplication(1)).toBe(true);

		expect(store.getSnapshot().reviewAnnotationApplication).toBeNull();
		expect(
			reviewAnnotationApplicationItemIds({
				activeEditorItemIds: [],
				application: store.getSnapshot().reviewAnnotationApplication,
				reviewPackage: makeBridgeReviewPackage(),
			}),
		).toEqual([]);
		expect(store.getSnapshot().presentationRevision).toBe(
			presentationRevisionBeforeAcknowledgement + 1,
		);
		expect(store.acknowledgeReviewAnnotationApplication(1)).toBe(false);
	});

	test('keeps catalog windows hidden and publishes exactly once at commit', () => {
		const store = new WorktreeAnnotationProjectionStore();
		let publicationCount = 0;
		store.subscribe((): void => {
			publicationCount += 1;
		});

		store.applyCatalogStaging(catalogStaging('catalog.begin', 7));
		store.applyCatalogStaging(catalogStaging('catalog.window', 7));
		expect(publicationCount).toBe(0);
		expect(store.getCatalogSnapshot()).toEqual({ kind: 'unknown' });

		expect(store.applyCatalogStaging(catalogStaging('catalog.commit', 7)).status).toBe('completed');
		expect(publicationCount).toBe(1);
		expect(store.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 7, orderedSessionIds: ['01890abc-def0-7abc-8def-0123456789ab'] },
			kind: 'current',
		});
	});

	test('worker replacement retires the candidate, retains active stale, and admits a lower revision', () => {
		const store = new WorktreeAnnotationProjectionStore();
		for (const phase of ['catalog.begin', 'catalog.window', 'catalog.commit'] as const) {
			store.applyCatalogStaging(catalogStaging(phase, 20));
		}
		store.applyCatalogStaging(catalogStaging('catalog.begin', 21));

		store.prepareForWorkerReplacement();
		expect(store.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 20 },
			kind: 'stale',
		});

		for (const phase of ['catalog.begin', 'catalog.window', 'catalog.commit'] as const) {
			store.applyCatalogStaging(catalogStaging(phase, 1, 'annotation-subscription-2', 2));
		}
		expect(store.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 1 },
			kind: 'current',
		});
	});

	test('rejects a late superseded Main window without discarding the newer candidate', () => {
		const store = new WorktreeAnnotationProjectionStore();
		store.applyCatalogStaging(catalogStaging('catalog.begin', 5));
		store.applyCatalogStaging(catalogStaging('catalog.begin', 6));

		expect(store.applyCatalogStaging(catalogStaging('catalog.window', 5))).toEqual({
			reason: 'noncurrent_transfer',
			status: 'rejected',
		});
		expect(store.applyCatalogStaging(catalogStaging('catalog.window', 6))).toEqual({
			status: 'accepted',
		});
		expect(store.applyCatalogStaging(catalogStaging('catalog.commit', 6)).status).toBe('completed');
		expect(store.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 6 },
			kind: 'current',
		});
	});

	test('applies a multi-window catalog incrementally and publishes only the final swap', () => {
		const store = new WorktreeAnnotationProjectionStore();
		const entries = Array.from({ length: 2_000 }, (_, index) => ({
			kind: 'session' as const,
			semanticRevision: index,
			sessionId: `01890abc-def0-7abc-8def-${index.toString(16).padStart(12, '0')}`,
		}));
		const sessionsById = new Map(entries.map((entry) => [entry.sessionId, entry]));
		const catalog = {
			authority: {
				subscriptionId: 'annotation-subscription-large',
				workerDerivationEpoch: 1,
				worktreeId: 'worktree-1',
			},
			catalogRevision: 7,
			entries,
			messageIdsByThreadId: new Map(),
			messagesById: new Map(),
			orderedSessionIds: entries.map((entry) => entry.sessionId),
			sessionsById,
			threadIdsBySessionId: new Map(),
			threadsById: new Map(),
			transferId: 'annotation-transfer-large',
		} satisfies BridgeCommWorkerAnnotationCatalog;
		const messages = bridgeCommWorkerAnnotationCatalogStagingEvents({
			catalog,
			surface: 'file',
		});
		let publicationCount = 0;
		store.subscribe((): void => {
			publicationCount += 1;
		});

		for (const message of messages.slice(0, -1)) store.applyCatalogStaging(message);
		expect(publicationCount).toBe(0);
		expect(store.getCatalogSnapshot()).toEqual({ kind: 'unknown' });
		const commit = messages.at(-1);
		if (commit === undefined) throw new Error('Expected annotation catalog commit.');
		store.applyCatalogStaging(commit);

		expect(publicationCount).toBe(1);
		expect(store.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 7, orderedSessionIds: catalog.orderedSessionIds },
			kind: 'current',
		});
	});
});

function catalogStaging(
	phase: 'catalog.begin' | 'catalog.commit' | 'catalog.window',
	catalogRevision: number,
	subscriptionId = 'annotation-subscription-1',
	workerDerivationEpoch = 1,
): BridgeWorkerAnnotationCatalogStagingEvent {
	const transfer =
		phase === 'catalog.begin'
			? {
					catalogRevision,
					expectedEntryCount: 1,
					kind: phase,
					transferId: `annotation-transfer-${catalogRevision}`,
				}
			: phase === 'catalog.window'
				? {
						catalogRevision,
						entries: [
							{
								kind: 'session' as const,
								semanticRevision: catalogRevision,
								sessionId: '01890abc-def0-7abc-8def-0123456789ab',
							},
						],
						kind: phase,
						transferId: `annotation-transfer-${catalogRevision}`,
						windowOrdinal: 0,
					}
				: {
						catalogRevision,
						entryCount: 1,
						kind: phase,
						transferId: `annotation-transfer-${catalogRevision}`,
						windowCount: 1,
					};
	return {
		authority: { subscriptionId, workerDerivationEpoch, worktreeId: 'worktree-1' },
		direction: 'serverWorkerToMain',
		kind: 'annotationCatalogStaging',
		surface: 'fileView',
		transfer,
		transferDescriptors: [],
		wireVersion: 1,
	};
}

function snapshot(
	projectionRevision: number,
	sourceGeneration: number,
): BridgeWorkerAnnotationProjectionSnapshot {
	return {
		expectedMessageCount: 0,
		expectedSessionCount: 0,
		expectedThreadCount: 0,
		projectionRevision,
		recoveryStatus: 'available',
		sessions: [],
		sourceGeneration,
		threads: [],
		worktreeId: 'worktree-1',
	};
}

function applyProjection(
	store: WorktreeAnnotationProjectionStore,
	projectionSnapshot: BridgeWorkerAnnotationProjectionSnapshot,
): void {
	store.apply({
		contentSessionIds: undefined,
		expectedContentSessionIds: [],
		operationCorrelationId: 'a'.repeat(64),
		reviewAnnotationApplication: null,
		snapshot: projectionSnapshot,
	});
}

function readyStore(): WorktreeAnnotationProjectionStore {
	const store = new WorktreeAnnotationProjectionStore();
	for (const phase of ['catalog.begin', 'catalog.window', 'catalog.commit'] as const) {
		store.applyCatalogStaging(catalogStaging(phase, 1));
	}
	return store;
}

function annotationMessageEntry(props: {
	readonly body?: string;
	readonly messageRevision: number;
}): BridgeWorkerAnnotationProjectionSnapshot['threads'][number]['messages'][number] {
	return {
		attentionState: 'not_applicable',
		authorKind: 'human',
		createdAt: 1,
		draft: null,
		handled: false,
		messageId: '01890abc-def0-7abc-8def-012345678901',
		messageRevision: props.messageRevision,
		ordinal: 0,
		savedBody: props.body ?? 'Saved body',
		savedRevision: 1,
		sessionId: '01890abc-def0-7abc-8def-0123456789ab',
		sessionRevision: props.messageRevision,
		status: 'editable',
		threadId: '01890abc-def0-7abc-8def-012345678902',
		threadRevision: 1,
	};
}

const annotationThreadContext = {
	diffSide: null,
	endLine: 2,
	path: 'Sources/App.swift',
	placement: 'exact',
	resolution: 'open',
	scope: 'located',
	sourceIdentity: 'source-1',
	sourceRole: 'file',
	startLine: 2,
	threadId: '01890abc-def0-7abc-8def-012345678902',
} as const;

function committedMessageOutcome(props: {
	readonly context?: WorktreeAnnotationThreadContext;
	readonly message: BridgeWorkerAnnotationProjectionSnapshot['threads'][number]['messages'][number];
}): WorktreeAnnotationCommandOutcome {
	const { placement: _placement, ...context } = props.context ?? annotationThreadContext;
	return {
		receipt: { context, kind: 'message', message: props.message },
		requestId: `command-message-${props.message.messageRevision}`,
		sessionId: props.message.sessionId,
		status: { kind: 'committed' },
		surface: 'file',
	};
}

function committedRemovalOutcome(props: {
	readonly removedMessageRevision?: number;
	readonly threadRevision: number | null;
}): WorktreeAnnotationCommandOutcome {
	return {
		receipt: {
			kind: 'message_removed',
			messageId: '01890abc-def0-7abc-8def-012345678901',
			removedMessageRevision: props.removedMessageRevision ?? 3,
			sessionId: '01890abc-def0-7abc-8def-0123456789ab',
			sessionRevision: 4,
			threadId: annotationThreadContext.threadId,
			threadRevision: props.threadRevision,
		},
		requestId: 'command-removal-4',
		sessionId: '01890abc-def0-7abc-8def-0123456789ab',
		status: { kind: 'committed' },
		surface: 'file',
	};
}

function projectionWithMessage(
	message: BridgeWorkerAnnotationProjectionSnapshot['threads'][number]['messages'][number],
	semanticRevision: number,
): BridgeWorkerAnnotationProjectionSnapshot {
	return {
		expectedMessageCount: 1,
		expectedSessionCount: 1,
		expectedThreadCount: 1,
		projectionRevision: semanticRevision,
		recoveryStatus: 'available',
		sessions: [annotationSessionSummary(semanticRevision)],
		sourceGeneration: semanticRevision,
		threads: [{ context: annotationThreadContext, messages: [message] }],
		worktreeId: 'worktree-1',
	};
}

function projectionWithNoMessages(
	semanticRevision: number,
): BridgeWorkerAnnotationProjectionSnapshot {
	return {
		expectedMessageCount: 0,
		expectedSessionCount: 1,
		expectedThreadCount: 0,
		projectionRevision: semanticRevision,
		recoveryStatus: 'available',
		sessions: [annotationSessionSummary(semanticRevision)],
		sourceGeneration: semanticRevision,
		threads: [],
		worktreeId: 'worktree-1',
	};
}

function annotationSessionSummary(
	semanticRevision: number,
): BridgeWorkerAnnotationProjectionSnapshot['sessions'][number] {
	return {
		completedAt: null,
		createdAt: 1,
		eligibleMessageCount: 1,
		eligibleWithoutInlinePlacementCount: 0,
		lifecycle: 'living',
		semanticRevision,
		sessionId: '01890abc-def0-7abc-8def-0123456789ab',
		sourceRelationship: 'applicable',
		updatedAt: semanticRevision,
	};
}

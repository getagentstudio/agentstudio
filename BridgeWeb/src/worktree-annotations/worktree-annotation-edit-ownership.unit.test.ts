import { describe, expect, test } from 'vitest';

import type { BridgeProductWorktreeAnnotationOperation } from '../core/comm-worker/bridge-product-call-contracts.js';
import { WorktreeAnnotationEditOwnershipController } from './worktree-annotation-edit-ownership.js';
import type {
	WorktreeAnnotationMessageEntry,
	WorktreeAnnotationProjectionSnapshot,
	WorktreeAnnotationSurfaceClient,
} from './worktree-annotation-surface-client.js';

describe('WorktreeAnnotationEditOwnershipController', () => {
	test('uses the committed Save receipt while the server projection still contains the old draft', async () => {
		// Arrange: Save has committed, but finite projection delivery is still behind.
		const fixture = createOwnershipFixture(messageWithDraft('old-editor-token'));
		const projectedSnapshot = fixture.client.getSnapshot();
		const serverThread = projectedSnapshot.threads[0];
		if (serverThread === undefined) throw new Error('Expected fixture thread.');
		const snapshot: WorktreeAnnotationProjectionSnapshot = {
			...projectedSnapshot,
			commandConfirmedThreads: [
				{
					context: { ...serverThread.context, placement: 'command_confirmed' },
					messages: [
						{ ...messageWithDraft(null), draft: null, messageRevision: 2, savedRevision: 2 },
					],
				},
			],
		};
		const controller = new WorktreeAnnotationEditOwnershipController({
			annotationClient: { ...fixture.client, getSnapshot: () => snapshot },
			editToken: 'new-editor-token',
			messageId: fixture.messageId,
		});

		// Act: immediately edit the saved message before projection catches up.
		await controller.acquire();

		// Assert: first flush creates the next draft; acquiring the deleted draft is invalid.
		expect(fixture.operations).toEqual([]);
	});

	test('acquires an existing draft with a new browser token and releases it in order', async () => {
		const fixture = createOwnershipFixture(messageWithDraft('persisted-stale-token'));
		const controller = new WorktreeAnnotationEditOwnershipController({
			annotationClient: fixture.client,
			editToken: 'browser-token',
			messageId: fixture.messageId,
		});

		await controller.acquire();
		await controller.release();

		expect(fixture.operations).toEqual([
			{
				editToken: 'browser-token',
				expectedDraftRevision: 1,
				expectedMessageRevision: 1,
				kind: 'draft.edit.acquire',
				messageId: fixture.messageId,
				sessionId: fixture.sessionId,
			},
			{
				editToken: 'browser-token',
				expectedDraftRevision: 2,
				expectedMessageRevision: 2,
				kind: 'draft.edit.release',
				messageId: fixture.messageId,
				sessionId: fixture.sessionId,
			},
		]);
	});

	test('does not acquire a saved message until its first draft flush creates ownership', async () => {
		const fixture = createOwnershipFixture({
			...messageWithDraft(null),
			draft: null,
			savedBody: 'Saved body',
			savedRevision: 1,
		});
		const controller = new WorktreeAnnotationEditOwnershipController({
			annotationClient: fixture.client,
			editToken: 'browser-token',
			messageId: fixture.messageId,
		});

		await controller.acquire();

		expect(fixture.operations).toEqual([]);
	});
});

function createOwnershipFixture(initialMessage: WorktreeAnnotationMessageEntry): {
	readonly client: WorktreeAnnotationSurfaceClient;
	readonly messageId: string;
	readonly operations: BridgeProductWorktreeAnnotationOperation[];
	readonly sessionId: string;
} {
	let message = initialMessage;
	const operations: BridgeProductWorktreeAnnotationOperation[] = [];
	const snapshot = (): WorktreeAnnotationProjectionSnapshot => ({
		commandConfirmedThreads: [],
		commandOutcomes: [],
		outputHistory: [],
		operationCorrelationId: null,
		presentationRevision: message.messageRevision,
		readStatus: { kind: 'ready' },
		recoveryStatus: 'available',
		reviewAnnotationApplication: null,
		revision: message.sessionRevision,
		sessions: [],
		threads: [
			{
				context: {
					diffSide: null,
					endLine: 1,
					path: 'Sources/App.swift',
					placement: 'exact',
					resolution: 'open',
					scope: 'located',
					sourceIdentity: 'source-1',
					sourceRole: 'file',
					startLine: 1,
					threadId: message.threadId,
				},
				messages: [message],
			},
		],
		sourceGeneration: 0,
		unreconciledCommandReceiptSessionIds: [],
		worktreeId: 'worktree-1',
	});
	const client: WorktreeAnnotationSurfaceClient = {
		acquireSession: () => (): void => {},
		acknowledgeReviewAnnotationApplication: (): boolean => false,
		dispose: (): void => {},
		execute: async (operation) => {
			operations.push(operation);
			if (operation.kind === 'draft.edit.acquire' && message.draft !== null) {
				message = {
					...message,
					draft: {
						...message.draft,
						activeEditToken: operation.editToken,
						revision: message.draft.revision + 1,
					},
					messageRevision: message.messageRevision + 1,
					sessionRevision: message.sessionRevision + 1,
				};
			}
			if (operation.kind === 'draft.edit.release' && message.draft !== null) {
				message = {
					...message,
					draft: {
						...message.draft,
						activeEditToken: null,
						revision: message.draft.revision + 1,
					},
					messageRevision: message.messageRevision + 1,
					sessionRevision: message.sessionRevision + 1,
				};
			}
			return {
				requestId: `request-${operations.length}`,
				sessionId: message.sessionId,
				status: { kind: 'committed' },
				surface: 'file',
			};
		},
		getCatalogSnapshot: () => ({ kind: 'unknown' }),
		getServerSnapshot: snapshot,
		getSnapshot: snapshot,
		getViewRecoveryStatus: () => null,
		inspectOutput: async () => {
			throw new Error('Unexpected output inspection.');
		},
		retryProjection: (): void => {},
		retryViewRecovery: (): void => {},
		subscribe: () => (): void => {},
		subscribeViewRecoveryStatus: () => (): void => {},
		waitForSnapshot: async (select) => {
			const result = select(snapshot());
			if (result === null) throw new Error('Expected immediate ownership projection.');
			return result;
		},
	};
	return {
		client,
		messageId: initialMessage.messageId,
		operations,
		sessionId: initialMessage.sessionId,
	};
}

function messageWithDraft(activeEditToken: string | null): WorktreeAnnotationMessageEntry {
	return {
		attentionState: 'not_applicable',
		authorKind: 'human',
		createdAt: 1,
		draft: { activeEditToken, body: 'Draft body', revision: 1 },
		handled: false,
		messageId: '00000000-0000-7000-8000-000000000031',
		messageRevision: 1,
		ordinal: 0,
		savedBody: 'Saved body',
		savedRevision: 1,
		sessionId: '00000000-0000-7000-8000-000000000011',
		sessionRevision: 3,
		status: 'editable',
		threadId: '00000000-0000-7000-8000-000000000021',
		threadRevision: 1,
	};
}

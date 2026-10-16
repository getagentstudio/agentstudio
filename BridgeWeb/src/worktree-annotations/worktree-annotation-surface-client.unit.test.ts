import { describe, expect, test, vi } from 'vitest';

import type { BridgeWorkerAnnotationProjectionSnapshot } from '../core/comm-worker/bridge-comm-worker-annotation-projection-decoder.js';
import { BRIDGE_WORKER_WIRE_VERSION } from '../core/comm-worker/bridge-worker-contracts.js';
import { WorktreeAnnotationProjectionStore } from './worktree-annotation-projection-store.js';
import {
	worktreeAnnotationOutcomeUnknownMessage,
	type WorktreeAnnotationOutputHistorySummary,
} from './worktree-annotation-surface-client.js';
import {
	catalogStagingMessages,
	createSurfaceClientHarness,
	messageId,
	projectionSnapshot,
	reviewPublicationIdentity,
	sessionId,
	siblingSessionId,
	threadId,
} from './worktree-annotation-surface-client.test-support.js';

describe('worktree annotation finite projection store', () => {
	test('installs one complete finite snapshot atomically', () => {
		const store = new WorktreeAnnotationProjectionStore();
		stageCatalog(store, 4);
		const listener = vi.fn();
		store.subscribe(listener);

		applyProjection(store, projectionSnapshot(4, 8));

		expect(listener).toHaveBeenCalledTimes(1);
		expect(store.getSnapshot()).toMatchObject({
			presentationRevision: 2,
			revision: 4,
			readStatus: { kind: 'ready' },
			worktreeId: 'worktree-1',
		});
		expect(store.getSnapshot().threads[0]?.messages[0]?.messageId).toBe(messageId);
	});

	test('rejects an older semantic revision without publishing', () => {
		const store = new WorktreeAnnotationProjectionStore();
		stageCatalog(store, 5);
		const listener = vi.fn();
		store.subscribe(listener);
		applyProjection(store, projectionSnapshot(5, 9));

		applyProjection(store, projectionSnapshot(4, 10));

		expect(listener).toHaveBeenCalledTimes(1);
		expect(store.getSnapshot().revision).toBe(5);
	});

	test('preserves exact command outcomes and cold output history across projection replacement', () => {
		const store = new WorktreeAnnotationProjectionStore();
		stageCatalog(store, 6);
		store.recordCommandOutcome({
			requestId: 'annotation-request-1',
			sessionId,
			status: { kind: 'committed' },
			surface: 'file',
		});
		store.replaceOutputHistory([
			{
				attemptId: '00000000-0000-7000-8000-000000000021',
				canMarkNotHandled: true,
				createdAt: 1,
				messageCount: 1,
				outputKind: 'clipboard_markdown',
				repeatedFromAttemptId: null,
				sessionId,
				state: 'succeeded',
				updatedAt: 2,
			},
		]);

		applyProjection(store, projectionSnapshot(6, 11));

		expect(store.getSnapshot().commandOutcomes).toHaveLength(1);
		expect(store.getSnapshot().outputHistory).toHaveLength(1);
	});

	test('preserves demanded rich content across an empty-demand control refresh', () => {
		const store = new WorktreeAnnotationProjectionStore();
		stageCatalog(store, 6);
		applyProjection(store, projectionSnapshot(6, 11), [sessionId]);

		applyProjection(
			store,
			{
				...projectionSnapshot(7, 11),
				expectedMessageCount: 0,
				expectedThreadCount: 0,
				threads: [],
			},
			[],
		);

		expect(store.getSnapshot().threads[0]?.messages[0]?.messageId).toBe(messageId);
		expect(store.getSnapshot().readStatus).toEqual({ kind: 'ready' });
	});

	test('retires removed-session rich content and output history at catalog commit', () => {
		const store = new WorktreeAnnotationProjectionStore();
		stageCatalog(store, 6);
		applyProjection(store, projectionSnapshot(6, 11), [sessionId]);
		store.replaceOutputHistory([outputHistorySummary(sessionId, '21')]);

		for (const message of catalogStagingMessages(7, 'fileView', false)) {
			store.applyCatalogStaging(message);
		}

		expect(store.getSnapshot().threads).toEqual([]);
		expect(store.getSnapshot().outputHistory).toEqual([]);
		expect(store.getSnapshot().readStatus).toEqual({ kind: 'refreshing' });
	});

	test('merges cold output history by demanded session', () => {
		const store = new WorktreeAnnotationProjectionStore();
		store.replaceOutputHistoryForSession(sessionId, [outputHistorySummary(sessionId, '21')]);

		store.replaceOutputHistoryForSession(siblingSessionId, [
			outputHistorySummary(siblingSessionId, '22'),
		]);

		expect(store.getSnapshot().outputHistory.map((summary) => summary.sessionId)).toEqual([
			sessionId,
			siblingSessionId,
		]);
	});
});

describe('worktree annotation surface command rendezvous', () => {
	test('rejects Review commands asynchronously until a publication is installed', async () => {
		// Arrange
		const harness = createSurfaceClientHarness(['worker-review-command'], 'review', false);

		// Act
		const pending = harness.client.execute({ kind: 'session.discover' });

		// Assert
		await expect(pending).rejects.toThrow('no installed publication identity');
		expect(harness.sentCommands).toEqual([]);
		harness.client.dispose();
	});

	test('stamps every Review command with the exact active publication identity', async () => {
		const harness = createSurfaceClientHarness(['worker-review-command'], 'review');

		const pending = harness.client.execute({ kind: 'session.discover' });

		expect(harness.sentCommands).toContainEqual({
			command: 'annotationCommand',
			epoch: 0,
			operation: { kind: 'session.discover' },
			reviewPublicationIdentity: reviewPublicationIdentity,
			surface: 'review',
		});
		harness.client.dispose();
		await expect(pending).rejects.toThrow('Annotation surface client is disposed.');
	});

	test('records main-thread install with the exact projection correlation', () => {
		const harness = createSurfaceClientHarness();

		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: {
				contentSessionIds: [sessionId],
				kind: 'ready',
				stageAttempt: 0,
				snapshot: projectionSnapshot(7, 12),
			},
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});

		const projectionSamples = harness.telemetrySamples.filter((sample) =>
			['projection_store_terminal', 'main_thread_install_terminal'].includes(
				sample.stringAttributes['agentstudio.bridge.phase'] ?? '',
			),
		);
		expect(
			harness.telemetrySamples
				.filter(
					(sample) => sample.stringAttributes['agentstudio.bridge.operation.id'] === 'a'.repeat(64),
				)
				.map((sample) => sample.stringAttributes['agentstudio.bridge.phase']),
		).toEqual([
			'projection_store_started',
			'main_thread_install_started',
			'projection_store_terminal',
			'main_thread_install_terminal',
		]);
		expect(harness.client.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 7 },
			kind: 'current',
		});
		expect(projectionSamples).toHaveLength(2);
		expect(projectionSamples[0]?.stringAttributes).toMatchObject({
			'agentstudio.bridge.operation.id': 'a'.repeat(64),
			'agentstudio.bridge.phase': 'projection_store_terminal',
			'agentstudio.bridge.result': 'success',
		});
		expect(projectionSamples[1]?.stringAttributes).toMatchObject({
			'agentstudio.bridge.operation.id': 'a'.repeat(64),
			'agentstudio.bridge.phase': 'main_thread_install_terminal',
			'agentstudio.bridge.result': 'success',
		});
		harness.client.dispose();
	});

	test('records distinct Main attempts for two ready projections of one operation', () => {
		const harness = createSurfaceClientHarness();
		const correlation = 'a'.repeat(64);
		for (const stageAttempt of [0, 1]) {
			harness.publish({
				direction: 'serverWorkerToMain',
				kind: 'annotationProjectionConvergence',
				operationCorrelationId: correlation,
				state: {
					contentSessionIds: [sessionId],
					kind: 'ready',
					snapshot: projectionSnapshot(7, 12),
					stageAttempt,
				},
				surface: 'fileView',
				transferDescriptors: [],
				wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			});
		}
		expect(
			harness.telemetrySamples
				.filter(
					(sample) => sample.stringAttributes['agentstudio.bridge.operation.id'] === correlation,
				)
				.map((sample) => sample.numericAttributes['agentstudio.bridge.stage.attempt']),
		).toEqual([0, 0, 0, 0, 1, 1, 1, 1]);
		harness.client.dispose();
	});

	test('ignores annotation convergence owned by the other retained viewer surface', () => {
		// Arrange
		const harness = createSurfaceClientHarness([], 'review');
		const releaseSession = harness.client.acquireSession(sessionId);
		harness.sentCommands.length = 0;
		const initialProjection = harness.client.getSnapshot();

		// Act
		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: {
				contentSessionIds: [sessionId],
				kind: 'ready',
				stageAttempt: 0,
				snapshot: projectionSnapshot(7, 12),
			},
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});

		// Assert
		expect(harness.client.getSnapshot()).toBe(initialProjection);
		expect(harness.telemetrySamples).toEqual([]);
		expect(harness.sentCommands).toEqual([]);
		releaseSession();
		harness.client.dispose();
	});

	test('commits catalog staging atomically without finite projection telemetry', () => {
		const harness = createSurfaceClientHarness();
		const messages = catalogStagingMessages(7, 'fileView');
		const [begin, window, commit] = messages;
		if (begin === undefined || window === undefined || commit === undefined) {
			throw new Error('Expected complete certified catalog staging.');
		}
		const initialPresentationRevision = harness.client.getSnapshot().presentationRevision;
		harness.publish(begin);
		harness.publish(window);
		expect(harness.client.getCatalogSnapshot().kind).toBe('unknown');
		expect(harness.client.getSnapshot().presentationRevision).toBe(initialPresentationRevision);
		harness.publish(commit);
		expect(harness.client.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 7, entries: expect.any(Array) },
			kind: 'current',
		});
		expect(harness.client.getSnapshot().presentationRevision).toBe(initialPresentationRevision + 1);
		expect(harness.telemetrySamples).toEqual([]);
		harness.client.dispose();
	});

	test('refreshes cold history for every demanded session after projection convergence', () => {
		const harness = createSurfaceClientHarness();
		const releaseSession = harness.client.acquireSession(sessionId);
		harness.sentCommands.length = 0;

		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: {
				contentSessionIds: [sessionId],
				kind: 'ready',
				stageAttempt: 0,
				snapshot: projectionSnapshot(7, 12),
			},
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});

		expect(harness.sentCommands).toContainEqual({
			command: 'annotationCommand',
			epoch: 0,
			operation: { kind: 'output.history', sessionId },
			surface: 'fileView',
		});
		releaseSession();
		harness.client.dispose();
	});

	test('does not refresh rich output history after a control-only projection', () => {
		const harness = createSurfaceClientHarness();
		const releaseSession = harness.client.acquireSession(sessionId);
		harness.sentCommands.length = 0;

		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: {
				contentSessionIds: [],
				kind: 'ready',
				stageAttempt: 0,
				snapshot: { ...projectionSnapshot(7, 12), threads: [] },
			},
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});

		expect(harness.sentCommands).not.toContainEqual(
			expect.objectContaining({ operation: { kind: 'output.history', sessionId } }),
		);
		expect(harness.client.getSnapshot().readStatus).toEqual({ kind: 'refreshing' });
		releaseSession();
		harness.client.dispose();
	});

	test('sends one typed projection retry for the owning surface', () => {
		const harness = createSurfaceClientHarness();

		harness.client.retryProjection();

		expect(harness.sentCommands).toContainEqual({
			command: 'annotationProjectionRetry',
			epoch: 0,
			surface: 'fileView',
		});
		harness.client.dispose();
	});

	test('reports an unknown Save outcome without claiming failure and reconciles its late receipt', async () => {
		// Arrange
		const harness = createSurfaceClientHarness();
		const save = harness.client.execute({
			editToken: '00000000-0000-7000-8000-000000000014',
			expectedDraftRevision: 1,
			expectedMessageRevision: 2,
			kind: 'draft.save',
			messageId,
			sessionId,
		});
		const canonicalMessage = projectionSnapshot(3, 12).threads[0]?.messages[0];
		if (canonicalMessage === undefined) throw new Error('Expected canonical message fixture.');

		// Act: the worker's deadline passes before native answers.
		harness.publish({
			deliveryStatus: 'unknownAfterDispatch',
			direction: 'serverWorkerToMain',
			kind: 'health',
			message: 'Bridge comm worker has not received the outcome of file.annotations.command.',
			requestId: 'worker-save-1',
			status: 'degraded',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});

		// Assert: the caller learns the outcome is pending, not that the Save failed.
		await expect(save).rejects.toThrow(worktreeAnnotationOutcomeUnknownMessage);
		expect(worktreeAnnotationOutcomeUnknownMessage).not.toMatch(/fail/iu);

		// Act: native commits the Save late.
		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			outcome: {
				receipt: {
					context: {
						diffSide: null,
						endLine: 4,
						path: 'Sources/App.swift',
						resolution: 'open',
						scope: 'located',
						sourceIdentity: 'source-1',
						sourceRole: 'file',
						startLine: 3,
						threadId,
					},
					kind: 'message',
					message: {
						...canonicalMessage,
						messageRevision: 3,
						savedBody: 'Saved after the deadline',
						savedRevision: 2,
						sessionRevision: 4,
						status: 'editable',
					},
				},
				requestId: 'product-late-save',
				sessionId,
				status: { kind: 'committed' },
				surface: 'file',
			},
			productRequestId: 'product-late-save',
			requestId: 'worker-save-1',
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});

		// Assert: the committed state is recorded and shown.
		expect(harness.client.getSnapshot().commandConfirmedThreads).toMatchObject([
			{ messages: [{ savedBody: 'Saved after the deadline' }] },
		]);
		expect(harness.client.getSnapshot().commandOutcomes).toMatchObject([
			{ requestId: 'product-late-save', status: { kind: 'committed' } },
		]);
		harness.client.dispose();
	});

	test('keeps an unknown Save draft through worker session loss', async () => {
		const harness = createSurfaceClientHarness();
		const releaseSession = harness.client.acquireSession(sessionId);
		const initialSnapshot = projectionSnapshot(3, 12);
		const initialThread = initialSnapshot.threads[0];
		const initialMessage = initialThread?.messages[0];
		if (initialThread === undefined || initialMessage === undefined) {
			throw new Error('Expected a draft message fixture.');
		}
		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: {
				contentSessionIds: [sessionId],
				kind: 'ready',
				stageAttempt: 0,
				snapshot: {
					...initialSnapshot,
					threads: [
						{
							...initialThread,
							messages: [
								{
									...initialMessage,
									draft: { activeEditToken: null, body: 'Unsaved after loss', revision: 2 },
								},
							],
						},
					],
				},
			},
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});
		const save = harness.client.execute({
			editToken: '00000000-0000-7000-8000-000000000014',
			expectedDraftRevision: 2,
			expectedMessageRevision: 1,
			kind: 'draft.save',
			messageId,
			sessionId,
		});
		expect(harness.sentCommands.at(-1)?.command).toBe('annotationCommand');
		const saveRequestId = `worker-save-${harness.sentCommands.length.toString()}`;
		harness.publish({
			deliveryStatus: 'unknownAfterDispatch',
			direction: 'serverWorkerToMain',
			kind: 'health',
			requestId: saveRequestId,
			status: 'degraded',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});
		await expect(save).rejects.toThrow(worktreeAnnotationOutcomeUnknownMessage);
		expect(harness.client.getSnapshot().readStatus).toEqual({ kind: 'ready' });
		expect(harness.client.getSnapshot().threads[0]?.messages[0]?.draft?.body).toBe(
			'Unsaved after loss',
		);

		harness.fireWorkerReplacement();
		expect(harness.client.getSnapshot().threads[0]?.messages[0]?.draft?.body).toBe(
			'Unsaved after loss',
		);
		releaseSession();
		harness.client.dispose();
	});

	test('exact Save outcome settles while projection transport is unavailable', async () => {
		const harness = createSurfaceClientHarness();
		const save = harness.client.execute({
			editToken: '00000000-0000-7000-8000-000000000014',
			expectedDraftRevision: 1,
			expectedMessageRevision: 2,
			kind: 'draft.save',
			messageId,
			sessionId,
		});
		const canonicalMessage = projectionSnapshot(3, 12).threads[0]?.messages[0];
		if (canonicalMessage === undefined) throw new Error('Expected canonical message fixture.');

		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: null,
			state: { catalogAuthorityRetired: false, kind: 'unavailable', retryable: true },
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});
		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			outcome: {
				receipt: {
					context: {
						diffSide: null,
						endLine: 4,
						path: 'Sources/App.swift',
						resolution: 'open',
						scope: 'located',
						sourceIdentity: 'source-1',
						sourceRole: 'file',
						startLine: 3,
						threadId,
					},
					kind: 'message',
					message: {
						...canonicalMessage,
						messageRevision: 3,
						savedBody: 'Saved from command',
						savedRevision: 2,
						sessionRevision: 4,
						status: 'editable',
					},
				},
				requestId: 'product-save-1',
				sessionId,
				status: { kind: 'committed' },
				surface: 'file',
			},
			productRequestId: 'product-save-1',
			requestId: 'worker-save-1',
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});
		expect(harness.client.getSnapshot().commandConfirmedThreads).toMatchObject([
			{ messages: [{ savedBody: 'Saved from command' }] },
		]);

		await expect(save).resolves.toMatchObject({
			requestId: 'product-save-1',
			status: { kind: 'committed' },
		});
		expect(harness.client.getSnapshot().readStatus).toEqual({
			kind: 'unavailable',
			retryable: true,
		});
		expect(harness.client.getSnapshot().commandOutcomes).toHaveLength(1);
		harness.client.dispose();
	});

	test('subscription authority retirement discards an incomplete candidate and retains active stale until lower-revision commit', () => {
		const harness = createSurfaceClientHarness();
		for (const message of catalogStagingMessages(20, 'fileView')) harness.publish(message);
		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: {
				contentSessionIds: [sessionId],
				kind: 'ready',
				stageAttempt: 0,
				snapshot: projectionSnapshot(20, 12),
			},
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});
		const candidateBegin = catalogStagingMessages(21, 'fileView')[0];
		if (candidateBegin === undefined) throw new Error('Expected candidate catalog begin.');
		harness.publish(candidateBegin);

		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: { catalogAuthorityRetired: true, kind: 'unavailable', retryable: true },
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});

		expect(harness.client.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 20 },
			kind: 'stale',
		});
		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: {
				contentSessionIds: [sessionId],
				kind: 'ready',
				stageAttempt: 0,
				snapshot: projectionSnapshot(21, 12),
			},
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});
		expect(harness.client.getSnapshot().revision).toBe(20);

		const replacementMessages = catalogStagingMessages(1, 'fileView').map((message) => ({
			...message,
			authority: {
				...message.authority,
				subscriptionId: 'fileView-annotation-subscription-2',
				workerDerivationEpoch: 2,
			},
		}));
		const [replacementBegin, replacementWindow, replacementCommit] = replacementMessages;
		if (
			replacementBegin === undefined ||
			replacementWindow === undefined ||
			replacementCommit === undefined
		) {
			throw new Error('Expected complete replacement catalog transfer.');
		}
		harness.publish(replacementBegin);
		expect(harness.client.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 20 },
			kind: 'stale',
		});
		harness.publish(replacementWindow);
		expect(harness.client.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 20 },
			kind: 'stale',
		});
		harness.publish(replacementCommit);
		expect(harness.client.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 1 },
			kind: 'current',
		});
		harness.client.dispose();
	});

	test('a routine epoch replacement keeps comments visible as refreshing until the replacement catalog commits', () => {
		// Arrange: the drawer shows a current catalog.
		const harness = createSurfaceClientHarness();
		for (const message of catalogStagingMessages(20, 'fileView')) harness.publish(message);
		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: {
				contentSessionIds: [sessionId],
				kind: 'ready',
				stageAttempt: 0,
				snapshot: projectionSnapshot(20, 12),
			},
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});
		const threadCountBeforeReplacement = harness.client.getSnapshot().threads.length;
		expect(threadCountBeforeReplacement).toBeGreaterThan(0);

		// Act: the worker moves annotations to a new surface epoch.
		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: { catalogAuthorityRetired: true, kind: 'refreshing' },
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});

		// Assert: comments stay on screen, marked refreshing, never "Updates unavailable".
		expect(harness.client.getSnapshot().readStatus).toEqual({ kind: 'refreshing' });
		expect(harness.client.getSnapshot().threads).toHaveLength(threadCountBeforeReplacement);
		expect(harness.client.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 20 },
			kind: 'stale',
		});
		for (const message of catalogStagingMessages(1, 'fileView')) {
			harness.publish({
				...message,
				authority: {
					...message.authority,
					subscriptionId: 'fileView-annotation-subscription-2',
					workerDerivationEpoch: 2,
				},
			});
		}
		expect(harness.client.getCatalogSnapshot()).toMatchObject({
			catalog: { catalogRevision: 1 },
			kind: 'current',
		});
		harness.client.dispose();
	});

	test('dispose rejects a pending command and ignores its late outcome', async () => {
		const harness = createSurfaceClientHarness();
		const pending = harness.client.execute({ kind: 'session.discover' });

		harness.client.dispose();
		harness.publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			outcome: {
				requestId: 'late-product-request',
				sessionId: null,
				status: { kind: 'committed' },
				surface: 'file',
			},
			productRequestId: 'late-product-request',
			requestId: 'worker-save-1',
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		});

		await expect(pending).rejects.toThrow('Annotation surface client is disposed.');
		expect(harness.client.getSnapshot().commandOutcomes).toEqual([]);
	});

	test('bounds unmatched accept, outcome, and degraded-failure correlations', async () => {
		const harness = createSurfaceClientHarness([
			'worker-accepted-0',
			'worker-accepted-1',
			'worker-failure-0',
			'worker-failure-1',
		]);
		for (let index = 0; index < 129; index += 1) {
			harness.publish({
				direction: 'serverWorkerToMain',
				kind: 'annotationCommandAccepted',
				outcome: {
					requestId: `product-orphan-${index.toString()}`,
					sessionId: null,
					status: { kind: 'committed' },
					surface: 'file',
				},
				productRequestId: `product-orphan-${index.toString()}`,
				requestId: `worker-accepted-${index.toString()}`,
				surface: 'fileView',
				transferDescriptors: [],
				wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			});
			harness.publish({
				direction: 'serverWorkerToMain',
				kind: 'health',
				message: `orphan failure ${index.toString()}`,
				requestId: `worker-failure-${index.toString()}`,
				status: 'degraded',
				transferDescriptors: [],
				wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			});
		}

		const evictedAccepted = harness.client.execute({ kind: 'session.discover' });
		const retainedAccepted = harness.client.execute({ kind: 'session.discover' });
		const evictedFailure = harness.client.execute({ kind: 'session.discover' });
		const retainedFailure = harness.client.execute({ kind: 'session.discover' });

		await expect(retainedAccepted).resolves.toMatchObject({ requestId: 'product-orphan-1' });
		await expect(retainedFailure).rejects.toThrow('orphan failure 1');
		harness.client.dispose();
		await expect(evictedAccepted).rejects.toThrow('Annotation surface client is disposed.');
		await expect(evictedFailure).rejects.toThrow('Annotation surface client is disposed.');
	});
});

function stageCatalog(store: WorktreeAnnotationProjectionStore, catalogRevision: number): void {
	for (const message of catalogStagingMessages(catalogRevision, 'fileView')) {
		store.applyCatalogStaging(message);
	}
}

function outputHistorySummary(
	outputSessionId: string,
	attemptSuffix: string,
): WorktreeAnnotationOutputHistorySummary {
	return {
		attemptId: `00000000-0000-7000-8000-0000000000${attemptSuffix}`,
		canMarkNotHandled: true,
		createdAt: 1,
		messageCount: 1,
		outputKind: 'clipboard_markdown',
		repeatedFromAttemptId: null,
		sessionId: outputSessionId,
		state: 'succeeded',
		updatedAt: 2,
	};
}

function applyProjection(
	store: WorktreeAnnotationProjectionStore,
	snapshot: BridgeWorkerAnnotationProjectionSnapshot,
	contentSessionIds?: readonly string[],
): void {
	store.apply({
		contentSessionIds,
		expectedContentSessionIds: contentSessionIds ?? [],
		operationCorrelationId: 'a'.repeat(64),
		reviewAnnotationApplication: null,
		snapshot,
	});
}

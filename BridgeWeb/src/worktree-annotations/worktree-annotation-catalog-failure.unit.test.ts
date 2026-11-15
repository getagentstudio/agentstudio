import { uuidv7 } from 'uuidv7';
import { describe, expect, test } from 'vitest';

import { bridgeCommWorkerAnnotationCatalogStagingEvents } from '../core/comm-worker/bridge-comm-worker-annotation-runtime-events.js';
import { BRIDGE_METADATA_CATALOG_MAXIMUM_ENTRY_COUNT } from '../core/comm-worker/bridge-metadata-catalog-transfer-contracts.js';
import { installBridgeProductCommentBatch } from '../core/comm-worker/bridge-product-comment-batch-installer.js';
import type { BridgeProductWorktreeAnnotationCatalogEntry } from '../core/comm-worker/bridge-product-worktree-annotation-contracts.js';
import type { BridgeWorkerAnnotationCatalogStagingEvent } from '../core/comm-worker/bridge-worker-annotation-contracts.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import { makeCommentCatalogInstallation } from '../core/comm-worker/test-fixtures/bridge-comm-worker-annotation-projection.test-support.js';
import { WorktreeAnnotationCatalogStaging } from './worktree-annotation-catalog-staging.js';
import {
	catalogStagingMessages,
	createSurfaceClientHarness,
	projectionSnapshot,
	reviewPublicationIdentity,
	sessionId,
	threadId,
} from './worktree-annotation-surface-client.test-support.js';

describe('large Review annotation catalog completion', () => {
	test('installs a multi-window catalog without a panel, composer, or session demand', () => {
		const harness = createSurfaceClientHarness([], 'review');
		const staging = largeReviewCatalogStaging();
		let publicationCount = 0;
		const unsubscribe = harness.client.subscribe((): void => {
			publicationCount += 1;
		});
		try {
			for (const message of staging.slice(0, -1)) harness.publish(message);
			expect(harness.client.getCatalogSnapshot()).toEqual({ kind: 'unknown' });
			expect(publicationCount).toBe(0);
			const commit = staging.at(-1);
			if (commit === undefined) throw new Error('Large catalog commit missing.');
			harness.publish(commit);

			const installed = harness.client.getCatalogSnapshot();
			expect(installed.kind).toBe('current');
			if (installed.kind !== 'current') throw new Error('Large Review catalog was not installed.');
			expect(installed.catalog.catalogRevision).toBe(7);
			expect(installed.catalog.messagesById.size).toBe(2_001);
			expect(installed.catalog.sessionsById.size).toBe(1);
			expect(installed.catalog.threadsById.size).toBe(1);
			expect(publicationCount).toBe(1);
			expect(harness.sentCommands).toEqual([]);
		} finally {
			unsubscribe();
			harness.client.dispose();
		}
	});

	test('reports an unavailable read when the current large catalog commit is rejected', () => {
		const harness = createSurfaceClientHarness([], 'review');
		const staging = largeReviewCatalogStaging();
		try {
			for (const message of staging.slice(0, -1)) harness.publish(message);
			const commit = staging.at(-1);
			if (commit?.transfer.kind !== 'catalog.commit')
				throw new Error('Large catalog commit missing.');

			// The producer has finished with an invalid count. No later event can
			// complete this candidate; the consumer must publish its failure now.
			harness.publish({
				...commit,
				transfer: { ...commit.transfer, entryCount: commit.transfer.entryCount + 1 },
			});

			expect(harness.client.getCatalogSnapshot()).toEqual({ kind: 'unknown' });
			expect(harness.client.getSnapshot().readStatus).toEqual({
				kind: 'unavailable',
				retryable: false,
			});
		} finally {
			harness.client.dispose();
		}
	});
});

describe('Review annotation catalog rejection', () => {
	test('retains the stale catalog when a replacement authority transfer fails', () => {
		const harness = createSurfaceClientHarness([], 'review');
		try {
			for (const message of catalogStagingMessages(7, 'review')) harness.publish(message);
			const previousCatalog = harness.client.getCatalogSnapshot();
			if (previousCatalog.kind !== 'current') throw new Error('Initial catalog not installed.');
			for (const message of catalogStagingMessages(1, 'review')) {
				if (message.transfer.kind === 'catalog.commit') continue;
				harness.publish({
					...message,
					authority: { ...message.authority, workerDerivationEpoch: 2 },
					transfer:
						message.transfer.kind === 'catalog.window'
							? { ...message.transfer, windowOrdinal: 1 }
							: message.transfer,
				});
			}
			const retained = harness.client.getCatalogSnapshot();
			expect(retained.kind).toBe('stale');
			if (retained.kind !== 'stale') throw new Error('Previous catalog not retained as stale.');
			expect(retained.catalog).toBe(previousCatalog.catalog);
			expect(harness.client.getSnapshot().readStatus).toEqual({
				kind: 'unavailable',
				retryable: false,
			});
		} finally {
			harness.client.dispose();
		}
	});

	test('reports unavailable when bounded windows exceed the candidate byte capacity', () => {
		const harness = createSurfaceClientHarness([], 'review');
		try {
			const messages = catalogStagingMessages(7, 'review');
			const begin = messages[0];
			const window = messages[1];
			if (begin?.transfer.kind !== 'catalog.begin' || window?.transfer.kind !== 'catalog.window')
				throw new Error('Catalog begin/window missing.');
			harness.publish({ ...begin, transfer: { ...begin.transfer, expectedEntryCount: 100_000 } });
			for (let startIndex = 0; startIndex < 100_000; startIndex += 500) {
				harness.publish({
					...window,
					transfer: {
						...window.transfer,
						entries: Array.from({ length: 500 }, () => ({
							kind: 'session' as const,
							semanticRevision: 7,
							sessionId: uuidv7(),
						})),
						windowOrdinal: startIndex / 500,
					},
				});
			}
			expect(harness.client.getCatalogSnapshot()).toEqual({ kind: 'unknown' });
			expect(harness.client.getSnapshot().readStatus).toEqual({
				kind: 'unavailable',
				retryable: false,
			});
		} finally {
			harness.client.dispose();
		}
	});

	test('retains the committed catalog when a successor window is out of order', () => {
		const harness = createSurfaceClientHarness([], 'review');
		try {
			for (const message of catalogStagingMessages(7, 'review')) harness.publish(message);
			const previousCatalog = harness.client.getCatalogSnapshot();
			if (previousCatalog.kind !== 'current') throw new Error('Initial catalog not installed.');
			expect(previousCatalog.catalog.catalogRevision).toBe(7);
			expect(previousCatalog.catalog.entries).toHaveLength(3);
			const successor = catalogStagingMessages(8, 'review');
			for (const message of successor) {
				if (message.transfer.kind === 'catalog.commit') continue;
				harness.publish(
					message.transfer.kind === 'catalog.window'
						? { ...message, transfer: { ...message.transfer, windowOrdinal: 1 } }
						: message,
				);
			}

			expect(harness.client.getCatalogSnapshot()).toBe(previousCatalog);
			expect(harness.client.getSnapshot().readStatus).toEqual({
				kind: 'unavailable',
				retryable: false,
			});
		} finally {
			harness.client.dispose();
		}
	});

	test('rejects unexpected authority in staging without discarding the current candidate', () => {
		// The store adopts every incoming authority before accept(), so this
		// staging-only refusal cannot be reached through the surface client.
		const staging = new WorktreeAnnotationCatalogStaging();
		const messages = catalogStagingMessages(7, 'review');
		const begin = messages[0];
		if (begin === undefined) throw new Error('Catalog begin missing.');
		staging.replaceExpectedAuthority(begin.authority);
		expect(staging.accept(begin)).toEqual({ status: 'accepted' });
		expect(
			staging.accept({ ...begin, authority: { ...begin.authority, subscriptionId: 'unexpected' } }),
		).toEqual({ reason: 'unexpected_authority', status: 'rejected' });
		for (const message of messages.slice(1, -1))
			expect(staging.accept(message)).toEqual({ status: 'accepted' });
		const commit = messages.at(-1);
		if (commit === undefined) throw new Error('Catalog commit missing.');
		expect(staging.accept(commit)).toMatchObject({
			status: 'completed',
			catalog: { catalogRevision: 7 },
		});
	});

	test.each([
		'duplicate_session_id',
		'duplicate_thread_id',
		'duplicate_thread_ordinal',
		'duplicate_message_id',
		'duplicate_message_ordinal',
		'unknown_session',
		'unknown_thread',
	] as const)('reports unavailable when a window has %s', (reason) => {
		const harness = createSurfaceClientHarness([], 'review');
		try {
			const messages = catalogStagingMessages(7, 'review');
			const begin = messages[0];
			const window = messages[1];
			if (begin?.transfer.kind !== 'catalog.begin' || window?.transfer.kind !== 'catalog.window')
				throw new Error('Catalog begin/window missing.');
			const entries = [...window.transfer.entries];
			const session = entries.find((entry) => entry.kind === 'session');
			const thread = entries.find((entry) => entry.kind === 'thread');
			const message = entries.find((entry) => entry.kind === 'message');
			if (session === undefined || thread === undefined || message === undefined)
				throw new Error('Catalog entries missing.');
			switch (reason) {
				case 'duplicate_session_id':
					entries.push(session);
					break;
				case 'duplicate_thread_id':
					entries.push(thread);
					break;
				case 'duplicate_thread_ordinal':
					entries.push({ ...thread, threadId: uuidv7() });
					break;
				case 'duplicate_message_id':
					entries.push(message);
					break;
				case 'duplicate_message_ordinal':
					entries.push({ ...message, messageId: uuidv7() });
					break;
				case 'unknown_session':
					entries.splice(0, 1);
					break;
				case 'unknown_thread':
					entries.splice(1, 1);
					break;
			}
			harness.publish({
				...begin,
				transfer: { ...begin.transfer, expectedEntryCount: entries.length },
			});
			harness.publish({ ...window, transfer: { ...window.transfer, entries } });

			expect(harness.client.getCatalogSnapshot()).toEqual({ kind: 'unknown' });
			expect(harness.client.getSnapshot().readStatus).toEqual({
				kind: 'unavailable',
				retryable: false,
			});
		} finally {
			harness.client.dispose();
		}
	});

	test.each(['entry_count_exceeded', 'malformed_transfer'] as const)(
		'reports unavailable when the current window is rejected for %s',
		(reason) => {
			const harness = createSurfaceClientHarness([], 'review');
			try {
				const messages = catalogStagingMessages(7, 'review');
				const begin = messages[0];
				const window = messages[1];
				if (begin?.transfer.kind !== 'catalog.begin' || window?.transfer.kind !== 'catalog.window')
					throw new Error('Catalog begin/window missing.');
				harness.publish({
					...begin,
					transfer: {
						...begin.transfer,
						expectedEntryCount: reason === 'entry_count_exceeded' ? 1 : 3,
					},
				});
				harness.publish(
					reason === 'malformed_transfer'
						? {
								...window,
								transfer: {
									...window.transfer,
									entries: [
										{ kind: 'session', semanticRevision: 7, sessionId: 'x'.repeat(128 * 1024) },
									],
								},
							}
						: window,
				);
				expect(harness.client.getCatalogSnapshot()).toEqual({ kind: 'unknown' });
				expect(harness.client.getSnapshot().readStatus).toEqual({
					kind: 'unavailable',
					retryable: false,
				});
			} finally {
				harness.client.dispose();
			}
		},
	);

	test.each(['noncurrent_transfer', 'revision_not_newer'] as const)(
		'publishes nothing for %s and preserves the pending valid transfer',
		(reason) => {
			const harness = createSurfaceClientHarness([], 'review');
			let publicationCount = 0;
			const unsubscribe = harness.client.subscribe((): void => {
				publicationCount += 1;
			});
			try {
				for (const message of catalogStagingMessages(7, 'review')) harness.publish(message);
				const successor = catalogStagingMessages(8, 'review');
				const begin = successor[0];
				if (begin?.transfer.kind !== 'catalog.begin') throw new Error('Catalog begin missing.');
				harness.publish(begin);
				const previousCatalog = harness.client.getCatalogSnapshot();
				const previousSnapshot = harness.client.getSnapshot();
				publicationCount = 0;

				if (reason === 'revision_not_newer') {
					harness.publish(begin);
				} else {
					for (const message of catalogStagingMessages(7, 'review').slice(1))
						harness.publish(message);
				}

				expect(publicationCount).toBe(0);
				expect(harness.client.getSnapshot()).toBe(previousSnapshot);
				expect(harness.client.getCatalogSnapshot()).toBe(previousCatalog);
				for (const message of successor.slice(1)) harness.publish(message);
				expect(harness.client.getCatalogSnapshot()).toMatchObject({
					kind: 'current',
					catalog: { catalogRevision: 8 },
				});
				expect(publicationCount).toBe(1);
			} finally {
				unsubscribe();
				harness.client.dispose();
			}
		},
	);

	test('recovers from an unavailable read when a later valid transfer completes', () => {
		const harness = createSurfaceClientHarness([], 'review');
		try {
			for (const message of catalogStagingMessages(7, 'review')) {
				harness.publish(
					message.transfer.kind === 'catalog.commit'
						? { ...message, transfer: { ...message.transfer, entryCount: 4 } }
						: message,
				);
			}
			expect(harness.client.getSnapshot().readStatus).toEqual({
				kind: 'unavailable',
				retryable: false,
			});
			for (const message of catalogStagingMessages(8, 'review')) harness.publish(message);
			expect(harness.client.getCatalogSnapshot()).toMatchObject({
				kind: 'current',
				catalog: { catalogRevision: 8 },
			});
			expect(harness.client.getSnapshot().readStatus).toEqual({ kind: 'refreshing' });
		} finally {
			harness.client.dispose();
		}
	});

	test('reports unavailable when a begin exceeds the catalog entry capacity', () => {
		const harness = createSurfaceClientHarness([], 'review');
		try {
			const begin = catalogStagingMessages(7, 'review')[0];
			if (begin?.transfer.kind !== 'catalog.begin') throw new Error('Catalog begin missing.');
			harness.publish({
				...begin,
				transfer: {
					...begin.transfer,
					expectedEntryCount: BRIDGE_METADATA_CATALOG_MAXIMUM_ENTRY_COUNT + 1,
				},
			});

			expect(harness.client.getCatalogSnapshot()).toEqual({ kind: 'unknown' });
			expect(harness.client.getSnapshot().readStatus).toEqual({
				kind: 'unavailable',
				retryable: false,
			});
		} finally {
			harness.client.dispose();
		}
	});
});

describe('catalog failure survives query-only convergence', () => {
	test.each(['unknown', 'stale', 'current'] as const)(
		'keeps the %s catalog unavailable until a valid catalog commits',
		(catalogKind) => {
			const harness = createSurfaceClientHarness([], 'review');
			const epoch = catalogKind === 'stale' ? 2 : 1;
			try {
				if (catalogKind !== 'unknown') {
					for (const message of catalogStagingMessages(7, 'review')) harness.publish(message);
				}
				publishRejectedCatalog(harness.publish, epoch);
				expect(harness.client.getCatalogSnapshot().kind).toBe(catalogKind);
				expect(harness.client.getSnapshot().readStatus.kind).toBe('unavailable');

				harness.publish(queryConvergence({ catalogAuthorityRetired: false, kind: 'refreshing' }));
				expect(harness.client.getSnapshot().readStatus).toEqual({
					kind: 'unavailable',
					retryable: false,
				});
				harness.publish(queryReady(8));
				expect(harness.client.getSnapshot().readStatus).toEqual({
					kind: 'unavailable',
					retryable: false,
				});
				expect(harness.client.getCatalogSnapshot().kind).toBe(catalogKind);
				// A query failure also cannot offer a retry that cannot replay the catalog.
				harness.publish(
					queryConvergence({
						catalogAuthorityRetired: false,
						kind: 'unavailable',
						retryable: true,
					}),
				);
				expect(harness.client.getSnapshot().readStatus).toEqual({
					kind: 'unavailable',
					retryable: false,
				});

				for (const message of catalogStagingMessages(9, 'review')) {
					harness.publish({
						...message,
						authority: { ...message.authority, workerDerivationEpoch: epoch },
					});
				}
				expect(harness.client.getCatalogSnapshot()).toMatchObject({
					kind: 'current',
					catalog: { catalogRevision: 9 },
				});
				expect(harness.client.getSnapshot().readStatus).toEqual({ kind: 'refreshing' });
				harness.publish(queryConvergence({ catalogAuthorityRetired: false, kind: 'refreshing' }));
				harness.publish(queryReady(9));
				expect(harness.client.getSnapshot().readStatus).toEqual({ kind: 'ready' });
				expect(harness.client.getSnapshot().threads).toHaveLength(1);
			} finally {
				harness.client.dispose();
			}
		},
	);

	test('query ready cannot clear a catalog failure against a retained current catalog', () => {
		const harness = createSurfaceClientHarness([], 'review');
		try {
			for (const message of catalogStagingMessages(7, 'review')) harness.publish(message);
			publishRejectedCatalog(harness.publish, 1);
			harness.publish(queryReady(8));
			expect(harness.client.getSnapshot().readStatus).toEqual({
				kind: 'unavailable',
				retryable: false,
			});
		} finally {
			harness.client.dispose();
		}
	});

	test('session demand cannot clear a first-install catalog failure', () => {
		const harness = createSurfaceClientHarness([], 'review');
		try {
			publishRejectedCatalog(harness.publish, 1);
			const release = harness.client.acquireSession(sessionId);
			try {
				expect(harness.client.getSnapshot().readStatus).toEqual({
					kind: 'unavailable',
					retryable: false,
				});
			} finally {
				release();
			}
		} finally {
			harness.client.dispose();
		}
	});

	test.each(['unknown', 'stale'] as const)(
		'authority retirement starts catalog recovery after a %s catalog failure',
		(catalogKind) => {
			const harness = createSurfaceClientHarness([], 'review');
			try {
				if (catalogKind === 'stale') {
					for (const message of catalogStagingMessages(7, 'review')) harness.publish(message);
				}
				publishRejectedCatalog(harness.publish, catalogKind === 'stale' ? 2 : 1);
				harness.publish(queryConvergence({ catalogAuthorityRetired: true, kind: 'refreshing' }));
				expect(harness.client.getSnapshot().readStatus).toEqual({ kind: 'refreshing' });
				expect(harness.client.getCatalogSnapshot().kind).toBe(catalogKind);
			} finally {
				harness.client.dispose();
			}
		},
	);

	test('an accepted begin from a replacement authority starts real catalog recovery', () => {
		const harness = createSurfaceClientHarness([], 'review');
		try {
			publishRejectedCatalog(harness.publish, 1);
			const begin = catalogStagingMessages(1, 'review')[0];
			if (begin === undefined) throw new Error('Catalog begin missing.');
			harness.publish({ ...begin, authority: { ...begin.authority, workerDerivationEpoch: 2 } });
			expect(harness.client.getSnapshot().readStatus).toEqual({ kind: 'refreshing' });
		} finally {
			harness.client.dispose();
		}
	});
});

function publishRejectedCatalog(
	publish: (message: BridgeWorkerServerToMainMessage) => void,
	workerDerivationEpoch: number,
): void {
	for (const message of catalogStagingMessages(8, 'review')) {
		publish({
			...message,
			authority: { ...message.authority, workerDerivationEpoch },
			transfer:
				message.transfer.kind === 'catalog.commit'
					? { ...message.transfer, entryCount: 4 }
					: message.transfer,
		});
	}
}

type QueryConvergenceMessage = Extract<
	BridgeWorkerServerToMainMessage,
	{ readonly kind: 'annotationProjectionConvergence' }
>;

function queryConvergence(state: QueryConvergenceMessage['state']): QueryConvergenceMessage {
	return {
		direction: 'serverWorkerToMain',
		kind: 'annotationProjectionConvergence',
		operationCorrelationId: 'a'.repeat(64),
		state,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
}

function queryReady(revision: number): QueryConvergenceMessage {
	return queryConvergence({
		contentSessionIds: [sessionId],
		kind: 'ready',
		reviewPublicationIdentity,
		snapshot: projectionSnapshot(revision, 12),
		stageAttempt: 0,
	});
}

function largeReviewCatalogStaging(): readonly BridgeWorkerAnnotationCatalogStagingEvent[] {
	const entries: BridgeProductWorktreeAnnotationCatalogEntry[] = [
		{ kind: 'session', semanticRevision: 7, sessionId },
		{ createdOrdinal: 0, kind: 'thread', scope: 'located', sessionId, threadId },
		...Array.from({ length: 2_001 }, (_, ordinal) => ({
			kind: 'message' as const,
			messageId: uuidv7(),
			ordinal,
			threadId,
		})),
	];
	const authority = {
		subscriptionId: 'large-review-annotations',
		workerDerivationEpoch: 1,
		worktreeId: 'worktree-1',
	};
	const installation = makeCommentCatalogInstallation({
		entries,
		revision: 7,
		snapshotCause: 'open',
		subscriptionId: authority.subscriptionId,
		subscriptionKind: 'review.annotations',
		worktreeId: authority.worktreeId,
	});
	const staging = bridgeCommWorkerAnnotationCatalogStagingEvents({
		catalog: installBridgeProductCommentBatch(installation, authority),
		surface: 'review',
	});
	expect(
		staging.filter((message) => message.transfer.kind === 'catalog.window').length,
	).toBeGreaterThan(1);
	return staging;
}

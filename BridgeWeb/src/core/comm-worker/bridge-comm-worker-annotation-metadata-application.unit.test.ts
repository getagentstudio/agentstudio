import { describe, expect, test } from 'vitest';

import { installBridgeProductCommentBatch } from './bridge-product-comment-batch-installer.js';
import type { BridgeProductWorktreeAnnotationCatalogEntry } from './bridge-product-worktree-annotation-contracts.js';
import {
	createHarness,
	makeCommentCatalogInstallation,
	makeProjectionPages,
	sessionId,
	uuidv7,
	worktreeId,
} from './test-fixtures/bridge-comm-worker-annotation-projection.test-support.js';

const firstSubscriptionId = 'file-annotation-notifications';
const replacementSubscriptionId = 'file-annotation-replacement';
const replacementWorktreeId = 'worktree-2';
const threadId = uuidv7(2);

function sessionScopedEntries(
	semanticRevision: number,
): readonly BridgeProductWorktreeAnnotationCatalogEntry[] {
	return [
		{ kind: 'session' as const, semanticRevision, sessionId },
		{ createdOrdinal: 0, kind: 'thread' as const, scope: 'session' as const, sessionId, threadId },
	];
}

describe('Bridge communication worker certified Comment catalog authority', () => {
	test('commits a session-scoped thread and admits a current demanded body read', async () => {
		const catalog = installBridgeProductCommentBatch(
			makeCommentCatalogInstallation({
				snapshotCause: 'open',
				entries: sessionScopedEntries(3),
				revision: 3,
				subscriptionId: firstSubscriptionId,
				subscriptionKind: 'file.annotations',
				worktreeId,
			}),
			{ subscriptionId: firstSubscriptionId, workerDerivationEpoch: 1, worktreeId },
		);
		expect(catalog.threadsById.get(threadId)).toMatchObject({
			scope: 'session',
			sessionId,
			threadId,
		});

		const harness = await createHarness({ pages: await makeProjectionPages(1, 3) });
		try {
			harness.controller.ensureSubscription();
			harness.controller.setDemand({ active: true, sessionIds: [sessionId], sourceGeneration: 3 });
			harness.controller.acceptInstalledCatalog(catalog);
			await harness.controller.waitForIdle();

			expect(harness.failures).toEqual([]);
			expect(harness.querySessionIds).toEqual([[], [sessionId]]);
			expect(harness.publications.at(-1)?.snapshot.sessions).toEqual(
				expect.arrayContaining([expect.objectContaining({ sessionId, semanticRevision: 3 })]),
			);
		} finally {
			await harness.controller.dispose();
		}
	});

	test('rejects a same-lifecycle worktree substitution and admits a new certified lifecycle', () => {
		const firstInstallation = makeCommentCatalogInstallation({
			snapshotCause: 'open',
			entries: sessionScopedEntries(1),
			revision: 1,
			subscriptionId: firstSubscriptionId,
			subscriptionKind: 'file.annotations',
			worktreeId,
		});
		const firstCatalog = installBridgeProductCommentBatch(firstInstallation, {
			subscriptionId: firstSubscriptionId,
			workerDerivationEpoch: 1,
			worktreeId,
		});
		expect(firstCatalog.authority.worktreeId).toBe(worktreeId);

		const replacementInstallation = makeCommentCatalogInstallation({
			snapshotCause: 'open',
			entries: sessionScopedEntries(1),
			revision: 1,
			subscriptionId: replacementSubscriptionId,
			subscriptionKind: 'file.annotations',
			worktreeId: replacementWorktreeId,
		});
		expect(() =>
			installBridgeProductCommentBatch(replacementInstallation, {
				subscriptionId: firstSubscriptionId,
				workerDerivationEpoch: 1,
				worktreeId,
			}),
		).toThrow(/subscription/u);
		const sameLifecycleWrongWorktree = makeCommentCatalogInstallation({
			snapshotCause: 'open',
			entries: sessionScopedEntries(1),
			revision: 2,
			subscriptionId: firstSubscriptionId,
			subscriptionKind: 'file.annotations',
			worktreeId: replacementWorktreeId,
		});
		expect(() =>
			installBridgeProductCommentBatch(sameLifecycleWrongWorktree, {
				subscriptionId: firstSubscriptionId,
				workerDerivationEpoch: 1,
				worktreeId,
			}),
		).toThrow(/worktree/u);

		const replacementCatalog = installBridgeProductCommentBatch(replacementInstallation, {
			subscriptionId: replacementSubscriptionId,
			workerDerivationEpoch: 2,
			worktreeId: replacementWorktreeId,
		});
		expect(replacementCatalog.authority).toEqual({
			subscriptionId: replacementSubscriptionId,
			workerDerivationEpoch: 2,
			worktreeId: replacementWorktreeId,
		});
	});
});

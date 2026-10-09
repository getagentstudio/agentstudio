import { createHash } from 'node:crypto';

import { describe, expect, test } from 'vitest';

import { deriveWorktreeAnnotationShareProjection } from '../../worktree-annotations/worktree-annotation-share-projection.js';
import { bridgeWorkerAnnotationProjectionHeaderSchema } from './bridge-comm-worker-annotation-projection-decoder.js';
import { installBridgeProductCommentBatch } from './bridge-product-comment-batch-installer.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import { createTestViewScopeOwner } from './bridge-product-view-scope-owner.test-support.js';
import {
	createHarness,
	deferred,
	makeCommentCatalogInstallation,
	makeProjectionPages,
	sessionId,
	uuidv7,
	worktreeId,
	type MutableProjectionPage,
} from './test-fixtures/bridge-comm-worker-annotation-projection.test-support.js';

describe('Bridge annotation projection session demand', () => {
	test('installed Comment catalog demand-only scope update finishes content without a catalog resnapshot', async () => {
		const deadlines: Array<{ active: boolean; fire: () => void }> = [];
		const clock: BridgeProductDeadlineClock = {
			schedule: (_delayMilliseconds, onDeadline): (() => void) => {
				const deadline = {
					active: true,
					fire: (): void => {
						if (!deadline.active) return;
						deadline.active = false;
						onDeadline();
					},
				};
				deadlines.push(deadline);
				return (): void => {
					deadline.active = false;
				};
			},
		};
		const resnapshotRequests: string[] = [];
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => ({
					...props,
					kind: 'subscription.scopeAccepted' as const,
					paneSessionId: 'pane-session-1',
					requestId: 'comment-scope-accepted',
					requestSequence: props.scopeRevision,
					wireVersion: 2 as const,
					workerInstanceId: 'worker-instance-1',
				}),
				resnapshotView: async (props) => {
					resnapshotRequests.push(props.subscriptionId);
					return {
						...props,
						kind: 'subscription.resnapshotAccepted' as const,
						paneSessionId: 'pane-session-1',
						requestId: 'comment-resnapshot-accepted',
						requestSequence: 3,
						wireVersion: 2 as const,
						workerInstanceId: 'worker-instance-1',
					};
				},
			},
			createIdentifier: (): string => 'comment-view-identity',
			deadlineClock: clock,
			maximumConsecutiveResnapshots: 2,
		});
		const harness = await createHarness({
			pages: await makeProjectionPages(1, 8),
			scopeUpdateOverride: async (scope): Promise<void> => {
				await owner.setScope({
					scope: { kind: 'comment', sessionIds: scope.sessionIds, worktreeId: scope.worktreeId },
					subscriptionId: scope.subscriptionId,
				});
			},
		});
		const subscriptionId = harness.notifications.subscription.subscriptionId;
		owner.register({
			scope: { kind: 'comment', sessionIds: [], worktreeId },
			subscriptionId,
			subscriptionKind: 'file.annotations',
		});
		try {
			await owner.setScope({
				scope: { kind: 'comment', sessionIds: [], worktreeId },
				subscriptionId,
			});
			owner.recordCertifiedInstall({
				handle: 'comment-view-identity',
				incarnation: 'comment-view-identity',
				scopeRevision: 1,
				subscriptionId,
			});
			harness.controller.setDemand({ active: true, sessionIds: [], sourceGeneration: 8 });
			harness.controller.ensureSubscription();
			harness.notifications.installCatalog(8);
			await harness.controller.waitForIdle();
			harness.controller.setDemand({ active: true, sessionIds: [sessionId], sourceGeneration: 8 });
			await harness.controller.waitForIdle();
			expect(harness.publications.at(-1)?.contentSessionIds).toEqual([sessionId]);
			expect(harness.scopeUpdates.at(-1)?.sessionIds).toEqual([sessionId]);
			for (const deadline of deadlines.filter((candidate) => candidate.active)) deadline.fire();
			expect(resnapshotRequests).toEqual([]);
		} finally {
			await harness.controller.dispose();
			owner.retire(subscriptionId);
		}
	});

	test.each([false, true])(
		'held A then B preserves only current demand (A released: %s)',
		async (releaseSessionA: boolean): Promise<void> => {
			const otherSessionId = uuidv7(42);
			const pages = await makeOverlappingDemandPages(otherSessionId);
			const heldQuery = deferred<unknown>();
			const heldQueryStarted = deferred<AbortSignal>();
			const replacementQueryStarted = deferred<void>();
			let heldQueryClaimed = false;
			const harness = await createHarness({
				pages: [...pages.values()],
				queryOverride: (request, signal): Promise<unknown> => {
					if (!heldQueryClaimed && request.sessionIds.includes(sessionId)) {
						heldQueryClaimed = true;
						heldQueryStarted.resolve(signal);
						// Deliberately return late through cancellation to exercise the publication fence.
						return heldQuery.promise;
					}
					if (request.sessionIds.includes(otherSessionId)) replacementQueryStarted.resolve();
					const page = pages.get(JSON.stringify(request.sessionIds));
					if (page === undefined) throw new Error('Unexpected annotation session demand.');
					return Promise.resolve({ descriptor: page.descriptor, kind: 'content' });
				},
			});
			try {
				harness.controller.setDemand({ active: true, sessionIds: [], sourceGeneration: 8 });
				harness.controller.ensureSubscription();
				const subscriptionId = harness.notifications.subscription.subscriptionId;
				const catalog = installBridgeProductCommentBatch(
					makeCommentCatalogInstallation({
						snapshotCause: 'open',
						entries: [
							{ kind: 'session', semanticRevision: 8, sessionId },
							{ kind: 'session', semanticRevision: 8, sessionId: otherSessionId },
						],
						revision: 8,
						subscriptionId,
						subscriptionKind: 'file.annotations',
						worktreeId,
					}),
					{ subscriptionId, workerDerivationEpoch: 1, worktreeId },
				);
				expect(harness.controller.acceptInstalledCatalog(catalog)).toBe(true);
				await harness.controller.waitForIdle();
				harness.controller.setDemand({
					active: true,
					sessionIds: [sessionId],
					sourceGeneration: 8,
				});
				const heldSignal = await heldQueryStarted.promise;
				if (releaseSessionA) {
					harness.controller.setDemand({ active: true, sessionIds: [], sourceGeneration: 8 });
				}
				const currentSessionIds = releaseSessionA ? [otherSessionId] : [sessionId, otherSessionId];
				harness.controller.setDemand({
					active: true,
					sessionIds: currentSessionIds,
					sourceGeneration: 8,
				});
				await replacementQueryStarted.promise;
				heldQuery.resolve({
					descriptor: pages.get(JSON.stringify([sessionId]))?.descriptor,
					kind: 'content',
				});
				await harness.controller.waitForIdle();

				expect(heldSignal.aborted).toBe(true);
				expect(harness.failures).toEqual([]);
				expect(harness.subscriptionCount()).toBe(1);
				expect(harness.querySessionIds).toEqual([[], [sessionId], currentSessionIds]);
				const publication = harness.publications.at(-1);
				expect(publication?.contentSessionIds).toEqual(currentSessionIds);
				expect(publication?.snapshot.sessions.map((session) => session.sessionId)).toEqual(
					currentSessionIds,
				);
				if (publication === undefined) throw new Error('Expected current annotation content.');
				expect(
					publication.snapshot.threads.flatMap((thread) =>
						thread.messages.map((message) => ({
							savedBody: message.savedBody,
							sessionId: message.sessionId,
						})),
					),
				).toEqual(
					currentSessionIds.map((currentSessionId) => ({
						savedBody: 'message-0',
						sessionId: currentSessionId,
					})),
				);
				const share = deriveWorktreeAnnotationShareProjection({
					scope: 'pending',
					threads: publication.snapshot.threads,
				});
				expect(share.pendingCount).toBe(currentSessionIds.length);
				expect(harness.publications.map((ready) => ready.contentSessionIds)).toEqual([
					[],
					currentSessionIds,
				]);
			} finally {
				heldQuery.resolve({
					descriptor: pages.get(JSON.stringify([sessionId]))?.descriptor,
					kind: 'content',
				});
				await harness.controller.dispose();
			}
		},
	);

	test('newly demanded installed session fetches rich content and exposes pending Share', async () => {
		const harness = await createHarness({ pages: await makeProjectionPages(1, 8) });
		harness.controller.setDemand({ active: true, sessionIds: [], sourceGeneration: 8 });
		harness.controller.ensureSubscription();
		harness.notifications.installCatalog(8);
		await harness.controller.waitForIdle();
		expect(harness.querySessionIds).toEqual([[]]);

		harness.controller.setDemand({ active: true, sessionIds: [sessionId], sourceGeneration: 8 });
		await harness.controller.waitForIdle();

		expect(harness.querySessionIds).toEqual([[], [sessionId]]);
		const publication = harness.publications.at(-1);
		expect(publication?.contentSessionIds).toEqual([sessionId]);
		expect(publication?.snapshot.threads[0]?.messages[0]?.sessionId).toBe(sessionId);
		if (publication === undefined) throw new Error('Expected demanded annotation publication.');
		const share = deriveWorktreeAnnotationShareProjection({
			scope: 'pending',
			threads: publication.snapshot.threads,
		});
		expect(share.pendingCount).toBe(1);
		expect(share.inlineThreads[0]?.messages).toHaveLength(1);
	});

	test('A to B to A re-reads A from current content without a catalog change', async () => {
		const otherSessionId = uuidv7(42);
		const pagesA = await makeProjectionPages(1, 8);
		const pageA = pagesA[0];
		if (pageA === undefined) throw new Error('Expected one A projection page.');
		const bytesB = new TextEncoder().encode(
			new TextDecoder().decode(pageA.bytes).replaceAll(sessionId, otherSessionId),
		);
		const pageB = {
			bytes: bytesB,
			descriptor: {
				...pageA.descriptor,
				descriptorId: 'projection-session-b',
				maximumBytes: bytesB.byteLength,
				page: {
					...pageA.descriptor.page,
					aggregateSha256: createHash('sha256').update(bytesB).digest('hex'),
				},
			},
		};
		const harness = await createHarness({
			pages: [pageA, pageB],
			queryOverride: (request) =>
				Promise.resolve({
					descriptor: request.sessionIds.includes(otherSessionId)
						? pageB.descriptor
						: pageA.descriptor,
					kind: 'content',
				}),
		});
		harness.controller.setDemand({ active: true, sessionIds: [sessionId], sourceGeneration: 8 });
		harness.controller.ensureSubscription();
		const subscriptionId = harness.notifications.subscription.subscriptionId;
		const catalog = installBridgeProductCommentBatch(
			makeCommentCatalogInstallation({
				snapshotCause: 'open',
				entries: [
					{ kind: 'session', semanticRevision: 1, sessionId },
					{ kind: 'session', semanticRevision: 1, sessionId: otherSessionId },
				],
				revision: 8,
				subscriptionId,
				subscriptionKind: 'file.annotations',
				worktreeId,
			}),
			{ subscriptionId, workerDerivationEpoch: 1, worktreeId },
		);
		expect(harness.controller.acceptInstalledCatalog(catalog)).toBe(true);
		await harness.controller.waitForIdle();

		harness.controller.setDemand({
			active: true,
			sessionIds: [otherSessionId],
			sourceGeneration: 8,
		});
		await harness.controller.waitForIdle();
		harness.controller.setDemand({ active: true, sessionIds: [sessionId], sourceGeneration: 8 });
		await harness.controller.waitForIdle();

		expect(harness.querySessionIds).toEqual([[], [sessionId], [otherSessionId], [sessionId]]);
		expect(harness.publications.at(-1)?.snapshot.threads[0]?.messages[0]?.sessionId).toBe(
			sessionId,
		);
	});

	test('equal demand adds no E4 query and pre-install demand uses the existing install path once', async () => {
		const harness = await createHarness({ pages: await makeProjectionPages(1, 8) });
		harness.controller.setDemand({ active: true, sessionIds: [sessionId], sourceGeneration: 8 });
		harness.controller.ensureSubscription();
		harness.controller.setDemand({
			active: true,
			sessionIds: [sessionId, sessionId],
			sourceGeneration: 8,
		});
		expect(harness.querySessionIds).toEqual([]);

		harness.notifications.installCatalog(8);
		await harness.controller.waitForIdle();
		expect(harness.querySessionIds).toEqual([[], [sessionId]]);
		harness.controller.setDemand({ active: true, sessionIds: [sessionId], sourceGeneration: 8 });
		await harness.controller.waitForIdle();
		expect(harness.querySessionIds).toEqual([[], [sessionId]]);
	});
});

async function makeOverlappingDemandPages(
	otherSessionId: string,
): Promise<Map<string, MutableProjectionPage>> {
	const basePage = (await makeProjectionPages(1, 8))[0];
	if (basePage === undefined) throw new Error('Expected one annotation projection page.');
	const [headerLine, messageLine] = new TextDecoder().decode(basePage.bytes).trimEnd().split('\n');
	if (headerLine === undefined || messageLine === undefined)
		throw new Error('Expected header and message records.');
	const headerRecord: unknown = JSON.parse(headerLine);
	if (headerRecord === null || typeof headerRecord !== 'object' || !('header' in headerRecord))
		throw new Error('Expected annotation projection header.');
	const header = bridgeWorkerAnnotationProjectionHeaderSchema.parse(headerRecord.header);
	const baseSession = header.sessions[0];
	if (baseSession === undefined) throw new Error('Expected annotation session.');
	const pages = new Map<string, MutableProjectionPage>();
	for (const sessionIds of [[], [sessionId], [otherSessionId], [sessionId, otherSessionId]]) {
		const sessions = sessionIds.map((currentSessionId) => {
			const { completedAt, createdAt, updatedAt, ...session } = baseSession;
			return {
				...session,
				completedAtUnixMilliseconds: completedAt,
				createdAtUnixMilliseconds: createdAt,
				updatedAtUnixMilliseconds: updatedAt,
				sessionId: currentSessionId,
			};
		});
		const records = [
			JSON.stringify({
				kind: 'header',
				header: {
					...header,
					sessions,
					expectedSessionCount: sessions.length,
					expectedThreadCount: sessions.length,
					expectedMessageCount: sessions.length,
				},
			}),
			...sessionIds.map((currentSessionId) =>
				currentSessionId === sessionId
					? messageLine
					: messageLine
							.replaceAll(sessionId, currentSessionId)
							.replaceAll(uuidv7(2), uuidv7(43))
							.replaceAll(uuidv7(100), uuidv7(101)),
			),
		];
		const bytes = new TextEncoder().encode(`${records.join('\n')}\n`);
		const key = JSON.stringify(sessionIds);
		pages.set(key, {
			bytes,
			descriptor: {
				...basePage.descriptor,
				descriptorId: `projection-demand-${pages.size}`,
				maximumBytes: bytes.byteLength,
				page: {
					...basePage.descriptor.page,
					aggregateSha256: createHash('sha256').update(bytes).digest('hex'),
					expectedSessionCount: sessions.length,
					expectedThreadCount: sessions.length,
					expectedMessageCount: sessions.length,
				},
			},
		});
	}
	return pages;
}

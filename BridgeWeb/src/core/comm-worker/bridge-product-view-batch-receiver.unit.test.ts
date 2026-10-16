import { describe, expect, it } from 'vitest';

import commentCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-comment-catalog-record-corpus.json' with { type: 'json' };
import fileCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import { BridgeProductBatchFrameRouter } from './bridge-product-batch-frame-router.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import type { BridgeProductControlMux } from './bridge-product-session-authority.js';
import { parseBridgeProductStrictJSON } from './bridge-product-strict-json.js';
import { BridgeProductViewBatchReceiver } from './bridge-product-view-batch-receiver.js';
import {
	ControlledBatchDeadlineClock,
	identity,
	begin,
	part,
	deletion,
	complete,
} from './bridge-product-view-batch-receiver.test-support.js';
import { createTestViewScopeOwner } from './bridge-product-view-scope-owner.test-support.js';

const noDeadlineClock: BridgeProductDeadlineClock = { schedule: () => (): void => {} };

function createRouter(): BridgeProductBatchFrameRouter {
	return new BridgeProductBatchFrameRouter({
		deadlineClock: noDeadlineClock,
		progressDeadlineMilliseconds: 5_000,
	});
}

function receiver(
	coversKey?: (scope: Readonly<Record<string, unknown>>, key: string) => boolean,
): BridgeProductViewBatchReceiver {
	return new BridgeProductViewBatchReceiver({
		...(coversKey === undefined ? {} : { coversKey }),
		handle: identity.handle,
		scope: { kind: 'review', interests: [] },
		scopeRevision: 0,
		subscriptionId: identity.subscriptionId,
		subscriptionKind: identity.subscriptionKind,
	});
}

describe('Bridge product W4 per-domain batch receiver', () => {
	it('installs an in-flight Review batch after demand advances to a newer scope revision', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		expect(state.accept(begin({ snapshotCause: 'open', partCount: 1, target: 1 })).kind).toBe(
			'staged',
		);
		state.setScope({ kind: 'review', interests: [{ lane: 'visible', itemIds: ['a'] }] }, 1);
		expect(state.accept(part({ key: 'a', revision: 1, value: 'A' })).kind).toBe('staged');
		expect(state.accept(complete({})).kind).toBe('installed');
		expect(state.records('default')).toEqual([{ key: 'a', revision: 1, value: 'A' }]);
	});

	it('an expired bank releases W2 for each successor resnapshot until the view budget is exhausted', async () => {
		const clock = new ControlledBatchDeadlineClock();
		const requests: string[] = [];
		const admissions: Promise<void>[] = [];
		const installations: string[] = [];
		const identities = ['handle-1', 'incarnation-1'];
		let nextIdentity = 0;
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => ({
					...props,
					kind: 'subscription.scopeAccepted' as const,
					paneSessionId: 'pane-1',
					requestId: 'scope-request',
					requestSequence: 1,
					wireVersion: 2 as const,
					workerInstanceId: 'worker-1',
				}),
				resnapshotView: async (props) => {
					requests.push(props.domain);
					return {
						...props,
						kind: 'subscription.resnapshotAccepted' as const,
						paneSessionId: 'pane-1',
						requestId: 'resnapshot-request',
						requestSequence: requests.length,
						wireVersion: 2 as const,
						workerInstanceId: 'worker-1',
					};
				},
			} satisfies Pick<BridgeProductControlMux, 'resnapshotView' | 'setViewScope'>,
			createIdentifier: (): string => identities[nextIdentity++] ?? 'unexpected-identity',
			deadlineClock: clock,
			maximumConsecutiveResnapshots: 3,
			progressDeadlineMilliseconds: 5_000,
		});
		owner.register({
			scope: { kind: 'review', interests: [] },
			subscriptionId: identity.subscriptionId,
			subscriptionKind: identity.subscriptionKind,
		});
		const router = new BridgeProductBatchFrameRouter({
			deadlineClock: clock,
			progressDeadlineMilliseconds: 5_000,
		});
		router.setSinks({
			install: (installation): void => {
				installations.push(installation.begin.batchId);
				owner.recordCertifiedInstall(installation.begin);
			},
			receipt: (): void => {},
			resnapshot: (): void => {},
			snapshotBeginAccepted: (frame): boolean => {
				if (frame.snapshotCause === undefined) throw new Error('Expected snapshot cause.');
				return owner.observeSnapshotBegin({ ...frame, snapshotCause: frame.snapshotCause });
			},
			resnapshotLatest: (subscriptionId, domain): void => {
				admissions.push(owner.resnapshot(subscriptionId, domain));
			},
		});
		for (const [batchId, target] of [
			['first', 1],
			['second', 2],
			['third', 3],
			['fourth', 4],
		] as const) {
			router.accept(begin({ snapshotCause: 'requested', batchId, partCount: 1, target }));
			router.accept(part({ batchId, key: batchId, revision: target, value: batchId }));
			clock.activeDeadline().fire();
			await Promise.all(admissions.splice(0));
		}
		expect(requests).toEqual(['default', 'default', 'default']);
		expect(owner.recoveryState(identity.subscriptionId)).toEqual({
			consecutiveResnapshots: 3,
			status: 'failedRetryable',
		});
		expect(installations).toEqual([]);
		await owner.retryView(identity.subscriptionId);
		expect(requests).toHaveLength(4);
		router.accept(begin({ snapshotCause: 'open', batchId: 'retry', partCount: 1, target: 5 }));
		router.accept(part({ batchId: 'retry', key: 'retry', revision: 5, value: 'ready' }));
		router.accept(complete({ batchId: 'retry' }));
		expect(installations).toEqual(['retry']);
		expect(clock.peakActiveDeadlineCount).toBe(1);
		expect(owner.recoveryState(identity.subscriptionId)).toEqual({
			consecutiveResnapshots: 0,
			status: 'ready',
		});
	});
	it('expires only an incomplete bank, preserves last good, and ignores its late complete', () => {
		const clock = new ControlledBatchDeadlineClock();
		const router = new BridgeProductBatchFrameRouter({
			deadlineClock: clock,
			progressDeadlineMilliseconds: 5_000,
		});
		const installations: string[] = [];
		const latestScopeResnapshots: string[] = [];
		router.setSinks({
			install: (installation): void => {
				installations.push(installation.begin.batchId);
			},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (subscriptionId): void => {
				latestScopeResnapshots.push(subscriptionId);
			},
		});
		router.accept(begin({ snapshotCause: 'open', batchId: 'last-good', partCount: 1, target: 1 }));
		router.accept(part({ batchId: 'last-good', key: 'a', revision: 1, value: 'A' }));
		router.accept(complete({ batchId: 'last-good' }));
		expect(clock.deadlines.every((deadline) => !deadline.active)).toBe(true);
		router.accept(
			begin({
				snapshotCause: undefined,
				batchId: 'incomplete',
				base: 1,
				mode: 'change',
				partCount: 1,
				target: 2,
			}),
		);
		router.accept(part({ batchId: 'incomplete', key: 'b', revision: 2, value: 'B' }));
		clock.activeDeadline().fire();
		router.accept(complete({ batchId: 'incomplete' }));
		const siblingSubscriptionId = 'sibling-subscription';
		for (const frame of [
			begin({ snapshotCause: 'open', batchId: 'sibling', partCount: 1, target: 1 }),
			part({ batchId: 'sibling', key: 'sibling', revision: 1, value: 'S' }),
			complete({ batchId: 'sibling' }),
		]) {
			router.accept(
				bridgeProductBatchFrameSchema.parse({ ...frame, subscriptionId: siblingSubscriptionId }),
			);
		}
		expect(installations).toEqual(['last-good', 'sibling']);
		expect(latestScopeResnapshots).toEqual([identity.subscriptionId]);
	});

	it('rearms on verified parts and cancels on complete, replacement, and retirement', () => {
		const clock = new ControlledBatchDeadlineClock();
		const router = new BridgeProductBatchFrameRouter({
			deadlineClock: clock,
			progressDeadlineMilliseconds: 5_000,
		});
		const resnapshots: string[] = [];
		router.setSinks({
			install: (): void => {},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (subscriptionId): void => {
				resnapshots.push(subscriptionId);
			},
		});
		const firstBegin = begin({ snapshotCause: 'open', batchId: 'first', partCount: 1, target: 1 });
		router.accept(firstBegin);
		const first = clock.activeDeadline();
		router.accept(firstBegin);
		expect(clock.activeDeadline()).toBe(first);
		router.accept(part({ batchId: 'first', key: 'a', revision: 1, value: 'A' }));
		expect(first.active).toBe(false);
		const afterPart = clock.activeDeadline();
		router.accept(part({ batchId: 'first', key: 'a', revision: 1, value: 'A' }));
		expect(clock.activeDeadline()).toBe(afterPart);
		router.accept(complete({ batchId: 'first' }));
		expect(afterPart.active).toBe(false);
		router.accept(begin({ snapshotCause: 'open', batchId: 'second', partCount: 1, target: 2 }));
		const beforeReplacement = clock.activeDeadline();
		router.accept(
			begin({ snapshotCause: 'open', batchId: 'replacement', partCount: 1, target: 3 }),
		);
		expect(beforeReplacement.active).toBe(false);
		const beforeHandleReplacement = clock.activeDeadline();
		router.accept(
			begin({
				snapshotCause: 'open',
				batchId: 'new-handle',
				handle: 'handle-2',
				partCount: 1,
				target: 4,
			}),
		);
		expect(beforeHandleReplacement.active).toBe(false);
		const beforeRetirement = clock.activeDeadline();
		router.retireSubscription(identity.subscriptionId);
		expect(beforeRetirement.active).toBe(false);
		expect(resnapshots).toEqual([]);
	});
	it('reports an accepted replacement snapshot once and ignores late parts from its abandoned stage', () => {
		const router = createRouter();
		const replacements: string[] = [];
		const resnapshots: string[] = [];
		const installations: string[] = [];
		router.setSinks({
			install: (installation): void => {
				installations.push(installation.begin.batchId);
			},
			receipt: (): void => {},
			snapshotBeginAccepted: (frame): void => {
				replacements.push(frame.batchId);
			},
			resnapshot: (frame): void => {
				resnapshots.push(frame.batchId);
			},
			resnapshotLatest: (): void => {},
		});
		router.accept(begin({ snapshotCause: 'open', batchId: 'abandoned', partCount: 2, target: 2 }));
		router.accept(part({ batchId: 'abandoned', key: 'a', revision: 1, value: 'old' }));
		const latePart = part({
			batchId: 'abandoned',
			key: 'b',
			partIndex: 1,
			revision: 2,
			value: 'late',
		});
		const lateComplete = complete({ batchId: 'abandoned' });
		for (let index = 0; index < 12; index += 1) {
			router.accept(
				begin({
					snapshotCause: 'open',
					batchId: `replacement-${index}`,
					partCount: 1,
					target: 3 + index,
				}),
			);
		}
		router.accept(latePart);
		router.accept(lateComplete);
		router.accept(part({ batchId: 'replacement-11', key: 'a', revision: 14, value: 'current' }));
		router.accept(complete({ batchId: 'replacement-11' }));
		expect(replacements).toEqual([
			'abandoned',
			...Array.from({ length: 12 }, (_, index) => `replacement-${index}`),
		]);
		expect(resnapshots).toEqual([]);
		expect(installations).toEqual(['replacement-11']);
	});
	it('routes a received part credit before the certified bank install', () => {
		const router = createRouter();
		const events: string[] = [];
		router.setSinks({
			install: (installation): void => {
				events.push(`installed:${installation.domain}:${installation.records.length}`);
			},
			receipt: (_, through): void => {
				events.push(`received:${through}`);
			},
			resnapshot: (): void => {
				events.push('resnapshot');
			},
			resnapshotLatest: (): void => {},
		});
		router.accept(begin({ snapshotCause: 'open', partCount: 1, target: 1 }));
		router.accept(part({ key: 'a', revision: 1, value: 'A' }));
		expect(events).toEqual(['received:1']);
		router.accept(complete({}));
		expect(events).toEqual(['received:1', 'installed:default:1']);
	});

	it('keeps the bank unchanged when typed verification rejects, then accepts a same-revision recovery snapshot', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', batchId: 'corrupt', partCount: 1, target: 2 }));
		state.accept(part({ batchId: 'corrupt', key: 'item/a', revision: 2, value: 'corrupt' }));
		expect(
			state.accept(complete({ batchId: 'corrupt' }), (installation): void => {
				if (installation.records[0]?.value === 'corrupt') throw new Error('typed rejection');
			}).kind,
		).toBe('resnapshot');
		expect(state.cursor('default')).toBe(0);
		expect(state.records('default')).toEqual([]);
		expect(state.takeInstallations()).toEqual([]);

		state.accept(begin({ snapshotCause: 'open', batchId: 'recovery', partCount: 1, target: 2 }));
		state.accept(
			part({
				batchId: 'recovery',
				deliverySequence: 3,
				key: 'item/a',
				revision: 2,
				value: 'valid',
			}),
		);
		expect(state.accept(complete({ batchId: 'recovery' }), (): void => {}).kind).toBe('installed');
		expect(state.records('default')).toEqual([{ key: 'item/a', revision: 2, value: 'valid' }]);
		expect(state.takeInstallations()).toHaveLength(1);

		state.accept(begin({ snapshotCause: 'open', batchId: 'stale', partCount: 1, target: 2 }));
		state.accept(
			part({ batchId: 'stale', deliverySequence: 4, key: 'item/a', revision: 2, value: 'stale' }),
		);
		state.accept(complete({ batchId: 'stale' }), (): void => {});
		expect(state.records('default')).toEqual([{ key: 'item/a', revision: 2, value: 'valid' }]);
	});

	it('an application rejection resnapshots only its subscription while a sibling installs', () => {
		const router = createRouter();
		const resnapshots: string[] = [];
		const installed: string[] = [];
		router.setSinks({
			install: (installation): void => {
				if (installation.begin.subscriptionId === identity.subscriptionId) {
					throw new Error('The typed application rejected this bank.');
				}
				installed.push(installation.begin.subscriptionId);
			},
			receipt: (): void => {},
			resnapshot: (frame): void => {
				resnapshots.push(frame.subscriptionId);
			},
			resnapshotLatest: (): void => {},
		});
		router.accept(begin({ snapshotCause: 'open', partCount: 1, target: 1 }));
		router.accept(part({ key: 'a', revision: 1, value: 'A' }));
		router.accept(complete({}));
		const siblingSubscriptionId = 'sibling-subscription';
		router.accept(
			bridgeProductBatchFrameSchema.parse({
				...begin({ snapshotCause: 'open', batchId: 'sibling-batch', partCount: 1, target: 1 }),
				subscriptionId: siblingSubscriptionId,
			}),
		);
		router.accept(
			bridgeProductBatchFrameSchema.parse({
				...part({ batchId: 'sibling-batch', key: 'b', revision: 1, value: 'B' }),
				subscriptionId: siblingSubscriptionId,
			}),
		);
		router.accept(
			bridgeProductBatchFrameSchema.parse({
				...complete({ batchId: 'sibling-batch' }),
				subscriptionId: siblingSubscriptionId,
			}),
		);
		expect(resnapshots).toEqual([identity.subscriptionId]);
		expect(installed).toEqual([siblingSubscriptionId]);
	});

	it('an asynchronous typed install rejection resnapshots after receipt credit', async () => {
		const router = createRouter();
		const events: string[] = [];
		let rejectInstallation: ((error: Error) => void) | undefined;
		const installation = new Promise<void>((_resolve, reject): void => {
			rejectInstallation = reject;
		});
		router.setSinks({
			install: (): Promise<void> => installation,
			receipt: (): void => {
				events.push('receipt');
			},
			resnapshot: (): void => {
				events.push('resnapshot');
			},
			resnapshotLatest: (): void => {},
		});
		router.accept(begin({ snapshotCause: 'open', partCount: 1, target: 1 }));
		router.accept(part({ key: 'a', revision: 1, value: 'A' }));
		router.accept(complete({}));
		expect(events).toEqual(['receipt']);
		rejectInstallation?.(new Error('The Review installer rejected its certified bank.'));
		await Promise.resolve();
		expect(events).toEqual(['receipt', 'resnapshot']);
	});

	it('installs all four kinds through strict JSON and the batch wire contract', () => {
		const cases = [
			{
				key: fileCorpus.rows[0]?.recordKey,
				kind: 'file.metadata',
				scope: { kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] },
				value: fileCorpus.rows[0]?.row,
			},
			{
				key: 'review:item-a',
				kind: 'review.metadata',
				scope: { kind: 'review', interests: [] },
				value: { itemId: 'item-a' },
			},
			{
				key: commentCorpus.records[0]?.recordKey,
				kind: 'file.annotations',
				scope: { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' },
				value: commentCorpus.records[0]?.record,
			},
			{
				key: commentCorpus.records[0]?.recordKey,
				kind: 'review.annotations',
				scope: { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' },
				value: commentCorpus.records[0]?.record,
			},
		] as const;
		for (const entry of cases) {
			expect(entry.key).toBeDefined();
			const state = new BridgeProductViewBatchReceiver({
				handle: identity.handle,
				scope: entry.scope,
				scopeRevision: 0,
				subscriptionId: identity.subscriptionId,
				subscriptionKind: entry.kind,
			});
			state.admitDomain('default', 'incarnation-1');
			const frames = [
				{
					...identity,
					kind: 'subscription.batchBegin',
					subscriptionKind: entry.kind,
					scope: entry.scope,
					baseRevision: 0,
					mode: 'snapshot',
					snapshotCause: 'open',
					partCount: 1,
					...(entry.kind === 'review.metadata'
						? { publicationId: '00000000-0000-7000-8000-000000000011' }
						: {}),
					targetRevision: 1,
					streamSequence: 1,
				},
				{
					...identity,
					kind: 'subscription.batchPart',
					subscriptionKind: entry.kind,
					deliverySequence: 1,
					part: { operation: 'put', key: entry.key, revision: 1, value: entry.value },
					partIndex: 0,
					streamSequence: 2,
				},
				{
					...identity,
					kind: 'subscription.batchComplete',
					subscriptionKind: entry.kind,
					coveredScope: entry.scope,
					streamSequence: 3,
				},
			];
			for (const frame of frames) {
				const validated = bridgeProductBatchFrameSchema.parse(frame);
				const rawBytes = new TextEncoder().encode(JSON.stringify(validated));
				state.accept(bridgeProductBatchFrameSchema.parse(parseBridgeProductStrictJSON(rawBytes)));
			}
			expect(state.records('default')).toEqual([
				{ key: entry.key, revision: 1, value: entry.value },
			]);
		}
	});

	it('keeps installed rows until every declared part completes, then swaps atomically', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		expect(state.accept(begin({ snapshotCause: 'open', partCount: 2, target: 2 })).kind).toBe(
			'staged',
		);
		expect(state.accept(part({ key: 'a', revision: 1, value: 'A' })).kind).toBe('staged');
		expect(state.records('default')).toEqual([]);
		expect(state.accept(complete({})).kind).toBe('resnapshot');
		expect(state.records('default')).toEqual([]);

		state.accept(begin({ snapshotCause: 'open', batchId: 'batch-2', partCount: 1, target: 3 }));
		state.accept(part({ batchId: 'batch-2', key: 'a', revision: 3, value: 'new' }));
		expect(state.accept(complete({ batchId: 'batch-2' })).kind).toBe('installed');
		expect(state.records('default')).toEqual([{ key: 'a', revision: 3, value: 'new' }]);
	});

	it('a zero-part coverage batch changes the cursor without pruning existing rows', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', partCount: 1, target: 1 }));
		state.accept(part({ key: 'a', revision: 1, value: 'A' }));
		state.accept(complete({}));
		state.accept(
			begin({
				snapshotCause: undefined,
				batchId: 'coverage-2',
				base: 1,
				mode: 'coverage',
				partCount: 0,
				target: 2,
			}),
		);
		expect(state.accept(complete({ batchId: 'coverage-2' })).kind).toBe('installed');
		expect(state.records('default')).toEqual([{ key: 'a', revision: 1, value: 'A' }]);
		expect(state.cursor('default')).toBe(2);
	});

	it('member completion waits for its collection dependency without blocking another domain', () => {
		const state = receiver();
		state.admitDomain('collection', 'collection-1');
		state.admitDomain('member-a', 'member-1');
		state.accept(
			begin({
				snapshotCause: 'open',
				domain: 'member-a',
				incarnation: 'member-1',
				partCount: 1,
				requiresCollection: 2,
				target: 1,
			}),
		);
		state.accept(
			part({ domain: 'member-a', incarnation: 'member-1', key: 'a', revision: 1, value: 'A' }),
		);
		expect(state.accept(complete({ domain: 'member-a', incarnation: 'member-1' })).kind).toBe(
			'staged',
		);
		expect(state.records('member-a')).toEqual([]);
		state.accept(
			begin({
				snapshotCause: 'open',
				batchId: 'collection-2',
				domain: 'collection',
				incarnation: 'collection-1',
				partCount: 0,
				target: 2,
			}),
		);
		expect(
			state.accept(
				complete({ batchId: 'collection-2', domain: 'collection', incarnation: 'collection-1' }),
			).kind,
		).toBe('installed');
		expect(state.records('member-a')).toEqual([{ key: 'a', revision: 1, value: 'A' }]);
		expect(state.takeInstallations().map((installation) => installation.domain)).toEqual([
			'collection',
			'member-a',
		]);
		expect(state.takeInstallations()).toEqual([]);
	});

	it('a deletion tombstone rejects a delayed write and an old incarnation', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', partCount: 1, target: 1 }));
		state.accept(part({ key: 'a', revision: 1, value: 'A' }));
		state.accept(complete({}));
		state.accept(
			begin({
				snapshotCause: undefined,
				batchId: 'delete-2',
				base: 1,
				mode: 'change',
				partCount: 1,
				target: 2,
			}),
		);
		state.accept(deletion({ batchId: 'delete-2', key: 'a', revision: 2 }));
		expect(state.accept(complete({ batchId: 'delete-2' })).kind).toBe('installed');
		state.accept(
			begin({
				snapshotCause: undefined,
				batchId: 'stale-3',
				base: 2,
				mode: 'change',
				partCount: 1,
				target: 3,
			}),
		);
		state.accept(part({ batchId: 'stale-3', key: 'a', revision: 1, value: 'stale' }));
		state.accept(complete({ batchId: 'stale-3' }));
		expect(state.records('default')).toEqual([]);
		expect(
			state.accept(
				begin({ snapshotCause: 'open', incarnation: 'retired', partCount: 1, target: 4 }),
			).kind,
		).toBe('ignored');
	});

	it('a conflicting duplicate invalidates staging without installing its earlier part', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', partCount: 1, target: 1 }));
		state.accept(part({ key: 'a', revision: 1, value: 'A' }));
		expect(state.accept(part({ key: 'a', revision: 1, value: 'different' })).kind).toBe(
			'resnapshot',
		);
		expect(state.accept(complete({})).kind).toBe('resnapshot');
		expect(state.records('default')).toEqual([]);
	});

	it('a windowed empty snapshot prunes only its range and leaves an absence floor', () => {
		const state = receiver((scope, key) =>
			typeof scope['prefix'] === 'string' ? key.startsWith(scope['prefix']) : true,
		);
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', partCount: 2, target: 2 }));
		state.accept(part({ key: 'src/a', revision: 1, value: 'A' }));
		state.accept(part({ key: 'docs/b', partIndex: 1, revision: 2, value: 'B' }));
		state.accept(complete({}));
		state.accept(
			begin({
				batchId: 'src-empty-3',
				mode: 'snapshot',
				snapshotCause: 'open',
				partCount: 0,
				target: 3,
			}),
		);
		expect(
			state.accept(
				complete({
					batchId: 'src-empty-3',
					coveredScope: { kind: 'review', interests: [], prefix: 'src/' },
				}),
			).kind,
		).toBe('installed');
		state.accept(
			begin({
				snapshotCause: undefined,
				batchId: 'late-4',
				base: 3,
				mode: 'change',
				partCount: 1,
				target: 4,
			}),
		);
		state.accept(part({ batchId: 'late-4', key: 'src/new', revision: 2, value: 'stale' }));
		state.accept(complete({ batchId: 'late-4' }));
		expect(state.records('default')).toEqual([{ key: 'docs/b', revision: 2, value: 'B' }]);
	});

	it('ignores a late change against the cursor replaced by a complete snapshot', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', batchId: 'initial', partCount: 1, target: 1 }));
		state.accept(part({ batchId: 'initial', key: 'a', revision: 1, value: 'old' }));
		state.accept(complete({ batchId: 'initial' }));
		state.accept(
			begin({ snapshotCause: 'open', batchId: 'recovered', base: 1, partCount: 1, target: 3 }),
		);
		state.accept(part({ batchId: 'recovered', key: 'a', revision: 3, value: 'current' }));
		expect(state.accept(complete({ batchId: 'recovered' })).kind).toBe('installed');

		expect(
			state.accept(
				begin({
					snapshotCause: undefined,
					batchId: 'late-change',
					base: 1,
					mode: 'change',
					partCount: 1,
					target: 4,
				}),
			).kind,
		).toBe('ignored');
		expect(state.cursor('default')).toBe(3);
		expect(state.records('default')).toEqual([{ key: 'a', revision: 3, value: 'current' }]);
	});

	it('scope comparison is independent of JSON member order', () => {
		const state = new BridgeProductViewBatchReceiver({
			handle: identity.handle,
			scope: { kind: 'review', interests: [{ lane: 'active', itemIds: ['first', 'second'] }] },
			scopeRevision: 0,
			subscriptionId: identity.subscriptionId,
			subscriptionKind: identity.subscriptionKind,
		});
		state.admitDomain('default', 'incarnation-1');
		expect(
			state.accept(
				begin({
					snapshotCause: 'open',
					partCount: 0,
					scope: { interests: [{ itemIds: ['first', 'second'], lane: 'active' }], kind: 'review' },
					target: 1,
				}),
			).kind,
		).toBe('staged');
		expect(state.accept(complete({})).kind).toBe('installed');
	});

	it('credits advance on received contiguous parts before installation', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', partCount: 3, target: 3 }));
		expect(state.accept(part({ key: 'c', partIndex: 2, revision: 3, value: 'C' }))).toEqual({
			kind: 'staged',
		});
		expect(state.accept(part({ key: 'a', partIndex: 0, revision: 1, value: 'A' }))).toEqual({
			kind: 'staged',
			receivedThroughDeliverySequence: 1,
		});
		expect(state.records('default')).toEqual([]);
		expect(state.accept(part({ key: 'b', partIndex: 1, revision: 2, value: 'B' }))).toEqual({
			kind: 'staged',
			receivedThroughDeliverySequence: 3,
		});
		expect(state.accept(complete({})).kind).toBe('installed');
	});

	it('credits are contiguous within each domain when delivery sequences overlap', () => {
		const state = receiver();
		state.admitDomain('member-a', 'incarnation-a');
		state.admitDomain('member-b', 'incarnation-b');
		state.accept(
			begin({
				snapshotCause: 'open',
				batchId: 'batch-a',
				domain: 'member-a',
				incarnation: 'incarnation-a',
				partCount: 2,
				target: 2,
			}),
		);
		state.accept(
			begin({
				snapshotCause: 'open',
				batchId: 'batch-b',
				domain: 'member-b',
				incarnation: 'incarnation-b',
				partCount: 2,
				target: 2,
			}),
		);
		expect(
			state.accept(
				part({
					batchId: 'batch-a',
					domain: 'member-a',
					incarnation: 'incarnation-a',
					key: 'a-1',
					partIndex: 0,
					revision: 1,
					value: 'A1',
				}),
			),
		).toEqual({ kind: 'staged', receivedThroughDeliverySequence: 1 });
		expect(
			state.accept(
				part({
					batchId: 'batch-a',
					domain: 'member-a',
					incarnation: 'incarnation-a',
					key: 'a-2',
					partIndex: 1,
					revision: 2,
					value: 'A2',
				}),
			),
		).toEqual({ kind: 'staged', receivedThroughDeliverySequence: 2 });
		expect(
			state.accept(
				part({
					batchId: 'batch-b',
					domain: 'member-b',
					incarnation: 'incarnation-b',
					key: 'b-2',
					partIndex: 1,
					revision: 2,
					value: 'B2',
				}),
			),
		).toEqual({ kind: 'staged' });
		expect(
			state.accept(
				part({
					batchId: 'batch-b',
					domain: 'member-b',
					incarnation: 'incarnation-b',
					key: 'b-1',
					partIndex: 0,
					revision: 1,
					value: 'B1',
				}),
			),
		).toEqual({ kind: 'staged', receivedThroughDeliverySequence: 2 });
	});

	it('a resnapshot establishes a new receipt base without acknowledging its missing first part', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', batchId: 'old', partCount: 2, target: 2 }));
		expect(
			state.accept(part({ batchId: 'old', key: 'old-2', partIndex: 1, revision: 2, value: 'O2' })),
		).toEqual({ kind: 'staged' });
		expect(state.accept(complete({ batchId: 'old' })).kind).toBe('resnapshot');
		state.accept(begin({ snapshotCause: 'open', batchId: 'replacement', partCount: 2, target: 4 }));
		expect(
			state.accept(
				part({ batchId: 'replacement', key: 'new-4', partIndex: 1, revision: 4, value: 'N4' }),
			),
		).toEqual({ kind: 'staged' });
		expect(
			state.accept(
				part({ batchId: 'replacement', key: 'new-3', partIndex: 0, revision: 3, value: 'N3' }),
			),
		).toEqual({ kind: 'staged', receivedThroughDeliverySequence: 4 });
	});

	it('keeps the installed view readable and ignores an old change after a replacement snapshot', () => {
		const state = receiver();
		state.admitDomain('default', identity.incarnation);
		state.accept(begin({ snapshotCause: 'open', batchId: 'initial', partCount: 1, target: 1 }));
		state.accept(part({ batchId: 'initial', key: 'item/a', revision: 1, value: 'A' }));
		expect(state.accept(complete({ batchId: 'initial' })).kind).toBe('installed');

		state.accept(begin({ snapshotCause: 'open', batchId: 'replacement', partCount: 1, target: 3 }));
		expect(state.records('default')).toEqual([{ key: 'item/a', revision: 1, value: 'A' }]);
		state.accept(part({ batchId: 'replacement', key: 'item/a', revision: 3, value: 'C' }));
		expect(state.accept(complete({ batchId: 'replacement' })).kind).toBe('installed');
		expect(state.cursor('default')).toBe(3);

		expect(
			state.accept(
				begin({
					snapshotCause: undefined,
					batchId: 'old-change',
					base: 1,
					mode: 'change',
					partCount: 1,
					target: 2,
				}),
			),
		).toEqual({ kind: 'ignored' });
		expect(state.records('default')).toEqual([{ key: 'item/a', revision: 3, value: 'C' }]);
	});

	it('a new handle retains stale rows until its range is certified', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', partCount: 1, target: 1 }));
		state.accept(part({ key: 'a', revision: 1, value: 'A' }));
		state.accept(complete({}));
		state.replaceHandle('handle-2', { kind: 'review', interests: [] }, 0);
		expect(state.records('default')).toEqual([]);
		expect(state.staleRecords('default')).toEqual([{ key: 'a', revision: 1, value: 'A' }]);
		state.admitDomain('default', 'incarnation-2');
		state.accept(
			begin({
				snapshotCause: 'open',
				handle: 'handle-2',
				incarnation: 'incarnation-2',
				partCount: 1,
				target: 1,
			}),
		);
		expect(state.accept(complete({ handle: 'handle-2', incarnation: 'incarnation-2' })).kind).toBe(
			'resnapshot',
		);
		expect(state.staleRecords('default')).toHaveLength(1);
		state.accept(
			begin({
				snapshotCause: 'open',
				batchId: 'replacement',
				handle: 'handle-2',
				incarnation: 'incarnation-2',
				partCount: 0,
				target: 1,
			}),
		);
		expect(
			state.accept(
				complete({ batchId: 'replacement', handle: 'handle-2', incarnation: 'incarnation-2' }),
			).kind,
		).toBe('installed');
		expect(state.staleRecords('default')).toEqual([]);
	});

	it('a delayed complete or lower-target snapshot cannot replace a newer row', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', partCount: 1, target: 1 }));
		state.accept(part({ key: 'a', revision: 1, value: 'A' }));
		state.accept(complete({}));
		state.accept(
			begin({
				snapshotCause: undefined,
				batchId: 'change-2',
				base: 1,
				mode: 'change',
				partCount: 1,
				target: 2,
			}),
		);
		state.accept(part({ batchId: 'change-2', key: 'a', revision: 2, value: 'new' }));
		state.accept(complete({ batchId: 'change-2' }));
		expect(state.accept(complete({ batchId: 'change-2' })).kind).toBe('ignored');
		expect(
			state.accept(begin({ snapshotCause: 'open', batchId: 'delayed', partCount: 0, target: 1 }))
				.kind,
		).toBe('ignored');
		expect(state.records('default')).toEqual([{ key: 'a', revision: 2, value: 'new' }]);
	});

	it('a failed replacement incarnation keeps its last good rows stale until certification', () => {
		const state = receiver();
		state.admitDomain('default', 'incarnation-1');
		state.accept(begin({ snapshotCause: 'open', partCount: 1, target: 1 }));
		state.accept(part({ key: 'a', revision: 1, value: 'A' }));
		state.accept(complete({}));
		state.admitDomain('default', 'incarnation-2');
		expect(state.records('default')).toEqual([]);
		expect(state.staleRecords('default')).toEqual([{ key: 'a', revision: 1, value: 'A' }]);
		expect(
			state.accept(
				begin({
					snapshotCause: undefined,
					batchId: 'new-change',
					incarnation: 'incarnation-2',
					mode: 'change',
					partCount: 0,
					target: 2,
				}),
			).kind,
		).toBe('resnapshot');
		expect(state.staleRecords('default')).toHaveLength(1);
		state.accept(
			begin({
				snapshotCause: 'open',
				batchId: 'new-snapshot',
				incarnation: 'incarnation-2',
				partCount: 0,
				target: 2,
			}),
		);
		expect(
			state.accept(complete({ batchId: 'new-snapshot', incarnation: 'incarnation-2' })).kind,
		).toBe('installed');
		expect(state.staleRecords('default')).toEqual([]);
	});
});

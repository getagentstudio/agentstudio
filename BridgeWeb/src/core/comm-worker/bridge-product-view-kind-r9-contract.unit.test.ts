import { describe, expect, it } from 'vitest';

import { BridgeProductBatchFrameRouter } from './bridge-product-batch-frame-router.js';
import {
	bridgeProductBatchFrameSchema,
	type BridgeProductBatchFrame,
} from './bridge-product-batch-wire-contracts.js';
import {
	BridgeProductViewBatchReceiver,
	type BridgeProductViewInstallation,
} from './bridge-product-view-batch-receiver.js';
import {
	ViewContractWireFixture,
	scopeCoversKey,
	type DataKind,
} from './bridge-product-view-kind-r9-contract.test-support.js';
import { BridgeProductTestFactRecorder } from './test-fixtures/bridge-product-test-fact-recorder.js';

const dataKinds = [
	'file.metadata',
	'review.metadata',
	'file.annotations',
	'review.annotations',
] as const;

describe('four-kind worker R9 contract through the real metadata codec', () => {
	it.each(dataKinds)(
		'%s keeps complete keyed banks through part faults, scope changes and slow consumption',
		async (kind: DataKind): Promise<void> => {
			const wire = new ViewContractWireFixture(kind);
			const state = new BridgeProductViewBatchReceiver({
				handle: wire.handle,
				scope: wire.scope,
				scopeRevision: 0,
				subscriptionId: wire.subscriptionId,
				subscriptionKind: kind,
				coversKey: scopeCoversKey,
			});
			state.admitDomain(wire.domain, wire.incarnation);
			const accept = (
				frame: BridgeProductBatchFrame,
			): ReturnType<BridgeProductViewBatchReceiver['accept']> =>
				state.accept(wire.roundTrip(frame));

			accept(
				wire.begin({ snapshotCause: 'open', batchId: 'initial', targetRevision: 1, partCount: 1 }),
			);
			accept(
				wire.part({
					batchId: 'initial',
					deliverySequence: 1,
					part: { key: 'src/a', operation: 'put', revision: 1, value: 'old' },
				}),
			);
			expect(state.records(wire.domain)).toEqual([]);
			expect(accept(wire.complete('initial')).kind).toBe('installed');
			expect(state.takeInstallations()).toHaveLength(1);
			const lastGood = state.records(wire.domain);

			accept(
				wire.begin({
					snapshotCause: undefined,
					batchId: 'missing',
					baseRevision: 1,
					targetRevision: 3,
					mode: 'change',
					partCount: 2,
				}),
			);
			accept(
				wire.part({
					batchId: 'missing',
					deliverySequence: 2,
					part: { key: 'src/a', operation: 'put', revision: 2, value: 'partial' },
				}),
			);
			expect(accept(wire.complete('missing')).kind).toBe('resnapshot');
			expect(state.records(wire.domain)).toEqual(lastGood);
			expect(state.takeInstallations()).toEqual([]);

			accept(
				wire.begin({
					snapshotCause: 'open',
					batchId: 'replacement',
					targetRevision: 5,
					partCount: 2,
				}),
			);
			// Demand expansion does not discard a still-valid in-flight batch.
			state.setScope(wire.expandedScope, 1);
			const secondPart = wire.part({
				batchId: 'replacement',
				partIndex: 1,
				deliverySequence: 4,
				part: { key: 'src/b', operation: 'put', revision: 5, value: 'B' },
			});
			expect(accept(secondPart)).toEqual({ kind: 'staged' });
			expect(accept(secondPart)).toEqual({ kind: 'staged' });
			expect(state.records(wire.domain)).toEqual(lastGood);
			expect(
				accept(
					wire.part({
						batchId: 'replacement',
						deliverySequence: 3,
						part: { key: 'src/a', operation: 'put', revision: 4, value: 'A' },
					}),
				),
			).toEqual({ kind: 'staged', receivedThroughDeliverySequence: 4 });
			const completion = wire.complete('replacement');
			expect(accept(completion).kind).toBe('installed');
			expect(state.records(wire.domain)).toEqual([
				{ key: 'src/a', revision: 4, value: 'A' },
				{ key: 'src/b', revision: 5, value: 'B' },
			]);
			expect(state.takeInstallations()).toHaveLength(1);
			expect(accept(completion).kind).toBe('ignored');
			expect(state.takeInstallations()).toEqual([]);

			// An entering key's current revision may be below the domain cursor.
			accept(
				wire.begin({
					snapshotCause: undefined,
					batchId: 'expanded',
					baseRevision: 5,
					targetRevision: 5,
					mode: 'coverage',
					partCount: 1,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(
				wire.part({
					batchId: 'expanded',
					deliverySequence: 5,
					scopeRevision: 1,
					part: { key: 'docs/new', operation: 'put', revision: 1, value: 'entering' },
				}),
			);
			expect(accept(wire.complete('expanded', wire.expandedScope, 1)).kind).toBe('installed');
			expect(state.records(wire.domain).find((record) => record.key === 'docs/new')).toEqual({
				key: 'docs/new',
				revision: 1,
				value: 'entering',
			});
			expect(state.records(wire.domain)).toHaveLength(3);
			expect(state.takeInstallations()[0]?.certified).toBe(false);
			accept(
				wire.begin({
					snapshotCause: undefined,
					batchId: 'empty-coverage',
					baseRevision: 5,
					targetRevision: 5,
					mode: 'coverage',
					partCount: 0,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(wire.complete('empty-coverage', wire.expandedScope, 1));
			expect(state.records(wire.domain)).toHaveLength(3);

			accept(
				wire.begin({
					snapshotCause: undefined,
					batchId: 'eviction',
					baseRevision: 5,
					targetRevision: 5,
					mode: 'coverage',
					partCount: 1,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(
				wire.part({
					batchId: 'eviction',
					deliverySequence: 6,
					part: { key: 'docs/new', operation: 'evict' },
				}),
			);
			accept(wire.complete('eviction', wire.expandedScope, 1));
			expect(state.records(wire.domain)).toHaveLength(2);
			accept(
				wire.begin({
					snapshotCause: undefined,
					batchId: 'reenter',
					baseRevision: 5,
					targetRevision: 5,
					mode: 'coverage',
					partCount: 1,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(
				wire.part({
					batchId: 'reenter',
					deliverySequence: 7,
					part: { key: 'docs/new', operation: 'put', revision: 1, value: 'entering' },
				}),
			);
			accept(wire.complete('reenter', wire.expandedScope, 1));
			expect(state.records(wire.domain)).toHaveLength(3);

			// Only the declared region is certified absent; its delayed rows cannot resurrect.
			accept(
				wire.begin({
					snapshotCause: 'open',
					batchId: 'empty-src',
					targetRevision: 6,
					partCount: 0,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(wire.complete('empty-src', wire.scope, 1));
			expect(state.records(wire.domain)).toEqual([
				{ key: 'docs/new', revision: 1, value: 'entering' },
			]);
			accept(
				wire.begin({
					snapshotCause: undefined,
					batchId: 'stale-absence',
					baseRevision: 6,
					targetRevision: 7,
					mode: 'change',
					partCount: 1,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(
				wire.part({
					batchId: 'stale-absence',
					deliverySequence: 8,
					part: { key: 'src/late', operation: 'put', revision: 5, value: 'stale' },
				}),
			);
			accept(wire.complete('stale-absence', wire.expandedScope, 1));
			expect(state.records(wire.domain)).toEqual([
				{ key: 'docs/new', revision: 1, value: 'entering' },
			]);
			accept(
				wire.begin({
					snapshotCause: undefined,
					batchId: 'delete',
					baseRevision: 7,
					targetRevision: 8,
					mode: 'change',
					partCount: 1,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(
				wire.part({
					batchId: 'delete',
					deliverySequence: 9,
					part: { key: 'docs/new', operation: 'delete', revision: 8 },
				}),
			);
			accept(wire.complete('delete', wire.expandedScope, 1));
			expect(state.records(wire.domain)).toEqual([]);
			accept(
				wire.begin({
					snapshotCause: undefined,
					batchId: 'recreate',
					baseRevision: 8,
					targetRevision: 9,
					mode: 'change',
					partCount: 1,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(
				wire.part({
					batchId: 'recreate',
					deliverySequence: 10,
					part: { key: 'docs/new', operation: 'put', revision: 9, value: 'recreated' },
				}),
			);
			accept(wire.complete('recreate', wire.expandedScope, 1));
			const recreated = [{ key: 'docs/new', revision: 9, value: 'recreated' }];
			accept(
				wire.begin({
					snapshotCause: undefined,
					batchId: 'stale-key',
					baseRevision: 9,
					targetRevision: 10,
					mode: 'change',
					partCount: 1,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(
				wire.part({
					batchId: 'stale-key',
					deliverySequence: 11,
					part: { key: 'docs/new', operation: 'put', revision: 8, value: 'older' },
				}),
			);
			accept(wire.complete('stale-key', wire.expandedScope, 1));
			expect(state.records(wire.domain)).toEqual(recreated);
			// A newer snapshot carrying an older value cannot overwrite this key.
			accept(
				wire.begin({
					snapshotCause: 'open',
					batchId: 'overlap',
					targetRevision: 12,
					partCount: 1,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(
				wire.part({
					batchId: 'overlap',
					deliverySequence: 12,
					part: { key: 'docs/new', operation: 'put', revision: 8, value: 'older snapshot row' },
				}),
			);
			accept(wire.complete('overlap', wire.expandedScope, 1));
			expect(state.records(wire.domain)).toEqual(recreated);
			expect(
				accept(
					wire.begin({
						snapshotCause: undefined,
						batchId: 'old-base',
						baseRevision: 1,
						targetRevision: 13,
						mode: 'change',
						partCount: 0,
						scope: wire.expandedScope,
						scopeRevision: 1,
					}),
				).kind,
			).toBe('ignored');

			accept(
				wire.begin({
					snapshotCause: 'open',
					batchId: 'conflict',
					targetRevision: 14,
					partCount: 1,
					scope: wire.expandedScope,
					scopeRevision: 1,
				}),
			);
			accept(
				wire.part({
					batchId: 'conflict',
					deliverySequence: 13,
					part: { key: 'docs/new', operation: 'put', revision: 14, value: 'candidate' },
				}),
			);
			expect(
				accept(
					wire.part({
						batchId: 'conflict',
						deliverySequence: 13,
						part: { key: 'docs/new', operation: 'put', revision: 14, value: 'conflicting' },
					}),
				).kind,
			).toBe('resnapshot');
			expect(state.records(wire.domain)).toEqual(recreated);
			state.replaceHandle('replacement-handle', wire.expandedScope, 2);
			state.admitDomain(wire.domain, 'replacement-incarnation');
			expect(
				accept(
					wire.begin({
						snapshotCause: 'open',
						batchId: 'retired',
						targetRevision: 15,
						partCount: 0,
					}),
				).kind,
			).toBe('ignored');
			expect(state.staleRecords(wire.domain)).toEqual(recreated);
			wire.finish();

			await proveSlowConsumptionAndScopedReplacement(kind);
		},
	);
});

async function proveSlowConsumptionAndScopedReplacement(kind: DataKind): Promise<void> {
	const wire = new ViewContractWireFixture(kind);
	const router = new BridgeProductBatchFrameRouter({
		deadlineClock: { schedule: (): (() => void) => (): void => {} },
		progressDeadlineMilliseconds: 1,
	});
	const release = new BridgeProductTestFactRecorder<'release'>();
	const completed = new BridgeProductTestFactRecorder<string>();
	const visible = new Map<string, BridgeProductViewInstallation['records']>();
	const resnapshots: string[] = [];
	const pending: Promise<void>[] = [];
	router.setSinks({
		install: (installation): Promise<void> | void => {
			visible.set(installation.begin.subscriptionId, installation.records);
			if (installation.begin.batchId === 'slow-current') {
				const held = release.waitFor().then((): void => {
					completed.record(installation.begin.batchId);
				});
				pending.push(held);
				return held;
			}
			completed.record(installation.begin.batchId);
		},
		receipt: (): void => {},
		resnapshot: (frame): void => {
			resnapshots.push(frame.subscriptionId);
		},
		resnapshotLatest: (): void => {},
	});
	const accept = (frame: BridgeProductBatchFrame): void => router.accept(wire.roundTrip(frame));
	try {
		accept(
			wire.begin({
				snapshotCause: 'open',
				batchId: 'slow-current',
				targetRevision: 1,
				partCount: 1,
			}),
		);
		accept(
			wire.part({
				batchId: 'slow-current',
				deliverySequence: 1,
				part: { key: 'src/a', operation: 'put', revision: 1, value: 'old' },
			}),
		);
		accept(wire.complete('slow-current'));
		expect(pending).toHaveLength(1);
		const oldBank = visible.get(wire.subscriptionId);
		accept(
			wire.begin({
				snapshotCause: undefined,
				batchId: 'many-keys',
				baseRevision: 1,
				targetRevision: 10,
				mode: 'change',
				partCount: 3,
			}),
		);
		accept(
			wire.part({
				batchId: 'many-keys',
				deliverySequence: 2,
				part: { key: 'src/a', operation: 'put', revision: 8, value: 'partial-a' },
			}),
		);
		const abandonedPart = wire.part({
			batchId: 'many-keys',
			partIndex: 1,
			deliverySequence: 3,
			part: { key: 'src/b', operation: 'put', revision: 9, value: 'partial-b' },
		});
		const abandonedComplete = wire.complete('many-keys');
		expect(visible.get(wire.subscriptionId)).toEqual(oldBank);
		// N3 owns the pending-key budget. W4 consumes its replacement, not a fake worker budget.
		accept(
			wire.begin({
				snapshotCause: 'open',
				batchId: 'budget-replacement',
				targetRevision: 11,
				partCount: 2,
			}),
		);
		accept(
			wire.part({
				batchId: 'budget-replacement',
				deliverySequence: 4,
				part: { key: 'src/a', operation: 'put', revision: 11, value: 'latest-a' },
			}),
		);
		accept(
			wire.part({
				batchId: 'budget-replacement',
				partIndex: 1,
				deliverySequence: 5,
				part: { key: 'src/b', operation: 'put', revision: 10, value: 'latest-b' },
			}),
		);
		expect(visible.get(wire.subscriptionId)).toEqual(oldBank);
		accept(wire.complete('budget-replacement'));
		accept(abandonedPart);
		accept(abandonedComplete);
		expect(visible.get(wire.subscriptionId)).toEqual([
			{ key: 'src/a', revision: 11, value: 'latest-a' },
			{ key: 'src/b', revision: 10, value: 'latest-b' },
		]);
		const sibling = 'healthy-sibling';
		for (const frame of [
			wire.begin({ snapshotCause: 'open', batchId: 'sibling', targetRevision: 1, partCount: 1 }),
			wire.part({
				batchId: 'sibling',
				deliverySequence: 1,
				part: { key: 'src/sibling', operation: 'put', revision: 1, value: 'healthy' },
			}),
			wire.complete('sibling'),
		]) {
			accept(
				bridgeProductBatchFrameSchema.parse({
					...frame,
					subscriptionId: sibling,
					handle: 'sibling-handle',
					incarnation: 'sibling-incarnation',
				}),
			);
		}
		await completed.waitFor((batchId): boolean => batchId === 'sibling');
		expect(visible.get(sibling)).toEqual([{ key: 'src/sibling', revision: 1, value: 'healthy' }]);
		expect(resnapshots).toEqual([]);
		release.record('release');
		await completed.waitFor((batchId): boolean => batchId === 'slow-current');
		await Promise.all(pending);
		expect(visible.get(wire.subscriptionId)?.[0]?.value).toBe('latest-a');
		wire.finish();
	} finally {
		release.record('release');
		await Promise.all(pending);
		router.retireSubscription(wire.subscriptionId);
		router.retireSubscription('healthy-sibling');
		release.close(new Error('contract fixture closed'));
		completed.close(new Error('contract fixture closed'));
	}
}

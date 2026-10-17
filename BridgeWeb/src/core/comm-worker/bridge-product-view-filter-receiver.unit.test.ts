import { describe, expect, test } from 'vitest';

import { BridgeProductBatchFrameRouter } from './bridge-product-batch-frame-router.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { BridgeProductViewBatchReceiver } from './bridge-product-view-batch-receiver.js';
import { bridgeProductViewScopeSchema } from './bridge-product-view-control-wire-contracts.js';

const scopeA = bridgeProductViewScopeSchema.parse({
	kind: 'file',
	changeFilter: { kind: 'none' },
	interests: [],
	pathScope: [],
});
const scopeB = bridgeProductViewScopeSchema.parse({
	kind: 'file',
	changeFilter: { kind: 'changes', baseline: { kind: 'uncommitted' }, kinds: ['modified'] },
	interests: [],
	pathScope: [],
});
const frameIdentity = {
	domain: 'default',
	handle: 'file-filter-handle',
	incarnation: 'file-filter-incarnation',
	metadataStreamId: 'file-filter-stream',
	paneSessionId: 'file-filter-pane',
	subscriptionId: 'file-filter-subscription',
	subscriptionKind: 'file.metadata',
	wireVersion: 2,
	workerInstanceId: 'file-filter-worker',
} as const;

function fileReceiver(): BridgeProductViewBatchReceiver {
	const receiver = new BridgeProductViewBatchReceiver({
		handle: frameIdentity.handle,
		scope: scopeA,
		scopeRevision: 0,
		subscriptionId: frameIdentity.subscriptionId,
		subscriptionKind: 'file.metadata',
	});
	receiver.admitDomain(frameIdentity.domain, frameIdentity.incarnation);
	return receiver;
}

let nextStreamSequence = 1;

function installSnapshot(props: {
	readonly batchId: string;
	readonly receiver: BridgeProductViewBatchReceiver;
	readonly scope: typeof scopeA;
	readonly scopeRevision: number;
	readonly targetRevision: number;
	readonly value?: string;
}): void {
	const shared = {
		...frameIdentity,
		batchId: props.batchId,
		scopeRevision: props.scopeRevision,
	};
	expect(
		props.receiver.accept(
			bridgeProductBatchFrameSchema.parse({
				...shared,
				baseRevision: 0,
				kind: 'subscription.batchBegin',
				mode: 'snapshot',
				snapshotCause: 'open',
				partCount: props.value === undefined ? 0 : 1,
				scope: props.scope,
				streamSequence: nextStreamSequence++,
				targetRevision: props.targetRevision,
			}),
		).kind,
	).toBe('staged');
	if (props.value !== undefined) {
		expect(
			props.receiver.accept(
				bridgeProductBatchFrameSchema.parse({
					...shared,
					deliverySequence: props.targetRevision,
					kind: 'subscription.batchPart',
					part: { key: 'a', operation: 'put', revision: 1, value: props.value },
					partIndex: 0,
					streamSequence: nextStreamSequence++,
				}),
			).kind,
		).toBe('staged');
	}
	expect(
		props.receiver.accept(
			bridgeProductBatchFrameSchema.parse({
				...shared,
				coveredScope: props.scope,
				kind: 'subscription.batchComplete',
				streamSequence: nextStreamSequence++,
			}),
		).kind,
	).toBe('installed');
}

describe('File view filter applicability', () => {
	test('accepted filter fences an older snapshot before the first batch begin', () => {
		const installations: string[] = [];
		const router = new BridgeProductBatchFrameRouter({
			deadlineClock: { schedule: () => (): void => {} },
			progressDeadlineMilliseconds: 5_000,
		});
		router.setSinks({
			install: (installation): void => {
				installations.push(installation.begin.batchId);
			},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
		});
		router.acceptScope({
			scope: scopeB,
			scopeRevision: 1,
			subscriptionId: frameIdentity.subscriptionId,
		});
		router.accept(
			bridgeProductBatchFrameSchema.parse({
				...frameIdentity,
				batchId: 'old-filter-before-first-begin',
				baseRevision: 0,
				kind: 'subscription.batchBegin',
				mode: 'snapshot',
				snapshotCause: 'open',
				partCount: 0,
				scope: scopeA,
				scopeRevision: 0,
				streamSequence: nextStreamSequence++,
				targetRevision: 1,
			}),
		);
		router.accept(
			bridgeProductBatchFrameSchema.parse({
				...frameIdentity,
				batchId: 'old-filter-before-first-begin',
				coveredScope: scopeA,
				kind: 'subscription.batchComplete',
				scopeRevision: 0,
				streamSequence: nextStreamSequence++,
			}),
		);
		expect(installations).toEqual([]);
	});

	test('accepted filter change fences a previously staged snapshot before the next begin', () => {
		const installations: string[] = [];
		const router = new BridgeProductBatchFrameRouter({
			deadlineClock: { schedule: () => (): void => {} },
			progressDeadlineMilliseconds: 5_000,
		});
		router.setSinks({
			install: (installation): void => {
				installations.push(installation.begin.batchId);
			},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
		});
		const oldBegin = bridgeProductBatchFrameSchema.parse({
			...frameIdentity,
			batchId: 'staged-old-filter',
			baseRevision: 0,
			kind: 'subscription.batchBegin',
			mode: 'snapshot',
			snapshotCause: 'open',
			partCount: 0,
			scope: scopeA,
			scopeRevision: 0,
			streamSequence: nextStreamSequence++,
			targetRevision: 1,
		});
		router.accept(oldBegin);
		router.acceptScope({
			scope: scopeB,
			scopeRevision: 1,
			subscriptionId: frameIdentity.subscriptionId,
		});
		router.accept(
			bridgeProductBatchFrameSchema.parse({
				...frameIdentity,
				batchId: oldBegin.batchId,
				coveredScope: scopeA,
				kind: 'subscription.batchComplete',
				scopeRevision: 0,
				streamSequence: nextStreamSequence++,
			}),
		);
		expect(installations).toEqual([]);
	});

	test('ignores a snapshot sealed under an older change filter', () => {
		const receiver = fileReceiver();
		const oldBegin = bridgeProductBatchFrameSchema.parse({
			...frameIdentity,
			batchId: 'old-filter-snapshot',
			baseRevision: 0,
			kind: 'subscription.batchBegin',
			mode: 'snapshot',
			snapshotCause: 'open',
			partCount: 0,
			scope: scopeA,
			scopeRevision: 0,
			streamSequence: nextStreamSequence++,
			targetRevision: 1,
		});
		receiver.setScope(scopeB, 1);
		expect(receiver.accept(oldBegin).kind).toBe('ignored');
		expect(receiver.takeInstallations()).toEqual([]);
	});

	test('A to B to A restores a key at its unchanged record revision', () => {
		const receiver = fileReceiver();
		installSnapshot({
			batchId: 'scope-a-first',
			receiver,
			scope: scopeA,
			scopeRevision: 0,
			targetRevision: 1,
			value: 'A',
		});
		receiver.setScope(scopeB, 1);
		installSnapshot({
			batchId: 'scope-b',
			receiver,
			scope: scopeB,
			scopeRevision: 1,
			targetRevision: 2,
		});
		expect(receiver.records('default')).toEqual([]);
		receiver.setScope(scopeA, 2);
		installSnapshot({
			batchId: 'scope-a-return',
			receiver,
			scope: scopeA,
			scopeRevision: 2,
			targetRevision: 3,
			value: 'A',
		});
		expect(receiver.records('default')).toEqual([{ key: 'a', revision: 1, value: 'A' }]);
	});
});

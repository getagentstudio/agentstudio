import { expect, test } from 'vitest';

import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import { installBridgeProductBatchDelivery } from './bridge-product-batch-delivery.js';
import { BridgeProductBatchFrameRouter } from './bridge-product-batch-frame-router.js';
import {
	bridgeProductBatchFrameSchema,
	type BridgeProductBatchFrame,
	type BridgeProductSnapshotCause,
} from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import { bridgeProductSessionBootstrapSchema } from './bridge-product-session-contracts.js';
import { admitBridgeProductSnapshotBegin } from './bridge-product-snapshot-begin-admission.js';
import { ControlledBatchDeadlineClock } from './bridge-product-view-batch-receiver.test-support.js';
import { bridgeProductViewAcknowledgementRequestSchema } from './bridge-product-view-control-wire-contracts.js';
import { createTestViewScopeOwner } from './bridge-product-view-scope-owner.test-support.js';

const fileScope = {
	kind: 'file',
	changeFilter: { kind: 'none' },
	pathScope: [],
	interests: [],
} as const;
const viewIdentity = {
	handle: 'older-view',
	incarnation: 'older-view',
	subscriptionId: 'older-subscription',
	scopeRevision: 1,
} as const;
const bootstrap = bridgeProductSessionBootstrapSchema.parse(sessionCorpus.bootstrap);
const frameIdentity = {
	...viewIdentity,
	domain: 'default',
	metadataStreamId: 'older-stream',
	paneSessionId: bootstrap.paneSessionId,
	workerInstanceId: bootstrap.workerInstanceId,
	wireVersion: 2,
	subscriptionKind: 'file.metadata',
} as const;

type SnapshotBegin = Extract<BridgeProductBatchFrame, { kind: 'subscription.batchBegin' }>;

function snapshotBegin(
	cause: BridgeProductSnapshotCause,
	batchId: string,
	sequence: number,
	targetRevision = 1,
): SnapshotBegin {
	const frame = bridgeProductBatchFrameSchema.parse({
		...frameIdentity,
		kind: 'subscription.batchBegin',
		batchId,
		streamSequence: sequence,
		mode: 'snapshot',
		snapshotCause: cause,
		baseRevision: 0,
		targetRevision,
		partCount: 1,
		scope: fileScope,
	});
	if (frame.kind !== 'subscription.batchBegin') throw new Error('Expected snapshot begin.');
	return frame;
}

function batchPart(
	begin: SnapshotBegin,
	streamSequence: number,
	deliverySequence: number,
): BridgeProductBatchFrame {
	return bridgeProductBatchFrameSchema.parse({
		...frameIdentity,
		batchId: begin.batchId,
		kind: 'subscription.batchPart',
		streamSequence,
		deliverySequence,
		partIndex: 0,
		part: {
			key: 'retained',
			revision: begin.targetRevision,
			operation: 'put',
			value: begin.batchId,
		},
	});
}

function batchComplete(begin: SnapshotBegin, streamSequence: number): BridgeProductBatchFrame {
	return bridgeProductBatchFrameSchema.parse({
		...frameIdentity,
		batchId: begin.batchId,
		kind: 'subscription.batchComplete',
		streamSequence,
		coveredScope: fileScope,
	});
}

async function createOlderDemandHarness(beginClock?: BridgeProductDeadlineClock): Promise<{
	readonly owner: ReturnType<typeof createTestViewScopeOwner>;
	readonly router: BridgeProductBatchFrameRouter;
	readonly clock: ControlledBatchDeadlineClock;
	readonly installed: string[];
	readonly acknowledgedContainedPart: Promise<number>;
	readonly dispose: () => void;
}> {
	const clock = new ControlledBatchDeadlineClock();
	const acknowledgement = createBridgeProductDeferred<number>();
	const installed: string[] = [];
	let requestSequence = 0;
	const owner = createTestViewScopeOwner({
		createIdentifier: (): string => 'older-view',
		maximumConsecutiveResnapshots: 2,
		// W2's replacement-begin timers are outside this W4 staging/containment oracle.
		deadlineClock: beginClock ?? { schedule: (): (() => void) => (): void => {} },
		controlMux: {
			setViewScope: async (request) => ({
				...request,
				kind: 'subscription.scopeAccepted' as const,
				paneSessionId: bootstrap.paneSessionId,
				workerInstanceId: bootstrap.workerInstanceId,
				wireVersion: 2 as const,
				requestId: `scope-${++requestSequence}`,
				requestSequence,
			}),
			resnapshotView: async (request) => ({
				...request,
				kind: 'subscription.resnapshotAccepted' as const,
				paneSessionId: bootstrap.paneSessionId,
				workerInstanceId: bootstrap.workerInstanceId,
				wireVersion: 2 as const,
				requestId: `resnapshot-${++requestSequence}`,
				requestSequence,
			}),
		},
	});
	owner.register({
		scope: fileScope,
		subscriptionId: viewIdentity.subscriptionId,
		subscriptionKind: 'file.metadata',
	});
	await owner.setScope({ scope: fileScope, subscriptionId: viewIdentity.subscriptionId });
	const router = new BridgeProductBatchFrameRouter({
		deadlineClock: clock,
		progressDeadlineMilliseconds: 5000,
	});
	router.acceptScope({
		scope: fileScope,
		scopeRevision: 1,
		subscriptionId: viewIdentity.subscriptionId,
	});
	const delivery = installBridgeProductBatchDelivery({
		authority: { bootstrap, capabilityHeader: 'test-capability', open: Promise.resolve() },
		router,
		deadlineClock: { schedule: (): (() => void) => (): void => {} },
		executeProductRequest: async (_, init): Promise<Response> => {
			if (!(init.body instanceof Uint8Array)) throw new Error('Expected receipt bytes.');
			const request = bridgeProductViewAcknowledgementRequestSchema.parse(
				JSON.parse(new TextDecoder().decode(init.body)),
			);
			if (request.receivedThroughDeliverySequence === 2) acknowledgement.resolve(2);
			return new Response(JSON.stringify({ ...request, kind: 'subscription.acknowledged' }), {
				status: 200,
			});
		},
		sinks: {
			snapshotBeginAccepted: (frame): boolean =>
				admitBridgeProductSnapshotBegin({ frame, owner, notify: undefined }),
			install: (installation): void => {
				installed.push(installation.begin.batchId);
				if (installation.begin.mode === 'snapshot')
					owner.recordCertifiedInstall(installation.begin);
			},
			receipt: (): void => {},
			resnapshot: (): void => {
				throw new Error('Expected valid batch.');
			},
			resnapshotLatest: (): void => {
				throw new Error('Progress deadline must not fire.');
			},
		},
	});
	const initial = snapshotBegin('open', 'initial-bank', 1);
	router.accept(initial);
	router.accept(batchPart(initial, 2, 1));
	router.accept(batchComplete(initial, 3));
	expect(owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
		status: 'ready',
		consecutiveResnapshots: 0,
	});
	return {
		owner,
		router,
		clock,
		installed,
		acknowledgedContainedPart: acknowledgement.promise,
		dispose: (): void => {
			delivery.close();
			router.retireSubscription(viewIdentity.subscriptionId);
			owner.retire(viewIdentity.subscriptionId);
		},
	};
}

async function replaceSameFilterDemand(
	harness: Awaited<ReturnType<typeof createOlderDemandHarness>>,
): Promise<void> {
	const scope = {
		...fileScope,
		interests: [{ lane: 'visible' as const, paths: ['src/current.ts'] }],
	};
	const settlement = await harness.owner.setScope({
		scope,
		subscriptionId: viewIdentity.subscriptionId,
	});
	if (settlement.kind !== 'accepted') throw new Error('Expected current demand admission.');
	harness.router.acceptScope({
		scope,
		scopeRevision: settlement.scopeRevision,
		subscriptionId: viewIdentity.subscriptionId,
	});
}

test('an accepted older same-filter recovery begin charges exactly once, including an exact duplicate', async (): Promise<void> => {
	const harness = await createOlderDemandHarness();
	try {
		await replaceSameFilterDemand(harness);
		const begin = snapshotBegin('recovery', 'older-recovery', 4, 2);
		harness.router.accept(begin);
		expect(harness.owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
			status: 'recovering',
			consecutiveResnapshots: 1,
		});
		harness.router.accept(begin);
		expect(harness.owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(
			1,
		);
	} finally {
		harness.dispose();
	}
});

test.each(['recovery', 'requested'] as const)(
	'Failed contains an accepted older-demand %s begin: credit returns without stage, install, deadline or reopening',
	async (cause): Promise<void> => {
		const harness = await createOlderDemandHarness();
		try {
			for (let attempt = 0; attempt < 3; attempt += 1)
				harness.router.accept(snapshotBegin('recovery', `failed-${attempt}`, 4 + attempt, 2));
			expect(harness.owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
				status: 'failedRetryable',
				consecutiveResnapshots: 2,
			});
			await replaceSameFilterDemand(harness);
			const scheduleCount = harness.clock.deadlines.length;
			const begin = snapshotBegin(cause, 'contained-older-demand', 7, 3);
			harness.router.accept(begin);
			expect.soft(harness.clock.deadlines.length).toBe(scheduleCount);
			expect.soft(harness.clock.deadlines.some((deadline) => deadline.active)).toBe(false);
			harness.router.accept(batchPart(begin, 8, 2));
			expect(await harness.acknowledgedContainedPart).toBe(2);
			harness.router.accept(batchComplete(begin, 9));
			expect(harness.installed).toEqual(['initial-bank']);
			expect(harness.owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
				status: 'failedRetryable',
				consecutiveResnapshots: 2,
			});
		} finally {
			harness.dispose();
		}
	},
);

test.each(['requested', 'recovery'] as const)(
	'older-demand newerInput keeps the outstanding request until %s consumes it once',
	async (cause): Promise<void> => {
		const harness = await createOlderDemandHarness();
		try {
			await harness.owner.resnapshot(viewIdentity.subscriptionId);
			await replaceSameFilterDemand(harness);
			harness.router.accept(snapshotBegin('newerInput', 'changed-input', 4, 2));
			expect(harness.owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(
				1,
			);
			harness.router.accept(snapshotBegin(cause, 'requested-replacement', 5, 3));
			expect(harness.owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(
				1,
			);
			harness.router.accept(snapshotBegin('recovery', 'next-unsuccessful', 6, 4));
			expect(harness.owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(
				2,
			);
		} finally {
			harness.dispose();
		}
	},
);

test('an older open cannot renew or clear an outstanding request at begin; current open still renews', async (): Promise<void> => {
	const harness = await createOlderDemandHarness();
	try {
		await harness.owner.resnapshot(viewIdentity.subscriptionId);
		await replaceSameFilterDemand(harness);
		harness.router.accept(snapshotBegin('open', 'older-open', 4, 2));
		expect(harness.owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(
			1,
		);
		harness.router.accept(snapshotBegin('recovery', 'fulfills-current-request', 5, 3));
		expect(harness.owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(
			1,
		);
		harness.router.accept(snapshotBegin('recovery', 'next-recovery', 6, 4));
		expect(harness.owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(
			2,
		);
		const current = bridgeProductBatchFrameSchema.parse({
			...snapshotBegin('open', 'current-open', 7, 5),
			scopeRevision: 2,
		});
		harness.router.accept(current);
		expect(harness.owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(
			0,
		);
	} finally {
		harness.dispose();
	}
});

test.each(['path-scope', 'change-filter'] as const)(
	'a READY File %s change keeps its mandatory snapshot begin deadline and recovery charge',
	async (filterChange): Promise<void> => {
		const beginClock = new ControlledBatchDeadlineClock();
		const harness = await createOlderDemandHarness(beginClock);
		try {
			const scope =
				filterChange === 'path-scope'
					? { ...fileScope, pathScope: ['src'] }
					: {
							...fileScope,
							changeFilter: {
								kind: 'changes' as const,
								baseline: { kind: 'uncommitted' as const },
								kinds: ['modified' as const],
							},
						};
			await harness.owner.setScope({ scope, subscriptionId: viewIdentity.subscriptionId });
			expect(harness.owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
				status: 'recovering',
				consecutiveResnapshots: 0,
			});
			beginClock.activeDeadline().fire();
			// A duplicate joins the operation issued by the deadline, never starts another one.
			await harness.owner.resnapshot(viewIdentity.subscriptionId);
			expect(harness.owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
				status: 'recovering',
				consecutiveResnapshots: 1,
			});
			expect(beginClock.activeDeadline().active).toBe(true);
		} finally {
			harness.dispose();
		}
	},
);

test('ordinary same-filter File demand arms no W2 timer and remains ready through deadline expiry', async (): Promise<void> => {
	const beginClock = new ControlledBatchDeadlineClock();
	const harness = await createOlderDemandHarness(beginClock);
	try {
		const scheduleCount = beginClock.deadlines.length;
		await replaceSameFilterDemand(harness);
		expect(beginClock.deadlines).toHaveLength(scheduleCount);
		expect(beginClock.deadlines.some((deadline) => deadline.active)).toBe(false);
		// Fire any erroneously armed begin deadline as a controlled subject, never wait for time.
		for (const deadline of beginClock.deadlines) if (deadline.active) deadline.fire();
		expect(harness.owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
			status: 'ready',
			consecutiveResnapshots: 0,
		});
	} finally {
		harness.dispose();
	}
});

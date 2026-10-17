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
import { bridgeProductSessionBootstrapSchema } from './bridge-product-session-contracts.js';
import { BridgeProductViewBatchReceiver } from './bridge-product-view-batch-receiver.js';
import { ControlledBatchDeadlineClock } from './bridge-product-view-batch-receiver.test-support.js';
import { bridgeProductViewAcknowledgementRequestSchema } from './bridge-product-view-control-wire-contracts.js';
import { createTestViewScopeOwner } from './bridge-product-view-scope-owner.test-support.js';

const viewIdentity = {
	handle: 'cause-view',
	incarnation: 'cause-view',
	scopeRevision: 0,
	subscriptionId: 'cause-subscription',
} as const;
const fileScope = {
	kind: 'file',
	changeFilter: { kind: 'none' },
	interests: [],
	pathScope: [],
} as const;
const frameIdentity = {
	...viewIdentity,
	domain: 'default',
	metadataStreamId: 'stream',
	paneSessionId: 'pane',
	subscriptionKind: 'file.metadata',
	wireVersion: 2,
	workerInstanceId: 'worker',
} as const;
const clock = { schedule: (): (() => void) => (): void => {} };

function harness(maximum = 2): {
	readonly owner: ReturnType<typeof createTestViewScopeOwner>;
	readonly requests: string[];
	readonly statuses: string[];
} {
	const requests: string[] = [];
	const statuses: string[] = [];
	const owner = createTestViewScopeOwner({
		createIdentifier: (): string => 'cause-view',
		maximumConsecutiveResnapshots: maximum,
		onViewRecoveryStatus: ({ status }): void => {
			statuses.push(status);
		},
		controlMux: {
			setViewScope: async (): Promise<never> => {
				throw new Error('Scope not changed.');
			},
			resnapshotView: async (props) => {
				requests.push(props.subscriptionId);
				return {
					...props,
					kind: 'subscription.resnapshotAccepted' as const,
					paneSessionId: 'pane',
					requestId: 'resnapshot',
					requestSequence: requests.length,
					wireVersion: 2 as const,
					workerInstanceId: 'worker',
				};
			},
		},
	});
	owner.register({
		scope: fileScope,
		subscriptionId: viewIdentity.subscriptionId,
		subscriptionKind: 'file.metadata',
	});
	return { owner, requests, statuses };
}
function begin(
	cause: BridgeProductSnapshotCause,
	batchId = 'initial',
	target = 1,
	sequence = 1,
): Extract<BridgeProductBatchFrame, { kind: 'subscription.batchBegin' }> {
	const frame = bridgeProductBatchFrameSchema.parse({
		...frameIdentity,
		batchId,
		kind: 'subscription.batchBegin',
		mode: 'snapshot',
		snapshotCause: cause,
		baseRevision: 0,
		targetRevision: target,
		partCount: 1,
		scope: fileScope,
		streamSequence: sequence,
	});
	if (frame.kind !== 'subscription.batchBegin') throw new Error('Expected begin.');
	return frame;
}
function complete(batchId: string, sequence: number): BridgeProductBatchFrame {
	return bridgeProductBatchFrameSchema.parse({
		...frameIdentity,
		batchId,
		kind: 'subscription.batchComplete',
		coveredScope: fileScope,
		streamSequence: sequence,
	});
}
function part(
	batchId: string,
	deliverySequence: number,
	sequence: number,
): BridgeProductBatchFrame {
	return bridgeProductBatchFrameSchema.parse({
		...frameIdentity,
		batchId,
		kind: 'subscription.batchPart',
		deliverySequence,
		streamSequence: sequence,
		partIndex: 0,
		part: { key: 'a', revision: 1, operation: 'put', value: batchId },
	});
}
function receiver(): BridgeProductViewBatchReceiver {
	const state = new BridgeProductViewBatchReceiver({
		handle: viewIdentity.handle,
		scope: fileScope,
		scopeRevision: 0,
		subscriptionId: viewIdentity.subscriptionId,
		subscriptionKind: 'file.metadata',
	});
	state.admitDomain('default', viewIdentity.incarnation);
	return state;
}

test.each(['requested', 'recovery'] as const)(
	'newer input preserves an outstanding request until %s satisfies it, without double charge',
	async (cause): Promise<void> => {
		const { owner } = harness(3);
		try {
			await owner.resnapshot(viewIdentity.subscriptionId);
			owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'newerInput' });
			owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: cause });
			expect(owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
				consecutiveResnapshots: 1,
				status: 'recovering',
			});
		} finally {
			owner.retire(viewIdentity.subscriptionId);
		}
	},
);

test('native recovery with no prior bank consumes the allowed attempts then immediately contains the next, without worker requests', (): void => {
	const { owner, requests, statuses } = harness();
	try {
		expect(owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' })).toBe(true);
		expect(owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' })).toBe(true);
		expect(owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' })).toBe(false);
		expect(owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
			consecutiveResnapshots: 2,
			status: 'failedRetryable',
		});
		expect(requests).toEqual([]);
		expect(statuses).toEqual(['recovering', 'failedRetryable']);
		expect(owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'requested' })).toBe(false);
		expect(owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'newerInput' })).toBe(true);
		expect(statuses).toEqual(['recovering', 'failedRetryable']);
		owner.recordCertifiedInstall({ ...viewIdentity, handle: 'stale-handle' });
		expect(owner.recoveryState(viewIdentity.subscriptionId)?.status).toBe('failedRetryable');
		owner.recordCertifiedInstall(viewIdentity);
		expect(owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
			consecutiveResnapshots: 0,
			status: 'ready',
		});
	} finally {
		owner.retire(viewIdentity.subscriptionId);
	}
});

test.each(['open', 'retry'] as const)(
	'%s is an explicit exit from failed containment',
	async (restart): Promise<void> => {
		const { owner, requests } = harness(1);
		try {
			owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' });
			owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' });
			if (restart === 'open') {
				expect(owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'open' })).toBe(true);
				expect(requests).toEqual([]);
			} else {
				await owner.retryView(viewIdentity.subscriptionId);
				expect(requests).toHaveLength(1);
			}
			expect(owner.recoveryState(viewIdentity.subscriptionId)?.status).toBe('recovering');
		} finally {
			owner.retire(viewIdentity.subscriptionId);
		}
	},
);

test('stale open cannot satisfy a current outstanding request', async (): Promise<void> => {
	const { owner } = harness(3);
	try {
		await owner.resnapshot(viewIdentity.subscriptionId);
		owner.observeSnapshotBegin({ ...viewIdentity, scopeRevision: 1, snapshotCause: 'open' });
		owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' });
		expect(owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(1);
	} finally {
		owner.retire(viewIdentity.subscriptionId);
	}
});

test('a current open after Failed renews the budget so the next stall sends one request', async (): Promise<void> => {
	const { owner, requests } = harness(2);
	try {
		owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' });
		owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' });
		owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' });
		expect(owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
			consecutiveResnapshots: 2,
			status: 'failedRetryable',
		});
		owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'open' });
		await owner.resnapshot(viewIdentity.subscriptionId);
		expect(requests).toHaveLength(1);
		expect(owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
			consecutiveResnapshots: 1,
			status: 'recovering',
		});
	} finally {
		owner.retire(viewIdentity.subscriptionId);
	}
});

test('a current open renews its budget and clears the outstanding request', async (): Promise<void> => {
	const { owner } = harness(3);
	try {
		await owner.resnapshot(viewIdentity.subscriptionId);
		owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'open' });
		expect(owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(0);
		owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' });
		expect(owner.recoveryState(viewIdentity.subscriptionId)?.consecutiveResnapshots).toBe(1);
	} finally {
		owner.retire(viewIdentity.subscriptionId);
	}
});

test('native recovery with a prior installed bank contains the excess attempt and retains that bank', (): void => {
	const { owner } = harness();
	const state = receiver();
	const admit = (
		frame: Extract<BridgeProductBatchFrame, { kind: 'subscription.batchBegin' }>,
	): boolean => {
		if (frame.snapshotCause === undefined) throw new Error('Expected cause.');
		return owner.observeSnapshotBegin({ ...frame, snapshotCause: frame.snapshotCause });
	};
	try {
		state.accept(begin('open'), undefined, admit);
		state.accept(part('initial', 1, 2));
		state.accept(complete('initial', 3));
		owner.recordCertifiedInstall(viewIdentity);
		state.accept(begin('recovery', 'recovery-1', 1, 4), undefined, admit);
		state.accept(begin('recovery', 'recovery-2', 1, 5), undefined, admit);
		const contained = begin('recovery', 'recovery-3', 1, 6);
		expect(state.accept(contained, undefined, admit)).toEqual({
			kind: 'ignored',
			snapshotContained: true,
		});
		expect(state.hasIncompleteStage(contained)).toBe(false);
		expect(state.records('default')).toEqual([{ key: 'a', revision: 1, value: 'initial' }]);
		expect(owner.recoveryState(viewIdentity.subscriptionId)?.status).toBe('failedRetryable');
	} finally {
		owner.retire(viewIdentity.subscriptionId);
	}
});

test('a queued pre-failure newer-input bank leaves Failed only when its install is certified', async (): Promise<void> => {
	const { owner, requests } = harness(1);
	const state = receiver();
	try {
		const queued = begin('newerInput');
		state.accept(queued);
		await owner.resnapshot(viewIdentity.subscriptionId);
		await owner.resnapshot(viewIdentity.subscriptionId);
		expect(owner.recoveryState(viewIdentity.subscriptionId)?.status).toBe('failedRetryable');
		state.accept(part('initial', 1, 2));
		state.accept(complete('initial', 3));
		const installation = state.takeInstallations()[0];
		if (installation === undefined) throw new Error('Expected queued snapshot install.');
		owner.recordCertifiedInstall(installation.begin);
		expect(owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
			consecutiveResnapshots: 0,
			status: 'ready',
		});
		expect(requests).toHaveLength(1);
	} finally {
		owner.retire(viewIdentity.subscriptionId);
	}
});

test('ignored stale and duplicate snapshot begins neither report causes nor change current progress', (): void => {
	const deadlines = new ControlledBatchDeadlineClock();
	const router = new BridgeProductBatchFrameRouter({
		deadlineClock: deadlines,
		progressDeadlineMilliseconds: 5000,
	});
	const causes: string[] = [];
	router.setSinks({
		install: (): void => {},
		receipt: (): void => {},
		resnapshot: (): void => {},
		resnapshotLatest: (): void => {},
		snapshotBeginAccepted: (frame): void => {
			if (frame.snapshotCause !== undefined) causes.push(frame.snapshotCause);
		},
	});
	const current = begin('open', 'current', 2, 5);
	router.accept(current);
	const deadline = deadlines.activeDeadline();
	router.accept(current);
	router.accept(begin('recovery', 'stale', 2, 4));
	expect(deadlines.activeDeadline()).toBe(deadline);
	expect(causes).toEqual(['open']);
	router.retireSubscription(viewIdentity.subscriptionId);
});

test.each([
	{ mode: 'snapshot' },
	{ mode: 'change', snapshotCause: 'open' },
	{ mode: 'snapshot', snapshotCause: 'unknown' },
	{ mode: 'coverage', snapshotCause: 'requested' },
])('rejects invalid cause shape $mode/$snapshotCause', (shape): void => {
	const { snapshotCause: _cause, ...uncategorized } = begin('open');
	expect(bridgeProductBatchFrameSchema.safeParse({ ...uncategorized, ...shape }).success).toBe(
		false,
	);
});

test('every fresh current snapshot reports its cause, while duplicate/stale/ignored begins do not', (): void => {
	const state = receiver();
	const initial = begin('open');
	expect(state.accept(initial)).toEqual({ kind: 'staged', snapshotCause: 'open' });
	expect(state.accept(initial)).toEqual({ kind: 'staged' });
	state.accept(part('initial', 1, 2));
	state.accept(complete('initial', 3));
	expect(state.accept(initial)).toEqual({ kind: 'ignored' });
	expect(state.accept(begin('recovery', 'stale', 0, 4))).toEqual({ kind: 'ignored' });
	expect(state.accept(begin('newerInput', 'fresh', 2, 5))).toEqual({
		kind: 'staged',
		snapshotCause: 'newerInput',
	});
});

test.each(['change', 'coverage'] as const)(
	'%s after expiry is neither a snapshot nor a charge',
	(mode): void => {
		const state = receiver();
		state.accept(begin('open'));
		state.accept(part('initial', 1, 2));
		state.accept(complete('initial', 3));
		const pending = begin('newerInput', 'pending', 2, 4);
		state.accept(pending);
		state.abandonIncompleteStage(pending);
		const { snapshotCause: _cause, ...withoutCause } = begin('open', 'next', 2, 5);
		expect(
			state.accept(bridgeProductBatchFrameSchema.parse({ ...withoutCause, mode, baseRevision: 1 })),
		).toEqual({ kind: 'staged' });
	},
);

test('contained recovery/requested banks return stream credits but never stage, install, or arm progress', async (): Promise<void> => {
	const { owner, requests, statuses } = harness(1);
	owner.observeSnapshotBegin({ ...viewIdentity, snapshotCause: 'recovery' });
	const ack = createBridgeProductDeferred<number>();
	const requestedAck = createBridgeProductDeferred<number>();
	const installed: string[] = [];
	let schedules = 0;
	const trackingClock = {
		schedule: (): (() => void) => {
			schedules += 1;
			return (): void => {};
		},
	};
	const router = new BridgeProductBatchFrameRouter({
		deadlineClock: trackingClock,
		progressDeadlineMilliseconds: 5000,
	});
	const bootstrap = bridgeProductSessionBootstrapSchema.parse(sessionCorpus.bootstrap);
	const acknowledger = installBridgeProductBatchDelivery({
		authority: { bootstrap, capabilityHeader: 'test-capability', open: Promise.resolve() },
		deadlineClock: clock,
		router,
		executeProductRequest: async (_, init): Promise<Response> => {
			if (!(init.body instanceof Uint8Array)) throw new Error('Expected ACK bytes.');
			const request = bridgeProductViewAcknowledgementRequestSchema.parse(
				JSON.parse(new TextDecoder().decode(init.body)),
			);
			ack.resolve(request.receivedThroughDeliverySequence);
			if (request.receivedThroughDeliverySequence === 2) requestedAck.resolve(2);
			return new Response(JSON.stringify({ ...request, kind: 'subscription.acknowledged' }), {
				status: 200,
			});
		},
		sinks: {
			snapshotBeginAccepted: (frame): boolean => {
				if (frame.snapshotCause === undefined) throw new Error('Expected snapshot cause.');
				return owner.observeSnapshotBegin({ ...frame, snapshotCause: frame.snapshotCause });
			},
			install: (installation): void => {
				installed.push(installation.begin.batchId);
				owner.recordCertifiedInstall(installation.begin);
			},
			receipt: (): void => {},
			resnapshot: (): void => {
				throw new Error('Contained bank must not resnapshot.');
			},
			resnapshotLatest: (): void => {
				throw new Error('Contained bank must not arm progress.');
			},
		},
	});
	try {
		router.accept(begin('recovery', 'contained', 1, 1));
		router.accept(part('contained', 1, 2));
		router.accept(complete('contained', 3));
		expect(await ack.promise).toBe(1);
		expect(installed).toEqual([]);
		expect(schedules).toBe(0);
		router.accept(begin('requested', 'requested-contained', 1, 4));
		router.accept(part('requested-contained', 2, 5));
		router.accept(complete('requested-contained', 6));
		expect(await requestedAck.promise).toBe(2);
		expect(installed).toEqual([]);
		expect(schedules).toBe(0);
		expect(requests).toEqual([]);
		expect(statuses).toEqual(['recovering', 'failedRetryable']);
		router.accept(begin('newerInput', 'equal-target', 1, 7));
		expect(owner.recoveryState(viewIdentity.subscriptionId)?.status).toBe('failedRetryable');
		router.accept(part('equal-target', 3, 8));
		router.accept(complete('equal-target', 9));
		expect(installed).toEqual(['equal-target']);
		expect(owner.recoveryState(viewIdentity.subscriptionId)).toEqual({
			consecutiveResnapshots: 0,
			status: 'ready',
		});
	} finally {
		acknowledger.close();
		router.retireSubscription(viewIdentity.subscriptionId);
		owner.retire(viewIdentity.subscriptionId);
	}
});

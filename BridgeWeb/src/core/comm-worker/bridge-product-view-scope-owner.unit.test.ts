import { describe, expect, test } from 'vitest';

import { BridgeProductControlAdmissionQueue } from './bridge-product-control-admission-queue.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import type { BridgeProductControlMux } from './bridge-product-session-authority.js';
import type {
	ViewResnapshotAdmissionProps,
	ViewScopeAdmissionProps,
} from './bridge-product-view-control-admission.js';
import { createTestViewScopeOwner } from './bridge-product-view-scope-owner.test-support.js';

const emptyFileScope = {
	changeFilter: { kind: 'none' },
	interests: [],
	kind: 'file',
	pathScope: [],
} as const;

class ControlledReplacementBeginClock implements BridgeProductDeadlineClock {
	readonly deadlines: Array<{ active: boolean; delayMilliseconds: number; fire: () => void }> = [];
	readonly #scheduleWaiters: Array<{ count: number; resolve: () => void }> = [];

	schedule(delayMilliseconds: number, onDeadline: () => void): () => void {
		const deadline = {
			active: true,
			delayMilliseconds,
			fire: (): void => {
				if (!deadline.active) throw new Error('Expected an armed replacement-begin deadline.');
				deadline.active = false;
				onDeadline();
			},
		};
		this.deadlines.push(deadline);
		for (const waiter of this.#scheduleWaiters.filter(
			(candidate) => candidate.count <= this.deadlines.length,
		)) {
			waiter.resolve();
		}
		this.#scheduleWaiters.splice(
			0,
			this.#scheduleWaiters.length,
			...this.#scheduleWaiters.filter((candidate) => candidate.count > this.deadlines.length),
		);
		return (): void => {
			deadline.active = false;
		};
	}

	waitForScheduleCount(count: number): Promise<void> {
		if (this.deadlines.length >= count) return Promise.resolve();
		return new Promise((resolve): void => {
			this.#scheduleWaiters.push({ count, resolve });
		});
	}

	activeDeadline(): (typeof this.deadlines)[number] {
		const deadline = this.deadlines.find((candidate) => candidate.active);
		if (deadline === undefined) throw new Error('Expected an active replacement-begin deadline.');
		return deadline;
	}
}

describe('W2 desired view scope owner', () => {
	test.each([
		'file.metadata',
		'review.metadata',
		'file.annotations',
		'review.annotations',
	] as const)(
		'a fresh %s scope stays recovering until certified installation',
		async (subscriptionKind) => {
			const scope =
				subscriptionKind === 'file.metadata'
					? emptyFileScope
					: subscriptionKind === 'review.metadata'
						? ({ kind: 'review', interests: [] } as const)
						: ({ kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' } as const);
			const owner = createTestViewScopeOwner({
				controlMux: {
					setViewScope: async (props) => acceptedScope(props),
					resnapshotView: async (props) => acceptedResnapshot(props),
				},
				createIdentifier: (): string => 'fresh-view',
				maximumConsecutiveResnapshots: 2,
			});
			owner.register({ scope, subscriptionId: 'fresh-subscription', subscriptionKind });
			await owner.setScope({ scope, subscriptionId: 'fresh-subscription' });
			expect(owner.recoveryState('fresh-subscription')?.status).toBe('recovering');
			owner.recordCertifiedInstall({
				handle: 'fresh-view',
				incarnation: 'fresh-view',
				scopeRevision: 1,
				subscriptionId: 'fresh-subscription',
			});
			expect(owner.recoveryState('fresh-subscription')?.status).toBe('ready');
			owner.retire('fresh-subscription');
		},
	);

	test('initial accepted scope with no first begin exhausts its bounded recovery and offers Retry', async () => {
		const clock = new ControlledReplacementBeginClock();
		const requests: ViewResnapshotAdmissionProps[] = [];
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => acceptedScope(props),
				resnapshotView: async (props) => {
					requests.push(props);
					return acceptedResnapshot(props);
				},
			},
			createIdentifier: (): string => 'initial-view',
			deadlineClock: clock,
			maximumConsecutiveResnapshots: 1,
			progressDeadlineMilliseconds: 5_000,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'initial-file',
			subscriptionKind: 'file.metadata',
		});
		expect(await owner.setScope({ scope: emptyFileScope, subscriptionId: 'initial-file' })).toEqual(
			{
				kind: 'accepted',
				scopeRevision: 1,
			},
		);

		clock.activeDeadline().fire();
		await clock.waitForScheduleCount(2);
		expect(requests).toHaveLength(1);
		clock.activeDeadline().fire();
		expect(owner.recoveryState('initial-file')).toEqual({
			consecutiveResnapshots: 1,
			status: 'failedRetryable',
		});
	});

	test('demand replacement after accepted resnapshot keeps the no-begin deadline and budget', async () => {
		const clock = new ControlledReplacementBeginClock();
		const requests: ViewResnapshotAdmissionProps[] = [];
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => acceptedScope(props),
				resnapshotView: async (props) => {
					requests.push(props);
					return acceptedResnapshot(props);
				},
			},
			createIdentifier: (): string => 'replacement-view',
			deadlineClock: clock,
			maximumConsecutiveResnapshots: 2,
			progressDeadlineMilliseconds: 5_000,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'replacement-file',
			subscriptionKind: 'file.metadata',
		});
		await owner.setScope({ scope: emptyFileScope, subscriptionId: 'replacement-file' });
		await owner.resnapshot('replacement-file');
		await owner.setScope({
			scope: { ...emptyFileScope, pathScope: ['new-selection'] },
			subscriptionId: 'replacement-file',
		});

		clock.activeDeadline().fire();
		await clock.waitForScheduleCount(4);
		expect(requests.map((request) => request.scopeRevision)).toEqual([1, 2]);
		clock.activeDeadline().fire();
		expect(owner.recoveryState('replacement-file')).toEqual({
			consecutiveResnapshots: 2,
			status: 'failedRetryable',
		});
	});

	test('Comment initial opening and pending resnapshot retain their begin obligation across demand', async () => {
		const clock = new ControlledReplacementBeginClock();
		const requests: ViewResnapshotAdmissionProps[] = [];
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => acceptedScope(props),
				resnapshotView: async (props) => {
					requests.push(props);
					return acceptedResnapshot(props);
				},
			},
			createIdentifier: (): string => 'comment-view',
			deadlineClock: clock,
			maximumConsecutiveResnapshots: 2,
		});
		const initialScope = { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' } as const;
		owner.register({
			scope: initialScope,
			subscriptionId: 'comment-subscription',
			subscriptionKind: 'file.annotations',
		});
		await owner.setScope({ scope: initialScope, subscriptionId: 'comment-subscription' });
		expect(clock.activeDeadline().active).toBe(true);
		owner.recordCertifiedInstall({
			handle: 'comment-view',
			incarnation: 'comment-view',
			scopeRevision: 1,
			subscriptionId: 'comment-subscription',
		});
		await owner.resnapshot('comment-subscription');
		await owner.setScope({
			scope: { ...initialScope, sessionIds: ['session-1'] },
			subscriptionId: 'comment-subscription',
		});
		clock.activeDeadline().fire();
		await clock.waitForScheduleCount(4);
		expect(requests.map((request) => request.scopeRevision)).toEqual([1, 2]);
		clock.activeDeadline().fire();
		expect(owner.recoveryState('comment-subscription')).toEqual({
			consecutiveResnapshots: 2,
			status: 'failedRetryable',
		});
	});

	test('a replacement begin observed before scope acceptance does not arm a stale deadline', async () => {
		const clock = new ControlledReplacementBeginClock();
		let releaseAdmission = (): void => {};
		const heldAdmission = new Promise<void>((resolve): void => {
			releaseAdmission = resolve;
		});
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => {
					await heldAdmission;
					return acceptedScope(props);
				},
				resnapshotView: async (props) => acceptedResnapshot(props),
			},
			createIdentifier: (): string => 'early-begin-view',
			deadlineClock: clock,
			maximumConsecutiveResnapshots: 2,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'early-begin-file',
			subscriptionKind: 'file.metadata',
		});
		const opening = owner.setScope({ scope: emptyFileScope, subscriptionId: 'early-begin-file' });
		owner.observeReplacementSnapshot({
			handle: 'early-begin-view',
			incarnation: 'early-begin-view',
			scopeRevision: 1,
			subscriptionId: 'early-begin-file',
		});
		releaseAdmission();
		expect(await opening).toEqual({ kind: 'accepted', scopeRevision: 1 });
		expect(clock.deadlines.every((deadline) => !deadline.active)).toBe(true);
	});

	test('render exhaustion fails only the Review metadata view and its Retry uses the existing resnapshot', async () => {
		const statuses: string[] = [];
		const requests: ViewResnapshotAdmissionProps[] = [];
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => acceptedScope(props),
				resnapshotView: async (props) => {
					requests.push(props);
					return acceptedResnapshot(props);
				},
			},
			createIdentifier: (): string => 'view-identity',
			maximumConsecutiveResnapshots: 2,
			onViewRecoveryStatus: (status): void => {
				statuses.push(`${status.view.subscriptionId}:${status.status}`);
			},
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-1',
			subscriptionKind: 'file.metadata',
		});
		owner.register({
			scope: { kind: 'review', interests: [] },
			subscriptionId: 'review-1',
			subscriptionKind: 'review.metadata',
		});
		owner.failViewsOfKind('review.metadata');
		expect(owner.recoveryState('review-1')?.status).toBe('failedRetryable');
		expect(owner.recoveryState('file-1')?.status).toBe('recovering');
		expect(statuses).toContain('review-1:failedRetryable');
		expect(requests).toHaveLength(0);
		await owner.retryView('review-1');
		expect(owner.recoveryState('review-1')?.status).toBe('recovering');
		expect(requests).toHaveLength(1);
	});

	test('accepted resnapshots without replacement begins exhaust the view budget and Retry rearms it', async () => {
		const clock = new ControlledReplacementBeginClock();
		const requests: ViewResnapshotAdmissionProps[] = [];
		const statuses: string[] = [];
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => acceptedScope(props),
				resnapshotView: async (props) => {
					requests.push(props);
					return acceptedResnapshot(props);
				},
			},
			createIdentifier: (): string => 'view-identity',
			deadlineClock: clock,
			maximumConsecutiveResnapshots: 2,
			onViewRecoveryStatus: (status): void => {
				statuses.push(`${status.view.subscriptionId}:${status.status}`);
			},
			progressDeadlineMilliseconds: 5_000,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-1',
			subscriptionKind: 'file.metadata',
		});
		owner.register({
			scope: { kind: 'review', interests: [] },
			subscriptionId: 'review-1',
			subscriptionKind: 'review.metadata',
		});

		await owner.resnapshot('file-1');
		expect(clock.activeDeadline().delayMilliseconds).toBe(5_000);
		clock.activeDeadline().fire();
		await clock.waitForScheduleCount(2);
		expect(requests).toHaveLength(2);
		clock.activeDeadline().fire();
		expect(owner.recoveryState('file-1')).toEqual({
			consecutiveResnapshots: 2,
			status: 'failedRetryable',
		});
		expect(owner.recoveryState('review-1')).toEqual({
			consecutiveResnapshots: 0,
			status: 'recovering',
		});
		expect(statuses).toContain('file-1:failedRetryable');
		await owner.retryView('file-1');
		expect(requests).toHaveLength(3);
		expect(owner.recoveryState('file-1')).toEqual({
			consecutiveResnapshots: 1,
			status: 'recovering',
		});
		owner.retire('file-1');
		expect(clock.deadlines.every((deadline) => !deadline.active)).toBe(true);
	});

	test('a certified Review install under older demand resets recovery without changing latest scope', async () => {
		const scopes: ViewScopeAdmissionProps[] = [];
		const clock = new ControlledReplacementBeginClock();
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => {
					scopes.push(props);
					return acceptedScope(props);
				},
				resnapshotView: async (props) => acceptedResnapshot(props),
			},
			createIdentifier: (): string => 'review-view-identity',
			deadlineClock: clock,
			maximumConsecutiveResnapshots: 2,
		});
		owner.register({
			scope: { kind: 'review', interests: [] },
			subscriptionId: 'review-subscription-1',
			subscriptionKind: 'review.metadata',
		});
		await owner.setScope({
			scope: { kind: 'review', interests: [{ lane: 'visible', itemIds: ['item-1'] }] },
			subscriptionId: 'review-subscription-1',
		});
		owner.observeReplacementSnapshot({
			handle: 'review-view-identity',
			incarnation: 'review-view-identity',
			scopeRevision: 1,
			subscriptionId: 'review-subscription-1',
		});
		await owner.setScope({
			scope: { kind: 'review', interests: [{ lane: 'foreground', itemIds: ['item-1'] }] },
			subscriptionId: 'review-subscription-1',
		});
		owner.recordCertifiedInstall({
			handle: 'review-view-identity',
			incarnation: 'review-view-identity',
			scopeRevision: 1,
			subscriptionId: 'review-subscription-1',
		});
		expect(owner.recoveryState('review-subscription-1')).toEqual({
			consecutiveResnapshots: 0,
			status: 'ready',
		});
		expect(clock.activeDeadline().active).toBe(true);
		expect(scopes).toHaveLength(2);
	});

	test('two scopes superseded before dispatch consume one control sequence for the latest demand', async () => {
		const queue = new BridgeProductControlAdmissionQueue();
		let releaseHeldControl: () => void = (): void => {};
		const heldControl = new Promise<void>((resolve): void => {
			releaseHeldControl = resolve;
		});
		const blocker = queue.enqueue(async (): Promise<void> => {
			await heldControl;
		});
		let nextSequence = 3;
		const dispatched: Array<{
			readonly sequence: number;
			readonly scope: ViewScopeAdmissionProps['scope'];
		}> = [];
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: (props) =>
					queue.enqueue(async () => {
						props.signal?.throwIfAborted();
						const sequence = nextSequence;
						nextSequence += 1;
						dispatched.push({ sequence, scope: props.scope });
						return { ...acceptedScope(props), requestSequence: sequence };
					}),
				resnapshotView: async (props) => acceptedResnapshot(props),
			},
			createIdentifier: (): string => 'view-identity',
			maximumConsecutiveResnapshots: 2,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		});
		const first = owner.setScope({ scope: emptyFileScope, subscriptionId: 'file-subscription-1' });
		const latestScope = { ...emptyFileScope, pathScope: ['latest'] } as const;
		const second = owner.setScope({ scope: latestScope, subscriptionId: 'file-subscription-1' });
		releaseHeldControl();
		await blocker;
		expect(await first).toEqual({ kind: 'cancelled' });
		expect(await second).toEqual({ kind: 'accepted', scopeRevision: 2 });
		expect(dispatched).toEqual([{ sequence: 3, scope: latestScope }]);
		expect(nextSequence).toBe(4);
	});

	test('emits per-view recovery status only when it changes', async () => {
		const statuses: Array<{
			readonly view: { readonly kind: string; readonly subscriptionId: string };
			readonly status: 'failedRetryable' | 'ready' | 'recovering';
		}> = [];
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => acceptedScope(props),
				resnapshotView: async (props) => acceptedResnapshot(props),
			},
			createIdentifier: (): string => 'view-identity',
			maximumConsecutiveResnapshots: 2,
			onViewRecoveryStatus: (status): void => {
				statuses.push(status);
			},
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		});
		owner.register({
			scope: { kind: 'comment', sessionIds: ['session-1'], worktreeId: 'worktree-1' },
			subscriptionId: 'comment-subscription-1',
			subscriptionKind: 'file.annotations',
		});

		await owner.resnapshot('file-subscription-1');
		owner.observeReplacementSnapshot({
			handle: 'view-identity',
			incarnation: 'view-identity',
			scopeRevision: 0,
			subscriptionId: 'file-subscription-1',
		});
		await owner.resnapshot('file-subscription-1');
		await owner.resnapshot('file-subscription-1');
		owner.recordCertifiedInstall({
			handle: 'view-identity',
			incarnation: 'view-identity',
			scopeRevision: 0,
			subscriptionId: 'file-subscription-1',
		});
		await owner.retryView('file-subscription-1');

		const fileStatuses = statuses.filter(
			(status): boolean => status.view.subscriptionId === 'file-subscription-1',
		);
		expect(fileStatuses).toEqual([
			{
				view: { kind: 'file.metadata', subscriptionId: 'file-subscription-1' },
				status: 'recovering',
			},
			{
				view: { kind: 'file.metadata', subscriptionId: 'file-subscription-1' },
				status: 'failedRetryable',
			},
			{ view: { kind: 'file.metadata', subscriptionId: 'file-subscription-1' }, status: 'ready' },
			{
				view: { kind: 'file.metadata', subscriptionId: 'file-subscription-1' },
				status: 'recovering',
			},
		]);
		expect(owner.recoveryState('comment-subscription-1')).toEqual({
			consecutiveResnapshots: 0,
			status: 'recovering',
		});
		expect(
			statuses.filter((status) => status.view.subscriptionId === 'comment-subscription-1'),
		).toEqual([
			{
				view: { kind: 'file.annotations', subscriptionId: 'comment-subscription-1' },
				status: 'recovering',
			},
		]);
	});

	test('counts unsuccessful page resnapshots per view, stops at the budget, and rearms on Retry', async () => {
		const resnapshots: ViewResnapshotAdmissionProps[] = [];
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => acceptedScope(props),
				resnapshotView: async (props) => {
					resnapshots.push(props);
					return acceptedResnapshot(props);
				},
			},
			createIdentifier: (): string => 'view-identity',
			maximumConsecutiveResnapshots: 2,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		});
		await owner.resnapshot('file-subscription-1');
		expect(owner.recoveryState('file-subscription-1')).toEqual({
			consecutiveResnapshots: 1,
			status: 'recovering',
		});
		owner.observeReplacementSnapshot({
			handle: 'view-identity',
			incarnation: 'view-identity',
			scopeRevision: 0,
			subscriptionId: 'file-subscription-1',
		});
		await owner.resnapshot('file-subscription-1');
		expect(owner.recoveryState('file-subscription-1')).toEqual({
			consecutiveResnapshots: 2,
			status: 'recovering',
		});
		owner.observeReplacementSnapshot({
			handle: 'view-identity',
			incarnation: 'view-identity',
			scopeRevision: 0,
			subscriptionId: 'file-subscription-1',
		});
		await owner.resnapshot('file-subscription-1');
		expect(owner.recoveryState('file-subscription-1')?.status).toBe('failedRetryable');
		expect(resnapshots).toHaveLength(2);
		await owner.retryView('file-subscription-1');
		expect(resnapshots).toHaveLength(3);
		expect(owner.recoveryState('file-subscription-1')).toEqual({
			consecutiveResnapshots: 1,
			status: 'recovering',
		});
	});

	test('coalesces overlapping admissions and fences their late settlement after retirement', async () => {
		let resolveAdmission: (() => void) | undefined;
		let requestCount = 0;
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => acceptedScope(props),
				resnapshotView: async (props) => {
					requestCount += 1;
					await new Promise<void>((resolve) => {
						resolveAdmission = resolve;
					});
					return acceptedResnapshot(props);
				},
			},
			createIdentifier: (() => {
				let nextIdentifier = 0;
				return (): string => `view-${++nextIdentifier}`;
			})(),
			maximumConsecutiveResnapshots: 2,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		});
		const first = owner.resnapshot('file-subscription-1');
		const second = owner.resnapshot('file-subscription-1');
		expect(requestCount).toBe(1);
		expect(owner.recoveryState('file-subscription-1')?.consecutiveResnapshots).toBe(1);
		owner.retire('file-subscription-1');
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		});
		resolveAdmission?.();
		await Promise.all([first, second]);
		expect(owner.recoveryState('file-subscription-1')).toEqual({
			consecutiveResnapshots: 0,
			status: 'recovering',
		});
	});

	test('a new scope can resnapshot while the old scope admission remains unsettled', async () => {
		const admissions: ViewResnapshotAdmissionProps[] = [];
		const settleByRevision = new Map<
			number,
			{ resolve: () => void; reject: (error: Error) => void }
		>();
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => acceptedScope(props),
				resnapshotView: async (props) => {
					admissions.push(props);
					await new Promise<void>((resolve, reject) => {
						settleByRevision.set(props.scopeRevision, { resolve, reject });
					});
					return acceptedResnapshot(props);
				},
			},
			createIdentifier: (): string => 'view-identity',
			maximumConsecutiveResnapshots: 3,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		});
		const oldScopeRecovery = owner.resnapshot('file-subscription-1');
		await owner.setScope({ scope: emptyFileScope, subscriptionId: 'file-subscription-1' });
		const currentRecovery = owner.resnapshot('file-subscription-1');
		expect(admissions.map((admission) => admission.scopeRevision)).toEqual([0, 1]);
		settleByRevision.get(0)?.reject(new Error('Superseded scope rejected.'));
		await expect(oldScopeRecovery).rejects.toThrow('Superseded scope rejected.');
		const duplicateCurrentRecovery = owner.resnapshot('file-subscription-1');
		expect(admissions).toHaveLength(2);
		settleByRevision.get(1)?.resolve();
		await Promise.all([currentRecovery, duplicateCurrentRecovery]);
		expect(owner.recoveryState('file-subscription-1')?.consecutiveResnapshots).toBe(2);
	});

	test('counts native replacement once and resets only after a certified install', async () => {
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => acceptedScope(props),
				resnapshotView: async (props) => acceptedResnapshot(props),
			},
			createIdentifier: (): string => 'view-identity',
			maximumConsecutiveResnapshots: 2,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		});
		owner.observeReplacementSnapshot({
			handle: 'view-identity',
			incarnation: 'view-identity',
			scopeRevision: 0,
			subscriptionId: 'file-subscription-1',
		});
		expect(owner.recoveryState('file-subscription-1')?.consecutiveResnapshots).toBe(1);
		owner.recordCertifiedInstall({
			handle: 'stale-handle',
			incarnation: 'view-identity',
			scopeRevision: 0,
			subscriptionId: 'file-subscription-1',
		});
		expect(owner.recoveryState('file-subscription-1')?.consecutiveResnapshots).toBe(1);
		owner.recordCertifiedInstall({
			handle: 'view-identity',
			incarnation: 'view-identity',
			scopeRevision: 0,
			subscriptionId: 'file-subscription-1',
		});
		expect(owner.recoveryState('file-subscription-1')).toEqual({
			consecutiveResnapshots: 0,
			status: 'ready',
		});
	});
	test('a newer File scope cancels the unsettled operation and resnapshot uses the latest revision', async () => {
		const scopes: ViewScopeAdmissionProps[] = [];
		const resnapshots: ViewResnapshotAdmissionProps[] = [];
		const controlMux = {
			setViewScope: async (props: ViewScopeAdmissionProps) => {
				scopes.push(props);
				if (props.scopeRevision === 1) {
					await new Promise<void>((_, reject): void => {
						props.signal?.addEventListener('abort', (): void => reject(new Error('superseded')), {
							once: true,
						});
					});
				}
				return acceptedScope(props);
			},
			resnapshotView: async (props: ViewResnapshotAdmissionProps) => {
				resnapshots.push(props);
				return acceptedResnapshot(props);
			},
		} satisfies Pick<BridgeProductControlMux, 'resnapshotView' | 'setViewScope'>;
		let nextIdentifier = 0;
		const owner = createTestViewScopeOwner({
			controlMux,
			createIdentifier: (): string => `view-identity-${++nextIdentifier}`,
			maximumConsecutiveResnapshots: 3,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		});
		const older = owner.setScope({ scope: emptyFileScope, subscriptionId: 'file-subscription-1' });
		const newerScope = {
			...emptyFileScope,
			interests: [{ lane: 'foreground', paths: ['src/current.ts'] }],
		} as const;
		const newer = owner.setScope({ scope: newerScope, subscriptionId: 'file-subscription-1' });

		await expect(older).resolves.toEqual({ kind: 'cancelled' });
		await expect(newer).resolves.toEqual({ kind: 'accepted', scopeRevision: 2 });
		expect(scopes.map((scope) => scope.scopeRevision)).toEqual([1, 2]);
		expect(scopes[0]?.signal?.aborted).toBe(true);
		await owner.resnapshot('file-subscription-1');
		expect(resnapshots).toMatchObject([
			{
				handle: 'view-identity-1',
				incarnation: 'view-identity-2',
				scopeRevision: 2,
				subscriptionId: 'file-subscription-1',
			},
		]);
	});

	test('retirement cancels the pending view operation and removes resnapshot authority', async () => {
		let started = false;
		const controlMux = {
			setViewScope: async (props: ViewScopeAdmissionProps) => {
				started = true;
				await new Promise<void>((_, reject): void => {
					props.signal?.addEventListener('abort', (): void => reject(new Error('retired')), {
						once: true,
					});
				});
				return acceptedScope(props);
			},
			resnapshotView: async (props: ViewResnapshotAdmissionProps) => acceptedResnapshot(props),
		} satisfies Pick<BridgeProductControlMux, 'resnapshotView' | 'setViewScope'>;
		const owner = createTestViewScopeOwner({
			controlMux,
			createIdentifier: (): string => 'view-identity',
			maximumConsecutiveResnapshots: 3,
		});
		owner.register({
			scope: emptyFileScope,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		});
		const pending = owner.setScope({
			scope: emptyFileScope,
			subscriptionId: 'file-subscription-1',
		});
		expect(started).toBe(true);
		owner.retire('file-subscription-1');
		await expect(pending).resolves.toEqual({ kind: 'cancelled' });
		await expect(owner.resnapshot('file-subscription-1')).resolves.toBeUndefined();
	});
});

function acceptedScope(
	props: ViewScopeAdmissionProps,
): Awaited<ReturnType<BridgeProductControlMux['setViewScope']>> {
	return {
		...props,
		kind: 'subscription.scopeAccepted' as const,
		paneSessionId: 'pane-session-1',
		requestId: 'request-1',
		requestSequence: 1,
		wireVersion: 2 as const,
		workerInstanceId: 'worker-instance-1',
	};
}

function acceptedResnapshot(
	props: ViewResnapshotAdmissionProps,
): Awaited<ReturnType<BridgeProductControlMux['resnapshotView']>> {
	return {
		...props,
		kind: 'subscription.resnapshotAccepted' as const,
		paneSessionId: 'pane-session-1',
		requestId: 'request-2',
		requestSequence: 2,
		wireVersion: 2 as const,
		workerInstanceId: 'worker-instance-1',
	};
}

import { describe, expect, test } from 'vitest';

import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import type { ViewResnapshotAdmissionProps } from './bridge-product-view-control-admission.js';
import { createTestViewScopeOwner } from './bridge-product-view-scope-owner.test-support.js';

type FailureTiming = 'armedDeadline' | 'lateResnapshot' | 'lateScope';

describe('W2 render-Failed request containment', () => {
	for (const kind of ['file.metadata', 'review.metadata'] as const) {
		test.each(['armedDeadline', 'lateResnapshot', 'lateScope'] as const)(
			`${kind} keeps its count and sends no recovery after %s render failure`,
			async (timing: FailureTiming) => {
				const admission = createBridgeProductDeferred<void>();
				const requests: ViewResnapshotAdmissionProps[] = [];
				const deadlines: Array<{ active: boolean; readonly fire: () => void }> = [];
				const clock: BridgeProductDeadlineClock = {
					schedule: (_delay, fire): (() => void) => {
						const deadline = { active: true, fire };
						deadlines.push(deadline);
						return (): void => {
							deadline.active = false;
						};
					},
				};
				const scope =
					kind === 'file.metadata'
						? ({
								kind: 'file',
								changeFilter: { kind: 'none' },
								interests: [],
								pathScope: [],
							} as const)
						: ({ kind: 'review', interests: [] } as const);
				const owner = createTestViewScopeOwner({
					controlMux: {
						resnapshotView: async (request) => {
							requests.push(request);
							if (timing === 'lateResnapshot') await admission.promise;
							return {
								...request,
								kind: 'subscription.resnapshotAccepted',
								paneSessionId: 'pane',
								requestId: 'resnapshot',
								requestSequence: requests.length,
								wireVersion: 2,
								workerInstanceId: 'worker',
							};
						},
						setViewScope: async (request) => {
							await admission.promise;
							return {
								...request,
								kind: 'subscription.scopeAccepted',
								paneSessionId: 'pane',
								requestId: 'scope',
								requestSequence: 1,
								wireVersion: 2,
								workerInstanceId: 'worker',
							};
						},
					},
					createIdentifier: (): string => 'view-identity',
					deadlineClock: clock,
					maximumConsecutiveResnapshots: 3,
				});
				owner.register({ scope, subscriptionId: 'affected', subscriptionKind: kind });
				try {
					const settlement =
						timing === 'lateScope'
							? owner.setScope({ scope, subscriptionId: 'affected' })
							: owner.resnapshot('affected');
					if (timing === 'armedDeadline') await settlement;
					const sentBeforeFailure = requests.length;
					const countBeforeFailure = owner.recoveryState('affected')?.consecutiveResnapshots;
					owner.failRenderView('affected');
					admission.resolve();
					await settlement;
					expect.soft(deadlines.every((deadline) => !deadline.active)).toBe(true);
					// A timer callback already queued before cancellation must also be inert.
					for (const deadline of [...deadlines]) deadline.fire();
					await owner.resnapshot('affected');
					expect.soft(requests).toHaveLength(sentBeforeFailure);
					expect.soft(owner.recoveryState('affected')).toEqual({
						consecutiveResnapshots: countBeforeFailure,
						status: 'failedRetryable',
					});
					// Existing explicit Retry remains a real new recovery admission.
					await owner.retryView('affected');
					expect(requests).toHaveLength(sentBeforeFailure + 1);
					expect(owner.recoveryState('affected')).toEqual({
						consecutiveResnapshots: 1,
						status: 'recovering',
					});
				} finally {
					admission.resolve();
					owner.retire('affected');
				}
			},
		);
	}
});

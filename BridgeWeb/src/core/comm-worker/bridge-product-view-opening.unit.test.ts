import { describe, expect, test } from 'vitest';

import type { ViewScopeAdmissionProps } from './bridge-product-view-control-admission.js';
import { bridgeProductInitialViewOpening } from './bridge-product-view-opening.js';
import { createTestViewScopeOwner } from './bridge-product-view-scope-owner.test-support.js';

describe('initial E4 view scope admission', () => {
	test('a newer Comment demand supersedes the initial scope without ending E3', async () => {
		let firstAdmissionStarted = (): void => {};
		const firstAdmission = new Promise<void>((resolve): void => {
			firstAdmissionStarted = resolve;
		});
		let registrationCount = 0;
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => {
					if (props.scopeRevision === 1) {
						firstAdmissionStarted();
						return await new Promise<never>((_resolve, reject): void => {
							props.signal?.addEventListener('abort', (): void => reject(new Error('superseded')), {
								once: true,
							});
						});
					}
					return {
						...props,
						kind: 'subscription.scopeAccepted' as const,
						paneSessionId: 'pane-session-1',
						requestId: 'request-2',
						requestSequence: 2,
						wireVersion: 2 as const,
						workerInstanceId: 'worker-instance-1',
					};
				},
				resnapshotView: async (): Promise<never> => {
					throw new Error('Unexpected resnapshot.');
				},
			},
			createIdentifier: (() => {
				let nextId = 0;
				return (): string => `comment-view-${++nextId}`;
			})(),
			maximumConsecutiveResnapshots: 3,
		});
		const openView = bridgeProductInitialViewOpening(
			{
				register: (props): void => {
					registrationCount += 1;
					owner.register(props);
				},
				setScope: owner.setScope.bind(owner),
			},
			'review.annotations',
		);
		if (openView === undefined) throw new Error('Comment view opening missing.');
		const subscriptionSignal = new AbortController().signal;
		const opening = openView('comment-subscription-1', subscriptionSignal, 'worktree-1');
		await firstAdmission;
		expect(
			await owner.setScope({
				scope: { kind: 'comment', sessionIds: ['session-1'], worktreeId: 'worktree-1' },
				subscriptionId: 'comment-subscription-1',
			}),
		).toEqual({ kind: 'accepted', scopeRevision: 2 });
		await expect(opening).resolves.toBeUndefined();
		expect(registrationCount).toBe(1);
	});

	test('a failed successor scope still settles while its superseded initial E3 stays open', async () => {
		let firstAdmissionStarted = (): void => {};
		const firstAdmission = new Promise<void>((resolve): void => {
			firstAdmissionStarted = resolve;
		});
		let registrationCount = 0;
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => {
					if (props.scopeRevision === 1) {
						firstAdmissionStarted();
						return await new Promise<never>((_resolve, reject): void => {
							props.signal?.addEventListener('abort', (): void => reject(new Error('superseded')), {
								once: true,
							});
						});
					}
					throw new Error('Successor scope admission failed.');
				},
				resnapshotView: async (): Promise<never> => {
					throw new Error('Unexpected resnapshot.');
				},
			},
			createIdentifier: (() => {
				let nextId = 0;
				return (): string => `comment-view-${++nextId}`;
			})(),
			maximumConsecutiveResnapshots: 3,
		});
		const openView = bridgeProductInitialViewOpening(
			{
				register: (props): void => {
					registrationCount += 1;
					owner.register(props);
				},
				setScope: owner.setScope.bind(owner),
			},
			'review.annotations',
		);
		if (openView === undefined) throw new Error('Comment view opening missing.');
		const opening = openView('comment-subscription-1', new AbortController().signal, 'worktree-1');
		await firstAdmission;
		await expect(
			owner.setScope({
				scope: { kind: 'comment', sessionIds: ['session-1'], worktreeId: 'worktree-1' },
				subscriptionId: 'comment-subscription-1',
			}),
		).rejects.toThrow('Successor scope admission failed.');
		await expect(opening).resolves.toBeUndefined();
		expect(registrationCount).toBe(1);
	});

	test('an aborted subscription still rejects its cancelled initial scope', async () => {
		const openView = bridgeProductInitialViewOpening(
			{
				register: (): void => {},
				setScope: async () => ({ kind: 'cancelled' as const }),
			},
			'review.annotations',
		);
		if (openView === undefined) throw new Error('Comment view opening missing.');
		const cancellation = new AbortController();
		cancellation.abort(new Error('Subscription was retired.'));
		await expect(
			openView('comment-subscription-1', cancellation.signal, 'worktree-1'),
		).rejects.toThrow('Subscription was retired.');
	});
	test('admits File scope after subscription open with one stable handle and typed acceptance', async () => {
		const requests: ViewScopeAdmissionProps[] = [];
		let nextId = 0;
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (props) => {
					requests.push(props);
					return {
						...props,
						kind: 'subscription.scopeAccepted',
						paneSessionId: 'pane-session-1',
						requestId: 'request-1',
						requestSequence: 1,
						wireVersion: 2,
						workerInstanceId: 'worker-instance-1',
					};
				},
				resnapshotView: async (): Promise<never> => {
					throw new Error('Unexpected resnapshot.');
				},
			},
			createIdentifier: (): string => `view-${++nextId}`,
			maximumConsecutiveResnapshots: 3,
		});
		const openView = bridgeProductInitialViewOpening(owner, 'file.metadata');
		if (openView === undefined) throw new Error('File view opening missing.');
		const signal = new AbortController().signal;
		await openView('file-subscription-1', signal, null);
		expect(requests).toEqual([
			{
				domain: 'default',
				handle: 'view-1',
				incarnation: 'view-2',
				scope: { kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] },
				scopeRevision: 1,
				signal: expect.any(AbortSignal),
				subscriptionId: 'file-subscription-1',
				subscriptionKind: 'file.metadata',
			},
		]);
	});

	test('Review metadata and native-authorized Comments receive their initial scopes', async () => {
		const requests: ViewScopeAdmissionProps[] = [];
		const controlMux = {
			setViewScope: async (props: ViewScopeAdmissionProps) => {
				requests.push(props);
				return {
					...props,
					kind: 'subscription.scopeAccepted' as const,
					paneSessionId: 'pane-session-1',
					requestId: 'request-1',
					requestSequence: 1,
					wireVersion: 2 as const,
					workerInstanceId: 'worker-instance-1',
				};
			},
		};
		const owner = createTestViewScopeOwner({
			controlMux: {
				...controlMux,
				resnapshotView: async (): Promise<never> => {
					throw new Error('Unexpected resnapshot.');
				},
			},
			createIdentifier: (() => {
				let nextId = 0;
				return (): string => `review-view-${++nextId}`;
			})(),
			maximumConsecutiveResnapshots: 3,
		});
		const review = bridgeProductInitialViewOpening(owner, 'review.metadata');
		const comment = bridgeProductInitialViewOpening(owner, 'review.annotations');
		if (review === undefined) throw new Error('Review view opening missing.');
		if (comment === undefined) throw new Error('Comment view opening missing.');
		await review('review-subscription-1', new AbortController().signal, null);
		await comment('comment-subscription-1', new AbortController().signal, 'native-worktree-1');
		expect(requests[0]).toMatchObject({
			scope: { kind: 'review', interests: [] },
			subscriptionKind: 'review.metadata',
		});
		expect(requests[1]).toMatchObject({
			scope: { kind: 'comment', sessionIds: [], worktreeId: 'native-worktree-1' },
			subscriptionId: 'comment-subscription-1',
			subscriptionKind: 'review.annotations',
		});
		expect(requests).toHaveLength(2);
	});
});

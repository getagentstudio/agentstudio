import { afterEach, expect, test, vi } from 'vitest';

import {
	makeContentRequestDescriptor,
	makeImmediateReviewContentStream,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { bridgeProductReviewMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import type { BridgeProductControlMux } from './bridge-product-session-authority.js';
import { createTestViewScopeOwner } from './bridge-product-view-scope-owner.test-support.js';
import { fetchBridgeWorkerReviewContentResource } from './bridge-worker-review-content-fetch.js';
import {
	createContentTransportHarness,
	metadataAccepted,
} from './test-fixtures/bridge-product-transport-content.test-support.js';

afterEach((): void => {
	vi.unstubAllGlobals();
});

test('successor selected Review preparation waits for its allocated metadata view to register', async (): Promise<void> => {
	// Arrange: a fresh successor transport has allocated E3, but no native reply yet.
	const harness = createContentTransportHarness(0, undefined, undefined, {
		schedule: (): (() => void) => (): void => {},
	});
	const subscription = harness.transport.subscribe(
		bridgeProductReviewMetadataApplicationProtocol,
		{},
	);
	const descriptor = makeContentRequestDescriptor({ role: 'head', text: 'successor content' });
	const openedDescriptorIds: string[] = [];
	try {
		// Act: the same pre-open scope barrier as selected Review preparation.
		const preparation = fetchBridgeWorkerReviewContentResource({
			beforeOpenContent: async (): Promise<void> => {
				await harness.transport.setViewScopeForSubscription?.({
					scope: { kind: 'review', interests: [] },
					subscriptionId: subscription.subscriptionId,
				});
			},
			descriptor,
			openContent: (openedDescriptor) => {
				openedDescriptorIds.push(openedDescriptor.descriptorId);
				return makeImmediateReviewContentStream(openedDescriptor, 'successor content');
			},
		});
		await harness.server.waitForMetadataStream();
		harness.server.emitMetadata(metadataAccepted(harness.server.requiredMetadataRequest()));

		// Assert: registration resumes current preparation, without terminal failure.
		await expect(preparation).resolves.toMatchObject({ disposition: 'ready' });
		expect(openedDescriptorIds).toEqual([descriptor.descriptorId]);
	} finally {
		await subscription.cancel();
	}
});

test('unknown Review metadata subscription still fails its pre-open authority', async (): Promise<void> => {
	const harness = createContentTransportHarness();
	await expect(
		harness.transport.setViewScopeForSubscription?.({
			scope: { kind: 'review', interests: [] },
			subscriptionId: 'never-allocated-subscription',
		}),
	).rejects.toThrow('Metadata view scope has no registered E3.');
});

test.each(['file.metadata', 'review.metadata', 'file.annotations', 'review.annotations'] as const)(
	'allocated %s scope resumes when its view registers',
	async (subscriptionKind): Promise<void> => {
		const scope =
			subscriptionKind === 'file.metadata'
				? ({ kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] } as const)
				: subscriptionKind === 'review.metadata'
					? ({ kind: 'review', interests: [] } as const)
					: ({ kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' } as const);
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (
					props,
				): Promise<Awaited<ReturnType<BridgeProductControlMux['setViewScope']>>> => ({
					...props,
					kind: 'subscription.scopeAccepted',
					paneSessionId: 'successor-pane',
					requestId: 'successor-request',
					requestSequence: 1,
					wireVersion: 2,
					workerInstanceId: 'successor-worker',
				}),
				resnapshotView: async (): Promise<never> => {
					throw new Error('Registration must not require a replacement.');
				},
			},
			createIdentifier: (): string => 'successor-view',
			maximumConsecutiveResnapshots: 2,
		});
		const subscriptionId = 'pending-successor-subscription';
		owner.allocatePendingRegistration(subscriptionId);
		const admission = owner.setScope({ scope, subscriptionId });
		const acceptedAdmission = expect(admission).resolves.toMatchObject({ kind: 'accepted' });
		owner.register({ scope, subscriptionId, subscriptionKind });
		try {
			await acceptedAdmission;
		} finally {
			owner.retire(subscriptionId);
		}
	},
);

test.each(['pending', 'registered'] as const)(
	'retiring a %s view fails its waiting or subsequent scope admission',
	async (registrationState): Promise<void> => {
		const owner = createTestViewScopeOwner({
			controlMux: {
				setViewScope: async (): Promise<never> => {
					throw new Error('Retired views must not send scope controls.');
				},
				resnapshotView: async (): Promise<never> => {
					throw new Error('Retired views must not request replacements.');
				},
			},
			createIdentifier: (): string => 'successor-view',
			maximumConsecutiveResnapshots: 2,
		});
		const subscriptionId = 'retired-successor-subscription';
		const scope = { kind: 'review', interests: [] } as const;
		owner.allocatePendingRegistration(subscriptionId);
		if (registrationState === 'registered') {
			owner.register({ scope, subscriptionId, subscriptionKind: 'review.metadata' });
			owner.retire(subscriptionId);
		}
		const admission = owner.setScope({ scope, subscriptionId });
		const rejectedAdmission = expect(admission).rejects.toThrow(
			'Metadata view scope has no registered E3.',
		);
		if (registrationState === 'pending') owner.retire(subscriptionId);
		await rejectedAdmission;
		await expect(owner.setScope({ scope, subscriptionId })).rejects.toThrow(
			'Metadata view scope has no registered E3.',
		);
	},
);

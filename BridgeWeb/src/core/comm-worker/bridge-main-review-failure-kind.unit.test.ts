import { expect, test } from 'vitest';

import { createBridgeMainRenderSnapshotStore } from './bridge-main-render-snapshot-store.js';

const wireFailureCases = [
	['targetNotFound', 'targetNotFound'],
	['targetMismatch', 'targetMismatch'],
	['defaultTargetUnavailable', 'defaultTargetUnavailable'],
	['providerUnavailable', 'refreshUnavailable'],
	['loadFailed:package:unavailableEndpoint', 'refreshUnavailable'],
	['new-native-reason', 'refreshUnavailable'],
] as const;

test.each(wireFailureCases)(
	'publishes %s as closed Main failure kind %s',
	(wireKind, expectedKind): void => {
		const store = createBridgeMainRenderSnapshotStore();
		try {
			store.applyWorkerPatch({
				slice: 'panelChrome',
				operation: 'upsert',
				payload: {
					reviewComparison: {
						activeTarget: { kind: 'ref', name: 'main', basis: 'commonCommit' },
						attempt: { status: 'unavailable', failureKind: wireKind, retryable: true },
						displayedSnapshot: { status: 'none' },
						repositoryDefaultTarget: null,
					},
				},
			});
			const attempt = store.getSnapshot().panelChromeSlice.reviewComparison?.attempt;
			expect(attempt).toMatchObject({ status: 'unavailable', failureKind: expectedKind });
		} finally {
			store.dispose();
		}
	},
);

test.each(wireFailureCases)(
	'Review display publication classifies %s as %s',
	(wireKind, expectedKind): void => {
		const store = createBridgeMainRenderSnapshotStore();
		try {
			store.applyReviewDisplayPatchEvent({
				direction: 'serverWorkerToMain',
				epoch: 1,
				kind: 'reviewDisplayPatch',
				reviewPublicationIdentity: null,
				projectionRevision: 1,
				sequence: 1,
				surface: 'review',
				transferDescriptors: [],
				wireVersion: 1,
				patches: [
					{
						slice: 'reviewComparison',
						operation: 'replace',
						payload: {
							activeTarget: { kind: 'ref', name: 'main', basis: 'commonCommit' },
							attempt: { status: 'unavailable', failureKind: wireKind, retryable: true },
							displayedSnapshot: { status: 'none' },
							repositoryDefaultTarget: null,
						},
					},
				],
			});
			expect(store.getSnapshot().panelChromeSlice.reviewComparison?.attempt).toMatchObject({
				status: 'unavailable',
				failureKind: expectedKind,
			});
		} finally {
			store.dispose();
		}
	},
);

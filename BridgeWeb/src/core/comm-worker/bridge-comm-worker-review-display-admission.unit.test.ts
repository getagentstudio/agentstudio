import { describe, expect, test } from 'vitest';

import { BridgeCommWorkerPanePresentationAuthority } from './bridge-comm-worker-pane-presentation.js';
import { admitBridgeCommWorkerReviewDisplayPatches } from './bridge-comm-worker-review-display-projection.js';
import type { BridgeWorkerReviewDisplayPatch } from './bridge-worker-contracts.js';
import { bridgeWorkerReviewSourceContext } from './bridge-worker-review-display.test-support.js';
import { bridgeWorkerReviewPublicationIdentity } from './bridge-worker-review-display.test-support.js';

describe('Bridge comm worker Review display admission', () => {
	test('keeps a newer pending comparison while admitting an older Review source', () => {
		const identity = bridgeWorkerReviewPublicationIdentity('review-package', 12);
		const settledComparison = {
			activeTarget: { basis: 'commonCommit', kind: 'branch', name: 'origin/main' },
			attempt: { reviewGeneration: identity.reviewGeneration, status: 'settled' },
			displayedSnapshot: {
				packageId: identity.packageId,
				reviewGeneration: identity.reviewGeneration,
				revision: identity.revision,
				status: 'current',
			},
			repositoryDefaultTarget: null,
		} as const;
		const pendingComparison = {
			...settledComparison,
			activeTarget: { basis: 'commonCommit', kind: 'branch', name: 'feature/next' },
			attempt: { reviewGeneration: identity.reviewGeneration + 1, status: 'pending' },
			displayedSnapshot: { ...settledComparison.displayedSnapshot, status: 'stale' },
		} as const;
		const sourcePatch: BridgeWorkerReviewDisplayPatch = {
			operation: 'upsert',
			payload: {
				...bridgeWorkerReviewSourceContext(identity.packageId),
				metadataSourceId: identity.sourceIdentity,
				metadataWindowIdentity: 'review-source-window-12',
				packageId: identity.packageId,
				reviewGeneration: identity.reviewGeneration,
				revision: identity.revision,
				status: 'ready',
				summary: {
					additions: 0,
					deletions: 0,
					filesChanged: 0,
					hiddenFileCount: 0,
					visibleFileCount: 0,
				},
				totalItemCount: 0,
				totalTreeRowCount: 0,
			},
			slice: 'reviewSource',
		};
		const patches: readonly BridgeWorkerReviewDisplayPatch[] = [
			{ operation: 'replace', payload: settledComparison, slice: 'reviewComparison' },
			sourcePatch,
		];
		const newerAuthority = new BridgeCommWorkerPanePresentationAuthority();
		newerAuthority.reconcileReviewComparison(3, pendingComparison);

		const staleCommit = admitBridgeCommWorkerReviewDisplayPatches({
			comparisonCommit: { presentationRevision: 2, reviewComparison: settledComparison },
			panePresentationAuthority: newerAuthority,
			patches,
		});
		const matchingCommit = admitBridgeCommWorkerReviewDisplayPatches({
			comparisonCommit: { presentationRevision: 2, reviewComparison: settledComparison },
			panePresentationAuthority: new BridgeCommWorkerPanePresentationAuthority(),
			patches,
		});

		expect(staleCommit.patches).toContainEqual({
			operation: 'replace',
			payload: pendingComparison,
			slice: 'reviewComparison',
		});
		expect(staleCommit.patches).toContainEqual(sourcePatch);
		expect(staleCommit.sourceIdentity).toMatchObject({
			packageId: identity.packageId,
			reviewGeneration: identity.reviewGeneration,
			revision: identity.revision,
		});
		expect(staleCommit.reviewComparison).toEqual(pendingComparison);
		expect(newerAuthority.snapshot.reviewComparison).toEqual(pendingComparison);
		expect(matchingCommit.reviewComparison).toEqual(settledComparison);
	});
});

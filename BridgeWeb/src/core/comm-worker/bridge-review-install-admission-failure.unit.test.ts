import { describe, expect, test } from 'vitest';

import { projectBridgePaneFailureSummary } from '../../app/bridge-pane-failure-summary.js';
import { bridgeReviewRefreshHeaderPresentation } from '../../app/bridge-review-refresh-header-chrome.js';
import {
	bridgeReviewFallbackRegionPresentation,
	bridgeReviewRegionSurfaceStatus,
} from '../../features/review/bridge-review-region-presentation.js';
import { createBridgeMainRenderSnapshotStore } from './bridge-main-render-snapshot-store.js';
import type { BridgeMainReviewPublicationIdentity } from './bridge-main-review-candidate-bank.js';
import { createBridgeMainReviewPresentationInstallationGate } from './bridge-main-review-presentation-installation-gate.js';
import {
	bridgeWorkerReviewDisplayPatchEventSchema,
	type BridgeWorkerReviewCandidateStartDisposition,
} from './bridge-worker-contracts.js';
import { bridgeWorkerReviewSourceContext } from './bridge-worker-review-display.test-support.js';

describe('Review install admission failure on the real candidate bank', () => {
	test.each(['initial', 'ordinary', 'promoted'] as const)(
		'%s current install admission becomes a retryable surface failure retaining prior content',
		async (kind) => {
			const store = createBridgeMainRenderSnapshotStore();
			const predecessor = identity(1);
			const candidate = identity(2);
			if (kind !== 'initial') {
				stageCandidate(store, predecessor, { kind: 'replacement' });
				expect(store.promoteReviewCandidate(predecessor)).toBe(true);
			}
			const previous = store.getSnapshot();
			stageCandidate(
				store,
				candidate,
				kind === 'initial'
					? { kind: 'replacement' }
					: {
							affectedStableFileIdentities: ['file-b'],
							kind: 'sameSource',
							presentationClass:
								kind === 'ordinary' ? { kind: 'ordinary' } : { kind: 'promoted', reason: 'files' },
						},
			);
			const receipts: BridgeMainReviewPublicationIdentity[] = [];
			const gate = createBridgeMainReviewPresentationInstallationGate({
				installationPort: {
					requestWorkerReplacement: (): void => {
						throw new Error('Unexpected replacement.');
					},
					requestInstallAdmission: (): Promise<never> =>
						Promise.reject(new Error('Install admission unavailable.')),
					sendInstalledReceipt: (installed): Promise<void> => {
						receipts.push(installed);
						return Promise.resolve();
					},
				},
				prepareActiveEditorsForInstallation: (): Promise<boolean> => Promise.resolve(true),
				store,
			});
			try {
				await gate.handleCandidateReady(
					{
						direction: 'serverWorkerToMain',
						epoch: 1,
						kind: 'reviewCandidateReady',
						packageId: candidate.packageId,
						publicationId: candidate.publicationId,
						reviewGeneration: candidate.generation,
						revision: candidate.revision,
						sequence: 2,
						sourceIdentity: candidate.sourceIdentity,
						surface: 'review',
						transferDescriptors: [],
						wireVersion: 1,
					},
					{ activeEditorStableFileIdentities: [], stableFileIdentities: [] },
				);
				expect(store.getSnapshot()).toBe(previous);
				expect(receipts).toEqual([]);
				expect(store.getReviewRefreshPresentation()).toMatchObject({
					candidate: null,
					failure: { identity: candidate, retryable: true },
				});
				expect(
					bridgeReviewRefreshHeaderPresentation({
						attentionItemIds: [],
						canRetry: true,
						refreshPresentation: store.getReviewRefreshPresentation(),
					}),
				).toEqual({
					action: null,
					statusText: null,
				});
				const state = bridgeReviewFallbackRegionPresentation({
					status: kind === 'initial' ? 'loading' : 'certifiedEmpty',
					comparisonPaneState: { kind: 'settled' },
					surface: bridgeReviewRegionSurfaceStatus({
						comparisonPaneState: { kind: 'settled' },
						refreshPresentation: store.getReviewRefreshPresentation(),
					}),
				});
				const summary = projectBridgePaneFailureSummary([
					{ part: 'review', state, retry: (): void => {} },
				]);
				expect(summary?.state.failure.kind).toBe('retryable');
				expect(summary?.retry).toBeTypeOf('function');
				await gate.semanticAttentionChanged({
					activeEditorStableFileIdentities: [],
					stableFileIdentities: [],
				});
				expect(store.getReviewRefreshPresentation().failure).not.toBeNull();
			} finally {
				gate.close();
			}
		},
	);
});

function identity(generation: number): BridgeMainReviewPublicationIdentity {
	return {
		generation,
		packageId: `package-${generation}`,
		publicationId: `00000000-0000-7000-8000-${String(generation).padStart(12, '0')}`,
		revision: 1,
		sourceIdentity: `source-${generation}`,
	};
}

function stageCandidate(
	store: ReturnType<typeof createBridgeMainRenderSnapshotStore>,
	publication: BridgeMainReviewPublicationIdentity,
	disposition: BridgeWorkerReviewCandidateStartDisposition,
): void {
	expect(store.startReviewCandidate({ disposition, identity: publication })).toBe(true);
	expect(
		store.stageReviewCandidateDisplayEvent({
			identity: publication,
			event: bridgeWorkerReviewDisplayPatchEventSchema.parse({
				direction: 'serverWorkerToMain',
				epoch: 1,
				kind: 'reviewDisplayPatch',
				projectionRevision: publication.generation,
				reviewPublicationIdentity: {
					packageId: publication.packageId,
					publicationId: publication.publicationId,
					reviewGeneration: publication.generation,
					revision: publication.revision,
					sourceIdentity: publication.sourceIdentity,
				},
				sequence: publication.generation,
				surface: 'review',
				transferDescriptors: [],
				wireVersion: 1,
				patches: [
					{
						operation: 'upsert',
						slice: 'reviewSource',
						payload: {
							...bridgeWorkerReviewSourceContext(publication.packageId),
							metadataSourceId: publication.sourceIdentity,
							metadataWindowIdentity: `window-${publication.generation}`,
							packageId: publication.packageId,
							reviewGeneration: publication.generation,
							revision: publication.revision,
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
					},
				],
			}),
		}),
	).toBe(true);
}

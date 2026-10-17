import { bridgeCommWorkerReviewDisplayItemFromBatch } from './bridge-comm-worker-review-batch-display-items.js';
import type { BridgeCommWorkerReviewBatchPresentation } from './bridge-comm-worker-review-batch-installer.js';
import { BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT } from './bridge-product-review-metadata-contracts.js';
import type { BridgeWorkerReviewDisplayPatch } from './bridge-worker-contracts.js';

/** Projects one certified Review bank into one worker-to-main display publication. */
export function bridgeCommWorkerReviewDisplayPatchesFromBatch(
	presentation: BridgeCommWorkerReviewBatchPresentation,
): readonly BridgeWorkerReviewDisplayPatch[] {
	const { displayed, desired } = presentation.publication;
	const patches: BridgeWorkerReviewDisplayPatch[] = [
		{ operation: 'replace', payload: desired.reviewComparison, slice: 'reviewComparison' },
	];
	if (displayed === null) {
		if (desired.status === 'failedPermanent' || desired.status === 'failedRetryable') {
			patches.push({
				operation: 'failed',
				payload: { error: 'metadataUnavailable', status: 'failed' },
				slice: 'reviewSource',
			});
		}
	} else {
		patches.push({
			operation: 'upsert',
			payload: {
				baseEndpoint: displayed.baseEndpoint,
				comparisonOrigin: displayed.comparisonOrigin,
				headEndpoint: displayed.headEndpoint,
				metadataSourceId: displayed.query.queryId,
				metadataWindowIdentity: JSON.stringify([
					'bridge-review-metadata-window-v1',
					displayed.query.queryId,
					displayed.generation,
					displayed.publicationId,
					displayed.revision,
				]),
				packageId: displayed.packageId,
				query: displayed.query,
				reviewGeneration: displayed.generation,
				reviewedSubjectLabel: displayed.reviewedSubjectLabel,
				revision: displayed.revision,
				status: desired.status === 'ready' ? 'ready' : 'stale',
				summary: displayed.summary,
				totalItemCount: presentation.orderedItems.length,
				totalTreeRowCount: presentation.treeRows.length,
			},
			slice: 'reviewSource',
		});
	}
	for (
		let index = 0;
		index < presentation.orderedItems.length || index === 0;
		index += BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT
	) {
		patches.push({
			operation: 'batch',
			payload: {
				items:
					displayed === null
						? []
						: presentation.orderedItems
								.slice(index, index + BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT)
								.map((item) => bridgeCommWorkerReviewDisplayItemFromBatch(item, displayed)),
				operations: [],
				reset: index === 0,
				startIndex: index,
			},
			slice: 'reviewItem',
		});
	}
	for (
		let index = 0;
		index < presentation.treeRows.length || index === 0;
		index += BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT
	) {
		patches.push({
			operation: 'batch',
			payload: {
				reset: index === 0,
				windows: [
					{
						rows: presentation.treeRows
							.slice(index, index + BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT)
							.map((row) => ({
								depth: row.depth,
								isDirectory: row.isDirectory,
								itemId: row.itemId,
								path: row.path,
								rowId: row.id,
							})),
						startIndex: index,
					},
				],
			},
			slice: 'reviewTree',
		});
	}
	return patches;
}

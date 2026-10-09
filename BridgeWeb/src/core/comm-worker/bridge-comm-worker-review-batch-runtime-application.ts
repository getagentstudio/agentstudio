import type { BridgeCommWorkerReviewBatchPresentation } from './bridge-comm-worker-review-batch-installer.js';
import type { BridgeCommWorkerReviewMetadataApplication } from './bridge-comm-worker-review-runtime-application.js';
import { reviewRuntimeChangedItemIds } from './bridge-comm-worker-review-runtime-index.js';

/** A certified Review bank replaces the complete runtime source at one local source epoch. */
export function bridgeCommWorkerReviewRuntimeApplicationFromBatch(props: {
	readonly previous: BridgeCommWorkerReviewBatchPresentation | null;
	readonly presentation: BridgeCommWorkerReviewBatchPresentation;
	readonly sourceEpoch: number;
	readonly workerDerivationEpoch: number;
}): BridgeCommWorkerReviewMetadataApplication {
	const currentItemIds = props.presentation.orderedItems.map((item) => item.itemId);
	const currentItemIdSet = new Set(currentItemIds);
	const removedItemIds =
		props.previous?.orderedItems
			.map((item) => item.itemId)
			.filter((itemId) => !currentItemIdSet.has(itemId)) ?? [];
	const affectedItemIds =
		props.previous === null
			? currentItemIds
			: reviewRuntimeChangedItemIds(props.previous.runtimeSource, props.presentation.runtimeSource);
	return {
		affectedItemIds,
		affectedRowIds: props.presentation.runtimeSource.rows.map((row) => row.id),
		// This is full-bank membership for pruning removed metadata, not the changed subset.
		completeContentItemIds: currentItemIds,
		completeRowIds: props.presentation.runtimeSource.rows.map((row) => row.id),
		operationCorrelationId: null,
		projectionRevision: props.presentation.targetRevision,
		removedItemIds,
		// W4 already installed the complete bank. Reusing the old chunked reset
		// would defer selected demand behind a second per-frame work pump.
		reset: false,
		rowMutation: { removedRowIds: [], rowUpserts: [] },
		source: props.presentation.runtimeSource,
		sourceEpoch: props.sourceEpoch,
		workerDerivationEpoch: props.workerDerivationEpoch,
	};
}

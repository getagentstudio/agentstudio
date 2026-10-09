import { makeReviewPublicationIdentity } from './bridge-comm-worker-entry.test-support.js';
import type { BridgeCommWorkerReviewMetadataApplication } from './bridge-comm-worker-review-runtime-application.js';

export function reviewMetadataApplication(props: {
	readonly contentItems: BridgeCommWorkerReviewMetadataApplication['source']['contentItems'];
	readonly contentRequestDescriptors: BridgeCommWorkerReviewMetadataApplication['source']['contentRequestDescriptors'];
	readonly renderSemantics: BridgeCommWorkerReviewMetadataApplication['source']['renderSemantics'];
	readonly rows: BridgeCommWorkerReviewMetadataApplication['source']['rows'];
	readonly reset?: boolean;
	readonly sourceEpoch: number;
}): BridgeCommWorkerReviewMetadataApplication {
	return {
		affectedItemIds: props.contentItems.map((item) => item.itemId),
		affectedRowIds: props.rows.map((row) => row.id),
		completeContentItemIds: props.contentItems.map((item) => item.itemId),
		completeRowIds: props.rows.map((row) => row.id),
		projectionRevision: 1,
		removedItemIds: [],
		reset: props.reset ?? false,
		rowMutation: { removedRowIds: [], rowUpserts: props.rows },
		source: {
			contentItems: props.contentItems,
			contentRequestDescriptors: props.contentRequestDescriptors,
			renderSemantics: props.renderSemantics,
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			rows: props.rows,
		},
		sourceEpoch: props.sourceEpoch,
		workerDerivationEpoch: 1,
	};
}

import type { z } from 'zod';

import type { BridgeCommWorkerReviewBatchPresentation } from './bridge-comm-worker-review-batch-installer.js';
import { reviewRuntimeChangedItemIds } from './bridge-comm-worker-review-runtime-index.js';
import type { bridgeProductReviewRefreshImpactSchema } from './bridge-product-review-metadata-contracts.js';
import type { BridgeWorkerReviewCandidateStartDisposition } from './bridge-worker-contracts.js';

export type BridgeProductReviewRefreshImpact = z.infer<
	typeof bridgeProductReviewRefreshImpactSchema
>;

export function reviewCandidateStartDispositionFromRefreshImpact(props: {
	readonly impact: BridgeProductReviewRefreshImpact | null;
	readonly previous: BridgeCommWorkerReviewBatchPresentation | null;
	readonly successor: BridgeCommWorkerReviewBatchPresentation;
}): BridgeWorkerReviewCandidateStartDisposition {
	const { impact, previous, successor } = props;
	if (impact === null) return { kind: 'replacement' };
	if (
		previous === null ||
		(impact.preDeliveryPresentationClass.kind === 'promoted' &&
			impact.preDeliveryPresentationClass.reason === 'unknown')
	) {
		return {
			affectedStableFileIdentities: impact.affectedStableFileIdentities,
			kind: 'sameSource',
			presentationClass: impact.preDeliveryPresentationClass,
		};
	}
	const affectedStableFileIdentities = reviewRuntimeChangedItemIds(
		previous.runtimeSource,
		successor.runtimeSource,
	);
	return {
		affectedStableFileIdentities,
		kind: 'sameSource',
		presentationClass: impact.preDeliveryPresentationClass,
	};
}

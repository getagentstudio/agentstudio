import { z } from 'zod';

import { bridgeProductReviewComparisonPresentationSchema } from './bridge-product-review-comparison-presentation-contracts.js';
import { bridgeWorkerPanelChromePatchPayloadSchema } from './bridge-worker-panel-chrome-contracts.js';

export const bridgeMainReviewFailureKindSchema = z.enum([
	'targetNotFound',
	'targetMismatch',
	'defaultTargetUnavailable',
	'refreshUnavailable',
]);
export type BridgeMainReviewFailureKind = z.infer<typeof bridgeMainReviewFailureKindSchema>;

function decodeReviewFailureKind(failureKind: string): BridgeMainReviewFailureKind {
	// Package/provider errors do not establish invalid target authority. Unknown wire reasons stay refresh-scoped.
	return failureKind === 'targetNotFound' ||
		failureKind === 'targetMismatch' ||
		failureKind === 'defaultTargetUnavailable'
		? failureKind
		: 'refreshUnavailable';
}

export const bridgeMainReviewComparisonPresentationSchema =
	bridgeProductReviewComparisonPresentationSchema.transform((presentation) => ({
		...presentation,
		attempt:
			presentation.attempt.status === 'unavailable'
				? {
						...presentation.attempt,
						failureKind: decodeReviewFailureKind(presentation.attempt.failureKind),
					}
				: presentation.attempt,
	}));
export type BridgeMainReviewComparisonPresentation = z.infer<
	typeof bridgeMainReviewComparisonPresentationSchema
>;

export const bridgeMainPanelChromeSliceSchema = bridgeWorkerPanelChromePatchPayloadSchema
	.omit({ reviewComparison: true })
	.extend({ reviewComparison: bridgeMainReviewComparisonPresentationSchema.nullable().optional() });
export type BridgeMainPanelChromeSlice = z.infer<typeof bridgeMainPanelChromeSliceSchema>;

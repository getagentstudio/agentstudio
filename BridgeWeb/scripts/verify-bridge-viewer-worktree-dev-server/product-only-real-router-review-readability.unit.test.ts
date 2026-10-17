import { expect, test } from 'vitest';

import { makePassingProductOnlyProof } from './product-only-real-router-contract.test-support.ts';
import { collectBridgeViewerProductOnlyContractViolations } from './product-only-real-router-contract.ts';

// Every other obligation passes; only the recorded window is unreadable.
test.each(['forward', 'backward'] as const)(
	'rejects one recorded %s placeholder window',
	(direction) => {
		const passing = makePassingProductOnlyProof();
		const windowFailure = {
			hydratedNonSelectedItemIds: [],
			readableNonSelectedItemIds: [],
			scrollTop: 100,
			visibleContentStates: [{ contentState: 'placeholder', itemId: 'review-item-2' }],
			visibleNonSelectedItemIds: ['review-item-2'],
		};
		const proof = {
			...passing,
			reviewFreshRoute: {
				...passing.reviewFreshRoute,
				...(direction === 'forward'
					? {
							hydrationCoverage: {
								...passing.reviewFreshRoute.hydrationCoverage,
								missingHydratedVisibleWindows: [windowFailure],
							},
						}
					: {
							backwardTraversal: {
								...passing.reviewFreshRoute.backwardTraversal,
								hydrationCoverage: {
									...passing.reviewFreshRoute.backwardTraversal.hydrationCoverage,
									missingHydratedVisibleWindows: [windowFailure],
								},
							},
						}),
			},
		};
		expect(
			collectBridgeViewerProductOnlyContractViolations(proof).map((violation) => violation.code),
		).toEqual([
			direction === 'forward'
				? 'REVIEW_FRESH_ROUTE_VISIBLE_READABLE_MISSING'
				: 'REVIEW_FRESH_ROUTE_BACKWARD_READABLE_INVALID',
		]);
	},
);

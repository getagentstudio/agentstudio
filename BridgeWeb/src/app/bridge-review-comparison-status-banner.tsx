import type { ReactElement } from 'react';

import type { BridgeReviewComparisonPaneState } from './bridge-review-comparison-pane-state.js';
import type { BridgeReviewComparisonTarget } from './bridge-review-comparison-target.js';

/** Comparison failure belongs to the pane summary; this is only an accessible loading status. */
export function BridgeReviewComparisonStatusBanner(props: {
	readonly onRetry: (target: BridgeReviewComparisonTarget) => void;
	readonly state: BridgeReviewComparisonPaneState;
}): ReactElement | null {
	if (props.state.kind !== 'loadingInitial' && props.state.kind !== 'loadingPrevious') return null;
	return (
		<span
			aria-atomic="true"
			aria-live="polite"
			className="sr-only"
			data-testid="bridge-review-comparison-loading-status"
			role="status"
		>
			Loading comparison with {props.state.requestedTargetLabel}…
		</span>
	);
}

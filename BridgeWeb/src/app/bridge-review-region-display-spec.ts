import type { BridgeMainReviewFailureKind } from '../core/comm-worker/bridge-main-review-comparison-presentation.js';

export const bridgeReviewRegionDisplaySpec = {
	noSource: 'This pane has no worktree',
	certifiedContent: 'Nothing to review',
	certifiedTree: 'No changed files',
	noSelection: 'Choose a comparison target',
	noFileSelection: 'No file selected',
	stale: 'Showing last update · stale',
	staleComparison: 'Stale',
	updating: 'Updating…',
	updateUnavailable: 'Update unavailable',
	contentUnavailable: 'Content unavailable',
	contentCorrectiveAction: 'Open this file in an external editor.',
	comparisonUnavailable: 'Comparison unavailable',
	refreshCorrectiveAction: 'Correct the Review source, then refresh.',
	targetCorrectiveAction: 'Choose an available comparison target.',
} as const;

export function bridgeReviewFailureDisplaySpec(failureKind: BridgeMainReviewFailureKind): {
	readonly message: string;
	readonly correctiveAction: string;
} {
	return failureKind === 'refreshUnavailable'
		? {
				message: bridgeReviewRegionDisplaySpec.updateUnavailable,
				correctiveAction: bridgeReviewRegionDisplaySpec.refreshCorrectiveAction,
			}
		: {
				message: bridgeReviewRegionDisplaySpec.comparisonUnavailable,
				correctiveAction: bridgeReviewRegionDisplaySpec.targetCorrectiveAction,
			};
}

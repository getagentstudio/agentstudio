import {
	projectBridgeRegionPresentation,
	type BridgeRegionFailure,
	type BridgeRegionPresentationState,
	type BridgeRegionReadState,
	type BridgeRegionSurfaceStatus,
} from '../../app/bridge-region-presentation-state.js';
import type { BridgeReviewComparisonPaneState } from '../../app/bridge-review-comparison-pane-state.js';
import {
	bridgeReviewFailureDisplaySpec,
	bridgeReviewRegionDisplaySpec,
} from '../../app/bridge-review-region-display-spec.js';
import type {
	BridgeMainReviewRefreshPresentation,
	BridgeMainViewRecoveryStatus,
} from '../../core/comm-worker/bridge-main-render-snapshot-store.js';

export function bridgeReviewRegionSurfaceStatus(props: {
	readonly comparisonPaneState: BridgeReviewComparisonPaneState;
	readonly recoveryStatus?: BridgeMainViewRecoveryStatus | null;
	readonly refreshPresentation?: BridgeMainReviewRefreshPresentation;
	readonly isActive?: boolean;
}): BridgeRegionSurfaceStatus {
	if (props.recoveryStatus?.status === 'failedRetryable')
		return {
			kind: 'failed',
			failure: {
				kind: 'retryable',
				scope: 'surface',
				message: bridgeReviewRegionDisplaySpec.updateUnavailable,
			},
		};
	const comparison = props.comparisonPaneState;
	if (comparison.kind === 'failedInitial' || comparison.kind === 'failedPrevious') {
		const display = bridgeReviewFailureDisplaySpec(comparison.failureKind);
		const failure: BridgeRegionFailure =
			comparison.retryTarget === null
				? { kind: 'permanent', scope: 'surface', ...display }
				: { kind: 'retryable', scope: 'surface', message: display.message };
		return { kind: 'failed', failure };
	}
	const refresh = props.refreshPresentation;
	if (refresh?.failure != null)
		return {
			kind: 'failed',
			failure: refresh.failure.retryable
				? {
						kind: 'retryable',
						scope: 'surface',
						message: bridgeReviewRegionDisplaySpec.updateUnavailable,
					}
				: {
						kind: 'permanent',
						scope: 'surface',
						message: bridgeReviewRegionDisplaySpec.updateUnavailable,
						correctiveAction: bridgeReviewRegionDisplaySpec.refreshCorrectiveAction,
					},
		};
	if (
		props.recoveryStatus?.status === 'recovering' ||
		refresh?.candidate != null ||
		comparison.kind === 'loadingPrevious'
	)
		return {
			kind: 'updating',
			...(props.isActive === false
				? { rest: 'hidden' as const }
				: refresh?.candidate?.role === 'updateReady'
					? { rest: 'held' as const }
					: {}),
		};
	return { kind: 'current' };
}

export function bridgeReviewFallbackRegionPresentation(props: {
	readonly surface?: BridgeRegionSurfaceStatus;
	readonly status: 'noSource' | 'noSelection' | 'certifiedEmpty' | 'loading' | 'failed';
	readonly comparisonPaneState: BridgeReviewComparisonPaneState;
	readonly recoveryStatus?: BridgeMainViewRecoveryStatus | null;
}): BridgeRegionPresentationState {
	const surface = props.surface ?? bridgeReviewRegionSurfaceStatus(props);
	if (props.status === 'failed' && surface.kind !== 'failed')
		return {
			kind: 'failed',
			retainsContent: false,
			failure: {
				kind: 'retryable',
				scope: 'surface',
				message: bridgeReviewRegionDisplaySpec.updateUnavailable,
			},
		};
	const loading =
		props.status === 'loading' ||
		(props.status !== 'certifiedEmpty' &&
			props.status !== 'noSource' &&
			props.comparisonPaneState.kind === 'loadingInitial');
	return projectBridgeRegionPresentation({
		demandedIdentity: props.status === 'noSelection' && !loading ? null : 'review',
		read:
			props.status === 'noSource'
				? { kind: 'noSource' }
				: props.status === 'certifiedEmpty'
					? { kind: 'complete', identity: 'review', hasContent: false }
					: { kind: 'loading' },
		surface: surface.kind === 'failed' ? surface : loading ? { kind: 'loading' } : surface,
	});
}

export function bridgeReviewReadyRegionPresentation(props: {
	readonly region: 'content' | 'tree';
	readonly identity: string;
	readonly hasChangedFiles: boolean;
	readonly hasSelectedItem: boolean;
	readonly selectedContentLoading: boolean;
	readonly selectedContentFailure: BridgeRegionFailure | null;
	readonly surface: BridgeRegionSurfaceStatus;
}): BridgeRegionPresentationState {
	let read: BridgeRegionReadState = {
		kind: 'complete',
		identity: props.identity,
		hasContent: props.hasChangedFiles,
	};
	let demandedIdentity: string | null = props.identity;
	if (props.region === 'content' && props.hasChangedFiles) {
		if (!props.hasSelectedItem) demandedIdentity = null;
		else if (props.selectedContentFailure !== null)
			read = {
				kind: 'failed',
				retainedIdentity: null,
				failure: props.selectedContentFailure,
			};
		else if (props.selectedContentLoading) read = { kind: 'loading' };
	}
	return projectBridgeRegionPresentation({ demandedIdentity, read, surface: props.surface });
}

export function bridgeReviewSelectedContentReadFailure(
	state: 'failed' | 'unavailable',
): BridgeRegionFailure {
	return state === 'failed'
		? { kind: 'retryable', scope: 'read', message: bridgeReviewRegionDisplaySpec.updateUnavailable }
		: {
				kind: 'permanent',
				scope: 'read',
				message: bridgeReviewRegionDisplaySpec.contentUnavailable,
				correctiveAction: bridgeReviewRegionDisplaySpec.contentCorrectiveAction,
			};
}

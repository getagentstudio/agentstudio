import { bridgePaneFailureDisplaySpec } from '../app/bridge-pane-failure-summary.js';
import {
	projectBridgeRegionPresentation,
	type BridgeRegionPresentationState,
	type BridgeRegionSurfaceStatus,
} from '../app/bridge-region-presentation-state.js';
import type { WorktreeAnnotationProjectionSnapshot } from './worktree-annotation-projection-store.js';
import type { WorktreeAnnotationSharePreviewReadiness } from './worktree-annotation-share-preview.js';

export function worktreeAnnotationSurfacePresentationStatus(
	readStatus: WorktreeAnnotationProjectionSnapshot['readStatus'],
): BridgeRegionSurfaceStatus {
	if (readStatus.kind === 'unavailable')
		return {
			kind: 'failed',
			failure: readStatus.retryable
				? { kind: 'retryable', scope: 'surface', message: bridgePaneFailureDisplaySpec.comments }
				: {
						kind: 'permanent',
						scope: 'surface',
						message: bridgePaneFailureDisplaySpec.comments,
						correctiveAction: bridgePaneFailureDisplaySpec.commentsCorrectiveAction,
					},
		};
	return readStatus.kind === 'refreshing' ? { kind: 'updating' } : { kind: 'current' };
}

export function worktreeAnnotationRegionPresentation(props: {
	readonly readiness: WorktreeAnnotationSharePreviewReadiness;
	readonly hasContent: boolean;
	readonly hasSelection: boolean;
	readonly surface?: BridgeRegionSurfaceStatus;
}): BridgeRegionPresentationState {
	const surface: BridgeRegionSurfaceStatus =
		props.surface ??
		(props.readiness === 'unconfirmed' ? { kind: 'updating' } : { kind: 'current' });
	const certified = surface.kind === 'current' && props.readiness !== 'unknown';
	return projectBridgeRegionPresentation({
		demandedIdentity: props.hasSelection ? 'comments' : null,
		read: {
			kind: certified ? 'complete' : 'partial',
			identity: 'comments',
			hasContent: props.hasContent,
		},
		surface,
	});
}

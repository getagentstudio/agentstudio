import { useSyncExternalStore, type ReactElement } from 'react';

import {
	worktreeAnnotationRegionPresentation,
	worktreeAnnotationSurfacePresentationStatus,
} from '../worktree-annotations/worktree-annotation-region-presentation.js';
import {
	useOptionalWorktreeAnnotationSurfaceClient,
	useWorktreeAnnotationProjection,
} from '../worktree-annotations/worktree-annotation-surface-provider.js';
import {
	bridgePaneFailureDisplaySpec,
	type BridgePaneFailureEntry,
} from './bridge-pane-failure-summary.js';
import type { BridgePaneReloadPort } from './bridge-pane-reload-port.js';
import { BridgePaneFailureMessage } from './bridge-region-presentation.js';
import { BridgeViewerRecoveryRetryButton } from './bridge-viewer-recovery-retry-button.js';

/** Reads existing Comments facts alongside the active shell's exact region outputs. */
export function BridgePaneFailureSummarySlot(props: {
	readonly entries: readonly BridgePaneFailureEntry[];
	readonly paneReloadPort?: BridgePaneReloadPort | undefined;
	readonly active?: boolean | undefined;
}): ReactElement | null {
	const annotationClient = useOptionalWorktreeAnnotationSurfaceClient();
	const projection = useWorktreeAnnotationProjection();
	const recovery = useSyncExternalStore(
		annotationClient?.subscribeViewRecoveryStatus ?? noSubscription,
		annotationClient?.getViewRecoveryStatus ?? noRecovery,
		annotationClient?.getViewRecoveryStatus ?? noRecovery,
	);
	const commentsSurface =
		recovery?.status === 'failedRetryable'
			? {
					kind: 'failed' as const,
					failure: {
						kind: 'retryable' as const,
						scope: 'surface' as const,
						message: bridgePaneFailureDisplaySpec.comments,
					},
				}
			: worktreeAnnotationSurfacePresentationStatus(projection.readStatus);
	const commentsState = worktreeAnnotationRegionPresentation({
		readiness: projection.revision === null ? 'unknown' : 'current',
		hasContent: projection.threads.length > 0,
		hasSelection: true,
		surface: commentsSurface,
	});
	if (props.active === false) return null;
	return (
		<BridgePaneFailureMessage
			entries={[
				...props.entries,
				{
					part: 'comments',
					state: commentsState,
					retry:
						annotationClient === null
							? undefined
							: (): void => {
									annotationClient.retryViewRecovery();
									annotationClient.retryProjection();
								},
				},
			]}
			paneReloadPort={props.paneReloadPort}
			retryControl={(onClick): ReactElement => (
				<BridgeViewerRecoveryRetryButton surface="pane" onClick={onClick} />
			)}
		/>
	);
}

function noSubscription(): () => void {
	return (): void => {};
}
function noRecovery(): null {
	return null;
}

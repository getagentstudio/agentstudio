import {
	projectBridgeRegionPresentation,
	type BridgeRegionPresentationState,
	type BridgeRegionSurfaceStatus,
} from '../app/bridge-region-presentation-state.js';
import type { BridgeWorkerPanelChromePatchPayload } from '../core/comm-worker/bridge-worker-contracts.js';
import type {
	BridgeFileViewerDisplayModel,
	BridgeFileViewerOpenState,
} from './bridge-file-viewer-display-model.js';

export function bridgeFileSurfacePresentationStatus(props: {
	readonly displayModel: BridgeFileViewerDisplayModel;
	readonly panelChrome: BridgeWorkerPanelChromePatchPayload;
	readonly recoveryFailed: boolean;
	readonly isActive: boolean;
}): BridgeRegionSurfaceStatus {
	if (
		props.recoveryFailed ||
		props.panelChrome.fileRefreshFailure != null ||
		props.displayModel.status?.state === 'failed'
	) {
		const message = props.panelChrome.message ?? 'Files unavailable';
		const failureKind = props.panelChrome.fileRefreshFailure?.failureKind;
		const fileRootCause =
			failureKind === 'missingRoot' || failureKind === 'unreadableRoot' ? failureKind : undefined;
		return {
			kind: 'failed',
			failure:
				props.panelChrome.fileRefreshFailure?.retryable === false
					? {
							kind: 'permanent',
							scope: 'surface',
							message,
							correctiveAction: 'Correct the source failure, then reopen this worktree.',
						}
					: {
							kind: 'retryable',
							scope: 'surface',
							message,
							...(fileRootCause === undefined ? {} : { fileRootCause }),
						},
		};
	}
	if (props.panelChrome.isLoading || props.displayModel.status?.state === 'stale')
		return { kind: 'updating', ...(!props.isActive ? { rest: 'hidden' } : {}) };
	return { kind: 'current' };
}

export function bridgeFileTreePresentation(props: {
	readonly displayModel: BridgeFileViewerDisplayModel;
	readonly surface: BridgeRegionSurfaceStatus;
}): BridgeRegionPresentationState {
	const identity = props.displayModel.source?.sourceId ?? 'file-inventory';
	return projectBridgeRegionPresentation({
		demandedIdentity: identity,
		read:
			props.displayModel.status?.state === 'noSource'
				? { kind: 'noSource' }
				: props.displayModel.source === null
					? { kind: 'loading' }
					: {
							kind: props.displayModel.status?.state === 'ready' ? 'complete' : 'partial',
							identity,
							hasContent: props.displayModel.totalRowCount > 0,
						},
		surface: props.surface,
	});
}

export function bridgeFileContentPresentation(props: {
	readonly noSource?: boolean;
	readonly openFileState: BridgeFileViewerOpenState;
	readonly displayedFileId: string | null;
	readonly surface: BridgeRegionSurfaceStatus;
}): BridgeRegionPresentationState {
	const openState = props.openFileState;
	return projectBridgeRegionPresentation({
		demandedIdentity: openState.status === 'idle' ? null : openState.fileId,
		read: props.noSource
			? { kind: 'noSource' }
			: openState.status === 'failed' || openState.status === 'unavailable'
				? {
						kind: 'failed',
						retainedIdentity: props.displayedFileId,
						failure:
							openState.status === 'unavailable'
								? {
										kind: 'permanent',
										scope: 'read',
										message: 'Content unavailable',
										correctiveAction: 'Open this file in an external editor.',
									}
								: { kind: 'retryable', scope: 'read', message: 'File content could not be read' },
					}
				: props.displayedFileId === null
					? { kind: 'loading' }
					: { kind: 'complete', identity: props.displayedFileId, hasContent: true },
		surface:
			openState.status === 'stale' || openState.status === 'loading'
				? props.surface.kind === 'failed'
					? props.surface
					: { kind: 'updating' }
				: props.surface,
	});
}

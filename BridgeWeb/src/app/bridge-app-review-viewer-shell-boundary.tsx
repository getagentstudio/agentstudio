import type { ReactElement, ReactNode } from 'react';
import { lazy, Suspense, useEffect, useState } from 'react';

import type { BridgeMainViewRecoveryStatus } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import { bridgeReviewFallbackRegionPresentation } from '../features/review/bridge-review-region-presentation.js';
import { BridgeReviewFallbackShell } from '../review-viewer/shell/review-viewer-fallback-shells.js';
import type { ReviewViewerShellProps } from '../review-viewer/shell/review-viewer-shell.js';
import type { BridgePaneReloadPort } from './bridge-pane-reload-port.js';
import type { BridgeRegionSurfaceStatus } from './bridge-region-presentation-state.js';
import type { BridgeReviewComparisonPaneState } from './bridge-review-comparison-pane-state.js';
import type { BridgeReviewComparisonTarget } from './bridge-review-comparison-target.js';

const LazyReviewViewerShell = lazy(async () => {
	const module = await import('../review-viewer/shell/review-viewer-shell.js');
	return { default: module.ReviewViewerShell };
});
export type BridgeReviewViewerPresentationState =
	| {
			readonly status:
				| 'noSource'
				| 'noTarget'
				| 'readyEmpty'
				| 'metadataLoading'
				| 'projectionPending'
				| 'projectionFailed';
	  }
	| { readonly status: 'metadataFailed'; readonly error: string | null }
	| {
			readonly status: 'ready';
			readonly presentationKey: string;
			readonly shellProps: Omit<
				ReviewViewerShellProps,
				'isActive' | 'viewerContextSwitcher' | 'viewerHeaderControls'
			>;
	  };
export interface BridgeReviewViewerShellBoundaryProps {
	readonly paneReloadPort?: BridgePaneReloadPort | undefined;
	readonly railVisible?: boolean | undefined;
	readonly regionSurfaceStatus?: BridgeRegionSurfaceStatus;
	readonly comparisonPaneState: BridgeReviewComparisonPaneState;
	readonly isActive: boolean;
	readonly onRetryComparison: (target: BridgeReviewComparisonTarget) => void;
	readonly onRetryMetadata?: () => void;
	readonly recoveryStatus?: BridgeMainViewRecoveryStatus | null;
	readonly presentationState: BridgeReviewViewerPresentationState;
	readonly viewerContextSwitcher: ReactNode;
	readonly viewerHeaderControls: ReactNode;
}
export function BridgeReviewViewerShellBoundary(
	props: BridgeReviewViewerShellBoundaryProps,
): ReactElement {
	const [hasActivatedReadyPresentation, setHasActivatedReadyPresentation] = useState(false);
	useEffect((): void => {
		if (props.presentationState.status !== 'ready') setHasActivatedReadyPresentation(false);
		else if (props.isActive) setHasActivatedReadyPresentation(true);
	}, [props.isActive, props.presentationState]);
	const fallback = (pendingModule = false): ReactElement => {
		const status = props.presentationState.status;
		const regionStatus = pendingModule ? 'loading' : bridgeReviewFallbackStatus(status);
		const comparison = props.comparisonPaneState;
		const retryTarget =
			comparison.kind === 'failedInitial' || comparison.kind === 'failedPrevious'
				? comparison.retryTarget
				: null;
		const state = bridgeReviewFallbackRegionPresentation({
			...(props.regionSurfaceStatus === undefined ? {} : { surface: props.regionSurfaceStatus }),
			status: regionStatus,
			comparisonPaneState: comparison,
			...(props.recoveryStatus === undefined ? {} : { recoveryStatus: props.recoveryStatus }),
		});
		const contentTestId =
			state.kind === 'failed'
				? 'bridge-review-metadata-failed-shell'
				: state.kind === 'loading'
					? 'bridge-review-metadata-loading-shell'
					: status === 'readyEmpty'
						? 'bridge-review-empty-canvas'
						: 'bridge-review-empty-shell';
		return (
			<BridgeReviewFallbackShell
				paneReloadPort={props.paneReloadPort}
				railVisible={props.railVisible}
				certifiedEmpty={status === 'readyEmpty'}
				state={state}
				contentTestId={contentTestId}
				isActive={props.isActive}
				onRetry={
					props.onRetryMetadata ??
					(retryTarget === null ? undefined : (): void => props.onRetryComparison(retryTarget))
				}
				viewerContextSwitcher={props.viewerContextSwitcher}
				viewerHeaderControls={props.viewerHeaderControls}
			/>
		);
	};
	if (props.presentationState.status !== 'ready') return fallback();
	if (!props.isActive && !hasActivatedReadyPresentation) return fallback(true);
	return (
		<Suspense fallback={fallback(true)}>
			<LazyReviewViewerShell
				{...props.presentationState.shellProps}
				isActive={props.isActive}
				viewerContextSwitcher={props.viewerContextSwitcher}
				viewerHeaderControls={props.viewerHeaderControls}
			/>
		</Suspense>
	);
}

function bridgeReviewFallbackStatus(
	status: BridgeReviewViewerPresentationState['status'],
): Parameters<typeof bridgeReviewFallbackRegionPresentation>[0]['status'] {
	switch (status) {
		case 'noSource':
			return 'noSource';
		case 'noTarget':
			return 'noSelection';
		case 'readyEmpty':
			return 'certifiedEmpty';
		case 'metadataLoading':
		case 'projectionPending':
		case 'ready':
			return 'loading';
		case 'metadataFailed':
		case 'projectionFailed':
			return 'failed';
		default:
			return assertNeverReviewPresentationStatus(status);
	}
}

function assertNeverReviewPresentationStatus(status: never): never {
	throw new Error(`Unexpected Review presentation status: ${String(status)}`);
}

import type { ReactElement, ReactNode } from 'react';

import { BridgePaneFailureSummarySlot } from '../../app/bridge-pane-failure-summary-slot.js';
import type { BridgePaneReloadPort } from '../../app/bridge-pane-reload-port.js';
import type { BridgeRegionPresentationState } from '../../app/bridge-region-presentation-state.js';
import { BridgeRegionPresentation } from '../../app/bridge-region-presentation.js';
import { bridgeReviewRegionDisplaySpec } from '../../app/bridge-review-region-display-spec.js';
import { BridgeViewerContentHeader } from '../../app/bridge-viewer-content-header.js';
import {
	BridgeViewerContextPanelProvider,
	BridgeViewerContextPanelViewport,
} from '../../app/bridge-viewer-context-panel-host.js';
import { BridgeViewerRailToolbar } from '../../app/bridge-viewer-rail-toolbar.js';
import { BridgeViewerResizableRailLayout } from '../../app/bridge-viewer-resizable-rail-layout.js';
import { BridgeViewerRightRailShell } from '../../app/bridge-viewer-right-rail-shell.js';

export function BridgeReviewFallbackShell(props: {
	readonly paneReloadPort?: BridgePaneReloadPort | undefined;
	readonly railVisible?: boolean | undefined;
	readonly certifiedEmpty: boolean;
	readonly state: BridgeRegionPresentationState;
	readonly contentTestId: string;
	readonly onRetry?: (() => void) | undefined;
	readonly isActive?: boolean | undefined;
	readonly viewerContextSwitcher?: ReactNode;
	readonly viewerHeaderControls?: ReactNode;
}): ReactElement {
	const failureSummary = (
		<BridgePaneFailureSummarySlot
			active={props.isActive}
			paneReloadPort={props.paneReloadPort}
			entries={[{ part: 'review', state: props.state, retry: props.onRetry }]}
		/>
	);
	return (
		<main
			className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-background text-foreground"
			data-testid="bridge-review-fallback-frame"
		>
			<BridgeViewerResizableRailLayout
				railVisible={props.railVisible}
				failureSummary={failureSummary}
				autosaveId="bridge-viewer-right-rail"
				isActive={props.isActive}
				content={
					<BridgeViewerContextPanelProvider>
						<section className="grid h-full min-h-0 min-w-0 grid-rows-[auto_minmax(0,1fr)] overflow-hidden">
							<BridgeViewerContentHeader
								controls={props.viewerHeaderControls}
								mode="review"
								statusText={null}
								title="Bridge Review"
							/>
							<BridgeViewerContextPanelViewport testId="bridge-review-context-panel-viewport">
								<section
									className="h-full min-h-0 min-w-0 bg-background"
									data-testid="bridge-review-fallback-canvas"
								>
									<div className="h-full min-h-0" data-testid={props.contentTestId}>
										<BridgeRegionPresentation
											region="review-content"
											shape="diff"
											state={props.state}
											emptyCopy={{
												noSource: bridgeReviewRegionDisplaySpec.noSource,
												noSelection: bridgeReviewRegionDisplaySpec.noSelection,
												certified: bridgeReviewRegionDisplaySpec.certifiedContent,
											}}
										>
											{props.certifiedEmpty ? (
												<p className="px-3 py-2 text-sm text-muted-foreground">
													{bridgeReviewRegionDisplaySpec.certifiedContent}
												</p>
											) : null}
										</BridgeRegionPresentation>
									</div>
								</section>
							</BridgeViewerContextPanelViewport>
						</section>
					</BridgeViewerContextPanelProvider>
				}
				contentTestId="bridge-review-content-panel"
				handleTestId="bridge-review-rail-resize-handle"
				rail={BridgeViewerRightRailShell({
					body: (
						<BridgeRegionPresentation
							region="review-tree"
							shape="tree"
							state={props.state}
							emptyCopy={{
								noSource: bridgeReviewRegionDisplaySpec.noSource,
								noSelection: bridgeReviewRegionDisplaySpec.noSelection,
								certified: bridgeReviewRegionDisplaySpec.certifiedTree,
							}}
						>
							{props.certifiedEmpty ? (
								<p className="px-3 py-2 text-sm text-muted-foreground">
									{bridgeReviewRegionDisplaySpec.certifiedTree}
								</p>
							) : null}
						</BridgeRegionPresentation>
					),
					bodyClassName: 'min-h-0 flex-1 overflow-hidden overscroll-contain p-3',
					bodyTestId: 'bridge-review-rail-scroll',
					layout: 'stack',
					toolbarBelow: props.railVisible === false ? null : failureSummary,
					testId: 'bridge-review-sidebar',
					toolbar: BridgeViewerRailToolbar({
						leading: props.viewerContextSwitcher,
						leadingTestId: 'bridge-review-rail-toolbar-leading',
						testId: 'bridge-review-rail-toolbar',
						trailing: null,
						trailingTestId: 'bridge-review-rail-toolbar-trailing',
					}),
				})}
				railTestId="bridge-review-resizable-rail"
			/>
		</main>
	);
}

import { useCallback, useEffect, useRef, useState, type ReactElement } from 'react';

import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeActiveViewerSource } from '../core/comm-worker/bridge-product-control-contracts.js';
import type { BridgeProductNavigationCommand } from '../core/comm-worker/bridge-product-session-contracts.js';
import type { BridgePaneFailedStartFact } from '../core/models/bridge-pane-failed-start.js';
import {
	BridgeFileViewerApp,
	type BridgeFileViewerAppProps,
} from '../file-viewer/bridge-file-viewer-app.js';
import {
	bridgeFileViewerDisplayModelForSnapshot,
	type BridgeFileViewerDisplaySource,
} from '../file-viewer/bridge-file-viewer-display-model.js';
import {
	BridgeFileViewerSurfaceClientProvider,
	useBridgeFileViewerRenderSnapshotController,
} from '../file-viewer/bridge-file-viewer-render-snapshot-controller.js';
import { useBridgeFileViewerDisplaySourceReporter } from '../file-viewer/use-bridge-file-viewer-display-source-reporter.js';
import { startBridgeFrameJankProbe } from '../foundation/diagnostics/bridge-frame-jank-probe.js';
import { startBridgeFrameLivenessProbe } from '../foundation/diagnostics/bridge-frame-liveness-probe.js';
import type { BridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import { recordBridgeFrameJankTelemetrySample } from '../foundation/telemetry/bridge-viewer-telemetry-adapter.js';
import { WorktreeAnnotationSurfaceProvider } from '../worktree-annotations/worktree-annotation-surface-provider.js';
import type { BridgeAppNavigationSource } from './bridge-app-navigation-admission.js';
import type { BridgePaneReloadPort } from './bridge-pane-reload-port.js';
import type { BridgeMermaidRenderer } from './markdown/bridge-mermaid-renderer.js';
import type { BridgeMarkdownRenderWorkerClient } from './markdown/worker/bridge-markdown-render-worker-client.js';

export interface BridgeFileViewerModeProps {
	readonly paneReloadPort?: BridgePaneReloadPort | undefined;
	readonly paneFailedStart?: BridgePaneFailedStartFact | null;
	readonly controlTarget: EventTarget;
	readonly codeViewWorkerFactory?: () => Worker;
	readonly codeViewWorkerPoolEnabled?: boolean;
	readonly fileViewClient: BridgePaneSurfaceClient;
	readonly fileViewerProps?: BridgeFileViewerAppProps;
	readonly isNavigationCommandStillEligible: (
		command: Extract<
			BridgeProductNavigationCommand,
			{ readonly commandKind: 'activateTarget'; readonly surface: 'file' }
		>,
	) => boolean;
	readonly isActive: boolean;
	readonly markdownWorkerClient: BridgeMarkdownRenderWorkerClient | null;
	readonly mermaidRenderer: BridgeMermaidRenderer;
	readonly navigationCommand?: Extract<
		BridgeProductNavigationCommand,
		{ readonly commandKind: 'activateTarget'; readonly surface: 'file' }
	>;
	readonly onActiveSourceChange: (activeSource: BridgeActiveViewerSource | null) => void;
	readonly onNavigationSourceChange: (
		source: Extract<BridgeAppNavigationSource, { readonly sourceKind: 'file' }> | null,
	) => void;
	readonly requiresNavigationSourceDiscovery: boolean;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly viewerContextSwitcher: ReactElement;
}

export function BridgeFileViewerMode(props: BridgeFileViewerModeProps): ReactElement {
	const { onActiveSourceChange, onNavigationSourceChange } = props;
	const [hasActivatedFileViewerShell, setHasActivatedFileViewerShell] = useState(props.isActive);
	const isActiveRef = useRef(props.isActive);
	isActiveRef.current = props.isActive;
	useEffect((): (() => void) => startBridgeFrameLivenessProbe(), []);
	useEffect(
		(): (() => void) =>
			startBridgeFrameJankProbe({
				onJankSample: (sample): void => {
					recordBridgeFrameJankTelemetrySample({
						...sample,
						telemetryRecorder: props.telemetryRecorder,
						traceContext: null,
						viewer: 'file',
						viewerIsActive: isActiveRef.current,
					});
				},
			}),
		[props.telemetryRecorder],
	);
	useEffect((): void => {
		if (props.isActive) {
			setHasActivatedFileViewerShell(true);
		}
	}, [props.isActive]);
	const reportNavigationDisplaySource = useCallback(
		(source: BridgeFileViewerDisplaySource | null): void => {
			onNavigationSourceChange(
				source === null
					? null
					: {
							sourceId: source.sourceId,
							sourceKind: 'file',
							subscriptionGeneration: source.generation,
						},
			);
		},
		[onNavigationSourceChange],
	);
	const reportDisplaySource = useCallback(
		(source: BridgeFileViewerDisplaySource | null): void => {
			onActiveSourceChange(
				source === null
					? null
					: {
							generation: source.generation,
							protocol: 'worktree-file',
							streamId: source.sourceId,
						},
			);
			reportNavigationDisplaySource(source);
		},
		[onActiveSourceChange, reportNavigationDisplaySource],
	);

	return (
		<BridgeFileViewerSurfaceClientProvider surfaceClient={props.fileViewClient}>
			<WorktreeAnnotationSurfaceProvider
				markdownWorkerClient={props.markdownWorkerClient}
				surfaceClient={props.fileViewClient}
				telemetryRecorder={props.telemetryRecorder}
			>
				{!props.isActive && !hasActivatedFileViewerShell ? (
					!props.requiresNavigationSourceDiscovery ? null : (
						<BridgeFileViewerHeadlessController
							onDisplaySourceChange={reportNavigationDisplaySource}
						/>
					)
				) : (
					<BridgeFileViewerApp
						paneReloadPort={props.paneReloadPort}
						paneFailedStart={props.paneFailedStart ?? null}
						{...props.fileViewerProps}
						{...(props.codeViewWorkerFactory === undefined
							? {}
							: { codeViewWorkerFactory: props.codeViewWorkerFactory })}
						{...(props.codeViewWorkerPoolEnabled === undefined
							? {}
							: { codeViewWorkerPoolEnabled: props.codeViewWorkerPoolEnabled })}
						isActive={props.isActive}
						markdownWorkerClient={props.markdownWorkerClient}
						mermaidRenderer={props.mermaidRenderer}
						isNavigationCommandStillEligible={props.isNavigationCommandStillEligible}
						controlTarget={props.controlTarget}
						{...(props.navigationCommand === undefined
							? {}
							: { navigationCommand: props.navigationCommand })}
						onDisplaySourceChange={reportDisplaySource}
						telemetryRecorder={props.telemetryRecorder}
						telemetryTraceContext={null}
						viewerContextSwitcher={props.viewerContextSwitcher}
					/>
				)}
			</WorktreeAnnotationSurfaceProvider>
		</BridgeFileViewerSurfaceClientProvider>
	);
}

function BridgeFileViewerHeadlessController(props: {
	readonly onDisplaySourceChange: (source: BridgeFileViewerDisplaySource | null) => void;
}): ReactElement {
	const renderSnapshotController = useBridgeFileViewerRenderSnapshotController({ selection: null });
	const displayModel = bridgeFileViewerDisplayModelForSnapshot(
		renderSnapshotController.fileDisplaySnapshot,
	);
	useBridgeFileViewerDisplaySourceReporter({
		onDisplaySourceChange: props.onDisplaySourceChange,
		source: displayModel.source,
	});
	return <div data-testid="bridge-file-viewer-headless-controller" />;
}

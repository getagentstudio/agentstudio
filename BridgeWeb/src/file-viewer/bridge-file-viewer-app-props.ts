import type { ReactNode } from 'react';

import type { BridgePaneReloadPort } from '../app/bridge-pane-reload-port.js';
import type { BridgeMermaidRenderer } from '../app/markdown/bridge-mermaid-renderer.js';
import type { BridgeMarkdownRenderWorkerClient } from '../app/markdown/worker/bridge-markdown-render-worker-client.js';
import type { BridgeProductNavigationCommand } from '../core/comm-worker/bridge-product-session-contracts.js';
import type { BridgePaneFailedStartFact } from '../core/models/bridge-pane-failed-start.js';
import type { BridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import type { BridgeTraceContext } from '../foundation/telemetry/bridge-trace-context.js';
import type { BridgeFileViewerDisplaySource } from './bridge-file-viewer-display-model.js';

export interface BridgeFileViewerOpenPathCommand {
	readonly activationStartedAtPerfNow: number;
	readonly commandId: number;
	readonly path: string;
	readonly traceContext: BridgeTraceContext | null;
}

export interface BridgeFileViewerAppProps {
	readonly paneFailedStart?: BridgePaneFailedStartFact | null;
	readonly paneReloadPort?: BridgePaneReloadPort | undefined;
	readonly railVisible?: boolean;
	readonly activationCause?: 'context_switcher' | 'native_request' | 'review_file_corner' | null;
	readonly activationSequence?: number | null;
	readonly activationStartedAtPerfNow?: number | null;
	readonly autoOpenInitialFile?: boolean;
	readonly codeViewWorkerFactory?: () => Worker;
	readonly codeViewWorkerPoolEnabled?: boolean;
	readonly controlTarget?: EventTarget;
	readonly isActive?: boolean;
	readonly markdownWorkerClient?: BridgeMarkdownRenderWorkerClient | null;
	readonly mermaidRenderer?: BridgeMermaidRenderer;
	readonly isNavigationCommandStillEligible?: (
		command: Extract<
			BridgeProductNavigationCommand,
			{ readonly commandKind: 'activateTarget'; readonly surface: 'file' }
		>,
	) => boolean;
	readonly navigationCommand?: Extract<
		BridgeProductNavigationCommand,
		{ readonly commandKind: 'activateTarget'; readonly surface: 'file' }
	>;
	readonly openPathCommand?: BridgeFileViewerOpenPathCommand;
	readonly onDisplaySourceChange?: (source: BridgeFileViewerDisplaySource | null) => void;
	readonly telemetryRecorder?: BridgeTelemetryRecorder | undefined;
	readonly telemetryTraceContext?: BridgeTraceContext | null | undefined;
	readonly viewerContextSwitcher?: ReactNode;
}

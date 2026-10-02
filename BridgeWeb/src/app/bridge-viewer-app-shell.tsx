import type { ReactElement, ReactNode } from 'react';

import type { BridgePaneFailedStartFact } from '../core/models/bridge-pane-failed-start.js';
import { bridgePaneFailedStartDisplaySpec } from './bridge-pane-failed-start-presentation.js';
import type { BridgePaneReloadPort } from './bridge-pane-reload-port.js';
import { BridgePaneFailureMessage } from './bridge-region-presentation.js';
import { BridgeViewerRecoveryRetryButton } from './bridge-viewer-recovery-retry-button.js';

export function BridgeViewerAppShell(props: {
	readonly appOwner: 'BridgeApp';
	readonly children: ReactNode;
	readonly mode: 'file' | 'review';
	readonly paneFailedStart?: BridgePaneFailedStartFact | null;
	readonly retainsContent?: boolean;
	readonly paneReloadPort?: BridgePaneReloadPort;
}): ReactElement {
	return (
		<div
			className="relative h-screen min-h-screen w-full overflow-hidden bg-background text-foreground antialiased"
			data-bridge-app-owner={props.appOwner}
			data-bridge-viewer-mode={props.mode}
			data-bridge-viewer-shell-owner="BridgeViewerAppShell"
			data-testid="bridge-app-root"
		>
			{props.paneFailedStart != null && props.children == null ? (
				<BridgePaneFailureMessage
					entries={[
						{
							part: props.mode,
							state: {
								kind: 'failed',
								retainsContent: false,
								failure: {
									kind: 'retryable',
									scope: 'pane',
									message: bridgePaneFailedStartDisplaySpec.message,
								},
							},
						},
					]}
					paneReloadPort={props.paneReloadPort}
					retryControl={(onClick): ReactElement => (
						<BridgeViewerRecoveryRetryButton surface="pane" onClick={onClick} />
					)}
				/>
			) : null}
			<div className="relative h-full min-h-0">{props.children}</div>
		</div>
	);
}

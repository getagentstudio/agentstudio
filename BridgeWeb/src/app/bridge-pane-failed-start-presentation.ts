import type { BridgePaneFailedStartFact } from '../core/models/bridge-pane-failed-start.js';
import type { BridgeRegionSurfaceStatus } from './bridge-region-presentation-state.js';

export const bridgePaneFailedStartDisplaySpec = { message: "Bridge couldn't start." } as const;

export function bridgePaneFailedStartSurfaceStatus(
	fact: BridgePaneFailedStartFact | null | undefined,
): BridgeRegionSurfaceStatus | null {
	if (fact == null) return null;
	return {
		kind: 'failed',
		failure: {
			kind: 'retryable',
			scope: 'pane',
			message: bridgePaneFailedStartDisplaySpec.message,
		},
	};
}

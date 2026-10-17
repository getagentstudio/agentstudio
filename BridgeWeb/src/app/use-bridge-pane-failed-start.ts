import { useCallback, useLayoutEffect, useRef, useState } from 'react';

import type { BridgePageReadyError } from '../bridge/bridge-page-handshake.js';
import type { BridgePaneRuntime } from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgePaneFailedStartFact } from '../core/models/bridge-pane-failed-start.js';

interface BridgePaneFailedStartPresentation {
	readonly failedStart: BridgePaneFailedStartFact | null;
	readonly getFailedStart: () => BridgePaneFailedStartFact | null;
	readonly reportReadyError: (error: BridgePageReadyError) => void;
}

/** One App publication of the existing startup terminal outcomes; no recovery work lives here. */
export function useBridgePaneFailedStart(
	runtime: BridgePaneRuntime,
	onFailedStart: () => void,
): BridgePaneFailedStartPresentation {
	const [failedStart, setFailedStart] = useState<BridgePaneFailedStartFact | null>(null);
	const failureRef = useRef<BridgePaneFailedStartFact | null>(null);
	const reportFailure = useCallback(
		(fact: BridgePaneFailedStartFact): void => {
			if (failureRef.current !== null) return;
			failureRef.current = fact;
			setFailedStart(fact);
			onFailedStart();
		},
		[onFailedStart],
	);
	useLayoutEffect((): (() => void) => {
		runtime.setPaneFailedStartHandler(reportFailure);
		return (): void => runtime.setPaneFailedStartHandler(null);
	}, [reportFailure, runtime]);
	const reportReadyError = useCallback(
		(error: BridgePageReadyError): void =>
			reportFailure({
				kind: 'failedStart',
				cause:
					error.kind === 'configuration_error'
						? 'configurationUnavailable'
						: 'readyAcknowledgementFailed',
			}),
		[reportFailure],
	);
	const getFailedStart = useCallback(
		(): BridgePaneFailedStartFact | null => failureRef.current,
		[],
	);
	return { failedStart, getFailedStart, reportReadyError };
}

import type { BridgeWorkerHealthEvent } from '../../core/comm-worker/bridge-worker-contracts.js';

/** The existing page export is shared by File and Review, including pre-subscription transport transitions. */
export function publishBridgeProductMetadataStreamDiagnostic(
	message: BridgeWorkerHealthEvent,
): void {
	const diagnostic = message.diagnostic;
	if (diagnostic?.kind !== 'productMetadataStream') return;
	const diagnosticGlobal = globalThis as typeof globalThis & {
		__bridgeProductMetadataStreamDiagnostic?: NonNullable<BridgeWorkerHealthEvent['diagnostic']> & {
			readonly transitionMessage: string | null;
		};
	};
	diagnosticGlobal.__bridgeProductMetadataStreamDiagnostic = Object.freeze({
		...diagnostic,
		transitionMessage: message.message ?? null,
	});
}

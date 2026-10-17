import type { BridgeProductMetadataStreamLifecycleObservation } from './bridge-product-metadata-stream-health-diagnostics.js';
import type { BridgeWorkerHealthEvent } from './bridge-worker-contracts.js';

export function bridgeProductStreamHealthEvent(
	observation: BridgeProductMetadataStreamLifecycleObservation,
): BridgeWorkerHealthEvent {
	return {
		direction: 'serverWorkerToMain',
		kind: 'health',
		status: 'ready',
		transferDescriptors: [],
		wireVersion: 1,
		message: `metadataStream:${observation.transition}; responseStatus=${observation.responseStatus ?? 'none'}`,
		diagnostic: { kind: 'productMetadataStream', ...observation.diagnostics },
	};
}

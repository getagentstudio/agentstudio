import type { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import { buildBridgeWorkerFileMetadataFailureHealthEvent } from './bridge-comm-worker-runtime-health.js';
import { bridgeProductMetadataStreamHealthDiagnostic } from './bridge-comm-worker-runtime-support.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';

/** A failed background ensure reports health without delaying Review installation. */
export function ensureBridgeCommWorkerFileMetadataInBackground(props: {
	readonly controller: BridgeCommWorkerProductController | null;
	readonly productTransport: BridgeProductTransportSession | undefined;
	readonly publish: (message: BridgeWorkerServerToMainMessage) => void;
}): void {
	void props.controller?.ensureFileSource().catch((): void => {
		props.publish(
			buildBridgeWorkerFileMetadataFailureHealthEvent(
				props.productTransport === undefined
					? undefined
					: bridgeProductMetadataStreamHealthDiagnostic(props.productTransport),
			),
		);
	});
}

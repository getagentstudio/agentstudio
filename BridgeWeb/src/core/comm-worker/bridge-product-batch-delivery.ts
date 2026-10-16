import {
	BridgeProductBatchFrameRouter,
	type BridgeProductBatchFrameSinks,
} from './bridge-product-batch-frame-router.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import type { BridgeProductSessionAuthority } from './bridge-product-session-authority.js';
import { BridgeProductViewReceiptAcknowledger } from './bridge-product-view-receipt-acknowledger.js';

/** W4 owns receipt; the ACK path cannot wait for a display installer. */
export function installBridgeProductBatchDelivery(props: {
	readonly authority: BridgeProductSessionAuthority;
	readonly deadlineClock: BridgeProductDeadlineClock;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly router: BridgeProductBatchFrameRouter;
	readonly sinks: BridgeProductBatchFrameSinks;
}): BridgeProductViewReceiptAcknowledger {
	const acknowledger = new BridgeProductViewReceiptAcknowledger({
		authority: props.authority,
		deadlineClock: props.deadlineClock,
		executeProductRequest: props.executeProductRequest,
		onExhausted: (request): void => props.router.requestResnapshotForLostReceipt(request),
	});
	props.router.setSinks({
		...props.sinks,
		receipt: (frame, through): void => {
			acknowledger.received({
				domain: frame.domain,
				handle: frame.handle,
				incarnation: frame.incarnation,
				receivedThroughDeliverySequence: through,
				subscriptionId: frame.subscriptionId,
			});
			props.sinks.receipt(frame, through);
		},
	});
	return acknowledger;
}

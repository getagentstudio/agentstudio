import type { BridgeProductSubscriptionFrameFailureCode } from './bridge-product-subscription-frame-failure.js';

export type BridgeProductMetadataRouteFailureCode =
	| BridgeProductSubscriptionFrameFailureCode
	| 'metadata_stream_error'
	| 'subscription_frame_rejected'
	| 'unknown_subscription';

export class BridgeProductMetadataRouteFailure extends Error {
	readonly routeFailureCode: BridgeProductMetadataRouteFailureCode;

	constructor(routeFailureCode: BridgeProductMetadataRouteFailureCode, message: string) {
		super(message);
		this.name = 'BridgeProductMetadataRouteFailure';
		this.routeFailureCode = routeFailureCode;
	}
}

export function bridgeProductMetadataRouteFailure(
	error: unknown,
): BridgeProductMetadataRouteFailure {
	return error instanceof BridgeProductMetadataRouteFailure
		? error
		: new BridgeProductMetadataRouteFailure(
				'subscription_frame_rejected',
				error instanceof Error ? error.message : 'Bridge product metadata frame routing failed.',
			);
}

import {
	BridgeProductSubscriptionFrameFailure,
	bridgeProductSubscriptionOperationFailureCode,
} from './bridge-product-subscription-frame-failure.js';

export type BridgeProductMetadataSurface = 'file' | 'review';

interface MetadataViewReopenCount {
	consecutiveReopens: number;
	desiredSignature: string | null;
	failure: BridgeProductSubscriptionFrameFailure | null;
	hasOpened: boolean;
}

/** W2 reopen counts outlive E3 allocation; view status remains transport-owned. */
export class BridgeProductViewReopenLifecycle {
	readonly #maximumConsecutiveReopens: number;
	readonly #views: Record<BridgeProductMetadataSurface, MetadataViewReopenCount> = {
		file: initialViewReopenCount(),
		review: initialViewReopenCount(),
	};

	constructor(maximumConsecutiveReopens: number) {
		if (!Number.isSafeInteger(maximumConsecutiveReopens) || maximumConsecutiveReopens <= 0)
			throw new Error('View reopen budget must be a positive safe integer.');
		this.#maximumConsecutiveReopens = maximumConsecutiveReopens;
	}

	admitOpen(surface: BridgeProductMetadataSurface): void {
		const view = this.#views[surface];
		if (view.hasOpened) {
			if (view.consecutiveReopens >= this.#maximumConsecutiveReopens)
				throw (
					view.failure ??
					new BridgeProductSubscriptionFrameFailure(
						'subscription_local_operation_failed',
						'Metadata view reopen budget exhausted.',
					)
				);
			view.consecutiveReopens += 1;
		}
		view.hasOpened = true;
	}

	recordFailure(surface: BridgeProductMetadataSurface, error: unknown): void {
		this.#views[surface].failure =
			error instanceof BridgeProductSubscriptionFrameFailure
				? error
				: new BridgeProductSubscriptionFrameFailure(
						bridgeProductSubscriptionOperationFailureCode(error),
						'Metadata view failed before a certified install.',
					);
	}

	recordCertifiedInstall(surface: BridgeProductMetadataSurface): void {
		this.#views[surface].consecutiveReopens = 0;
		this.#views[surface].failure = null;
	}

	materialDesiredChange(surface: BridgeProductMetadataSurface, signature: string): void {
		const view = this.#views[surface];
		if (view.desiredSignature === signature) return;
		view.desiredSignature = signature;
		this.retry(surface);
	}

	retry(surface: BridgeProductMetadataSurface): void {
		const view = this.#views[surface];
		view.consecutiveReopens = 0;
		view.failure = null;
		view.hasOpened = false;
	}
}

function initialViewReopenCount(): MetadataViewReopenCount {
	return { consecutiveReopens: 0, desiredSignature: null, failure: null, hasOpened: false };
}

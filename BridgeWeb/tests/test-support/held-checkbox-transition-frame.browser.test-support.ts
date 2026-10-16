import { createBridgeProductDeferred } from '../../src/core/comm-worker/bridge-product-async-queue.js';

/** Hold native delivery before it reaches either implementation's callback. */
export function createHeldCheckboxTransitionFrame(): {
	readonly arm: () => void;
	readonly arrived: Promise<void>;
	readonly release: () => void;
	readonly close: () => void;
} {
	const nativeRequest = window.requestAnimationFrame;
	const arrived = createBridgeProductDeferred<void>();
	let isArmed = false;
	let heldDelivery: (() => void) | undefined;
	const interceptedRequest: typeof window.requestAnimationFrame = (callback): number => {
		const previousLimit = Error.stackTraceLimit;
		let registrationStack: string | undefined;
		try {
			Error.stackTraceLimit = 50;
			registrationStack = new Error('Checkbox RAF registration').stack;
		} finally {
			Error.stackTraceLimit = previousLimit;
		}
		const isCheckboxSchedulerRequest =
			isArmed && registrationStack?.includes('useTransitionStatus') === true;
		return nativeRequest.call(window, (timestamp): void => {
			if (isCheckboxSchedulerRequest && heldDelivery === undefined) {
				isArmed = false;
				heldDelivery = (): void => {
					callback(timestamp);
				};
				arrived.resolve();
			} else callback(timestamp);
		});
	};
	window.requestAnimationFrame = interceptedRequest;
	return {
		arm: (): void => {
			isArmed = true;
		},
		arrived: arrived.promise,
		release: (): void => {
			const delivery = heldDelivery;
			if (delivery === undefined)
				throw new Error('Checkbox transition native delivery was never held.');
			heldDelivery = undefined;
			// Never add or remove act here. The stored callback is precisely the one
			// given to the native request API by the implementation under test.
			delivery();
		},
		close: (): void => {
			isArmed = false;
			heldDelivery = undefined;
			if (window.requestAnimationFrame === interceptedRequest)
				window.requestAnimationFrame = nativeRequest;
		},
	};
}

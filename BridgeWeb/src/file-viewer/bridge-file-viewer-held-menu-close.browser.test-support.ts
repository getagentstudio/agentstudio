import { act } from 'react';
import { vi } from 'vitest';

import { createBridgeProductDeferred } from '../core/comm-worker/bridge-product-async-queue.js';
import { prepareFileMenuCompletion } from './bridge-file-viewer-menu-completion.browser.test-support.js';

/** Hold the real close owner's animation completion until the capture-frame join. */
export function holdFileMenuCloseAnimationCompletion(ownerSignal: AbortSignal): {
	readonly releaseAfterCapture: () => Promise<void>;
	readonly close: () => Promise<void>;
	readonly wasCaptured: () => boolean;
} {
	const captured = createBridgeProductDeferred<void>();
	const retired = createBridgeProductDeferred<never>();
	void retired.promise.catch((): void => {});
	const completion = prepareFileMenuCompletion(false);
	const retire = (): void => {
		retired.reject(new Error('Held File menu close animation owner retired.'));
	};
	ownerSignal.addEventListener('abort', retire, { once: true });
	if (ownerSignal.aborted) retire();
	// oxlint-disable-next-line unbound-method -- Rebind the original native method to its Element receiver.
	const originalGetAnimations = Element.prototype.getAnimations;
	let gate: Animation | undefined;
	let captureObserved = false;
	const spy = vi.spyOn(Element.prototype, 'getAnimations').mockImplementation(function (
		this: Element,
		options?: GetAnimationsOptions,
	): Animation[] {
		const animations = originalGetAnimations.call(this, options);
		if (
			options?.subtree === true ||
			!this.hasAttribute('data-closed') ||
			this.getAttribute('data-testid') !== 'worktree-file-filter-menu-popover'
		)
			return animations;
		// Base UI's own exec() sees this paused animation and awaits its real
		// finished promise. Its original done -> flushSync callback stays intact.
		if (gate === undefined) {
			gate = new Animation(new KeyframeEffect(this, [], { duration: 1 }), document.timeline);
			gate.pause();
		}
		captureObserved = true;
		captured.resolve();
		return animations.includes(gate) ? animations : [...animations, gate];
	});
	const missingCapture = completion.promise.then((): never => {
		throw new Error('File menu closed without capturing its animation-finished owner.');
	});
	void missingCapture.catch((): void => {});
	return {
		wasCaptured: (): boolean => captureObserved,
		releaseAfterCapture: async (): Promise<void> => {
			await Promise.race([captured.promise, missingCapture, retired.promise]);
			gate?.finish();
			// No act here: the implementation must supply the scope containing done.
			await Promise.race([completion.promise, retired.promise]);
		},
		close: async (): Promise<void> => {
			try {
				await act(async (): Promise<void> => {
					gate?.finish();
					if (captureObserved) await Promise.race([completion.promise, retired.promise]);
				});
			} finally {
				retire();
				ownerSignal.removeEventListener('abort', retire);
				act((): void => gate?.cancel());
				completion.dispose();
				spy.mockRestore();
			}
		},
	};
}

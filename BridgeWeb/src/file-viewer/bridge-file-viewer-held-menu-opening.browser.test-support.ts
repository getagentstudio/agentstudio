import { act } from 'react';
import { vi } from 'vitest';

import { observeBridgeTransitionDOMFact } from '../../tests/test-support/bridge-transition-dom-fact.browser.test-support.js';
import { createBridgeProductDeferred } from '../core/comm-worker/bridge-product-async-queue.js';
import { prepareFileMenuCompletion } from './bridge-file-viewer-menu-completion.browser.test-support.js';

export const missingFileMenuOpeningCapture =
	'Missing File menu opening-tick capture: correlated native opening completed with settled DOM without interception.';
export const retiredFileMenuOpeningCapture =
	'File menu opening-tick capture owner retired before release.';

/** Own the capture, its alternative opening outcome, and the helper operation together. */
export function createHeldFileMenuOpeningChallenge(props: {
	readonly ownerSignals: readonly AbortSignal[];
	readonly matchesRegistration?: (stack: string | undefined) => boolean;
	readonly beforeRelease?: () => void;
}): {
	readonly run: (openMenu: (afterCapture: () => Promise<void>) => Promise<void>) => Promise<void>;
	readonly snapshot: () => {
		readonly captureDisposition: 'awaiting' | 'captured' | 'released' | 'retired';
		readonly captureContinuationJoined: boolean;
		readonly interactionJoined: boolean;
		readonly observationsDisposed: boolean;
		readonly spiesRestored: boolean;
		readonly openingCompleted: boolean;
		readonly heldFrameCancelled: boolean;
		readonly staleDeliveryIgnored: boolean;
		readonly hasHeldDelivery: boolean;
	};
} {
	const capture = createBridgeProductDeferred<void>();
	void capture.promise.catch((): void => {});
	const disposed = createBridgeProductDeferred<void>();
	const completion = prepareFileMenuCompletion(true);
	const settledDOM = observeBridgeTransitionDOMFact({
		label: 'correlated File menu opening settled DOM',
		isCommitted: (): boolean => {
			const trigger = document.querySelector('[data-testid="worktree-file-filter-menu"]');
			const popup = document.querySelector('[data-testid="worktree-file-filter-menu-popover"]');
			return (
				trigger?.getAttribute('aria-expanded') === 'true' &&
				popup instanceof HTMLElement &&
				popup.hasAttribute('data-open') &&
				!popup.hasAttribute('data-starting-style') &&
				!popup.hasAttribute('data-ending-style')
			);
		},
	});
	let captureDisposition: 'awaiting' | 'captured' | 'released' | 'retired' = 'awaiting';
	let heldDelivery: (() => void) | undefined;
	let heldNativeId: number | undefined;
	let captureContinuationJoined = false;
	let interactionJoined = false;
	let captureOperation: Promise<void> | undefined;
	let observationsDisposed = false;
	let spiesRestored = false;
	let openingCompleted = false;
	let heldFrameCancelled = false;
	let staleDeliveryIgnored = false;
	const retire = (): void => {
		if (captureDisposition === 'released') return;
		captureDisposition = 'retired';
		capture.reject(new Error(retiredFileMenuOpeningCapture));
	};
	for (const signal of props.ownerSignals) signal.addEventListener('abort', retire, { once: true });
	if (props.ownerSignals.some((signal) => signal.aborted)) retire();
	const openingObservation = Promise.race([
		Promise.all([completion.promise, settledDOM.promise]).then((): void => {
			openingCompleted = true;
			if (captureDisposition === 'awaiting')
				capture.reject(new Error(missingFileMenuOpeningCapture));
		}),
		disposed.promise,
	]).catch((error: unknown): void => capture.reject(error));
	const originalRequest = window.requestAnimationFrame;
	const originalCancel = window.cancelAnimationFrame;
	const requestSpy = vi
		.spyOn(window, 'requestAnimationFrame')
		.mockImplementation((callback): number => {
			const stack = new Error('File menu opening-tick registration').stack;
			const matches =
				props.matchesRegistration?.(stack) ?? stack?.includes('useTransitionStatus') === true;
			if (!matches || heldNativeId !== undefined || captureDisposition !== 'awaiting')
				return originalRequest.call(window, callback);
			heldNativeId = originalRequest.call(window, (timestamp): void => {
				if (captureDisposition !== 'awaiting') return;
				captureDisposition = 'captured';
				heldDelivery = (): void => callback(timestamp);
				capture.resolve();
			});
			return heldNativeId;
		});
	const cancelSpy = vi
		.spyOn(window, 'cancelAnimationFrame')
		.mockImplementation((nativeId): void => {
			if (nativeId === heldNativeId) heldFrameCancelled = true;
			originalCancel.call(window, nativeId);
		});
	return {
		snapshot: () => ({
			captureDisposition,
			captureContinuationJoined,
			interactionJoined,
			observationsDisposed,
			spiesRestored,
			openingCompleted,
			heldFrameCancelled,
			staleDeliveryIgnored,
			hasHeldDelivery: heldDelivery !== undefined,
		}),
		run: async (openMenu): Promise<void> => {
			try {
				const captureAndRelease = async (): Promise<void> => {
					await capture.promise;
					props.beforeRelease?.();
					if (props.ownerSignals.some((signal) => signal.aborted))
						throw new Error(retiredFileMenuOpeningCapture);
					const delivery = heldDelivery;
					if (delivery === undefined) throw new Error(missingFileMenuOpeningCapture);
					heldDelivery = undefined;
					captureDisposition = 'released';
					// Supply no act here: only the implementation's captured wrapper owns delivery.
					delivery();
				};
				await openMenu((): Promise<void> => {
					captureOperation = captureAndRelease();
					return captureOperation;
				});
				interactionJoined = true;
			} catch (error: unknown) {
				if (props.ownerSignals.some((signal) => signal.aborted))
					throw new Error(retiredFileMenuOpeningCapture, { cause: error });
				throw error;
			} finally {
				retire();
				if (captureOperation !== undefined) {
					await captureOperation.catch((): void => {});
					captureContinuationJoined = true;
				}
				// Pre-capture retirement leaves actFrame's shared waitForBridgeViewerAnimationFrame unjoined (TQ118).
				completion.dispose();
				settledDOM.close();
				disposed.resolve();
				for (const signal of props.ownerSignals) signal.removeEventListener('abort', retire);
				await openingObservation;
				observationsDisposed = true;
				try {
					if (heldDelivery !== undefined) {
						const popup = document.querySelector(
							'[data-testid="worktree-file-filter-menu-popover"]',
						);
						const before = popup?.outerHTML;
						// Challenge the cancelled wrapper with stale delivery after adapter retirement.
						act(heldDelivery);
						staleDeliveryIgnored = popup?.outerHTML === before;
						heldDelivery = undefined;
					}
				} finally {
					requestSpy.mockRestore();
					cancelSpy.mockRestore();
					spiesRestored =
						window.requestAnimationFrame === originalRequest &&
						window.cancelAnimationFrame === originalCancel;
				}
			}
		},
	};
}

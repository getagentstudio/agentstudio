import { expect, vi } from 'vitest';

import type { ClickAdmissionReviewHarness } from '../review-viewer/code-view/worktree-annotation-click-admission.browser.test-support.js';
import {
	completeCleanup,
	runWithOwnedCleanup,
} from './worktree-annotation-click-admission-cleanup.browser.test-support.js';

export interface HeldInitialReadinessControls {
	readonly isReleased: () => boolean;
	readonly recordObserver: (observer: MutationObserver) => void;
	readonly registerCleanup: (dispose: () => Promise<void>) => () => void;
}

export async function proveDisposedInitialReadiness(props: {
	readonly createHeld: (
		controls: HeldInitialReadinessControls,
	) => Promise<ClickAdmissionReviewHarness>;
	readonly registerCleanup: (dispose: () => Promise<void>) => () => void;
	readonly admitLater: () => Promise<void>;
}): Promise<void> {
	let released = false;
	let oldCallbackResumed = false;
	let ownerDispose: (() => Promise<void>) | undefined;
	let readinessObserver: MutationObserver | undefined;
	let announceReadinessHeld: (() => void) | undefined;
	const readinessHeld = new Promise<void>((resolve): void => {
		announceReadinessHeld = resolve;
	});
	const setup = props.createHeld({
		isReleased: (): boolean => {
			announceReadinessHeld?.();
			return released;
		},
		recordObserver: (observer): void => {
			readinessObserver = observer;
		},
		registerCleanup: (dispose): (() => void) => {
			ownerDispose = dispose;
			return props.registerCleanup(dispose);
		},
	});
	const setupSettlement = setup.then(
		(): { readonly kind: 'ready' } => {
			oldCallbackResumed = true;
			return { kind: 'ready' };
		},
		(error: unknown): { readonly kind: 'rejected'; readonly error: unknown } => ({
			kind: 'rejected',
			error,
		}),
	);
	await readinessHeld;
	if (ownerDispose === undefined || readinessObserver === undefined)
		throw new Error('Expected registered readiness ownership.');
	const disconnectSpy = vi.spyOn(readinessObserver, 'disconnect');
	await runWithOwnedCleanup(
		async (): Promise<void> => {
			await ownerDispose?.();
			expect.soft(disconnectSpy).toHaveBeenCalledOnce();
			// The broken owner has no abort settlement. Let a later real DOM close
			// that red path so the regression never waits for a runner timeout.
			if (disconnectSpy.mock.calls.length === 0) {
				released = true;
				await props.admitLater();
			}
			const settlement = await setupSettlement;
			expect.soft(settlement.kind).toBe('rejected');
			if (settlement.kind === 'rejected')
				expect(settlement.error).toEqual(new Error('Click-admission outcome wait disposed.'));
			if (disconnectSpy.mock.calls.length > 0) {
				released = true;
				await props.admitLater();
			}
			expect.soft(oldCallbackResumed).toBe(false);
		},
		async (): Promise<void> => {
			await completeCleanup([
				async (): Promise<void> => {
					await ownerDispose?.();
				},
				(): void => {
					readinessObserver?.disconnect();
				},
				(): void => {
					disconnectSpy.mockRestore();
				},
			]);
		},
	);
}

import { expect, vi } from 'vitest';

import type { ClickAdmissionReviewHarness } from '../review-viewer/code-view/worktree-annotation-click-admission.browser.test-support.js';
import { runWithOwnedCleanup } from './worktree-annotation-click-admission-cleanup.browser.test-support.js';
import { ClickAdmissionResourceOwner } from './worktree-annotation-click-admission-resource-owner.browser.test-support.js';

export interface HeldInitialReadinessControls {
	readonly isReleased: () => boolean;
	readonly recordObserver: (observer: MutationObserver) => void;
	readonly recordDisposer: (dispose: () => Promise<void>) => void;
}

export async function proveDisposedInitialReadiness(props: {
	readonly createHeld: (
		controls: HeldInitialReadinessControls,
	) => Promise<ClickAdmissionReviewHarness>;
	readonly resources: ClickAdmissionResourceOwner;
	readonly admitLater: () => Promise<void>;
}): Promise<void> {
	const group = props.resources.createGroup('held readiness proof');
	let released = false;
	let oldCallbackResumed = false;
	let ownerDispose: (() => Promise<void>) | undefined;
	let readinessObserver: MutationObserver | undefined;
	const readinessHeld = props.resources.wait<void>({ group, label: 'readiness held fact' });
	props.resources.register({
		group,
		kind: 'root',
		label: 'held readiness harness cleanup',
		restore: async (): Promise<void> => {
			await ownerDispose?.();
		},
	});
	const setup = props.createHeld({
		isReleased: (): boolean => {
			readinessHeld.resolve(undefined);
			return released;
		},
		recordObserver: (observer): void => {
			readinessObserver = observer;
		},
		recordDisposer: (dispose): void => {
			ownerDispose = dispose;
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
	await readinessHeld.promise;
	if (ownerDispose === undefined || readinessObserver === undefined)
		throw new Error('Expected registered readiness ownership.');
	const observedReadiness = readinessObserver;
	const disconnectSpy = props.resources.spy({
		group,
		label: 'readiness disconnect witness',
		create: () => vi.spyOn(observedReadiness, 'disconnect'),
	}).spy;
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
		(): Promise<void> => props.resources.releaseGroup(group),
	);
}

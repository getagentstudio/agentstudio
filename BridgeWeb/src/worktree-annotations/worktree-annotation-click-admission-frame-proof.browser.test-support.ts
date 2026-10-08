import { expect, vi } from 'vitest';

import type { ClickAdmissionReviewHarness } from '../review-viewer/code-view/worktree-annotation-click-admission.browser.test-support.js';
import {
	runWithOwnedCleanup,
	completeCleanup,
} from './worktree-annotation-click-admission-cleanup.browser.test-support.js';
import { requirePierreElement } from './worktree-annotation-click-admission-pointer.browser.test-support.js';
import {
	runCleanupAct,
	observeTestFrameWait,
} from './worktree-annotation-click-admission-render.browser.test-support.js';
import { ClickAdmissionResourceOwner } from './worktree-annotation-click-admission-resource-owner.browser.test-support.js';

export async function proveEscapeFrameIndependence(props: {
	readonly resources: ClickAdmissionResourceOwner;
	readonly harness: ClickAdmissionReviewHarness;
	readonly dismiss: () => Promise<void>;
}): Promise<void> {
	const group = props.resources.createGroup('Escape frame proof');
	const heldFrames: FrameRequestCallback[] = [];
	const frameRequested = props.resources.wait<'frameRequested'>({
		group,
		label: 'test frame requested',
	});
	let holdingTestFrame = false;
	const requestFrame = globalThis.requestAnimationFrame.bind(globalThis);
	let dismissal: Promise<void> | undefined;
	props.resources.register({
		group,
		kind: 'frame',
		label: 'Escape held-frame completion',
		restore: async (): Promise<void> => {
			await completeCleanup([
				(): void => {
					for (const callback of heldFrames.splice(0)) callback(0);
				},
				async (): Promise<void> => {
					await dismissal?.catch((): void => {});
				},
				(): Promise<void> =>
					runCleanupAct((): void => {
						for (const callback of heldFrames.splice(0)) callback(0);
					}),
				props.harness.dispose,
			]);
		},
	});
	await runWithOwnedCleanup(
		async (): Promise<void> => {
			const row = requirePierreElement(
				'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
				'Expected an addition row before testing dismissal.',
			);
			await props.harness.hoverAndClickUtility(row, 601);
			await props.harness.waitForComposer(true);
			expect(
				document.querySelector('[aria-label="Write an annotation in Markdown"]'),
			).not.toBeNull();
			const frameSpy = props.resources.spy({
				group,
				label: 'Escape requestAnimationFrame witness',
				create: () => vi.spyOn(globalThis, 'requestAnimationFrame'),
			});
			frameSpy.spy.mockImplementation((callback: FrameRequestCallback): number => {
				if (!holdingTestFrame) return requestFrame(callback);
				holdingTestFrame = false;
				heldFrames.push(callback);
				return heldFrames.length;
			});
			observeTestFrameWait({
				resources: props.resources,
				group,
				observer: (): void => {
					holdingTestFrame = true;
					frameRequested.resolve('frameRequested');
				},
			});
			dismissal = props.resources.track({ group, label: 'Escape event act', start: props.dismiss });
			const outcome = await Promise.race([
				dismissal.then((): 'dismissed' => 'dismissed'),
				frameRequested.promise,
			]);
			expect(outcome, 'Escape publication must complete without an unrelated frame.').toBe(
				'dismissed',
			);
			await props.harness.waitForComposer(false);
			expect(document.querySelector('[aria-label="Write an annotation in Markdown"]')).toBeNull();
		},
		(): Promise<void> => props.resources.releaseGroup(group),
	);
}

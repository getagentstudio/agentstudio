import { expect } from 'vitest';

import { createClickAdmissionReviewHarness } from '../review-viewer/code-view/worktree-annotation-click-admission.browser.test-support.js';
import { runWithOwnedCleanup } from './worktree-annotation-click-admission-cleanup.browser.test-support.js';
import { requirePierreElement } from './worktree-annotation-click-admission-pointer.browser.test-support.js';

export async function proveRetiredHoverIntent(
	props: Pick<
		Parameters<typeof createClickAdmissionReviewHarness>[0],
		'metadataPublicationOwner' | 'registerCleanup'
	>,
): Promise<void> {
	let retiredRow: HTMLElement | undefined;
	let replacementApplied = false;
	let hoverDispatchCount = 0;
	let announceBlockedOldPre: (() => void) | undefined;
	const blockedOldPre = new Promise<'blockedOldPre'>((resolve): void => {
		announceBlockedOldPre = (): void => resolve('blockedOldPre');
	});
	const harness = await createClickAdmissionReviewHarness({
		metadataPublicationOwner: props.metadataPublicationOwner,
		registerCleanup: props.registerCleanup,
		registerFailureDiagnostic: (): void => {},
		recordWaitForProof: (kind): void => {
			if (kind === 'gutter utility appearance' && retiredRow?.isConnected === false)
				announceBlockedOldPre?.();
		},
		afterHoverBeforeUtility: (codeView, pointerId): void => {
			hoverDispatchCount += 1;
			if (pointerId !== 403 || replacementApplied) return;
			replacementApplied = true;
			const item = codeView.getItem('item-source');
			if (item === undefined) throw new Error('Expected original hover intent item.');
			codeView.setItems([]);
			codeView.setItems([item]);
			codeView.render(true);
			expect(retiredRow?.isConnected).toBe(false);
		},
	});
	let hover: Promise<void> | undefined;
	await runWithOwnedCleanup(
		async (): Promise<void> => {
			retiredRow = requirePierreElement(
				'[data-additions] [data-column-number="3"][data-line-type="context"]',
				'Expected original context intent.',
			);
			hover = harness.hoverAndClickUtility(retiredRow, 403);
			const outcome = hover.then(
				(): 'admitted' => 'admitted',
				(): 'rejected' => 'rejected',
			);
			await harness.interactionSetup.hoverDispatched;
			// Baseline's exact doomed wait is a closing fact, never a correctness timeout.
			const winner = await Promise.race([outcome, blockedOldPre]);
			if (winner === 'blockedOldPre') await harness.dispose();
			expect(await outcome).toBe('admitted');
			expect(
				hoverDispatchCount,
				'One observed pre retirement permits exactly one replacement hover.',
			).toBe(2);
			expect(harness.gutterAdmissions).toEqual([
				{ range: { start: 3, end: 3, side: 'additions' } },
			]);
		},
		async (): Promise<void> => {
			await harness.dispose();
			await hover?.catch((): void => {});
		},
	);
}

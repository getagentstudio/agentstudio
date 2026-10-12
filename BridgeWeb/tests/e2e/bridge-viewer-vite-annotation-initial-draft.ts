import type { Page } from 'playwright';

import { waitForAnnotationMainProjectionReceipt } from './bridge-viewer-vite-annotation-main-projection-observation.ts';
import { waitForCommittedAnnotationOutcome } from './bridge-viewer-vite-annotation-wire-response-observation.ts';

export async function createProjectedAnnotationDraft(props: {
	readonly page: Page;
	readonly savedBody: string;
	readonly sourceRefreshCommitted: Promise<{
		readonly requestSequence: number;
		readonly sessionId: string | null;
	}> | null;
	readonly surface: 'file' | 'review';
}): Promise<void> {
	const rootReceipt = waitForCommittedAnnotationOutcome(props.page, 'root.create', props.surface);
	await props.page
		.getByRole('textbox', { name: 'Write an annotation in Markdown' })
		.fill(props.savedBody);
	const receipt = await rootReceipt;
	if (props.sourceRefreshCommitted !== null) {
		const sourceRefresh = await props.sourceRefreshCommitted;
		if (sourceRefresh.sessionId !== receipt.sessionId) {
			throw new Error('Initial source refresh did not commit the root draft session.');
		}
		// Demand and source.refresh run concurrently. A successful demanded query's
		// descriptor can retire before transfer; the owning store reconciles the root
		// receipt through whichever current projection actually installs its draft.
		await waitForAnnotationMainProjectionReceipt({
			messageState: 'draft',
			page: props.page,
			receipt,
		});
	}
	await props.page
		.locator('[data-testid="worktree-annotation-message"][data-annotation-draft="present"]')
		.waitFor({ state: 'visible' });
	await props.page.waitForFunction((): boolean => {
		const saveButton = document.querySelector<HTMLButtonElement>('[aria-label="Save annotation"]');
		return saveButton !== null && !saveButton.disabled;
	}, undefined);
}

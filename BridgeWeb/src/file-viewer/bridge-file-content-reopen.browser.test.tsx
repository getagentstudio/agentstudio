import { act, type ReactElement } from 'react';
import { expect, test } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise the production region and Pierre styles.
import '../app/bridge-app.css';
import type { BridgeWorkerCodeViewFileItem } from '../core/comm-worker/bridge-worker-pierre-render-job.js';
import { waitForBridgeReviewRecoveryDomState } from '../review-viewer/test-support/bridge-review-recovery-dom-state.test-support.js';
import { terminateBridgePierreWorkerPoolSingletonForTest } from '../review-viewer/workers/pierre/bridge-pierre-worker-pool.js';
import { createWorktreeAnnotationBrowserProviderHarness } from '../worktree-annotations/worktree-annotation-browser-test-support.js';
import {
	BridgeFileViewerCodePanel,
	type BridgeFileViewerCodePanelState,
} from './bridge-file-viewer-code-panel.js';

const lastCompleteItem = {
	id: 'file:retained-file',
	type: 'file',
	version: 1,
	file: {
		name: 'First.swift',
		contents: 'let lastCompleteSource = true;\n',
		lang: 'swift',
		cacheKey: 'retained-complete-source',
	},
	bridgeMetadata: {
		itemId: 'retained-file',
		displayPath: 'First.swift',
		contentRoles: ['file'],
		contentState: 'hydrated',
		cacheKey: 'retained-complete-source',
		lineCount: 1,
	},
} satisfies BridgeWorkerCodeViewFileItem;

test('same-file reconnect read keeps last-complete Pierre content visible, then a different file loads without those bytes', async (): Promise<void> => {
	const annotations = createWorktreeAnnotationBrowserProviderHarness('fileView');
	const readyState = {
		status: 'ready',
		fileId: 'retained-file',
		path: 'First.swift',
		displayItem: null,
	} satisfies BridgeFileViewerCodePanelState;
	const coordinator = { observePostRender: (): void => {}, reconcilePublication: (): void => {} };
	function panel(
		state: BridgeFileViewerCodePanelState,
		selectedItem: BridgeWorkerCodeViewFileItem | null,
	): ReactElement {
		return annotations.wrap(
			<div className="h-[600px] w-[960px]">
				<BridgeFileViewerCodePanel
					codeViewWorkerPoolEnabled={false}
					openFileState={state}
					selectedCodeViewItem={selectedItem}
					renderFulfillmentCoordinator={coordinator}
					totalHeightPixels={null}
				/>
			</div>,
		);
	}
	const rendered = await render(panel(readyState, lastCompleteItem));
	try {
		await waitForBridgeReviewRecoveryDomState({
			readState: (): string =>
				[...document.querySelectorAll('diffs-container')]
					.map((element): string => element.shadowRoot?.textContent ?? '')
					.join(' '),
			isExpected: (text): boolean => text.includes('lastCompleteSource'),
		});
		const originalBody = document.querySelector('[data-testid="bridge-file-viewer-code-view"]');
		if (!(originalBody instanceof HTMLElement)) throw new Error('Expected the painted File body.');
		await act(async (): Promise<void> => {
			await rendered.rerender(panel({ ...readyState, status: 'loading' }, null));
		});
		expect(document.querySelector('[data-bridge-region="file-content"]')).toHaveAttribute(
			'data-presentation-state',
			'updating',
		);
		expect(document.querySelector('[data-testid="bridge-file-viewer-code-view"]')).toBe(
			originalBody,
		);
		expect(getComputedStyle(originalBody).visibility).toBe('visible');
		expect(
			document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]'),
		).toHaveAttribute('data-worktree-rendered-file-path', 'First.swift');
		expect(document.querySelector('diffs-container')).not.toBeNull();
		await act(async (): Promise<void> => {
			await page.screenshot({ path: '../../../tmp/g1-F-same-file-reopen-retained.png' });
		});
		await act(async (): Promise<void> => {
			await rendered.rerender(
				panel(
					{ status: 'loading', fileId: 'other-file', path: 'Other.swift', displayItem: null },
					null,
				),
			);
		});
		expect(document.querySelector('[data-bridge-region="file-content"]')).toHaveAttribute(
			'data-presentation-state',
			'loading',
		);
		expect(
			document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]'),
		).not.toHaveAttribute('data-worktree-rendered-file-path');
		expect(
			document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]'),
		).not.toHaveAttribute('data-worktree-open-file-body-preview');
	} finally {
		await act(async (): Promise<void> => {
			await rendered.unmount();
		});
		annotations.surface.client.renderStore.dispose();
		terminateBridgePierreWorkerPoolSingletonForTest();
	}
});

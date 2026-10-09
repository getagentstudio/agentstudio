import { act } from 'react';
import { expect } from 'vitest';

import { settleFileViewerMenuTransition } from '../file-viewer/bridge-file-viewer-app-startup.browser.test-support.js';
import { waitForBridgeFileViewerBrowserDomState } from '../file-viewer/bridge-file-viewer-browser-test-dom-state.js';
import { actClick } from './bridge-app-browser-test-actions.js';
import {
	dispatchBridgeViewerFilterShortcut,
	requireActiveContextButton,
	requireHTMLElement,
} from './bridge-app-pane-runtime-control-test-support.js';

export async function proveFileMenuDismissalBeforeHide(
	mount: () => Promise<unknown>,
): Promise<void> {
	await mount();
	const shell = await waitForBridgeFileViewerBrowserDomState({
		readState: (): Element | null =>
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		isExpected: (shell): boolean => shell !== null,
	});
	expect(shell).not.toBeNull();
	const appRoot = requireHTMLElement(document.querySelector('[data-testid="bridge-app-root"]'));
	await dispatchBridgeViewerFilterShortcut();
	await settleFileViewerMenuTransition();
	expect(
		document.querySelector('[data-testid="worktree-file-filter-menu-popover"][data-open]'),
	).not.toBeNull();
	await actClick(requireActiveContextButton('review'));
	await waitForBridgeFileViewerBrowserDomState({
		readState: (): string | null => appRoot.getAttribute('data-bridge-viewer-mode'),
		isExpected: (mode): boolean => mode === 'review',
	});
	expect(appRoot.getAttribute('data-bridge-viewer-mode')).toBe('review');
	// Commit the menu capture frame before joining its native close completion.
	await act(async (): Promise<void> => {
		await new Promise<void>((resolve): void => {
			requestAnimationFrame((): void => resolve());
		});
	});
	await settleFileViewerMenuTransition();
	expect(
		document.querySelector('[data-testid="worktree-file-filter-menu-popover"][data-open]'),
	).toBeNull();
}

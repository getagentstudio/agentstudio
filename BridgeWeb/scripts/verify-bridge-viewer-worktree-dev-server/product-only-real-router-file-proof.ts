import { errors, type Page } from 'playwright';

import {
	bridgeViewerProductOnlySelectors,
	type BridgeViewerFileMarkdownStateSnapshot,
} from './product-only-real-router-contract.ts';

/** Selects a known repository path through the real File tree search. */
export async function selectFileProofPath(props: {
	readonly page: Page;
	readonly path: string;
	readonly settleTimeoutMilliseconds: number;
}): Promise<void> {
	const searchInput = props.page.locator('[data-testid="worktree-file-search-input"]');
	if (!(await searchInput.isVisible())) {
		await props.page.locator('[data-testid="worktree-file-search-toggle"]').click();
	}
	await searchInput.fill(props.path);
	const fileRow = props.page
		.locator(
			`[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container button[data-item-path="${props.path}"][data-item-type="file"]`,
		)
		.first();
	await fileRow.waitFor({ state: 'visible', timeout: props.settleTimeoutMilliseconds });
	await fileRow.click();
	await props.page.waitForFunction(
		({ path, selectors }): boolean =>
			document.querySelector(selectors.fileShell)?.getAttribute('data-worktree-open-file-path') ===
			path,
		{ path: props.path, selectors: bridgeViewerProductOnlySelectors },
		{ timeout: props.settleTimeoutMilliseconds },
	);
}

export async function readPaintedFileMarkdown(props: {
	readonly page: Page;
	readonly expectedRenderedText?: string;
	readonly settleTimeoutMilliseconds: number;
}): Promise<BridgeViewerFileMarkdownStateSnapshot> {
	await props.page.waitForFunction(
		({ expectedRenderedText, selectors }): boolean => {
			const shell = document.querySelector(selectors.fileShell);
			const article = document.querySelector(selectors.fileMarkdownCanvas);
			const selectedPath = shell?.getAttribute('data-worktree-open-file-path');
			if (!(article instanceof HTMLElement) || selectedPath === null) return false;
			const style = getComputedStyle(article);
			return (
				shell?.getAttribute('data-worktree-open-file-state') === 'ready' &&
				article.getAttribute('data-bridge-markdown-source-path') === selectedPath &&
				article.closest('[hidden]') === null &&
				style.display !== 'none' &&
				style.visibility !== 'hidden' &&
				article.getClientRects().length > 0 &&
				(article.textContent?.trim().length ?? 0) > 0 &&
				(expectedRenderedText === null || article.textContent?.trim() === expectedRenderedText)
			);
		},
		{
			expectedRenderedText: props.expectedRenderedText ?? null,
			selectors: bridgeViewerProductOnlySelectors,
		},
		{ timeout: props.settleTimeoutMilliseconds },
	);
	return await props.page.evaluate((selectors): BridgeViewerFileMarkdownStateSnapshot => {
		const shell = document.querySelector(selectors.fileShell);
		const article = document.querySelector(selectors.fileMarkdownCanvas);
		const style = article instanceof HTMLElement ? getComputedStyle(article) : null;
		return {
			articleCharacterCount: article?.textContent?.trim().length ?? 0,
			canvasVisible:
				article instanceof HTMLElement &&
				article.closest('[hidden]') === null &&
				style?.display !== 'none' &&
				style?.visibility !== 'hidden' &&
				article.getClientRects().length > 0,
			selectedDisplayPath: shell?.getAttribute('data-worktree-open-file-path') ?? null,
			sourcePath: article?.getAttribute('data-bridge-markdown-source-path') ?? null,
		};
	}, bridgeViewerProductOnlySelectors);
}

export async function waitForFileProductTerminalState(props: {
	readonly page: Page;
	readonly settleTimeoutMilliseconds: number;
}): Promise<boolean> {
	try {
		await props.page.waitForFunction(
			(selectors): boolean => {
				const shell = document.querySelector(selectors.fileShell);
				const codeCanvas = document.querySelector(selectors.fileCodeCanvas);
				const selectedContentState = shell?.getAttribute('data-worktree-open-file-state');
				const selectedPath = shell?.getAttribute('data-worktree-open-file-path');
				const renderedPath = codeCanvas?.getAttribute('data-worktree-rendered-file-path');
				const bodyPreview = codeCanvas?.getAttribute('data-worktree-open-file-body-preview');
				if (!(codeCanvas instanceof HTMLElement)) return false;
				const style = getComputedStyle(codeCanvas);
				return (
					Number(shell?.getAttribute('data-worktree-metadata-tree-row-count') ?? '0') > 0 &&
					selectedContentState === 'ready' &&
					selectedPath !== null &&
					renderedPath === selectedPath &&
					typeof bodyPreview === 'string' &&
					bodyPreview.length > 0 &&
					codeCanvas.closest('[hidden]') === null &&
					style.display !== 'none' &&
					style.visibility !== 'hidden' &&
					codeCanvas.getClientRects().length > 0
				);
			},
			bridgeViewerProductOnlySelectors,
			{ timeout: props.settleTimeoutMilliseconds },
		);
		return true;
	} catch (error: unknown) {
		if (error instanceof errors.TimeoutError) return false;
		throw error;
	}
}

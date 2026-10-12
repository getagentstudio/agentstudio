import { mkdir } from 'node:fs/promises';
import { join, relative } from 'node:path';

import type { Page } from 'playwright';

import { countFlattenedWorktreeFileTreeRows } from '../../src/features/worktree-file/models/worktree-file-tree-size.ts';
import { proofRunDirectoryPath, repoRootPath } from './config.ts';
import { dismissOpenBridgeMenus } from './content-state.ts';
import {
	bridgeFileViewerTreeRowHeightPixels,
	type WorktreeFileProductControlsProof,
	type WorktreeFileSearchChromeProof,
	type WorktreeFileTreeExtentSource,
} from './types.ts';

export async function captureWorktreeDevServerScreenshot(props: {
	readonly name: string;
	readonly page: Page;
}): Promise<string> {
	await mkdir(proofRunDirectoryPath, { recursive: true });
	const screenshotPath = join(proofRunDirectoryPath, props.name);
	await props.page.screenshot({ fullPage: true, path: screenshotPath });
	return relative(repoRootPath, screenshotPath);
}

export function assertWorktreeFileProductControlsProof(props: {
	readonly proof: WorktreeFileProductControlsProof;
}): void {
	const { proof } = props;
	if (proof.initialVisibleCount <= 1 || proof.initialRenderedPathSample.length <= 1) {
		throw new Error(
			`Expected Worktree/File initial tree to have multiple rows: ${JSON.stringify(proof)}`,
		);
	}
	if (proof.initialTreeSizeSource !== 'providerFacts') {
		throw new Error(
			`Expected Worktree/File initial tree extent source to be providerFacts: ${JSON.stringify(proof)}`,
		);
	}
	if (
		!proof.searchResultIncludesTarget ||
		proof.searchVisibleCount !== 1 ||
		proof.searchRenderedPathSample.length !== 1 ||
		proof.searchRenderedPathSample[0] !== proof.targetPath
	) {
		throw new Error(
			`Expected Worktree/File search to isolate target path: ${JSON.stringify(proof)}`,
		);
	}
	if (proof.searchStatusText !== `1/${proof.totalTreeRowCount}`) {
		throw new Error(
			`Expected Worktree/File search status to show result delta: ${JSON.stringify(proof)}`,
		);
	}
	if (proof.searchTreeSizeSource !== 'localProjection') {
		throw new Error(
			`Expected Worktree/File search projection extent source to be localProjection: ${JSON.stringify(proof)}`,
		);
	}
	if (
		proof.searchChromeProof.searchInputHeight !== 24 ||
		!proof.searchChromeProof.searchInputContainedInRail ||
		proof.searchChromeProof.searchInputFontSize !== '11px' ||
		!proof.searchChromeProof.searchInputClassName.includes('h-6') ||
		!proof.searchChromeProof.searchInputClassName.includes('w-[calc(100%-1rem)]') ||
		!proof.searchChromeProof.searchInputClassName.includes('!text-[11px]') ||
		proof.searchChromeProof.searchToggleHeight !== 24 ||
		proof.searchChromeProof.searchToggleFontSize !== '11px' ||
		proof.searchChromeProof.regexToggleHeight !== 24 ||
		proof.searchChromeProof.regexToggleFontSize !== '11px'
	) {
		throw new Error(
			`Expected Worktree/File search chrome to match compact shared controls: ${JSON.stringify(proof)}`,
		);
	}
	assertWorktreeProjectedTreeSize({
		actualSizePixels: proof.searchTreeSizePixels,
		expectedSizePixels: proof.expectedSearchTreeSizePixels,
		label: 'search',
		proof,
	});
	if (
		!proof.regexModeActive ||
		proof.regexVisibleCount !== 1 ||
		proof.regexRenderedPathSample.length !== 1 ||
		proof.regexRenderedPathSample[0] !== proof.targetPath
	) {
		throw new Error(
			`Expected Worktree/File regex search to isolate target path: ${JSON.stringify(proof)}`,
		);
	}
	if (proof.regexTreeSizeSource !== 'localProjection') {
		throw new Error(
			`Expected Worktree/File regex projection extent source to be localProjection: ${JSON.stringify(proof)}`,
		);
	}
	assertWorktreeProjectedTreeSize({
		actualSizePixels: proof.regexTreeSizePixels,
		expectedSizePixels: proof.expectedRegexTreeSizePixels,
		label: 'regex',
		proof,
	});
	if (
		!proof.invalidRegexModeActive ||
		proof.invalidRegexStatusText !== 'Invalid regex' ||
		proof.invalidRegexRenderedPathSample.length !== 0 ||
		proof.invalidRegexTreeSizeSource !== 'localProjection'
	) {
		throw new Error(
			`Expected Worktree/File invalid regex state to be visible and locally projected: ${JSON.stringify(proof)}`,
		);
	}
	assertWorktreeProjectedTreeSize({
		actualSizePixels: proof.invalidRegexTreeSizePixels,
		expectedSizePixels: proof.expectedInvalidRegexTreeSizePixels,
		label: 'invalid regex',
		proof,
	});
	if (
		proof.allFilterVisibleCount !== proof.totalTreeRowCount ||
		proof.allRenderedPathSample.length <= proof.searchRenderedPathSample.length
	) {
		throw new Error(
			`Expected Worktree/File all filter reset to restore visible rows: ${JSON.stringify(proof)}`,
		);
	}
	if (proof.allTreeSizeSource !== 'providerFacts') {
		throw new Error(
			`Expected Worktree/File all reset extent source to be providerFacts: ${JSON.stringify(proof)}`,
		);
	}
}

export function assertWorktreeProjectedTreeSize(props: {
	readonly actualSizePixels: number | null;
	readonly expectedSizePixels: number;
	readonly label: string;
	readonly proof: WorktreeFileProductControlsProof;
}): void {
	if (
		props.actualSizePixels === null ||
		Math.abs(props.actualSizePixels - props.expectedSizePixels) > 1
	) {
		throw new Error(
			`Expected Worktree/File ${props.label} tree extent to match flattened rendered rows: ${JSON.stringify(props.proof)}`,
		);
	}
}

export async function fillWorktreeFileSearch(page: Page, value: string): Promise<void> {
	if ((await page.locator('[data-testid="worktree-file-search-input"]').count()) === 0) {
		await page.locator('[data-testid="worktree-file-search-toggle"]').click();
	}
	await page.locator('[data-testid="worktree-file-search-input"]').fill(value);
}

export async function readWorktreeFileSearchChromeProof(
	page: Page,
): Promise<WorktreeFileSearchChromeProof> {
	return await page.evaluate((): WorktreeFileSearchChromeProof => {
		const searchInput = document.querySelector<HTMLInputElement>(
			'[data-testid="worktree-file-search-input"]',
		);
		const searchToggle = document.querySelector<HTMLElement>(
			'[data-testid="worktree-file-search-toggle"]',
		);
		const regexToggle = document.querySelector<HTMLElement>(
			'[data-testid="worktree-file-regex-toggle"]',
		);
		if (searchInput === null || searchToggle === null || regexToggle === null) {
			throw new Error('Expected Worktree/File search chrome to be mounted');
		}
		const searchInputStyle = getComputedStyle(searchInput);
		const searchToggleStyle = getComputedStyle(searchToggle);
		const regexToggleStyle = getComputedStyle(regexToggle);
		const searchInputRect = searchInput.getBoundingClientRect();
		const searchRailRect =
			document
				.querySelector<HTMLElement>('[data-testid="bridge-file-viewer-rail-toolbar"]')
				?.getBoundingClientRect() ?? searchInputRect;
		return {
			regexToggleFontSize: regexToggleStyle.fontSize,
			regexToggleHeight: Math.round(regexToggle.getBoundingClientRect().height),
			searchInputClassName: searchInput.className,
			searchInputContainedInRail:
				searchInputRect.left >= searchRailRect.left &&
				searchInputRect.right <= searchRailRect.right,
			searchInputFontSize: searchInputStyle.fontSize,
			searchInputHeight: Math.round(searchInputRect.height),
			searchInputLeft: Math.round(searchInputRect.left),
			searchInputRight: Math.round(searchInputRect.right),
			searchRailLeft: Math.round(searchRailRect.left),
			searchRailRight: Math.round(searchRailRect.right),
			searchToggleFontSize: searchToggleStyle.fontSize,
			searchToggleHeight: Math.round(searchToggle.getBoundingClientRect().height),
		};
	});
}

export async function clickWorktreeFileControl(page: Page, testId: string): Promise<void> {
	await page.locator(`[data-testid="${testId}"]`).click();
}

export async function selectWorktreeFileFilter(page: Page, label: string): Promise<void> {
	await page.locator('[data-testid="worktree-file-filter-menu"]').click();
	await page.waitForSelector('[data-testid="worktree-file-filter-menu-option-label"]');
	const optionLocator = page
		.locator('[data-testid="worktree-file-filter-menu-option"]')
		.filter({ hasText: label })
		.first();
	if ((await optionLocator.count()) === 0) {
		const availableLabels = await page
			.locator('[data-testid="worktree-file-filter-menu-option-label"]')
			.allTextContents();
		throw new Error(
			`Expected Worktree/File filter option ${label}; available options: ${availableLabels.join(', ')}`,
		);
	}
	await optionLocator.click({ timeout: 2_000 });
	await dismissOpenBridgeMenus(page);
}

export async function visibleWorktreeFileRowCount(page: Page): Promise<number> {
	return await page.evaluate(
		(): number =>
			window.bridgeWorktreeVerifier
				.getPierreFileTreeItems()
				.filter((candidate) => candidate.dataset['itemType'] === 'file').length,
	);
}

export async function visibleWorktreeFilePathSample(page: Page): Promise<readonly string[]> {
	return await page.evaluate((): readonly string[] =>
		window.bridgeWorktreeVerifier
			.getPierreFileTreeItems()
			.filter((candidate) => candidate.dataset['itemType'] === 'file')
			.map((candidate) => candidate.dataset['itemPath'] ?? '')
			.filter((path) => path.length > 0),
	);
}

export async function waitForWorktreeRenderedFilePathSample(
	page: Page,
	expectedPaths: readonly string[],
): Promise<void> {
	await page.waitForFunction(
		(expected: readonly string[]): boolean => {
			const visiblePaths = window.bridgeWorktreeVerifier
				.getPierreFileTreeItems()
				.filter((candidate) => candidate.dataset['itemType'] === 'file')
				.map((candidate) => candidate.dataset['itemPath'] ?? '')
				.filter((path) => path.length > 0);
			return (
				visiblePaths.length === expected.length &&
				visiblePaths.every((path, index) => path === expected[index])
			);
		},
		expectedPaths,
		{ timeout: 10_000 },
	);
}

export async function worktreeFileRowExists(page: Page, path: string): Promise<boolean> {
	return await page.evaluate(
		(targetPath: string): boolean =>
			window.bridgeWorktreeVerifier.getPierreFileTreeItem(targetPath) !== null,
		path,
	);
}

export async function worktreeFileControlPressed(page: Page, testId: string): Promise<boolean> {
	return await page.evaluate((targetTestId: string): boolean => {
		const control = document.querySelector(`[data-testid="${CSS.escape(targetTestId)}"]`);
		return control?.getAttribute('aria-pressed') === 'true';
	}, testId);
}

export async function worktreeFileFilterStatusText(page: Page): Promise<string> {
	return await page.evaluate(
		(): string =>
			document.querySelector('[data-testid="worktree-file-filter-count"]')?.textContent ?? '',
	);
}

export async function waitForWorktreeFileInvalidRegexStatus(page: Page): Promise<void> {
	await page.waitForFunction(
		(): boolean =>
			document.querySelector('[data-testid="worktree-file-filter-count"]')?.textContent ===
			'Invalid regex',
		{ timeout: 10_000 },
	);
}

export async function worktreeFileTreeTotalSizeSource(
	page: Page,
): Promise<WorktreeFileTreeExtentSource | null> {
	return await page.evaluate((): WorktreeFileTreeExtentSource | null => {
		const rawSource = document
			.querySelector('[data-testid="bridge-file-viewer-pierre-file-tree"]')
			?.getAttribute('data-worktree-tree-total-size-source');
		return rawSource === 'providerFacts' || rawSource === 'localProjection' ? rawSource : null;
	});
}

export async function worktreeFileTreeTotalSizePixels(page: Page): Promise<number | null> {
	return await page.evaluate((): number | null => {
		const rawSize = document
			.querySelector('[data-testid="bridge-file-viewer-pierre-file-tree"]')
			?.getAttribute('data-worktree-tree-total-size');
		if (rawSize === undefined || rawSize === null) {
			return null;
		}
		const parsedSize = Number(rawSize);
		return Number.isFinite(parsedSize) ? parsedSize : null;
	});
}

export function projectedTreeSizePixels(paths: readonly string[]): number {
	return (
		Math.max(1, countFlattenedWorktreeFileTreeRows(paths)) * bridgeFileViewerTreeRowHeightPixels
	);
}

export interface WorktreeFileFilterStatusCount {
	readonly totalCount: number;
	readonly visibleCount: number;
}

export function parseWorktreeFileFilterStatusCount(
	statusText: string,
): WorktreeFileFilterStatusCount {
	const [visibleCountText, totalCountText, extraText] = statusText.split('/');
	if (visibleCountText === undefined || totalCountText === undefined || extraText !== undefined) {
		throw new Error(`Expected Worktree/File status count, got ${statusText}`);
	}
	const visibleCount = Number(visibleCountText);
	const totalCount = Number(totalCountText);
	if (
		!Number.isInteger(visibleCount) ||
		visibleCount < 0 ||
		!Number.isInteger(totalCount) ||
		totalCount < 0
	) {
		throw new Error(`Expected Worktree/File status count, got ${statusText}`);
	}
	return { totalCount, visibleCount };
}

export async function waitForWorktreeFileFilterStatus(
	page: Page,
	visibleCount: number,
	totalCount: number | undefined,
): Promise<void> {
	await page.waitForFunction(
		(expected: { readonly totalCount?: number; readonly visibleCount: number }): boolean => {
			const statusText =
				document.querySelector('[data-testid="worktree-file-filter-count"]')?.textContent ?? '';
			const [visibleCountText, totalCountText, extraText] = statusText.split('/');
			if (
				visibleCountText === undefined ||
				totalCountText === undefined ||
				extraText !== undefined
			) {
				return false;
			}
			const actualVisibleCount = Number(visibleCountText);
			const actualTotalCount = Number(totalCountText);
			if (
				!Number.isInteger(actualVisibleCount) ||
				actualVisibleCount < 0 ||
				!Number.isInteger(actualTotalCount) ||
				actualTotalCount < 0
			) {
				return false;
			}
			return expected.totalCount === undefined
				? actualVisibleCount === expected.visibleCount
				: actualVisibleCount === expected.visibleCount && actualTotalCount === expected.totalCount;
		},
		totalCount === undefined ? { visibleCount } : { totalCount, visibleCount },
		{ timeout: 10_000 },
	);
}

export async function waitForWorktreeFileFilterStatusAtLeast(
	page: Page,
	visibleCount: number,
): Promise<void> {
	await page.waitForFunction(
		(expected: { readonly visibleCount: number }): boolean => {
			const statusText =
				document.querySelector('[data-testid="worktree-file-filter-count"]')?.textContent ?? '';
			const [visibleCountText, totalCountText, extraText] = statusText.split('/');
			if (
				visibleCountText === undefined ||
				totalCountText === undefined ||
				extraText !== undefined
			) {
				return false;
			}
			const actualVisibleCount = Number(visibleCountText);
			const actualTotalCount = Number(totalCountText);
			return (
				Number.isInteger(actualVisibleCount) &&
				actualVisibleCount >= expected.visibleCount &&
				Number.isInteger(actualTotalCount) &&
				actualTotalCount >= actualVisibleCount
			);
		},
		{ visibleCount },
		{ timeout: 10_000 },
	);
}

export async function worktreeFileFilterStatusVisibleCount(page: Page): Promise<number> {
	const statusText = await worktreeFileFilterStatusText(page);
	return parseWorktreeFileFilterStatusCount(statusText).visibleCount;
}

export async function scrollPierreFileTreeUntilPathVisible(
	page: Page,
	path: string,
): Promise<void> {
	const foundWithoutScroll = await worktreeFileRowExists(page, path);
	if (foundWithoutScroll) {
		return;
	}
	for (let attempt = 0; attempt < 80; attempt += 1) {
		await page.evaluate(
			(input: { readonly attempt: number; readonly path: string }): boolean => {
				const helpers = window.bridgeWorktreeVerifier;
				const scrollElement = helpers.getPierreFileTreeScrollElement();
				if (!(scrollElement instanceof HTMLElement)) {
					return false;
				}
				const maxScrollTop = Math.max(0, scrollElement.scrollHeight - scrollElement.clientHeight);
				const nextScrollTop =
					maxScrollTop === 0 ? 0 : Math.floor((maxScrollTop * input.attempt) / 79);
				scrollElement.scrollTop = nextScrollTop;
				return true;
			},
			{ attempt, path },
		);
		await page.waitForTimeout(25);
		const didFind = await worktreeFileRowExists(page, path);
		if (didFind) {
			return;
		}
	}
	throw new Error(`Expected Pierre FileTree row for ${path}`);
}

export async function waitForWorktreeOpenFileState(props: {
	readonly page: Page;
	readonly path: string;
	readonly state: 'loading' | 'ready' | 'refreshing' | 'stale' | 'unavailable';
}): Promise<void> {
	try {
		await props.page.waitForFunction(
			(expected: { readonly path: string; readonly state: string }): boolean => {
				const contentPanel = document.querySelector(
					'[data-testid="bridge-file-viewer-code-canvas"]',
				);
				return (
					contentPanel?.getAttribute('data-worktree-open-file-path') === expected.path &&
					contentPanel?.getAttribute('data-worktree-open-file-state') === expected.state
				);
			},
			{ path: props.path, state: props.state },
			{ timeout: 20_000 },
		);
	} catch (error) {
		const debugState = await props.page.evaluate((targetPath: string) => {
			const contentPanel = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
			const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
			const refreshButtons = Array.from(
				document.querySelectorAll<HTMLButtonElement>('[data-testid="worktree-file-refresh"]'),
			);
			return {
				currentPath: contentPanel?.getAttribute('data-worktree-open-file-path') ?? null,
				currentState: contentPanel?.getAttribute('data-worktree-open-file-state') ?? null,
				refreshButtonCount: refreshButtons.length,
				refreshButtonStates: refreshButtons.map((button) => ({
					disabled: button.disabled,
					visible: button.offsetParent !== null,
				})),
				refreshClickBubble:
					document.documentElement.dataset['bridgeWorktreeVerifierRefreshClickBubbled'] ?? null,
				refreshClickTarget:
					document.documentElement.dataset['bridgeWorktreeVerifierRefreshClicked'] ?? null,
				waitLabel: document.documentElement.dataset['bridgeWorktreeVerifierOpenWaitLabel'] ?? null,
				sourceCursor: shell?.getAttribute('data-worktree-source-cursor') ?? null,
				lastRefreshCommitState: shell?.getAttribute('data-last-refresh-commit-state') ?? null,
				lastRefreshCurrentRequestId:
					shell?.getAttribute('data-last-refresh-current-request-id') ?? null,
				lastRefreshDescriptorId: shell?.getAttribute('data-last-refresh-descriptor-id') ?? null,
				lastRefreshRequestId: shell?.getAttribute('data-last-refresh-request-id') ?? null,
				lastRefreshResult: shell?.getAttribute('data-last-refresh-result') ?? null,
				devReloadFrameCount:
					document.documentElement.dataset['bridgeWorktreeDevLastReloadFrameCount'] ?? null,
				devReloadFrameKinds:
					document.documentElement.dataset['bridgeWorktreeDevLastReloadFrameKinds'] ?? null,
				devReloadRequest:
					document.documentElement.dataset['bridgeWorktreeDevLastReloadRequest'] ?? null,
				devReloadSourceCursor:
					document.documentElement.dataset['bridgeWorktreeDevLastReloadSourceCursor'] ?? null,
				devReloadStatus:
					document.documentElement.dataset['bridgeWorktreeDevLastReloadStatus'] ?? null,
				forceSplitReloadFrameCount:
					document.documentElement.dataset['bridgeWorktreeDevLastForceSplitReloadFrameCount'] ??
					null,
				forceSplitReloadFrameKinds:
					document.documentElement.dataset['bridgeWorktreeDevLastForceSplitReloadFrameKinds'] ??
					null,
				forceSplitReloadSourceCursor:
					document.documentElement.dataset['bridgeWorktreeDevLastForceSplitReloadSourceCursor'] ??
					null,
				forceSplitReloadStatus:
					document.documentElement.dataset['bridgeWorktreeDevLastForceSplitReloadStatus'] ?? null,
				targetPath,
				targetTreeRowExists:
					window.bridgeWorktreeVerifier.getPierreFileTreeItem(targetPath) !== null,
			};
		}, props.path);
		throw new Error(
			`Timed out waiting for Worktree/File ${props.state}: ${JSON.stringify(debugState)}`,
			{ cause: error },
		);
	}
}

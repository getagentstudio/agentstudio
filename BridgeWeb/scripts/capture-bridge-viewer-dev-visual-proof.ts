import { mkdir, writeFile } from 'node:fs/promises';
import { basename, resolve } from 'node:path';

import { chromium, type Page } from 'playwright';
import { z } from 'zod';

const defaultDevServerUrl =
	'http://127.0.0.1:5173/?fixture=large-diffshub&workers=on&scenario=scroll';
const defaultDiffshubReferenceUrl = 'https://diffshub.com/getagentstudio/agentstudio/pull/180';
const preferredTargetPaths = [
	process.env['BRIDGE_VIEWER_VISUAL_TARGET_PATH'],
	'Sources/BridgeViewer/NewPanel.ts',
	'large/browser/huge-diff.ts',
	'docs/plans/bridge-viewer-browser.md',
	'.github/workflows/ci.yml',
	'BridgeWeb/package.json',
	'BridgeWeb/scripts/capture-bridge-viewer-dev-visual-proof.ts',
].filter((path): path is string => path !== undefined && path.length > 0);

const bridgeViewerVisualProofSchema = z.object({
	artifactDirectory: z.string(),
	devServerUrl: z.string(),
	diffshubReference: z.object({
		bodyBackgroundColor: z.string(),
		documentClassName: z.string(),
		hasCodeView: z.boolean(),
		hasFileTree: z.boolean(),
		screenshot: z.string(),
		themeStorage: z.object({
			darkTheme: z.string().nullable(),
			mode: z.string().nullable(),
		}),
		url: z.string(),
	}),
	gitStatusFilterMenu: z.object({
		ariaExpanded: z.string().nullable(),
		checkboxItemCount: z.number().int().nonnegative(),
		hasAllStatusesMenuItem: z.boolean(),
		height: z.number().nonnegative(),
		optionLabels: z.array(z.string()),
		rowHeights: z.array(z.number().nonnegative()),
		width: z.number().nonnegative(),
	}),
	pageTheme: z.object({
		bodyBackgroundColor: z.string(),
		documentClassName: z.string(),
	}),
	referenceComparison: z.object({
		bodyBackgroundColorChannelDelta: z.number().nonnegative(),
		diffshubBodyBackgroundColor: z.string(),
		localBodyBackgroundColor: z.string(),
	}),
	shellChrome: z.object({
		hasTopHeader: z.boolean(),
		hasTopProjectionScope: z.boolean(),
		reviewModeControlHeight: z.number().nonnegative(),
		reviewModeControlWidth: z.number().nonnegative(),
		rightRailToolbarHeight: z.number().nonnegative(),
	}),
	screenshots: z.object({
		gitStatusFilterOpen: z.string(),
		gitStatusFilterPopoverCrop: z.string(),
		largeScrolledView: z.string(),
	}),
	selectedDisplayPath: z.string().nullable(),
	targetDisplayPath: z.string(),
	workerPoolState: z.string().nullable(),
});

type BridgeViewerVisualProof = z.infer<typeof bridgeViewerVisualProofSchema>;

const devServerUrl = process.env['BRIDGE_VIEWER_DEV_SERVER_URL'] ?? defaultDevServerUrl;
const diffshubReferenceUrl =
	process.env['BRIDGE_VIEWER_DIFFSHUB_REFERENCE_URL'] ?? defaultDiffshubReferenceUrl;
const repoRoot =
	basename(process.cwd()) === 'BridgeWeb' ? resolve(process.cwd(), '..') : process.cwd();
const artifactDirectory =
	process.env['BRIDGE_VIEWER_VISUAL_PROOF_DIR'] ??
	resolve(
		repoRoot,
		'tmp',
		'bridge-viewer-visual-proof',
		`${new Date().toISOString().replace(/[:.]/gu, '-')}-dev-server`,
	);

await mkdir(artifactDirectory, { recursive: true });

const browser = await chromium.launch({ headless: true });

try {
	const diffshubReference = await captureDiffshubReference();
	const page = await makeProofPage();
	try {
		await page.goto(devServerUrl, { waitUntil: 'networkidle', timeout: 30_000 });
		await page.waitForTimeout(1_200);
		const targetDisplayPath = await resolveVisualProofTargetPath(page);
		await searchForFile(page, targetDisplayPath);
		await clickFileTreePath(page, targetDisplayPath);
		await page.waitForFunction(
			(path: string): boolean =>
				document
					.querySelector('[data-selected-display-path]')
					?.getAttribute('data-selected-display-path') === path,
			targetDisplayPath,
			{ timeout: 10_000 },
		);
		await page.waitForTimeout(800);
		await clearRailSearch(page);
		await page.waitForTimeout(300);
		const largeScrolledViewPath = resolve(artifactDirectory, 'large-scrolled-view.png');
		await page.screenshot({ fullPage: false, path: largeScrolledViewPath });
		const gitStatusFilterMenu = await openGitStatusFilterMenu(page);
		await waitForFilterPopoverSettled(page);
		const gitStatusFilterOpenPath = resolve(artifactDirectory, 'git-status-filter-open.png');
		await page.screenshot({ fullPage: false, path: gitStatusFilterOpenPath });
		const gitStatusFilterPopoverCropPath = resolve(
			artifactDirectory,
			'git-status-filter-popover-crop.png',
		);
		await page
			.locator('[data-testid="bridge-review-facet-popover"]')
			.screenshot({ path: gitStatusFilterPopoverCropPath });

		const pageTheme = await readPageTheme(page);
		const selectedState = await readSelectedState(page);
		const proof = bridgeViewerVisualProofSchema.parse({
			artifactDirectory,
			devServerUrl,
			diffshubReference,
			gitStatusFilterMenu,
			pageTheme,
			referenceComparison: buildReferenceComparison({
				diffshubBodyBackgroundColor: diffshubReference.bodyBackgroundColor,
				localBodyBackgroundColor: pageTheme.bodyBackgroundColor,
			}),
			shellChrome: await readShellChrome(page),
			screenshots: {
				gitStatusFilterOpen: gitStatusFilterOpenPath,
				gitStatusFilterPopoverCrop: gitStatusFilterPopoverCropPath,
				largeScrolledView: largeScrolledViewPath,
			},
			selectedDisplayPath: selectedState.selectedDisplayPath,
			targetDisplayPath,
			workerPoolState: selectedState.workerPoolState,
		});
		await writeFile(
			resolve(artifactDirectory, 'bridge-viewer-dev-visual-proof.json'),
			`${JSON.stringify(proof, null, 2)}\n`,
			'utf8',
		);
		console.log(JSON.stringify({ ok: true, ...proof }, null, 2));
	} finally {
		await page.close();
	}
} finally {
	await browser.close();
}

async function captureDiffshubReference(): Promise<BridgeViewerVisualProof['diffshubReference']> {
	const page = await makeProofPage();
	try {
		await page.addInitScript((): void => {
			window.localStorage.setItem('theme', 'dark');
			window.localStorage.setItem('diffshub-dark-theme', 'catppuccin-mocha');
		});
		await page.goto(diffshubReferenceUrl, { waitUntil: 'domcontentloaded', timeout: 60_000 });
		await page.waitForFunction(
			(): boolean =>
				document.querySelector('file-tree-container') !== null ||
				document.querySelector('diffs-container') !== null,
			{ timeout: 60_000 },
		);
		await page.waitForFunction((): boolean => document.documentElement.classList.contains('dark'), {
			timeout: 10_000,
		});
		const screenshot = resolve(artifactDirectory, 'diffshub-reference-pr180-catppuccin-mocha.png');
		await page.screenshot({ fullPage: false, path: screenshot });
		return await page.evaluate(
			(props: { readonly screenshot: string; readonly url: string }) => ({
				bodyBackgroundColor: window.getComputedStyle(document.body).backgroundColor,
				documentClassName: document.documentElement.className,
				hasCodeView: document.querySelector('diffs-container') !== null,
				hasFileTree: document.querySelector('file-tree-container') !== null,
				screenshot: props.screenshot,
				themeStorage: {
					darkTheme: window.localStorage.getItem('diffshub-dark-theme'),
					mode: window.localStorage.getItem('theme'),
				},
				url: props.url,
			}),
			{ screenshot, url: diffshubReferenceUrl },
		);
	} finally {
		await page.close();
	}
}

interface BuildReferenceComparisonProps {
	readonly diffshubBodyBackgroundColor: string;
	readonly localBodyBackgroundColor: string;
}

function buildReferenceComparison(
	props: BuildReferenceComparisonProps,
): BridgeViewerVisualProof['referenceComparison'] {
	return {
		bodyBackgroundColorChannelDelta: calculateRgbChannelDelta(
			props.localBodyBackgroundColor,
			props.diffshubBodyBackgroundColor,
		),
		diffshubBodyBackgroundColor: props.diffshubBodyBackgroundColor,
		localBodyBackgroundColor: props.localBodyBackgroundColor,
	};
}

function calculateRgbChannelDelta(leftColor: string, rightColor: string): number {
	const leftRgb = parseRgbColor(leftColor);
	const rightRgb = parseRgbColor(rightColor);
	if (leftRgb === null || rightRgb === null) {
		return 0;
	}
	return (
		Math.abs(leftRgb[0] - rightRgb[0]) +
		Math.abs(leftRgb[1] - rightRgb[1]) +
		Math.abs(leftRgb[2] - rightRgb[2])
	);
}

function parseRgbColor(color: string): readonly [number, number, number] | null {
	const match = /^rgb\((\d+),\s*(\d+),\s*(\d+)\)$/u.exec(color);
	if (match === null) {
		return null;
	}
	return [Number(match[1]), Number(match[2]), Number(match[3])];
}

async function makeProofPage(): Promise<Page> {
	return await browser.newPage({
		colorScheme: 'dark',
		deviceScaleFactor: 1,
		viewport: {
			width: 1728,
			height: 980,
		},
	});
}

async function resolveVisualProofTargetPath(page: Page): Promise<string> {
	await page.waitForFunction(
		(): boolean => {
			const treeRoot = document.querySelector('file-tree-container')?.shadowRoot;
			return (
				treeRoot !== undefined &&
				treeRoot !== null &&
				treeRoot.querySelector('[data-item-path]') instanceof HTMLElement
			);
		},
		{ timeout: 10_000 },
	);
	return await page.evaluate((candidatePaths: readonly string[]): string => {
		const treeRoot = document.querySelector('file-tree-container')?.shadowRoot;
		if (treeRoot === undefined || treeRoot === null) {
			throw new Error('Expected Bridge file tree shadow root');
		}
		for (const candidatePath of candidatePaths) {
			const candidateRow = treeRoot.querySelector(
				`[data-item-path="${CSS.escape(candidatePath)}"]`,
			);
			if (candidateRow instanceof HTMLElement) {
				return candidatePath;
			}
		}
		const firstPath =
			treeRoot
				.querySelector('[data-item-path][data-item-type="file"]')
				?.getAttribute('data-item-path') ??
			treeRoot.querySelector('[data-item-path]')?.getAttribute('data-item-path');
		if (firstPath === null || firstPath === undefined || firstPath.length === 0) {
			throw new Error('Expected at least one Bridge file tree item path');
		}
		return firstPath;
	}, preferredTargetPaths);
}

async function searchForFile(page: Page, targetDisplayPath: string): Promise<void> {
	const searchText = targetDisplayPath.split('/').at(-1) ?? targetDisplayPath;
	await fillBridgeViewerFileTreeSearch(page, searchText);
	await page.waitForFunction(
		(path: string): boolean => {
			const row = document
				.querySelector('file-tree-container')
				?.shadowRoot?.querySelector(`[data-item-path="${CSS.escape(path)}"]`);
			return row instanceof HTMLElement;
		},
		targetDisplayPath,
		{ timeout: 10_000 },
	);
}

async function clearRailSearch(page: Page): Promise<void> {
	await fillBridgeViewerFileTreeSearch(page, '');
	await page.keyboard.press('Escape');
	await page.locator('[data-testid="bridge-review-facet-menu-control"]').focus();
	await page.waitForFunction(
		(): boolean => {
			const input = document
				.querySelector('file-tree-container')
				?.shadowRoot?.querySelector('input[role="searchbox"], input[type="search"], input');
			return !(input instanceof HTMLInputElement) || input.value.length === 0;
		},
		{ timeout: 10_000 },
	);
}

async function fillBridgeViewerFileTreeSearch(page: Page, searchText: string): Promise<void> {
	await page.locator('button[data-testid="bridge-review-search-toggle"]').click();
	await page.waitForFunction((): boolean => {
		const searchInput = document
			.querySelector('file-tree-container')
			?.shadowRoot?.querySelector('input[role="searchbox"], input[type="search"], input');
		return searchInput instanceof HTMLInputElement;
	});
	await page.evaluate((value: string): void => {
		const searchInput = document
			.querySelector('file-tree-container')
			?.shadowRoot?.querySelector<HTMLInputElement>(
				'input[role="searchbox"], input[type="search"], input',
			);
		if (searchInput === null || searchInput === undefined) {
			throw new Error('Expected Bridge viewer file tree search input');
		}
		searchInput.value = value;
		searchInput.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText' }));
		searchInput.focus();
	}, searchText);
}

async function clickFileTreePath(page: Page, path: string): Promise<void> {
	const didClick = await page.evaluate((targetPath: string): boolean => {
		const row = document
			.querySelector('file-tree-container')
			?.shadowRoot?.querySelector(`[data-item-path="${CSS.escape(targetPath)}"]`);
		if (!(row instanceof HTMLElement)) {
			return false;
		}
		row.click();
		return true;
	}, path);
	if (!didClick) {
		throw new Error(`Expected file tree row for ${path}`);
	}
}

async function openGitStatusFilterMenu(
	page: Page,
): Promise<BridgeViewerVisualProof['gitStatusFilterMenu']> {
	await page.locator('[data-testid="bridge-review-facet-menu-control"]').click();
	await page.waitForSelector('[data-testid="bridge-review-facet-popover"]', {
		state: 'visible',
		timeout: 10_000,
	});
	return await page.evaluate((): BridgeViewerVisualProof['gitStatusFilterMenu'] => {
		const trigger = document.querySelector('[data-testid="bridge-review-facet-menu-control"]');
		const popover = document.querySelector('[data-testid="bridge-review-facet-popover"]');
		const bounds = popover instanceof HTMLElement ? popover.getBoundingClientRect() : null;
		const checkboxItems = Array.from(document.querySelectorAll('[role="menuitemcheckbox"]'));
		const optionLabels = checkboxItems.map((item: Element): string => {
			const label = item.querySelector('[data-testid="bridge-review-facet-option-label"]');
			return (label?.textContent ?? item.textContent ?? '').replace(/\s+/g, ' ').trim();
		});
		return {
			ariaExpanded: trigger?.getAttribute('aria-expanded') ?? null,
			checkboxItemCount: checkboxItems.length,
			hasAllStatusesMenuItem: optionLabels.some((label: string): boolean =>
				label.includes('All statuses'),
			),
			height: bounds?.height ?? 0,
			optionLabels,
			rowHeights: checkboxItems.map((item: Element): number =>
				item instanceof HTMLElement ? item.getBoundingClientRect().height : 0,
			),
			width: bounds?.width ?? 0,
		};
	});
}

async function waitForFilterPopoverSettled(page: Page): Promise<void> {
	await page.waitForFunction(
		(): boolean => {
			const popover = document.querySelector('[data-testid="bridge-review-facet-popover"]');
			if (!(popover instanceof HTMLElement)) {
				return false;
			}
			const computedStyle = window.getComputedStyle(popover);
			return computedStyle.opacity === '1' && computedStyle.transform === 'none';
		},
		{ timeout: 10_000 },
	);
}

async function readSelectedState(page: Page): Promise<{
	readonly selectedDisplayPath: string | null;
	readonly workerPoolState: string | null;
}> {
	return await page.evaluate(
		(): {
			readonly selectedDisplayPath: string | null;
			readonly workerPoolState: string | null;
		} => ({
			selectedDisplayPath:
				document
					.querySelector('[data-selected-display-path]')
					?.getAttribute('data-selected-display-path') ?? null,
			workerPoolState:
				document
					.querySelector('[data-bridge-pierre-worker-pool-state]')
					?.getAttribute('data-bridge-pierre-worker-pool-state') ?? null,
		}),
	);
}

async function readPageTheme(page: Page): Promise<BridgeViewerVisualProof['pageTheme']> {
	return await page.evaluate((): BridgeViewerVisualProof['pageTheme'] => ({
		bodyBackgroundColor: window.getComputedStyle(document.body).backgroundColor,
		documentClassName: document.documentElement.className,
	}));
}

async function readShellChrome(page: Page): Promise<BridgeViewerVisualProof['shellChrome']> {
	const shellChrome = await page.evaluate((): BridgeViewerVisualProof['shellChrome'] => {
		const topHeader = document.querySelector('[data-testid="bridge-review-top-header"]');
		const reviewModeControl = document.querySelector(
			'[data-testid="bridge-review-mode-segmented-control"]',
		);
		const rightRailToolbar = document.querySelector('[data-testid="bridge-review-rail-toolbar"]');
		const reviewModeControlBounds =
			reviewModeControl instanceof HTMLElement ? reviewModeControl.getBoundingClientRect() : null;
		const rightRailToolbarBounds =
			rightRailToolbar instanceof HTMLElement ? rightRailToolbar.getBoundingClientRect() : null;
		return {
			hasTopHeader: topHeader !== null,
			hasTopProjectionScope:
				topHeader !== null &&
				topHeader.querySelector('[data-testid="bridge-review-projection-scope"]') !== null,
			reviewModeControlHeight: reviewModeControlBounds?.height ?? 0,
			reviewModeControlWidth: reviewModeControlBounds?.width ?? 0,
			rightRailToolbarHeight: rightRailToolbarBounds?.height ?? 0,
		};
	});
	if (shellChrome.hasTopHeader) {
		throw new Error('Bridge visual proof failed: top review metadata header is still mounted');
	}
	if (shellChrome.hasTopProjectionScope) {
		throw new Error('Bridge visual proof failed: top projection strip is still mounted');
	}
	if (shellChrome.reviewModeControlHeight === 0 || shellChrome.reviewModeControlWidth === 0) {
		throw new Error('Bridge visual proof failed: compact review mode control is missing');
	}
	return shellChrome;
}

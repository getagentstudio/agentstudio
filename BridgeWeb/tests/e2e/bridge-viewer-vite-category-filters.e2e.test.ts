import type { Browser, Locator, Page } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import {
	createBridgeViewerCategoryFixture,
	type BridgeViewerCategoryCase,
} from './bridge-viewer-vite-category-fixture.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import {
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { bridgeViewerViteProductFileUrl } from './bridge-viewer-vite-product-url.ts';
import { observeBrowserRuntimeDiagnostics } from './bridge-viewer-vite-review-comparison-observation.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

type CategoryViewerSurface = 'file' | 'review';

const treeSettlementTimeoutMilliseconds = 30_000;

test('filters File and Review trees with native-classified filesystem metadata', async (context): Promise<void> => {
	return await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
		const fixture = await createBridgeViewerCategoryFixture();
		let browser: Browser | null = null;
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let diagnostics: ReturnType<typeof observeBrowserRuntimeDiagnostics> | null = null;
		let primaryFailure: { readonly error: unknown } | null = null;
		try {
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
			const page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			diagnostics = observeBrowserRuntimeDiagnostics(page);

			await page.goto(
				bridgeViewerViteProductFileUrl(server.origin, 'category-corpus/source/component.ts'),
				{ waitUntil: 'domcontentloaded' },
			);
			await expectTreePaths(page, 'file', fixture.expectedAllTreePaths, 'initial File tree');
			await exerciseCategoryMenu({
				categoryCases: fixture.categoryCases,
				menuOptionTestId: 'worktree-file-filter-menu-option',
				popoverTestId: 'worktree-file-filter-menu-popover',
				surface: 'file',
				triggerTestId: 'worktree-file-filter-menu',
				page,
			});
			await closeMenuIfOpen(page, 'worktree-file-filter-menu-popover');

			const finalFileCategory = requireFinalCategoryCase(fixture.categoryCases);
			await exerciseEmptySearchIntersection({
				categoryTreePaths: finalFileCategory.expectedFileTreePaths,
				clearSearchTestId: 'worktree-file-search-clear',
				inputTestId: 'worktree-file-search-input',
				page,
				surface: 'file',
				triggerTestId: 'worktree-file-search-toggle',
			});
			await clearCategoryFilter({
				clearTestId: 'worktree-file-filter-menu-clear',
				page,
				popoverTestId: 'worktree-file-filter-menu-popover',
				restoredTreePaths: fixture.expectedAllTreePaths,
				surface: 'file',
				triggerTestId: 'worktree-file-filter-menu',
			});

			await page
				.getByTestId('bridge-viewer-mode-host-file')
				.getByRole('button', { name: 'Review', exact: true })
				.click();
			await page.getByTestId('review-viewer-shell').waitFor({ state: 'visible' });
			await expectTreePaths(
				page,
				'review',
				fixture.expectedReviewDefaultTreePaths,
				'initial Review tree',
			);
			await exerciseCategoryMenu({
				categoryCases: fixture.categoryCases,
				menuOptionTestId: 'bridge-review-facet-option',
				popoverTestId: 'bridge-review-facet-popover',
				surface: 'review',
				triggerTestId: 'bridge-review-facet-menu-control',
				page,
			});
			await closeMenuIfOpen(page, 'bridge-review-facet-popover');

			const finalReviewCategory = requireFinalCategoryCase(fixture.categoryCases);
			await exerciseEmptySearchIntersection({
				categoryTreePaths: finalReviewCategory.expectedReviewTreePaths,
				clearSearchTestId: 'bridge-review-search-clear',
				inputTestId: 'bridge-review-search-input',
				page,
				surface: 'review',
				triggerTestId: 'bridge-review-search-toggle',
			});
			await clearCategoryFilter({
				clearTestId: 'bridge-review-facet-clear',
				page,
				popoverTestId: 'bridge-review-facet-popover',
				restoredTreePaths: fixture.expectedReviewDefaultTreePaths,
				surface: 'review',
				triggerTestId: 'bridge-review-facet-menu-control',
			});
		} catch (error: unknown) {
			primaryFailure = {
				error: new Error(
					`Native category E2E failed. Browser: ${await diagnostics?.describe()}. Backend: ${server?.diagnostics() ?? 'not started'}`,
					{ cause: error },
				),
			};
		} finally {
			await runAllOwnedCleanupOperations({
				operations: [
					{
						name: 'browser',
						run: async (): Promise<void> => {
							await browser?.close();
						},
					},
					{
						name: 'Vite and Swift',
						run: async (): Promise<void> => {
							if (server === null) return;
							const cleanup = await server.stop();
							expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
							expect(cleanup.forcedTerminationRequired).toBe(false);
						},
					},
					{ name: 'fixture', run: fixture.dispose },
				],
				...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
			});
		}
	});
});

async function exerciseCategoryMenu(props: {
	readonly categoryCases: readonly BridgeViewerCategoryCase[];
	readonly menuOptionTestId: string;
	readonly page: Page;
	readonly popoverTestId: string;
	readonly surface: CategoryViewerSurface;
	readonly triggerTestId: string;
}): Promise<void> {
	for (const categoryCase of props.categoryCases) {
		// oxlint-disable-next-line no-await-in-loop -- Each visible menu selection must settle through the native query path before the next.
		await selectCategory({ ...props, categoryCase });
		// oxlint-disable-next-line no-await-in-loop -- Exact rows prove the matching files, non-matches, and required ancestors together.
		const expectedTreePaths =
			props.surface === 'file'
				? categoryCase.expectedFileTreePaths
				: categoryCase.expectedReviewTreePaths;
		await expectTreePaths(
			props.page,
			props.surface,
			expectedTreePaths,
			`${props.surface} ${categoryCase.label} category`,
		);
	}
}

async function selectCategory(props: {
	readonly categoryCase: BridgeViewerCategoryCase;
	readonly menuOptionTestId: string;
	readonly page: Page;
	readonly popoverTestId: string;
	readonly triggerTestId: string;
}): Promise<void> {
	const popover = await ensureMenuOpen(props);
	const categoryGroup = popover.getByRole('group', { name: 'File category', exact: true });
	const option = categoryGroup
		.getByTestId(props.menuOptionTestId)
		.filter({ hasText: props.categoryCase.label });
	await expectSingleOption(option, props.categoryCase.label);
	await option.click();
}

async function clearCategoryFilter(props: {
	readonly clearTestId: string;
	readonly page: Page;
	readonly popoverTestId: string;
	readonly restoredTreePaths: readonly string[];
	readonly surface: CategoryViewerSurface;
	readonly triggerTestId: string;
}): Promise<void> {
	const popover = await ensureMenuOpen(props);
	await popover.getByTestId(props.clearTestId).click();
	await expectTreePaths(
		props.page,
		props.surface,
		props.restoredTreePaths,
		`${props.surface} Clear restore`,
	);
}

async function ensureMenuOpen(props: {
	readonly page: Page;
	readonly popoverTestId: string;
	readonly triggerTestId: string;
}): Promise<Locator> {
	const popover = props.page.getByTestId(props.popoverTestId);
	if (!(await popover.isVisible())) {
		await props.page.getByTestId(props.triggerTestId).click();
		await popover.waitFor({ state: 'visible' });
	}
	return popover;
}

async function closeMenuIfOpen(page: Page, popoverTestId: string): Promise<void> {
	const popover = page.getByTestId(popoverTestId);
	if (await popover.isVisible()) {
		await page.keyboard.press('Escape');
		await popover.waitFor({ state: 'hidden' });
	}
}

async function expectSingleOption(option: Locator, label: string): Promise<void> {
	const optionCount = await option.count();
	if (optionCount !== 1) {
		throw new Error(
			`Expected one visible File category option for ${label}, received ${optionCount}.`,
		);
	}
}

async function exerciseEmptySearchIntersection(props: {
	readonly categoryTreePaths: readonly string[];
	readonly clearSearchTestId: string;
	readonly inputTestId: string;
	readonly page: Page;
	readonly surface: CategoryViewerSurface;
	readonly triggerTestId: string;
}): Promise<void> {
	await props.page.getByTestId(props.triggerTestId).click();
	const searchInput = props.page.getByTestId(props.inputTestId);
	await searchInput.waitFor({ state: 'visible' });
	await searchInput.fill('NO_NATIVE_CATEGORY_MATCH');
	await expectTreePaths(props.page, props.surface, [], `${props.surface} deliberate empty result`);
	await props.page.getByTestId(props.clearSearchTestId).click();
	await expectTreePaths(
		props.page,
		props.surface,
		props.categoryTreePaths,
		`${props.surface} category after search Clear`,
	);
}

async function expectTreePaths(
	page: Page,
	surface: CategoryViewerSurface,
	expectedPaths: readonly string[],
	label: string,
): Promise<void> {
	const selector =
		surface === 'file'
			? '[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container'
			: '[data-testid="bridge-review-trees-panel"] file-tree-container';
	try {
		await page.waitForFunction(
			({ expected, treeSelector }): boolean => {
				const treeHost = document.querySelector(treeSelector);
				if (!(treeHost instanceof HTMLElement) || treeHost.shadowRoot === null) return false;
				const observed = [
					...new Set(
						Array.from(treeHost?.shadowRoot?.querySelectorAll('button[data-item-path]') ?? [])
							.filter(
								(candidate): candidate is HTMLElement =>
									candidate instanceof HTMLElement &&
									!candidate.hasAttribute('data-file-tree-sticky-row') &&
									!candidate.hasAttribute('data-item-parked'),
							)
							.map((candidate): string => candidate.dataset['itemPath'] ?? '')
							.filter((path): boolean => path.length > 0),
					),
				].toSorted();
				return JSON.stringify(observed) === JSON.stringify(expected);
			},
			{ expected: [...expectedPaths].toSorted(), treeSelector: selector },
			{ timeout: treeSettlementTimeoutMilliseconds },
		);
	} catch (error: unknown) {
		let observedPaths: readonly string[] | string;
		try {
			observedPaths = await readTreePaths(page, selector);
		} catch (readError: unknown) {
			observedPaths = `unavailable: ${String(readError)}`;
		}
		throw new Error(
			`${label} did not settle. Expected: ${JSON.stringify([...expectedPaths].toSorted())}; observed: ${JSON.stringify(observedPaths)}.`,
			{ cause: error },
		);
	}
	const observedPaths = await readTreePaths(page, selector);
	expect(observedPaths, label).toEqual([...expectedPaths].toSorted());
}

async function readTreePaths(page: Page, selector: string): Promise<readonly string[]> {
	return await page.evaluate((treeSelector): readonly string[] => {
		const treeHost = document.querySelector(treeSelector);
		if (!(treeHost instanceof HTMLElement) || treeHost.shadowRoot === null) {
			throw new Error(`Category tree is unavailable for selector ${treeSelector}.`);
		}
		return [
			...new Set(
				Array.from(treeHost?.shadowRoot?.querySelectorAll('button[data-item-path]') ?? [])
					.filter(
						(candidate): candidate is HTMLElement =>
							candidate instanceof HTMLElement &&
							!candidate.hasAttribute('data-file-tree-sticky-row') &&
							!candidate.hasAttribute('data-item-parked'),
					)
					.map((candidate): string => candidate.dataset['itemPath'] ?? '')
					.filter((path): boolean => path.length > 0),
			),
		].toSorted();
	}, selector);
}

function requireFinalCategoryCase(
	categoryCases: readonly BridgeViewerCategoryCase[],
): BridgeViewerCategoryCase {
	const finalCategoryCase = categoryCases.at(-1);
	if (finalCategoryCase === undefined) {
		throw new Error('Native category fixture requires at least one category case.');
	}
	return finalCategoryCase;
}

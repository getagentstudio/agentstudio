import type { Browser, Locator, Page } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import {
	createBridgeViewerGitStatusFixture,
	type BridgeViewerGitStatusCase,
} from './bridge-viewer-vite-git-status-fixture.ts';
import {
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { bridgeViewerViteProductReviewUrl } from './bridge-viewer-vite-product-url.ts';
import { observeBrowserRuntimeDiagnostics } from './bridge-viewer-vite-review-comparison-observation.ts';

const treeSettlementTimeoutMilliseconds = 30_000;

test('filters the native Git working-tree review by every status and clears combined facets', async (): Promise<void> => {
	const fixture = await createBridgeViewerGitStatusFixture();
	let browser: Browser | null = null;
	let server: BridgeViewerOwnedViteProductServer | null = null;
	let diagnostics: ReturnType<typeof observeBrowserRuntimeDiagnostics> | null = null;
	let primaryFailure: { readonly error: unknown } | null = null;
	try {
		server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
		browser = await launchBridgeViewerE2EChromium();
		const page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
		diagnostics = observeBrowserRuntimeDiagnostics(page);

		await page.goto(bridgeViewerViteProductReviewUrl(server.origin, fixture.addedSourcePath), {
			waitUntil: 'domcontentloaded',
		});
		await page.getByTestId('review-viewer-shell').waitFor({ state: 'visible' });
		await expectReviewTreePaths(page, fixture.expectedAllTreePaths, 'initial All statuses');
		await expectSelectedReviewCodeContent(
			page,
			fixture.selectedSourceContentMarker,
			'initial selected source content',
		);

		for (const statusCase of fixture.statusCases) {
			// oxlint-disable-next-line no-await-in-loop -- Each product filter must settle through Swift, the worker, and Pierre before the next selection.
			await selectFacetOption(page, 'Git status', statusCase.label);
			// oxlint-disable-next-line no-await-in-loop -- Exact rows prove matches, exclusions, ancestors, and the honest empty Copied result.
			await expectReviewTreePaths(
				page,
				statusCase.expectedTreePaths,
				`${statusCase.label} Git status`,
			);
		}

		await selectFacetOption(page, 'Git status', 'All statuses');
		await expectReviewTreePaths(page, fixture.expectedAllTreePaths, 'selected All statuses');
		await expectSelectedReviewCodeContent(
			page,
			fixture.selectedSourceContentMarker,
			'selected source content after empty status and All statuses',
		);

		await setVisibilityToggle(page, 'bridge-review-facet-show-binary', true);
		await expectReviewTreePaths(
			page,
			fixture.expectedWithBinaryTreePaths,
			'Include binary files enabled independently',
		);
		await setVisibilityToggle(page, 'bridge-review-facet-show-binary', false);
		await expectReviewTreePaths(
			page,
			fixture.expectedAllTreePaths,
			'Include binary files disabled independently',
		);
		await setVisibilityToggle(page, 'bridge-review-facet-show-large', true);
		await expectReviewTreePaths(
			page,
			fixture.expectedWithLargeTreePaths,
			'Include large files enabled independently',
		);
		await setVisibilityToggle(page, 'bridge-review-facet-show-binary', true);
		await expectReviewTreePaths(
			page,
			fixture.expectedWithBinaryAndLargeTreePaths,
			'Include binary and large files together',
		);
		await setVisibilityToggle(page, 'bridge-review-facet-show-large', false);
		await expectReviewTreePaths(
			page,
			fixture.expectedWithBinaryTreePaths,
			'Include large files disabled independently',
		);

		let popover = await ensureFacetMenuOpen(page);
		let clear = popover.getByTestId('bridge-review-facet-clear');
		expect(await clear.getAttribute('data-disabled')).toBeNull();
		await clear.click();
		await popover.waitFor({ state: 'hidden' });
		await expectReviewTreePaths(
			page,
			fixture.expectedAllTreePaths,
			'Clear resets visibility toggles',
		);

		await selectFacetOption(page, 'Git status', 'Added');
		await selectFacetOption(page, 'File category', 'Tests');
		await expectReviewTreePaths(
			page,
			fixture.addedTestTreePaths,
			'combined Added and Tests facets',
		);

		await selectFacetOption(page, 'Git status', 'Deleted');
		await expectReviewTreePaths(page, [], 'combined Deleted and Tests empty result');

		popover = await ensureFacetMenuOpen(page);
		clear = popover.getByTestId('bridge-review-facet-clear');
		expect(await clear.getAttribute('data-disabled')).toBeNull();
		await clear.click();
		await popover.waitFor({ state: 'hidden' });
		await expectReviewTreePaths(page, fixture.expectedAllTreePaths, 'Clear filters restore');
		await expectSelectedReviewCodeContent(
			page,
			fixture.selectedSourceContentMarker,
			'selected source content after combined empty result and Clear',
		);
		expect(await page.getByTestId('bridge-review-facet-active-indicator').count()).toBe(0);
	} catch (error: unknown) {
		primaryFailure = {
			error: new Error(
				`Native Git-status filter E2E failed. Browser: ${await diagnostics?.describe()}. Backend: ${server?.diagnostics() ?? 'not started'}`,
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

async function setVisibilityToggle(
	page: Page,
	testId: 'bridge-review-facet-show-binary' | 'bridge-review-facet-show-large',
	expectedChecked: boolean,
): Promise<void> {
	const popover = await ensureFacetMenuOpen(page);
	const toggle = popover.getByTestId(testId);
	await toggle.click();
	expect(await toggle.getAttribute('aria-checked')).toBe(String(expectedChecked));
}

async function selectFacetOption(
	page: Page,
	groupLabel: 'File category' | 'Git status',
	optionLabel: BridgeViewerGitStatusCase['label'] | 'All statuses' | 'Tests',
): Promise<void> {
	const popover = await ensureFacetMenuOpen(page);
	const option = popover
		.getByRole('group', { name: groupLabel, exact: true })
		.getByTestId('bridge-review-facet-option')
		.filter({ hasText: optionLabel });
	const optionCount = await option.count();
	if (optionCount !== 1) {
		throw new Error(
			`Expected one ${groupLabel} option for ${optionLabel}, received ${optionCount}.`,
		);
	}
	await option.click();
	expect(await option.getAttribute('aria-checked')).toBe('true');
}

async function ensureFacetMenuOpen(page: Page): Promise<Locator> {
	const popover = page.getByTestId('bridge-review-facet-popover');
	if (!(await popover.isVisible())) {
		await page.getByTestId('bridge-review-facet-menu-control').click();
		await popover.waitFor({ state: 'visible' });
	}
	return popover;
}

async function expectReviewTreePaths(
	page: Page,
	expectedPaths: readonly string[],
	label: string,
): Promise<void> {
	if (expectedPaths.length === 0) {
		await expectReviewEmptyState(page, label);
		return;
	}
	const treeSelector = '[data-testid="bridge-review-trees-panel"] file-tree-container';
	try {
		await page.waitForFunction(
			({ expected, selector }): boolean => {
				const treeHost = document.querySelector(selector);
				if (!(treeHost instanceof HTMLElement) || treeHost.shadowRoot === null) return false;
				const observed = [
					...new Set(
						Array.from(treeHost.shadowRoot.querySelectorAll('button[data-item-path]'))
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
			{ expected: [...expectedPaths].toSorted(), selector: treeSelector },
			{ timeout: treeSettlementTimeoutMilliseconds },
		);
	} catch (error: unknown) {
		let observedPaths: readonly string[] | string;
		try {
			observedPaths = await readReviewTreePaths(page, treeSelector);
		} catch (readError: unknown) {
			observedPaths = `unavailable: ${String(readError)}`;
		}
		throw new Error(
			`${label} did not settle. Expected: ${JSON.stringify([...expectedPaths].toSorted())}; observed: ${JSON.stringify(observedPaths)}.`,
			{ cause: error },
		);
	}
	const observedPaths = await readReviewTreePaths(page, treeSelector);
	expect(observedPaths, label).toEqual([...expectedPaths].toSorted());
}

async function expectReviewEmptyState(page: Page, label: string): Promise<void> {
	await page.waitForFunction(
		(): boolean => {
			const shell = document.querySelector('[data-testid="review-viewer-shell"]');
			const emptyCanvas = document.querySelector('[data-testid="bridge-review-empty-canvas"]');
			const emptyFileTree = document.querySelector('[data-testid="bridge-review-empty-file-tree"]');
			const filterTrigger = document.querySelector(
				'[data-testid="bridge-review-facet-menu-control"]',
			);
			return (
				shell instanceof HTMLElement &&
				shell.dataset['reviewMetadataItemCount'] === '0' &&
				shell.dataset['reviewMetadataTreeRowCount'] === '0' &&
				emptyCanvas instanceof HTMLElement &&
				emptyFileTree instanceof HTMLElement &&
				filterTrigger instanceof HTMLButtonElement &&
				!filterTrigger.disabled
			);
		},
		undefined,
		{ timeout: treeSettlementTimeoutMilliseconds },
	);
	const shell = page.getByTestId('review-viewer-shell');
	expect(await shell.getAttribute('data-review-metadata-item-count'), label).toBe('0');
	expect(await shell.getAttribute('data-review-metadata-tree-row-count'), label).toBe('0');
	expect(await page.getByTestId('bridge-review-empty-canvas').isVisible(), label).toBe(true);
	expect(await page.getByTestId('bridge-review-empty-file-tree').isVisible(), label).toBe(true);
	expect(await page.getByTestId('bridge-review-facet-menu-control').isEnabled(), label).toBe(true);
}

async function expectSelectedReviewCodeContent(
	page: Page,
	marker: string,
	label: string,
): Promise<void> {
	await page.waitForFunction(
		(markerText: string): boolean => {
			const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
			if (!(panel instanceof HTMLElement)) return false;
			const pending: Array<Element | ShadowRoot> = [panel];
			while (pending.length > 0) {
				const current = pending.shift();
				if (current === undefined) break;
				for (const row of current.querySelectorAll('[data-line]')) {
					const bounds = row.getBoundingClientRect();
					if (
						row.closest('[data-additions]') !== null &&
						bounds.width > 0 &&
						bounds.height > 0 &&
						(row.textContent?.includes(markerText) ?? false)
					) {
						return true;
					}
				}
				for (const descendant of current.querySelectorAll('*')) {
					if (descendant.shadowRoot !== null) pending.push(descendant.shadowRoot);
				}
			}
			return false;
		},
		marker,
		{ timeout: treeSettlementTimeoutMilliseconds },
	);
	expect(
		await page.evaluate((markerText: string): boolean => {
			const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
			if (panel === null) return false;
			const pending: Array<Element | ShadowRoot> = [panel];
			while (pending.length > 0) {
				const current = pending.shift();
				if (current === undefined) break;
				for (const row of current.querySelectorAll('[data-line]')) {
					if (
						row.closest('[data-additions]') !== null &&
						(row.textContent?.includes(markerText) ?? false)
					) {
						return true;
					}
				}
				for (const descendant of current.querySelectorAll('*')) {
					if (descendant.shadowRoot !== null) pending.push(descendant.shadowRoot);
				}
			}
			return false;
		}, marker),
		label,
	).toBe(true);
}

async function readReviewTreePaths(page: Page, selector: string): Promise<readonly string[]> {
	return await page.evaluate((treeSelector): readonly string[] => {
		const treeHost = document.querySelector(treeSelector);
		if (!(treeHost instanceof HTMLElement) || treeHost.shadowRoot === null) {
			throw new Error(`Review tree is unavailable for selector ${treeSelector}.`);
		}
		return [
			...new Set(
				Array.from(treeHost.shadowRoot.querySelectorAll('button[data-item-path]'))
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

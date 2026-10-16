import type { Browser, Page } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import { selectReviewFile } from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { createBridgeViewerViteProductFixture } from './bridge-viewer-vite-product-fixture.ts';
import { waitForStreamRecoveryFilePaint } from './bridge-viewer-vite-stream-recovery-readiness.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

export function registerReviewActivationWaitProof(): void {
	test('names held Review activation and ends selection from inactive-owner refusal', async (context) => {
		await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			const fixture = await createBridgeViewerViteProductFixture();
			const browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
			const page = await browser.newPage();
			let selection: ReturnType<typeof handleLaunchPromise<void>> | null = null;
			try {
				await page.setContent('<main>Review metadata delivery held</main>');
				selection = handleLaunchPromise(
					selectReviewFile({ page, path: 'held-review.ts', testLaunch: fixture.oracle.testLaunch }),
					'held Review activation',
				);
				expect(await page.getByTestId('review-viewer-shell').count()).toBe(0);
				expect(fixture.oracle.testLaunch.pendingSteps).toContain(
					'Review file selection: shell mount and tree row for held-review.ts',
				);
				await page.setContent(
					'<main data-testid="bridge-dev-session-inactive">Open elsewhere</main>',
				);
				await expect(selection.value()).rejects.toThrow(
					'Review shell mount refused by bridge-dev-session-inactive',
				);
				console.log('TQ85_OWNER_PROOF pending=Review-file-selection terminal=open-elsewhere');
			} finally {
				await page.close();
				await selection?.settled;
				await browser.close();
				await fixture.dispose();
			}
		});
	});

	test('names the requested Review tree row after mounted-shell search ingress until row publication completes selection', async (context) => {
		await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			const fixture = await createBridgeViewerViteProductFixture();
			let browser: Browser | null = null;
			let page: Page | null = null;
			let selection: ReturnType<typeof handleLaunchPromise<void>> | null = null;
			let searchIngress: ReturnType<typeof handleLaunchPromise<void>> | null = null;
			let primaryFailure: { readonly error: unknown } | null = null;
			const targetPath = 'Sources/held-review-row.ts';
			const selectionStep = `Review file selection: shell mount and tree row for ${targetPath}`;
			try {
				browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
				page = await browser.newPage();
				await page.setContent(
					'<main data-testid="review-viewer-shell"><section data-testid="bridge-review-trees-panel"><file-tree-container></file-tree-container></section></main>',
				);
				await page.evaluate((): void => {
					const tree = document.querySelector('file-tree-container');
					if (tree === null) throw new Error('Held-row proof requires the mounted tree.');
					const shadowRoot = tree.attachShadow({ mode: 'open' });
					const search = document.createElement('input');
					search.setAttribute('data-file-tree-search-input', 'true');
					search.value = 'prior-filter';
					search.addEventListener('input', (): void => {
						document.documentElement.dataset['heldReviewSearchIngress'] = search.value;
					});
					shadowRoot.append(search);
				});
				searchIngress = fixture.oracle.testLaunch.observeStep(
					`Review tree search input ingress for ${targetPath}`,
					page.evaluate(
						(path: string): Promise<void> =>
							new Promise((resolve): void => {
								const inspect = (): void => {
									if (document.documentElement.dataset['heldReviewSearchIngress'] !== path) return;
									observer.disconnect();
									resolve();
								};
								const observer = new MutationObserver(inspect);
								observer.observe(document.documentElement, {
									attributes: true,
									attributeFilter: ['data-held-review-search-ingress'],
								});
								inspect();
							}),
						targetPath,
					),
				);
				selection = handleLaunchPromise(
					selectReviewFile({ page, path: targetPath, testLaunch: fixture.oracle.testLaunch }),
					'Review held-row selection',
				);
				await searchIngress.value();
				expect(await page.getByTestId('review-viewer-shell').count()).toBe(1);
				expect(await page.locator('input[data-file-tree-search-input]').inputValue()).toBe(
					targetPath,
				);
				expect(await page.locator('button[data-item-path]').count()).toBe(0);
				expect(fixture.oracle.testLaunch.pendingSteps).toContain(selectionStep);
				console.log(
					`TQ85_HELD_ROW shell=mounted search=${targetPath} row=absent pending=${selectionStep}`,
				);
				await page.evaluate((path: string): void => {
					const shadowRoot = document.querySelector('file-tree-container')?.shadowRoot;
					if (shadowRoot === undefined || shadowRoot === null)
						throw new Error('Held-row proof lost its tree owner.');
					const row = document.createElement('button');
					row.dataset['itemPath'] = path;
					row.dataset['itemType'] = 'file';
					row.textContent = path;
					row.addEventListener('click', (): void => {
						document
							.querySelector('[data-testid="review-viewer-shell"]')
							?.setAttribute('data-selected-display-path', path);
						document.documentElement.dataset['heldReviewRowClicks'] = String(
							Number(document.documentElement.dataset['heldReviewRowClicks'] ?? '0') + 1,
						);
					});
					shadowRoot.append(row);
				}, targetPath);
				await selection.value();
				expect(
					await page.getByTestId('review-viewer-shell').getAttribute('data-selected-display-path'),
				).toBe(targetPath);
				expect(await page.locator('input[data-file-tree-search-input]').inputValue()).toBe(
					'prior-filter',
				);
				expect(
					await page.evaluate(
						(): string | undefined => document.documentElement.dataset['heldReviewRowClicks'],
					),
				).toBe('1');
				expect(fixture.oracle.testLaunch.pendingSteps).not.toContain(selectionStep);
				console.log(
					'TQ85_HELD_ROW row=published selection=joined clicks=1 search=restored pending=removed',
				);
			} catch (error: unknown) {
				primaryFailure = { error };
				throw error;
			} finally {
				await runAllOwnedCleanupOperations({
					operations: [
						{
							name: 'held-row page',
							run: async (): Promise<void> => {
								await page?.close();
							},
						},
						{
							name: 'held-row observer joins',
							run: async (): Promise<void> => {
								await Promise.all([selection?.settled, searchIngress?.settled]);
							},
						},
						{
							name: 'held-row browser',
							run: async (): Promise<void> => {
								await browser?.close();
							},
						},
						{ name: 'held-row fixture', run: fixture.dispose },
					],
					...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
				});
			}
		});
	});
}

export function registerStreamRecoveryWaitProof(): void {
	test('names held File recovery paint and settles only from the ready matching source', async (context) => {
		await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			const fixture = await createBridgeViewerViteProductFixture();
			const browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
			const page = await browser.newPage();
			let paint: ReturnType<typeof handleLaunchPromise<void>> | null = null;
			try {
				await page.setContent(
					'<main data-testid="bridge-file-viewer-code-canvas" data-worktree-open-file-state="ready"><diffs-container data-bridge-painted-source-correlations=\'[{"observedSha256":"old-source"}]\'></diffs-container></main>',
				);
				paint = handleLaunchPromise(
					waitForStreamRecoveryFilePaint({
						page,
						expectedSha256: 'new-source',
						streamState: 'disconnected',
						testLaunch: fixture.oracle.testLaunch,
					}),
					'held File recovery paint',
				);
				expect(
					await page
						.locator('diffs-container')
						.getAttribute('data-bridge-painted-source-correlations'),
				).toContain('old-source');
				const step =
					'File metadata disconnected: selected File ready and painted source new-source';
				expect(fixture.oracle.testLaunch.pendingSteps).toContain(step);
				await page.evaluate((): void => {
					document.querySelector('main')?.setAttribute('data-worktree-open-file-state', 'loading');
					document
						.querySelector('diffs-container')
						?.setAttribute(
							'data-bridge-painted-source-correlations',
							JSON.stringify([{ observedSha256: 'new-source' }]),
						);
				});
				expect(await page.locator('main').getAttribute('data-worktree-open-file-state')).toBe(
					'loading',
				);
				expect(fixture.oracle.testLaunch.pendingSteps).toContain(step);
				await page.evaluate((): void => {
					document.querySelector('main')?.setAttribute('data-worktree-open-file-state', 'ready');
				});
				await paint.value();
				expect(fixture.oracle.testLaunch.pendingSteps).not.toContain(step);
				console.log('TQ90_OWNER_PROOF pending=selected-File-paint release=ready-matching-SHA');
			} finally {
				await page.close();
				await paint?.settled;
				await browser.close();
				await fixture.dispose();
			}
		});
	});
}

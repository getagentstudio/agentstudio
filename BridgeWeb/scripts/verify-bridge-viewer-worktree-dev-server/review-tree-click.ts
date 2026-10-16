import type { Page } from 'playwright';

import { reviewFirstVisibleContentStates } from './performance-correlation.ts';
import {
	worktreeFileTreeReachableScanCount,
	type InPageReviewTreeClickPerformanceSample,
	type ReviewTreeSearchClickProof,
} from './types.ts';

export async function reviewTreeReachablePathScrollTopMap(
	page: Page,
): Promise<ReadonlyMap<string, number>> {
	const entries = await page.evaluate(
		async (sampleCount: number): Promise<readonly (readonly [string, number])[]> => {
			const treeHost = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			const scrollElement = treeHost?.shadowRoot?.querySelector(
				'[data-file-tree-virtualized-scroll="true"]',
			);
			if (!(scrollElement instanceof HTMLElement)) {
				throw new Error('Expected Worktree/Review tree scroll element for reachable-path scan');
			}
			const scrollTopByPath = new Map<string, number>();
			const animationFrame = (): Promise<void> =>
				new Promise((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
			const maxScrollTop = Math.max(0, scrollElement.scrollHeight - scrollElement.clientHeight);
			for (let sampleIndex = 0; sampleIndex < sampleCount; sampleIndex += 1) {
				const targetScrollTop =
					sampleCount <= 1 ? 0 : Math.round((maxScrollTop * sampleIndex) / (sampleCount - 1));
				scrollElement.scrollTop = targetScrollTop;
				await animationFrame();
				await animationFrame();
				for (const candidate of treeHost?.shadowRoot?.querySelectorAll('button[data-item-path]') ??
					[]) {
					if (
						candidate instanceof HTMLElement &&
						candidate.dataset['itemType'] === 'file' &&
						!candidate.hasAttribute('data-file-tree-sticky-row') &&
						!candidate.hasAttribute('data-item-parked')
					) {
						const path = candidate.dataset['itemPath'] ?? '';
						if (path.length > 0) {
							scrollTopByPath.set(path, scrollElement.scrollTop);
						}
					}
				}
			}
			return [...scrollTopByPath.entries()].sort(([leftPath], [rightPath]): number =>
				leftPath.localeCompare(rightPath),
			);
		},
		worktreeFileTreeReachableScanCount,
	);
	return new Map(entries);
}

export async function revealReviewTreeFilePath(props: {
	readonly page: Page;
	readonly path: string;
	readonly scrollTopHint: number;
}): Promise<void> {
	await props.page.waitForFunction(
		async (expected: {
			readonly scrollTopHint: number;
			readonly targetPath: string;
		}): Promise<boolean> => {
			const treeHost = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			const scrollElement = treeHost?.shadowRoot?.querySelector(
				'[data-file-tree-virtualized-scroll="true"]',
			);
			if (!(scrollElement instanceof HTMLElement)) {
				return false;
			}
			const searchInput = treeHost?.shadowRoot?.querySelector('input[data-file-tree-search-input]');
			if (searchInput instanceof HTMLInputElement && searchInput.value.length > 0) {
				searchInput.value = '';
				searchInput.dispatchEvent(new InputEvent('input', { bubbles: true }));
			}
			const animationFrame = (): Promise<void> =>
				new Promise((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
			const rowHeight = 24;
			const maxScrollTop = Math.max(0, scrollElement.scrollHeight - scrollElement.clientHeight);
			const candidateScrollTops = [
				expected.scrollTopHint,
				expected.scrollTopHint - rowHeight * 8,
				expected.scrollTopHint + rowHeight * 8,
				expected.scrollTopHint - rowHeight * 16,
				expected.scrollTopHint + rowHeight * 16,
			].map((scrollTop): number => Math.max(0, Math.min(maxScrollTop, Math.round(scrollTop))));
			for (const targetScrollTop of candidateScrollTops) {
				scrollElement.scrollTop = targetScrollTop;
				await animationFrame();
				await animationFrame();
				const button = Array.from(
					treeHost?.shadowRoot?.querySelectorAll('button[data-item-path]') ?? [],
				).find(
					(candidate): candidate is HTMLElement =>
						candidate instanceof HTMLElement &&
						candidate.dataset['itemPath'] === expected.targetPath &&
						candidate.dataset['itemType'] === 'file' &&
						!candidate.hasAttribute('data-file-tree-sticky-row') &&
						!candidate.hasAttribute('data-item-parked'),
				);
				if (button instanceof HTMLElement) {
					const buttonRect = button.getBoundingClientRect();
					const scrollRect = scrollElement.getBoundingClientRect();
					const visible =
						buttonRect.bottom > scrollRect.top &&
						buttonRect.top < scrollRect.bottom &&
						buttonRect.width > 0 &&
						buttonRect.height > 0;
					if (visible) {
						scrollElement.scrollTop = Math.max(
							0,
							Math.min(
								maxScrollTop,
								Math.round(
									scrollElement.scrollTop +
										(buttonRect.top - scrollRect.top) -
										scrollRect.height / 2 +
										buttonRect.height / 2,
								),
							),
						);
						await animationFrame();
						await animationFrame();
						return true;
					}
					const centeredScrollTop =
						scrollElement.scrollTop +
						(buttonRect.top - scrollRect.top) -
						scrollRect.height / 2 +
						buttonRect.height / 2;
					scrollElement.scrollTop = Math.max(
						0,
						Math.min(maxScrollTop, Math.round(centeredScrollTop)),
					);
					await animationFrame();
					await animationFrame();
					const adjustedButton = Array.from(
						treeHost?.shadowRoot?.querySelectorAll('button[data-item-path]') ?? [],
					).find(
						(candidate): candidate is HTMLElement =>
							candidate instanceof HTMLElement &&
							candidate.dataset['itemPath'] === expected.targetPath &&
							candidate.dataset['itemType'] === 'file' &&
							!candidate.hasAttribute('data-file-tree-sticky-row') &&
							!candidate.hasAttribute('data-item-parked'),
					);
					if (adjustedButton instanceof HTMLElement) {
						const adjustedButtonRect = adjustedButton.getBoundingClientRect();
						const adjustedScrollRect = scrollElement.getBoundingClientRect();
						if (
							adjustedButtonRect.bottom > adjustedScrollRect.top &&
							adjustedButtonRect.top < adjustedScrollRect.bottom &&
							adjustedButtonRect.width > 0 &&
							adjustedButtonRect.height > 0
						) {
							return true;
						}
					}
				}
			}
			return false;
		},
		{ scrollTopHint: props.scrollTopHint, targetPath: props.path },
		{ timeout: 10_000 },
	);
}

export async function waitForVisibleReviewTreeFilePath(props: {
	readonly page: Page;
	readonly path: string;
}): Promise<void> {
	await props.page.waitForFunction(
		(targetPath: string): boolean => {
			const treeHost = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			const button = Array.from(
				treeHost?.shadowRoot?.querySelectorAll('button[data-item-path]') ?? [],
			).find(
				(candidate): candidate is HTMLElement =>
					candidate instanceof HTMLElement &&
					candidate.dataset['itemPath'] === targetPath &&
					candidate.dataset['itemType'] === 'file' &&
					!candidate.hasAttribute('data-file-tree-sticky-row') &&
					!candidate.hasAttribute('data-item-parked'),
			);
			if (!(button instanceof HTMLElement)) {
				return false;
			}
			const rect = button.getBoundingClientRect();
			return rect.width > 0 && rect.height > 0;
		},
		props.path,
		{ timeout: 2_000 },
	);
}

export async function selectReviewTreeFilePath(props: {
	readonly page: Page;
	readonly path: string;
}): Promise<void> {
	const previousSearchValue = await props.page.evaluate(
		async (path: string): Promise<string | null> => {
			const treeHost = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			const shadowRoot = treeHost?.shadowRoot;
			if (shadowRoot === null || shadowRoot === undefined) {
				throw new Error('Expected Review tree shadow root before selecting a file.');
			}
			const targetFileButton = (): HTMLElement | undefined =>
				Array.from(shadowRoot.querySelectorAll('button[data-item-path]')).find(
					(candidate): candidate is HTMLElement =>
						candidate instanceof HTMLElement &&
						candidate.dataset['itemPath'] === path &&
						candidate.dataset['itemType'] === 'file' &&
						!candidate.hasAttribute('data-file-tree-sticky-row') &&
						!candidate.hasAttribute('data-item-parked'),
				);
			if (targetFileButton() !== undefined) return null;

			const searchInput = shadowRoot.querySelector('input[data-file-tree-search-input]');
			if (!(searchInput instanceof HTMLInputElement)) {
				throw new Error(
					`Review file row is not rendered and the tree search input is unavailable: ${path}`,
				);
			}
			const previousValue = searchInput.value;
			await new Promise<void>((resolve): void => {
				const observer = new MutationObserver((): void => {
					if (targetFileButton() === undefined) return;
					observer.disconnect();
					resolve();
				});
				observer.observe(shadowRoot, { attributes: true, childList: true, subtree: true });
				searchInput.value = path;
				searchInput.dispatchEvent(new InputEvent('input', { bubbles: true }));
				if (targetFileButton() !== undefined) {
					observer.disconnect();
					resolve();
				}
			});
			return previousValue;
		},
		props.path,
	);

	try {
		await props.page.evaluate((path: string): void => {
			const treeHost = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			const row = Array.from(
				treeHost?.shadowRoot?.querySelectorAll('button[data-item-path]') ?? [],
			).find(
				(candidate): candidate is HTMLElement =>
					candidate instanceof HTMLElement &&
					candidate.dataset['itemPath'] === path &&
					candidate.dataset['itemType'] === 'file' &&
					!candidate.hasAttribute('data-file-tree-sticky-row') &&
					!candidate.hasAttribute('data-item-parked'),
			);
			if (row === undefined) throw new Error(`Review file row missing: ${path}`);
			row.scrollIntoView({ block: 'center', inline: 'nearest' });
			row.click();
		}, props.path);
	} finally {
		if (previousSearchValue !== null) {
			await props.page.evaluate((value: string): void => {
				const searchInput = document
					.querySelector('[data-testid="bridge-review-trees-panel"] file-tree-container')
					?.shadowRoot?.querySelector('input[data-file-tree-search-input]');
				if (!(searchInput instanceof HTMLInputElement)) return;
				searchInput.value = value;
				searchInput.dispatchEvent(new InputEvent('input', { bubbles: true }));
			}, previousSearchValue);
		}
	}
}

export async function collectInPageReviewTreeClickPerformanceSample(props: {
	readonly displayPath: string;
	readonly page: Page;
	readonly timeoutMilliseconds: number;
}): Promise<InPageReviewTreeClickPerformanceSample> {
	return await props.page.evaluate(
		async (expected: {
			readonly displayPath: string;
			readonly firstVisibleContentStates: readonly string[];
			readonly timeoutMilliseconds: number;
		}): Promise<InPageReviewTreeClickPerformanceSample> => {
			const animationFrame = (): Promise<void> =>
				new Promise((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
			const reviewShell = (): HTMLElement | null => {
				const element = document.querySelector('[data-testid="review-viewer-shell"]');
				return element instanceof HTMLElement ? element : null;
			};
			const codePanel = (): HTMLElement | null => {
				const element = document.querySelector('[data-testid="bridge-code-view-panel"]');
				return element instanceof HTMLElement ? element : null;
			};
			const numberAttribute = (element: HTMLElement | null, name: string): number | null => {
				if (element === null) {
					return null;
				}
				const attributeValue = element.getAttribute(name);
				if (attributeValue === null || attributeValue.length === 0) {
					return null;
				}
				const value = Number(attributeValue);
				return Number.isFinite(value) && value >= 0 ? value : null;
			};
			const matchingTreeButton = (): HTMLElement | null => {
				const treeHost = document.querySelector(
					'[data-testid="bridge-review-trees-panel"] file-tree-container',
				);
				const button = Array.from(
					treeHost?.shadowRoot?.querySelectorAll('button[data-item-path]') ?? [],
				).find(
					(candidate): candidate is HTMLElement =>
						candidate instanceof HTMLElement &&
						candidate.dataset['itemPath'] === expected.displayPath &&
						candidate.dataset['itemType'] === 'file' &&
						!candidate.hasAttribute('data-file-tree-sticky-row') &&
						!candidate.hasAttribute('data-item-parked'),
				);
				return button instanceof HTMLElement ? button : null;
			};
			const visibleTreeButtonSelected = (): boolean => {
				const button = matchingTreeButton();
				if (button === null) {
					return false;
				}
				const buttonRect = button.getBoundingClientRect();
				const visible = buttonRect.width > 0 && buttonRect.height > 0;
				const selected =
					button.hasAttribute('data-item-selected') ||
					button.getAttribute('aria-selected') === 'true' ||
					button.getAttribute('data-selected') === 'true';
				return visible && selected;
			};
			const reviewCodeViewMaterializedSatisfied = (): boolean => {
				const shell = reviewShell();
				const panel = codePanel();
				if (shell === null || panel === null) {
					return false;
				}
				const additionLineCount = Number(
					panel.getAttribute('data-selected-materialized-addition-line-count') ?? '0',
				);
				const deletionLineCount = Number(
					panel.getAttribute('data-selected-materialized-deletion-line-count') ?? '0',
				);
				const fileLineCount = Number(
					panel.getAttribute('data-selected-materialized-file-line-count') ?? '0',
				);
				const selectedContentState = shell.getAttribute('data-selected-content-state');
				const selectedDisplayPath = shell.getAttribute('data-selected-display-path');
				const selectedPanelDisplayPath = panel.getAttribute('data-selected-display-path');
				const selectedMaterializedItemType = panel.getAttribute(
					'data-selected-materialized-item-type',
				);
				const selectedModelContentState = panel.getAttribute(
					'data-selected-materialized-model-content-state',
				);
				const hasRenderableLines =
					Number.isFinite(additionLineCount) &&
					Number.isFinite(deletionLineCount) &&
					Number.isFinite(fileLineCount) &&
					additionLineCount + deletionLineCount + fileLineCount > 0;
				return (
					selectedDisplayPath === expected.displayPath &&
					selectedPanelDisplayPath === expected.displayPath &&
					selectedContentState === 'ready' &&
					selectedMaterializedItemType !== null &&
					(selectedModelContentState === 'ready' ||
						selectedModelContentState === 'hydrated' ||
						selectedModelContentState === 'windowed') &&
					hasRenderableLines
				);
			};
			const reviewFirstVisibleContentWindowSatisfied = (): boolean => {
				const shell = reviewShell();
				const panel = codePanel();
				if (shell === null || panel === null) {
					return false;
				}
				const additionLineCount = Number(
					panel.getAttribute('data-selected-materialized-addition-line-count') ?? '0',
				);
				const deletionLineCount = Number(
					panel.getAttribute('data-selected-materialized-deletion-line-count') ?? '0',
				);
				const fileLineCount = Number(
					panel.getAttribute('data-selected-materialized-file-line-count') ?? '0',
				);
				const selectedContentState = shell.getAttribute('data-selected-content-state');
				const selectedDisplayPath = shell.getAttribute('data-selected-display-path');
				const selectedMaterializedItemType = panel.getAttribute(
					'data-selected-materialized-item-type',
				);
				const selectedModelContentState = panel.getAttribute(
					'data-selected-materialized-model-content-state',
				);
				const visibleText = [
					panel.textContent ?? '',
					...Array.from(document.querySelectorAll('diffs-container')).map(
						(container): string => container.shadowRoot?.textContent ?? '',
					),
				]
					.join(' ')
					.replace(/\s+/gu, ' ')
					.trim();
				const hasRenderableLines =
					Number.isFinite(additionLineCount) &&
					Number.isFinite(deletionLineCount) &&
					Number.isFinite(fileLineCount) &&
					additionLineCount + deletionLineCount + fileLineCount > 0;
				const stillOnlyLoading =
					visibleText.length > 0 &&
					visibleText.replace(/Loading content\.\.\.|Loading syntax view\.\.\./gu, '').trim()
						.length === 0;
				return (
					selectedDisplayPath === expected.displayPath &&
					selectedContentState === 'ready' &&
					selectedMaterializedItemType !== null &&
					selectedModelContentState !== null &&
					expected.firstVisibleContentStates.includes(selectedModelContentState) &&
					hasRenderableLines &&
					visibleText.length > 0 &&
					!stillOnlyLoading
				);
			};
			const waitForElapsedMilliseconds = async (
				predicate: () => boolean,
				label: string,
				startedAt: number,
			): Promise<number> => {
				while (performance.now() - startedAt <= expected.timeoutMilliseconds) {
					if (predicate()) {
						return Math.max(0, performance.now() - startedAt);
					}
					await animationFrame();
				}
				throw new Error(
					`Timed out waiting for in-page Review ${label} for ${expected.displayPath}`,
				);
			};
			const treeHost = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			const button = Array.from(
				treeHost?.shadowRoot?.querySelectorAll('button[data-item-path]') ?? [],
			).find(
				(candidate): candidate is HTMLElement =>
					candidate instanceof HTMLElement &&
					candidate.dataset['itemPath'] === expected.displayPath &&
					candidate.dataset['itemType'] === 'file' &&
					!candidate.hasAttribute('data-file-tree-sticky-row') &&
					!candidate.hasAttribute('data-item-parked'),
			);
			if (!(button instanceof HTMLElement)) {
				throw new Error(`Expected visible Worktree/Review tree button for ${expected.displayPath}`);
			}
			button.focus();
			const startedAt = performance.now();
			button.click();
			const clickDispatchMilliseconds = Math.max(0, performance.now() - startedAt);
			const [
				treeSelectionVisibleMilliseconds,
				selectedMilliseconds,
				readyMilliseconds,
				codeViewMaterializedMilliseconds,
				visibleContentRenderedMilliseconds,
			] = await Promise.all([
				waitForElapsedMilliseconds(visibleTreeButtonSelected, 'tree selection visible', startedAt),
				waitForElapsedMilliseconds(
					(): boolean =>
						reviewShell()?.getAttribute('data-selected-display-path') === expected.displayPath,
					'selection commit',
					startedAt,
				),
				waitForElapsedMilliseconds(
					(): boolean => {
						const shell = reviewShell();
						return (
							shell?.getAttribute('data-selected-display-path') === expected.displayPath &&
							shell?.getAttribute('data-selected-content-state') === 'ready'
						);
					},
					'selected ready',
					startedAt,
				),
				waitForElapsedMilliseconds(
					reviewCodeViewMaterializedSatisfied,
					'CodeView materialized metadata',
					startedAt,
				),
				waitForElapsedMilliseconds(
					reviewFirstVisibleContentWindowSatisfied,
					'first visible content window',
					startedAt,
				),
			]);
			const sample = {
				appSelectionCommitMilliseconds: numberAttribute(
					reviewShell(),
					'data-review-selection-commit-duration-ms',
				),
				codeViewMaterializedMilliseconds,
				clickDispatchMilliseconds,
				durationMilliseconds: visibleContentRenderedMilliseconds,
				readyMilliseconds,
				selectedMaterializationMilliseconds: numberAttribute(
					codePanel(),
					'data-selected-materialized-duration-ms',
				),
				selectedMilliseconds,
				treeSelectionVisibleMilliseconds,
				visibleContentRenderedMilliseconds,
			};
			window.bridgeWorktreeVerifierReviewClickSample = sample;
			return sample;
		},
		{
			displayPath: props.displayPath,
			firstVisibleContentStates: reviewFirstVisibleContentStates,
			timeoutMilliseconds: props.timeoutMilliseconds,
		},
	);
}

export async function waitForReviewTreeScrollSettled(page: Page): Promise<void> {
	await page.waitForFunction(
		async (): Promise<boolean> => {
			const treeHost = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			const treeRoot = treeHost?.shadowRoot ?? null;
			const root = treeRoot?.querySelector('[data-file-tree-virtualized-root="true"]');
			const list = treeRoot?.querySelector('[data-file-tree-virtualized-list="true"]');
			if (root?.hasAttribute('data-is-scrolling') || list?.hasAttribute('data-is-scrolling')) {
				return false;
			}
			await new Promise<void>((resolve): void => {
				requestAnimationFrame((): void => {
					resolve();
				});
			});
			await new Promise<void>((resolve): void => {
				requestAnimationFrame((): void => {
					resolve();
				});
			});
			return !(root?.hasAttribute('data-is-scrolling') || list?.hasAttribute('data-is-scrolling'));
		},
		undefined,
		{ timeout: 2_000 },
	);
}

export async function reviewTreeSelectedPathMatches(props: {
	readonly page: Page;
	readonly path: string;
	readonly timeoutMilliseconds: number;
}): Promise<boolean> {
	return await props.page
		.waitForFunction(
			(targetPath: string): boolean => {
				const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
				return reviewShell?.getAttribute('data-selected-display-path') === targetPath;
			},
			props.path,
			{ timeout: props.timeoutMilliseconds },
		)
		.then(
			() => true,
			() => false,
		);
}

export async function selectedReviewTreeTargetProof(props: {
	readonly page: Page;
	readonly path: string;
}): Promise<ReviewTreeSearchClickProof | null> {
	return props.page.evaluate((targetPath: string): ReviewTreeSearchClickProof | null => {
		const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
		if (reviewShell?.getAttribute('data-selected-display-path') !== targetPath) {
			return null;
		}
		return {
			clickedRowItemPath: targetPath,
			clickedRowItemType: 'file',
			clickedRowVisible: true,
			searchInputValue: null,
			searchOpened: true,
			selectedContentStateAfterClick:
				reviewShell?.getAttribute('data-selected-content-state') ?? null,
			selectedDisplayPathAfterClick:
				reviewShell?.getAttribute('data-selected-display-path') ?? null,
			selectionMethod: 'preselected-review-tree-target',
			targetPath,
		};
	}, props.path);
}

export async function waitForReviewSelectedContentState(props: {
	readonly displayPath: string;
	readonly page: Page;
	readonly state: 'failed' | 'loading' | 'ready';
}): Promise<void> {
	try {
		await props.page.waitForFunction(
			(expected: { readonly displayPath: string; readonly state: string }): boolean => {
				const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
				return (
					reviewShell?.getAttribute('data-selected-display-path') === expected.displayPath &&
					reviewShell?.getAttribute('data-selected-content-state') === expected.state
				);
			},
			{ displayPath: props.displayPath, state: props.state },
			{ timeout: 30_000 },
		);
	} catch (error) {
		const debugState = await props.page.evaluate((targetPath: string) => {
			const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
			const codePanel = document.querySelector('[data-testid="bridge-code-view-panel"]');
			return {
				currentDisplayPath: reviewShell?.getAttribute('data-selected-display-path') ?? null,
				currentState: reviewShell?.getAttribute('data-selected-content-state') ?? null,
				selectedItemId: codePanel?.getAttribute('data-selected-item-id') ?? null,
				targetPath,
			};
		}, props.displayPath);
		throw new Error(
			`Timed out waiting for Worktree/Review selected content ${props.state} for ${props.displayPath}: ${JSON.stringify(debugState)}`,
			{ cause: error },
		);
	}
}

export async function waitForAnyReviewSelectedContentState(props: {
	readonly page: Page;
	readonly state: 'failed' | 'loading' | 'ready';
}): Promise<void> {
	try {
		await props.page.waitForFunction(
			(expectedState: string): boolean => {
				const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
				const selectedDisplayPath = reviewShell?.getAttribute('data-selected-display-path') ?? null;
				return (
					selectedDisplayPath !== null &&
					reviewShell?.getAttribute('data-selected-content-state') === expectedState
				);
			},
			props.state,
			{ timeout: 30_000 },
		);
	} catch (error) {
		const debugState = await props.page.evaluate(() => {
			const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
			const codePanel = document.querySelector('[data-testid="bridge-code-view-panel"]');
			return {
				currentDisplayPath: reviewShell?.getAttribute('data-selected-display-path') ?? null,
				currentState: reviewShell?.getAttribute('data-selected-content-state') ?? null,
				selectedItemId: codePanel?.getAttribute('data-selected-item-id') ?? null,
			};
		});
		throw new Error(
			`Timed out waiting for any Worktree/Review selected content ${props.state}: ${JSON.stringify(debugState)}`,
			{ cause: error },
		);
	}
}

export async function waitForReviewVisibleDemandTelemetry(page: Page): Promise<void> {
	try {
		await page.waitForFunction(
			(): boolean => {
				const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
				if (!(reviewShell instanceof HTMLElement)) {
					return false;
				}
				const loadedCount = Number(
					reviewShell.getAttribute('data-review-visible-demand-loaded-count') ?? '0',
				);
				const visibleIntentCount = Number(
					reviewShell.getAttribute('data-review-visible-demand-visible-intent-count') ?? '0',
				);
				return (
					reviewShell.getAttribute('data-review-visible-demand-interest') === 'visible' &&
					Number.isFinite(loadedCount) &&
					Number.isFinite(visibleIntentCount) &&
					loadedCount > 0 &&
					loadedCount === visibleIntentCount
				);
			},
			undefined,
			{ timeout: 20_000 },
		);
	} catch (error) {
		const telemetry = await page.evaluate(() => {
			const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
			return {
				loadedCount:
					reviewShell instanceof HTMLElement
						? reviewShell.getAttribute('data-review-visible-demand-loaded-count')
						: null,
				interest:
					reviewShell instanceof HTMLElement
						? reviewShell.getAttribute('data-review-visible-demand-interest')
						: null,
				visibleIntentCount:
					reviewShell instanceof HTMLElement
						? reviewShell.getAttribute('data-review-visible-demand-visible-intent-count')
						: null,
			};
		});
		throw new Error(
			`Expected Review visible demand telemetry before perf clicks: ${JSON.stringify(telemetry)}`,
			{ cause: error },
		);
	}
}

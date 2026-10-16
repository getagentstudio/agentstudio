import type { Page } from 'playwright';

import {
	clickWorktreeFileControl,
	fillWorktreeFileSearch,
	selectWorktreeFileFilter,
	waitForWorktreeFileFilterStatus,
	worktreeFileControlPressed,
} from './file-search-filter.ts';
import {
	interactionPerformanceSampleCount,
	maximumNormalPerformanceLineCount,
	worktreeFileTreeReachableScanCount,
	type ReviewPerformanceClickTarget,
	type WorktreeFileDescriptor,
} from './types.ts';

export async function resetWorktreeFileTreeForPerformanceSamples(props: {
	readonly page: Page;
	readonly resetFilterLabel: string;
	readonly totalMetadataTreeRowCount: number;
}): Promise<void> {
	await selectWorktreeFileFilter(props.page, props.resetFilterLabel);
	if (await worktreeFileControlPressed(props.page, 'worktree-file-regex-toggle')) {
		await clickWorktreeFileControl(props.page, 'worktree-file-regex-toggle');
	}
	await fillWorktreeFileSearch(props.page, '');
	await waitForWorktreeFileFilterStatus(
		props.page,
		props.totalMetadataTreeRowCount,
		props.totalMetadataTreeRowCount,
	);
}

export async function worktreeFileTreeReachablePathSet(page: Page): Promise<ReadonlySet<string>> {
	const paths = await page.evaluate(async (sampleCount: number): Promise<readonly string[]> => {
		const helpers = window.bridgeWorktreeVerifier;
		const scrollElement = helpers.getPierreFileTreeScrollElement();
		if (!(scrollElement instanceof HTMLElement)) {
			throw new Error('Expected Pierre FileTree scroll element for reachable-path scan');
		}
		const reachablePaths = new Set<string>();
		const maxScrollTop = Math.max(0, scrollElement.scrollHeight - scrollElement.clientHeight);
		const animationFrame = (): Promise<void> =>
			new Promise((resolve): void => {
				requestAnimationFrame((): void => resolve());
			});
		for (let sampleIndex = 0; sampleIndex < sampleCount; sampleIndex += 1) {
			const targetScrollTop =
				sampleCount <= 1 ? 0 : Math.round((maxScrollTop * sampleIndex) / (sampleCount - 1));
			scrollElement.scrollTop = targetScrollTop;
			await animationFrame();
			await animationFrame();
			for (const candidate of helpers.getPierreFileTreeItems()) {
				if (candidate.dataset['itemType'] === 'file') {
					const path = candidate.dataset['itemPath'] ?? '';
					if (path.length > 0) {
						reachablePaths.add(path);
					}
				}
			}
		}
		return [...reachablePaths].sort((left, right): number => left.localeCompare(right));
	}, worktreeFileTreeReachableScanCount);
	return new Set(paths);
}

export async function waitForPerformanceFileTreeAnchorSettled(
	page: Page,
	path: string,
): Promise<void> {
	await page.waitForFunction(
		(targetPath: string): boolean => {
			const helpers = window.bridgeWorktreeVerifier;
			const scrollElement = helpers.getPierreFileTreeScrollElement();
			const anchor = helpers
				.getPierreFileTreeItems()
				.find((candidate) => candidate.dataset['itemPath'] === targetPath);
			const anchorVisible = (() => {
				if (!(scrollElement instanceof HTMLElement) || !(anchor instanceof HTMLElement)) {
					return false;
				}
				const scrollRect = scrollElement.getBoundingClientRect();
				const anchorRect = anchor.getBoundingClientRect();
				return anchorRect.bottom > scrollRect.top && anchorRect.top < scrollRect.bottom;
			})();
			if (
				!(scrollElement instanceof HTMLElement) ||
				!(anchor instanceof HTMLElement) ||
				!anchorVisible
			) {
				delete window.bridgeWorktreeVerifierLastTreeAnchorSignature;
				window.bridgeWorktreeVerifierStableTreeAnchorFrames = 0;
				return false;
			}
			const treeRect = scrollElement.getBoundingClientRect();
			const anchorRect = anchor.getBoundingClientRect();
			const visiblePaths = helpers
				.getPierreFileTreeItems()
				.map((candidate) => candidate.dataset['itemPath'] ?? '')
				.join('\u0000');
			const signature = [
				Math.round(scrollElement.scrollTop),
				Math.round(anchorRect.top - treeRect.top),
				visiblePaths,
			].join('|');
			if (window.bridgeWorktreeVerifierLastTreeAnchorSignature === signature) {
				window.bridgeWorktreeVerifierStableTreeAnchorFrames =
					(window.bridgeWorktreeVerifierStableTreeAnchorFrames ?? 0) + 1;
			} else {
				window.bridgeWorktreeVerifierLastTreeAnchorSignature = signature;
				window.bridgeWorktreeVerifierStableTreeAnchorFrames = 1;
			}
			return window.bridgeWorktreeVerifierStableTreeAnchorFrames >= 2;
		},
		path,
		{ timeout: 10_000 },
	);
}

export async function collectWorktreeTreeScrollPerformanceSamples(page: Page): Promise<{
	readonly blankTreeWindowCount: number;
	readonly durationMilliseconds: readonly number[];
	readonly settleFrameCounts: readonly number[];
	readonly wrongVisibleRowCount: number;
}> {
	const samples = await page.evaluate(
		async (
			sampleCount: number,
		): Promise<{
			readonly blankTreeWindowCount: number;
			readonly durationMilliseconds: readonly number[];
			readonly settleFrameCounts: readonly number[];
			readonly wrongVisibleRowCount: number;
		}> => {
			const helpers = window.bridgeWorktreeVerifier;
			const scrollElement = helpers.getPierreFileTreeScrollElement();
			if (!(scrollElement instanceof HTMLElement)) {
				throw new Error('Expected Pierre FileTree scroll element for performance proof');
			}
			const maxScrollTop = Math.max(0, scrollElement.scrollHeight - scrollElement.clientHeight);
			const durationMilliseconds: number[] = [];
			const settleFrameCounts: number[] = [];
			let blankTreeWindowCount = 0;
			let wrongVisibleRowCount = 0;
			const animationFrame = (): Promise<void> =>
				new Promise((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
			const visiblePathSignature = (): string =>
				helpers
					.getPierreFileTreeItems()
					.map((candidate): string => candidate.dataset['itemPath'] ?? '')
					.filter((path): boolean => path.length > 0)
					.join('\u0000');
			for (let sampleIndex = 0; sampleIndex < sampleCount; sampleIndex += 1) {
				const targetScrollTop =
					sampleCount <= 1 ? 0 : Math.round((maxScrollTop * sampleIndex) / (sampleCount - 1));
				const startedAt = performance.now();
				scrollElement.scrollTop = targetScrollTop;
				let previousSignature = '';
				let stableSignature = '';
				let settleFrameCount = 0;
				for (let frameIndex = 0; frameIndex < 24; frameIndex += 1) {
					await animationFrame();
					settleFrameCount = frameIndex + 1;
					const nextSignature = visiblePathSignature();
					if (nextSignature.length > 0 && nextSignature === previousSignature) {
						stableSignature = nextSignature;
						break;
					}
					previousSignature = nextSignature;
				}
				settleFrameCounts.push(stableSignature.length === 0 ? Number.NaN : settleFrameCount);
				durationMilliseconds.push(Math.max(0, performance.now() - startedAt));
				if (stableSignature.length === 0) {
					const latestSignature = visiblePathSignature();
					if (latestSignature.length === 0 && scrollElement.scrollHeight > 0) {
						blankTreeWindowCount += 1;
					} else {
						wrongVisibleRowCount += 1;
					}
				}
			}
			return {
				blankTreeWindowCount,
				durationMilliseconds,
				settleFrameCounts,
				wrongVisibleRowCount,
			};
		},
		interactionPerformanceSampleCount,
	);
	return samples;
}

export async function resetReviewTreeForPerformanceSamples(page: Page): Promise<void> {
	const reviewTreeContainerSelector =
		'[data-testid="bridge-review-trees-panel"] file-tree-container';
	const searchInputLocator = page
		.locator(`${reviewTreeContainerSelector} input[data-file-tree-search-input]`)
		.first();
	if (await searchInputLocator.isVisible()) {
		await searchInputLocator.fill('');
	}
	await page.waitForFunction(
		(): boolean => {
			const treeHost = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			const scrollElement = treeHost?.shadowRoot?.querySelector(
				'[data-file-tree-virtualized-scroll="true"]',
			);
			const rows =
				treeHost?.shadowRoot?.querySelectorAll(
					'button[data-item-path]:not([data-file-tree-sticky-row]):not([data-item-parked])',
				) ?? [];
			return scrollElement instanceof HTMLElement && rows.length > 0;
		},
		{ timeout: 10_000 },
	);
}

export async function collectReviewTreeScrollPerformanceSamples(page: Page): Promise<{
	readonly blankTreeWindowCount: number;
	readonly durationMilliseconds: readonly number[];
	readonly settleFrameCounts: readonly number[];
	readonly wrongVisibleRowCount: number;
}> {
	return await page.evaluate(
		async (
			sampleCount: number,
		): Promise<{
			readonly blankTreeWindowCount: number;
			readonly durationMilliseconds: readonly number[];
			readonly settleFrameCounts: readonly number[];
			readonly wrongVisibleRowCount: number;
		}> => {
			const treeHost = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			const scrollElement = treeHost?.shadowRoot?.querySelector(
				'[data-file-tree-virtualized-scroll="true"]',
			);
			if (!(scrollElement instanceof HTMLElement)) {
				throw new Error('Expected Worktree/Review tree scroll element for performance proof');
			}
			const reviewTreeItems = (): HTMLElement[] =>
				Array.from(
					treeHost?.shadowRoot?.querySelectorAll(
						'button[data-item-path]:not([data-file-tree-sticky-row]):not([data-item-parked])',
					) ?? [],
				).filter((candidate): candidate is HTMLElement => candidate instanceof HTMLElement);
			const visiblePathSignature = (): string =>
				reviewTreeItems()
					.map((candidate): string => candidate.dataset['itemPath'] ?? '')
					.filter((path): boolean => path.length > 0)
					.join('\u0000');
			const animationFrame = (): Promise<void> =>
				new Promise((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
			const maxScrollTop = Math.max(0, scrollElement.scrollHeight - scrollElement.clientHeight);
			const durationMilliseconds: number[] = [];
			const settleFrameCounts: number[] = [];
			let blankTreeWindowCount = 0;
			let wrongVisibleRowCount = 0;
			for (let sampleIndex = 0; sampleIndex < sampleCount; sampleIndex += 1) {
				const targetScrollTop =
					sampleCount <= 1 ? 0 : Math.round((maxScrollTop * sampleIndex) / (sampleCount - 1));
				const startedAt = performance.now();
				scrollElement.scrollTop = targetScrollTop;
				let previousSignature = '';
				let stableSignature = '';
				let settleFrameCount = 0;
				for (let frameIndex = 0; frameIndex < 24; frameIndex += 1) {
					await animationFrame();
					settleFrameCount = frameIndex + 1;
					const nextSignature = visiblePathSignature();
					if (nextSignature.length > 0 && nextSignature === previousSignature) {
						stableSignature = nextSignature;
						break;
					}
					previousSignature = nextSignature;
				}
				settleFrameCounts.push(stableSignature.length === 0 ? Number.NaN : settleFrameCount);
				durationMilliseconds.push(Math.max(0, performance.now() - startedAt));
				if (stableSignature.length === 0) {
					const latestSignature = visiblePathSignature();
					if (latestSignature.length === 0 && scrollElement.scrollHeight > 0) {
						blankTreeWindowCount += 1;
					} else {
						wrongVisibleRowCount += 1;
					}
				}
			}
			return {
				blankTreeWindowCount,
				durationMilliseconds,
				settleFrameCounts,
				wrongVisibleRowCount,
			};
		},
		interactionPerformanceSampleCount,
	);
}

export async function collectReviewCodeViewScrollPerformanceSamples(page: Page): Promise<{
	readonly blankWindowCount: number;
	readonly durationMilliseconds: readonly number[];
	readonly heightChangeCount: number;
	readonly settleFrameCounts: readonly number[];
}> {
	return await page.evaluate(
		async (
			sampleCount: number,
		): Promise<{
			readonly blankWindowCount: number;
			readonly durationMilliseconds: readonly number[];
			readonly heightChangeCount: number;
			readonly settleFrameCounts: readonly number[];
		}> => {
			const scrollElement = document.querySelector('.bridge-code-view-scroll-owner');
			const codePanel = document.querySelector('[data-testid="bridge-code-view-panel"]');
			if (!(scrollElement instanceof HTMLElement) || !(codePanel instanceof HTMLElement)) {
				throw new Error('Expected Worktree/Review CodeView scroll element for performance proof');
			}
			const animationFrame = (): Promise<void> =>
				new Promise((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
			const visibleContentSignature = (): string => {
				const shadowText = Array.from(document.querySelectorAll('diffs-container'))
					.map((container): string => container.shadowRoot?.textContent ?? '')
					.join(' ');
				return [codePanel.textContent ?? '', shadowText].join(' ').replace(/\s+/gu, ' ').trim();
			};
			const maxScrollTop = Math.max(0, scrollElement.scrollHeight - scrollElement.clientHeight);
			const durationMilliseconds: number[] = [];
			const settleFrameCounts: number[] = [];
			let blankWindowCount = 0;
			let heightChangeCount = 0;
			let previousScrollHeight = scrollElement.scrollHeight;
			for (let sampleIndex = 0; sampleIndex < sampleCount; sampleIndex += 1) {
				const targetScrollTop =
					sampleCount <= 1 ? 0 : Math.round((maxScrollTop * sampleIndex) / (sampleCount - 1));
				const startedAt = performance.now();
				scrollElement.scrollTop = targetScrollTop;
				let previousSignature = '';
				let stableSignature = '';
				let settleFrameCount = 0;
				for (let frameIndex = 0; frameIndex < 24; frameIndex += 1) {
					await animationFrame();
					settleFrameCount = frameIndex + 1;
					const nextSignature = visibleContentSignature();
					if (nextSignature.length > 0 && nextSignature === previousSignature) {
						stableSignature = nextSignature;
						break;
					}
					previousSignature = nextSignature;
				}
				if (scrollElement.scrollHeight !== previousScrollHeight) {
					heightChangeCount += 1;
					previousScrollHeight = scrollElement.scrollHeight;
				}
				settleFrameCounts.push(stableSignature.length === 0 ? Number.NaN : settleFrameCount);
				durationMilliseconds.push(Math.max(0, performance.now() - startedAt));
				if (stableSignature.length === 0) {
					blankWindowCount += 1;
				}
			}
			return { blankWindowCount, durationMilliseconds, heightChangeCount, settleFrameCounts };
		},
		interactionPerformanceSampleCount,
	);
}

export function normalWorktreeFilePerformanceDescriptors(
	descriptors: readonly WorktreeFileDescriptor[],
): readonly WorktreeFileDescriptor[] {
	return descriptors
		.filter((descriptor): boolean => {
			const lineCount = Number(descriptor['lineCount'] ?? 0);
			return (
				worktreeFilePathEligibleForPerformanceClick(descriptor.path) &&
				!descriptor['isBinary'] &&
				descriptor['virtualizedExtentKind'] === 'exactLineCount' &&
				Number.isFinite(lineCount) &&
				lineCount > 0 &&
				lineCount <= maximumNormalPerformanceLineCount
			);
		})
		.toSorted((left, right): number => left.path.localeCompare(right.path));
}

export function normalWorktreeReviewPerformanceClickTargets(
	clickTargets: readonly ReviewPerformanceClickTarget[],
): readonly ReviewPerformanceClickTarget[] {
	return clickTargets
		.filter((target): boolean => {
			const lineCount = target.lineCount;
			return (
				worktreeFilePathEligibleForPerformanceClick(target.displayPath) &&
				(lineCount === null ||
					(Number.isFinite(lineCount) &&
						lineCount > 0 &&
						lineCount <= maximumNormalPerformanceLineCount))
			);
		})
		.toSorted((left, right): number => left.displayPath.localeCompare(right.displayPath));
}

export function worktreeFilePathEligibleForPerformanceClick(path: string): boolean {
	return path.split('/').every((segment): boolean => !segment.startsWith('.'));
}

export function worktreeFileDescriptorExpectedBytes(
	descriptor: WorktreeFileDescriptor,
): number | null {
	const content = descriptor.contentDescriptor.descriptor['content'];
	if (content === null || typeof content !== 'object') {
		return null;
	}
	const expectedBytes = 'expectedBytes' in content ? content.expectedBytes : undefined;
	if (typeof expectedBytes === 'number' && Number.isFinite(expectedBytes)) {
		return expectedBytes;
	}
	const maxBytes = 'maxBytes' in content ? content.maxBytes : undefined;
	return typeof maxBytes === 'number' && Number.isFinite(maxBytes) ? maxBytes : null;
}

export function evenlySampledDescriptors(props: {
	readonly descriptors: readonly WorktreeFileDescriptor[];
	readonly sampleCount: number;
}): readonly WorktreeFileDescriptor[] {
	if (props.descriptors.length < props.sampleCount) {
		return [];
	}
	return Array.from({ length: props.sampleCount }, (_, sampleIndex): WorktreeFileDescriptor => {
		const descriptorIndex =
			props.sampleCount <= 1
				? 0
				: Math.floor((sampleIndex * (props.descriptors.length - 1)) / (props.sampleCount - 1));
		const descriptor = props.descriptors[descriptorIndex];
		if (descriptor === undefined) {
			throw new Error(`Missing Worktree/File performance descriptor at ${descriptorIndex}`);
		}
		return descriptor;
	});
}

export function evenlySampledReviewClickTargets(props: {
	readonly clickTargets: readonly ReviewPerformanceClickTarget[];
	readonly sampleCount: number;
}): readonly ReviewPerformanceClickTarget[] {
	if (props.clickTargets.length === 0) {
		return [];
	}
	return Array.from(
		{ length: props.sampleCount },
		(_, sampleIndex): ReviewPerformanceClickTarget => {
			const clickTargetIndex =
				props.clickTargets.length === 1
					? 0
					: Math.floor((sampleIndex * (props.clickTargets.length - 1)) / (props.sampleCount - 1));
			const clickTarget = props.clickTargets[clickTargetIndex];
			if (clickTarget === undefined) {
				throw new Error(`Missing Worktree/Review performance click target at ${clickTargetIndex}`);
			}
			return clickTarget;
		},
	);
}

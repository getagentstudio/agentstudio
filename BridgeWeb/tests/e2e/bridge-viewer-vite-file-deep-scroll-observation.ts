import type { Page } from 'playwright';

import {
	decodePaintedSourceCorrelations,
	type PaintedSourceCorrelation,
} from './bridge-viewer-vite-painted-source-correlation.ts';
import type {
	BridgeViewerViteProductContentOracle,
	BridgeViewerViteProductFixtureOracle,
} from './bridge-viewer-vite-product-fixture.ts';

const fileDeepScrollWaitTimeoutMilliseconds = 120_000;

export interface FileDeepScrollObservation {
	readonly deepTreePathPainted: boolean;
	readonly finalMarkerPainted: boolean;
	readonly lineCount: number;
	readonly paintedCorrelations: readonly PaintedSourceCorrelation[];
	readonly renderedItemId: string | null;
	readonly renderedPath: string | null;
	readonly scrollHeight: number;
	readonly scrollTop: number;
	readonly selectedPath: string | null;
	readonly treeScrollTop: number;
	readonly workerUrls: readonly string[];
}

interface FileDeepScrollBrowserSnapshot extends Omit<
	FileDeepScrollObservation,
	'paintedCorrelations'
> {
	readonly encodedPaintedCorrelations: string;
}

export interface FileContentScrollObservation {
	readonly finalMarkerPainted: boolean;
	readonly firstMarkerPainted: boolean;
	readonly middleMarkerPainted: boolean;
}

export async function clearFileSearchAndScrollTreeDeep(props: {
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly page: Page;
}): Promise<void> {
	const searchInput = props.page.locator('[data-testid="worktree-file-search-input"]');
	if ((await searchInput.count()) > 0) await searchInput.fill('');
	await props.page.waitForFunction(
		(targetPath: string): boolean => {
			const treeHost = document.querySelector(
				'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
			);
			const scrollOwner = treeHost?.shadowRoot?.querySelector(
				'[data-file-tree-virtualized-scroll="true"]',
			);
			if (!(scrollOwner instanceof HTMLElement)) return false;
			scrollOwner.scrollTop = Math.max(0, scrollOwner.scrollHeight - scrollOwner.clientHeight);
			scrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
			return scrollOwner.scrollTop > 0 && targetPath.length > 0;
		},
		props.oracle.fileTreeDeepPath,
		{ timeout: fileDeepScrollWaitTimeoutMilliseconds },
	);
	await props.page.waitForFunction(
		(targetPath: string): boolean => {
			const treeHost = document.querySelector(
				'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
			);
			return (
				treeHost?.shadowRoot?.querySelector(`[data-item-path="${CSS.escape(targetPath)}"]`) !== null
			);
		},
		props.oracle.fileTreeDeepPath,
		{ timeout: fileDeepScrollWaitTimeoutMilliseconds },
	);
}

export async function scrollSelectedFileThroughMarkers(props: {
	readonly content: BridgeViewerViteProductContentOracle;
	readonly page: Page;
}): Promise<FileContentScrollObservation> {
	const observedMarkers = new Set<string>();
	for (const [scrollFraction, marker] of [
		[0, props.content.firstMarker],
		[0.5, props.content.middleMarker],
		[1, props.content.finalMarker],
	] as const) {
		// oxlint-disable-next-line no-await-in-loop -- Each virtualized content window must paint before advancing.
		await props.page.evaluate((fraction: number): void => {
			const scrollOwner = document.querySelector(
				'[data-testid="bridge-file-viewer-code-view"] .bridge-code-view-scroll-owner',
			);
			if (!(scrollOwner instanceof HTMLElement))
				throw new Error('File CodeView scroll owner missing.');
			scrollOwner.scrollTop = Math.max(
				0,
				(scrollOwner.scrollHeight - scrollOwner.clientHeight) * fraction,
			);
			scrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
		}, scrollFraction);
		// oxlint-disable-next-line no-await-in-loop -- Marker observation is the bounded event for each scroll.
		await props.page.waitForFunction(
			(markerText: string): boolean => {
				const pendingRoots: Array<Document | Element | ShadowRoot> = [document];
				while (pendingRoots.length > 0) {
					const root = pendingRoots.shift();
					if (root === undefined) break;
					if (
						[...root.querySelectorAll('[data-line-index], [data-content]')].some((element) =>
							(element.textContent ?? '').includes(markerText),
						)
					) {
						return true;
					}
					for (const descendant of root.querySelectorAll('*')) {
						if (descendant.shadowRoot !== null) pendingRoots.push(descendant.shadowRoot);
					}
				}
				return false;
			},
			marker,
			{ timeout: fileDeepScrollWaitTimeoutMilliseconds },
		);
		observedMarkers.add(marker);
	}
	return {
		finalMarkerPainted: observedMarkers.has(props.content.finalMarker),
		firstMarkerPainted: observedMarkers.has(props.content.firstMarker),
		middleMarkerPainted: observedMarkers.has(props.content.middleMarker),
	};
}

export async function readFileDeepScrollObservation(props: {
	readonly content?: BridgeViewerViteProductContentOracle;
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly page: Page;
	readonly workerUrls: readonly string[];
}): Promise<FileDeepScrollObservation> {
	const content = props.content ?? props.oracle.fileContent;
	const snapshot = await props.page.evaluate(
		({ deepTreePath, finalMarker, workerUrls }): FileDeepScrollBrowserSnapshot => {
			const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
			const renderedItem = canvas?.querySelector(
				'diffs-container[data-bridge-painted-source-correlations]',
			);
			const scrollOwner = document.querySelector(
				'[data-testid="bridge-file-viewer-code-view"] .bridge-code-view-scroll-owner',
			);
			if (!(canvas instanceof HTMLElement) || !(scrollOwner instanceof HTMLElement)) {
				throw new Error(
					'File deep-scroll observation requires the mounted canvas and scroll owner.',
				);
			}
			const encodedCorrelations =
				renderedItem?.getAttribute('data-bridge-painted-source-correlations') ?? '[]';
			const pendingRoots: Array<Document | Element | ShadowRoot> = [document];
			const paintedText: string[] = [];
			while (pendingRoots.length > 0) {
				const root = pendingRoots.shift();
				if (root === undefined) break;
				paintedText.push(
					...[...root.querySelectorAll('[data-line-index], [data-content]')].map(
						(element): string => element.textContent ?? '',
					),
				);
				for (const descendant of root.querySelectorAll('*')) {
					if (descendant.shadowRoot !== null) pendingRoots.push(descendant.shadowRoot);
				}
			}
			const treeHost = document.querySelector(
				'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
			);
			const treeScrollOwner = treeHost?.shadowRoot?.querySelector(
				'[data-file-tree-virtualized-scroll="true"]',
			);
			return {
				deepTreePathPainted:
					treeHost?.shadowRoot?.querySelector(`[data-item-path="${CSS.escape(deepTreePath)}"]`) !==
					null,
				encodedPaintedCorrelations: encodedCorrelations,
				finalMarkerPainted: paintedText.some((text): boolean => text.includes(finalMarker)),
				lineCount: Number(canvas.getAttribute('data-worktree-rendered-line-count') ?? '0'),
				renderedItemId: canvas.getAttribute('data-worktree-rendered-item-id'),
				renderedPath: canvas.getAttribute('data-worktree-rendered-file-path'),
				scrollHeight: scrollOwner.scrollHeight,
				scrollTop: scrollOwner.scrollTop,
				selectedPath: canvas.getAttribute('data-worktree-open-file-path'),
				treeScrollTop: treeScrollOwner instanceof HTMLElement ? treeScrollOwner.scrollTop : 0,
				workerUrls,
			};
		},
		{
			deepTreePath: props.oracle.fileTreeDeepPath,
			finalMarker: content.finalMarker,
			workerUrls: props.workerUrls,
		},
	);
	const { encodedPaintedCorrelations, ...observation } = snapshot;
	return {
		...observation,
		paintedCorrelations: decodePaintedSourceCorrelations(encodedPaintedCorrelations),
	};
}

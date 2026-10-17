import { act } from 'react';

import type { BridgeProductCallResult } from '../core/comm-worker/bridge-product-call-contracts.js';
import type { BridgeTelemetrySample } from '../foundation/telemetry/bridge-telemetry-event.js';
import type { BridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import {
	findBridgeViewerTreeScrollOwner,
	waitForBridgeViewerAnimationFrame,
} from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import type {
	BrowserFileViewScope,
	PublishBrowserFileBatch,
} from './bridge-file-viewer-browser-test-batches.js';
import {
	beginBridgeFileViewerBrowserInteractionAct,
	createBridgeFileViewerBrowserTestPaneSessionFactory,
	prepareNextBridgeFileViewerBrowserQueryCompletion,
	type BridgeFileViewerBrowserTestPaneSessionFactory,
	waitForBridgeFileViewerWorkerMessageDrain,
	waitForBridgeFileViewerWorkerPublicationQueue,
} from './bridge-file-viewer-browser-test-comm-worker.js';

export {
	createBridgeFileViewerBrowserTestPaneSessionFactory,
	type BridgeFileViewerBrowserTestPaneSessionFactory,
	waitForBridgeFileViewerWorkerMessageDrain,
};

export async function settleBridgeFileViewerBrowserUpdates(): Promise<void> {
	await waitForBridgeFileViewerWorkerMessageDrain();
	await actFrame();
	await actFrame();
	await actFrame();
	await actFrame();
	await waitForBridgeFileViewerWorkerMessageDrain();
	// The final worker drain can commit the display snapshot that triggers
	// selection reconciliation in a passive effect. Advance one more act-scoped
	// frame so that effect's state update is committed before the test asserts.
	await actFrame();
}

export async function settleBridgeFileViewerBrowserInteraction(): Promise<void> {
	await waitForBridgeFileViewerWorkerMessageDrain();
	await actFrame();
	await waitForBridgeFileViewerWorkerMessageDrain();
}

export async function interactAndWaitForBridgeFileViewerQueryCompletion(
	actScopedInteraction: () => void | Promise<void>,
): Promise<void> {
	const completion = prepareNextBridgeFileViewerBrowserQueryCompletion();
	const endInteractionAct = beginBridgeFileViewerBrowserInteractionAct();
	try {
		await act(async (): Promise<void> => {
			await actScopedInteraction();
		});
		endInteractionAct();
		await act(async (): Promise<void> => {
			await completion.promise;
			await waitForBridgeFileViewerWorkerPublicationQueue();
		});
	} catch (error: unknown) {
		endInteractionAct();
		completion.cancel();
		throw error;
	}
}

export function installBridgeFileViewerNoopResizeObserver(): void {
	Object.assign(globalThis, { ResizeObserver: BridgeFileViewerNoopResizeObserver });
}

export function bridgeFileViewerNoopResizeObserverIsInstalled(): boolean {
	return globalThis.ResizeObserver === BridgeFileViewerNoopResizeObserver;
}

export function requireBrowserFileBatchPublisher(
	publisher: PublishBrowserFileBatch | null,
): PublishBrowserFileBatch {
	if (publisher === null) {
		throw new Error('File metadata subscription was not initialized.');
	}
	return publisher;
}

export function makeBrowserFileBatchPublisherObservation(): {
	readonly publisher: Promise<PublishBrowserFileBatch>;
	readonly observe: (publisher: PublishBrowserFileBatch) => void;
} {
	let resolvePublisher: ((publisher: PublishBrowserFileBatch) => void) | undefined;
	const publisher = new Promise<PublishBrowserFileBatch>((resolve): void => {
		resolvePublisher = resolve;
	});
	return {
		publisher,
		observe: (receivedPublisher): void => {
			if (resolvePublisher === undefined) {
				throw new Error('File batch publisher observation was not initialized.');
			}
			resolvePublisher(receivedPublisher);
		},
	};
}

export function metadataInterestPathsForLane(
	update: BrowserFileViewScope,
	lane: BrowserFileViewScope['interests'][number]['lane'],
): readonly string[] {
	return update.interests.find((interest) => interest.lane === lane)?.paths ?? [];
}

export function requireDeactivateFiles(deactivateFiles: (() => void) | null): () => void {
	if (deactivateFiles === null) {
		throw new Error('Controlled FileViewer did not publish its deactivate callback.');
	}
	return deactivateFiles;
}

export function requireActivateFiles(activateFiles: (() => void) | null): () => void {
	if (activateFiles === null) {
		throw new Error('Controlled FileViewer did not publish its activate callback.');
	}
	return activateFiles;
}

export function requireOpenSlowFile(openSlowFile: (() => void) | null): () => void {
	if (openSlowFile === null) {
		throw new Error('Controlled FileViewer did not publish its open callback.');
	}
	return openSlowFile;
}

class BridgeFileViewerNoopResizeObserver implements ResizeObserver {
	disconnect(): void {}

	observe(_target: Element): void {}

	unobserve(_target: Element): void {}
}

/**
 * This app mounts real resizable-panel/tree/code-view chrome (ResizeObserver
 * and rAF-driven layout settling) and every `waitForXxxAttempt` poll below
 * advances one real animation frame at a time until its condition holds.
 * Each tick must open and close its own `act()` scope: wrapping the *entire*
 * multi-frame recursive poll in a single outer `act()` call instead defers
 * React's DOM commits until that outer call resolves, so the very condition
 * being polled for can never become true while the poll is still running.
 * Advancing one frame per `act()` call lets each tick's update commit to the
 * DOM before the next check runs.
 */
export async function actFrame(): Promise<void> {
	await act(async (): Promise<void> => {
		await waitForBridgeViewerAnimationFrame();
	});
}

/** Wraps a click so any React updates it triggers are act()-protected. */
export async function actClick(element: { readonly click: () => void }): Promise<void> {
	await act(async (): Promise<void> => {
		element.click();
		await Promise.resolve();
	});
}

/**
 * Wraps a synchronous, state-mutating action (a ref-published setter, a
 * deferred-promise resolve, a direct frame-publisher call) plus one
 * microtask drain in act(). Use this for a single discrete action, not a
 * multi-frame poll — see the `actFrame` note above for why those differ.
 */
export async function actUpdate(update: () => void | Promise<void>): Promise<void> {
	await act(async (): Promise<void> => {
		await update();
		await Promise.resolve();
	});
}

export async function actUpdateAndWaitForBridgeFileViewerWorkerPublication(
	update: () => void | Promise<void>,
): Promise<void> {
	const endInteractionAct = beginBridgeFileViewerBrowserInteractionAct();
	try {
		await act(async (): Promise<void> => {
			await update();
			await Promise.resolve();
		});
		endInteractionAct();
		await waitForBridgeFileViewerWorkerPublicationQueue();
	} catch (error: unknown) {
		endInteractionAct();
		throw error;
	}
}

export async function waitForOpenFileState(expectedState: string): Promise<void> {
	await waitForOpenFileStateAttempt({ attempt: 0, expectedState });
}

export async function waitForFileViewerActiveState(expectedState: string): Promise<void> {
	await waitForFileViewerActiveStateAttempt({ attempt: 0, expectedState });
}

export async function waitForRefreshButtonEnabled(): Promise<void> {
	await waitForRefreshButtonEnabledAttempt({ attempt: 0 });
}

export async function waitForDemandDispatchState(expectedState: string): Promise<void> {
	await waitForDemandDispatchStateAttempt({ attempt: 0, expectedState });
}

export async function waitForDemandDispatchLoadedCount(expectedLoadedCount: string): Promise<void> {
	await waitForDemandDispatchLoadedCountAttempt({ attempt: 0, expectedLoadedCount });
}

export async function waitForDemandDispatchFirstLane(expectedFirstLane: string): Promise<void> {
	await waitForDemandDispatchFirstLaneAttempt({ attempt: 0, expectedFirstLane });
}

export async function waitForOpenedContentCount(props: {
	readonly expectedCount: number;
	readonly openedDescriptorIds: readonly string[];
}): Promise<void> {
	await waitForOpenedContentCountAttempt({
		attempt: 0,
		expectedCount: props.expectedCount,
		openedDescriptorIds: props.openedDescriptorIds,
	});
}

export async function waitForMetadataInterestUpdateCount(props: {
	readonly expectedCount: number;
	readonly metadataInterestUpdates: readonly BrowserFileViewScope[];
}): Promise<void> {
	await waitForMetadataInterestUpdateCountAttempt({
		attempt: 0,
		expectedCount: props.expectedCount,
		metadataInterestUpdates: props.metadataInterestUpdates,
	});
}

export async function waitForMetadataTreeRowCount(expectedCount: number): Promise<void> {
	await waitForMetadataTreeRowCountAttempt({ attempt: 0, expectedCount });
}

export async function waitForSelectedDisplayPath(expectedPath: string): Promise<void> {
	await waitForSelectedDisplayPathAttempt({ attempt: 0, expectedPath });
}

export async function waitForMetadataSubscriptionOpenCount(props: {
	readonly expectedCount: number;
	readonly getLoadCount: () => number;
}): Promise<void> {
	await waitForMetadataSubscriptionOpenCountAttempt({
		attempt: 0,
		expectedCount: props.expectedCount,
		getLoadCount: props.getLoadCount,
	});
}

export function makeTestTelemetryRecorder(
	samples: BridgeTelemetrySample[],
): BridgeTelemetryRecorder {
	return {
		isEnabled: (scope): boolean => scope === 'web',
		record: (sample): void => {
			samples.push(sample);
		},
		measure: (props): ReturnType<typeof props.operation> => props.operation(),
		flush: (): boolean => true,
	};
}

export async function waitForTelemetrySample(props: {
	readonly name: string;
	readonly samples: readonly BridgeTelemetrySample[];
}): Promise<BridgeTelemetrySample> {
	return waitForTelemetrySampleCount({
		count: 1,
		name: props.name,
		samples: props.samples,
	});
}

export async function waitForTelemetrySampleCount(props: {
	readonly count: number;
	readonly name: string;
	readonly samples: readonly BridgeTelemetrySample[];
	readonly attempt?: number;
}): Promise<BridgeTelemetrySample> {
	const matchingSamples = props.samples.filter((sample): boolean => sample.name === props.name);
	if (matchingSamples.length >= props.count) {
		const sample = matchingSamples.at(props.count - 1);
		if (sample === undefined) {
			throw new Error(`Expected telemetry sample at index ${props.count - 1}.`);
		}
		return sample;
	}
	const attempt = props.attempt ?? 0;
	if (attempt >= 60) {
		throw new Error(
			`Expected ${props.count} telemetry samples named ${props.name}; actual=${matchingSamples.length}`,
		);
	}
	await actFrame();
	return waitForTelemetrySampleCount({
		...props,
		attempt: attempt + 1,
	});
}

export async function waitForFileCodeViewViewport(): Promise<HTMLElement> {
	await waitForBridgeFileViewerWorkerMessageDrain();
	return waitForFileCodeViewViewportAttempt({ attempt: 0 });
}

export async function waitForFileCodeViewScrollOwner(): Promise<HTMLElement> {
	return waitForFileCodeViewScrollOwnerAttempt({ attempt: 0 });
}

export async function waitForFileCodeViewScrollable(scrollOwner: HTMLElement): Promise<void> {
	await waitForFileCodeViewScrollableAttempt({ attempt: 0, scrollOwner });
}

export async function waitForFileCodeViewScrollTopAtLeast(props: {
	readonly minimumScrollTop: number;
	readonly scrollOwner: HTMLElement;
}): Promise<void> {
	await waitForFileCodeViewScrollTopAtLeastAttempt({
		attempt: 0,
		minimumScrollTop: props.minimumScrollTop,
		scrollOwner: props.scrollOwner,
	});
}

export async function waitForOpenFileStateAttempt(props: {
	readonly attempt: number;
	readonly expectedState: string;
}): Promise<void> {
	if (openFileState() === props.expectedState) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected open file state ${props.expectedState}; actual=${openFileState() ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForOpenFileStateAttempt({
		attempt: props.attempt + 1,
		expectedState: props.expectedState,
	});
}

export async function waitForRefreshButtonEnabledAttempt(props: {
	readonly attempt: number;
}): Promise<void> {
	if (!refreshButtonIsDisabled()) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error('Expected Worktree/File refresh button to become enabled.');
	}
	await actFrame();
	await waitForRefreshButtonEnabledAttempt({ attempt: props.attempt + 1 });
}

export async function waitForFileCodeViewViewportAttempt(props: {
	readonly attempt: number;
}): Promise<HTMLElement> {
	const viewport = document.querySelector('[data-testid="bridge-file-viewer-code-view"]');
	if (viewport instanceof HTMLElement) {
		await actFrame();
		const confirmedViewport = document.querySelector(
			'[data-testid="bridge-file-viewer-code-view"]',
		);
		if (viewport.isConnected && confirmedViewport === viewport) {
			return viewport;
		}
	}
	if (props.attempt >= 60) {
		throw new Error('Expected one connected File CodeView viewport across a stable frame.');
	}
	if (!(viewport instanceof HTMLElement)) {
		await actFrame();
	}
	return waitForFileCodeViewViewportAttempt({ attempt: props.attempt + 1 });
}

export async function waitForFileCodeViewScrollOwnerAttempt(props: {
	readonly attempt: number;
}): Promise<HTMLElement> {
	const scrollOwner = document.querySelector('.bridge-code-view-scroll-owner');
	if (scrollOwner instanceof HTMLElement) {
		return scrollOwner;
	}
	if (props.attempt >= 60) {
		throw new Error('Expected File CodeView scroll owner to be mounted.');
	}
	await actFrame();
	return waitForFileCodeViewScrollOwnerAttempt({ attempt: props.attempt + 1 });
}

export async function waitForFileCodeViewScrollableAttempt(props: {
	readonly attempt: number;
	readonly scrollOwner: HTMLElement;
}): Promise<void> {
	if (props.scrollOwner.scrollHeight > props.scrollOwner.clientHeight + 32) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected File CodeView to be scrollable; scrollHeight=${props.scrollOwner.scrollHeight}; clientHeight=${props.scrollOwner.clientHeight}`,
		);
	}
	await actFrame();
	await waitForFileCodeViewScrollableAttempt({
		attempt: props.attempt + 1,
		scrollOwner: props.scrollOwner,
	});
}

async function waitForFileCodeViewScrollTopAtLeastAttempt(props: {
	readonly attempt: number;
	readonly minimumScrollTop: number;
	readonly scrollOwner: HTMLElement;
}): Promise<void> {
	if (props.scrollOwner.scrollTop >= props.minimumScrollTop) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected File CodeView scrollTop >= ${props.minimumScrollTop}; actual=${props.scrollOwner.scrollTop}`,
		);
	}
	await actFrame();
	await waitForFileCodeViewScrollTopAtLeastAttempt({
		...props,
		attempt: props.attempt + 1,
	});
}

export function openFileState(): string | null {
	return (
		document
			.querySelector('[data-worktree-open-file-state]')
			?.getAttribute('data-worktree-open-file-state') ?? null
	);
}

export function refreshButtonIsDisabled(): boolean {
	const refreshButton = document.querySelector('[data-testid="worktree-file-refresh"]');
	if (!(refreshButton instanceof HTMLButtonElement)) {
		throw new Error('Expected Worktree/File refresh button to be mounted.');
	}
	return refreshButton.disabled;
}

export function openFilePath(): string | null {
	return (
		document
			.querySelector('[data-worktree-open-file-path]')
			?.getAttribute('data-worktree-open-file-path') ?? null
	);
}

export function selectedDisplayPath(): string | null {
	return (
		document
			.querySelector('[data-testid="bridge-file-viewer-shell"]')
			?.getAttribute('data-selected-display-path') ?? null
	);
}

export function visibleCodeText(): string {
	const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
	if (!(canvas instanceof HTMLElement)) {
		return '';
	}
	const codeViewContainer = canvas.querySelector('[data-testid="bridge-file-viewer-code-view"]');
	if (
		codeViewContainer instanceof HTMLElement &&
		getComputedStyle(codeViewContainer).visibility === 'hidden'
	) {
		return '';
	}
	const renderedText = Array.from(canvas.querySelectorAll('diffs-container'))
		.flatMap((container) =>
			Array.from(container.shadowRoot?.querySelectorAll('[data-content]') ?? []),
		)
		.map((contentBlock) => contentBlock.textContent ?? '')
		.join('\n');
	return renderedText.length > 0 ? renderedText : (canvas.textContent ?? '');
}

export function openFileBodyPreview(): string | null {
	return (
		document
			.querySelector('[data-testid="bridge-file-viewer-code-canvas"]')
			?.getAttribute('data-worktree-open-file-body-preview') ?? null
	);
}

export function renderedFilePath(): string | null {
	return (
		document
			.querySelector('[data-testid="bridge-file-viewer-code-canvas"]')
			?.getAttribute('data-worktree-rendered-file-path') ?? null
	);
}

export async function waitForOpenFileBodyPreview(expectedText: string): Promise<void> {
	await waitForOpenFileBodyPreviewAttempt({ attempt: 0, expectedText });
}

export async function waitForOpenFileBodyPreviewAttempt(props: {
	readonly attempt: number;
	readonly expectedText: string;
}): Promise<void> {
	const actualPreview = openFileBodyPreview();
	if (actualPreview?.includes(props.expectedText) === true) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected open file body preview ${props.expectedText}; actual=${actualPreview ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForOpenFileBodyPreviewAttempt({
		attempt: props.attempt + 1,
		expectedText: props.expectedText,
	});
}

export function fileCanvasRenderedTextOffset(text: string): number | null {
	const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
	if (!(canvas instanceof HTMLElement)) {
		return null;
	}
	return renderedTextOffsetWithinRoot({
		canvas,
		root: canvas,
		text,
		visitedRoots: new Set<ParentNode>(),
	});
}

export function renderedTextOffsetWithinRoot(props: {
	readonly canvas: HTMLElement;
	readonly root: ParentNode;
	readonly text: string;
	readonly visitedRoots: Set<ParentNode>;
}): number | null {
	if (props.visitedRoots.has(props.root)) {
		return null;
	}
	props.visitedRoots.add(props.root);
	const walker = document.createTreeWalker(props.root, NodeFilter.SHOW_TEXT);
	let currentNode = walker.nextNode();
	while (currentNode !== null) {
		if (currentNode.textContent?.includes(props.text)) {
			const parentElement = currentNode.parentElement;
			if (parentElement instanceof HTMLElement) {
				return parentElement.getBoundingClientRect().top - props.canvas.getBoundingClientRect().top;
			}
		}
		currentNode = walker.nextNode();
	}
	for (const candidate of props.root.querySelectorAll<HTMLElement>('[data-line-index]')) {
		if (candidate.textContent?.includes(props.text)) {
			return candidate.getBoundingClientRect().top - props.canvas.getBoundingClientRect().top;
		}
	}
	const shadowRootOffsets = Array.from(props.root.querySelectorAll('*')).flatMap(
		(element): readonly number[] => {
			const shadowRoot = element.shadowRoot;
			if (shadowRoot === null) {
				return [];
			}
			const offset = renderedTextOffsetWithinRoot({
				canvas: props.canvas,
				root: shadowRoot,
				text: props.text,
				visitedRoots: props.visitedRoots,
			});
			return offset === null ? [] : [offset];
		},
	);
	return shadowRootOffsets.length === 0 ? null : Math.min(...shadowRootOffsets);
}

export async function waitForVisibleCodeText(expectedText: string): Promise<void> {
	await waitForVisibleCodeTextAttempt({ attempt: 0, expectedText });
}

export function makeGeneratedFileBody(label: string, lineCount: number): string {
	return Array.from(
		{ length: lineCount },
		(_value, index): string =>
			`export const ${label}Line${String(index + 1).padStart(3, '0')} = true;`,
	).join('\n');
}

export async function waitForVisibleCodeTextAttempt(props: {
	readonly attempt: number;
	readonly expectedText: string;
}): Promise<void> {
	const actualText = visibleCodeText();
	if (actualText.includes(props.expectedText)) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected visible code text ${props.expectedText}; actual=${actualText.slice(0, 300)}`,
		);
	}
	await actFrame();
	await waitForVisibleCodeTextAttempt({
		attempt: props.attempt + 1,
		expectedText: props.expectedText,
	});
}

export async function waitForDemandDispatchStateAttempt(props: {
	readonly attempt: number;
	readonly expectedState: string;
}): Promise<void> {
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	const actualState = shell?.getAttribute('data-last-demand-dispatch-status') ?? null;
	if (actualState === props.expectedState) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected demand dispatch state ${props.expectedState}; actual=${actualState ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForDemandDispatchStateAttempt({
		attempt: props.attempt + 1,
		expectedState: props.expectedState,
	});
}

export async function waitForFileViewerActiveStateAttempt(props: {
	readonly attempt: number;
	readonly expectedState: string;
}): Promise<void> {
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	const actualState = shell?.getAttribute('data-file-viewer-active') ?? null;
	if (actualState === props.expectedState) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected FileViewer active state ${props.expectedState}; actual=${actualState ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForFileViewerActiveStateAttempt({
		attempt: props.attempt + 1,
		expectedState: props.expectedState,
	});
}

export async function waitForDemandDispatchLoadedCountAttempt(props: {
	readonly attempt: number;
	readonly expectedLoadedCount: string;
}): Promise<void> {
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	const actualLoadedCount = shell?.getAttribute('data-last-demand-dispatch-loaded-count') ?? null;
	if (actualLoadedCount === props.expectedLoadedCount) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected demand dispatch loaded count ${props.expectedLoadedCount}; actual=${actualLoadedCount ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForDemandDispatchLoadedCountAttempt({
		attempt: props.attempt + 1,
		expectedLoadedCount: props.expectedLoadedCount,
	});
}

export async function waitForDemandDispatchFirstLaneAttempt(props: {
	readonly attempt: number;
	readonly expectedFirstLane: string;
}): Promise<void> {
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	const actualFirstLane = shell?.getAttribute('data-last-demand-dispatch-first-lane') ?? null;
	if (actualFirstLane === props.expectedFirstLane) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected demand dispatch first lane ${props.expectedFirstLane}; actual=${actualFirstLane ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForDemandDispatchFirstLaneAttempt({
		attempt: props.attempt + 1,
		expectedFirstLane: props.expectedFirstLane,
	});
}

export async function waitForDemandDispatchFirstFreshnessKeyContaining(
	expectedContentHandle: string,
): Promise<void> {
	await waitForDemandDispatchFirstFreshnessKeyContainingAttempt({
		attempt: 0,
		expectedContentHandle,
	});
}

export async function waitForRefreshDebugState(props: {
	readonly commitState: string;
	readonly result: string;
}): Promise<void> {
	await waitForRefreshDebugStateAttempt({ attempt: 0, ...props });
}

export async function waitForRefreshDebugStateAttempt(props: {
	readonly attempt: number;
	readonly commitState: string;
	readonly result: string;
}): Promise<void> {
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	const actualCommitState = shell?.getAttribute('data-last-refresh-commit-state') ?? null;
	const actualResult = shell?.getAttribute('data-last-refresh-result') ?? null;
	if (actualCommitState === props.commitState && actualResult === props.result) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected refresh debug state ${props.commitState}/${props.result}; actual=${actualCommitState ?? 'missing'}/${actualResult ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForRefreshDebugStateAttempt({
		...props,
		attempt: props.attempt + 1,
	});
}

export async function waitForDemandDispatchFirstFreshnessKeyContainingAttempt(props: {
	readonly attempt: number;
	readonly expectedContentHandle: string;
}): Promise<void> {
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	const actualFirstFreshnessKey =
		shell?.getAttribute('data-last-demand-dispatch-first-freshness-key') ?? null;
	if (actualFirstFreshnessKey?.includes(props.expectedContentHandle) === true) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected demand dispatch first freshness key to include ${
				props.expectedContentHandle
			}; actual=${actualFirstFreshnessKey ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForDemandDispatchFirstFreshnessKeyContainingAttempt({
		attempt: props.attempt + 1,
		expectedContentHandle: props.expectedContentHandle,
	});
}

export async function waitForOpenedContentCountAttempt(props: {
	readonly attempt: number;
	readonly expectedCount: number;
	readonly openedDescriptorIds: readonly string[];
}): Promise<void> {
	if (props.openedDescriptorIds.length === props.expectedCount) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected ${props.expectedCount} fetches; actual=${props.openedDescriptorIds.length}`,
		);
	}
	await actFrame();
	await waitForOpenedContentCountAttempt({
		attempt: props.attempt + 1,
		expectedCount: props.expectedCount,
		openedDescriptorIds: props.openedDescriptorIds,
	});
}

export async function waitForMetadataInterestUpdateCountAttempt(props: {
	readonly attempt: number;
	readonly expectedCount: number;
	readonly metadataInterestUpdates: readonly BrowserFileViewScope[];
}): Promise<void> {
	if (props.metadataInterestUpdates.length >= props.expectedCount) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected at least ${props.expectedCount} metadata interest updates; actual=${props.metadataInterestUpdates.length}`,
		);
	}
	await actFrame();
	await waitForMetadataInterestUpdateCountAttempt({
		attempt: props.attempt + 1,
		expectedCount: props.expectedCount,
		metadataInterestUpdates: props.metadataInterestUpdates,
	});
}

export async function waitForMetadataTreeRowCountAttempt(props: {
	readonly attempt: number;
	readonly expectedCount: number;
}): Promise<void> {
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	const actualCount = Number(shell?.getAttribute('data-worktree-metadata-tree-row-count') ?? '0');
	if (actualCount === props.expectedCount) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected metadata tree row count ${props.expectedCount}; actual=${actualCount}`,
		);
	}
	await actFrame();
	await waitForMetadataTreeRowCountAttempt({
		attempt: props.attempt + 1,
		expectedCount: props.expectedCount,
	});
}

export async function waitForSelectedDisplayPathAttempt(props: {
	readonly attempt: number;
	readonly expectedPath: string;
}): Promise<void> {
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	const actualPath = shell?.getAttribute('data-selected-display-path') ?? null;
	if (actualPath === props.expectedPath) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected selected display path ${props.expectedPath}; actual=${actualPath ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForSelectedDisplayPathAttempt({
		attempt: props.attempt + 1,
		expectedPath: props.expectedPath,
	});
}

export async function waitForTreeScrollHeightAtLeast(
	minimumScrollHeight: number,
	attempt = 0,
): Promise<void> {
	const scrollOwner = findBridgeViewerTreeScrollOwner();
	const actualScrollHeight = scrollOwner?.scrollHeight ?? 0;
	if (actualScrollHeight >= minimumScrollHeight) {
		return;
	}
	if (attempt >= 60) {
		throw new Error(
			`Expected tree scrollHeight >= ${minimumScrollHeight}; actual=${actualScrollHeight}`,
		);
	}
	await actFrame();
	await waitForTreeScrollHeightAtLeast(minimumScrollHeight, attempt + 1);
}

export async function waitForMetadataSubscriptionOpenCountAttempt(props: {
	readonly attempt: number;
	readonly expectedCount: number;
	readonly getLoadCount: () => number;
}): Promise<void> {
	const currentLoadCount = props.getLoadCount();
	if (currentLoadCount === props.expectedCount) {
		return;
	}
	if (props.attempt >= 60) {
		throw new Error(
			`Expected ${props.expectedCount} initial surface loads; actual=${currentLoadCount}`,
		);
	}
	await actFrame();
	await waitForMetadataSubscriptionOpenCountAttempt({
		attempt: props.attempt + 1,
		expectedCount: props.expectedCount,
		getLoadCount: props.getLoadCount,
	});
}

export function makeDeferredContent(): {
	readonly promise: Promise<string>;
	readonly resolve: (value: string) => void;
} {
	let resolveContent: ((value: string) => void) | null = null;
	const promise = new Promise<string>((resolve): void => {
		resolveContent = resolve;
	});
	return {
		promise,
		resolve: (value): void => {
			if (resolveContent === null) {
				throw new Error('Deferred content resolver was not initialized.');
			}
			resolveContent(value);
		},
	};
}

export function makeDeferredCurrentSource(): {
	readonly promise: Promise<BridgeProductCallResult<'file.source.current'>>;
	readonly resolve: (value: BridgeProductCallResult<'file.source.current'>) => void;
} {
	let resolveCurrentSource:
		| ((value: BridgeProductCallResult<'file.source.current'>) => void)
		| null = null;
	const promise = new Promise<BridgeProductCallResult<'file.source.current'>>((resolve): void => {
		resolveCurrentSource = resolve;
	});
	return {
		promise,
		resolve: (value): void => {
			if (resolveCurrentSource === null) {
				throw new Error('Deferred File source resolver was not initialized.');
			}
			resolveCurrentSource(value);
		},
	};
}

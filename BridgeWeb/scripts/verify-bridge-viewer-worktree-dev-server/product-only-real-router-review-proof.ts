import { errors, type Page } from 'playwright';

import {
	bridgeViewerProductOnlySelectors,
	type BridgeViewerReviewFreshRouteProof,
	type BridgeViewerReviewHydrationCoverage,
	type BridgeViewerReviewHydrationMilestone,
	type BridgeViewerReviewHydrationWindowFailure,
	type BridgeViewerReviewMountedHeaderOrderViolation,
	type BridgeViewerReviewFailureDemandSnapshot,
	type BridgeViewerReviewFailureSnapshot,
	type BridgeViewerReviewTreeSelectionProof,
} from './product-only-real-router-contract.ts';
import {
	type FreshReviewHydrationWindowSnapshot,
	previousFreshReviewTraversalScrollTop,
	waitForFreshReviewHydrationWindowSnapshot,
} from './product-only-real-router-review-hydration-window.ts';
import { waitForProductBrowserFrameSettlement } from './product-only-real-router-settlement.ts';

const productJourneyTimeoutMilliseconds = 120_000;
const productCompositionSettleTimeoutMilliseconds = 10_000;
const freshReviewSettledBottomTurnCount = 3;
const maximumFreshReviewHydrationWindowFailures = 32;
interface FreshReviewViewportState {
	readonly codeScroll: {
		readonly clientHeight: number;
		readonly scrollHeight: number;
		readonly scrollTop: number;
	};
	readonly codeViewManifestItemCount: number;
	readonly directoryDisclosure: readonly { readonly expanded: string; readonly path: string }[];
	readonly metadataItemCount: number;
	readonly mountedItemIds: readonly string[];
	readonly selectedItemId: string | null;
	readonly visibleItems: readonly {
		readonly contentState: string | null;
		readonly hostBottomOffset: number;
		readonly hostTopOffset: number;
		readonly itemId: string;
		readonly paintIdentity: string | null;
		readonly renderedLineCount: number;
	}[];
}

interface FreshReviewHydrationCoverageAccumulator {
	readonly missingHydratedVisibleWindows: BridgeViewerReviewHydrationWindowFailure[];
	readonly observedHydratedNonSelectedItemIdSet: Set<string>;
	readonly recordedWindowSignatures: Set<string>;
	settledWindowCount: number;
}

export async function proveFreshReviewRoute(props: {
	readonly expectedItemIds: readonly string[];
	readonly page: Page;
}): Promise<BridgeViewerReviewFreshRouteProof> {
	await props.page.waitForSelector(bridgeViewerProductOnlySelectors.reviewShell, {
		timeout: productJourneyTimeoutMilliseconds,
	});
	await waitForReviewProductTerminalState(props.page);
	await waitForFreshReviewManifestState({
		expectedItemCount: props.expectedItemIds.length,
		page: props.page,
	});
	await installFreshReviewIdentitySnapshot(props.page);

	let viewportState = await readFreshReviewViewportState(props.page);
	const selectedItemIdBeforeInitialHydration = viewportState.selectedItemId;
	const expectedItemIndexById = new Map(
		props.expectedItemIds.map((itemId, itemIndex): readonly [string, number] => [
			itemId,
			itemIndex,
		]),
	);
	const mountedHeaderOrderViolations: BridgeViewerReviewMountedHeaderOrderViolation[] = [];
	const mountedHeaderOrderViolationSignatures = new Set<string>();
	const observedHeaderItemIds: string[] = [];
	const observedHeaderItemIdSet = new Set<string>();
	const hydrationMilestones: BridgeViewerReviewHydrationMilestone[] = [];
	const hydrationCoverageAccumulator = createFreshReviewHydrationCoverageAccumulator();
	const traversalStepBudget = Math.max(512, props.expectedItemIds.length * 4);
	for (let stepIndex = 0; stepIndex < traversalStepBudget; stepIndex += 1) {
		if (
			!freshReviewInitialWindowRequiresTraversal({
				codeScroll: viewportState.codeScroll,
				selectedItemId: selectedItemIdBeforeInitialHydration,
				visibleItems: viewportState.visibleItems,
			})
		) {
			break;
		}
		await scrollFreshReviewCodeView({
			direction: 'forward',
			page: props.page,
			state: viewportState,
		});
		viewportState = await readFreshReviewViewportState(props.page);
	}
	const initialHydrationWindow = await captureFreshReviewHydrationWindow({
		excludedItemIds: [],
		page: props.page,
		selectedItemId: selectedItemIdBeforeInitialHydration,
	});
	viewportState = await readFreshReviewViewportState(props.page);
	const initialDirectoryDisclosure = viewportState.directoryDisclosure;
	const selectedItemIdAtStart = viewportState.selectedItemId;
	const initialVisibleItemIds = viewportState.visibleItems.map((item): string => item.itemId);
	recordMountedHeaderOrderViolation({
		expectedItemIndexById,
		mountedItemIds: initialVisibleItemIds,
		mountedHeaderOrderViolations,
		mountedHeaderOrderViolationSignatures,
	});
	appendFirstSeenItemIds({
		itemIds: viewportState.mountedItemIds,
		observedItemIds: observedHeaderItemIds,
		observedItemIdSet: observedHeaderItemIdSet,
	});
	recordFreshReviewHydrationCoverageWindow({
		accumulator: hydrationCoverageAccumulator,
		window: initialHydrationWindow,
	});
	hydrationMilestones.push({
		hydratedNonSelectedItemIds: initialHydrationWindow.hydratedNonSelectedItemIds,
		label: 'initial',
		visibleNonSelectedItemIds: initialHydrationWindow.visibleNonSelectedItemIds,
	});

	const pendingMilestones: Array<{
		readonly label: BridgeViewerReviewHydrationMilestone['label'];
		readonly minimumObservedItemCount: number;
	}> = [
		{ label: 'quarter', minimumObservedItemCount: Math.ceil(props.expectedItemIds.length * 0.25) },
		{ label: 'middle', minimumObservedItemCount: Math.ceil(props.expectedItemIds.length * 0.5) },
		{
			label: 'threeQuarter',
			minimumObservedItemCount: Math.ceil(props.expectedItemIds.length * 0.75),
		},
		{ label: 'final', minimumObservedItemCount: props.expectedItemIds.length },
	];
	let settledBottomTurnCount = 0;
	for (let stepIndex = 0; stepIndex < traversalStepBudget; stepIndex += 1) {
		const settledHydrationWindow = await captureFreshReviewHydrationWindow({
			excludedItemIds: [],
			page: props.page,
			selectedItemId: selectedItemIdAtStart,
		});
		recordFreshReviewHydrationCoverageWindow({
			accumulator: hydrationCoverageAccumulator,
			window: settledHydrationWindow,
		});
		viewportState = await readFreshReviewViewportState(props.page);
		recordMountedHeaderOrderViolation({
			expectedItemIndexById,
			mountedItemIds: viewportState.visibleItems.map((item): string => item.itemId),
			mountedHeaderOrderViolations,
			mountedHeaderOrderViolationSignatures,
		});
		appendFirstSeenItemIds({
			itemIds: viewportState.mountedItemIds,
			observedItemIds: observedHeaderItemIds,
			observedItemIdSet: observedHeaderItemIdSet,
		});
		while (
			pendingMilestones.length > 0 &&
			isFreshReviewTraversalMilestoneReady({
				milestone: pendingMilestones[0],
				observedItemCount: observedHeaderItemIds.length,
			})
		) {
			const milestone = pendingMilestones.shift();
			if (milestone === undefined) break;
			hydrationMilestones.push({
				hydratedNonSelectedItemIds: settledHydrationWindow.hydratedNonSelectedItemIds,
				label: milestone.label,
				visibleNonSelectedItemIds: settledHydrationWindow.visibleNonSelectedItemIds,
			});
		}
		const maximumScrollTop = Math.max(
			0,
			viewportState.codeScroll.scrollHeight - viewportState.codeScroll.clientHeight,
		);
		if (viewportState.codeScroll.scrollTop >= maximumScrollTop - 1) {
			settledBottomTurnCount += 1;
			if (settledBottomTurnCount >= freshReviewSettledBottomTurnCount) break;
		} else {
			settledBottomTurnCount = 0;
		}
		await scrollFreshReviewCodeView({
			direction: 'forward',
			page: props.page,
			state: viewportState,
		});
	}
	for (const milestone of pendingMilestones) {
		hydrationMilestones.push(
			await captureFreshReviewHydrationMilestone({
				excludedItemIds: milestone.label === 'final' ? initialVisibleItemIds : [],
				label: milestone.label,
				page: props.page,
				selectedItemId: selectedItemIdAtStart,
			}),
		);
	}
	viewportState = await readFreshReviewViewportState(props.page);
	recordMountedHeaderOrderViolation({
		expectedItemIndexById,
		mountedItemIds: viewportState.visibleItems.map((item): string => item.itemId),
		mountedHeaderOrderViolations,
		mountedHeaderOrderViolationSignatures,
	});
	appendFirstSeenItemIds({
		itemIds: viewportState.mountedItemIds,
		observedItemIds: observedHeaderItemIds,
		observedItemIdSet: observedHeaderItemIdSet,
	});
	const forwardCompletedScroll = viewportState.codeScroll;
	const backwardHydrationCoverageAccumulator = createFreshReviewHydrationCoverageAccumulator();
	const backwardMountedHeaderOrderViolations: BridgeViewerReviewMountedHeaderOrderViolation[] = [];
	const backwardMountedHeaderOrderViolationSignatures = new Set<string>();
	for (let stepIndex = 0; stepIndex < traversalStepBudget; stepIndex += 1) {
		const settledHydrationWindow = await captureFreshReviewHydrationWindow({
			excludedItemIds: [],
			page: props.page,
			selectedItemId: selectedItemIdAtStart,
		});
		recordFreshReviewHydrationCoverageWindow({
			accumulator: backwardHydrationCoverageAccumulator,
			window: settledHydrationWindow,
		});
		viewportState = await readFreshReviewViewportState(props.page);
		recordMountedHeaderOrderViolation({
			expectedItemIndexById,
			mountedItemIds: viewportState.visibleItems.map((item): string => item.itemId),
			mountedHeaderOrderViolations: backwardMountedHeaderOrderViolations,
			mountedHeaderOrderViolationSignatures: backwardMountedHeaderOrderViolationSignatures,
		});
		if (viewportState.codeScroll.scrollTop <= 1) break;
		await scrollFreshReviewCodeView({
			direction: 'backward',
			page: props.page,
			state: viewportState,
		});
	}
	viewportState = await readFreshReviewViewportState(props.page);
	const identity = await readFreshReviewIdentitySnapshot(props.page);
	return {
		...identity,
		backwardTraversal: {
			completedScrollTop: viewportState.codeScroll.scrollTop,
			hydrationCoverage: freshReviewHydrationCoverage({
				accumulator: backwardHydrationCoverageAccumulator,
				expectedItemIds: props.expectedItemIds,
				selectedItemId: selectedItemIdAtStart,
			}),
			mountedHeaderOrderViolations: backwardMountedHeaderOrderViolations,
			selectedItemIdAtCompletion: viewportState.selectedItemId,
		},
		codeViewManifestItemCount: viewportState.codeViewManifestItemCount,
		completedScroll: forwardCompletedScroll,
		expectedItemIds: props.expectedItemIds,
		finalDirectoryDisclosure: viewportState.directoryDisclosure,
		hydrationCoverage: freshReviewHydrationCoverage({
			accumulator: hydrationCoverageAccumulator,
			expectedItemIds: props.expectedItemIds,
			selectedItemId: selectedItemIdAtStart,
		}),
		hydrationMilestones,
		initialDirectoryDisclosure,
		metadataItemCount: viewportState.metadataItemCount,
		mountedHeaderOrderViolations,
		observedHeaderItemIds,
		selectedItemIdAtCompletion: viewportState.selectedItemId,
		selectedItemIdAtStart,
	};
}

export function freshReviewInitialWindowRequiresTraversal(props: {
	readonly codeScroll: FreshReviewViewportState['codeScroll'];
	readonly selectedItemId: string | null;
	readonly visibleItems: FreshReviewViewportState['visibleItems'];
}): boolean {
	if (props.selectedItemId === null || props.visibleItems.length === 0) return false;
	const maximumScrollTop = Math.max(
		0,
		props.codeScroll.scrollHeight - props.codeScroll.clientHeight,
	);
	return (
		props.codeScroll.scrollTop < maximumScrollTop - 1 &&
		props.visibleItems.every(
			(item): boolean =>
				item.itemId === props.selectedItemId &&
				(item.contentState === 'hydrated' || item.contentState === 'windowed') &&
				item.paintIdentity !== null,
		) &&
		props.visibleItems.some(
			(item): boolean => item.hostBottomOffset >= props.codeScroll.clientHeight,
		)
	);
}

export function isFreshReviewTraversalMilestoneReady(props: {
	readonly milestone:
		| {
				readonly label: BridgeViewerReviewHydrationMilestone['label'];
				readonly minimumObservedItemCount: number;
		  }
		| undefined;
	readonly observedItemCount: number;
}): boolean {
	return (
		props.milestone !== undefined &&
		props.milestone.label !== 'final' &&
		props.observedItemCount >= props.milestone.minimumObservedItemCount
	);
}

export async function proveReviewTreeSelection(props: {
	readonly expectedItemIds: readonly string[];
	readonly page: Page;
}): Promise<BridgeViewerReviewTreeSelectionProof> {
	const beforeSelection = await readFreshReviewViewportState(props.page);
	const targetPath = await props.page.evaluate((selectors): string => {
		const treeHost = document.querySelector(selectors.reviewTreeHost);
		const fileRows = [...(treeHost?.shadowRoot?.querySelectorAll('[data-item-path]') ?? [])].filter(
			(row): boolean => !row.hasAttribute('aria-expanded'),
		);
		const targetRow = fileRows.at(-1);
		if (!(targetRow instanceof HTMLElement)) {
			throw new Error('REVIEW_TREE_SELECTION_FILE_MISSING');
		}
		const path = targetRow.getAttribute('data-item-path');
		if (path === null) throw new Error('REVIEW_TREE_SELECTION_TARGET_PATH_MISSING');
		targetRow.click();
		return path;
	}, bridgeViewerProductOnlySelectors);
	await waitForProductCompositionState(async (): Promise<void> => {
		await props.page.waitForFunction(
			({ initialItemId, selectors }): boolean => {
				const codePanel = document.querySelector(selectors.reviewCodePanel);
				const targetItemId = codePanel?.getAttribute('data-selected-item-id');
				if (targetItemId === null || targetItemId === initialItemId) return false;
				const targetHost = queryAllInOpenShadowRoots(codePanel ?? document, 'diffs-container').find(
					(host): boolean => {
						const itemMarker = bridgeReviewHostElement(host, '[data-bridge-code-view-item-id]');
						return itemMarker?.getAttribute('data-bridge-code-view-item-id') === targetItemId;
					},
				);
				if (targetHost === undefined) return false;
				const contentState = bridgeReviewHostElement(
					targetHost,
					'[data-bridge-code-view-content-state]',
				)?.getAttribute('data-bridge-code-view-content-state');
				return contentState === 'hydrated' || contentState === 'windowed';

				function bridgeReviewHostElement(host: Element, selector: string): Element | null {
					return host.querySelector(selector) ?? host.shadowRoot?.querySelector(selector) ?? null;
				}

				function queryAllInOpenShadowRoots(
					root: Document | Element | ShadowRoot,
					selector: string,
				): Element[] {
					const matches = [...root.querySelectorAll(selector)];
					for (const descendant of root.querySelectorAll('*')) {
						if (descendant.shadowRoot === null) continue;
						matches.push(...queryAllInOpenShadowRoots(descendant.shadowRoot, selector));
					}
					return matches;
				}
			},
			{
				initialItemId: beforeSelection.selectedItemId,
				selectors: bridgeViewerProductOnlySelectors,
			},
			{ timeout: productCompositionSettleTimeoutMilliseconds },
		);
	});
	await waitForFreshReviewFrameSettlement({ page: props.page, stage: 'tree-selection' });
	const afterSelection = await readFreshReviewViewportState(props.page);
	const targetItemId = afterSelection.selectedItemId;
	if (targetItemId === null || !props.expectedItemIds.includes(targetItemId)) {
		throw new Error(`REVIEW_TREE_SELECTION_TARGET_OUTSIDE_MANIFEST: ${targetPath}`);
	}
	const targetVisibleItem = afterSelection.visibleItems.find(
		(item): boolean => item.itemId === targetItemId,
	);
	const expectedItemIndexById = new Map(
		props.expectedItemIds.map((itemId, itemIndex): readonly [string, number] => [
			itemId,
			itemIndex,
		]),
	);
	return {
		codeViewManifestItemCountAfterSelection: afterSelection.codeViewManifestItemCount,
		codeViewManifestItemCountBeforeSelection: beforeSelection.codeViewManifestItemCount,
		mountedHeaderOrderViolation: mountedHeaderOrderViolationForExpectedOrder({
			expectedItemIndexById,
			mountedItemIds: afterSelection.visibleItems.map((item): string => item.itemId),
		}),
		selectedContentState: targetVisibleItem?.contentState ?? null,
		selectedItemIdAtCompletion: afterSelection.selectedItemId,
		selectedItemIdAtStart: beforeSelection.selectedItemId,
		targetItemId,
		targetPath,
	};
}

export async function waitForFreshReviewManifestState(props: {
	readonly expectedItemCount: number;
	readonly page: Page;
}): Promise<void> {
	try {
		await props.page.waitForFunction(
			({ expectedItemCount, selectors }): boolean => {
				const shell = document.querySelector(selectors.reviewShell);
				const codePanel = document.querySelector(selectors.reviewCodePanel);
				const treeHost = document.querySelector(selectors.reviewTreeHost);
				return (
					Number(shell?.getAttribute('data-review-metadata-item-count') ?? '0') ===
						expectedItemCount &&
					Number(codePanel?.getAttribute('data-code-view-item-count') ?? '0') ===
						expectedItemCount &&
					treeHost?.shadowRoot?.querySelector('[data-item-path][aria-expanded]') !== null
				);
			},
			{ expectedItemCount: props.expectedItemCount, selectors: bridgeViewerProductOnlySelectors },
			{ timeout: productCompositionSettleTimeoutMilliseconds },
		);
	} catch (error: unknown) {
		if (error instanceof errors.TimeoutError) {
			throw new Error(`REVIEW_FRESH_ROUTE_MANIFEST_MISMATCH: expected=${props.expectedItemCount}`, {
				cause: error,
			});
		}
		throw error;
	}
}

export async function readFreshReviewFailureSnapshot(
	page: Page,
): Promise<BridgeViewerReviewFailureSnapshot> {
	const state = await readFreshReviewViewportState(page);
	const demand = await page.evaluate((selectors) => {
		const shell = document.querySelector(selectors.reviewShell);
		const rootDataset = document.documentElement.dataset;
		const numberAttribute = (attributeName: string): number | null => {
			const value = shell?.getAttribute(attributeName) ?? null;
			if (value === null) return null;
			const parsedValue = Number(value);
			return Number.isFinite(parsedValue) ? parsedValue : null;
		};
		const stringAttribute = (attributeName: string): string | null =>
			shell?.getAttribute(attributeName) ?? null;
		const datasetNumber = (key: string): number | null => {
			const value = rootDataset[key];
			if (value === undefined) return null;
			const parsedValue = Number(value);
			return Number.isFinite(parsedValue) ? parsedValue : null;
		};
		return {
			pierreWorkerPool: {
				activeTaskCount: datasetNumber('bridgePierreWorkerPoolActiveTasks'),
				busyWorkerCount: datasetNumber('bridgePierreWorkerPoolBusyWorkers'),
				managerState: rootDataset['bridgePierreWorkerPoolManagerState'] ?? null,
				queuedTaskCount: datasetNumber('bridgePierreWorkerPoolQueuedTasks'),
				totalWorkerCount: datasetNumber('bridgePierreWorkerPoolTotalWorkers'),
				workersFailed:
					rootDataset['bridgePierreWorkerPoolWorkersFailed'] === undefined
						? null
						: rootDataset['bridgePierreWorkerPoolWorkersFailed'] === 'true',
			},
			selected: {
				deferredCount: numberAttribute('data-review-selected-demand-deferred-count'),
				droppedIntentCount: numberAttribute('data-review-selected-demand-dropped-intent-count'),
				executorInFlightAfter: numberAttribute(
					'data-review-selected-demand-executor-in-flight-after',
				),
				executorQueuedLoadAfter: numberAttribute(
					'data-review-selected-demand-executor-queued-load-after',
				),
				failedCount: numberAttribute('data-review-selected-demand-failed-count'),
				foregroundIntentCount: numberAttribute(
					'data-review-selected-demand-foreground-intent-count',
				),
				interest: stringAttribute('data-review-selected-demand-interest'),
				loadedCount: numberAttribute('data-review-selected-demand-loaded-count'),
				resultReason: stringAttribute('data-review-selected-demand-result-reason'),
				resultStatus: stringAttribute('data-review-selected-demand-result-status'),
				staleDropCount: numberAttribute('data-review-selected-demand-stale-drop-count'),
				visibleIntentCount: numberAttribute('data-review-selected-demand-visible-intent-count'),
			},
			visible: {
				deferredCount: numberAttribute('data-review-visible-demand-deferred-count'),
				droppedIntentCount: numberAttribute('data-review-visible-demand-dropped-intent-count'),
				executorInFlightAfter: numberAttribute(
					'data-review-visible-demand-executor-in-flight-after',
				),
				executorQueuedLoadAfter: numberAttribute(
					'data-review-visible-demand-executor-queued-load-after',
				),
				failedCount: numberAttribute('data-review-visible-demand-failed-count'),
				foregroundIntentCount: numberAttribute(
					'data-review-visible-demand-foreground-intent-count',
				),
				interest: stringAttribute('data-review-visible-demand-interest'),
				loadedCount: numberAttribute('data-review-visible-demand-loaded-count'),
				resultReason: null,
				resultStatus: null,
				staleDropCount: numberAttribute('data-review-visible-demand-stale-drop-count'),
				visibleIntentCount: numberAttribute('data-review-visible-demand-visible-intent-count'),
			},
		};
	}, bridgeViewerProductOnlySelectors);
	const visibleContentStateCounts: Record<string, number> = {};
	for (const item of state.visibleItems) {
		const contentState = item.contentState ?? 'missing';
		visibleContentStateCounts[contentState] = (visibleContentStateCounts[contentState] ?? 0) + 1;
	}
	return {
		codeScroll: state.codeScroll,
		codeViewManifestItemCount: state.codeViewManifestItemCount,
		metadataItemCount: state.metadataItemCount,
		mountedItemCount: state.mountedItemIds.length,
		pierreWorkerPool: demand.pierreWorkerPool,
		selectedDemand: demand.selected satisfies BridgeViewerReviewFailureDemandSnapshot,
		selectedItemVisible: state.visibleItems.some(
			(item): boolean => item.itemId === state.selectedItemId,
		),
		visibleContentStateCounts,
		visibleDemand: demand.visible satisfies BridgeViewerReviewFailureDemandSnapshot,
		visibleItemCount: state.visibleItems.length,
	};
}

async function readFreshReviewViewportState(page: Page): Promise<FreshReviewViewportState> {
	return await page.evaluate((selectors): FreshReviewViewportState => {
		const shell = document.querySelector(selectors.reviewShell);
		const codePanel = document.querySelector(selectors.reviewCodePanel);
		const codeScrollOwner = document.querySelector(selectors.reviewCodeScrollOwner);
		const treeHost = document.querySelector(selectors.reviewTreeHost);
		if (!(codeScrollOwner instanceof HTMLElement)) {
			throw new Error('REVIEW_FRESH_ROUTE_CODE_SCROLL_OWNER_MISSING');
		}
		const reviewItemHosts = queryAllInOpenShadowRoots(codePanel ?? document, 'diffs-container');
		const codeScrollRect = codeScrollOwner.getBoundingClientRect();
		const mountedItemIds: string[] = [];
		const visibleItems: Array<{
			readonly contentState: string | null;
			readonly hostBottomOffset: number;
			readonly hostTopOffset: number;
			readonly itemId: string;
			readonly paintIdentity: string | null;
			readonly renderedLineCount: number;
		}> = [];
		for (const reviewItemHost of reviewItemHosts) {
			const itemMarker = bridgeReviewHostElement(reviewItemHost, '[data-bridge-code-view-item-id]');
			if (itemMarker === null) continue;
			const itemId = itemMarker.getAttribute('data-bridge-code-view-item-id');
			if (itemId === null) continue;
			mountedItemIds.push(itemId);
			const hostRect = reviewItemHost.getBoundingClientRect();
			if (hostRect.bottom <= codeScrollRect.top || hostRect.top >= codeScrollRect.bottom) continue;
			visibleItems.push({
				contentState:
					bridgeReviewHostElement(
						reviewItemHost,
						'[data-bridge-code-view-content-state]',
					)?.getAttribute('data-bridge-code-view-content-state') ?? null,
				hostBottomOffset: hostRect.bottom - codeScrollRect.top,
				hostTopOffset: hostRect.top - codeScrollRect.top,
				itemId,
				paintIdentity: paintedReviewIdentity(reviewItemHost),
				renderedLineCount: queryAllInOpenShadowRoots(reviewItemHost, '[data-line][data-line-index]')
					.length,
			});
		}
		const directoryDisclosure =
			treeHost?.shadowRoot === null || treeHost?.shadowRoot === undefined
				? []
				: [...treeHost.shadowRoot.querySelectorAll('[data-item-path][aria-expanded]')]
						.map((row) => ({
							expanded: row.getAttribute('aria-expanded') ?? '',
							path: row.getAttribute('data-item-path') ?? '',
						}))
						.toSorted((left, right): number => left.path.localeCompare(right.path));
		return {
			codeScroll: {
				clientHeight: codeScrollOwner.clientHeight,
				scrollHeight: codeScrollOwner.scrollHeight,
				scrollTop: codeScrollOwner.scrollTop,
			},
			codeViewManifestItemCount: Number(
				codePanel?.getAttribute('data-code-view-item-count') ?? '0',
			),
			directoryDisclosure,
			metadataItemCount: Number(shell?.getAttribute('data-review-metadata-item-count') ?? '0'),
			mountedItemIds,
			selectedItemId: codePanel?.getAttribute('data-selected-item-id') ?? null,
			visibleItems,
		};

		function bridgeReviewHostElement(host: Element, selector: string): Element | null {
			return host.querySelector(selector) ?? host.shadowRoot?.querySelector(selector) ?? null;
		}

		function paintedReviewIdentity(host: Element): string | null {
			const publicationId = host.getAttribute('data-bridge-painted-publication-id');
			const sourceCorrelations = host.getAttribute('data-bridge-painted-source-correlations');
			return publicationId === null || sourceCorrelations === null
				? null
				: JSON.stringify([publicationId, sourceCorrelations]);
		}

		function queryAllInOpenShadowRoots(
			root: Document | Element | ShadowRoot,
			selector: string,
		): Element[] {
			const matches = [...root.querySelectorAll(selector)];
			for (const descendant of root.querySelectorAll('*')) {
				if (descendant.shadowRoot === null) continue;
				matches.push(...queryAllInOpenShadowRoots(descendant.shadowRoot, selector));
			}
			return matches;
		}
	}, bridgeViewerProductOnlySelectors);
}

async function captureFreshReviewHydrationMilestone(props: {
	readonly excludedItemIds: readonly string[];
	readonly label: BridgeViewerReviewHydrationMilestone['label'];
	readonly page: Page;
	readonly selectedItemId: string | null;
}): Promise<BridgeViewerReviewHydrationMilestone> {
	const window = await captureFreshReviewHydrationWindow(props);
	return {
		hydratedNonSelectedItemIds: window.hydratedNonSelectedItemIds,
		label: props.label,
		visibleNonSelectedItemIds: window.visibleNonSelectedItemIds,
	};
}

async function captureFreshReviewHydrationWindow(props: {
	readonly excludedItemIds: readonly string[];
	readonly page: Page;
	readonly selectedItemId: string | null;
}): Promise<FreshReviewHydrationWindowSnapshot> {
	const readyWindow = await waitForFreshReviewHydrationWindowSnapshot({
		...props,
		timeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
	});
	if (readyWindow === null) {
		const state = await readFreshReviewViewportState(props.page);
		throw new Error(
			`REVIEW_FRESH_ROUTE_HYDRATION_WINDOW_TIMEOUT:${JSON.stringify({
				excludedItemIds: props.excludedItemIds,
				scrollTop: state.codeScroll.scrollTop,
				selectedItemId: props.selectedItemId,
				visibleItems: state.visibleItems,
			})}`,
		);
	}
	await waitForFreshReviewFrameSettlement({ page: props.page, stage: 'hydration-window' });
	const settledWindow = await waitForFreshReviewHydrationWindowSnapshot({
		...props,
		timeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
	});
	if (settledWindow === null) throw new Error('REVIEW_FRESH_ROUTE_POST_SETTLEMENT_TIMEOUT');
	return settledWindow;
}

function createFreshReviewHydrationCoverageAccumulator(): FreshReviewHydrationCoverageAccumulator {
	return {
		missingHydratedVisibleWindows: [],
		observedHydratedNonSelectedItemIdSet: new Set<string>(),
		recordedWindowSignatures: new Set<string>(),
		settledWindowCount: 0,
	};
}

function recordFreshReviewHydrationCoverageWindow(props: {
	readonly accumulator: FreshReviewHydrationCoverageAccumulator;
	readonly window: FreshReviewHydrationWindowSnapshot;
}): void {
	const signature = JSON.stringify([
		Math.round(props.window.scrollTop),
		props.window.visibleNonSelectedItemIds,
	]);
	if (props.accumulator.recordedWindowSignatures.has(signature)) return;
	props.accumulator.recordedWindowSignatures.add(signature);
	props.accumulator.settledWindowCount += 1;
	for (const itemId of props.window.hydratedNonSelectedItemIds) {
		props.accumulator.observedHydratedNonSelectedItemIdSet.add(itemId);
	}
	const hydrationMatchesVisibility =
		props.window.hydratedNonSelectedItemIds.length ===
			props.window.visibleNonSelectedItemIds.length &&
		props.window.visibleNonSelectedItemIds.every((itemId): boolean =>
			props.window.hydratedNonSelectedItemIds.includes(itemId),
		);
	if (
		hydrationMatchesVisibility ||
		props.accumulator.missingHydratedVisibleWindows.length >=
			maximumFreshReviewHydrationWindowFailures
	) {
		return;
	}
	props.accumulator.missingHydratedVisibleWindows.push({
		hydratedNonSelectedItemIds: props.window.hydratedNonSelectedItemIds,
		scrollTop: props.window.scrollTop,
		visibleContentStates: props.window.visibleContentStates,
		visibleNonSelectedItemIds: props.window.visibleNonSelectedItemIds,
	});
}

function freshReviewHydrationCoverage(props: {
	readonly accumulator: FreshReviewHydrationCoverageAccumulator;
	readonly expectedItemIds: readonly string[];
	readonly selectedItemId: string | null;
}): BridgeViewerReviewHydrationCoverage {
	return {
		missingHydratedVisibleWindows: props.accumulator.missingHydratedVisibleWindows,
		observedHydratedNonSelectedItemIds: props.expectedItemIds.filter(
			(itemId): boolean =>
				itemId !== props.selectedItemId &&
				props.accumulator.observedHydratedNonSelectedItemIdSet.has(itemId),
		),
		settledWindowCount: props.accumulator.settledWindowCount,
	};
}

function appendFirstSeenItemIds(props: {
	readonly itemIds: readonly string[];
	readonly observedItemIds: string[];
	readonly observedItemIdSet: Set<string>;
}): void {
	for (const itemId of props.itemIds) {
		if (props.observedItemIdSet.has(itemId)) continue;
		props.observedItemIdSet.add(itemId);
		props.observedItemIds.push(itemId);
	}
}

export function mountedHeaderOrderViolationForExpectedOrder(props: {
	readonly expectedItemIndexById: ReadonlyMap<string, number>;
	readonly mountedItemIds: readonly string[];
}): BridgeViewerReviewMountedHeaderOrderViolation | null {
	const expectedItemIndexes = props.mountedItemIds.map(
		(itemId): number | null => props.expectedItemIndexById.get(itemId) ?? null,
	);
	const preservesExpectedOrder = expectedItemIndexes.every(
		(expectedItemIndex, mountedItemIndex): boolean => {
			if (expectedItemIndex === null) return false;
			if (mountedItemIndex === 0) return true;
			const previousExpectedItemIndex = expectedItemIndexes[mountedItemIndex - 1];
			return (
				previousExpectedItemIndex !== undefined &&
				previousExpectedItemIndex !== null &&
				previousExpectedItemIndex < expectedItemIndex
			);
		},
	);
	return preservesExpectedOrder
		? null
		: { expectedItemIndexes, mountedItemIds: [...props.mountedItemIds] };
}

function recordMountedHeaderOrderViolation(props: {
	readonly expectedItemIndexById: ReadonlyMap<string, number>;
	readonly mountedItemIds: readonly string[];
	readonly mountedHeaderOrderViolations: BridgeViewerReviewMountedHeaderOrderViolation[];
	readonly mountedHeaderOrderViolationSignatures: Set<string>;
}): void {
	const violation = mountedHeaderOrderViolationForExpectedOrder(props);
	if (violation === null) return;
	const signature = violation.mountedItemIds.join('\u0000');
	if (props.mountedHeaderOrderViolationSignatures.has(signature)) return;
	props.mountedHeaderOrderViolationSignatures.add(signature);
	props.mountedHeaderOrderViolations.push(violation);
}

async function scrollFreshReviewCodeView(props: {
	readonly direction: 'backward' | 'forward';
	readonly page: Page;
	readonly state: FreshReviewViewportState;
}): Promise<void> {
	const nextScrollTop =
		props.direction === 'forward'
			? nextFreshReviewTraversalScrollTop({
					codeScroll: props.state.codeScroll,
				})
			: previousFreshReviewTraversalScrollTop({
					codeScroll: props.state.codeScroll,
				});
	await props.page.evaluate(
		({ nextScrollTop, selector }): void => {
			const codeScrollOwner = document.querySelector(selector);
			if (!(codeScrollOwner instanceof HTMLElement)) return;
			codeScrollOwner.dispatchEvent(
				new WheelEvent('wheel', {
					bubbles: true,
					deltaY: nextScrollTop - codeScrollOwner.scrollTop,
				}),
			);
			codeScrollOwner.scrollTop = Math.floor(nextScrollTop);
			codeScrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
		},
		{ nextScrollTop, selector: bridgeViewerProductOnlySelectors.reviewCodeScrollOwner },
	);
	try {
		await props.page.waitForFunction(
			({ expectedScrollTop, selector }): boolean => {
				const scrollOwner = document.querySelector(selector);
				return (
					scrollOwner instanceof HTMLElement &&
					Math.abs(scrollOwner.scrollTop - expectedScrollTop) <= 1
				);
			},
			{
				expectedScrollTop: nextScrollTop,
				selector: bridgeViewerProductOnlySelectors.reviewCodeScrollOwner,
			},
			{ timeout: productCompositionSettleTimeoutMilliseconds },
		);
	} catch (error: unknown) {
		if (!(error instanceof errors.TimeoutError)) throw error;
		throw new Error(`REVIEW_FRESH_ROUTE_SCROLL_SETTLEMENT_TIMEOUT:${nextScrollTop}`, {
			cause: error,
		});
	}
	await waitForFreshReviewFrameSettlement({
		page: props.page,
		stage: `${props.direction}-scroll:${nextScrollTop}`,
	});
}

async function waitForFreshReviewFrameSettlement(props: {
	readonly page: Page;
	readonly stage: string;
}): Promise<void> {
	await waitForProductBrowserFrameSettlement({
		page: props.page,
		stage: `review-fresh-route:${props.stage}`,
		timeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
	});
}

export function nextFreshReviewTraversalScrollTop(props: {
	readonly codeScroll: FreshReviewViewportState['codeScroll'];
}): number {
	const maximumScrollTop = Math.max(
		0,
		props.codeScroll.scrollHeight - props.codeScroll.clientHeight,
	);
	const viewportAdvance = Math.max(1, props.codeScroll.clientHeight * 0.8);
	// A hydrated host may extend several viewports and then shrink after render.
	// Keep overlap with every intervening geometry window during traversal.
	return Math.min(maximumScrollTop, Math.floor(props.codeScroll.scrollTop + viewportAdvance));
}

async function installFreshReviewIdentitySnapshot(page: Page): Promise<void> {
	await page.evaluate((selectors): void => {
		type ReviewFreshRouteProofWindow = Window & {
			bridgeViewerFreshReviewIdentity?: {
				readonly codeScrollOwner: Element | null;
				readonly treeHost: Element | null;
				readonly treeShadowRoot: ShadowRoot | null;
			};
		};
		const treeHost = document.querySelector(selectors.reviewTreeHost);
		(window as ReviewFreshRouteProofWindow).bridgeViewerFreshReviewIdentity = {
			codeScrollOwner: document.querySelector(selectors.reviewCodeScrollOwner),
			treeHost,
			treeShadowRoot: treeHost?.shadowRoot ?? null,
		};
	}, bridgeViewerProductOnlySelectors);
}

async function readFreshReviewIdentitySnapshot(page: Page): Promise<{
	readonly codeScrollOwnerIdentityStable: boolean;
	readonly treeHostIdentityStable: boolean;
	readonly treeShadowRootIdentityStable: boolean;
}> {
	return await page.evaluate((selectors) => {
		type ReviewFreshRouteProofWindow = Window & {
			bridgeViewerFreshReviewIdentity?: {
				readonly codeScrollOwner: Element | null;
				readonly treeHost: Element | null;
				readonly treeShadowRoot: ShadowRoot | null;
			};
		};
		const initialIdentity = (window as ReviewFreshRouteProofWindow).bridgeViewerFreshReviewIdentity;
		const currentTreeHost = document.querySelector(selectors.reviewTreeHost);
		return {
			codeScrollOwnerIdentityStable:
				initialIdentity?.codeScrollOwner ===
				document.querySelector(selectors.reviewCodeScrollOwner),
			treeHostIdentityStable: initialIdentity?.treeHost === currentTreeHost,
			treeShadowRootIdentityStable:
				initialIdentity?.treeShadowRoot === (currentTreeHost?.shadowRoot ?? null),
		};
	}, bridgeViewerProductOnlySelectors);
}

export async function waitForReviewProductTerminalState(page: Page): Promise<boolean> {
	return await waitForProductCompositionState(async (): Promise<void> => {
		await page.waitForFunction(
			(selectors): boolean => {
				const shell = document.querySelector(selectors.reviewShell);
				const codePanel = document.querySelector(selectors.reviewCodePanel);
				const state = shell?.getAttribute('data-selected-content-state');
				const selectedPath = shell?.getAttribute('data-selected-display-path');
				return (
					state === 'ready' &&
					selectedPath !== null &&
					codePanel?.getAttribute('data-selected-display-path') === selectedPath &&
					Number(codePanel?.getAttribute('data-selected-content-character-count') ?? '0') > 0 &&
					Number(codePanel?.getAttribute('data-selected-content-line-count') ?? '0') > 0 &&
					Number(codePanel?.getAttribute('data-selected-content-cache-key-count') ?? '0') > 0 &&
					isVisibleInPage(codePanel)
				);

				// oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer helpers.
				function isVisibleInPage(element: Element | null): boolean {
					if (!(element instanceof HTMLElement) || element.closest('[hidden]') !== null)
						return false;
					const style = getComputedStyle(element);
					return (
						style.display !== 'none' &&
						style.visibility !== 'hidden' &&
						element.getClientRects().length > 0
					);
				}
			},
			bridgeViewerProductOnlySelectors,
			{ timeout: productCompositionSettleTimeoutMilliseconds },
		);
	});
}

async function waitForProductCompositionState(wait: () => Promise<void>): Promise<boolean> {
	try {
		await wait();
		return true;
	} catch (error: unknown) {
		if (error instanceof errors.TimeoutError) return false;
		throw error;
	}
}

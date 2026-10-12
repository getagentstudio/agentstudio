import type { Page } from 'playwright';

import {
	bridgeViewerProductOnlySelectors,
	type BridgeViewerConsoleDiagnostic,
	type BridgeViewerFailedResponse,
	type BridgeViewerProductOnlyJourneyFailureCheckpoint,
	type BridgeViewerReviewFailureDemandSnapshot,
	type BridgeViewerReviewFailureSnapshot,
} from './product-only-real-router-contract.ts';
import { bridgeViewerJourneyFailureCode } from './product-only-real-router-failure.ts';
import type { BridgeViewerRealRouterObserver } from './product-only-real-router-page.ts';
import {
	bridgeViewerReviewPaintFailureEvidenceFromError,
	type BridgeViewerReviewPaintFailureSnapshot,
	type BridgeViewerReviewPaintLedgerEntry,
	type BridgeViewerReviewPaintFailureEvidence,
} from './product-only-real-router-review-paint.ts';
import { readFreshReviewViewportState } from './product-only-real-router-review-proof.ts';

export function reviewFailureSnapshotFromPaintFailureEvidence(
	evidence: BridgeViewerReviewPaintFailureEvidence,
): BridgeViewerReviewFailureSnapshot {
	const emptyDemand: BridgeViewerReviewFailureDemandSnapshot = {
		deferredCount: null,
		droppedIntentCount: null,
		executorInFlightAfter: null,
		executorQueuedLoadAfter: null,
		failedCount: null,
		foregroundIntentCount: null,
		interest: null,
		loadedCount: null,
		resultReason: null,
		resultStatus: null,
		staleDropCount: null,
		visibleIntentCount: null,
	};
	return {
		codeScroll: evidence.snapshot.codeScroll,
		codeViewManifestItemCount: 0,
		metadataItemCount: 0,
		mountedItemCount: 0,
		pierreWorkerPool: {
			activeTaskCount: null,
			busyWorkerCount: null,
			managerState: null,
			queuedTaskCount: null,
			totalWorkerCount: null,
			workersFailed: null,
		},
		selectedDemand: emptyDemand,
		selectedItemVisible: false,
		visibleContentStateCounts: {},
		visibleDemand: emptyDemand,
		paintLedger: evidence.paintLedger,
		paintFailure: evidence.snapshot,
		pendingPaintItemId: evidence.pendingPaintItemId,
		visibleItemCount: 0,
	};
}

export async function captureBridgeViewerProductOnlyJourneyFailure(props: {
	readonly browserDiagnostics: readonly BridgeViewerConsoleDiagnostic[];
	readonly documentGeneration: number;
	readonly error: unknown;
	readonly failedResponses: readonly BridgeViewerFailedResponse[];
	readonly page: Page;
	readonly routeObserver: Pick<
		BridgeViewerRealRouterObserver,
		'flushResponseParsers' | 'failureTransportSnapshot'
	>;
}): Promise<Omit<BridgeViewerProductOnlyJourneyFailureCheckpoint, 'browserCleanup' | 'workers'>> {
	try {
		await props.routeObserver.flushResponseParsers();
	} catch {}
	let review: BridgeViewerProductOnlyJourneyFailureCheckpoint['review'] = null;
	let captureStatus: 'captured' | 'unavailable' = 'unavailable';
	const paintFailure = bridgeViewerReviewPaintFailureEvidenceFromError(props.error);
	try {
		review = await readFreshReviewFailureSnapshot(
			props.page,
			paintFailure === null
				? {}
				: {
						paintFailure: paintFailure.snapshot,
						paintLedger: paintFailure.paintLedger,
						pendingPaintItemId: paintFailure.pendingPaintItemId,
					},
		);
		captureStatus = 'captured';
	} catch {
		if (paintFailure !== null) {
			review = reviewFailureSnapshotFromPaintFailureEvidence(paintFailure);
			captureStatus = 'captured';
		}
	}
	return {
		browserDiagnostics: props.browserDiagnostics,
		captureStatus,
		documentGeneration: props.documentGeneration,
		failureCode: bridgeViewerJourneyFailureCode(props.error),
		failedResponses: props.failedResponses,
		review,
		transport: props.routeObserver.failureTransportSnapshot(),
	};
}

export async function readFreshReviewFailureSnapshot(
	page: Page,
	props: {
		readonly paintFailure?: BridgeViewerReviewPaintFailureSnapshot;
		readonly paintLedger?: readonly BridgeViewerReviewPaintLedgerEntry[];
		readonly pendingPaintItemId?: string | null;
	} = {},
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
		paintLedger: props.paintLedger ?? [],
		paintFailure: props.paintFailure ?? null,
		pendingPaintItemId: props.pendingPaintItemId ?? null,
		visibleItemCount: state.visibleItems.length,
	};
}

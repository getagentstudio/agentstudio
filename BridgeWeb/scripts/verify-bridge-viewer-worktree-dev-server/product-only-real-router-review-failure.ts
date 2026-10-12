import type {
	BridgeViewerReviewFailureDemandSnapshot,
	BridgeViewerReviewFailureSnapshot,
} from './product-only-real-router-contract.ts';
import type { BridgeViewerReviewPaintFailureEvidence } from './product-only-real-router-review-paint.ts';

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

import type { BridgeWorkerRenderDispositionApplicationReceiptResult } from './bridge-comm-worker-render-disposition-application.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';
import type { BridgeWorkerRenderDispositionReceipt } from './bridge-worker-render-fulfillment.js';
import type { BridgeWorkerPaintReleasedReceipt } from './bridge-worker-render-fulfillment.js';

export function applyBridgeCommWorkerPostResponseOwnerEffects(props: {
	readonly advanceRenderFulfillmentLifecycle: (
		surface: BridgeWorkerRenderDispositionReceipt['surface'],
	) => void;
	readonly receiptResults: readonly BridgeWorkerRenderDispositionApplicationReceiptResult[];
	readonly currentFileOperationCorrelationId: () => string | null;
	readonly onFileOperationSettled: () => void;
	readonly publish: (message: BridgeWorkerServerToMainMessage) => void;
	readonly recordFileDisposition: (receipt: BridgeWorkerRenderDispositionReceipt) => void;
	readonly releaseReviewPosition: (receipt: BridgeWorkerRenderDispositionReceipt) => boolean;
	readonly readmitReviewPaintRelease: (receipt: BridgeWorkerPaintReleasedReceipt) => void;
	readonly settleFileDisposition: (receipt: BridgeWorkerRenderDispositionReceipt) => {
		readonly settled: boolean;
		readonly terminalPatch: BridgeWorkerServerToMainMessage | null;
	};
}): void {
	const eligibleReceipts: BridgeWorkerRenderDispositionReceipt[] = [];
	for (const result of props.receiptResults) {
		if (result.status === 'rejected') continue;
		const receipt = result.receipt;
		if (receipt.kind === 'paint.released') {
			if (receipt.surface === 'review' && result.status === 'accepted') {
				props.readmitReviewPaintRelease(receipt);
			}
			continue;
		}
		eligibleReceipts.push(receipt);
		if (receipt.surface === 'review') {
			props.releaseReviewPosition(receipt);
			continue;
		}
		if (receipt.operationCorrelationId === props.currentFileOperationCorrelationId()) {
			props.recordFileDisposition(receipt);
		}
		const settlement = props.settleFileDisposition(receipt);
		if (settlement.terminalPatch !== null) props.publish(settlement.terminalPatch);
		if (settlement.settled) props.onFileOperationSettled();
	}
	for (const surface of new Set(eligibleReceipts.map((receipt) => receipt.surface))) {
		props.advanceRenderFulfillmentLifecycle(surface);
	}
}

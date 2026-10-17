import { buildBridgeWorkerDegradedHealthEvent } from './bridge-comm-worker-command-support.js';
import { buildBridgeWorkerReadyHealthEvent } from './bridge-comm-worker-protocol.js';
import type { BridgeCommWorkerTelemetryRecorder } from './bridge-comm-worker-telemetry.js';
import { recordBridgeWorkerRenderDispositionBatchTelemetry } from './bridge-render-disposition-telemetry.js';
import type {
	BridgeWorkerRenderDispositionCommand,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import type { BridgeWorkerRenderFulfillmentRegistry } from './bridge-worker-render-fulfillment-registry.js';
import type { BridgeWorkerRenderAdmissionReceipt } from './bridge-worker-render-fulfillment.js';

export interface BridgeWorkerRenderDispositionApplicationReceiptResult {
	readonly receipt: BridgeWorkerRenderAdmissionReceipt;
	readonly reason?: string;
	readonly status: 'accepted' | 'duplicate' | 'rejected';
}

export interface BridgeWorkerRenderDispositionApplication {
	readonly messages: readonly BridgeWorkerServerToMainMessage[];
	readonly receiptResults: readonly BridgeWorkerRenderDispositionApplicationReceiptResult[];
}

export function applyBridgeWorkerRenderDispositionCommand(props: {
	readonly command: BridgeWorkerRenderDispositionCommand;
	readonly store: {
		readonly renderFulfillmentRegistry: Pick<
			BridgeWorkerRenderFulfillmentRegistry,
			'applyDisposition' | 'applyPaintRelease'
		>;
	};
	readonly telemetryClient?: BridgeCommWorkerTelemetryRecorder;
}): BridgeWorkerRenderDispositionApplication {
	const resultCounts = { accepted: 0, duplicate: 0, rejected: 0 };
	let unexpectedRejectionCount = 0;
	const receiptResults: BridgeWorkerRenderDispositionApplicationReceiptResult[] = [];
	for (const receipt of props.command.receipts) {
		const result =
			receipt.kind === 'paint.released'
				? props.store.renderFulfillmentRegistry.applyPaintRelease(receipt)
				: props.store.renderFulfillmentRegistry.applyDisposition(receipt);
		resultCounts[result.status] += 1;
		if (result.status === 'rejected' && receipt.kind === 'render.disposition') {
			unexpectedRejectionCount += 1;
		}
		receiptResults.push({
			receipt,
			...(result.status === 'rejected' ? { reason: result.reason } : {}),
			status: result.status,
		});
	}
	recordBridgeWorkerRenderDispositionBatchTelemetry({
		acceptedCount: resultCounts.accepted,
		duplicateCount: resultCounts.duplicate,
		receiptCount: props.command.receipts.length,
		rejectedCount: resultCounts.rejected,
		surface: props.command.receipts[0]?.surface ?? 'review',
		...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
	});
	const messages =
		unexpectedRejectionCount > 0
			? [
					buildBridgeWorkerDegradedHealthEvent({
						message: 'Bridge render disposition did not match a current worker publication.',
						requestId: props.command.requestId,
					}),
				]
			: [buildBridgeWorkerReadyHealthEvent(props.command.requestId)];
	return { messages, receiptResults };
}

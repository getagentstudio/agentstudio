import type { BridgeWorkerRuntimeRecoverySource } from '../../foundation/diagnostics/bridge-worker-replacement-reason.js';
import { bridgeRenderDispositionAdmissionPolicy } from '../demand/bridge-content-demand-policy.js';
import type { BridgeCommWorkerTelemetryRecorder } from './bridge-comm-worker-telemetry.js';
import {
	recordBridgeRenderDispositionAdmissionTelemetry,
	type BridgeRenderDispositionTerminalOutcome,
} from './bridge-render-disposition-telemetry.js';
import {
	bridgeWorkerRenderDispositionBatchMaximumReceiptCount,
	type BridgeWorkerRenderAdmissionReceipt,
} from './bridge-worker-render-fulfillment.js';
import type { BridgePaneSurface } from './bridge-worker-rpc-client.js';
import type { BridgeWorkerRpcLifecycleStore } from './bridge-worker-rpc-lifecycle-store.js';

export type BridgeMainRenderDispositionDeliveryState =
	| 'closing'
	| 'ordinary'
	| 'probe_available'
	| 'probe_in_flight'
	| 'stalled';

export interface BridgeMainRenderDispositionAdmissionSnapshot {
	readonly deliveryState: BridgeMainRenderDispositionDeliveryState;
	readonly duplicateReceiptCount: number;
	readonly inFlightReceiptCount: number;
	readonly oldestPendingAgeMilliseconds: number;
	readonly pendingReceiptCount: number;
	readonly pendingReceiptHighWaterMark: number;
	readonly retainedReceiptCount: number;
}

export interface BridgeMainRenderDispositionAdmission {
	readonly dispose: () => void;
	readonly enqueue: (receipt: BridgeWorkerRenderAdmissionReceipt) => void;
	readonly prepareForWorkerReplacement: () => void;
	readonly resumeAfterWorkerReplacement: () => void;
	readonly resumeAfterViewRecovery: () => void;
	readonly snapshot: () => BridgeMainRenderDispositionAdmissionSnapshot;
}

export interface CreateBridgeMainRenderDispositionAdmissionProps {
	readonly dispatchBatch: (receipts: readonly BridgeWorkerRenderAdmissionReceipt[]) => string;
	readonly lifecycleStore: BridgeWorkerRpcLifecycleStore;
	readonly maximumBatchSize?: number;
	readonly maximumPendingReceiptCount?: number;
	readonly now?: () => number;
	readonly onProbeExhausted?: () => void;
	readonly onPublicationSettled?: (settlement: {
		readonly publicationId: string;
		readonly outcome: 'settled-ok' | 'settled-failed';
	}) => void;
	readonly requestWorkerReplacement: (source: BridgeWorkerRuntimeRecoverySource) => void;
	readonly surface: BridgePaneSurface;
	readonly telemetryClient?: BridgeCommWorkerTelemetryRecorder;
}

interface PendingReceipt {
	readonly enqueuedAtMilliseconds: number;
	readonly key: string;
	readonly receipt: BridgeWorkerRenderAdmissionReceipt;
}

interface InFlightBatch {
	readonly dispatchedAtMilliseconds: number;
	readonly duplicateReceiptCountAtDispatch: number;
	readonly kind: 'ordinary' | 'probe';
	readonly receiptKeys: readonly string[];
	readonly receipts: readonly BridgeWorkerRenderAdmissionReceipt[];
	readonly receiptCount: number;
	readonly requestId: string;
}

export function createBridgeMainRenderDispositionAdmission(
	props: CreateBridgeMainRenderDispositionAdmissionProps,
): BridgeMainRenderDispositionAdmission {
	const maximumBatchSize =
		props.maximumBatchSize ?? bridgeWorkerRenderDispositionBatchMaximumReceiptCount;
	const maximumPendingReceiptCount =
		props.maximumPendingReceiptCount ??
		bridgeRenderDispositionAdmissionPolicy.maximumPendingReceiptCount;
	assertPositiveSafeInteger(maximumBatchSize, 'batch size');
	assertPositiveSafeInteger(maximumPendingReceiptCount, 'pending receipt count');
	if (maximumBatchSize > bridgeWorkerRenderDispositionBatchMaximumReceiptCount) {
		throw new Error('Bridge render disposition admission batch exceeds the wire maximum.');
	}
	if (maximumBatchSize > maximumPendingReceiptCount) {
		throw new Error('Bridge render disposition admission batch exceeds pending capacity.');
	}

	const admittedReceiptKeys = new Set<string>();
	const now = props.now ?? performance.now.bind(performance);
	const pendingReceipts: PendingReceipt[] = [];
	const pendingPublicationReceipts = new Map<
		string,
		{ count: number; hasPaintedReceipt: boolean; failed: boolean }
	>();
	let deliveryState: BridgeMainRenderDispositionDeliveryState = 'ordinary';
	let duplicateReceiptCount = 0;
	let producedReceiptCount = 0;
	let inFlightBatch: InFlightBatch | null = null;
	let isDisposed = false;
	let pendingReceiptHighWaterMark = 0;
	let unsubscribeLifecycle: (() => void) | null = null;

	const retainedReceiptCount = (): number =>
		pendingReceipts.length + (inFlightBatch?.receiptCount ?? 0);

	const clearReceipts = (): void => {
		pendingReceipts.length = 0;
		pendingPublicationReceipts.clear();
		admittedReceiptKeys.clear();
		inFlightBatch = null;
	};
	const oldestPendingAgeMilliseconds = (): number =>
		pendingReceipts.length === 0
			? 0
			: Math.max(0, now() - (pendingReceipts[0]?.enqueuedAtMilliseconds ?? now()));
	const recordAdmissionTelemetry = (recordProps: {
		readonly acknowledgementDurationMilliseconds?: number;
		readonly batchReceiptCount?: number;
		readonly duplicateCount?: number;
		readonly outcome?: BridgeRenderDispositionTerminalOutcome;
		readonly phase: Parameters<typeof recordBridgeRenderDispositionAdmissionTelemetry>[0]['phase'];
	}): void => {
		recordBridgeRenderDispositionAdmissionTelemetry({
			duplicateCount: recordProps.duplicateCount ?? 0,
			inFlightReceiptCount: inFlightBatch?.receiptCount ?? 0,
			oldestPendingAgeMilliseconds: oldestPendingAgeMilliseconds(),
			pendingHighWaterMark: pendingReceiptHighWaterMark,
			pendingReceiptCount: pendingReceipts.length,
			phase: recordProps.phase,
			producedCount: producedReceiptCount,
			retainedReceiptCount: retainedReceiptCount(),
			surface: props.surface,
			...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
			...(recordProps.acknowledgementDurationMilliseconds === undefined
				? {}
				: {
						acknowledgementDurationMilliseconds: recordProps.acknowledgementDurationMilliseconds,
					}),
			...(recordProps.batchReceiptCount === undefined
				? {}
				: { batchReceiptCount: recordProps.batchReceiptCount }),
			...(recordProps.outcome === undefined ? {} : { outcome: recordProps.outcome }),
		});
	};

	const dispatchNextBatch = (): void => {
		if (
			isDisposed ||
			deliveryState === 'closing' ||
			deliveryState === 'probe_in_flight' ||
			deliveryState === 'stalled' ||
			inFlightBatch !== null ||
			pendingReceipts.length === 0
		) {
			return;
		}
		const entries = pendingReceipts.splice(0, maximumBatchSize);
		const kind = deliveryState === 'probe_available' ? 'probe' : 'ordinary';
		if (kind === 'probe') deliveryState = 'probe_in_flight';
		let requestId: string;
		try {
			requestId = props.dispatchBatch(entries.map((entry) => entry.receipt));
		} catch (error: unknown) {
			pendingReceipts.unshift(...entries);
			if (kind === 'probe') deliveryState = 'probe_available';
			throw error;
		}
		const dispatchedAtMilliseconds = now();
		inFlightBatch = {
			dispatchedAtMilliseconds,
			duplicateReceiptCountAtDispatch: duplicateReceiptCount,
			kind,
			receiptCount: entries.length,
			receiptKeys: entries.map((entry) => entry.key),
			receipts: entries.map((entry) => entry.receipt),
			requestId,
		};
		recordAdmissionTelemetry({
			batchReceiptCount: entries.length,
			phase: 'render_disposition_batch_dispatched',
		});
	};

	const observeLifecycle = (): void => {
		if (isDisposed || deliveryState === 'closing' || inFlightBatch === null) return;
		const request = props.lifecycleStore.getSnapshot().requestsById[inFlightBatch.requestId];
		if (request === undefined || request.surface !== props.surface || request.state === 'pending') {
			return;
		}
		const settledBatch = inFlightBatch;
		inFlightBatch = null;
		for (const key of settledBatch.receiptKeys) admittedReceiptKeys.delete(key);
		const workerProgressed = request.state === 'acked' || request.state === 'failed';
		let probeExhausted = false;
		const outcome: BridgeRenderDispositionTerminalOutcome =
			request.state === 'acked' ? 'acked' : request.state === 'failed' ? 'degraded' : 'timed_out';
		for (const receipt of settledBatch.receipts) {
			const publication = pendingPublicationReceipts.get(receipt.publicationId);
			if (publication === undefined) continue;
			publication.count -= 1;
			if (request.state !== 'acked') publication.failed = true;
			if (publication.count !== 0) continue;
			pendingPublicationReceipts.delete(receipt.publicationId);
			if (publication.hasPaintedReceipt) {
				props.onPublicationSettled?.({
					publicationId: receipt.publicationId,
					outcome: publication.failed ? 'settled-failed' : 'settled-ok',
				});
			}
		}
		if (settledBatch.kind === 'probe') {
			deliveryState = workerProgressed ? 'ordinary' : 'stalled';
			probeExhausted = !workerProgressed;
		} else if (request.state === 'timed_out' || request.state === 'superseded') {
			deliveryState = 'probe_available';
		} else {
			deliveryState = 'ordinary';
		}
		recordAdmissionTelemetry({
			acknowledgementDurationMilliseconds: Math.max(
				0,
				now() - settledBatch.dispatchedAtMilliseconds,
			),
			batchReceiptCount: settledBatch.receiptCount,
			duplicateCount: Math.max(
				0,
				duplicateReceiptCount - settledBatch.duplicateReceiptCountAtDispatch,
			),
			outcome,
			phase: 'render_disposition_batch_terminal',
		});
		if (probeExhausted) {
			props.onProbeExhausted?.();
			return;
		}
		dispatchNextBatch();
	};

	const subscribeLifecycle = (): void => {
		unsubscribeLifecycle?.();
		unsubscribeLifecycle = props.lifecycleStore.subscribe(observeLifecycle);
	};

	subscribeLifecycle();

	const prepareForWorkerReplacement = (): void => {
		if (isDisposed || deliveryState === 'closing') return;
		deliveryState = 'closing';
		unsubscribeLifecycle?.();
		unsubscribeLifecycle = null;
		recordAdmissionTelemetry({
			outcome: 'cleared',
			phase: 'render_disposition_admission_cleared',
		});
		clearReceipts();
	};
	const resumeAdmission = (): void => {
		if (isDisposed) return;
		clearReceipts();
		duplicateReceiptCount = 0;
		pendingReceiptHighWaterMark = 0;
		producedReceiptCount = 0;
		deliveryState = 'ordinary';
		subscribeLifecycle();
	};

	return {
		dispose: (): void => {
			if (isDisposed) return;
			prepareForWorkerReplacement();
			isDisposed = true;
		},
		enqueue: (receipt): void => {
			if (isDisposed || deliveryState === 'closing') return;
			if (receipt.surface === 'file' ? props.surface !== 'fileView' : props.surface !== 'review') {
				throw new Error('Bridge render disposition receipt targets another surface.');
			}
			const key = bridgeRenderDispositionAdmissionKey(receipt);
			if (admittedReceiptKeys.has(key)) {
				duplicateReceiptCount += 1;
				return;
			}
			producedReceiptCount += 1;
			admittedReceiptKeys.add(key);
			const publication = pendingPublicationReceipts.get(receipt.publicationId) ?? {
				count: 0,
				failed: false,
				hasPaintedReceipt: false,
			};
			publication.count += 1;
			publication.hasPaintedReceipt ||=
				receipt.kind === 'render.disposition' && receipt.disposition === 'painted';
			pendingPublicationReceipts.set(receipt.publicationId, publication);
			pendingReceipts.push({ enqueuedAtMilliseconds: now(), key, receipt });
			pendingReceiptHighWaterMark = Math.max(pendingReceiptHighWaterMark, retainedReceiptCount());
			if (retainedReceiptCount() >= maximumPendingReceiptCount) {
				deliveryState = 'closing';
				unsubscribeLifecycle?.();
				unsubscribeLifecycle = null;
				recordAdmissionTelemetry({
					phase: 'render_disposition_admission_overloaded',
				});
				props.requestWorkerReplacement('renderDispositionOverload');
				return;
			}
			dispatchNextBatch();
		},
		prepareForWorkerReplacement,
		resumeAfterWorkerReplacement: resumeAdmission,
		resumeAfterViewRecovery: resumeAdmission,
		snapshot: (): BridgeMainRenderDispositionAdmissionSnapshot => ({
			deliveryState,
			duplicateReceiptCount,
			inFlightReceiptCount: inFlightBatch?.receiptCount ?? 0,
			oldestPendingAgeMilliseconds: oldestPendingAgeMilliseconds(),
			pendingReceiptCount: pendingReceipts.length,
			pendingReceiptHighWaterMark,
			retainedReceiptCount: retainedReceiptCount(),
		}),
	};
}

function bridgeRenderDispositionAdmissionKey(receipt: BridgeWorkerRenderAdmissionReceipt): string {
	return JSON.stringify([
		receipt.paneSessionId,
		receipt.workerInstanceId,
		receipt.surface,
		receipt.itemId,
		receipt.publicationId,
		receipt.publicationSequence,
		receipt.submissionId,
		receipt.attemptId,
		receipt.workerDerivationEpoch,
		receipt.windowKey,
		receipt.operationCorrelationId,
		receipt.kind === 'paint.released' ? receipt.kind : receipt.disposition,
		'reason' in receipt ? receipt.reason : null,
	]);
}

function assertPositiveSafeInteger(value: number, name: string): void {
	if (!Number.isSafeInteger(value) || value <= 0) {
		throw new Error(`Bridge render disposition admission ${name} must be positive.`);
	}
}

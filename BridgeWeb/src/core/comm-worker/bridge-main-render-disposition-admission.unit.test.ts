import { describe, expect, test, vi } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import {
	createBridgeMainRenderDispositionAdmission,
	type BridgeMainRenderDispositionAdmission,
} from './bridge-main-render-disposition-admission.js';
import type {
	BridgeWorkerRenderAdmissionReceipt,
	BridgeWorkerRenderDispositionReceipt,
} from './bridge-worker-render-fulfillment.js';
import { makeBridgeWorkerRenderReceiptIdentity } from './bridge-worker-render-fulfillment.test-support.js';
import { createBridgeWorkerRpcLifecycleStore } from './bridge-worker-rpc-lifecycle-store.js';

describe('Bridge main render disposition admission', () => {
	test('delivers paint release after painted disposition through the same acknowledged batch path', () => {
		const harness = createAdmissionHarness({ maximumBatchSize: 2 });
		const painted = { ...makeQueuedReceipt(1), disposition: 'painted' as const };
		const release = {
			...makeBridgeWorkerRenderReceiptIdentity({
				itemId: 'item-1',
				publicationSequence: 1,
				surface: 'review',
				workerDerivationEpoch: 1,
			}),
			kind: 'paint.released' as const,
			receivedAtMilliseconds: 2,
		};
		harness.admission.enqueue(painted);
		harness.admission.enqueue(release);
		expect(harness.dispatched).toHaveLength(1);
		harness.ack('batch-1');
		expect(
			harness.dispatched.map(({ receipts }) => receipts.map((receipt) => receipt.kind)),
		).toEqual([['render.disposition'], ['paint.released']]);
		harness.ack('batch-2');
		expect(harness.admission.snapshot().pendingReceiptCount).toBe(0);
	});
	test('holds the next batch until the in-flight request is acknowledged', () => {
		const harness = createAdmissionHarness({ maximumBatchSize: 2 });
		harness.admission.enqueue(makeQueuedReceipt(1));
		harness.admission.enqueue(makeQueuedReceipt(2));
		harness.admission.enqueue(makeQueuedReceipt(3));

		expect(
			harness.dispatched.map(({ receipts }) => receipts.map((receipt) => receipt.itemId)),
		).toEqual([['item-1']]);
		harness.ack('batch-1');
		expect(
			harness.dispatched.map(({ receipts }) => receipts.map((receipt) => receipt.itemId)),
		).toEqual([['item-1'], ['item-2', 'item-3']]);
	});

	test('fails only the view after the recovery probe times out without replacing the worker', () => {
		// Arrange
		const requestWorkerReplacement = vi.fn();
		const onProbeExhausted = vi.fn();
		const harness = createAdmissionHarness({
			maximumBatchSize: 1,
			onProbeExhausted,
			requestWorkerReplacement,
		});
		for (let index = 1; index <= 4; index += 1) harness.admission.enqueue(makeQueuedReceipt(index));

		// Act
		harness.timeout('batch-1');
		expect(harness.dispatched).toHaveLength(2);
		harness.timeout('batch-2');
		harness.timeout('batch-2');

		// Assert
		expect(harness.dispatched).toHaveLength(2);
		expect(harness.admission.snapshot().deliveryState).toBe('stalled');
		expect(onProbeExhausted).toHaveBeenCalledOnce();
		expect(requestWorkerReplacement).not.toHaveBeenCalled();
		harness.admission.resumeAfterViewRecovery();
		harness.admission.enqueue(makeQueuedReceipt(5));
		expect(harness.dispatched).toHaveLength(3);
	});

	test('clears unknown debt when the FIFO recovery probe reaches a worker terminal', () => {
		const harness = createAdmissionHarness({ maximumBatchSize: 1 });
		for (let index = 1; index <= 3; index += 1) harness.admission.enqueue(makeQueuedReceipt(index));

		harness.timeout('batch-1');
		harness.fail('batch-2');

		expect(harness.admission.snapshot().deliveryState).toBe('ordinary');
		expect(harness.dispatched).toHaveLength(3);
	});

	test('enters closing and requests replacement once at the pending ceiling', () => {
		const requestWorkerReplacement = vi.fn();
		const harness = createAdmissionHarness({
			maximumBatchSize: 1,
			maximumPendingReceiptCount: 3,
			requestWorkerReplacement,
		});
		harness.admission.enqueue(makeQueuedReceipt(1));
		harness.admission.enqueue(makeQueuedReceipt(2));
		harness.admission.enqueue(makeQueuedReceipt(3));

		expect(harness.admission.snapshot()).toMatchObject({
			deliveryState: 'closing',
			retainedReceiptCount: 3,
		});
		expect(requestWorkerReplacement).toHaveBeenCalledOnce();
		expect(requestWorkerReplacement).toHaveBeenCalledWith('renderDispositionOverload');
		harness.admission.enqueue(makeQueuedReceipt(4));
		expect(requestWorkerReplacement).toHaveBeenCalledOnce();
	});

	test('closing before synthetic terminalization cannot release another batch', () => {
		const harness = createAdmissionHarness({ maximumBatchSize: 1 });
		harness.admission.enqueue(makeQueuedReceipt(1));
		harness.admission.enqueue(makeQueuedReceipt(2));

		harness.admission.prepareForWorkerReplacement();
		harness.fail('batch-1');

		expect(harness.dispatched).toHaveLength(1);
		expect(harness.admission.snapshot()).toMatchObject({
			deliveryState: 'closing',
			retainedReceiptCount: 0,
		});
	});

	test('suppresses an exact duplicate disposition while it remains admitted', () => {
		const harness = createAdmissionHarness({ maximumBatchSize: 2 });
		const receipt = makeQueuedReceipt(1);
		harness.admission.enqueue(receipt);
		harness.admission.enqueue(receipt);

		expect(harness.dispatched).toHaveLength(1);
		expect(harness.admission.snapshot()).toMatchObject({ duplicateReceiptCount: 1 });
	});

	test('restores a synchronously failed dispatch without losing the receipt', () => {
		const lifecycleStore = createBridgeWorkerRpcLifecycleStore();
		const admission = createBridgeMainRenderDispositionAdmission({
			dispatchBatch: (): string => {
				throw new Error('dispatch failed');
			},
			lifecycleStore,
			requestWorkerReplacement: (): void => {},
			surface: 'review',
		});

		expect((): void => admission.enqueue(makeQueuedReceipt(1))).toThrow('dispatch failed');
		expect(admission.snapshot()).toMatchObject({
			inFlightReceiptCount: 0,
			pendingReceiptCount: 1,
			retainedReceiptCount: 1,
		});
	});

	test('keeps distinct complete receipt identities even when the item and attempt match', () => {
		const harness = createAdmissionHarness({ maximumBatchSize: 2 });
		const receipt = makeQueuedReceipt(1);
		harness.admission.enqueue(receipt);
		harness.admission.enqueue({ ...receipt, windowKey: 'another-window' });

		expect(harness.admission.snapshot().duplicateReceiptCount).toBe(0);
		harness.ack('batch-1');
		expect(harness.dispatched.flatMap(({ receipts }) => receipts)).toHaveLength(2);
	});

	test('records bounded batch admission and terminal telemetry without receipt identity', () => {
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const harness = createAdmissionHarness({
			maximumBatchSize: 2,
			telemetrySamples,
		});
		harness.admission.enqueue(makeQueuedReceipt(1));
		harness.admission.enqueue(makeQueuedReceipt(1));
		harness.ack('batch-1');

		expect(telemetrySamples.map((sample) => sample.stringAttributes)).toEqual([
			expect.objectContaining({
				'agentstudio.bridge.phase': 'render_disposition_batch_dispatched',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.viewer': 'review',
			}),
			expect.objectContaining({
				'agentstudio.bridge.phase': 'render_disposition_batch_terminal',
				'agentstudio.bridge.render_disposition.outcome': 'acked',
			}),
		]);
		expect(telemetrySamples[0]?.numericAttributes).toMatchObject({
			'agentstudio.bridge.render_disposition.batch_receipt_count': 1,
			'agentstudio.bridge.render_disposition.in_flight_count': 1,
			'agentstudio.bridge.render_disposition.pending_count': 0,
			'agentstudio.bridge.render_disposition.pending_high_water_mark': 1,
			'agentstudio.bridge.render_disposition.retained_count': 1,
		});
		expect(telemetrySamples[1]).toMatchObject({
			durationMilliseconds: expect.any(Number),
			numericAttributes: expect.objectContaining({
				'agentstudio.bridge.render_disposition.duplicate_count': 1,
				'agentstudio.bridge.render_disposition.in_flight_count': 0,
				'agentstudio.bridge.render_disposition.retained_count': 0,
			}),
		});
		expect(JSON.stringify(telemetrySamples)).not.toContain('item-1');
		expect(JSON.stringify(telemetrySamples)).not.toContain('batch-1');
	});

	test('settles painted publication evidence only after all its admitted receipts reach terminals', () => {
		const settlements: Array<{ publicationId: string; outcome: string }> = [];
		const harness = createAdmissionHarness({
			maximumBatchSize: 1,
			onPublicationSettled: (settlement): void => {
				settlements.push(settlement);
			},
		});
		const queued = { ...makeQueuedReceipt(1), publicationId: 'publication-a' };
		const painted = { ...makePaintedReceipt(1), publicationId: 'publication-a' };
		harness.admission.enqueue(queued);
		harness.admission.enqueue(painted);

		expect(settlements).toEqual([]);
		harness.ack('batch-1');
		expect(settlements).toEqual([]);
		harness.ack('batch-2');
		expect(settlements).toEqual([{ publicationId: 'publication-a', outcome: 'settled-ok' }]);
	});

	test('reports failed painted publication settlement and keeps later publications separate', () => {
		const settlements: Array<{ publicationId: string; outcome: string }> = [];
		const harness = createAdmissionHarness({
			maximumBatchSize: 1,
			onPublicationSettled: (settlement): void => {
				settlements.push(settlement);
			},
		});
		harness.admission.enqueue({ ...makePaintedReceipt(1), publicationId: 'publication-a' });
		harness.admission.enqueue({ ...makePaintedReceipt(2), publicationId: 'publication-b' });

		harness.fail('batch-1');
		expect(settlements).toEqual([{ publicationId: 'publication-a', outcome: 'settled-failed' }]);
		expect(harness.dispatched).toHaveLength(2);
		harness.ack('batch-2');
		expect(settlements).toEqual([
			{ publicationId: 'publication-a', outcome: 'settled-failed' },
			{ publicationId: 'publication-b', outcome: 'settled-ok' },
		]);
	});
});

function createAdmissionHarness(options: {
	readonly maximumBatchSize?: number;
	readonly maximumPendingReceiptCount?: number;
	readonly onProbeExhausted?: () => void;
	readonly onPublicationSettled?: (settlement: {
		readonly publicationId: string;
		readonly outcome: 'settled-ok' | 'settled-failed';
	}) => void;
	readonly requestWorkerReplacement?: () => void;
	readonly telemetrySamples?: BridgeTelemetrySample[];
}): {
	readonly ack: (requestId: string) => void;
	readonly admission: BridgeMainRenderDispositionAdmission;
	readonly dispatched: Array<{
		readonly receipts: readonly BridgeWorkerRenderAdmissionReceipt[];
		readonly requestId: string;
	}>;
	readonly fail: (requestId: string) => void;
	readonly timeout: (requestId: string) => void;
} {
	const lifecycleStore = createBridgeWorkerRpcLifecycleStore();
	const dispatched: Array<{
		readonly receipts: readonly BridgeWorkerRenderAdmissionReceipt[];
		readonly requestId: string;
	}> = [];
	let nextBatchSequence = 0;
	const admission = createBridgeMainRenderDispositionAdmission({
		dispatchBatch: (receipts): string => {
			nextBatchSequence += 1;
			const requestId = `batch-${nextBatchSequence}`;
			lifecycleStore.startRequest({ command: 'renderDisposition', requestId, surface: 'review' });
			dispatched.push({ receipts, requestId });
			return requestId;
		},
		lifecycleStore,
		...(options.maximumBatchSize === undefined
			? {}
			: { maximumBatchSize: options.maximumBatchSize }),
		...(options.maximumPendingReceiptCount === undefined
			? {}
			: { maximumPendingReceiptCount: options.maximumPendingReceiptCount }),
		requestWorkerReplacement: options.requestWorkerReplacement ?? ((): void => {}),
		onProbeExhausted: options.onProbeExhausted ?? ((): void => {}),
		...(options.onPublicationSettled === undefined
			? {}
			: { onPublicationSettled: options.onPublicationSettled }),
		surface: 'review',
		...(options.telemetrySamples === undefined
			? {}
			: {
					telemetryClient: {
						record: (sample: BridgeTelemetrySample): void => {
							options.telemetrySamples?.push(sample);
						},
					},
				}),
	});
	return {
		ack: (requestId: string): void => {
			lifecycleStore.ackRequest({ acknowledgedAtSequence: 0, requestId });
		},
		admission,
		dispatched,
		fail: (requestId: string): void => {
			lifecycleStore.failRequest({ reason: 'worker_degraded', requestId });
		},
		timeout: (requestId: string): void => {
			lifecycleStore.timeoutRequest({ requestId });
		},
	};
}

function makeQueuedReceipt(index: number): BridgeWorkerRenderDispositionReceipt {
	return {
		...makeBridgeWorkerRenderReceiptIdentity({
			itemId: `item-${index}`,
			publicationSequence: index,
			surface: 'review',
			workerDerivationEpoch: 1,
		}),
		disposition: 'queued',
		kind: 'render.disposition',
		receivedAtMilliseconds: index,
	};
}

function makePaintedReceipt(index: number): BridgeWorkerRenderDispositionReceipt {
	return { ...makeQueuedReceipt(index), disposition: 'painted' };
}

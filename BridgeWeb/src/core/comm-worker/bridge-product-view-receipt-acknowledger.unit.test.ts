import { describe, expect, test } from 'vitest';

import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { installBridgeProductBatchDelivery } from './bridge-product-batch-delivery.js';
import { BridgeProductBatchFrameRouter } from './bridge-product-batch-frame-router.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import type { BridgeProductSessionAuthority } from './bridge-product-session-authority.js';
import { bridgeProductSessionBootstrapSchema } from './bridge-product-session-contracts.js';
import { bridgeProductViewAcknowledgementRequestSchema } from './bridge-product-view-control-wire-contracts.js';
import { BridgeProductViewReceiptAcknowledger } from './bridge-product-view-receipt-acknowledger.js';

const clock: BridgeProductDeadlineClock = { schedule: () => (): void => {} };
const bootstrap = bridgeProductSessionBootstrapSchema.parse(sessionCorpus.bootstrap);
const authority: BridgeProductSessionAuthority = {
	bootstrap,
	capabilityHeader: 'test-capability',
	open: Promise.resolve(),
};

const receipt = {
	domain: 'default',
	handle: 'view-handle-1',
	incarnation: 'view-incarnation-1',
	receivedThroughDeliverySequence: 1,
	subscriptionId: 'view-subscription-1',
} as const;

describe('Bridge product view receipt acknowledgement owner', () => {
	test('the W4 receipt sink returns credit before installation', async () => {
		const router = new BridgeProductBatchFrameRouter({
			deadlineClock: clock,
			progressDeadlineMilliseconds: bootstrap.policy.viewBatchProgressDeadlineMilliseconds,
		});
		const acknowledged: number[] = [];
		const installed: number[] = [];
		const acknowledger = installBridgeProductBatchDelivery({
			authority,
			deadlineClock: clock,
			executeProductRequest: async (_, requestInit): Promise<Response> => {
				if (!(requestInit.body instanceof Uint8Array)) throw new Error('Expected ACK bytes.');
				const request = bridgeProductViewAcknowledgementRequestSchema.parse(
					JSON.parse(new TextDecoder().decode(requestInit.body)),
				);
				acknowledged.push(request.receivedThroughDeliverySequence);
				return new Response(JSON.stringify({ ...request, kind: 'subscription.acknowledged' }), {
					status: 200,
				});
			},
			router,
			sinks: {
				install: (installation): void => {
					installed.push(installation.records.length);
				},
				receipt: (): void => {},
				resnapshot: (): void => {},
				resnapshotLatest: (): void => {},
			},
		});
		const identity = {
			batchId: 'batch-file-1',
			domain: 'default',
			handle: 'view-handle-1',
			incarnation: 'view-incarnation-1',
			metadataStreamId: 'metadata-stream-1',
			paneSessionId: bootstrap.paneSessionId,
			scopeRevision: 1,
			subscriptionId: 'view-subscription-1',
			subscriptionKind: 'file.metadata',
			wireVersion: bootstrap.wireVersion,
			workerInstanceId: bootstrap.workerInstanceId,
		} as const;
		router.accept(
			bridgeProductBatchFrameSchema.parse({
				...identity,
				baseRevision: 0,
				kind: 'subscription.batchBegin',
				mode: 'snapshot',
				snapshotCause: 'open',
				partCount: 1,
				scope: { kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] },
				streamSequence: 1,
				targetRevision: 1,
			}),
		);
		router.accept(
			bridgeProductBatchFrameSchema.parse({
				...identity,
				deliverySequence: 1,
				kind: 'subscription.batchPart',
				part: { key: '/workspace/a.swift', operation: 'put', revision: 1, value: { kind: 'file' } },
				partIndex: 0,
				streamSequence: 2,
			}),
		);
		await acknowledger.waitForIdle();
		expect(acknowledged).toEqual([1]);
		expect(installed).toEqual([]);
	});

	test('replays an identical acknowledgement after a lost reply', async () => {
		const exactBodies: string[] = [];
		const exhausted: number[] = [];
		const executeProductRequest: BridgeProductRequestExecutor = async (_, requestInit) => {
			if (!(requestInit.body instanceof Uint8Array)) throw new Error('Expected encoded ACK bytes.');
			const body = new TextDecoder().decode(requestInit.body);
			exactBodies.push(body);
			if (exactBodies.length === 1) return new Response('', { status: 502 });
			const request = bridgeProductViewAcknowledgementRequestSchema.parse(JSON.parse(body));
			return new Response(JSON.stringify({ ...request, kind: 'subscription.acknowledged' }), {
				status: 200,
			});
		};
		const acknowledger = new BridgeProductViewReceiptAcknowledger({
			authority,
			deadlineClock: clock,
			executeProductRequest,
			onExhausted: (request): void => {
				exhausted.push(request.receivedThroughDeliverySequence);
			},
		});
		acknowledger.received(receipt);
		await acknowledger.waitForIdle();
		expect(exactBodies).toHaveLength(2);
		expect(exactBodies[1]).toBe(exactBodies[0]);
		expect(exhausted).toEqual([]);
	});

	test('exhaustion reports only the affected view after the bootstrap retry bound', async () => {
		const exactBodies: string[] = [];
		const exhausted: string[] = [];
		const acknowledger = new BridgeProductViewReceiptAcknowledger({
			authority,
			deadlineClock: clock,
			executeProductRequest: async (_, requestInit): Promise<Response> => {
				if (!(requestInit.body instanceof Uint8Array))
					throw new Error('Expected encoded ACK bytes.');
				exactBodies.push(new TextDecoder().decode(requestInit.body));
				return new Response('', { status: 502 });
			},
			onExhausted: (request): void => {
				exhausted.push(request.subscriptionId);
			},
		});
		acknowledger.received(receipt);
		await acknowledger.waitForIdle();
		expect(exactBodies).toHaveLength(bootstrap.policy.admissionRetryCount + 1);
		expect(new Set(exactBodies).size).toBe(1);
		expect(exhausted).toEqual([receipt.subscriptionId]);
	});

	test('exhaustion discards later credits from the abandoned batch before resnapshot', async () => {
		const sentSequences: number[] = [];
		const exhausted: number[] = [];
		let signalFirstRequest = (): void => {};
		let releaseFirstRequest = (): void => {};
		const firstRequestStarted = new Promise<void>((resolve): void => {
			signalFirstRequest = resolve;
		});
		const firstRequestHeld = new Promise<void>((resolve): void => {
			releaseFirstRequest = resolve;
		});
		const acknowledger = new BridgeProductViewReceiptAcknowledger({
			authority,
			deadlineClock: clock,
			executeProductRequest: async (_, requestInit): Promise<Response> => {
				if (!(requestInit.body instanceof Uint8Array)) throw new Error('Expected ACK bytes.');
				const request = bridgeProductViewAcknowledgementRequestSchema.parse(
					JSON.parse(new TextDecoder().decode(requestInit.body)),
				);
				sentSequences.push(request.receivedThroughDeliverySequence);
				if (sentSequences.length === 1) {
					signalFirstRequest();
					await firstRequestHeld;
				}
				return new Response('', { status: 502 });
			},
			onExhausted: (request): void => {
				exhausted.push(request.receivedThroughDeliverySequence);
			},
		});
		acknowledger.received(receipt);
		await firstRequestStarted;
		acknowledger.received({ ...receipt, receivedThroughDeliverySequence: 2 });
		releaseFirstRequest();
		await acknowledger.waitForIdle();

		expect(sentSequences).toEqual(
			Array.from({ length: bootstrap.policy.admissionRetryCount + 1 }, (): number => 1),
		);
		expect(exhausted).toEqual([1]);
	});
});

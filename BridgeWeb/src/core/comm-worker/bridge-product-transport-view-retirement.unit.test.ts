import { afterEach, describe, expect, test, vi } from 'vitest';

import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { bridgeProductFileMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import type {
	BridgeProductControlRequest,
	BridgeProductMetadataStreamRequest,
} from './bridge-product-session-contracts.js';
import {
	bridgeProductViewAcknowledgementRequestSchema,
	type BridgeProductViewAcknowledgementRequest,
} from './bridge-product-view-control-wire-contracts.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	fileSourceConfiguration,
	metadataAccepted,
	subscriptionAccepted,
	subscriptionCancelled,
	type TransportHarness,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async (): Promise<void> => {
	await disposeTransportHarnesses();
	vi.unstubAllGlobals();
});

describe('real File transport retires pending view credits', () => {
	test.each([200, 502])(
		'retired A cannot dispatch queued credits or retry a %i reply while B continues',
		async (lateStatus): Promise<void> => {
			const harness = createTransportHarness({ deadlineClock: { schedule: () => (): void => {} } });
			const heldAck = createBridgeProductDeferred<Response>();
			const firstAck = createBridgeProductDeferred<void>();
			const stagedAll = createBridgeProductDeferred<void>();
			const siblingAck = createBridgeProductDeferred<void>();
			const attempts: BridgeProductViewAcknowledgementRequest[] = [];
			let firstSignal: AbortSignal | null | undefined;
			let receivedCount = 0;
			harness.transport.setBatchFrameSinks?.({
				install: (): void => {},
				resnapshot: (): void => {},
				resnapshotLatest: (): void => {},
				receipt: (): void => {
					if (++receivedCount === 3) stagedAll.resolve();
				},
			});
			const originalFetch = harness.server.fetch;
			vi.stubGlobal(
				'fetch',
				async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
					const body: unknown =
						init?.body instanceof Uint8Array
							? JSON.parse(new TextDecoder().decode(init.body))
							: null;
					const parsed = bridgeProductViewAcknowledgementRequestSchema.safeParse(body);
					if (!parsed.success) return originalFetch(input, init);
					const request = parsed.data;
					attempts.push(request);
					if (attempts.length === 1) {
						firstSignal = init?.signal;
						firstAck.resolve();
						return heldAck.promise;
					}
					if (request.subscriptionId === second.subscriptionId) siblingAck.resolve();
					return new Response(JSON.stringify({ ...request, kind: 'subscription.acknowledged' }), {
						status: 200,
					});
				},
			);
			const first = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
				source: fileSourceConfiguration(),
			});
			const second = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
				source: fileSourceConfiguration(),
			});
			const stream = await harness.server.waitForMetadataStreamOpened();
			harness.server.emitMetadata(metadataAccepted(stream, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: stream,
					streamSequence: 1,
					subscriptionId: first.subscriptionId,
				}),
			);
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: stream,
					streamSequence: 2,
					subscriptionId: second.subscriptionId,
				}),
			);
			const firstScope = await harness.server.waitForControlRequestWhere(
				(request) =>
					request.kind === 'subscription.setScope' &&
					request.subscriptionId === first.subscriptionId,
			);
			const secondScope = await harness.server.waitForControlRequestWhere(
				(request) =>
					request.kind === 'subscription.setScope' &&
					request.subscriptionId === second.subscriptionId,
			);
			if (
				firstScope.kind !== 'subscription.setScope' ||
				secondScope.kind !== 'subscription.setScope'
			)
				throw new Error('Expected admitted File scopes.');
			emitReceiptBatch(harness, stream, firstScope, 3, 2);
			await firstAck.promise;
			emitReceiptBatch(harness, stream, secondScope, 6, 1);
			await stagedAll.promise;
			await first.cancel();
			heldAck.resolve(
				new Response(
					lateStatus === 200
						? JSON.stringify({ ...attempts[0], kind: 'subscription.acknowledged' })
						: '',
					{ status: lateStatus },
				),
			);
			await siblingAck.promise;
			expect(
				attempts.filter((request) => request.subscriptionId === first.subscriptionId),
			).toHaveLength(1);
			expect(
				attempts.filter((request) => request.subscriptionId === second.subscriptionId),
			).toHaveLength(1);
			expect(firstSignal?.aborted).toBe(true);
			expect(
				harness.server.controlRequests.filter(
					(request) => request.kind === 'subscription.resnapshot',
				),
			).toEqual([]);
			await second.cancel();
			harness.server.emitMetadata(
				subscriptionCancelled({
					epoch: 0,
					kind: 'file.metadata',
					request: stream,
					streamSequence: 8,
					subscriptionId: first.subscriptionId,
				}),
			);
			harness.server.emitMetadata(
				subscriptionCancelled({
					epoch: 0,
					kind: 'file.metadata',
					request: stream,
					streamSequence: 9,
					subscriptionId: second.subscriptionId,
				}),
			);
		},
	);
});

function emitReceiptBatch(
	harness: TransportHarness,
	stream: BridgeProductMetadataStreamRequest,
	scope: Extract<BridgeProductControlRequest, { kind: 'subscription.setScope' }>,
	streamSequence: number,
	partCount: number,
): void {
	const identity = {
		domain: scope.domain,
		handle: scope.handle,
		incarnation: scope.incarnation,
		metadataStreamId: stream.metadataStreamId,
		paneSessionId: stream.paneSessionId,
		scopeRevision: scope.scopeRevision,
		subscriptionId: scope.subscriptionId,
		subscriptionKind: 'file.metadata',
		wireVersion: stream.wireVersion,
		workerInstanceId: stream.workerInstanceId,
		batchId: `batch-${scope.subscriptionId}`,
	};
	harness.server.emitMetadata(
		bridgeProductBatchFrameSchema.parse({
			...identity,
			baseRevision: 0,
			kind: 'subscription.batchBegin',
			mode: 'snapshot',
			snapshotCause: 'open',
			partCount,
			scope: scope.scope,
			streamSequence,
			targetRevision: 1,
		}),
	);
	for (let partIndex = 0; partIndex < partCount; partIndex += 1) {
		harness.server.emitMetadata(
			bridgeProductBatchFrameSchema.parse({
				...identity,
				deliverySequence: partIndex + 1,
				kind: 'subscription.batchPart',
				partIndex,
				part: { key: `file-${partIndex}`, operation: 'put', revision: 1, value: { kind: 'file' } },
				streamSequence: streamSequence + partIndex + 1,
			}),
		);
	}
}

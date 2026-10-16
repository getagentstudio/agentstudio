import { afterEach, describe, expect, test, vi } from 'vitest';

import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	fileSourceConfiguration,
	metadataAccepted,
	requestErrorResponse,
	subscriptionAccepted,
	subscriptionReset,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async (): Promise<void> => {
	try {
		await disposeTransportHarnesses();
	} finally {
		vi.unstubAllGlobals();
	}
});

describe('W2 reopen policy through real control, subscription and metadata codec owners', () => {
	test('file.refresh.retry rejoins source discovery after failure before any E3', async () => {
		const harness = createTransportHarness({
			deadlineClock: { schedule: (): (() => void) => (): void => {} },
		});
		let sourceCallCount = 0;
		harness.server.productCallHandler = (request): Response => {
			if (request.call.method === 'file.source.current' && ++sourceCallCount === 1)
				return requestErrorResponse(request, 'internal');
			return new Response(
				JSON.stringify({
					kind: 'call.completed',
					paneSessionId: request.paneSessionId,
					requestId: request.requestId,
					requestSequence: request.requestSequence,
					wireVersion: request.wireVersion,
					workerInstanceId: request.workerInstanceId,
					call: {
						method: request.call.method,
						result:
							request.call.method === 'file.source.current'
								? { status: 'available', source: fileSourceConfiguration() }
								: null,
					},
				}),
				{ headers: { 'Content-Type': 'application/json' } },
			);
		};
		const controller = new BridgeCommWorkerProductController({
			productTransport: harness.transport,
		});
		await expect(controller.ensureFileSource()).rejects.toThrow();
		expect(
			harness.server.controlRequests.some((request) => request.kind === 'subscription.open'),
		).toBe(false);
		await controller.sendProductControl({ method: 'file.refresh.retry', params: {} });
		expect(sourceCallCount).toBe(2);
		const stream = await harness.server.waitForMetadataStreamOpened();
		harness.server.emitMetadata(metadataAccepted(stream, 0));
		const opening = await harness.server.waitForControlRequest('subscription.open');
		expect(opening.kind).toBe('subscription.open');
	});

	test('repeated producer resets exhaust the cross-E3 policy and explicit Retry opens a successor', async () => {
		const statuses: string[] = [];
		const harness = createTransportHarness({
			deadlineClock: { schedule: (): (() => void) => (): void => {} },
			onViewRecoveryStatus: (status): void => {
				statuses.push(status.status);
			},
		});
		const policy = harness.transport.metadataReopenPolicy.viewMaximumConsecutiveResnapshots;
		const failures = Array.from({ length: policy + 1 }, () => createBridgeProductDeferred<void>());
		let failureCount = 0;
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: async () => ({
				status: 'available',
				source: fileSourceConfiguration(),
			}),
			onFileMetadataFailure: (): void => {
				failureCount += 1;
				failures[failureCount - 1]?.resolve();
			},
			productTransport: harness.transport,
		});
		await controller.ensureFileSource();
		const stream = await harness.server.waitForMetadataStreamOpened();
		harness.server.emitMetadata(metadataAccepted(stream, 0));
		let sequence = 0;
		for (let attempt = 1; attempt <= policy + 1; attempt += 1) {
			const opening = await harness.server.waitForControlRequest('subscription.open', attempt);
			if (opening.kind !== 'subscription.open') throw new Error('Expected exact opening.');
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: attempt,
					kind: 'file.metadata',
					request: stream,
					streamSequence: ++sequence,
					subscriptionId: opening.subscriptionId,
				}),
			);
			await harness.server.waitForControlRequest('subscription.setScope', attempt);
			harness.server.emitMetadata(
				subscriptionReset({
					epoch: attempt,
					kind: 'file.metadata',
					reason: 'stale_source',
					request: stream,
					streamSequence: ++sequence,
					subscriptionId: opening.subscriptionId,
					subscriptionSequence: 1,
				}),
			);
			await failures[attempt - 1]?.promise;
		}
		await expect(controller.ensureFileSource()).rejects.toThrow();
		expect(statuses.at(-1)).toBe('failedRetryable');
		expect(
			harness.server.controlRequests.filter((request) => request.kind === 'subscription.open'),
		).toHaveLength(policy + 1);
		await controller.retryMetadataView('file');
		const replacement = await harness.server.waitForControlRequest('subscription.open', policy + 2);
		expect(replacement.kind).toBe('subscription.open');
		expect(statuses.at(-1)).toBe('recovering');
	});
});

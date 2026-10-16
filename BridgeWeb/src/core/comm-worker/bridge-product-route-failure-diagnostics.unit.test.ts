import { afterEach, describe, expect, test, vi } from 'vitest';

import { bridgeProductReviewMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerHealthEventSchema,
} from './bridge-worker-contracts.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	metadataAccepted,
	subscriptionAccepted,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async (): Promise<void> => {
	try {
		await disposeTransportHarnesses();
	} finally {
		vi.unstubAllGlobals();
	}
});

describe('Bridge product route failure diagnostics', () => {
	test('retains a lifecycle routing rejection when the next physical open fails', async (): Promise<void> => {
		const harness = createTransportHarness();
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		const terminal = subscription.events[Symbol.asyncIterator]().next();
		void terminal.catch((): void => {});
		await harness.server.waitForMetadataStream();
		const streamRequest = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(streamRequest, 0));
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 0,
				kind: 'review.metadata',
				request: streamRequest,
				streamSequence: 1,
				subscriptionId: 'subscription-the-client-never-opened',
			}),
		);

		await expect(terminal).rejects.toThrow(/unknown subscription/iu);
		vi.stubGlobal('fetch', async (): Promise<Response> => new Response(null, { status: 409 }));
		const retry = harness.transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
		await expect(retry.events[Symbol.asyncIterator]().next()).rejects.toThrow(/409/iu);

		expect(harness.transport.metadataStreamDiagnostics?.()).toMatchObject({
			failureStage: 'fetch',
			routeFailureCode: 'unknown_subscription',
			streamOpenCount: 1,
		});
		expect(
			bridgeWorkerHealthEventSchema.safeParse({
				wireVersion: BRIDGE_WORKER_WIRE_VERSION,
				direction: 'serverWorkerToMain',
				transferDescriptors: [],
				kind: 'health',
				status: 'degraded',
				diagnostic: {
					kind: 'productMetadataStream',
					...harness.transport.metadataStreamDiagnostics?.(),
				},
			}).success,
		).toBe(true);
	});
});

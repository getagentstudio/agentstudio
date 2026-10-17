import { afterEach, describe, expect, test, vi } from 'vitest';

import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	fileSourceConfiguration,
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

describe('Bridge product source retirement through the real transport', () => {
	test.each(['file', 'review'] as const)(
		'reopens %s after a worker-epoch retirement cancel acknowledgement without waiting for native terminal',
		async (surface): Promise<void> => {
			// Arrange: the real controller consumes one accepted subscription.
			const harness = createTransportHarness();
			const retired = createBridgeProductDeferred<void>();
			const controller = new BridgeCommWorkerProductController({
				callCurrentFileSource: async () => ({
					source: fileSourceConfiguration(),
					status: 'available',
				}),
				onFileMetadataFailure: (): void => retired.resolve(),
				onReviewMetadataFailure: (): void => retired.resolve(),
				productTransport: harness.transport,
			});
			if (surface === 'file') await controller.ensureFileSource();
			else controller.ensureReviewMetadata();
			await harness.server.waitForMetadataStream();
			const streamRequest = harness.server.requiredMetadataRequest();
			harness.server.emitMetadata(metadataAccepted(streamRequest, 0));
			await harness.server.waitForControlKind('subscription.open');
			const opened = harness.server.requiredControlRequest('subscription.open', 0);
			const subscriptionKind = surface === 'file' ? 'file.metadata' : 'review.metadata';
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 1,
					kind: subscriptionKind,
					request: streamRequest,
					streamSequence: 1,
					subscriptionId: opened.subscriptionId,
				}),
			);

			// Act: the worker explicitly rotates this surface. Native acknowledges
			await harness.server.waitForControlKind('subscription.setScope');
			// the cancel but withholds the cancelled frame.
			harness.transport.advanceWorkerDerivationEpoch(surface);
			await retired.promise;
			if (surface === 'file') await controller.ensureFileSource();
			else controller.ensureReviewMetadata();

			// Assert: the replacement opened at the next epoch without that frame.
			await harness.server.waitForControlKind('subscription.open', 2);
			await harness.server.waitForControlKind('subscription.setScope', 2);
			expect(
				harness.server.controlRequests.map((request) =>
					request.kind === 'subscription.open' || request.kind === 'subscription.cancel'
						? `${request.kind}:${request.workerDerivationEpoch}`
						: request.kind,
				),
			).toEqual([
				'subscription.open:1',
				'subscription.setScope',
				'subscription.cancel:1',
				'subscription.open:3',
				'subscription.setScope',
			]);
		},
	);
});

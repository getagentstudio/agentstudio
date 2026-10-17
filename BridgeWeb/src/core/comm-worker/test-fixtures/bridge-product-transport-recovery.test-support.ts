import { bridgeProductFileMetadataApplicationProtocol } from '../bridge-product-metadata-application-registry.js';
import type { BridgeProductControlRequest } from '../bridge-product-session-contracts.js';
import {
	createTransportHarness,
	fileSourceConfiguration,
	metadataAccepted,
	subscriptionAccepted,
} from './bridge-product-transport-metadata.test-support.js';

export async function establishFileSubscription(
	harness: ReturnType<typeof createTransportHarness>,
): Promise<{
	readonly events: AsyncIterator<never>;
	readonly subscription: { cancel(): Promise<void>; readonly subscriptionId: string };
}> {
	const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
		source: fileSourceConfiguration(),
	});
	const events = subscription.events[Symbol.asyncIterator]();
	await harness.server.waitForMetadataStream();
	const request = harness.server.requiredMetadataRequest();
	harness.server.emitMetadata(metadataAccepted(request, 0));
	harness.server.emitMetadata(
		subscriptionAccepted({
			epoch: 0,
			kind: 'file.metadata',
			request,
			streamSequence: 1,
			subscriptionId: subscription.subscriptionId,
		}),
	);
	await harness.server.waitForControlKind('subscription.setScope');
	return { subscription, events };
}

export function retainedResponse(
	request: Extract<BridgeProductControlRequest, { kind: 'workerSession.resync' }>,
): Response {
	return resyncResponse(
		request,
		request.activeSubscriptions.map((item) => ({ ...item, disposition: 'retained' as const })),
	);
}

export function resyncResponse(
	request: Extract<BridgeProductControlRequest, { kind: 'workerSession.resync' }>,
	reconciliation: readonly unknown[],
	metadataStreamSequenceBarrier = request.lastAcceptedStreamSequence,
): Response {
	return new Response(
		JSON.stringify({
			paneSessionId: request.paneSessionId,
			requestId: request.requestId,
			requestSequence: request.requestSequence,
			wireVersion: request.wireVersion,
			workerInstanceId: request.workerInstanceId,
			kind: 'resync.accepted',
			metadataStreamSequenceBarrier,
			nextExpectedRequestSequence: request.requestSequence + 1,
			reconciliation,
		}),
		{ status: 200 },
	);
}

export function observeSettlement(promise: Promise<unknown>, observe: () => void): void {
	void promise.then(observe, observe);
}

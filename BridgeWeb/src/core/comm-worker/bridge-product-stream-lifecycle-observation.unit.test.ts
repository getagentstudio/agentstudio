import { afterEach, expect, test, vi } from 'vitest';

import { publishBridgeProductMetadataStreamDiagnostic } from '../../foundation/diagnostics/bridge-product-metadata-stream-diagnostic.js';
import {
	bridgeProductFileMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import type { BridgeProductMetadataStreamLifecycleObservation } from './bridge-product-metadata-stream-health-diagnostics.js';
import { bridgeProductStreamHealthEvent } from './bridge-product-stream-health-event.js';
import { bridgeWorkerHealthEventSchema } from './bridge-worker-contracts.js';
import { BridgeProductTestFactRecorder } from './test-fixtures/bridge-product-test-fact-recorder.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	fileSourceConfiguration,
	metadataAccepted,
	subscriptionAccepted,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async (): Promise<void> => {
	await disposeTransportHarnesses();
	vi.unstubAllGlobals();
});

test.each(['file', 'review'] as const)(
	'%s publishes stream transitions before subscription admission',
	async (surface: 'file' | 'review'): Promise<void> => {
		const harness = createTransportHarness();
		const observations: BridgeProductMetadataStreamLifecycleObservation[] = [];
		vi.stubGlobal('__bridgeProductMetadataStreamDiagnostic', undefined);
		harness.transport.setMetadataStreamHealthSink?.((observation): void => {
			observations.push(observation);
			const message = bridgeWorkerHealthEventSchema.parse(
				bridgeProductStreamHealthEvent(observation),
			);
			expect(message.requestId).toBeUndefined();
			publishBridgeProductMetadataStreamDiagnostic(message);
		});
		if (surface === 'review')
			harness.transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
		else
			harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
				source: fileSourceConfiguration(),
			});
		const stream = await harness.server.waitForMetadataStreamOpened();
		harness.server.emitMetadata(metadataAccepted(stream, 0));
		await harness.server.waitForControlRequest('subscription.open');
		expect(observations.map((observation) => observation.transition)).toEqual([
			'fetchStarted',
			'responseReceived',
			'firstByteRead',
			'acceptedRouted',
		]);
		expect(observations[1]?.responseStatus).toBe(200);
		expect(Reflect.get(globalThis, '__bridgeProductMetadataStreamDiagnostic')).toMatchObject({
			transitionMessage: 'metadataStream:acceptedRouted; responseStatus=200',
			lastRoutedFrameKind: 'metadataStream.accepted',
		});
		expect(observations[3]?.diagnostics).toMatchObject({
			lastRoutedFrameKind: 'metadataStream.accepted',
			readFulfilledCount: 1,
			routedFrameCount: 1,
		});
	},
);

test('a failed installed stream publishes failure and restart, without publishing every chunk', async (): Promise<void> => {
	const harness = createTransportHarness();
	const observations: BridgeProductMetadataStreamLifecycleObservation[] = [];
	const facts =
		new BridgeProductTestFactRecorder<BridgeProductMetadataStreamLifecycleObservation>();
	harness.transport.setMetadataStreamHealthSink?.((observation): void => {
		observations.push(observation);
		facts.record(observation);
	});
	const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
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
			subscriptionId: subscription.subscriptionId,
		}),
	);
	await harness.server.waitForControlRequest('subscription.setScope');
	expect(observations.map((observation) => observation.transition)).toEqual([
		'fetchStarted',
		'responseReceived',
		'firstByteRead',
		'acceptedRouted',
	]);
	harness.server.failMetadataReader(new Error('held transport disconnected'));
	await harness.server.waitForMetadataStreamOpened(2);
	await facts.waitFor((observation) => observation.transition === 'responseReceived', 2);
	expect(observations.map((observation) => observation.transition)).toEqual([
		'fetchStarted',
		'responseReceived',
		'firstByteRead',
		'acceptedRouted',
		'failed',
		'restartScheduled',
		'fetchStarted',
		'responseReceived',
	]);
	expect(
		observations.find((observation) => observation.transition === 'failed')?.diagnostics
			.failureStage,
	).toBe('read');
});

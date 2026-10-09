import { describe, expect, it, vi } from 'vitest';

import type { BridgeTelemetryWorkerBatchRequest } from './bridge-telemetry-worker-contracts.js';
import {
	createSettlementSkewHarness,
	makeRequiredMainRecorderEvent,
	nextPortMessageOfType,
	nextPortMessagesOfType,
} from './bridge-telemetry-worker-entry-settlement.unit.test-support.js';
import {
	bootstrapBridgeTelemetryWorkerEntry,
	createBridgeTelemetryWorkerPortHost,
	type BridgeTelemetryWorkerGlobalScope,
} from './bridge-telemetry-worker-entry.js';
import {
	acceptedTransport,
	attachTestProducer,
	makeBootstrap,
	nextPortReplies,
	nextPortReply,
} from './bridge-telemetry-worker.unit.test-support.js';

describe('telemetry worker port entry', () => {
	it('installs the global worker entry from one strict bootstrap message', async () => {
		const listeners: Array<(event: MessageEvent<unknown>) => void> = [];
		const postedHealth: unknown[] = [];
		const scope: BridgeTelemetryWorkerGlobalScope = {
			postMessage: (message): void => {
				postedHealth.push(message);
			},
			addEventListener: (_type, listener): void => {
				listeners.push(listener);
			},
		};
		bootstrapBridgeTelemetryWorkerEntry(scope, {
			createTransport: () => acceptedTransport([]),
		});
		const mainChannel = new MessageChannel();
		const commChannel = new MessageChannel();
		listeners[0]?.(
			new MessageEvent('message', {
				data: {
					type: 'telemetry.bootstrap',
					bootstrap: makeBootstrap(),
					mainPort: mainChannel.port1,
					commPort: commChannel.port1,
				},
			}),
		);

		expect(postedHealth).toEqual([
			{
				type: 'telemetry.health',
				status: 'ready',
				message: 'Telemetry worker ready.',
			},
		]);
		const replies = nextPortReplies(mainChannel.port2, 2);
		mainChannel.port2.postMessage({
			type: 'sample',
			sequence: 1,
			sample: {
				type: 'diagnostic',
				code: 'outbox_bytes',
				timestampMilliseconds: 1,
				value: 0,
			},
		});
		expect(await replies).toEqual([
			{
				type: 'producer.ready',
				generation: 1,
				initialSampleCredits: 2,
				initialControlCredits: 2,
			},
			expect.objectContaining({
				result: expect.objectContaining({ type: 'accepted', producerId: 'main' }),
			}),
		]);
		mainChannel.port2.close();
		commChannel.port2.close();
	});

	it('binds producer identity to two dedicated MessagePorts', async () => {
		const mainChannel = new MessageChannel();
		const commChannel = new MessageChannel();
		const capturedBatches: BridgeTelemetryWorkerBatchRequest[] = [];
		const host = createBridgeTelemetryWorkerPortHost({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(capturedBatches),
			mainPort: mainChannel.port1,
			commPort: commChannel.port1,
		});
		attachTestProducer(mainChannel.port2);
		const commProducer = attachTestProducer(commChannel.port2);
		const commReply = nextPortReply(commChannel.port2);
		commProducer.record({
			type: 'diagnostic',
			code: 'worker_queue_depth',
			timestampMilliseconds: 1,
			value: 3,
		});
		expect(await commReply).toMatchObject({
			type: 'producer.ingress-result',
			result: { type: 'accepted', producerId: 'comm' },
		});

		const drain = await host.drainAndClose();
		expect(drain.producerHighWatermarks).toEqual({ main: 0, comm: 1 });
		expect(capturedBatches[0]?.samples[0]?.producerId).toBe('comm');
		mainChannel.port2.close();
		commChannel.port2.close();
	});

	it('holds a Main recorder event until both producers settle and reopens cleanly', async () => {
		const harness = await createSettlementSkewHarness();
		const mainSettlementRequested = nextPortMessageOfType(
			harness.mainChannel.port2,
			'producer.settlement.request',
		);
		const mainIngressAccepted = nextPortMessageOfType(
			harness.mainChannel.port2,
			'producer.ingress-result',
		);
		const firstDrain = harness.host.drain();

		try {
			await Promise.all([mainSettlementRequested, harness.commSettlementGate.held]);
			harness.mainRecorder.record(makeRequiredMainRecorderEvent());
			const sentSamplesBeforeCommSettlement = harness.mainProducerMessages.filter(
				(message) => message.type === 'sample',
			).length;
			harness.commSettlementGate.release();

			const firstDrainResult = await firstDrain;
			expect(sentSamplesBeforeCommSettlement).toBe(0);
			expect(firstDrainResult).toMatchObject({ type: 'drained', proofEligible: true });
			const acceptedMainSample = await mainIngressAccepted;
			const secondDrainResult = await harness.host.drain();
			expect(acceptedMainSample).toMatchObject({
				type: 'producer.ingress-result',
				result: { type: 'accepted', producerId: 'main', sequence: 1 },
			});
			expect(secondDrainResult).toMatchObject({
				type: 'drained',
				proofEligible: true,
				requiredLossCount: 0,
				optionalLossCount: 0,
				sequenceGapCount: 0,
				producerHighWatermarks: { main: 1, comm: 0 },
			});
			expect(
				harness.capturedBatches
					.flatMap((batch) => batch.samples)
					.map((sample) => sample.producerId),
			).toContain('main');
		} finally {
			harness.commSettlementGate.release();
			harness.host.dispose();
			harness.mainChannel.port2.close();
			harness.commChannel.port2.close();
		}
	});

	it('reports required loss when a settlement-gap burst exceeds producer retention', async () => {
		const harness = await createSettlementSkewHarness();
		const mainSettlementRequested = nextPortMessageOfType(
			harness.mainChannel.port2,
			'producer.settlement.request',
		);
		const mainIngressResults = nextPortMessagesOfType(
			harness.mainChannel.port2,
			'producer.ingress-result',
			3,
		);
		const firstDrain = harness.host.drain();

		try {
			await Promise.all([mainSettlementRequested, harness.commSettlementGate.held]);
			harness.mainRecorder.record(makeRequiredMainRecorderEvent());
			harness.mainRecorder.record(makeRequiredMainRecorderEvent());
			harness.mainRecorder.record(makeRequiredMainRecorderEvent());
			const sentSamplesBeforeCommSettlement = harness.mainProducerMessages.filter(
				(message) => message.type === 'sample',
			).length;
			harness.commSettlementGate.release();

			await firstDrain;
			expect(sentSamplesBeforeCommSettlement).toBe(0);
			await mainIngressResults;
			const nextDrainResult = await harness.host.drain();

			expect(nextDrainResult).toMatchObject({
				type: 'drained',
				proofEligible: false,
				requiredLossCount: 1,
				sequenceGapCount: 0,
			});
		} finally {
			harness.commSettlementGate.release();
			harness.host.dispose();
			harness.mainChannel.port2.close();
			harness.commChannel.port2.close();
		}
	});

	it('closes without publishing reopened credits after terminal settlement', async () => {
		const harness = await createSettlementSkewHarness();
		const mainSettlementRequested = nextPortMessageOfType(
			harness.mainChannel.port2,
			'producer.settlement.request',
		);
		const terminalDrain = harness.host.drainAndClose();

		try {
			await Promise.all([mainSettlementRequested, harness.commSettlementGate.held]);
			harness.commSettlementGate.release();

			const result = await terminalDrain;

			expect(result).toMatchObject({ type: 'drained', settlementDisposition: 'closed' });
			expect(harness.mainWorkerCommands).toContainEqual(
				expect.objectContaining({
					type: 'producer.settlement.request',
					disposition: 'close',
					sampleCredits: 0,
					controlCredits: 0,
				}),
			);
			expect(harness.mainWorkerCommands).not.toContainEqual(
				expect.objectContaining({ type: 'producer.credit-grant' }),
			);
		} finally {
			harness.commSettlementGate.release();
			harness.host.dispose();
			harness.mainChannel.port2.close();
			harness.commChannel.port2.close();
		}
	});

	it('policy-schedules flush and returns native-admitted credits on the producer port', async () => {
		const mainChannel = new MessageChannel();
		const commChannel = new MessageChannel();
		const scheduledFlushes: Array<() => Promise<void>> = [];
		const host = createBridgeTelemetryWorkerPortHost({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport([]),
			mainPort: mainChannel.port1,
			commPort: commChannel.port1,
			scheduleFlush: (callback, delayMilliseconds): void => {
				expect(delayMilliseconds).toBe(0);
				scheduledFlushes.push(callback);
			},
		});
		const ingressReply = nextPortReply(mainChannel.port2);
		mainChannel.port2.postMessage({
			type: 'sample',
			sequence: 1,
			sample: {
				type: 'diagnostic',
				code: 'buffer_bytes',
				timestampMilliseconds: 1,
				value: 1,
			},
		});
		expect(await ingressReply).toMatchObject({ result: { type: 'accepted' } });
		expect(scheduledFlushes).toHaveLength(1);
		const creditReply = nextPortReply(mainChannel.port2);
		await scheduledFlushes[0]?.();
		expect(await creditReply).toEqual({
			type: 'producer.credit-grant',
			sampleCredits: 1,
		});
		host.dispose();
		mainChannel.port2.close();
		commChannel.port2.close();
	});

	it('coalesces ingress behind one policy flush and acknowledges control separately', async () => {
		const mainChannel = new MessageChannel();
		const commChannel = new MessageChannel();
		const scheduledFlushes: Array<() => Promise<void>> = [];
		const host = createBridgeTelemetryWorkerPortHost({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport([]),
			mainPort: mainChannel.port1,
			commPort: commChannel.port1,
			scheduleFlush: (callback): void => {
				scheduledFlushes.push(callback);
			},
		});
		const firstIngressReply = nextPortReply(mainChannel.port2);
		mainChannel.port2.postMessage({
			type: 'sample',
			sequence: 1,
			sample: {
				type: 'diagnostic',
				code: 'buffer_bytes',
				timestampMilliseconds: 1,
				value: 1,
			},
		});
		expect(await firstIngressReply).toMatchObject({ result: { type: 'accepted' } });
		const secondIngressReply = nextPortReply(mainChannel.port2);
		mainChannel.port2.postMessage({
			type: 'sample',
			sequence: 2,
			sample: {
				type: 'diagnostic',
				code: 'buffer_bytes',
				timestampMilliseconds: 2,
				value: 2,
			},
		});
		expect(await secondIngressReply).toMatchObject({ result: { type: 'accepted' } });
		expect(scheduledFlushes).toHaveLength(1);
		const sampleGrant = nextPortReply(mainChannel.port2);
		await scheduledFlushes[0]?.();
		expect(await sampleGrant).toEqual({
			type: 'producer.credit-grant',
			sampleCredits: 2,
		});

		const controlReplies = nextPortReplies(mainChannel.port2, 2);
		mainChannel.port2.postMessage({
			type: 'loss.summary',
			controlSequence: 1,
			lostSequenceStart: 3,
			lostSequenceEnd: 3,
			requiredCount: 0,
			optionalCount: 1,
			reason: 'credit_exhausted',
		});
		expect(await controlReplies).toEqual([
			expect.objectContaining({
				type: 'producer.ingress-result',
				result: expect.objectContaining({ type: 'accepted' }),
			}),
			{ type: 'producer.credit-grant', controlCredits: 1 },
		]);
		host.dispose();
		mainChannel.port2.close();
		commChannel.port2.close();
	});

	it('does not flush or post grants after disposal wins the scheduled race', async () => {
		const mainChannel = new MessageChannel();
		const commChannel = new MessageChannel();
		const mainPostMessage = vi.spyOn(mainChannel.port1, 'postMessage');
		const scheduledFlushes: Array<() => Promise<void>> = [];
		const postBatch = vi.fn(acceptedTransport([]).postBatch);
		const host = createBridgeTelemetryWorkerPortHost({
			bootstrap: makeBootstrap(),
			transport: { postBatch },
			mainPort: mainChannel.port1,
			commPort: commChannel.port1,
			scheduleFlush: (callback): void => {
				scheduledFlushes.push(callback);
			},
		});
		const ingressReply = nextPortReply(mainChannel.port2);
		mainChannel.port2.postMessage({
			type: 'sample',
			sequence: 1,
			sample: {
				type: 'diagnostic',
				code: 'buffer_bytes',
				timestampMilliseconds: 1,
				value: 1,
			},
		});
		await ingressReply;
		const postsBeforeDispose = mainPostMessage.mock.calls.length;

		host.dispose();
		await scheduledFlushes[0]?.();

		expect(postBatch).not.toHaveBeenCalled();
		expect(mainPostMessage).toHaveBeenCalledTimes(postsBeforeDispose);
		mainChannel.port2.close();
		commChannel.port2.close();
	});

	it('rejects a body that attempts to claim producer identity', async () => {
		const mainChannel = new MessageChannel();
		const commChannel = new MessageChannel();
		const host = createBridgeTelemetryWorkerPortHost({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport([]),
			mainPort: mainChannel.port1,
			commPort: commChannel.port1,
		});
		const reply = nextPortReply(mainChannel.port2);
		mainChannel.port2.postMessage({
			type: 'sample',
			sequence: 1,
			producerId: 'comm',
			sample: {
				type: 'diagnostic',
				code: 'buffer_bytes',
				timestampMilliseconds: 1,
				value: 0,
			},
		});
		expect(await reply).toMatchObject({ result: { type: 'rejected', reason: 'invalid_message' } });
		host.dispose();
		mainChannel.port2.close();
		commChannel.port2.close();
	});

	it('replaces only the requested producer port with fresh initial credits', async () => {
		const listeners: Array<(event: MessageEvent<unknown>) => void> = [];
		const postedMessages: unknown[] = [];
		const scope: BridgeTelemetryWorkerGlobalScope = {
			postMessage: (message): void => {
				postedMessages.push(message);
			},
			addEventListener: (_type, listener): void => {
				listeners.push(listener);
			},
		};
		bootstrapBridgeTelemetryWorkerEntry(scope, {
			createTransport: () => acceptedTransport([]),
		});
		const mainChannel = new MessageChannel();
		const commChannel = new MessageChannel();
		attachTestProducer(mainChannel.port2, { receivesReady: true });
		attachTestProducer(commChannel.port2, { receivesReady: true });
		listeners[0]?.(
			new MessageEvent('message', {
				data: {
					type: 'telemetry.bootstrap',
					bootstrap: makeBootstrap(),
					mainPort: mainChannel.port1,
					commPort: commChannel.port1,
				},
			}),
		);
		const replacementChannel = new MessageChannel();
		attachTestProducer(replacementChannel.port2, { receivesReady: true });
		const ready = nextPortReply(replacementChannel.port2);

		listeners[0]?.(
			new MessageEvent('message', {
				data: {
					type: 'telemetry.producer.replace',
					requestId: 'replace-comm-1',
					producerId: 'comm',
					producerPort: replacementChannel.port1,
				},
			}),
		);

		expect(await ready).toEqual({
			type: 'producer.ready',
			generation: 2,
			initialSampleCredits: 2,
			initialControlCredits: 2,
		});
		expect(postedMessages.at(-1)).toEqual({
			type: 'telemetry.producer.replaced',
			requestId: 'replace-comm-1',
			producerId: 'comm',
		});
		mainChannel.port2.close();
		commChannel.port2.close();
		replacementChannel.port2.close();
	});

	it('settles a barrier-waiting drain when disposal wins the lifecycle race', async () => {
		const mainChannel = new MessageChannel();
		const commChannel = new MessageChannel();
		const host = createBridgeTelemetryWorkerPortHost({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport([]),
			mainPort: mainChannel.port1,
			commPort: commChannel.port1,
		});
		const drain = host.drain();

		host.dispose();

		await expect(drain).rejects.toThrow('Telemetry worker port host was disposed.');
		mainChannel.port2.close();
		commChannel.port2.close();
	});

	it('continues replacement with failed proof after the old producer barrier times out', async () => {
		const scheduledTimeouts: Array<() => void> = [];
		const mainChannel = new MessageChannel();
		const commChannel = new MessageChannel();
		const replacementChannel = new MessageChannel();
		const host = createBridgeTelemetryWorkerPortHost({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport([]),
			mainPort: mainChannel.port1,
			commPort: commChannel.port1,
			scheduleLifecycleTimeout: (callback): (() => void) => {
				scheduledTimeouts.push(callback);
				return (): void => {};
			},
		});
		const replacement = host.replaceProducer('comm', replacementChannel.port1);
		await vi.waitFor(() => expect(scheduledTimeouts).toHaveLength(1));

		scheduledTimeouts[0]?.();
		await replacement;

		expect(host.runtime.snapshot()).toMatchObject({
			proofEligible: false,
			producers: { comm: { generation: 2 } },
		});
		host.dispose();
		mainChannel.port2.close();
		commChannel.port2.close();
		replacementChannel.port2.close();
	});
});

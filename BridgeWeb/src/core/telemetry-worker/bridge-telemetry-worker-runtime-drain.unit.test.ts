import { describe, expect, it, vi } from 'vitest';

import { createBridgeTelemetryWorkerRuntime } from './bridge-telemetry-worker-factory.js';
import { createBridgeTelemetryWorkerProducer } from './bridge-telemetry-worker-producer.js';
import {
	acceptBarrierReceipt,
	acceptedTransport,
	completeDrainWithSettlements,
	mainLifecycleSample,
	makeBootstrap,
	optionalDiagnosticSample,
} from './bridge-telemetry-worker-runtime.test-support.js';

describe('BridgeTelemetryWorkerRuntime drain and proof settlement', () => {
	it('does not recount an individually unbatchable producer loss summary', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap({
				policy: { ...makeBootstrap().policy, batchMaxBytes: 64 },
			}),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		await runtime.acceptProducerMessage(main, {
			type: 'loss.summary',
			controlSequence: 1,
			lostSequenceStart: 1,
			lostSequenceEnd: 2,
			requiredCount: 1,
			optionalCount: 1,
			reason: 'credit_exhausted',
		});

		await runtime.flush();

		expect(runtime.snapshot()).toMatchObject({
			requiredLossCount: 1,
			optionalLossCount: 1,
		});
	});

	it('does not recount producer loss summaries when the outbox cannot retain them', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap({
				policy: { ...makeBootstrap().policy, outboxMaxBytes: 64 },
			}),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		await runtime.acceptProducerMessage(main, {
			type: 'loss.summary',
			controlSequence: 1,
			lostSequenceStart: 1,
			lostSequenceEnd: 2,
			requiredCount: 1,
			optionalCount: 1,
			reason: 'credit_exhausted',
		});

		await runtime.flush();

		expect(runtime.snapshot()).toMatchObject({
			requiredLossCount: 1,
			optionalLossCount: 1,
		});
	});

	it('fails proof and retains no body when the outbox byte cap is exhausted', async () => {
		const postBatch = vi.fn(acceptedTransport().postBatch);
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap({
				policy: { ...makeBootstrap().policy, outboxMaxBytes: 64 },
			}),
			transport: { postBatch },
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		await runtime.acceptProducerMessage(main, {
			type: 'sample',
			sequence: 1,
			sample: mainLifecycleSample,
		});

		await runtime.flush();

		expect(postBatch).not.toHaveBeenCalled();
		expect(runtime.snapshot()).toMatchObject({
			proofEligible: false,
			requiredLossCount: 1,
			outboxCount: 0,
		});
	});

	it('excludes real post-seal ambient samples while preserving sequence continuity across reopen', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		const pendingIngress: Promise<unknown>[] = [];
		const producer = createBridgeTelemetryWorkerProducer({
			initialSampleCredits: 1,
			initialControlCredits: 1,
			send: (message): void => {
				pendingIngress.push(runtime.acceptProducerMessage(main, message));
			},
		});
		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: main.generation,
			initialSampleCredits: 1,
			initialControlCredits: 1,
		});
		expect(producer.record(mainLifecycleSample).disposition).toBe('posted');
		await Promise.all(pendingIngress.splice(0));
		runtime.prepareProducerBarrier('main', 'barrier-1');
		expect(
			producer.acceptWorkerCommand({
				type: 'producer.barrier.request',
				barrierId: 'barrier-1',
				generation: main.generation,
			}),
		).toBe(true);
		await Promise.all(pendingIngress.splice(0));
		expect(producer.record(mainLifecycleSample).disposition).toBe('loss_recorded');
		expect(producer.record(optionalDiagnosticSample).disposition).toBe('loss_recorded');
		await runtime.drainBufferedForSettlement();
		runtime.prepareProducerSettlement('main', 'barrier-1');
		expect(
			producer.acceptWorkerCommand({
				type: 'producer.settlement.request',
				barrierId: 'barrier-1',
				generation: main.generation,
				disposition: 'reopen',
				sampleCredits: 1,
				controlCredits: 1,
			}),
		).toBe(true);
		await Promise.all(pendingIngress.splice(0));
		expect(runtime.finishDrain(false)).toMatchObject({
			proofEligible: true,
			requiredLossCount: 0,
			optionalLossCount: 0,
			producerHighWatermarks: { main: 1 },
		});
		expect(runtime.snapshot().producers.main?.nextExpectedSequence).toBe(4);

		expect(producer.record(mainLifecycleSample).disposition).toBe('posted');
		await Promise.all(pendingIngress.splice(0));
		runtime.prepareProducerBarrier('main', 'barrier-2');
		expect(
			producer.acceptWorkerCommand({
				type: 'producer.barrier.request',
				barrierId: 'barrier-2',
				generation: main.generation,
			}),
		).toBe(true);
		await Promise.all(pendingIngress.splice(0));
		await runtime.drainBufferedForSettlement();
		runtime.prepareProducerSettlement('main', 'barrier-2');
		expect(
			producer.acceptWorkerCommand({
				type: 'producer.settlement.request',
				barrierId: 'barrier-2',
				generation: main.generation,
				disposition: 'close',
				sampleCredits: 0,
				controlCredits: 0,
			}),
		).toBe(true);
		await Promise.all(pendingIngress.splice(0));
		expect(runtime.finishDrain(true)).toMatchObject({
			proofEligible: true,
			requiredLossCount: 0,
			optionalLossCount: 0,
			producerHighWatermarks: { main: 4 },
		});
	});

	it('still counts a pending required loss from before the barrier', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		runtime.prepareProducerBarrier('main', 'barrier-main');
		expect(
			await runtime.acceptProducerMessage(main, {
				type: 'producer.barrier.receipt',
				barrierId: 'barrier-main',
				generation: main.generation,
				producerSequenceHighWatermark: 1,
				preSealLossRange: {
					lostSequenceStart: 1,
					lostSequenceEnd: 1,
					requiredCount: 1,
					optionalCount: 0,
				},
			}),
		).toMatchObject({ type: 'accepted' });
		const result = await completeDrainWithSettlements({
			runtime,
			close: true,
			producers: [
				{
					installation: main,
					highWatermark: 2,
					postSealLossRange: {
						lostSequenceStart: 2,
						lostSequenceEnd: 2,
						requiredCount: 1,
						optionalCount: 0,
					},
				},
			],
		});
		expect(result).toMatchObject({ proofEligible: false, requiredLossCount: 1 });
	});

	it('counts loss of a prefix sample from the outbox during drain', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap({
				policy: { ...makeBootstrap().policy, maxRetryAttempts: 1 },
			}),
			transport: {
				postBatch: async () => {
					throw new Error('transport unavailable');
				},
			},
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		await runtime.acceptProducerMessage(main, {
			type: 'sample',
			sequence: 1,
			sample: mainLifecycleSample,
		});
		await acceptBarrierReceipt({ runtime, installation: main, highWatermark: 1 });
		await runtime.drainBufferedForSettlement();
		runtime.prepareProducerSettlement('main', 'barrier-main');
		await runtime.acceptProducerMessage(main, {
			type: 'producer.settlement.receipt',
			barrierId: 'barrier-main',
			generation: main.generation,
			producerSequenceHighWatermark: 2,
			postSealLossRange: {
				lostSequenceStart: 2,
				lostSequenceEnd: 2,
				requiredCount: 1,
				optionalCount: 0,
			},
		});
		expect(runtime.finishDrain(true)).toMatchObject({
			proofEligible: false,
			requiredLossCount: 1,
		});
	});

	it('rejects a malformed post-seal range and a wrong-generation receipt', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		await acceptBarrierReceipt({ runtime, installation: main, highWatermark: 0 });
		runtime.prepareProducerSettlement('main', 'barrier-main');
		expect(
			await runtime.acceptProducerMessage(main, {
				type: 'producer.settlement.receipt',
				barrierId: 'barrier-main',
				generation: main.generation,
				producerSequenceHighWatermark: 1,
				postSealLossRange: {
					lostSequenceStart: 1,
					lostSequenceEnd: 1,
					requiredCount: 0,
					optionalCount: 0,
				},
			}),
		).toMatchObject({ type: 'rejected', reason: 'sequence_gap' });
		expect(
			await runtime.acceptProducerMessage(main, {
				type: 'producer.settlement.receipt',
				barrierId: 'barrier-main',
				generation: main.generation + 1,
				producerSequenceHighWatermark: 0,
				postSealLossRange: null,
			}),
		).toMatchObject({ type: 'rejected', reason: 'invalid_message' });
		expect(runtime.snapshot()).toMatchObject({ proofEligible: false, sequenceGapCount: 1 });
	});

	it('fails a missing settlement even when the barrier was clean', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		await acceptBarrierReceipt({ runtime, installation: main, highWatermark: 0 });
		await runtime.drainBufferedForSettlement();
		expect(runtime.finishDrain(true)).toMatchObject({ proofEligible: false });
	});

	it('does not clear an earlier proof failure when post-seal loss is excluded', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		runtime.failProof();
		await acceptBarrierReceipt({ runtime, installation: main, highWatermark: 0 });
		expect(
			await completeDrainWithSettlements({
				runtime,
				close: true,
				producers: [
					{
						installation: main,
						highWatermark: 1,
						postSealLossRange: {
							lostSequenceStart: 1,
							lostSequenceEnd: 1,
							requiredCount: 1,
							optionalCount: 0,
						},
					},
				],
			}),
		).toMatchObject({ proofEligible: false, requiredLossCount: 0 });
	});

	it('rejects an optional raw sample after the barrier as a protocol breach', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		await acceptBarrierReceipt({ runtime, installation: main, highWatermark: 0 });
		expect(
			await runtime.acceptProducerMessage(main, {
				type: 'sample',
				sequence: 1,
				sample: optionalDiagnosticSample,
			}),
		).toMatchObject({ type: 'rejected' });
		expect(runtime.snapshot().proofEligible).toBe(false);
	});

	it('rejects an optional raw sample during drain after the barrier', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		await acceptBarrierReceipt({ runtime, installation: main, highWatermark: 0 });
		await runtime.drainBufferedForSettlement();
		expect(
			await runtime.acceptProducerMessage(main, {
				type: 'sample',
				sequence: 1,
				sample: optionalDiagnosticSample,
			}),
		).toMatchObject({ type: 'rejected', reason: 'closed' });
		expect(runtime.snapshot().proofEligible).toBe(false);
	});

	it('fails proof when a raw sample races after its accepted producer barrier', async () => {
		let releaseNativeAdmission!: () => void;
		const nativeAdmission = new Promise<void>((resolve): void => {
			releaseNativeAdmission = resolve;
		});
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: {
				postBatch: async (request) => {
					await nativeAdmission;
					return {
						type: 'accepted',
						telemetrySessionId: request.telemetrySessionId,
						batchSequence: request.batchSequence,
						nextExpectedBatchSequence: request.batchSequence + 1,
						acceptedSampleCount: request.samples.length,
						acceptedLossCount: 0,
					};
				},
			},
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		const comm = runtime.installProducer('comm');
		await runtime.acceptProducerMessage(main, {
			type: 'sample',
			sequence: 1,
			sample: mainLifecycleSample,
		});
		await acceptBarrierReceipt({ runtime, installation: main, highWatermark: 1 });
		await acceptBarrierReceipt({ runtime, installation: comm, highWatermark: 0 });

		const drain = completeDrainWithSettlements({
			runtime,
			close: true,
			producers: [
				{
					installation: main,
					highWatermark: 1,
					postSealLossRange: null,
				},
				{ installation: comm, highWatermark: 0 },
			],
		});
		const racedRequiredSample = await runtime.acceptProducerMessage(main, {
			type: 'sample',
			sequence: 2,
			sample: mainLifecycleSample,
		});
		releaseNativeAdmission();

		expect(racedRequiredSample).toMatchObject({ type: 'rejected', reason: 'closed' });
		expect((await drain).proofEligible).toBe(false);
	});

	it('fails proof when a nonempty comm generation is replaced before it is sealed', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		const commV1 = runtime.installProducer('comm');
		await runtime.acceptProducerMessage(commV1, {
			type: 'sample',
			sequence: 1,
			sample: mainLifecycleSample,
		});

		const commV2 = runtime.replaceProducer('comm');
		await acceptBarrierReceipt({ runtime, installation: main, highWatermark: 0 });
		await acceptBarrierReceipt({ runtime, installation: commV2, highWatermark: 0 });

		expect(
			(
				await completeDrainWithSettlements({
					runtime,
					close: true,
					producers: [
						{ installation: main, highWatermark: 0 },
						{ installation: commV2, highWatermark: 0 },
					],
				})
			).proofEligible,
		).toBe(false);
	});

	it('preserves proof when a clean comm generation is sealed before replacement', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		const commV1 = runtime.installProducer('comm');
		await runtime.acceptProducerMessage(commV1, {
			type: 'sample',
			sequence: 1,
			sample: mainLifecycleSample,
		});
		await acceptBarrierReceipt({ runtime, installation: commV1, highWatermark: 1 });

		const commV2 = runtime.replaceProducer('comm');
		await acceptBarrierReceipt({ runtime, installation: main, highWatermark: 0 });
		await acceptBarrierReceipt({ runtime, installation: commV2, highWatermark: 0 });

		expect(
			(
				await completeDrainWithSettlements({
					runtime,
					close: true,
					producers: [
						{ installation: main, highWatermark: 0 },
						{ installation: commV2, highWatermark: 0 },
					],
				})
			).proofEligible,
		).toBe(true);
	});

	it('drains exact producer high-watermarks, evicts stale replay, and closes permanently', async () => {
		const runtime = createBridgeTelemetryWorkerRuntime({
			bootstrap: makeBootstrap(),
			transport: acceptedTransport(),
		});
		if (runtime === null) return;
		const main = runtime.installProducer('main');
		const comm = runtime.installProducer('comm');
		await runtime.acceptProducerMessage(main, {
			type: 'sample',
			sequence: 1,
			sample: mainLifecycleSample,
		});
		await runtime.acceptProducerMessage(comm, {
			type: 'sample',
			sequence: 1,
			sample: mainLifecycleSample,
		});
		await acceptBarrierReceipt({ runtime, installation: main, highWatermark: 1 });
		await acceptBarrierReceipt({ runtime, installation: comm, highWatermark: 1 });

		const drain = await completeDrainWithSettlements({
			runtime,
			close: true,
			producers: [
				{ installation: main, highWatermark: 1 },
				{ installation: comm, highWatermark: 1 },
			],
		});
		expect(drain).toMatchObject({
			type: 'drained',
			proofEligible: true,
			settlementDisposition: 'closed',
			requiredLossCount: 0,
			optionalLossCount: 0,
			sequenceGapCount: 0,
			producerHighWatermarks: { comm: 1, main: 1 },
		});
		expect(runtime.snapshot().state).toBe('closed');
		expect(
			await runtime.acceptProducerMessage(main, {
				type: 'sample',
				sequence: 2,
				sample: mainLifecycleSample,
			}),
		).toMatchObject({ type: 'rejected', reason: 'closed' });
	});
});

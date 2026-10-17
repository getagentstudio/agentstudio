import { describe, expect, it, vi } from 'vitest';

import { createBridgeTelemetryWorkerProducer } from './bridge-telemetry-worker-producer.js';

const lifecycleSample = {
	type: 'interaction.lifecycle',
	stage: 'painted',
	timestampMilliseconds: 20,
	surface: 'file',
	interactionSequence: 2,
	attemptId: 'attempt-2',
} as const;

const diagnosticSample = {
	type: 'diagnostic',
	code: 'buffer_bytes',
	timestampMilliseconds: 21,
	value: 128,
} as const;

describe('BridgeTelemetryWorkerProducer', () => {
	it('labels active retention overflow as credit exhaustion after producer ready', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 1,
			preReadyRequiredSampleMaxEncodedBytes: 16 * 1024,
			send,
		});
		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 0,
			initialControlCredits: 1,
		});
		expect(producer.record(lifecycleSample).disposition).toBe('retained');
		expect(producer.record({ ...lifecycleSample, attemptId: 'second' }).disposition).toBe(
			'loss_recorded',
		);
		producer.grantSampleCredits(1);
		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{ type: 'sample', sequence: 1, sample: lifecycleSample },
			{
				type: 'loss.summary',
				controlSequence: 1,
				lostSequenceStart: 2,
				lostSequenceEnd: 2,
				requiredCount: 1,
				optionalCount: 0,
				reason: 'credit_exhausted',
			},
		]);
	});

	it('reports worker-entry overflow before the producer existed without inventing sample bodies', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialSampleCredits: 0,
			initialControlCredits: 0,
			preReadyRequiredSampleCapacity: 2,
			preReadyRequiredSampleMaxEncodedBytes: 16 * 1024,
			send,
		});
		producer.record(lifecycleSample);
		producer.recordPriorLoss({ requiredCount: 2, optionalCount: 1, reason: 'queue_saturated' });
		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 1,
			initialControlCredits: 1,
		});
		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{ type: 'sample', sequence: 1, sample: lifecycleSample },
			{
				type: 'loss.summary',
				controlSequence: 1,
				lostSequenceStart: 2,
				lostSequenceEnd: 4,
				requiredCount: 2,
				optionalCount: 1,
				reason: 'queue_saturated',
			},
		]);
	});
	it('retains required startup samples until producer ready and preserves their sequence', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 2,
			preReadyRequiredSampleMaxEncodedBytes: 16 * 1024,
			send,
		});

		expect(producer.record(lifecycleSample)).toEqual({ disposition: 'retained', sequence: 1 });
		expect(
			producer.record({ ...lifecycleSample, attemptId: 'attempt-3', interactionSequence: 3 }),
		).toEqual({ disposition: 'retained', sequence: 2 });
		expect(send).not.toHaveBeenCalled();

		expect(
			producer.acceptWorkerCommand({
				type: 'producer.ready',
				generation: 1,
				initialSampleCredits: 2,
				initialControlCredits: 1,
			}),
		).toBe(true);
		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{ type: 'sample', sequence: 1, sample: lifecycleSample },
			{
				type: 'sample',
				sequence: 2,
				sample: { ...lifecycleSample, attemptId: 'attempt-3', interactionSequence: 3 },
			},
		]);
		expect(producer.snapshot()).toMatchObject({
			availableSampleCredits: 0,
			nextSequence: 3,
			pendingLossRange: null,
		});
	});

	it('rejects repeated and stale ready commands without resetting installed generation credits', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 1,
			preReadyRequiredSampleMaxEncodedBytes: 16 * 1024,
			send,
		});

		expect(producer.record(lifecycleSample)).toEqual({ disposition: 'retained', sequence: 1 });
		expect(
			producer.acceptWorkerCommand({
				type: 'producer.ready',
				generation: 2,
				initialSampleCredits: 0,
				initialControlCredits: 0,
			}),
		).toBe(true);

		const repeatedReadyAccepted = producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 2,
			initialSampleCredits: 1,
			initialControlCredits: 1,
		});
		const staleReadyAccepted = producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 1,
			initialControlCredits: 1,
		});

		expect([repeatedReadyAccepted, staleReadyAccepted]).toEqual([false, false]);
		expect(send).not.toHaveBeenCalled();
		expect(producer.snapshot()).toMatchObject({
			generation: 2,
			availableSampleCredits: 0,
			availableControlCredits: 0,
			retainedPreReadyRequiredSampleCount: 1,
		});

		producer.grantSampleCredits(1);
		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{ type: 'sample', sequence: 1, sample: lifecycleSample },
		]);
	});

	it('retains a synchronous required burst until installed credits recycle in exact order', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 128,
			preReadyRequiredSampleMaxEncodedBytes: 64 * 1024,
			send,
		});
		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 128,
			initialControlCredits: 4,
		});

		const postedResults = Array.from({ length: 128 }, () => producer.record(lifecycleSample));
		const retainedResults = Array.from({ length: 93 }, () => producer.record(lifecycleSample));

		expect(postedResults.every((result) => result.disposition === 'posted')).toBe(true);
		expect(retainedResults.every((result) => result.disposition === 'retained')).toBe(true);
		expect(producer.snapshot()).toMatchObject({
			availableSampleCredits: 0,
			retainedPreReadyRequiredSampleCount: 93,
			pendingLossRange: null,
		});

		producer.grantSampleCredits(93);

		const messages = send.mock.calls.map(([message]) => message);
		expect(messages).toHaveLength(221);
		expect(messages.every((message) => message.type === 'sample')).toBe(true);
		expect(messages.map((message) => ('sequence' in message ? message.sequence : null))).toEqual(
			Array.from({ length: 221 }, (_, index) => index + 1),
		);
		expect(producer.snapshot()).toMatchObject({
			availableSampleCredits: 0,
			retainedPreReadyRequiredSampleCount: 0,
			retainedPreReadyRequiredSampleEncodedBytes: 0,
			pendingLossRange: null,
		});
		expect(producer.flushLossSummary()).toBe(true);
	});

	it('keeps optional loss bodyless and ordered behind retained required work', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 2,
			preReadyRequiredSampleMaxEncodedBytes: 16 * 1024,
			send,
		});
		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 0,
			initialControlCredits: 1,
		});

		expect(producer.record(lifecycleSample)).toEqual({ disposition: 'retained', sequence: 1 });
		expect(producer.record(diagnosticSample)).toEqual({
			disposition: 'loss_recorded',
			sequence: 2,
		});
		expect(send).not.toHaveBeenCalled();

		producer.grantSampleCredits(1);

		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{ type: 'sample', sequence: 1, sample: lifecycleSample },
			{
				type: 'loss.summary',
				controlSequence: 1,
				lostSequenceStart: 2,
				lostSequenceEnd: 2,
				requiredCount: 0,
				optionalCount: 1,
				reason: 'credit_exhausted',
			},
		]);
		expect(JSON.stringify(send.mock.calls)).not.toContain('buffer_bytes');
	});

	it('accounts exact required pre-ready overflow after retained startup samples drain', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 1,
			preReadyRequiredSampleMaxEncodedBytes: 16 * 1024,
			send,
		});
		const overflowedSample = {
			...lifecycleSample,
			attemptId: 'attempt-overflow',
			interactionSequence: 3,
			stage: 'validity_rejected',
		} as const;

		expect(producer.record(lifecycleSample)).toEqual({ disposition: 'retained', sequence: 1 });
		expect(producer.record(overflowedSample)).toEqual({
			disposition: 'loss_recorded',
			sequence: 2,
		});
		expect(send).not.toHaveBeenCalled();

		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 1,
			initialControlCredits: 1,
		});

		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{ type: 'sample', sequence: 1, sample: lifecycleSample },
			{
				type: 'loss.summary',
				controlSequence: 1,
				lostSequenceStart: 2,
				lostSequenceEnd: 2,
				requiredCount: 1,
				optionalCount: 0,
				reason: 'queue_saturated',
			},
		]);
		expect(JSON.stringify(send.mock.calls)).not.toContain('attempt-overflow');
	});

	it('bounds retained required startup samples by aggregate encoded bytes', () => {
		const send = vi.fn();
		const overflowedSample = {
			...lifecycleSample,
			attemptId: 'attempt-byte-cap',
			interactionSequence: 3,
		} as const;
		const retainedSampleEncodedBytes = encodedSampleByteLength(lifecycleSample);
		const overflowedSampleEncodedBytes = encodedSampleByteLength(overflowedSample);
		const aggregateEncodedByteCap = retainedSampleEncodedBytes + overflowedSampleEncodedBytes - 1;
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 2,
			preReadyRequiredSampleMaxEncodedBytes: aggregateEncodedByteCap,
			send,
		});

		expect(producer.record(lifecycleSample)).toEqual({ disposition: 'retained', sequence: 1 });
		expect(producer.snapshot()).toMatchObject({
			retainedPreReadyRequiredSampleCount: 1,
		});
		expect(producer.record(overflowedSample)).toEqual({
			disposition: 'loss_recorded',
			sequence: 2,
		});
		expect(send).not.toHaveBeenCalled();

		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 1,
			initialControlCredits: 1,
		});

		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{ type: 'sample', sequence: 1, sample: lifecycleSample },
			{
				type: 'loss.summary',
				controlSequence: 1,
				lostSequenceStart: 2,
				lostSequenceEnd: 2,
				requiredCount: 1,
				optionalCount: 0,
				reason: 'queue_saturated',
			},
		]);

		const closeProducer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 1,
			preReadyRequiredSampleMaxEncodedBytes: retainedSampleEncodedBytes,
			send: vi.fn(),
		});
		expect(closeProducer.record(lifecycleSample).disposition).toBe('retained');
		expect(closeProducer.snapshot()).toMatchObject({
			retainedPreReadyRequiredSampleCount: 1,
		});
		closeProducer.close();
		expect(closeProducer.snapshot()).toMatchObject({
			retainedPreReadyRequiredSampleCount: 0,
		});
	});

	it('classifies a single required startup sample over the encoded byte cap exactly', () => {
		const send = vi.fn();
		const encodedByteCap = encodedSampleByteLength(lifecycleSample) - 1;
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 1,
			preReadyRequiredSampleMaxEncodedBytes: encodedByteCap,
			send,
		});

		expect(producer.record(lifecycleSample)).toEqual({
			disposition: 'loss_recorded',
			sequence: 1,
		});
		expect(send).not.toHaveBeenCalled();

		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 0,
			initialControlCredits: 1,
		});

		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{
				type: 'loss.summary',
				controlSequence: 1,
				lostSequenceStart: 1,
				lostSequenceEnd: 1,
				requiredCount: 1,
				optionalCount: 0,
				reason: 'encoded_byte_cap',
			},
		]);
		expect(JSON.stringify(send.mock.calls)).not.toContain('attempt-2');
	});

	it('may shed optional samples before ready without consuming required startup capacity', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 1,
			preReadyRequiredSampleMaxEncodedBytes: 16 * 1024,
			send,
		});

		expect(producer.record(diagnosticSample)).toEqual({
			disposition: 'loss_recorded',
			sequence: 1,
		});
		expect(producer.record(lifecycleSample)).toEqual({ disposition: 'retained', sequence: 2 });

		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 1,
			initialControlCredits: 1,
		});

		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{
				type: 'loss.summary',
				controlSequence: 1,
				lostSequenceStart: 1,
				lostSequenceEnd: 1,
				requiredCount: 0,
				optionalCount: 1,
				reason: 'queue_saturated',
			},
			{ type: 'sample', sequence: 2, sample: lifecycleSample },
		]);
	});

	it('keeps retained required startup samples behind an earlier loss awaiting control credit', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 1,
			preReadyRequiredSampleMaxEncodedBytes: 16 * 1024,
			send,
		});

		expect(producer.record(diagnosticSample)).toEqual({
			disposition: 'loss_recorded',
			sequence: 1,
		});
		expect(producer.record(lifecycleSample)).toEqual({ disposition: 'retained', sequence: 2 });

		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 1,
			initialControlCredits: 0,
		});

		expect(send).not.toHaveBeenCalled();
		expect(producer.snapshot()).toMatchObject({
			availableSampleCredits: 1,
			retainedPreReadyRequiredSampleCount: 1,
		});

		producer.grantControlCredits(1);
		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{
				type: 'loss.summary',
				controlSequence: 1,
				lostSequenceStart: 1,
				lostSequenceEnd: 1,
				requiredCount: 0,
				optionalCount: 1,
				reason: 'queue_saturated',
			},
			{ type: 'sample', sequence: 2, sample: lifecycleSample },
		]);
	});

	it('accounts active required overflow as credit exhaustion behind a full retained queue', () => {
		const send = vi.fn();
		const laterRequiredSample = {
			...lifecycleSample,
			attemptId: 'attempt-later',
			interactionSequence: 3,
			stage: 'main_received',
		} as const;
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 1,
			preReadyRequiredSampleMaxEncodedBytes: 16 * 1024,
			send,
		});

		expect(producer.record(lifecycleSample)).toEqual({ disposition: 'retained', sequence: 1 });
		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 0,
			initialControlCredits: 1,
		});

		expect(producer.record(laterRequiredSample)).toEqual({
			disposition: 'loss_recorded',
			sequence: 2,
		});
		expect(send).not.toHaveBeenCalled();

		producer.grantSampleCredits(1);
		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{ type: 'sample', sequence: 1, sample: lifecycleSample },
			{
				type: 'loss.summary',
				controlSequence: 1,
				lostSequenceStart: 2,
				lostSequenceEnd: 2,
				requiredCount: 1,
				optionalCount: 0,
				reason: 'credit_exhausted',
			},
		]);
		expect(JSON.stringify(send.mock.calls)).not.toContain('attempt-later');
	});

	it('posts only compact sequenced samples while credits are available', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 1,
			initialSampleCredits: 1,
			send,
		});

		expect(producer.record(lifecycleSample)).toEqual({ disposition: 'posted', sequence: 1 });
		expect(send).toHaveBeenCalledWith({
			type: 'sample',
			sequence: 1,
			sample: lifecycleSample,
		});
		expect(producer.snapshot()).toMatchObject({
			nextSequence: 2,
			availableSampleCredits: 0,
		});
		expect('barrier' in producer).toBe(false);
	});

	it('retains no sample body without credit and emits an exact ordered loss range', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 2,
			initialSampleCredits: 0,
			send,
		});
		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 0,
			initialControlCredits: 2,
		});

		expect(producer.record(lifecycleSample)).toEqual({ disposition: 'loss_recorded', sequence: 1 });
		expect(producer.record(diagnosticSample)).toEqual({
			disposition: 'loss_recorded',
			sequence: 2,
		});
		expect(send).toHaveBeenCalledWith({
			type: 'loss.summary',
			controlSequence: 1,
			lostSequenceStart: 1,
			lostSequenceEnd: 1,
			requiredCount: 1,
			optionalCount: 0,
			reason: 'credit_exhausted',
		});
		expect(producer.flushLossSummary()).toBe(true);
		expect(send).toHaveBeenCalledWith({
			type: 'loss.summary',
			controlSequence: 2,
			lostSequenceStart: 2,
			lostSequenceEnd: 2,
			requiredCount: 0,
			optionalCount: 1,
			reason: 'credit_exhausted',
		});
		expect(send.mock.calls.map(([message]) => message)).toHaveLength(2);
		expect(JSON.stringify(send.mock.calls)).not.toContain('attempt-2');
	});

	it('does not lose pending loss ranges when control credit is exhausted', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			send,
		});
		producer.record(lifecycleSample);

		expect(producer.flushLossSummary()).toBe(false);
		expect(producer.snapshot().pendingLossRange).toEqual({
			start: 1,
			end: 1,
			requiredCount: 1,
			optionalCount: 0,
		});
		producer.grantControlCredits(1);
		expect(producer.flushLossSummary()).toBe(true);
		expect(send).toHaveBeenCalledTimes(1);
	});

	it('seals behind a worker barrier and reports pre-seal plus post-seal loss', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 0,
			initialSampleCredits: 0,
			preReadyRequiredSampleCapacity: 1,
			preReadyRequiredSampleMaxEncodedBytes: 16 * 1024,
			send,
		});
		producer.acceptWorkerCommand({
			type: 'producer.ready',
			generation: 1,
			initialSampleCredits: 0,
			initialControlCredits: 0,
		});
		producer.record(lifecycleSample);

		expect(
			producer.acceptWorkerCommand({
				type: 'producer.barrier.request',
				barrierId: 'barrier-main-1',
				generation: 1,
			}),
		).toBe(true);
		producer.record(lifecycleSample);
		expect(
			producer.acceptWorkerCommand({
				type: 'producer.settlement.request',
				barrierId: 'barrier-main-1',
				generation: 1,
				disposition: 'reopen',
				sampleCredits: 2,
				controlCredits: 1,
			}),
		).toBe(true);
		expect(send.mock.calls.map(([message]) => message)).toEqual([
			{
				type: 'producer.barrier.receipt',
				barrierId: 'barrier-main-1',
				generation: 1,
				producerSequenceHighWatermark: 1,
				preSealLossRange: {
					lostSequenceStart: 1,
					lostSequenceEnd: 1,
					requiredCount: 1,
					optionalCount: 0,
				},
			},
			{
				type: 'producer.settlement.receipt',
				barrierId: 'barrier-main-1',
				generation: 1,
				producerSequenceHighWatermark: 2,
				postSealLossRange: {
					lostSequenceStart: 2,
					lostSequenceEnd: 2,
					requiredCount: 1,
					optionalCount: 0,
				},
			},
		]);
		expect(producer.snapshot()).toMatchObject({
			state: 'active',
			nextSequence: 3,
			availableSampleCredits: 2,
			availableControlCredits: 1,
		});
	});

	it('refills only through explicit worker grants and rejects posts after close', () => {
		const send = vi.fn();
		const producer = createBridgeTelemetryWorkerProducer({
			initialControlCredits: 1,
			initialSampleCredits: 0,
			send,
		});
		producer.grantSampleCredits(1);
		expect(producer.record(diagnosticSample).disposition).toBe('posted');
		producer.close();
		expect(producer.record(diagnosticSample)).toEqual({ disposition: 'closed', sequence: 2 });
		expect(send).toHaveBeenCalledTimes(1);
	});
});

function encodedSampleByteLength(sample: object): number {
	return new TextEncoder().encode(JSON.stringify(sample)).byteLength;
}

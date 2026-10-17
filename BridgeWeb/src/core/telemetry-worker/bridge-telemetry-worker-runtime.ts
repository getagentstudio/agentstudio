import {
	bridgeTelemetryWorkerProducerMessageSchema,
	isRequiredBridgeTelemetrySample,
	type BridgeTelemetryCompactSample,
	type BridgeTelemetryProducerInstallation,
	type BridgeTelemetryWorkerProducerCreditGrants,
	type BridgeTelemetryProducerId,
	type BridgeTelemetryStampedLossSummary,
	type BridgeTelemetryStampedSample,
	type BridgeTelemetryWorkerBatchRequest,
	type BridgeTelemetryWorkerBatchResponse,
	type BridgeTelemetryWorkerBatchTransport,
	type BridgeTelemetryWorkerBootstrap,
	type BridgeTelemetryWorkerDrainResult,
	type BridgeTelemetryWorkerIngressResult,
	type BridgeTelemetryLossDiagnostic,
	type BridgeTelemetryBatchDeliveryFailureSnapshot,
	type BridgeTelemetryTransportFailureSnapshot,
	type BridgeTelemetryWorkerProducerMessage,
	type BridgeTelemetryWorkerRetryScheduler,
	type BridgeTelemetryWorkerRuntime,
	type BridgeTelemetryWorkerSnapshot,
} from './bridge-telemetry-worker-contracts.js';
import {
	bridgeTelemetryBatchResponseMismatch,
	bridgeTelemetryEncodedBytes,
	encodeBridgeTelemetryBatchRequest,
	makeBridgeTelemetryWorkerDrainResult,
	makeBridgeTelemetryWorkerProducerState,
	makeBridgeTelemetryWorkerProducerSnapshot,
	BridgeTelemetryWorkerProducerCreditGrantLedger,
	type BridgeTelemetryWorkerBufferedLossSummary,
	type BridgeTelemetryWorkerBufferedSample,
	type BridgeTelemetryWorkerOutboxBatch,
	type BridgeTelemetryWorkerProducerState,
} from './bridge-telemetry-worker-runtime-support.js';
import { BridgeTelemetryWorkerTransportError } from './bridge-telemetry-worker-transport.js';
import type { BridgeTelemetryWorkerTransportFailureDetails } from './bridge-telemetry-worker-transport.js';

export class BridgeTelemetryWorkerRuntimeCore implements BridgeTelemetryWorkerRuntime {
	private readonly producers = new Map<
		BridgeTelemetryProducerId,
		BridgeTelemetryWorkerProducerState
	>();
	private readonly bufferedSamples: BridgeTelemetryWorkerBufferedSample[] = [];
	private readonly bufferedLossSummaries: BridgeTelemetryWorkerBufferedLossSummary[] = [];
	private readonly outbox: BridgeTelemetryWorkerOutboxBatch[] = [];
	private readonly lossDiagnostics: BridgeTelemetryLossDiagnostic[] = [];
	private state: BridgeTelemetryWorkerSnapshot['state'] = 'active';
	private proofEligible = true;
	private lossy = false;
	private requiredLossCount = 0;
	private optionalLossCount = 0;
	private sequenceGapCount = 0;
	private bufferedBytes = 0;
	private outboxBytes = 0;
	private nextBatchSequence = 1;
	private acceptedBatchSequence = 0;
	private isPostInFlight = false;
	private lastBatchDeliveryFailure: BridgeTelemetryBatchDeliveryFailureSnapshot | null = null;
	private readonly creditGrantLedger = new BridgeTelemetryWorkerProducerCreditGrantLedger();

	constructor(
		private readonly bootstrap: BridgeTelemetryWorkerBootstrap,
		private readonly transport: BridgeTelemetryWorkerBatchTransport,
		private readonly scheduleRetry: BridgeTelemetryWorkerRetryScheduler,
	) {}

	installProducer(producerId: BridgeTelemetryProducerId): BridgeTelemetryProducerInstallation {
		if (this.producers.has(producerId)) {
			throw new Error(`Telemetry producer already installed: ${producerId}`);
		}
		const state = makeBridgeTelemetryWorkerProducerState(producerId, 1, this.bootstrap.policy);
		this.producers.set(producerId, state);
		return { producerId, generation: state.generation };
	}

	replaceProducer(producerId: BridgeTelemetryProducerId): BridgeTelemetryProducerInstallation {
		const previousProducer = this.producers.get(producerId);
		const previousGeneration = previousProducer?.generation ?? 0;
		if (
			previousProducer !== undefined &&
			previousProducer.barrierHighWatermark !== previousProducer.nextExpectedSequence - 1
		) {
			this.markProofFailure();
		}
		const state = makeBridgeTelemetryWorkerProducerState(
			producerId,
			previousGeneration + 1,
			this.bootstrap.policy,
		);
		this.creditGrantLedger.discard(producerId);
		this.producers.set(producerId, state);
		return { producerId, generation: state.generation };
	}

	async acceptProducerMessage(
		installation: BridgeTelemetryProducerInstallation,
		value: unknown,
	): Promise<BridgeTelemetryWorkerIngressResult> {
		const producer = this.producers.get(installation.producerId);
		if (producer === undefined || producer.generation !== installation.generation) {
			this.markProofFailure();
			return { type: 'rejected', reason: 'revoked_port' };
		}
		const decodedMessage = bridgeTelemetryWorkerProducerMessageSchema.safeParse(value);
		if (!decodedMessage.success) {
			this.markProofFailure();
			return { type: 'rejected', reason: 'invalid_message' };
		}
		if (
			decodedMessage.data.type !== 'producer.barrier.receipt' &&
			decodedMessage.data.type !== 'producer.settlement.receipt' &&
			this.state !== 'active'
		) {
			if (
				decodedMessage.data.type === 'sample' &&
				(producer.barrierHighWatermark !== null ||
					isRequiredBridgeTelemetrySample(decodedMessage.data.sample))
			) {
				this.markProofFailure();
			}
			return { type: 'rejected', reason: 'closed' };
		}
		return this.acceptDecodedMessage(producer, decodedMessage.data);
	}

	prepareProducerBarrier(
		producerId: BridgeTelemetryProducerId,
		barrierId: string,
	): BridgeTelemetryProducerInstallation {
		const producer = this.producers.get(producerId);
		if (producer === undefined) {
			throw new Error(`Telemetry producer is not installed: ${producerId}`);
		}
		producer.expectedBarrierId = barrierId;
		producer.barrierHighWatermark = null;
		producer.settlementReceived = false;
		return { producerId, generation: producer.generation };
	}

	prepareProducerSettlement(producerId: BridgeTelemetryProducerId, barrierId: string): void {
		const producer = this.producers.get(producerId);
		if (producer === undefined || producer.expectedBarrierId !== barrierId) {
			this.markProofFailure();
		}
	}

	producerSettlementReceived(producerId: BridgeTelemetryProducerId): boolean {
		return this.producers.get(producerId)?.settlementReceived ?? false;
	}

	finishDrain(closeAfterDrain: boolean): BridgeTelemetryWorkerDrainResult {
		for (const producer of this.producers.values()) {
			if (!producer.settlementReceived) {
				this.markProofFailure();
			}
		}
		const result = this.currentDrainResult(closeAfterDrain ? 'closed' : 'reopened');
		if (closeAfterDrain) {
			this.state = 'closed';
			return result;
		}
		for (const producer of this.producers.values()) {
			producer.barrierHighWatermark = null;
			producer.expectedBarrierId = null;
			producer.settlementReceived = false;
			producer.availableSampleCredits = this.bootstrap.policy.initialSampleCredits;
			producer.availableControlCredits = this.bootstrap.policy.initialControlCredits;
		}
		this.creditGrantLedger.takeSampleGrants();
		this.creditGrantLedger.takeControlGrants();
		this.state = 'active';
		return result;
	}

	failProof(): void {
		this.markProofFailure();
	}

	takeProducerCreditGrants(): BridgeTelemetryWorkerProducerCreditGrants {
		return this.creditGrantLedger.takeSampleGrants();
	}

	takeProducerControlCreditGrants(): BridgeTelemetryWorkerProducerCreditGrants {
		return this.creditGrantLedger.takeControlGrants();
	}

	async flush(): Promise<void> {
		if (this.state === 'closed') {
			return;
		}
		this.stageNextBatch();
		if (this.isPostInFlight) {
			return;
		}
		const batch = this.outbox[0];
		if (batch === undefined) {
			return;
		}
		await this.postOutboxBatch(batch);
	}

	snapshot(): BridgeTelemetryWorkerSnapshot {
		const bufferedSampleBytes = this.bufferedSamples.reduce(
			(total, sample) => total + sample.encodedBytes,
			0,
		);
		const bufferedLossSummaryBytes = this.bufferedLossSummaries.reduce(
			(total, summary) => total + summary.encodedBytes,
			0,
		);
		const headOutbox = this.outbox[0];
		return {
			state: this.state,
			proofEligible: this.proofEligible,
			lossy: this.lossy,
			requiredLossCount: this.requiredLossCount,
			optionalLossCount: this.optionalLossCount,
			sequenceGapCount: this.sequenceGapCount,
			bufferedSampleCount: this.bufferedSamples.length,
			bufferedSampleBytes,
			bufferedLossSummaryCount: this.bufferedLossSummaries.length,
			bufferedLossSummaryBytes,
			bufferedBytes: this.bufferedBytes,
			outboxCount: this.outbox.length,
			outboxBytes: this.outboxBytes,
			isPostInFlight: this.isPostInFlight,
			headOutbox:
				headOutbox === undefined
					? null
					: {
							batchSequence: headOutbox.request.batchSequence,
							retryAttempts: headOutbox.retryAttempts,
							retryScheduled: headOutbox.retryScheduled,
						},
			lastBatchDeliveryFailure: this.lastBatchDeliveryFailure,
			nextBatchSequence: this.nextBatchSequence,
			acceptedBatchSequence: this.acceptedBatchSequence,
			lossDiagnostics: [...this.lossDiagnostics],
			producers: {
				main: makeBridgeTelemetryWorkerProducerSnapshot(this.producers.get('main')),
				comm: makeBridgeTelemetryWorkerProducerSnapshot(this.producers.get('comm')),
			},
		};
	}

	async drain(): Promise<BridgeTelemetryWorkerDrainResult> {
		await this.drainBufferedForSettlement();
		return this.finishDrain(false);
	}

	async drainAndClose(): Promise<BridgeTelemetryWorkerDrainResult> {
		await this.drainBufferedForSettlement();
		return this.finishDrain(true);
	}

	async drainBufferedForSettlement(): Promise<void> {
		if (this.state === 'closed') {
			return;
		}
		this.state = 'draining';
		for (const producer of this.producers.values()) {
			if (producer.barrierHighWatermark !== producer.nextExpectedSequence - 1) {
				this.sequenceGapCount += 1;
				this.markProofFailure();
			}
		}
		const maximumDrainPasses =
			this.bootstrap.policy.outboxMaxCount + this.bootstrap.policy.maxRetryAttempts + 2;
		await this.drainBufferedState(maximumDrainPasses);
		if (
			this.bufferedSamples.length > 0 ||
			this.bufferedLossSummaries.length > 0 ||
			this.outbox.length > 0
		) {
			this.markProofFailure();
		}
	}

	private acceptDecodedMessage(
		producer: BridgeTelemetryWorkerProducerState,
		message: BridgeTelemetryWorkerProducerMessage,
	): BridgeTelemetryWorkerIngressResult {
		switch (message.type) {
			case 'sample':
				return this.acceptSample(producer, message.sequence, message.sample);
			case 'loss.summary':
				return this.acceptLossSummary(producer, message);
			case 'producer.barrier.receipt':
				return this.acceptBarrierReceipt(producer, message);
			case 'producer.settlement.receipt':
				return this.acceptSettlementReceipt(producer, message);
		}
		throw new Error('Unreachable telemetry producer message');
	}

	private async drainBufferedState(remainingPasses: number): Promise<void> {
		if (remainingPasses === 0) {
			this.markProofFailure();
			return;
		}
		const before =
			this.bufferedSamples.length + this.bufferedLossSummaries.length + this.outbox.length;
		await this.flush();
		const after =
			this.bufferedSamples.length + this.bufferedLossSummaries.length + this.outbox.length;
		if (after === 0) {
			return;
		}
		if (after >= before) {
			this.markProofFailure();
			return;
		}
		await this.drainBufferedState(remainingPasses - 1);
	}

	private acceptSample(
		producer: BridgeTelemetryWorkerProducerState,
		sequence: number,
		sample: BridgeTelemetryCompactSample,
	): BridgeTelemetryWorkerIngressResult {
		if (producer.barrierHighWatermark !== null) {
			this.markProofFailure();
			return { type: 'rejected', reason: 'closed' };
		}
		const sequenceRejection = this.validateSampleSequence(producer, sequence, sample);
		if (sequenceRejection !== null) {
			return sequenceRejection;
		}
		producer.nextExpectedSequence = sequence + 1;
		const required = isRequiredBridgeTelemetrySample(sample);
		if (producer.availableSampleCredits === 0) {
			this.recordLossDiagnostic({
				origin: 'worker',
				producerId: producer.producerId,
				reason: 'credit_exhausted',
				requiredCount: required ? 1 : 0,
				optionalCount: required ? 0 : 1,
				lastLostSequenceStart: sequence,
				lastLostSequenceEnd: sequence,
			});
			this.recordLoss(required, 1);
			return { type: 'rejected', reason: 'sample_credit_exhausted' };
		}
		producer.availableSampleCredits -= 1;
		const compactSampleBytes = bridgeTelemetryEncodedBytes(sample);
		if (compactSampleBytes > this.bootstrap.policy.compactSampleMaxEncodedBytes) {
			this.recordLossDiagnostic({
				origin: 'worker',
				producerId: producer.producerId,
				reason: 'encoded_byte_cap',
				requiredCount: required ? 1 : 0,
				optionalCount: required ? 0 : 1,
				lastLostSequenceStart: sequence,
				lastLostSequenceEnd: sequence,
			});
			this.recordLoss(required, 1);
			this.returnSampleCredit(producer.producerId, producer.generation);
			return { type: 'rejected', reason: 'sample_too_large' };
		}
		const stamped: BridgeTelemetryStampedSample = {
			producerId: producer.producerId,
			producerSequence: sequence,
			sample,
		};
		const buffered = this.admitBufferedSample({
			stamped,
			producerGeneration: producer.generation,
			encodedBytes: bridgeTelemetryEncodedBytes(stamped),
			required,
		});
		return { type: 'accepted', producerId: producer.producerId, sequence, buffered };
	}

	private acceptLossSummary(
		producer: BridgeTelemetryWorkerProducerState,
		message: Extract<BridgeTelemetryWorkerProducerMessage, { type: 'loss.summary' }>,
	): BridgeTelemetryWorkerIngressResult {
		const controlRejection = this.consumeControlSequence(producer, message.controlSequence);
		if (controlRejection !== null) {
			return controlRejection;
		}
		const rangeCount = message.lostSequenceEnd - message.lostSequenceStart + 1;
		if (
			message.lostSequenceStart !== producer.nextExpectedSequence ||
			rangeCount !== message.requiredCount + message.optionalCount
		) {
			this.sequenceGapCount += 1;
			this.markProofFailure();
			return { type: 'rejected', reason: 'invalid_loss_summary' };
		}
		producer.nextExpectedSequence = message.lostSequenceEnd + 1;
		this.recordLossDiagnostic({
			origin: 'producer',
			producerId: producer.producerId,
			reason: message.reason,
			requiredCount: message.requiredCount,
			optionalCount: message.optionalCount,
			lastLostSequenceStart: message.lostSequenceStart,
			lastLostSequenceEnd: message.lostSequenceEnd,
		});
		this.recordLossCounts(message.requiredCount, message.optionalCount);
		const stamped: BridgeTelemetryStampedLossSummary = {
			producerId: producer.producerId,
			lostSequenceStart: message.lostSequenceStart,
			lostSequenceEnd: message.lostSequenceEnd,
			requiredCount: message.requiredCount,
			optionalCount: message.optionalCount,
			reason: message.reason,
		};
		const encodedSummaryBytes = bridgeTelemetryEncodedBytes(stamped);
		this.bufferedLossSummaries.push({ stamped, encodedBytes: encodedSummaryBytes });
		this.bufferedBytes += encodedSummaryBytes;
		this.returnControlCredit(producer.producerId, producer.generation);
		return {
			type: 'accepted',
			producerId: producer.producerId,
			sequence: message.lostSequenceEnd,
			buffered: true,
		};
	}

	private acceptBarrierReceipt(
		producer: BridgeTelemetryWorkerProducerState,
		message: Extract<BridgeTelemetryWorkerProducerMessage, { type: 'producer.barrier.receipt' }>,
	): BridgeTelemetryWorkerIngressResult {
		if (
			message.generation !== producer.generation ||
			message.barrierId !== producer.expectedBarrierId
		) {
			this.markProofFailure();
			return { type: 'rejected', reason: 'invalid_message' };
		}
		if (!this.acceptReceiptLossRange(producer, message.preSealLossRange)) {
			return { type: 'rejected', reason: 'sequence_gap' };
		}
		if (message.preSealLossRange !== null) {
			this.recordLossCounts(
				message.preSealLossRange.requiredCount,
				message.preSealLossRange.optionalCount,
			);
		}
		if (message.producerSequenceHighWatermark !== producer.nextExpectedSequence - 1) {
			this.sequenceGapCount += 1;
			this.markProofFailure();
			return { type: 'rejected', reason: 'sequence_gap' };
		}
		producer.barrierHighWatermark = message.producerSequenceHighWatermark;
		return {
			type: 'accepted',
			producerId: producer.producerId,
			sequence: message.producerSequenceHighWatermark,
			buffered: message.preSealLossRange !== null,
		};
	}

	private acceptSettlementReceipt(
		producer: BridgeTelemetryWorkerProducerState,
		message: Extract<BridgeTelemetryWorkerProducerMessage, { type: 'producer.settlement.receipt' }>,
	): BridgeTelemetryWorkerIngressResult {
		if (
			message.generation !== producer.generation ||
			message.barrierId !== producer.expectedBarrierId
		) {
			this.markProofFailure();
			return { type: 'rejected', reason: 'invalid_message' };
		}
		if (!this.acceptReceiptLossRange(producer, message.postSealLossRange)) {
			return { type: 'rejected', reason: 'sequence_gap' };
		}
		if (message.producerSequenceHighWatermark !== producer.nextExpectedSequence - 1) {
			this.sequenceGapCount += 1;
			this.markProofFailure();
			return { type: 'rejected', reason: 'sequence_gap' };
		}
		producer.settlementReceived = true;
		return {
			type: 'accepted',
			producerId: producer.producerId,
			sequence: message.producerSequenceHighWatermark,
			buffered: message.postSealLossRange !== null,
		};
	}

	private acceptReceiptLossRange(
		producer: BridgeTelemetryWorkerProducerState,
		range: {
			readonly lostSequenceStart: number;
			readonly lostSequenceEnd: number;
			readonly requiredCount: number;
			readonly optionalCount: number;
		} | null,
	): boolean {
		if (range === null) {
			return true;
		}
		const rangeCount = range.lostSequenceEnd - range.lostSequenceStart + 1;
		if (
			range.lostSequenceStart !== producer.nextExpectedSequence ||
			rangeCount !== range.requiredCount + range.optionalCount
		) {
			this.sequenceGapCount += 1;
			this.markProofFailure();
			return false;
		}
		producer.nextExpectedSequence = range.lostSequenceEnd + 1;
		return true;
	}

	private validateSampleSequence(
		producer: BridgeTelemetryWorkerProducerState,
		sequence: number,
		sample: BridgeTelemetryCompactSample,
	): BridgeTelemetryWorkerIngressResult | null {
		if (sequence < producer.nextExpectedSequence) {
			this.markProofFailure();
			return { type: 'rejected', reason: 'duplicate_sequence' };
		}
		if (sequence > producer.nextExpectedSequence) {
			this.sequenceGapCount += 1;
			const missingSequenceCount = sequence - producer.nextExpectedSequence;
			this.recordLossCounts(
				missingSequenceCount + (isRequiredBridgeTelemetrySample(sample) ? 1 : 0),
				isRequiredBridgeTelemetrySample(sample) ? 0 : 1,
			);
			producer.nextExpectedSequence = sequence + 1;
			return { type: 'rejected', reason: 'sequence_gap' };
		}
		return null;
	}

	private consumeControlSequence(
		producer: BridgeTelemetryWorkerProducerState,
		controlSequence: number,
	): BridgeTelemetryWorkerIngressResult | null {
		if (controlSequence !== producer.nextExpectedControlSequence) {
			this.sequenceGapCount += 1;
			this.markProofFailure();
			return { type: 'rejected', reason: 'duplicate_control_sequence' };
		}
		producer.nextExpectedControlSequence += 1;
		if (producer.availableControlCredits === 0) {
			this.markProofFailure();
			return { type: 'rejected', reason: 'control_credit_exhausted' };
		}
		producer.availableControlCredits -= 1;
		return null;
	}

	private admitBufferedSample(sample: BridgeTelemetryWorkerBufferedSample): boolean {
		while (!this.sampleFitsBuffer(sample)) {
			const optionalIndex = this.bufferedSamples.findIndex((candidate) => !candidate.required);
			if (optionalIndex === -1) {
				this.recordBufferedSampleLossDiagnostic(sample, 'queue_saturated');
				this.recordLoss(sample.required, 1);
				this.returnSampleCredit(sample.stamped.producerId, sample.producerGeneration);
				return false;
			}
			const [shedSample] = this.bufferedSamples.splice(optionalIndex, 1);
			if (shedSample !== undefined) {
				this.bufferedBytes -= shedSample.encodedBytes;
				this.recordBufferedSampleLossDiagnostic(shedSample, 'queue_saturated');
				this.recordLoss(false, 1);
				this.returnSampleCredit(shedSample.stamped.producerId, shedSample.producerGeneration);
			}
		}
		this.bufferedSamples.push(sample);
		this.bufferedBytes += sample.encodedBytes;
		return true;
	}

	private sampleFitsBuffer(sample: BridgeTelemetryWorkerBufferedSample): boolean {
		return (
			this.bufferedSamples.length < this.bootstrap.policy.workerBufferMaxSamples &&
			this.bufferedBytes + sample.encodedBytes <= this.bootstrap.policy.workerBufferMaxBytes
		);
	}

	private stageNextBatch(): void {
		if (this.bufferedSamples.length === 0 && this.bufferedLossSummaries.length === 0) {
			return;
		}
		const samples = this.takeSamplesForBatch();
		const lossSummaries = this.takeLossSummariesForBatch(samples);
		if (samples.length === 0 && lossSummaries.length === 0) {
			this.shedUnbatchableBuffer();
			return;
		}
		const fittedBatch = this.fitBatchToEncodedByteCap(samples, lossSummaries);
		if (fittedBatch === null) {
			return;
		}
		const { request, encodedBody } = fittedBatch;
		if (
			this.outbox.length >= this.bootstrap.policy.outboxMaxCount ||
			this.outboxBytes + encodedBody.byteLength > this.bootstrap.policy.outboxMaxBytes
		) {
			for (const sample of samples) {
				this.recordBufferedSampleLossDiagnostic(sample, 'outbox_saturated');
			}
			this.accountOutboxLoss(samples);
			return;
		}
		this.nextBatchSequence += 1;
		this.outbox.push({
			request,
			encodedBody,
			samples,
			lossSummaries,
			retryAttempts: 0,
			retryScheduled: false,
		});
		this.outboxBytes += encodedBody.byteLength;
	}

	private fitBatchToEncodedByteCap(
		samples: BridgeTelemetryWorkerBufferedSample[],
		lossSummaries: BridgeTelemetryWorkerBufferedLossSummary[],
	): {
		readonly request: BridgeTelemetryWorkerBatchRequest;
		readonly encodedBody: Uint8Array;
	} | null {
		while (samples.length > 0 || lossSummaries.length > 0) {
			const request: BridgeTelemetryWorkerBatchRequest = {
				type: 'telemetry.batch',
				schemaVersion: 2,
				telemetrySessionId: this.bootstrap.telemetrySessionId,
				batchSequence: this.nextBatchSequence,
				samples: samples.map((sample) => sample.stamped),
				lossSummaries: lossSummaries.map((summary) => summary.stamped),
			};
			const encodedBody = encodeBridgeTelemetryBatchRequest(request);
			if (encodedBody.byteLength <= this.bootstrap.policy.batchMaxBytes) {
				return { request, encodedBody };
			}
			const deferredLossSummary = lossSummaries.pop();
			if (deferredLossSummary !== undefined) {
				if (samples.length === 0 && lossSummaries.length === 0) {
					this.markProofFailure();
					return null;
				}
				this.bufferedLossSummaries.unshift(deferredLossSummary);
				this.bufferedBytes += deferredLossSummary.encodedBytes;
				continue;
			}
			if (samples.length > 1) {
				const deferredSample = samples.pop();
				if (deferredSample !== undefined) {
					this.bufferedSamples.unshift(deferredSample);
					this.bufferedBytes += deferredSample.encodedBytes;
				}
				continue;
			}
			const unbatchableSample = samples.pop();
			if (unbatchableSample !== undefined) {
				this.recordBufferedSampleLossDiagnostic(unbatchableSample, 'encoded_byte_cap');
				this.recordLoss(unbatchableSample.required, 1);
				this.returnSampleCredit(
					unbatchableSample.stamped.producerId,
					unbatchableSample.producerGeneration,
				);
			} else {
				this.markProofFailure();
			}
		}
		return null;
	}

	private takeSamplesForBatch(): BridgeTelemetryWorkerBufferedSample[] {
		const samples: BridgeTelemetryWorkerBufferedSample[] = [];
		let approximateBytes = 0;
		while (samples.length < this.bootstrap.policy.batchMaxSamples) {
			const candidate = this.bufferedSamples[0];
			if (
				candidate === undefined ||
				approximateBytes + candidate.encodedBytes > this.bootstrap.policy.batchMaxBytes
			) {
				break;
			}
			this.bufferedSamples.shift();
			this.bufferedBytes -= candidate.encodedBytes;
			samples.push(candidate);
			approximateBytes += candidate.encodedBytes;
		}
		return samples;
	}

	private takeLossSummariesForBatch(
		samples: readonly BridgeTelemetryWorkerBufferedSample[],
	): BridgeTelemetryWorkerBufferedLossSummary[] {
		const summaries: BridgeTelemetryWorkerBufferedLossSummary[] = [];
		let approximateBytes = samples.reduce((total, sample) => total + sample.encodedBytes, 0);
		while (summaries.length + samples.length < this.bootstrap.policy.batchMaxSamples) {
			const candidate = this.bufferedLossSummaries[0];
			if (
				candidate === undefined ||
				approximateBytes + candidate.encodedBytes > this.bootstrap.policy.batchMaxBytes
			) {
				break;
			}
			this.bufferedLossSummaries.shift();
			this.bufferedBytes -= candidate.encodedBytes;
			summaries.push(candidate);
			approximateBytes += candidate.encodedBytes;
		}
		return summaries;
	}

	private shedUnbatchableBuffer(): void {
		for (const sample of this.bufferedSamples.splice(0)) {
			this.recordBufferedSampleLossDiagnostic(sample, 'encoded_byte_cap');
			this.recordLoss(sample.required, 1);
			this.returnSampleCredit(sample.stamped.producerId, sample.producerGeneration);
		}
		this.bufferedLossSummaries.splice(0);
		this.bufferedBytes = 0;
	}

	private accountOutboxLoss(samples: readonly BridgeTelemetryWorkerBufferedSample[]): void {
		for (const sample of samples) {
			this.recordLoss(sample.required, 1);
			this.returnSampleCredit(sample.stamped.producerId, sample.producerGeneration);
		}
	}

	private async postOutboxBatch(batch: BridgeTelemetryWorkerOutboxBatch): Promise<void> {
		this.isPostInFlight = true;
		try {
			const response = await this.transport.postBatch(
				batch.request,
				batch.encodedBody,
				this.bootstrap.telemetryCapability,
			);
			this.handleBatchResponse(batch, response);
		} catch (error) {
			this.handleBatchFailure(batch, error);
		} finally {
			this.isPostInFlight = false;
		}
	}

	private handleBatchResponse(
		batch: BridgeTelemetryWorkerOutboxBatch,
		response: BridgeTelemetryWorkerBatchResponse,
	): void {
		const mismatchField = bridgeTelemetryBatchResponseMismatch(response, batch.request);
		if (mismatchField !== null) {
			this.lastBatchDeliveryFailure = {
				kind: 'response_mismatch',
				batchSequence: batch.request.batchSequence,
				retryAttempts: batch.retryAttempts,
				mismatchField,
			};
			this.failOutboxBatch(batch);
			return;
		}
		if (response.type === 'rejected') {
			if (response.retryable) {
				this.handleBatchFailure(batch, undefined, response);
			} else {
				this.lastBatchDeliveryFailure = {
					kind: 'native_rejection',
					batchSequence: batch.request.batchSequence,
					retryAttempts: batch.retryAttempts,
					reason: response.reason,
					retryable: false,
				};
				this.failOutboxBatch(batch);
			}
			return;
		}
		if (response.type === 'accepted_with_loss') {
			this.recordLossCounts(response.nativeRequiredLossCount, response.nativeOptionalLossCount);
		}
		this.acceptedBatchSequence = batch.request.batchSequence;
		for (const sample of batch.samples) {
			this.returnSampleCredit(sample.stamped.producerId, sample.producerGeneration);
		}
		this.removeOutboxBatch(batch);
	}

	private handleBatchFailure(
		batch: BridgeTelemetryWorkerOutboxBatch,
		error?: unknown,
		nativeRejection?: Extract<BridgeTelemetryWorkerBatchResponse, { readonly type: 'rejected' }>,
	): void {
		batch.retryAttempts += 1;
		if (error instanceof BridgeTelemetryWorkerTransportError) {
			this.lastBatchDeliveryFailure = {
				kind: 'transport',
				transport: transportFailureSnapshot(error.details, batch.retryAttempts),
			};
		} else if (nativeRejection !== undefined) {
			this.lastBatchDeliveryFailure = {
				kind: 'native_rejection',
				batchSequence: batch.request.batchSequence,
				retryAttempts: batch.retryAttempts,
				reason: nativeRejection.reason,
				retryable: true,
			};
		}
		if (batch.retryAttempts >= this.bootstrap.policy.maxRetryAttempts) {
			this.failOutboxBatch(batch);
			return;
		}
		if (batch.retryScheduled) {
			return;
		}
		batch.retryScheduled = true;
		this.scheduleRetry(async (): Promise<void> => {
			batch.retryScheduled = false;
			if (this.outbox[0] === batch && this.state !== 'closed') {
				await this.postOutboxBatch(batch);
			}
		}, batch.retryAttempts);
	}

	private failOutboxBatch(batch: BridgeTelemetryWorkerOutboxBatch): void {
		if (!this.outbox.includes(batch)) {
			return;
		}
		this.markProofFailure();
		this.state = 'closed';
		for (const pendingBatch of this.outbox.splice(0)) {
			for (const sample of pendingBatch.samples) {
				this.recordBufferedSampleLossDiagnostic(sample, 'transport_retry_exhausted');
				this.recordLoss(sample.required, 1);
			}
		}
		for (const sample of this.bufferedSamples.splice(0)) {
			this.recordBufferedSampleLossDiagnostic(sample, 'transport_retry_exhausted');
			this.recordLoss(sample.required, 1);
		}
		this.bufferedLossSummaries.splice(0);
		this.bufferedBytes = 0;
		this.outboxBytes = 0;
	}

	private removeOutboxBatch(batch: BridgeTelemetryWorkerOutboxBatch): void {
		const index = this.outbox.indexOf(batch);
		if (index === -1) {
			return;
		}
		this.outbox.splice(index, 1);
		this.outboxBytes -= batch.encodedBody.byteLength;
	}

	private recordLoss(required: boolean, count: number): void {
		this.recordLossCounts(required ? count : 0, required ? 0 : count);
	}

	private recordBufferedSampleLossDiagnostic(
		sample: BridgeTelemetryWorkerBufferedSample,
		reason: BridgeTelemetryLossDiagnostic['reason'],
	): void {
		this.recordLossDiagnostic({
			origin: 'worker',
			producerId: sample.stamped.producerId,
			reason,
			requiredCount: sample.required ? 1 : 0,
			optionalCount: sample.required ? 0 : 1,
			lastLostSequenceStart: sample.stamped.producerSequence,
			lastLostSequenceEnd: sample.stamped.producerSequence,
		});
	}

	private recordLossDiagnostic(diagnostic: BridgeTelemetryLossDiagnostic): void {
		const existingIndex = this.lossDiagnostics.findIndex(
			(existing) =>
				existing.origin === diagnostic.origin &&
				existing.producerId === diagnostic.producerId &&
				existing.reason === diagnostic.reason,
		);
		if (existingIndex >= 0) {
			const existing = this.lossDiagnostics[existingIndex];
			if (existing !== undefined) {
				this.lossDiagnostics[existingIndex] = {
					...diagnostic,
					requiredCount: existing.requiredCount + diagnostic.requiredCount,
					optionalCount: existing.optionalCount + diagnostic.optionalCount,
				};
			}
			return;
		}
		if (this.lossDiagnostics.length < 16) {
			this.lossDiagnostics.push(diagnostic);
		}
	}

	private recordLossCounts(requiredCount: number, optionalCount: number): void {
		this.requiredLossCount += requiredCount;
		this.optionalLossCount += optionalCount;
		if (requiredCount > 0) {
			this.markProofFailure();
		}
		if (optionalCount > 0) {
			this.lossy = true;
		}
	}

	private markProofFailure(): void {
		this.proofEligible = false;
	}

	private returnSampleCredit(producerId: BridgeTelemetryProducerId, generation: number): void {
		const producer = this.producers.get(producerId);
		if (producer !== undefined && producer.generation === generation) {
			producer.availableSampleCredits += 1;
			this.creditGrantLedger.recordSampleGrant(producerId);
		}
	}

	private returnControlCredit(producerId: BridgeTelemetryProducerId, generation: number): void {
		const producer = this.producers.get(producerId);
		if (producer !== undefined && producer.generation === generation) {
			producer.availableControlCredits += 1;
			this.creditGrantLedger.recordControlGrant(producerId);
		}
	}

	private currentDrainResult(
		settlementDisposition: 'closed' | 'reopened',
	): BridgeTelemetryWorkerDrainResult {
		return makeBridgeTelemetryWorkerDrainResult({
			proofEligible: this.proofEligible,
			settlementDisposition,
			requiredLossCount: this.requiredLossCount,
			optionalLossCount: this.optionalLossCount,
			sequenceGapCount: this.sequenceGapCount,
			acceptedBatchSequence: this.acceptedBatchSequence,
			mainProducer: this.producers.get('main'),
			commProducer: this.producers.get('comm'),
		});
	}
}

function transportFailureSnapshot(
	details: BridgeTelemetryWorkerTransportFailureDetails,
	retryAttempts: number,
): BridgeTelemetryTransportFailureSnapshot {
	return { ...details, retryAttempts };
}

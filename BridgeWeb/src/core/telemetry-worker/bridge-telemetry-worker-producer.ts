import {
	isRequiredBridgeTelemetrySample,
	type BridgeTelemetryCompactSample,
	type BridgeTelemetryLossReason,
	type BridgeTelemetryWorkerProducerCommand,
	type BridgeTelemetryWorkerProducerMessage,
} from './bridge-telemetry-worker-contracts.js';
import { bridgeTelemetryWorkerProducerCommandSchema } from './bridge-telemetry-worker-contracts.js';

export interface BridgeTelemetryWorkerProducerSnapshot {
	readonly state: 'active' | 'closed' | 'sealed';
	readonly generation: number | null;
	readonly nextSequence: number;
	readonly nextControlSequence: number;
	readonly availableSampleCredits: number;
	readonly availableControlCredits: number;
	readonly pendingLossRange: {
		readonly start: number;
		readonly end: number;
		readonly requiredCount: number;
		readonly optionalCount: number;
	} | null;
	readonly retainedPreReadyRequiredSampleCount: number;
	readonly retainedPreReadyRequiredSampleEncodedBytes: number;
	readonly postSealLossRange: {
		readonly start: number;
		readonly end: number;
		readonly requiredCount: number;
		readonly optionalCount: number;
	} | null;
}

export type BridgeTelemetryWorkerProducerRecordResult =
	| { readonly disposition: 'posted'; readonly sequence: number }
	| { readonly disposition: 'retained'; readonly sequence: number }
	| { readonly disposition: 'loss_recorded'; readonly sequence: number }
	| { readonly disposition: 'closed'; readonly sequence: number };

export interface BridgeTelemetryWorkerProducer {
	readonly record: (
		sample: BridgeTelemetryCompactSample,
	) => BridgeTelemetryWorkerProducerRecordResult;
	readonly recordPriorLoss: (input: {
		readonly requiredCount: number;
		readonly optionalCount: number;
		readonly reason: BridgeTelemetryLossReason;
	}) => void;
	readonly flushLossSummary: () => boolean;
	readonly grantSampleCredits: (count: number) => void;
	readonly grantControlCredits: (count: number) => void;
	readonly acceptWorkerCommand: (value: unknown) => boolean;
	readonly snapshot: () => BridgeTelemetryWorkerProducerSnapshot;
	readonly close: () => void;
}

export interface CreateBridgeTelemetryWorkerProducerProps {
	readonly initialSampleCredits: number;
	readonly initialControlCredits: number;
	readonly send: (message: BridgeTelemetryWorkerProducerMessage) => void;
	readonly preReadyRequiredSampleCapacity?: number;
	readonly preReadyRequiredSampleMaxEncodedBytes?: number;
}

interface MutableLossRange {
	start: number;
	end: number;
	requiredCount: number;
	optionalCount: number;
}

interface WireLossRange {
	readonly lostSequenceStart: number;
	readonly lostSequenceEnd: number;
	readonly requiredCount: number;
	readonly optionalCount: number;
}

type PreReadyEntry =
	| {
			readonly kind: 'sample';
			readonly sample: BridgeTelemetryCompactSample;
			readonly encodedBytes: number;
			readonly sequence: number;
	  }
	| {
			readonly kind: 'loss';
			readonly range: MutableLossRange;
			readonly reason: BridgeTelemetryLossReason;
	  };

function appendLoss(
	range: MutableLossRange | null,
	sequence: number,
	required: boolean,
): MutableLossRange {
	if (range === null) {
		return {
			start: sequence,
			end: sequence,
			requiredCount: required ? 1 : 0,
			optionalCount: required ? 0 : 1,
		};
	}
	range.end = sequence;
	range.requiredCount += required ? 1 : 0;
	range.optionalCount += required ? 0 : 1;
	return range;
}

function wireLossRange(range: MutableLossRange | null): WireLossRange | null {
	return range === null
		? null
		: {
				lostSequenceStart: range.start,
				lostSequenceEnd: range.end,
				requiredCount: range.requiredCount,
				optionalCount: range.optionalCount,
			};
}

export function createBridgeTelemetryWorkerProducer(
	props: CreateBridgeTelemetryWorkerProducerProps,
): BridgeTelemetryWorkerProducer {
	assertCreditCount(props.initialSampleCredits);
	assertCreditCount(props.initialControlCredits);
	const preReadyRequiredSampleCapacity = props.preReadyRequiredSampleCapacity ?? 0;
	const preReadyRequiredSampleMaxEncodedBytes = props.preReadyRequiredSampleMaxEncodedBytes ?? 0;
	const boundedRequiredRetentionEnabled =
		preReadyRequiredSampleCapacity > 0 && preReadyRequiredSampleMaxEncodedBytes > 0;
	assertCreditCount(preReadyRequiredSampleCapacity);
	assertCreditCount(preReadyRequiredSampleMaxEncodedBytes);
	let state: BridgeTelemetryWorkerProducerSnapshot['state'] = 'active';
	let generation: number | null = null;
	let nextSequence = 1;
	let nextControlSequence = 1;
	let availableSampleCredits = props.initialSampleCredits;
	let availableControlCredits = props.initialControlCredits;
	let pendingLossRange: MutableLossRange | null = null;
	let postSealLossRange: MutableLossRange | null = null;
	let activeBarrierId: string | null = null;
	const preReadyEntries: PreReadyEntry[] = [];
	let retainedPreReadyRequiredSampleCount = 0;
	let retainedPreReadyRequiredSampleEncodedBytes = 0;

	const appendPreReadyLoss = (
		sequence: number,
		required: boolean,
		reason: BridgeTelemetryLossReason,
	): void => {
		const tail = preReadyEntries.at(-1);
		if (tail?.kind === 'loss' && tail.reason === reason && tail.range.end + 1 === sequence) {
			appendLoss(tail.range, sequence, required);
			return;
		}
		preReadyEntries.push({ kind: 'loss', range: appendLoss(null, sequence, required), reason });
	};

	const retainRequiredSampleOrRecordLoss = (
		sample: BridgeTelemetryCompactSample,
		sequence: number,
		optionalLossReason: BridgeTelemetryLossReason,
	): BridgeTelemetryWorkerProducerRecordResult => {
		const required = isRequiredBridgeTelemetrySample(sample);
		if (!required) {
			appendPreReadyLoss(sequence, false, optionalLossReason);
			return { disposition: 'loss_recorded', sequence };
		}
		const encodedBytes = encodedTelemetrySampleBytes(sample);
		if (encodedBytes === null || encodedBytes > preReadyRequiredSampleMaxEncodedBytes) {
			appendPreReadyLoss(sequence, true, 'encoded_byte_cap');
			return { disposition: 'loss_recorded', sequence };
		}
		if (
			retainedPreReadyRequiredSampleCount >= preReadyRequiredSampleCapacity ||
			retainedPreReadyRequiredSampleEncodedBytes + encodedBytes >
				preReadyRequiredSampleMaxEncodedBytes
		) {
			appendPreReadyLoss(sequence, true, optionalLossReason);
			return { disposition: 'loss_recorded', sequence };
		}
		preReadyEntries.push({ encodedBytes, kind: 'sample', sample, sequence });
		retainedPreReadyRequiredSampleCount += 1;
		retainedPreReadyRequiredSampleEncodedBytes += encodedBytes;
		return { disposition: 'retained', sequence };
	};

	const drainPreReadyEntries = (): void => {
		if (state !== 'active' || generation === null) return;
		while (preReadyEntries.length > 0) {
			const entry = preReadyEntries[0];
			if (entry?.kind === 'sample') {
				if (availableSampleCredits === 0) return;
				availableSampleCredits -= 1;
				retainedPreReadyRequiredSampleCount -= 1;
				retainedPreReadyRequiredSampleEncodedBytes -= entry.encodedBytes;
				preReadyEntries.shift();
				props.send({ type: 'sample', sequence: entry.sequence, sample: entry.sample });
				continue;
			}
			if (entry?.kind === 'loss') {
				if (availableControlCredits === 0) return;
				availableControlCredits -= 1;
				preReadyEntries.shift();
				props.send({
					type: 'loss.summary',
					controlSequence: nextControlSequence,
					lostSequenceStart: entry.range.start,
					lostSequenceEnd: entry.range.end,
					requiredCount: entry.range.requiredCount,
					optionalCount: entry.range.optionalCount,
					reason: entry.reason,
				});
				nextControlSequence += 1;
				continue;
			}
			return;
		}
	};

	const collapsePreReadyEntriesIntoPendingLoss = (): void => {
		for (const entry of preReadyEntries.splice(0)) {
			if (entry.kind === 'sample') {
				pendingLossRange = appendLoss(pendingLossRange, entry.sequence, true);
				continue;
			}
			for (let sequence = entry.range.start; sequence <= entry.range.end; sequence += 1) {
				const requiredOffset = sequence - entry.range.start < entry.range.requiredCount;
				pendingLossRange = appendLoss(pendingLossRange, sequence, requiredOffset);
			}
		}
		retainedPreReadyRequiredSampleCount = 0;
		retainedPreReadyRequiredSampleEncodedBytes = 0;
	};

	const seal = (): boolean => {
		if (state === 'closed') {
			return false;
		}
		drainPreReadyEntries();
		collapsePreReadyEntriesIntoPendingLoss();
		state = 'sealed';
		availableSampleCredits = 0;
		availableControlCredits = 0;
		return true;
	};

	const producer: BridgeTelemetryWorkerProducer = {
		recordPriorLoss: ({ requiredCount, optionalCount, reason }): void => {
			const lostCount = requiredCount + optionalCount;
			if (
				state !== 'active' ||
				generation !== null ||
				!Number.isSafeInteger(requiredCount) ||
				requiredCount < 0 ||
				!Number.isSafeInteger(optionalCount) ||
				optionalCount < 0 ||
				!Number.isSafeInteger(nextSequence + lostCount)
			) {
				throw new Error('Invalid prior telemetry loss range');
			}
			if (lostCount === 0) return;
			const start = nextSequence;
			nextSequence += lostCount;
			const tail = preReadyEntries.at(-1);
			if (tail?.kind === 'loss' && tail.reason === reason && tail.range.end + 1 === start) {
				tail.range.end += lostCount;
				tail.range.requiredCount += requiredCount;
				tail.range.optionalCount += optionalCount;
				return;
			}
			preReadyEntries.push({
				kind: 'loss',
				range: {
					start,
					end: nextSequence - 1,
					requiredCount,
					optionalCount,
				},
				reason,
			});
		},
		record: (sample): BridgeTelemetryWorkerProducerRecordResult => {
			const sequence = nextSequence;
			nextSequence += 1;
			if (state === 'closed') {
				return { disposition: 'closed', sequence };
			}
			if (state === 'sealed') {
				postSealLossRange = appendLoss(
					postSealLossRange,
					sequence,
					isRequiredBridgeTelemetrySample(sample),
				);
				return { disposition: 'loss_recorded', sequence };
			}
			if (generation === null && boundedRequiredRetentionEnabled) {
				return retainRequiredSampleOrRecordLoss(sample, sequence, 'queue_saturated');
			}
			drainPreReadyEntries();
			if (
				boundedRequiredRetentionEnabled &&
				(preReadyEntries.length > 0 || availableSampleCredits === 0)
			) {
				return retainRequiredSampleOrRecordLoss(sample, sequence, 'credit_exhausted');
			}
			if (pendingLossRange !== null && !producer.flushLossSummary()) {
				pendingLossRange = appendLoss(
					pendingLossRange,
					sequence,
					isRequiredBridgeTelemetrySample(sample),
				);
				return { disposition: 'loss_recorded', sequence };
			}
			if (availableSampleCredits > 0) {
				availableSampleCredits -= 1;
				props.send({ type: 'sample', sequence, sample });
				return { disposition: 'posted', sequence };
			}
			pendingLossRange = appendLoss(
				pendingLossRange,
				sequence,
				isRequiredBridgeTelemetrySample(sample),
			);
			return { disposition: 'loss_recorded', sequence };
		},
		flushLossSummary: (): boolean => {
			drainPreReadyEntries();
			if (preReadyEntries.length > 0) {
				return false;
			}
			if (pendingLossRange === null) {
				return true;
			}
			if (state === 'closed' || availableControlCredits === 0) {
				return false;
			}
			availableControlCredits -= 1;
			props.send({
				type: 'loss.summary',
				controlSequence: nextControlSequence,
				lostSequenceStart: pendingLossRange.start,
				lostSequenceEnd: pendingLossRange.end,
				requiredCount: pendingLossRange.requiredCount,
				optionalCount: pendingLossRange.optionalCount,
				reason: 'credit_exhausted',
			});
			nextControlSequence += 1;
			pendingLossRange = null;
			return true;
		},
		grantSampleCredits: (count): void => {
			assertPositiveCreditGrant(count);
			if (state === 'active') {
				availableSampleCredits += count;
				drainPreReadyEntries();
			}
		},
		grantControlCredits: (count): void => {
			assertPositiveCreditGrant(count);
			if (state === 'active') {
				availableControlCredits += count;
				drainPreReadyEntries();
			}
		},
		acceptWorkerCommand: (value): boolean => {
			const decoded = bridgeTelemetryWorkerProducerCommandSchema.safeParse(value);
			if (!decoded.success) {
				return false;
			}
			const command: BridgeTelemetryWorkerProducerCommand = decoded.data;
			if (command.type === 'producer.ready') {
				if (generation !== null) return false;
				generation = command.generation;
				if (state === 'active') {
					availableSampleCredits = command.initialSampleCredits;
					availableControlCredits = command.initialControlCredits;
					drainPreReadyEntries();
				}
				return true;
			}
			if (command.type === 'producer.credit-grant') {
				if ('sampleCredits' in command) {
					producer.grantSampleCredits(command.sampleCredits);
				} else {
					producer.grantControlCredits(command.controlCredits);
				}
				return true;
			}
			if (generation !== command.generation) {
				return false;
			}
			if (command.type === 'producer.barrier.request') {
				if (!seal()) {
					return false;
				}
				activeBarrierId = command.barrierId;
				props.send({
					type: 'producer.barrier.receipt',
					barrierId: command.barrierId,
					generation: command.generation,
					producerSequenceHighWatermark: nextSequence - 1,
					preSealLossRange: wireLossRange(pendingLossRange),
				});
				pendingLossRange = null;
				return true;
			}
			if (state !== 'sealed' || activeBarrierId !== command.barrierId) {
				return false;
			}
			props.send({
				type: 'producer.settlement.receipt',
				barrierId: command.barrierId,
				generation: command.generation,
				producerSequenceHighWatermark: nextSequence - 1,
				postSealLossRange: wireLossRange(postSealLossRange),
			});
			postSealLossRange = null;
			activeBarrierId = null;
			if (command.disposition === 'close') {
				producer.close();
			} else {
				state = 'active';
				availableSampleCredits = command.sampleCredits;
				availableControlCredits = command.controlCredits;
			}
			return true;
		},
		snapshot: (): BridgeTelemetryWorkerProducerSnapshot => ({
			state,
			generation,
			nextSequence,
			nextControlSequence,
			availableSampleCredits,
			availableControlCredits,
			retainedPreReadyRequiredSampleCount,
			retainedPreReadyRequiredSampleEncodedBytes,
			pendingLossRange:
				pendingLossRange === null
					? null
					: {
							start: pendingLossRange.start,
							end: pendingLossRange.end,
							requiredCount: pendingLossRange.requiredCount,
							optionalCount: pendingLossRange.optionalCount,
						},
			postSealLossRange:
				postSealLossRange === null
					? null
					: {
							start: postSealLossRange.start,
							end: postSealLossRange.end,
							requiredCount: postSealLossRange.requiredCount,
							optionalCount: postSealLossRange.optionalCount,
						},
		}),
		close: (): void => {
			state = 'closed';
			availableSampleCredits = 0;
			availableControlCredits = 0;
			preReadyEntries.splice(0);
			retainedPreReadyRequiredSampleCount = 0;
			retainedPreReadyRequiredSampleEncodedBytes = 0;
		},
	};
	return producer;
}

function encodedTelemetrySampleBytes(sample: BridgeTelemetryCompactSample): number | null {
	try {
		return new TextEncoder().encode(JSON.stringify(sample)).byteLength;
	} catch {
		return null;
	}
}

function assertCreditCount(count: number): void {
	if (!Number.isInteger(count) || count < 0) {
		throw new Error('Telemetry producer credit count must be a non-negative integer');
	}
}

function assertPositiveCreditGrant(count: number): void {
	if (!Number.isInteger(count) || count <= 0) {
		throw new Error('Telemetry producer credit grant must be a positive integer');
	}
}

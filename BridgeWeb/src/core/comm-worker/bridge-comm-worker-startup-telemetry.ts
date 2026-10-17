import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import type { BridgeTelemetryLossReason } from '../telemetry-worker/bridge-telemetry-worker-contracts.js';
import {
	bridgeTelemetryCompactSampleForEvent,
	type BridgeTelemetryEventCompactSample,
	type BridgeTelemetryWorkerEventProducer,
} from '../telemetry-worker/bridge-telemetry-worker-event-adapter.js';

type StartupTelemetryEntry =
	| { readonly kind: 'sample'; readonly sample: BridgeTelemetryEventCompactSample }
	| {
			readonly kind: 'loss';
			requiredCount: number;
			optionalCount: number;
			readonly reason: BridgeTelemetryLossReason;
	  };

export class BridgeCommWorkerStartupTelemetryBuffer {
	readonly #entries: StartupTelemetryEntry[] = [];
	#maximumBytes = 0;
	#maximumSamples = 0;
	#retainedBytes = 0;
	#retainedSamples = 0;
	#retentionClosed = false;
	#isConfigured = false;

	configure(input: { readonly maximumBytes: number; readonly maximumSamples: number }): void {
		if (this.#isConfigured) throw new Error('Comm worker startup telemetry is already configured');
		this.#maximumBytes = input.maximumBytes;
		this.#maximumSamples = input.maximumSamples;
		this.#isConfigured = true;
	}

	record(sample: BridgeTelemetrySample): void {
		// The only recorder owner is installed after the product bootstrap configures this buffer.
		if (!this.#isConfigured) return;
		const compact = bridgeTelemetryCompactSampleForEvent(
			sample,
			performance.timeOrigin + performance.now(),
		);
		if (compact.type === 'event.optional') {
			this.#appendLoss(false, 'queue_saturated');
			return;
		}
		let encodedBytes: number;
		try {
			encodedBytes = new TextEncoder().encode(JSON.stringify(compact)).byteLength;
		} catch {
			this.#retentionClosed = true;
			this.#appendLoss(true, 'encoded_byte_cap');
			return;
		}
		if (encodedBytes > this.#maximumBytes) {
			this.#retentionClosed = true;
			this.#appendLoss(true, 'encoded_byte_cap');
			return;
		}
		if (
			this.#retentionClosed ||
			this.#retainedSamples >= this.#maximumSamples ||
			this.#retainedBytes + encodedBytes > this.#maximumBytes
		) {
			this.#retentionClosed = true;
			this.#appendLoss(true, 'queue_saturated');
			return;
		}
		this.#entries.push({ kind: 'sample', sample: compact });
		this.#retainedSamples += 1;
		this.#retainedBytes += encodedBytes;
	}

	drainInto(producer: BridgeTelemetryWorkerEventProducer): void {
		for (const entry of this.#entries) {
			if (entry.kind === 'sample') {
				producer.recordCompact(entry.sample);
			} else {
				producer.recordPriorLoss({
					requiredCount: entry.requiredCount,
					optionalCount: entry.optionalCount,
					reason: entry.reason,
				});
			}
		}
		this.#entries.splice(0);
		this.#retainedBytes = 0;
		this.#retainedSamples = 0;
	}

	#appendLoss(required: boolean, reason: BridgeTelemetryLossReason): void {
		const tail = this.#entries.at(-1);
		if (tail?.kind === 'loss' && tail.reason === reason) {
			tail.requiredCount += required ? 1 : 0;
			tail.optionalCount += required ? 0 : 1;
			return;
		}
		this.#entries.push({
			kind: 'loss',
			requiredCount: required ? 1 : 0,
			optionalCount: required ? 0 : 1,
			reason,
		});
	}
}

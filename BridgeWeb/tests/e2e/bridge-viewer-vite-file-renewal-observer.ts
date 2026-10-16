import { bridgeProductFileBatchRowSchema } from '../../src/core/comm-worker/bridge-product-file-batch-row-contracts.js';
import { BridgeProductMetadataFrameDecoder } from '../../src/core/comm-worker/bridge-product-metadata-frame-codec.js';

export interface FileRenewalWireEvent {
	readonly eventKind: string;
	readonly path: string | null;
	readonly descriptorSha256: string | null;
	readonly generation: number;
	readonly streamSequence: number;
}

export interface SubscriptionLifecycleWireEvent {
	readonly atEpochMilliseconds: number;
	readonly eventKind: string;
	readonly reason: string | null;
	readonly streamSequence: number;
	readonly subscriptionId: string;
	readonly subscriptionKind: string;
}

// Diagnostic only: decode observed copies of real frames, never modify forwarding.
export class BridgeFileRenewalWireObserver {
	readonly #decoder = new BridgeProductMetadataFrameDecoder();
	readonly #events: FileRenewalWireEvent[] = [];
	readonly #firstLifecycleEvents: SubscriptionLifecycleWireEvent[] = [];
	readonly #lifecycleEvents: SubscriptionLifecycleWireEvent[] = [];
	readonly #pendingBatches = new Map<
		string,
		{
			readonly partCount: number;
			readonly observedPartIndexes: Set<number>;
			readonly parts: Map<number, FileRenewalWireEvent>;
		}
	>();
	#decodeFailureCount = 0;

	observe(chunk: Uint8Array): void {
		try {
			for (const frame of this.#decoder.push(chunk)) {
				if (!('subscriptionKind' in frame)) continue;
				switch (frame.kind) {
					case 'subscription.accepted':
					case 'subscription.cancelled':
					case 'subscription.end':
					case 'subscription.reset': {
						const event = {
							atEpochMilliseconds: Date.now(),
							eventKind: frame.kind,
							reason: 'reason' in frame ? frame.reason : null,
							streamSequence: frame.streamSequence,
							subscriptionId: frame.subscriptionId,
							subscriptionKind: frame.subscriptionKind,
						} satisfies SubscriptionLifecycleWireEvent;
						if (this.#firstLifecycleEvents.length < 32) this.#firstLifecycleEvents.push(event);
						this.#lifecycleEvents.push(event);
						if (this.#lifecycleEvents.length > 128) this.#lifecycleEvents.shift();
						break;
					}
					case 'subscription.batchBegin':
					case 'subscription.batchPart':
					case 'subscription.batchComplete':
						break;
				}
				if (frame.subscriptionKind !== 'file.metadata') continue;
				switch (frame.kind) {
					case 'subscription.batchBegin':
						this.#pendingBatches.set(frame.batchId, {
							partCount: frame.partCount,
							observedPartIndexes: new Set(),
							parts: new Map(),
						});
						break;
					case 'subscription.batchPart': {
						const pending = this.#pendingBatches.get(frame.batchId);
						if (pending === undefined) break;
						pending.observedPartIndexes.add(frame.partIndex);
						if (frame.part.operation !== 'put') break;
						const row = bridgeProductFileBatchRowSchema.safeParse(frame.part.value);
						if (!row.success || row.data.kind !== 'file') break;
						const descriptor = row.data.readDescriptor;
						pending.parts.set(frame.partIndex, {
							eventKind: descriptor === null ? 'file.invalidated' : 'file.descriptorReady',
							path: row.data.displayKey,
							descriptorSha256: descriptor?.expectedSha256 ?? null,
							generation: descriptor?.source.subscriptionGeneration ?? 0,
							streamSequence: frame.streamSequence,
						});
						break;
					}
					case 'subscription.batchComplete': {
						const pending = this.#pendingBatches.get(frame.batchId);
						this.#pendingBatches.delete(frame.batchId);
						if (pending === undefined || pending.observedPartIndexes.size !== pending.partCount)
							break;
						for (const event of [...pending.parts.entries()]
							.toSorted(([left], [right]) => left - right)
							.map(([, value]) => value)) {
							if (this.#events.length >= 256) break;
							this.#events.push(event);
						}
						break;
					}
					case 'subscription.accepted':
					case 'subscription.cancelled':
					case 'subscription.end':
					case 'subscription.reset':
						break;
				}
			}
		} catch {
			this.#decodeFailureCount += 1;
		}
	}

	snapshot(): {
		readonly events: readonly FileRenewalWireEvent[];
		readonly firstLifecycleEvents: readonly SubscriptionLifecycleWireEvent[];
		readonly lifecycleEvents: readonly SubscriptionLifecycleWireEvent[];
		readonly decodeFailureCount: number;
	} {
		return {
			events: [...this.#events],
			firstLifecycleEvents: [...this.#firstLifecycleEvents],
			lifecycleEvents: [...this.#lifecycleEvents],
			decodeFailureCount: this.#decodeFailureCount,
		};
	}
}

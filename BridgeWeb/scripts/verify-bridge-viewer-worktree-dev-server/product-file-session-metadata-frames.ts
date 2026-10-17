import { BridgeProductMetadataFrameDecoder } from '../../src/core/comm-worker/bridge-product-metadata-frame-codec.js';
import type { BridgeProductMetadataFrame } from '../../src/core/comm-worker/bridge-product-session-contracts.js';

export class BridgeVerifierMetadataFrames {
	readonly #currentSubscriptionId: string;
	readonly #decoder = new BridgeProductMetadataFrameDecoder();
	readonly #frames: BridgeProductMetadataFrame[] = [];
	readonly #observe: (frame: BridgeProductMetadataFrame) => Promise<void>;
	readonly #reader: ReadableStreamDefaultReader<Uint8Array>;

	constructor(
		reader: ReadableStreamDefaultReader<Uint8Array>,
		observe: (frame: BridgeProductMetadataFrame) => Promise<void>,
		currentSubscriptionId: string,
	) {
		this.#reader = reader;
		this.#observe = observe;
		this.#currentSubscriptionId = currentSubscriptionId;
	}

	async waitFor(
		predicate: (frame: BridgeProductMetadataFrame) => boolean,
	): Promise<BridgeProductMetadataFrame> {
		for (;;) {
			const matchedFrame = this.#takeMatchingFrameOrThrow(predicate);
			if (matchedFrame !== null) return matchedFrame;
			// oxlint-disable-next-line no-await-in-loop -- Metadata frames must be decoded in stream order.
			const chunk = await this.#reader.read();
			if (chunk.done) throw new Error('Bridge product metadata stream ended early.');
			const frames = this.#decoder.push(chunk.value);
			for (const frame of frames) {
				// oxlint-disable-next-line no-await-in-loop -- Physical observations preserve stream order.
				await this.#observe(frame);
			}
			this.#frames.push(
				...frames.filter(
					(frame) =>
						frame.kind !== 'subscription.batchBegin' && frame.kind !== 'subscription.batchPart',
				),
			);
		}
	}

	#takeMatchingFrameOrThrow(
		predicate: (frame: BridgeProductMetadataFrame) => boolean,
	): BridgeProductMetadataFrame | null {
		for (const [frameIndex, frame] of this.#frames.entries()) {
			if (predicate(frame)) {
				this.#frames.splice(frameIndex, 1);
				return frame;
			}
			this.#throwIfUnexpectedTerminal(frame);
		}
		return null;
	}

	#throwIfUnexpectedTerminal(frame: BridgeProductMetadataFrame): void {
		if (frame.kind === 'metadataStream.error') {
			throw new Error(
				`Bridge product metadata stream terminated kind=${frame.kind} code=${frame.code}.`,
			);
		}
		if (
			(frame.kind === 'subscription.reset' ||
				frame.kind === 'subscription.end' ||
				frame.kind === 'subscription.cancelled') &&
			frame.subscriptionId === this.#currentSubscriptionId
		) {
			const reason = frame.kind === 'subscription.reset' ? frame.reason : 'none';
			throw new Error(
				`Bridge product current File metadata subscription terminated kind=${frame.kind} reason=${reason}.`,
			);
		}
	}
}

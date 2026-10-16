import type { BridgeProductMetadataFrame } from '../../src/core/comm-worker/bridge-product-session-contracts.js';

export interface MetadataFrameObservation {
	readonly frames: readonly BridgeProductMetadataFrame[];
	readonly record: (frame: BridgeProductMetadataFrame) => void;
	readonly waitFor: (
		predicate: (frame: BridgeProductMetadataFrame) => boolean,
		startingAt: number,
	) => Promise<BridgeProductMetadataFrame>;
}

export function observeMetadataFrames(): MetadataFrameObservation {
	const frames: BridgeProductMetadataFrame[] = [];
	const waiters: {
		readonly predicate: (frame: BridgeProductMetadataFrame) => boolean;
		readonly resolve: (frame: BridgeProductMetadataFrame) => void;
		readonly startingAt: number;
	}[] = [];
	return {
		frames,
		record: (frame): void => {
			frames.push(frame);
			const frameIndex = frames.length - 1;
			for (let waiterIndex = waiters.length - 1; waiterIndex >= 0; waiterIndex -= 1) {
				const waiter = waiters[waiterIndex];
				if (waiter === undefined) continue;
				if (frameIndex < waiter.startingAt || !waiter.predicate(frame)) continue;
				waiters.splice(waiterIndex, 1);
				waiter.resolve(frame);
			}
		},
		waitFor: (predicate, startingAt): Promise<BridgeProductMetadataFrame> => {
			const observed = frames.slice(startingAt).find(predicate);
			if (observed !== undefined) return Promise.resolve(observed);
			return new Promise((resolve): void => {
				waiters.push({ predicate, resolve, startingAt });
			});
		},
	};
}

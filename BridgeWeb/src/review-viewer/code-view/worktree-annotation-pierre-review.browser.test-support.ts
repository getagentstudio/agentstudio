import { act } from 'react';

interface ReviewAnimationFrameClock {
	readonly settleCondition: (predicate: () => boolean, failureMessage: string) => Promise<void>;
	readonly drain: () => Promise<void>;
	readonly restore: () => void;
}

/** Pierre looks up the global frame functions when queuing, not when importing. */
export function installReviewAnimationFrameClock(signal: AbortSignal): ReviewAnimationFrameClock {
	const originalRequestFrame = globalThis.requestAnimationFrame;
	const originalCancelFrame = globalThis.cancelAnimationFrame;
	const queuedFrames = new Map<number, FrameRequestCallback>();
	let nextFrameId = 0;
	let frameTimestamp = 0;

	globalThis.requestAnimationFrame = (callback: FrameRequestCallback): number => {
		const frameId = ++nextFrameId;
		queuedFrames.set(frameId, callback);
		return frameId;
	};
	globalThis.cancelAnimationFrame = (frameId: number): void => {
		queuedFrames.delete(frameId);
	};

	const advanceFrame = async (): Promise<void> => {
		await act(async (): Promise<void> => {
			signal.throwIfAborted();
			// Simulated animation time advances independently of machine speed.
			frameTimestamp += 1000 / 60;
			// Requests made by these callbacks belong to the next frame.
			const currentFrameIds = [...queuedFrames.keys()];
			for (const frameId of currentFrameIds) {
				const callback = queuedFrames.get(frameId);
				queuedFrames.delete(frameId);
				callback?.(frameTimestamp);
			}
		});
	};
	const drain = async (): Promise<void> => {
		// An empty act also joins React work from the preceding stimulus.
		do {
			await advanceFrame();
		} while (queuedFrames.size > 0);
	};

	return {
		drain,
		async settleCondition(predicate: () => boolean, failureMessage: string): Promise<void> {
			// Each queued frame and its resulting React work finish before observation.
			await drain();
			if (!predicate()) {
				throw new Error(`${failureMessage} The test-owned animation-frame queue is empty.`);
			}
		},
		restore(): void {
			globalThis.requestAnimationFrame = originalRequestFrame;
			globalThis.cancelAnimationFrame = originalCancelFrame;
			if (queuedFrames.size > 0) {
				throw new Error(`Review cleanup left ${queuedFrames.size} animation-frame callbacks.`);
			}
		},
	};
}

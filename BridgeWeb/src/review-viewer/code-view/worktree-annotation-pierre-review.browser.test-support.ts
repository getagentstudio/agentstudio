import { act } from 'react';

/** Observe the control's committed DOM, with failure exits owned by its panel and page. */
export function waitForReviewControl(props: {
	readonly panel: Element;
	readonly signal: AbortSignal;
	readonly isReady: () => boolean;
	readonly label: string;
}): Promise<void> {
	return new Promise<void>((resolve, reject): void => {
		const observer = new MutationObserver(inspect);
		function dispose(): void {
			observer.disconnect();
			props.signal.removeEventListener('abort', abort);
			window.removeEventListener('error', fail);
			window.removeEventListener('unhandledrejection', fail);
			window.removeEventListener('pagehide', fail);
		}
		function fail(event: Event): void {
			dispose();
			reject(
				new Error(`Awaiting ${props.label} ended with ${event.type}.`, {
					cause:
						event instanceof ErrorEvent
							? event.error
							: event instanceof PromiseRejectionEvent
								? event.reason
								: undefined,
				}),
			);
		}
		function abort(): void {
			dispose();
			reject(
				new Error(`Test retired while awaiting ${props.label}.`, { cause: props.signal.reason }),
			);
		}
		function inspect(): void {
			try {
				if (!props.panel.isConnected) {
					dispose();
					reject(new Error(`Review panel retired while awaiting ${props.label}.`));
				} else if (props.isReady()) {
					dispose();
					resolve();
				}
			} catch (error: unknown) {
				dispose();
				reject(error);
			}
		}
		observer.observe(document.body, { attributes: true, childList: true, subtree: true });
		props.signal.addEventListener('abort', abort, { once: true });
		window.addEventListener('error', fail);
		window.addEventListener('unhandledrejection', fail);
		window.addEventListener('pagehide', fail);
		if (props.signal.aborted) abort();
		else inspect();
	});
}

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

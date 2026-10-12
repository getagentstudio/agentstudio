import { act } from 'react';
import { afterEach, beforeEach } from 'vitest';

import { createBridgeProductDeferred } from '../../src/core/comm-worker/bridge-product-async-queue.js';

let ownerSignal: AbortSignal | undefined;
const activeObservations = new Set<() => void>();

beforeEach((context): void => {
	ownerSignal = context.signal;
});
afterEach((): void => {
	for (const close of activeObservations) close();
	activeObservations.clear();
	ownerSignal = undefined;
});

/** Observe a committed outcome, including an initial check; never advance frames to poll it. */
export function observeBridgeTransitionDOMFact(props: {
	readonly label: string;
	readonly isCommitted: () => boolean;
	readonly root?: Node;
}): { readonly promise: Promise<void>; readonly close: () => void } {
	const signal = ownerSignal;
	if (signal === undefined) throw new Error(`No test owner for ${props.label}.`);
	const completed = createBridgeProductDeferred<void>();
	const inspect = (): void => {
		if (props.isCommitted()) completed.resolve();
	};
	const observer = new MutationObserver(inspect);
	const close = (): void => {
		observer.disconnect();
		signal.removeEventListener('abort', close);
		activeObservations.delete(close);
		completed.reject(new Error(`Test owner retired while awaiting ${props.label}.`));
	};
	observer.observe(props.root ?? document.body, {
		attributes: true,
		childList: true,
		subtree: true,
	});
	activeObservations.add(close);
	signal.addEventListener('abort', close, { once: true });
	void completed.promise.catch((): void => {});
	if (signal.aborted) close();
	else inspect();
	return { promise: completed.promise, close };
}

/**
 * Native transition RAF writers commit in discrete act turns while an operation
 * awaits its DOM fact. An outer async act waiting for that same React commit
 * would deadlock it. This adapter has no frame count or idle criterion, and is
 * restored when the operation closes; animation Promise writers are joined
 * separately inside act by the caller.
 */
export async function runBridgeTransitionFramesInAct<TResult>(
	operation: () => Promise<TResult>,
): Promise<TResult> {
	const requestFrame = window.requestAnimationFrame;
	const cancelFrame = window.cancelAnimationFrame;
	const acceptedFrames = new Map<
		number,
		{ readonly promise: Promise<void>; readonly resolve: () => void }
	>();
	let isActive = true;
	window.requestAnimationFrame = (callback: FrameRequestCallback): number => {
		const completed = createBridgeProductDeferred<void>();
		const frameId = requestFrame.call(window, (timestamp): void => {
			if (!isActive) {
				callback(timestamp);
				completed.resolve();
				return;
			}
			try {
				act((): void => {
					callback(timestamp);
				});
			} finally {
				completed.resolve();
			}
		});
		acceptedFrames.set(frameId, completed);
		return frameId;
	};
	window.cancelAnimationFrame = (frameId: number): void => {
		cancelFrame.call(window, frameId);
		acceptedFrames.get(frameId)?.resolve();
	};
	try {
		// Base UI has a shared scheduler tick registered before this operation. Join
		// that actual native frame in act before registering the operation's writers;
		// this is a registration barrier, never the operation's completion predicate.
		await act(async (): Promise<void> => {
			await new Promise<void>((resolve) => requestFrame.call(window, (): void => resolve()));
		});
		const result = await operation();
		// The owner's closing fact defines the cutoff. Join precisely the callbacks
		// accepted before it, including cancelled callbacks, rather than await idle.
		await Promise.all([...acceptedFrames.values()].map((frame) => frame.promise));
		return result;
	} finally {
		isActive = false;
		window.requestAnimationFrame = requestFrame;
		window.cancelAnimationFrame = cancelFrame;
	}
}

export async function finishBridgeTransitionAnimations(element: Element): Promise<void> {
	const animations = element.getAnimations({ subtree: true });
	const completed = animations.map(async (animation): Promise<void> => {
		try {
			await animation.finished;
		} catch {
			/* A superseding transition cancels its predecessor. */
		}
	});
	for (const animation of animations) animation.finish();
	await Promise.all(completed);
}

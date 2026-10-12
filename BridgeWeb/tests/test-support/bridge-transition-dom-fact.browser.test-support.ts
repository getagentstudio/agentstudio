import { act } from 'react';
import { afterEach, beforeEach } from 'vitest';

import { createBridgeProductDeferred } from '../../src/core/comm-worker/bridge-product-async-queue.js';

let ownerSignal: AbortSignal | undefined;
const activeObservations = new Set<() => void>();
const activeFrameAdapters = new Set<() => void>();

beforeEach((context): void => {
	ownerSignal = context.signal;
});
afterEach((): void => {
	for (const retire of activeFrameAdapters) retire();
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

type RequestFrameAPI = typeof window.requestAnimationFrame;
type CancelFrameAPI = typeof window.cancelAnimationFrame;
interface RequestFramePatch {
	readonly previous: RequestFrameAPI;
	readonly isRestored: () => boolean;
}
interface CancelFramePatch {
	readonly previous: CancelFrameAPI;
	readonly isRestored: () => boolean;
}
const requestFramePatches = new WeakMap<RequestFrameAPI, RequestFramePatch>();
const cancelFramePatches = new WeakMap<CancelFrameAPI, CancelFramePatch>();

export type BridgeTransitionFramePhase = 'registration barrier' | 'operation' | 'final frame join';
interface BridgeTransitionFrameOptions {
	readonly ownerAbortSignal?: AbortSignal;
	readonly onPhase?: (phase: BridgeTransitionFramePhase) => void;
}
interface OwnedTransitionFrame {
	nativeId: number;
	disposition: 'queued' | 'ran' | 'cancelled' | 'retired';
	readonly promise: Promise<void>;
	readonly resolve: () => void;
	readonly reject: (error: unknown) => void;
}

function resolveRequestFrameAncestor(api: RequestFrameAPI, skipActive: boolean): RequestFrameAPI {
	const patch = requestFramePatches.get(api);
	return patch !== undefined && (skipActive || patch.isRestored())
		? resolveRequestFrameAncestor(patch.previous, skipActive)
		: api;
}
function resolveCancelFrameAncestor(api: CancelFrameAPI, skipActive: boolean): CancelFrameAPI {
	const patch = cancelFramePatches.get(api);
	return patch !== undefined && (skipActive || patch.isRestored())
		? resolveCancelFrameAncestor(patch.previous, skipActive)
		: api;
}

/**
 * The owner's closing fact cuts off the finite final join. A successor captured
 * during that join retains its own act wrapper after API restoration; it runs
 * under the same test owner or is retired on abort/cleanup. No idle wait.
 */
export async function runBridgeTransitionFramesInAct<TResult>(
	operation: () => Promise<TResult>,
	options: BridgeTransitionFrameOptions = {},
): Promise<TResult> {
	const testOwner = ownerSignal;
	if (testOwner === undefined)
		throw new Error('Bridge transition frame adapter has no test owner.');
	const previousRequest = window.requestAnimationFrame;
	const previousCancel = window.cancelAnimationFrame;
	// A nested adapter owns its own frames, without enrolling them in an older
	// adapter that may be retired independently.
	const nativeRequest = resolveRequestFrameAncestor(previousRequest, true);
	const nativeCancel = resolveCancelFrameAncestor(previousCancel, true);
	const pendingFrames = new Map<number, OwnedTransitionFrame>();
	const retired = createBridgeProductDeferred<never>();
	void retired.promise.catch((): void => {});
	const signals = new Set([
		testOwner,
		...(options.ownerAbortSignal === undefined ? [] : [options.ownerAbortSignal]),
	]);
	let phase: BridgeTransitionFramePhase = 'registration barrier';
	let isRetired = false;
	let areAPIsRestored = false;
	const detachOwnerWhenFinished = (): void => {
		if (!areAPIsRestored || pendingFrames.size !== 0) return;
		activeFrameAdapters.delete(cleanup);
		for (const signal of signals) signal.removeEventListener('abort', abortOwner);
	};
	const settleFrame = (
		frame: OwnedTransitionFrame,
		disposition: OwnedTransitionFrame['disposition'],
	): void => {
		frame.disposition = disposition;
		pendingFrames.delete(frame.nativeId);
		frame.resolve();
		detachOwnerWhenFinished();
	};
	const restoreAPIs = (): void => {
		areAPIsRestored = true;
		if (window.requestAnimationFrame === patchedRequest)
			window.requestAnimationFrame = resolveRequestFrameAncestor(previousRequest, false);
		if (window.cancelAnimationFrame === patchedCancel)
			window.cancelAnimationFrame = resolveCancelFrameAncestor(previousCancel, false);
		detachOwnerWhenFinished();
	};
	const retire = (error: Error): void => {
		if (isRetired) return;
		isRetired = true;
		retired.reject(error);
		for (const frame of pendingFrames.values()) {
			nativeCancel.call(window, frame.nativeId);
			settleFrame(frame, 'retired');
		}
		restoreAPIs();
	};
	const abortOwner = (): void =>
		retire(new Error(`Bridge transition frame owner aborted during ${phase}.`));
	const cleanup = (): void =>
		retire(new Error(`Bridge transition frame owner cleanup during ${phase}.`));
	const scheduleOwnedFrame = (callback: FrameRequestCallback): OwnedTransitionFrame => {
		const completed = createBridgeProductDeferred<void>();
		const frame: OwnedTransitionFrame = { nativeId: 0, disposition: 'queued', ...completed };
		frame.nativeId = nativeRequest.call(window, (timestamp): void => {
			if (frame.disposition !== 'queued') return;
			try {
				act((): void => {
					callback(timestamp);
				});
				settleFrame(frame, 'ran');
			} catch (error: unknown) {
				frame.disposition = 'ran';
				pendingFrames.delete(frame.nativeId);
				frame.reject(error);
				detachOwnerWhenFinished();
				throw error;
			}
		});
		pendingFrames.set(frame.nativeId, frame);
		void frame.promise.catch((): void => {});
		return frame;
	};
	const patchedRequest: RequestFrameAPI = (callback): number => {
		if (areAPIsRestored)
			return resolveRequestFrameAncestor(previousRequest, false).call(window, callback);
		return scheduleOwnedFrame(callback).nativeId;
	};
	const patchedCancel: CancelFrameAPI = (frameId): void => {
		const frame = pendingFrames.get(frameId);
		nativeCancel.call(window, frameId);
		if (frame !== undefined) settleFrame(frame, 'cancelled');
	};
	requestFramePatches.set(patchedRequest, {
		previous: previousRequest,
		isRestored: (): boolean => areAPIsRestored,
	});
	cancelFramePatches.set(patchedCancel, {
		previous: previousCancel,
		isRestored: (): boolean => areAPIsRestored,
	});
	window.requestAnimationFrame = patchedRequest;
	window.cancelAnimationFrame = patchedCancel;
	activeFrameAdapters.add(cleanup);
	for (const signal of signals) signal.addEventListener('abort', abortOwner, { once: true });
	const publishPhase = (nextPhase: BridgeTransitionFramePhase): void => {
		phase = nextPhase;
		options.onPhase?.(phase);
	};
	try {
		if ([...signals].some((signal) => signal.aborted)) abortOwner();
		if (isRetired) return await retired.promise;
		publishPhase('registration barrier');
		if (isRetired) return await retired.promise;
		// Preserve the accepted ordering fence for Base UI's already registered tick.
		await act(async (): Promise<void> => {
			await Promise.race([scheduleOwnedFrame((): void => {}).promise, retired.promise]);
		});
		if (isRetired) return await retired.promise;
		publishPhase('operation');
		if (isRetired) return await retired.promise;
		const result = await Promise.race([operation(), retired.promise]);
		if (isRetired) return await retired.promise;
		const closingFrames = [...pendingFrames.values()];
		publishPhase('final frame join');
		if (isRetired) return await retired.promise;
		await Promise.race([Promise.all(closingFrames.map((frame) => frame.promise)), retired.promise]);
		if (isRetired) return await retired.promise;
		return result;
	} catch (error: unknown) {
		retire(
			new Error(`Bridge transition frame operation retired during ${phase}.`, { cause: error }),
		);
		throw error;
	} finally {
		restoreAPIs();
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

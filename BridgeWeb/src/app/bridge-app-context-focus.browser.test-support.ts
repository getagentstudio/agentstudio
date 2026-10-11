import { afterEach, beforeEach } from 'vitest';

import { BridgeTestFactRecorder } from '../../tests/test-support/bridge-test-fact-recorder.js';

type FocusFrameFact =
	| { readonly kind: 'completed' | 'cancelled' | 'held'; readonly index: number }
	| { readonly kind: 'failed'; readonly index: number; readonly error: unknown };

let facts = new BridgeTestFactRecorder<FocusFrameFact>();
let requestedCount = 0;
let restoreFrameClock: (() => void) | null = null;
let holdNextFrame = false;
let heldFrame: { readonly index: number; readonly callback: FrameRequestCallback } | null = null;
const activeFocusObservations = new Set<() => void>();
let currentTestSignal: AbortSignal | undefined;

beforeEach((context): void => {
	currentTestSignal = context.signal;
	restoreFrameClock?.();
	facts = new BridgeTestFactRecorder<FocusFrameFact>();
	const ownerFacts = facts;
	let isClosed = false;
	requestedCount = 0;
	holdNextFrame = false;
	heldFrame = null;
	const requestFrame = window.requestAnimationFrame;
	const cancelFrame = window.cancelAnimationFrame;
	const ownedFrames = new Map<number, number>();
	const run = (index: number, callback: FrameRequestCallback, timestamp: number): void => {
		if (isClosed) return;
		try {
			callback(timestamp);
			ownerFacts.record({ kind: 'completed', index });
		} catch (error: unknown) {
			ownerFacts.record({ kind: 'failed', index, error });
			throw error;
		}
	};
	// The pre-existing held-handoff test identifies this exact production clock
	// ingress by the callback's named focus operation. Other frame owners are untouched.
	window.requestAnimationFrame = (callback: FrameRequestCallback): number => {
		if (!callback.toString().includes('focusActiveBridgeViewerContextControl'))
			return requestFrame.call(window, callback);
		const index = ++requestedCount;
		if (holdNextFrame) {
			holdNextFrame = false;
			const handle = requestFrame.call(window, (): void => {});
			cancelFrame.call(window, handle);
			ownedFrames.set(handle, index);
			heldFrame = {
				index,
				callback: (timestamp): void => {
					if (!ownedFrames.delete(handle))
						throw new Error('Held context focus callback retired before release.');
					run(index, callback, timestamp);
				},
			};
			ownerFacts.record({ kind: 'held', index });
			return handle;
		}
		let handle = 0;
		handle = requestFrame.call(window, (timestamp): void => {
			ownedFrames.delete(handle);
			run(index, callback, timestamp);
		});
		ownedFrames.set(handle, index);
		return handle;
	};
	window.cancelAnimationFrame = (handle: number): void => {
		const index = ownedFrames.get(handle);
		if (index !== undefined) {
			ownedFrames.delete(handle);
			if (!isClosed) ownerFacts.record({ kind: 'cancelled', index });
		}
		cancelFrame.call(window, handle);
	};
	const close = (): void => {
		if (isClosed) return;
		isClosed = true;
		window.requestAnimationFrame = requestFrame;
		window.cancelAnimationFrame = cancelFrame;
		for (const handle of ownedFrames.keys()) cancelFrame.call(window, handle);
		ownedFrames.clear();
		const error = new Error('Context focus handoff observation closed.');
		ownerFacts.close(error);
		context.signal.removeEventListener('abort', close);
	};
	restoreFrameClock = close;
	context.signal.addEventListener('abort', close, { once: true });
	context.onTestFinished(close);
});

afterEach((): void => {
	for (const close of activeFocusObservations) close();
	activeFocusObservations.clear();
	currentTestSignal = undefined;
	restoreFrameClock?.();
	restoreFrameClock = null;
});

export function nextContextFocusHandoff(): number {
	return requestedCount + 1;
}

export async function awaitContextFocusHandoff(index: number): Promise<void> {
	const outcome = await facts.waitFor(
		(fact): boolean => fact.index === index && fact.kind !== 'held',
		`Context focus handoff ${index} completed`,
	);
	if (outcome.kind === 'cancelled') throw new Error(`Context focus handoff ${index} cancelled.`);
	if (outcome.kind === 'failed') throw outcome.error;
}

export function holdNextContextFocusHandoff(): {
	readonly arrived: Promise<void>;
	readonly release: () => void;
} {
	holdNextFrame = true;
	const index = nextContextFocusHandoff();
	const arrived = facts
		.waitFor(
			(fact): boolean => fact.kind === 'held' && fact.index === index,
			`Context focus handoff ${index} held arrival`,
		)
		.then((): void => {});
	void arrived.catch((): void => {});
	return {
		arrived,
		release: (): void => {
			const frame = heldFrame;
			if (frame === null) throw new Error('Expected the owned context focus handoff to be held.');
			heldFrame = null;
			frame.callback(0);
		},
	};
}

export function observeContextFocusIn(matchesTarget: (target: EventTarget | null) => boolean): {
	readonly arrived: Promise<void>;
	readonly close: () => void;
	readonly inspect: () => void;
} {
	const focusFacts = new BridgeTestFactRecorder<'focused'>();
	const arrived = focusFacts
		.waitFor((fact): boolean => fact === 'focused', 'Context focus target focused')
		.then((): void => {});
	// Teardown may reject before the caller starts awaiting; preserve the promise
	// rejection for its eventual await without creating an unhandled secondary error.
	void arrived.catch((): void => {});
	const ownerSignal = currentTestSignal;
	let isClosed = false;
	let hasArrived = false;
	const resolveArrival = (): void => {
		if (isClosed) return;
		hasArrived = true;
		focusFacts.record('focused');
		close();
	};
	const onFocusIn = (event: FocusEvent): void => {
		if (!matchesTarget(event.target) || isClosed) return;
		resolveArrival();
	};
	const close = (): void => {
		if (isClosed) return;
		isClosed = true;
		document.removeEventListener('focusin', onFocusIn, true);
		ownerSignal?.removeEventListener('abort', close);
		activeFocusObservations.delete(close);
		focusFacts.close(
			new Error(
				hasArrived
					? 'Context focus observation completed.'
					: 'Context focus observation closed before the target focused.',
			),
		);
	};
	document.addEventListener('focusin', onFocusIn, true);
	ownerSignal?.addEventListener('abort', close, { once: true });
	activeFocusObservations.add(close);
	return {
		arrived,
		close,
		inspect: (): void => {
			if (matchesTarget(document.activeElement)) resolveArrival();
		},
	};
}

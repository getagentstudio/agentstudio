import { act } from 'react';
import { expect, vi } from 'vitest';
import { cleanup } from 'vitest-browser-react';

interface SlotPublicationCoordinator<TSnapshot> {
	readonly hasHeaderRenderers: boolean;
	readonly hasAnnotationRenderer: boolean;
	readonly hasGutterRenderer: boolean;
	onSnapshotChange(snapshot: TSnapshot): void;
}

/** React publication at Pierre's existing slot owner, not a frame proxy. */
export class PierreSlotPublicationFacts<TSnapshot> {
	readonly #wrappedCoordinators = new WeakMap<
		SlotPublicationCoordinator<TSnapshot>,
		SlotPublicationCoordinator<TSnapshot>
	>();
	readonly #publications: Promise<void>[] = [];

	wrap(
		coordinator: SlotPublicationCoordinator<TSnapshot> | undefined,
	): SlotPublicationCoordinator<TSnapshot> | undefined {
		if (coordinator === undefined) return undefined;
		const previous = this.#wrappedCoordinators.get(coordinator);
		if (previous !== undefined) return previous;
		const wrapped: SlotPublicationCoordinator<TSnapshot> = {
			...coordinator,
			onSnapshotChange: (snapshot): void => {
				// The callback is synchronous; no outcome or frame wait holds this act open.
				this.publish((): void => coordinator.onSnapshotChange(snapshot));
			},
		};
		this.#wrappedCoordinators.set(coordinator, wrapped);
		return wrapped;
	}

	publish(callback: () => void): void {
		const publication = new Promise<void>((resolve, reject): void => {
			act(async (): Promise<void> => callback()).then(resolve, reject);
		});
		this.#publications.push(publication);
	}

	async join(): Promise<void> {
		await Promise.all(this.#publications.splice(0));
	}
}

export function queryPierreElements(selector: string): Element[] {
	const elements: Element[] = [];
	const pendingRoots: ParentNode[] = [document];
	while (pendingRoots.length > 0) {
		const root = pendingRoots.shift();
		if (root === undefined) break;
		elements.push(...root.querySelectorAll(selector));
		for (const candidate of root.querySelectorAll('*')) {
			if (candidate.shadowRoot !== null) pendingRoots.push(candidate.shadowRoot);
		}
	}
	return elements;
}

export function waitForPierreCondition(
	predicate: () => boolean,
	signal?: AbortSignal,
): Promise<void> {
	return new Promise<void>((resolve, reject): void => {
		const observedRoots = new Set<Node>();
		const observer = new MutationObserver(checkCondition);
		function finish(): void {
			observer.disconnect();
			signal?.removeEventListener('abort', abortWait);
		}
		function abortWait(): void {
			finish();
			reject(new Error('Click-admission outcome wait disposed.'));
		}
		function checkCondition(): void {
			const roots: ParentNode[] = [document];
			while (roots.length > 0) {
				const root = roots.shift();
				if (root === undefined) break;
				if (!observedRoots.has(root)) {
					observedRoots.add(root);
					observer.observe(root, { childList: true, subtree: true });
				}
				for (const candidate of root.querySelectorAll('*')) {
					if (candidate.shadowRoot !== null) roots.push(candidate.shadowRoot);
				}
			}
			if (predicate()) {
				finish();
				resolve();
			}
		}
		if (signal?.aborted === true) abortWait();
		else {
			signal?.addEventListener('abort', abortWait, { once: true });
			checkCondition();
		}
	});
}

let announceTestFrameWait: (() => void) | undefined;

export function observeTestFrameWait(observer: (() => void) | undefined): void {
	announceTestFrameWait = observer;
}

// Retained as the test-frame owner used by the deterministic pre-fix red.
export async function nextAnimationFrame(): Promise<void> {
	announceTestFrameWait?.();
	await new Promise<void>((resolve): void => {
		requestAnimationFrame((): void => resolve());
	});
}

export async function actEvent(callback: () => void): Promise<void> {
	await act(async (): Promise<void> => callback());
}

export async function proveHeldProductFrameIsolation(props: {
	readonly prepareUtility: () => Promise<void>;
	readonly clickUtility: () => Promise<void>;
	readonly waitForComposer: () => Promise<void>;
	readonly dispose: () => Promise<void>;
}): Promise<void> {
	await props.prepareUtility();
	let announceProductFrame: (() => void) | undefined;
	const productFrameRequested = new Promise<void>((resolve): void => {
		announceProductFrame = resolve;
	});
	const heldFrames = new Map<number, FrameRequestCallback>();
	const requestFrame = globalThis.requestAnimationFrame.bind(globalThis);
	const cancelFrame = globalThis.cancelAnimationFrame.bind(globalThis);
	const frameSpy = vi
		.spyOn(globalThis, 'requestAnimationFrame')
		.mockImplementation((callback: FrameRequestCallback): number => {
			announceProductFrame?.();
			// Preserve real frame IDs and cancellation, but withhold product delivery.
			const frameId = requestFrame((): void => {});
			heldFrames.set(frameId, callback);
			return frameId;
		});
	const cancelSpy = vi
		.spyOn(globalThis, 'cancelAnimationFrame')
		.mockImplementation((frameId: number): void => {
			heldFrames.delete(frameId);
			cancelFrame(frameId);
		});
	let outcome: Promise<void> | undefined;
	try {
		await props.clickUtility();
		await productFrameRequested;
		outcome = props.waitForComposer();
		const disposedOutcome = expect(outcome).rejects.toThrow('outcome wait disposed');
		let laterActCompleted = false;
		await actEvent((): void => {
			laterActCompleted = true;
		});
		expect(laterActCompleted).toBe(true);
		await props.dispose();
		await disposedOutcome;
	} finally {
		// Unmount cancels the actual pending rendering owners before restoring delivery.
		await cleanup();
		await props.dispose();
		await outcome?.catch((): void => {});
		frameSpy.mockRestore();
		cancelSpy.mockRestore();
		// Drain uncancelled product delivery after unmount, so Pierre's shared frame
		// owner cannot retain an intercepted frame ID into the next test.
		await actEvent((): void => {
			for (const callback of heldFrames.values()) callback(0);
		});
	}
}

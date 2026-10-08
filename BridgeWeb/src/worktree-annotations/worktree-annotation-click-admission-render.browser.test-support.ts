import { act } from 'react';
import { expect, vi } from 'vitest';
import { cleanup } from 'vitest-browser-react';

import {
	completeCleanup,
	runWithOwnedCleanup,
} from './worktree-annotation-click-admission-cleanup.browser.test-support.js';
import {
	ClickAdmissionResourceOwner,
	type ClickAdmissionResourceGroup,
	type ClickAdmissionResourceToken,
} from './worktree-annotation-click-admission-resource-owner.browser.test-support.js';

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
	readonly #resources: ClickAdmissionResourceOwner;
	readonly #group: ClickAdmissionResourceGroup;
	constructor(resources: ClickAdmissionResourceOwner, group: ClickAdmissionResourceGroup) {
		this.#resources = resources;
		this.#group = group;
		resources.register({
			group,
			kind: 'join',
			label: 'slot and metadata publication ledger',
			restore: (): Promise<void> => this.join(),
		});
	}

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
		const publication = this.#resources.track({
			group: this.#group,
			label: 'slot/metadata act',
			start: async (): Promise<void> => {
				await act(async (): Promise<void> => callback());
			},
		});
		this.#publications.push(publication);
	}

	async join(): Promise<void> {
		const failures: unknown[] = [];
		while (this.#publications.length > 0) {
			// oxlint-disable-next-line no-await-in-loop -- Drain newly registered publication batches through their completion, never poll.
			const results = await Promise.allSettled(this.#publications.splice(0));
			for (const result of results) {
				if (result.status === 'rejected') failures.push(result.reason);
			}
		}
		if (failures.length === 1) throw failures[0];
		if (failures.length > 1)
			throw new AggregateError(failures, 'Click-admission publications failed.');
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

export function waitForPierreCondition(props: {
	readonly predicate: () => boolean;
	readonly resources: ClickAdmissionResourceOwner;
	readonly group: ClickAdmissionResourceGroup;
	readonly recordObserver?: ((observer: MutationObserver) => void) | undefined;
}): Promise<void> {
	const outcome = props.resources.wait<void>({ group: props.group, label: 'Pierre DOM outcome' });
	const observedRoots = new Set<Node>();
	const observer = new MutationObserver(checkCondition);
	let disconnected = false;
	const disconnect = (): void => {
		if (disconnected) return;
		disconnected = true;
		observer.disconnect();
		props.resources.forget(observerResource);
	};
	const observerResource = props.resources.register({
		group: props.group,
		kind: 'observer',
		label: 'Pierre DOM observer',
		restore: disconnect,
	});
	props.recordObserver?.(observer);
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
		if (props.predicate()) {
			disconnect();
			outcome.resolve(undefined);
		}
	}
	void outcome.promise.then(disconnect, disconnect);
	checkCondition();
	return outcome.promise;
}

const testFrameObservation: { notify: (() => void) | undefined } = { notify: undefined };

export function observeTestFrameWait(props: {
	readonly resources: ClickAdmissionResourceOwner;
	readonly group: ClickAdmissionResourceGroup;
	readonly observer: (() => void) | undefined;
}): void {
	props.resources.patch({
		group: props.group,
		label: 'test-frame observation adapter',
		target: testFrameObservation,
		key: 'notify',
		value: props.observer,
	});
}

export async function nextAnimationFrame(
	resources: ClickAdmissionResourceOwner,
	group: ClickAdmissionResourceGroup,
): Promise<void> {
	const completion = resources.wait<void>({ group, label: 'test frame delivery' });
	const registration: { frameId?: number } = {};
	resources.register({
		group,
		kind: 'frame',
		label: 'test frame cancellation',
		restore: (): void => {
			if (registration.frameId !== undefined) cancelAnimationFrame(registration.frameId);
		},
	});
	testFrameObservation.notify?.();
	registration.frameId = requestAnimationFrame((): void => completion.resolve(undefined));
	await completion.promise;
}

export function actEvent(
	resources: ClickAdmissionResourceOwner,
	group: ClickAdmissionResourceGroup,
	callback: () => void,
): Promise<void> {
	return resources.track({
		group,
		label: 'event act',
		start: async (): Promise<void> => {
			await act(async (): Promise<void> => callback());
		},
	});
}

// Only used inside an already-registered resource restore action, whose promise
// the registry joins even while it is closing (no new resource installation).
export async function runCleanupAct(callback: () => void): Promise<void> {
	await act(async (): Promise<void> => callback());
}

export async function proveHeldProductFrameIsolation(props: {
	readonly resources: ClickAdmissionResourceOwner;
	readonly recordFrameWait?: () => void;
	readonly prepareUtility: () => Promise<void>;
	readonly clickUtility: () => Promise<void>;
	readonly waitForComposer: () => Promise<void>;
	readonly dispose: () => Promise<void>;
}): Promise<void> {
	const group = props.resources.createGroup('held product frames');
	const heldFrames = new Map<number, FrameRequestCallback>();
	const originalRequestFrame = globalThis.requestAnimationFrame;
	const originalCancelFrame = globalThis.cancelAnimationFrame;
	let frameSpyToken: ClickAdmissionResourceToken | undefined;
	let cancelSpyToken: ClickAdmissionResourceToken | undefined;
	let outcome: Promise<void> | undefined;
	let finalization: Promise<void> | undefined;
	const disposeHeldFrames = (): Promise<void> => {
		finalization ??= completeCleanup([
			// Restore the two global functions in reverse install order BEFORE
			// unmount: header-effect teardown may itself request a native frame.
			async (): Promise<void> => {
				if (cancelSpyToken !== undefined) await props.resources.release(cancelSpyToken);
			},
			async (): Promise<void> => {
				if (frameSpyToken !== undefined) await props.resources.release(frameSpyToken);
			},
			props.dispose,
			cleanup,
			async (): Promise<void> => {
				await outcome?.catch((): void => {});
			},
			(): Promise<void> =>
				runCleanupAct((): void => {
					for (const callback of heldFrames.values()) callback(0);
				}),
		]);
		return finalization;
	};
	props.resources.register({
		group,
		kind: 'frame',
		label: 'held-frame preparation cleanup',
		restore: disposeHeldFrames,
	});
	await runWithOwnedCleanup(
		async (): Promise<void> => {
			await props.prepareUtility();
			const productFrameRequested = props.resources.wait<void>({
				group,
				label: 'product frame requested',
			});
			const frameSpy = props.resources.spy({
				group,
				label: 'requestAnimationFrame interception',
				create: () => vi.spyOn(globalThis, 'requestAnimationFrame'),
			});
			frameSpyToken = frameSpy.token;
			frameSpy.spy.mockImplementation((callback: FrameRequestCallback): number => {
				productFrameRequested.resolve(undefined);
				const registration: { frameId?: number } = {};
				props.resources.register({
					group,
					kind: 'frame',
					label: 'intercepted native frame cancellation',
					restore: (): void => {
						if (registration.frameId !== undefined)
							originalCancelFrame.call(globalThis, registration.frameId);
					},
				});
				const frameId = originalRequestFrame.call(globalThis, (): void => {});
				registration.frameId = frameId;
				heldFrames.set(frameId, callback);
				return frameId;
			});
			const cancelSpy = props.resources.spy({
				group,
				label: 'cancelAnimationFrame interception',
				create: () => vi.spyOn(globalThis, 'cancelAnimationFrame'),
			});
			cancelSpyToken = cancelSpy.token;
			cancelSpy.spy.mockImplementation((frameId: number): void => {
				heldFrames.delete(frameId);
				originalCancelFrame.call(globalThis, frameId);
			});
			// Registered before the first await with interception installed; this also
			// runs from afterEach when this helper never reaches its own finally.
			props.resources.register({
				group,
				kind: 'frame',
				label: 'held-frame drain before spy restoration',
				restore: disposeHeldFrames,
			});
			await props.clickUtility();
			props.recordFrameWait?.();
			await productFrameRequested.promise;
			outcome = props.waitForComposer();
			const disposedOutcome = expect(outcome).rejects.toThrow('outcome wait disposed');
			let laterActCompleted = false;
			await actEvent(props.resources, group, (): void => {
				laterActCompleted = true;
			});
			expect(laterActCompleted).toBe(true);
			await props.dispose();
			await disposedOutcome;
		},
		(): Promise<void> => props.resources.releaseGroup(group),
	);
}

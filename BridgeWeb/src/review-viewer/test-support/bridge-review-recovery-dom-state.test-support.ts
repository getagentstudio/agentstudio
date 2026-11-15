import { act } from 'react';
import { afterEach, beforeEach } from 'vitest';

let ownerSignal: AbortSignal | undefined;
const activeObservations = new Map<(error: Error) => void, Node>();
const activeTargets = new Set<Node>();
const activeActs = new Set<Promise<unknown>>();

beforeEach((context): void => {
	ownerSignal = context.signal;
});
afterEach(async (): Promise<void> => {
	await retireBridgeReviewRecoveryWaits(new Error('Review recovery test teardown'));
	activeTargets.clear();
	ownerSignal = undefined;
});

export function bridgeReviewRecoveryOwnerSignal(): AbortSignal {
	if (ownerSignal === undefined) throw new Error('Review recovery wait has no test owner');
	return ownerSignal;
}

export async function retireBridgeReviewRecoveryWaits(error: Error): Promise<void> {
	for (const retire of activeObservations.keys()) retire(error);
	await Promise.allSettled(activeActs);
}

export function registerBridgeReviewRecoveryTarget(target: Node): () => void {
	activeTargets.add(target);
	return (): void => {
		activeTargets.delete(target);
		for (const [retire, observedTarget] of activeObservations) {
			if (target === observedTarget || target.contains(observedTarget)) {
				retire(new Error('Review recovery witness target retired'));
			}
		}
	};
}

function recoveryObservationTarget(target: Node | undefined): Node {
	if (target !== undefined) return target;
	if (activeTargets.size > 1)
		throw new Error('Review recovery wait requires an explicit target for multiple witnesses');
	return activeTargets.values().next().value ?? document.body;
}

export async function waitForBridgeReviewRecoveryDomState<TState>(props: {
	readonly readState: () => TState;
	readonly isExpected: (state: TState) => boolean;
	readonly label?: string;
	readonly signal?: AbortSignal;
	readonly target?: Node;
}): Promise<TState> {
	return await runBridgeReviewRecoveryAct(() => observeBridgeReviewRecoveryDomState(props));
}

export async function runBridgeReviewRecoveryAct<TState>(
	operation: () => Promise<TState>,
): Promise<TState> {
	let result: { readonly state: TState } | undefined;
	const completed = Promise.resolve(
		act(async (): Promise<void> => {
			result = { state: await operation() };
		}),
	);
	activeActs.add(completed);
	try {
		await completed;
		if (result === undefined) throw new Error('Review recovery act ended without its observation');
		return result.state;
	} finally {
		activeActs.delete(completed);
	}
}

function observeBridgeReviewRecoveryDomState<TState>(props: {
	readonly readState: () => TState;
	readonly isExpected: (state: TState) => boolean;
	readonly label?: string;
	readonly signal?: AbortSignal;
	readonly target?: Node;
}): Promise<TState> {
	const signals = new Set([
		bridgeReviewRecoveryOwnerSignal(),
		...(props.signal === undefined ? [] : [props.signal]),
	]);
	const target = recoveryObservationTarget(props.target);
	const label = props.label ?? props.readState.toString();
	return new Promise<TState>((resolve, reject): void => {
		let isFinished = false;
		const finish = (outcome: { readonly state: TState } | { readonly error: unknown }): void => {
			if (isFinished) return;
			isFinished = true;
			observer.disconnect();
			document.removeEventListener('scroll', publishWhenExpected, true);
			document.removeEventListener('scrollend', publishWhenExpected, true);
			for (const signal of signals) signal.removeEventListener('abort', abort);
			activeObservations.delete(retire);
			if ('error' in outcome)
				reject(
					new Error(
						`Awaiting Review DOM ${label}: ${outcome.error instanceof Error ? outcome.error.message : 'observation failed'}`,
						{ cause: outcome.error },
					),
				);
			else resolve(outcome.state);
		};
		const retire = (error: Error): void => {
			if (!isFinished) console.info(`Review DOM wait ended: ${label}; ${error.message}`);
			finish({ error });
		};
		const abort = (): void =>
			retire(
				new Error('Review recovery owner aborted', {
					cause: [...signals].find((signal) => signal.aborted)?.reason,
				}),
			);
		const observedRoots = new WeakSet<Node>();
		const observeRoot = (root: Node): void => {
			if (observedRoots.has(root)) return;
			observedRoots.add(root);
			observer.observe(root, {
				attributes: true,
				characterData: true,
				childList: true,
				subtree: true,
			});
		};
		const observeShadowRoots = (root: ParentNode): void => {
			for (const element of root.querySelectorAll('*')) {
				if (element.shadowRoot === null) continue;
				observeRoot(element.shadowRoot);
				observeShadowRoots(element.shadowRoot);
			}
		};
		const publishWhenExpected = (): void => {
			if (isFinished) return;
			if (!target.isConnected) {
				retire(new Error('Review recovery target retired'));
				return;
			}
			try {
				const state = props.readState();
				if (props.isExpected(state)) finish({ state });
			} catch (error: unknown) {
				finish({ error });
			}
		};
		const observer = new MutationObserver((): void => {
			if (isFinished) return;
			try {
				observeShadowRoots(document.documentElement);
				publishWhenExpected();
			} catch (error: unknown) {
				finish({ error });
			}
		});
		document.addEventListener('scroll', publishWhenExpected, true);
		document.addEventListener('scrollend', publishWhenExpected, true);
		activeObservations.set(retire, target);
		for (const signal of signals) signal.addEventListener('abort', abort, { once: true });
		if ([...signals].some((signal) => signal.aborted)) abort();
		else {
			try {
				observeRoot(document.documentElement);
				observeShadowRoots(document.documentElement);
				publishWhenExpected();
			} catch (error: unknown) {
				finish({ error });
			}
		}
	});
}

export async function scrollBridgeReviewRecoveryWitnessTo(props: {
	readonly scrollOwner: HTMLElement;
	readonly scrollTop: number;
}): Promise<void> {
	const signal = bridgeReviewRecoveryOwnerSignal();
	const scroll = async (): Promise<void> => {
		await new Promise<void>((resolve, reject): void => {
			if (signal.aborted) {
				reject(new Error('Review scroll owner aborted', { cause: signal.reason }));
				return;
			}
			if (!props.scrollOwner.isConnected) {
				reject(new Error('Review scroll target retired'));
				return;
			}
			const maximumScrollTop = Math.max(
				0,
				props.scrollOwner.scrollHeight - props.scrollOwner.clientHeight,
			);
			const nextScrollTop = Math.round(Math.max(0, Math.min(maximumScrollTop, props.scrollTop)));
			if (Math.abs(props.scrollOwner.scrollTop - nextScrollTop) <= 1) {
				resolve();
				return;
			}
			// Assigning scrollTop queues a native scroll event. A synthetic dispatch does not consume
			// that event: Pierre can render and publish React state again after the synthetic act ends.
			let isFinished = false;
			const finish = (error?: Error): void => {
				if (isFinished) return;
				isFinished = true;
				props.scrollOwner.removeEventListener('scrollend', complete);
				signal.removeEventListener('abort', abort);
				observer.disconnect();
				activeObservations.delete(retire);
				if (error === undefined) resolve();
				else reject(error);
			};
			const complete = (): void => finish();
			const retire = (error: Error): void => finish(error);
			const abort = (): void =>
				retire(new Error('Review scroll owner aborted', { cause: signal.reason }));
			const observer = new MutationObserver((): void => {
				if (!props.scrollOwner.isConnected) retire(new Error('Review scroll target retired'));
			});
			observer.observe(document.documentElement, { childList: true, subtree: true });
			props.scrollOwner.addEventListener('scrollend', complete, { once: true });
			signal.addEventListener('abort', abort, { once: true });
			activeObservations.set(retire, props.scrollOwner);
			if (signal.aborted) {
				abort();
				return;
			}
			if (!props.scrollOwner.isConnected) {
				retire(new Error('Review scroll target retired'));
				return;
			}
			try {
				props.scrollOwner.scrollTop = nextScrollTop;
			} catch (error: unknown) {
				retire(new Error('Review scroll write failed', { cause: error }));
			}
		});
	};
	const completed = Promise.resolve(act(scroll));
	activeActs.add(completed);
	try {
		await completed;
	} finally {
		activeActs.delete(completed);
	}
}

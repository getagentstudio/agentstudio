import { act } from 'react';

export async function waitForBridgeReviewRecoveryDomState<TState>(props: {
	readonly readState: () => TState;
	readonly isExpected: (state: TState) => boolean;
}): Promise<TState> {
	let observedState = props.readState();
	await act(async (): Promise<void> => {
		observedState = await observeBridgeReviewRecoveryDomState(props);
	});
	return observedState;
}

function observeBridgeReviewRecoveryDomState<TState>(props: {
	readonly readState: () => TState;
	readonly isExpected: (state: TState) => boolean;
}): Promise<TState> {
	const initialState = props.readState();
	if (props.isExpected(initialState)) return Promise.resolve(initialState);
	return new Promise<TState>((resolve): void => {
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
			const state = props.readState();
			if (!props.isExpected(state)) return;
			observer.disconnect();
			document.removeEventListener('scroll', publishWhenExpected, true);
			document.removeEventListener('scrollend', publishWhenExpected, true);
			resolve(state);
		};
		const observer = new MutationObserver((): void => {
			observeShadowRoots(document.documentElement);
			publishWhenExpected();
		});
		observeRoot(document.documentElement);
		observeShadowRoots(document.documentElement);
		document.addEventListener('scroll', publishWhenExpected, true);
		document.addEventListener('scrollend', publishWhenExpected, true);
		publishWhenExpected();
	});
}

export async function scrollBridgeReviewRecoveryWitnessTo(props: {
	readonly scrollOwner: HTMLElement;
	readonly scrollTop: number;
}): Promise<void> {
	await act(async (): Promise<void> => {
		const maximumScrollTop = Math.max(
			0,
			props.scrollOwner.scrollHeight - props.scrollOwner.clientHeight,
		);
		const nextScrollTop = Math.round(Math.max(0, Math.min(maximumScrollTop, props.scrollTop)));
		if (Math.abs(props.scrollOwner.scrollTop - nextScrollTop) <= 1) return;
		// Assigning scrollTop queues a native scroll event. A synthetic dispatch does not consume
		// that event: Pierre can render and publish React state again after the synthetic act ends.
		const scrollCompleted = new Promise<void>((resolve): void => {
			props.scrollOwner.addEventListener('scrollend', (): void => resolve(), { once: true });
		});
		props.scrollOwner.scrollTop = nextScrollTop;
		await scrollCompleted;
	});
}

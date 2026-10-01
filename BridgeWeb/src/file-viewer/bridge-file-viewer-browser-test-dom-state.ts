import { act } from 'react';

export async function waitForBridgeFileViewerBrowserDomState<TState>(props: {
	readonly readState: () => TState;
	readonly isExpected: (state: TState) => boolean;
}): Promise<TState> {
	let observedState = props.readState();
	await act(async (): Promise<void> => {
		if (props.isExpected(observedState)) return;
		observedState = await new Promise<TState>((resolve): void => {
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
				document.removeEventListener('focusin', publishWhenExpected, true);
				document.removeEventListener('focusout', publishWhenExpected, true);
				resolve(state);
			};
			const observer = new MutationObserver((): void => {
				observeShadowRoots(document.documentElement);
				publishWhenExpected();
			});
			observeRoot(document.documentElement);
			observeShadowRoots(document.documentElement);
			document.addEventListener('focusin', publishWhenExpected, true);
			document.addEventListener('focusout', publishWhenExpected, true);
			publishWhenExpected();
		});
	});
	return observedState;
}

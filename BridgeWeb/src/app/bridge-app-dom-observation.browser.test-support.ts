import { afterEach, beforeEach } from 'vitest';

import { BridgeProductTestFactRecorder } from '../core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';

type AppDomObservationRoot = Document | HTMLElement | ShadowRoot;

let currentTestSignal: AbortSignal | undefined;
const activeObservations = new Set<() => void>();

beforeEach((context): void => {
	currentTestSignal = context.signal;
});

afterEach((): void => {
	for (const close of activeObservations) close();
	activeObservations.clear();
	currentTestSignal = undefined;
});

/** Read only DOM-owned state; callback/counter waits must use their own fact recorder. */
export async function observeBridgeAppDomValue<TValue>(props: {
	readonly root?: AppDomObservationRoot;
	readonly getValue: () => TValue;
	readonly isSatisfied: (value: TValue) => boolean;
	readonly signal?: AbortSignal;
}): Promise<TValue> {
	const root = props.root ?? document;
	const signal = props.signal ?? currentTestSignal;
	if (signal === undefined) throw new Error('App DOM observation has no test owner signal.');
	const facts = new BridgeProductTestFactRecorder<TValue>();
	const observedRoots = new WeakSet<Node>();
	let isClosed = false;
	const close = (): void => {
		isClosed = true;
		facts.close(new Error('App DOM observation aborted or test owner retired.'));
	};
	const inspect = (): void => {
		if (isClosed) return;
		const value = props.getValue();
		if (props.isSatisfied(value)) facts.record(value);
	};
	const observeRoot = (nextRoot: AppDomObservationRoot): void => {
		if (observedRoots.has(nextRoot)) return;
		observedRoots.add(nextRoot);
		observer.observe(nextRoot, {
			attributes: true,
			childList: true,
			characterData: true,
			subtree: true,
		});
	};
	const observeShadowRoots = (parent: AppDomObservationRoot): void => {
		if (parent instanceof HTMLElement && parent.shadowRoot !== null) {
			observeRoot(parent.shadowRoot);
			observeShadowRoots(parent.shadowRoot);
		}
		for (const element of parent.querySelectorAll('*')) {
			if (element.shadowRoot === null) continue;
			observeRoot(element.shadowRoot);
			observeShadowRoots(element.shadowRoot);
		}
	};
	const observer = new MutationObserver((): void => {
		observeShadowRoots(root);
		inspect();
	});
	const events = ['focusin', 'focusout', 'input', 'change', 'scroll', 'scrollend'] as const;
	observeRoot(root);
	observeShadowRoots(root);
	for (const event of events) root.addEventListener(event, inspect, true);
	signal.addEventListener('abort', close, { once: true });
	activeObservations.add(close);
	try {
		if (signal.aborted) close();
		else inspect();
		// The caller awaits its writer inside act. Keeping act open while waiting for
		// a React DOM commit would prevent that same commit from draining the act queue.
		return await facts.waitFor();
	} finally {
		isClosed = true;
		observer.disconnect();
		for (const event of events) root.removeEventListener(event, inspect, true);
		signal.removeEventListener('abort', close);
		activeObservations.delete(close);
		facts.close(new Error('App DOM observation closed.'));
	}
}

export function observeBridgeAppDomUntilEqual<TValue>(
	getValue: () => TValue,
	expectedValue: TValue,
	root?: AppDomObservationRoot,
): Promise<TValue> {
	return observeBridgeAppDomValue({
		getValue,
		isSatisfied: (value): boolean => value === expectedValue,
		...(root === undefined ? {} : { root }),
	});
}

export function observeBridgeAppDomUntilTruthy<TValue>(
	getValue: () => TValue,
	root?: AppDomObservationRoot,
): Promise<TValue> {
	return observeBridgeAppDomValue({
		getValue,
		isSatisfied: (value): boolean => Boolean(value),
		...(root === undefined ? {} : { root }),
	});
}

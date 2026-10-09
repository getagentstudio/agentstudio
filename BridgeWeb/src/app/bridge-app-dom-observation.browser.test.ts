import { expect, test, vi } from 'vitest';

import { observeBridgeAppDomValue } from './bridge-app-dom-observation.browser.test-support.js';

test('a retired app DOM observation closes through its signal instead of a timer result', async (): Promise<void> => {
	vi.useFakeTimers();
	const signalOwner = new AbortController();
	const observation = {
		root: document,
		getValue: (): Element | null => document.querySelector('[data-bw-held-dom]'),
		isSatisfied: (element: Element | null): boolean => element !== null,
		signal: signalOwner.signal,
	};
	const outcome = observeBridgeAppDomValue(observation).then(
		(): string => 'unexpected DOM completion',
		(error: unknown): string => String(error),
	);
	try {
		signalOwner.abort();
		// Reproduce the former oracle's outcome using only its controlled virtual clock.
		await vi.advanceTimersByTimeAsync(5_000);
		expect(await outcome).toContain('App DOM observation aborted');
	} finally {
		vi.useRealTimers();
	}
});

test('observes the exact target in a newly mounted open shadow root', async (): Promise<void> => {
	const host = document.createElement('div');
	const owner = new AbortController();
	let targetShadowRoot: ShadowRoot | null = null;
	const observed = observeBridgeAppDomValue({
		root: document,
		getValue: (): Element | null =>
			targetShadowRoot?.querySelector('[data-bw-target="ready"]') ?? null,
		isSatisfied: (value): boolean => value !== null,
		signal: owner.signal,
	});
	const root = host.attachShadow({ mode: 'open' });
	targetShadowRoot = root;
	document.body.append(host);
	const unrelated = document.createElement('span');
	unrelated.dataset['bwTarget'] = 'unrelated';
	root.append(unrelated);
	const target = document.createElement('span');
	target.dataset['bwTarget'] = 'ready';
	root.append(target);
	try {
		expect(await observed).toBe(target);
	} finally {
		owner.abort();
		host.remove();
	}
});

test('observes a native focus change rather than a DOM attribute sample', async (): Promise<void> => {
	const target = document.createElement('button');
	document.body.append(target);
	const observed = observeBridgeAppDomValue({
		root: document,
		getValue: (): Element | null => document.activeElement,
		isSatisfied: (element): boolean => element === target,
	});
	target.focus();
	try {
		expect(await observed).toBe(target);
	} finally {
		target.remove();
	}
});

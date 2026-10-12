import { runInNewContext } from 'node:vm';

import { expect, test } from 'vitest';

import { observeReviewPaintReceipt } from './product-only-real-router-review-paint-observation.ts';

// Execute the actual serializable callback in a Node VM with a DOM protocol double.
// No animation-frame or timer API is provided to the page callback.
function observationFixture(props: { readonly alreadyPainted?: boolean } = {}): {
	readonly cancelled: () => void;
	readonly disconnected: () => boolean;
	readonly listenerCount: () => number;
	readonly observedRootCount: () => number;
	readonly publish: (itemId: string, publicationId: string) => void;
	readonly receipt: Promise<unknown>;
} {
	const attributes = new Map<string, string>();
	let mutationObserved = (): void => {};
	let disconnected = false;
	const observedRoots = new Set<unknown>();
	const marker = { getAttribute: (): string => 'item-a' };
	const shadowRoot = {
		querySelector: (): typeof marker => marker,
		querySelectorAll: (): readonly never[] => [],
	};
	const host = {
		getAttribute: (attribute: string): string | null => attributes.get(attribute) ?? null,
		querySelector: (): null => null,
		shadowRoot,
	};
	const listeners = new Map<string, (event: Event) => void>();
	class FixtureCustomEvent extends Event {
		readonly detail: string;
		constructor(type: string, detail: string) {
			super(type);
			this.detail = detail;
		}
	}
	const eventSource = {
		addEventListener: (type: string, callback: (event: Event) => void): void => {
			listeners.set(type, callback);
		},
		removeEventListener: (type: string): void => {
			listeners.delete(type);
		},
	};
	const publish = (itemId: string, publicationId: string): void => {
		attributes.set('data-bridge-painted-publication-id', publicationId);
		attributes.set(
			'data-bridge-painted-source-correlations',
			JSON.stringify([{ semanticItemId: itemId, publicationId }]),
		);
		mutationObserved();
	};
	if (props.alreadyPainted === true) publish('item-a', 'publication-initial');
	const result: unknown = runInNewContext(
		`(${observeReviewPaintReceipt.toString()})({ itemId: 'item-a' })`,
		{
			CustomEvent: FixtureCustomEvent,
			document: {
				...eventSource,
				querySelectorAll: (): readonly (typeof host)[] => [host],
			},
			MutationObserver: class {
				constructor(callback: () => void) {
					mutationObserved = callback;
				}
				observe(root: unknown): void {
					observedRoots.add(root);
				}
				disconnect(): void {
					disconnected = true;
				}
			},
			window: eventSource,
		},
	);
	return {
		cancelled: (): void => {
			listeners.get('__bridge_review_paint_cancel')?.(
				new FixtureCustomEvent('__bridge_review_paint_cancel', 'item-a'),
			);
		},
		disconnected: (): boolean => disconnected,
		listenerCount: (): number => listeners.size,
		observedRootCount: (): number => observedRoots.size,
		publish,
		receipt: Promise.resolve(result),
	};
}

test('resolves an exact receipt published after observation attaches, without a frame loop', async () => {
	const fixture = observationFixture();
	expect(fixture.observedRootCount()).toBe(2); // document and renderer shadow root
	fixture.publish('different-item', 'publication-a');
	expect(fixture.disconnected()).toBe(false);
	fixture.publish('item-a', 'publication-a');
	expect(await fixture.receipt).toEqual({ publicationId: 'publication-a' });
	expect(fixture.disconnected()).toBe(true);
	expect(fixture.listenerCount()).toBe(0);
});

test('initially published receipt settles and retires observation', async () => {
	const fixture = observationFixture({ alreadyPainted: true });
	expect(await fixture.receipt).toEqual({ publicationId: 'publication-initial' });
	expect(fixture.disconnected()).toBe(true);
	expect(fixture.listenerCount()).toBe(0);
});

test('owner cancellation retires observer and listeners', async () => {
	const fixture = observationFixture();
	const failedReceipt = expect(fixture.receipt).rejects.toThrow('cancelled by journey owner');
	fixture.cancelled();
	await failedReceipt;
	expect(fixture.disconnected()).toBe(true);
	expect(fixture.listenerCount()).toBe(0);
});

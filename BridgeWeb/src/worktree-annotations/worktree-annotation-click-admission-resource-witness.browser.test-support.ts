import { expect, vi } from 'vitest';

import { nextAnimationFrame } from './worktree-annotation-click-admission-render.browser.test-support.js';
import { ClickAdmissionResourceOwner } from './worktree-annotation-click-admission-resource-owner.browser.test-support.js';

function noWitnessAction(): void {}

export type ResourceWitnessKind =
	| 'prototype patch'
	| 'frame spy'
	| 'observer'
	| 'outcome wait'
	| 'frame wait';
export interface ResourceWitnessReceipt {
	readonly assertRestored: () => void;
	readonly assertNoOldCallback: () => void;
}

export async function proveResourceRelease(
	resources: ClickAdmissionResourceOwner,
	kind: ResourceWitnessKind,
): Promise<ResourceWitnessReceipt> {
	const group = resources.createGroup(`generic witness: ${kind}`);
	const originalRequestFrame = globalThis.requestAnimationFrame;
	const originalCancelFrame = globalThis.cancelAnimationFrame;
	let oldCallbackCount = 0;
	let stimulate: () => void = noWitnessAction;
	let assertKindRestored: () => void = noWitnessAction;
	const pending = resources.wait<void>({ group, label: `pending ${kind}` });
	let wait: Promise<void> = pending.promise;
	void wait.then(
		(): void => {
			oldCallbackCount += 1;
		},
		(): void => {},
	);

	if (kind === 'prototype patch') {
		class WitnessPrototype {
			publish(this: void): void {}
		}
		const original = WitnessPrototype.prototype.publish;
		resources.patch({
			group,
			label: 'generic prototype witness',
			target: WitnessPrototype.prototype,
			key: 'publish',
			value: (): void => pending.resolve(undefined),
		});
		assertKindRestored = (): void => {
			expect(WitnessPrototype.prototype.publish).toBe(original);
		};
		stimulate = (): void => new WitnessPrototype().publish();
	} else if (kind === 'frame spy') {
		const request = resources.spy({
			group,
			label: 'generic frame-spy witness',
			create: () => vi.spyOn(globalThis, 'requestAnimationFrame'),
		});
		request.spy.mockImplementation((): number => {
			oldCallbackCount += 1;
			pending.resolve(undefined);
			return 0;
		});
		resources.spy({
			group,
			label: 'generic cancel-spy witness',
			create: () => vi.spyOn(globalThis, 'cancelAnimationFrame'),
		});
	} else if (kind === 'observer') {
		const target = document.createElement('div');
		const observer = new MutationObserver((): void => {
			oldCallbackCount += 1;
			pending.resolve(undefined);
		});
		resources.register({
			group,
			kind: 'observer',
			label: 'generic native observer witness',
			restore: (): void => observer.disconnect(),
		});
		observer.observe(target, { childList: true });
		stimulate = (): void => {
			target.append(document.createElement('span'));
		};
		assertKindRestored = (): void => {
			expect(observer.takeRecords()).toHaveLength(0);
		};
	} else if (kind === 'frame wait') {
		const request = resources.spy({
			group,
			label: 'withheld test frame witness',
			create: () => vi.spyOn(globalThis, 'requestAnimationFrame'),
		});
		request.spy.mockImplementation((): number => 0);
		wait = nextAnimationFrame(resources, group);
		void wait.then(
			(): void => {
				oldCallbackCount += 1;
			},
			(): void => {},
		);
	} else {
		stimulate = (): void => pending.resolve(undefined);
	}

	const rejection = expect(wait).rejects.toEqual(
		new Error('Click-admission outcome wait disposed.'),
	);
	const disposal = resources.dispose();
	expect(resources.dispose()).toBe(disposal);
	await disposal;
	await rejection;
	stimulate();
	const assertRestored = (): void => {
		expect(globalThis.requestAnimationFrame).toBe(originalRequestFrame);
		expect(globalThis.cancelAnimationFrame).toBe(originalCancelFrame);
		assertKindRestored();
	};
	const assertNoOldCallback = (): void => {
		expect(oldCallbackCount).toBe(0);
	};
	assertRestored();
	assertNoOldCallback();
	return { assertRestored, assertNoOldCallback };
}

import { expect, test } from 'vitest';

import { proveHeldProductFrameIsolation } from './worktree-annotation-click-admission-render.browser.test-support.js';
import { ClickAdmissionResourceOwner } from './worktree-annotation-click-admission-resource-owner.browser.test-support.js';
import {
	proveResourceRelease,
	type ResourceWitnessReceipt,
	type ResourceWitnessKind,
} from './worktree-annotation-click-admission-resource-witness.browser.test-support.js';

export function registerResourceWitnessCases(props: {
	readonly resources: () => ClickAdmissionResourceOwner;
	readonly admitLater: () => Promise<void>;
	readonly disposeOwner: () => Promise<void>;
}): void {
	let leakWitness: ResourceWitnessReceipt | undefined;
	let cascadeWitness:
		| {
				readonly requestFrame: typeof requestAnimationFrame;
				readonly cancelFrame: typeof cancelAnimationFrame;
				didEnterWait: boolean;
				oldCallbackWoke: boolean;
		  }
		| undefined;

	for (const kind of [
		'prototype patch',
		'frame spy',
		'observer',
		'outcome wait',
		'frame wait',
	] satisfies readonly ResourceWitnessKind[]) {
		test(`test-owner releases pending ${kind}`, async () => {
			leakWitness = await proveResourceRelease(props.resources(), kind);
		});
		test(`later real harness stays clean after ${kind}`, async () => {
			if (leakWitness === undefined) throw new Error('Expected the preceding resource witness.');
			leakWitness.assertRestored();
			await props.admitLater();
			leakWitness.assertNoOldCallback();
		});
	}

	test('afterEach disposal releases an undisposed frame group deterministically', async () => {
		const resources = props.resources();
		const witnessGroup = resources.createGroup('afterEach cascade witness');
		const entered = resources.wait<void>({ group: witnessGroup, label: 'product wait entered' });
		cascadeWitness = {
			requestFrame: globalThis.requestAnimationFrame,
			cancelFrame: globalThis.cancelAnimationFrame,
			didEnterWait: false,
			oldCallbackWoke: false,
		};
		const witness = cascadeWitness;
		const operation = proveHeldProductFrameIsolation({
			resources,
			prepareUtility: async (): Promise<void> => {},
			clickUtility: async (): Promise<void> => {},
			recordFrameWait: (): void => {
				witness.didEnterWait = true;
				entered.resolve(undefined);
			},
			waitForComposer: (): Promise<void> => {
				witness.oldCallbackWoke = true;
				return Promise.reject(new Error('Click-admission outcome wait disposed.'));
			},
			dispose: async (): Promise<void> => {},
		});
		const rejection = expect(operation).rejects.toEqual(
			new Error('Click-admission outcome wait disposed.'),
		);
		await entered.promise;
		// Invoke the EXACT function registered as afterEach. The frame helper and
		// its group have not disposed themselves; no runner hang bound is involved.
		await props.disposeOwner();
		await rejection;
		expect(globalThis.requestAnimationFrame).toBe(witness.requestFrame);
		expect(globalThis.cancelAnimationFrame).toBe(witness.cancelFrame);
		expect(witness.oldCallbackWoke).toBe(false);
	});

	test('next test is clean after undisposed-group afterEach cleanup', async () => {
		if (cascadeWitness === undefined) throw new Error('Expected the afterEach-cascade witness.');
		expect(cascadeWitness.didEnterWait).toBe(true);
		expect(globalThis.requestAnimationFrame).toBe(cascadeWitness.requestFrame);
		expect(globalThis.cancelAnimationFrame).toBe(cascadeWitness.cancelFrame);
		await props.admitLater();
		expect(cascadeWitness.oldCallbackWoke).toBe(false);
	});
}

import { act } from 'react';
import { describe, expect, test } from 'vitest';

import {
	retireBridgeReviewRecoveryWaits,
	registerBridgeReviewRecoveryTarget,
	scrollBridgeReviewRecoveryWitnessTo,
	waitForBridgeReviewRecoveryDomState,
} from './bridge-review-recovery-dom-state.test-support.js';
import {
	disposeBridgeReviewRecoveryWitnessHarnesses,
	makeBridgeReviewRecoveryWitnessFiles,
	renderBridgeReviewRecoveryWitness,
} from './bridge-viewer-browser.recovery-witness.test-support.js';

describe('Review recovery wait retirement', () => {
	test('runner abort retires a pending act before a late update in the next scope', async () => {
		// Arrange — the owner abort is the same causal end used by the runner's hang bound.
		const owner = new AbortController();
		const target = document.createElement('div');
		document.body.append(target);
		const waitProps = {
			label: 'held Review metadata arrival',
			readState: (): boolean => target.dataset['ready'] === 'true',
			isExpected: (ready: boolean): boolean => ready,
			signal: owner.signal,
			target,
		};
		const outcome = waitForBridgeReviewRecoveryDomState(waitProps).then(
			(value) => ({ kind: 'completed', value }) as const,
			(error: unknown) => ({ kind: 'retired', error }) as const,
		);

		// Act — a failed owner must not keep its act open into a successor's update.
		owner.abort(new Error('runner owner ended'));
		await retireBridgeReviewRecoveryWaits(new Error('runner teardown'));
		await act(async (): Promise<void> => {
			target.dataset['ready'] = 'true';
			await outcome;
		});

		// Assert — late success cannot reopen retired work or corrupt the next act scope.
		expect(await outcome).toMatchObject({ kind: 'retired' });
	});

	test('target retirement rejects the pending arrival instead of leaving an observer behind', async () => {
		// Arrange
		const target = document.createElement('div');
		document.body.append(target);
		const outcome = waitForBridgeReviewRecoveryDomState({
			label: 'retiring Review panel',
			target,
			readState: (): boolean => target.dataset['ready'] === 'true',
			isExpected: (ready: boolean): boolean => ready,
		});
		const retired = expect(outcome).rejects.toThrow(
			'retiring Review panel: Review recovery target retired',
		);

		// Act / Assert
		target.remove();
		await retired;
		await act(async (): Promise<void> => {});
	});

	test('a failed state read ends the wait with its primary error', async () => {
		// Arrange
		const failure = new Error('Review pane unavailable');
		// Act / Assert
		await expect(
			waitForBridgeReviewRecoveryDomState({
				label: 'Review pane read',
				readState: (): boolean => {
					throw failure;
				},
				isExpected: (ready: boolean): boolean => ready,
			}),
		).rejects.toThrow('Review pane read: Review pane unavailable');
	});

	test('an implicit fixture target ends its wait when its subtree retires', async () => {
		// Arrange — existing R68 call sites inherit fixture ownership without changing their oracle.
		const target = document.createElement('div');
		document.body.append(target);
		const retireTarget = registerBridgeReviewRecoveryTarget(target);
		const outcome = waitForBridgeReviewRecoveryDomState({
			label: 'registered Review fixture',
			readState: (): boolean => target.dataset['ready'] === 'true',
			isExpected: (ready: boolean): boolean => ready,
		});
		const retired = expect(outcome).rejects.toThrow('Review recovery witness target retired');
		// Act / Assert
		retireTarget();
		await retired;
	});

	test('teardown closes a held native scroll act before the next scope', async () => {
		// Arrange — hold the browser's scroll completion, without a wall-clock wait.
		const target = document.createElement('div');
		document.body.append(target);
		Object.defineProperties(target, {
			clientHeight: { value: 10 },
			scrollHeight: { value: 100 },
			scrollTop: { get: (): number => 0, set: (_value: number): void => {} },
		});
		const outcome = scrollBridgeReviewRecoveryWitnessTo({ scrollOwner: target, scrollTop: 50 });
		const retired = expect(outcome).rejects.toThrow('Review fixture cleanup');

		// Act
		await retireBridgeReviewRecoveryWaits(new Error('Review fixture cleanup'));
		await retired;

		// Assert — the retired scroll event cannot affect a successor act.
		await act(async (): Promise<void> => {
			target.dispatchEvent(new Event('scrollend'));
		});
	});

	test('fixture retirement ends a command-fact wait whose producer did not arrive', async () => {
		// Arrange — a mounted witness has no selection command until metadata is published.
		const harness = await renderBridgeReviewRecoveryWitness(
			makeBridgeReviewRecoveryWitnessFiles({
				count: 1,
				lineCount: 2,
				markerPrefix: 'RETIRED_COMMAND',
			}),
		);
		const pending = harness.workerEventSeam.waitForSentRequest(
			(request): boolean => request.command.command === 'select',
			'Review selection before fixture retirement',
		);
		const retired = expect(pending).rejects.toThrow('Review recovery witness disposed');

		// Act / Assert — no DOM mutation is needed to close the command producer's own fact source.
		disposeBridgeReviewRecoveryWitnessHarnesses();
		await retired;
		await act(async (): Promise<void> => {});
	});
});

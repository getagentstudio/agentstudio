import { expect, onTestFinished, vi } from 'vitest';

import { readBridgeCommWorkerAbsoluteNowMilliseconds } from './bridge-comm-worker-clock.js';
import type { BridgeCommWorkerPort } from './bridge-comm-worker-entry.js';
import * as runtimeProtocol from './bridge-comm-worker-runtime-protocol.js';
import type { RegisterBridgeCommWorkerRuntimePortProtocolProps } from './bridge-comm-worker-runtime-protocol.js';
import { ControlledBatchDeadlineClock } from './bridge-product-view-batch-receiver.test-support.js';

type RenderFulfillmentWakeScheduler = NonNullable<
	RegisterBridgeCommWorkerRuntimePortProtocolProps['scheduleRenderFulfillmentWake']
>;

export interface ExpectedRetainedRenderWakes {
	readonly count: number;
	readonly reason: string;
	/** A real renderer may discharge all declared captures before fixture disposal. */
	readonly allowFullyDischarged?: boolean;
}

export interface RegisterTestBridgeCommWorkerRuntimeProps extends RegisterBridgeCommWorkerRuntimePortProtocolProps {
	readonly expectedRetainedRenderWakes?: ExpectedRetainedRenderWakes;
}

export interface TestBridgeCommWorkerRenderWakes {
	readonly clock: ControlledBatchDeadlineClock;
	readonly pendingWakeCount: () => number;
	readonly expectRetainedWakes: (expectation: ExpectedRetainedRenderWakes) => void;
	readonly retirementRemainderCount: () => number | null;
	readonly retire: () => void;
	readonly schedule: RenderFulfillmentWakeScheduler;
}

export function createTestBridgeCommWorkerRenderWakes(
	scheduleOverride?: RenderFulfillmentWakeScheduler,
	now: () => number = readBridgeCommWorkerAbsoluteNowMilliseconds,
): TestBridgeCommWorkerRenderWakes {
	const clock = new ControlledBatchDeadlineClock(now);
	const cancelWakes = new Set<() => void>();
	let retired = false;
	let expectedRemainder: ExpectedRetainedRenderWakes = {
		count: 0,
		reason: 'No undelivered render wake is expected at fixture retirement.',
	};
	let retirementRemainderCount: number | null = null;
	const retire = (): void => {
		if (retired) return;
		retirementRemainderCount = cancelWakes.size;
		retired = true;
		try {
			expect(
				retirementRemainderCount,
				`Unexpected retained render wakes: ${expectedRemainder.reason}`,
			).toBe(
				expectedRemainder.allowFullyDischarged === true && retirementRemainderCount === 0
					? 0
					: expectedRemainder.count,
			);
		} finally {
			for (const cancel of cancelWakes) cancel();
			clock.retire();
		}
	};
	onTestFinished(retire);
	return {
		clock,
		expectRetainedWakes: (expectation): void => {
			if (retired) throw new Error('Cannot declare render wakes after fixture retirement.');
			expectedRemainder = { ...expectation };
		},
		pendingWakeCount: (): number => cancelWakes.size,
		retirementRemainderCount: (): number | null => retirementRemainderCount,
		retire,
		schedule: (delayMilliseconds, wake): (() => void) => {
			if (retired) throw new Error('Cannot schedule a render wake after test fixture retirement.');
			let pending = true;
			let cancelCapture: (() => void) | null = null;
			const cancel = (): void => {
				pending = false;
				cancelWakes.delete(cancel);
				cancelCapture?.();
			};
			const deliverWake = (): void => {
				pending = false;
				cancelWakes.delete(cancel);
				wake();
			};
			cancelCapture =
				scheduleOverride === undefined
					? clock.schedule(delayMilliseconds, deliverWake)
					: scheduleOverride(delayMilliseconds, deliverWake);
			if (pending) cancelWakes.add(cancel);
			return cancel;
		},
	};
}

export function registerTestBridgeCommWorkerRuntimePortProtocol(
	port: BridgeCommWorkerPort,
	props: RegisterTestBridgeCommWorkerRuntimeProps,
): TestBridgeCommWorkerRenderWakes {
	const { expectedRetainedRenderWakes, ...runtimeProps } = props;
	const renderWakes = createTestBridgeCommWorkerRenderWakes(
		props.scheduleRenderFulfillmentWake,
		props.now,
	);
	if (expectedRetainedRenderWakes !== undefined) {
		renderWakes.expectRetainedWakes(expectedRetainedRenderWakes);
	}
	runtimeProtocol.registerBridgeCommWorkerRuntimePortProtocol(port, {
		...runtimeProps,
		scheduleRenderFulfillmentWake: renderWakes.schedule,
	});
	return renderWakes;
}

// Entry bootstrap does not expose runtime scheduler props. Keep its real registration
// and runtime, and inject only the test-owned clock at that existing boundary.
export function installTestBridgeCommWorkerEntryRenderWakes(): {
	readonly latestRuntime: () => TestBridgeCommWorkerRenderWakes;
} {
	let latestRenderWakes: TestBridgeCommWorkerRenderWakes | null = null;
	const registerRuntime = runtimeProtocol.registerBridgeCommWorkerRuntimePortProtocol;
	const registrationSpy = vi
		.spyOn(runtimeProtocol, 'registerBridgeCommWorkerRuntimePortProtocol')
		.mockImplementation((port, props): void => {
			const renderWakes = createTestBridgeCommWorkerRenderWakes(
				props.scheduleRenderFulfillmentWake,
				props.now,
			);
			latestRenderWakes = renderWakes;
			registerRuntime(port, { ...props, scheduleRenderFulfillmentWake: renderWakes.schedule });
		});
	onTestFinished((): void => {
		registrationSpy.mockRestore();
	});
	return {
		latestRuntime: (): TestBridgeCommWorkerRenderWakes => {
			if (latestRenderWakes === null)
				throw new Error('The test entry has not registered a runtime.');
			return latestRenderWakes;
		},
	};
}

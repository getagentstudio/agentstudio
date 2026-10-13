import { expect, onTestFinished, vi } from 'vitest';

import { readBridgeCommWorkerAbsoluteNowMilliseconds } from './bridge-comm-worker-clock.js';
import type { BridgeCommWorkerPort } from './bridge-comm-worker-entry.js';
import * as runtimeProtocol from './bridge-comm-worker-runtime-protocol.js';
import type { RegisterBridgeCommWorkerRuntimePortProtocolProps } from './bridge-comm-worker-runtime-protocol.js';
import { ControlledBatchDeadlineClock } from './bridge-product-view-batch-receiver.test-support.js';

type RenderFulfillmentWakeScheduler = NonNullable<
	RegisterBridgeCommWorkerRuntimePortProtocolProps['scheduleRenderFulfillmentWake']
>;

export interface TestBridgeCommWorkerRenderWakes {
	readonly clock: ControlledBatchDeadlineClock;
	readonly pendingWakeCount: () => number;
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
	const retire = (): void => {
		retired = true;
		for (const cancel of cancelWakes) cancel();
		clock.retire();
		expect(cancelWakes.size).toBe(0);
		expect(clock.deadlines.filter((deadline) => deadline.active)).toEqual([]);
	};
	onTestFinished(retire);
	return {
		clock,
		pendingWakeCount: (): number => cancelWakes.size,
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
	props: RegisterBridgeCommWorkerRuntimePortProtocolProps,
): TestBridgeCommWorkerRenderWakes {
	const renderWakes = createTestBridgeCommWorkerRenderWakes(
		props.scheduleRenderFulfillmentWake,
		props.now,
	);
	runtimeProtocol.registerBridgeCommWorkerRuntimePortProtocol(port, {
		...props,
		scheduleRenderFulfillmentWake: renderWakes.schedule,
	});
	return renderWakes;
}

// Entry bootstrap does not expose runtime scheduler props. Keep its real registration
// and runtime, and inject only the test-owned clock at that existing boundary.
export function installTestBridgeCommWorkerEntryRenderWakes(): void {
	const registerRuntime = runtimeProtocol.registerBridgeCommWorkerRuntimePortProtocol;
	const registrationSpy = vi
		.spyOn(runtimeProtocol, 'registerBridgeCommWorkerRuntimePortProtocol')
		.mockImplementation((port, props): void => {
			const renderWakes = createTestBridgeCommWorkerRenderWakes(
				props.scheduleRenderFulfillmentWake,
				props.now,
			);
			registerRuntime(port, { ...props, scheduleRenderFulfillmentWake: renderWakes.schedule });
		});
	onTestFinished((): void => {
		registrationSpy.mockRestore();
	});
}

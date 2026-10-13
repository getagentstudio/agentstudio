import { describe, expect, test, vi } from 'vitest';

import { createTestBridgeCommWorkerRenderWakes } from './bridge-comm-worker-runtime-protocol.fixture.test-support.js';

describe('Comm runtime fixture render-wake ownership', () => {
	test('captures deadlines without a native timer and retires undelivered callbacks', () => {
		const scheduleTimer = vi.spyOn(globalThis, 'setTimeout');
		try {
			const renderWakes = createTestBridgeCommWorkerRenderWakes();
			const delivered: string[] = [];
			renderWakes.schedule(5_000, (): void => {
				delivered.push('receipt-expiry');
			});
			const capturedWake = renderWakes.clock.activeDeadline();
			expect(scheduleTimer).not.toHaveBeenCalled();
			expect(renderWakes.pendingWakeCount()).toBe(1);
			renderWakes.retire();
			expect(renderWakes.pendingWakeCount()).toBe(0);
			expect((): void => capturedWake.fire()).toThrow('Expected an armed batch deadline.');
			expect(delivered).toEqual([]);
			expect((): void => {
				renderWakes.schedule(25, (): void => {});
			}).toThrow('after test fixture retirement');
		} finally {
			scheduleTimer.mockRestore();
		}
	});

	test('delivers only the captured deadline and discharges its pending ownership', () => {
		const renderWakes = createTestBridgeCommWorkerRenderWakes();
		const delivered: string[] = [];
		renderWakes.schedule(5_000, (): void => {
			delivered.push('receipt-expiry');
		});
		renderWakes.schedule(25, (): void => {
			delivered.push('retry');
		});
		renderWakes.clock.activeDeadline().fire();
		expect(delivered).toEqual(['receipt-expiry']);
		expect(renderWakes.pendingWakeCount()).toBe(1);
		renderWakes.retire();
		expect(renderWakes.pendingWakeCount()).toBe(0);
		expect(delivered).toEqual(['receipt-expiry']);
	});

	test('retirement cancels retained captures from an explicitly supplied scheduler', () => {
		const cancelCapture = vi.fn<() => void>();
		const renderWakes = createTestBridgeCommWorkerRenderWakes(() => cancelCapture);
		renderWakes.schedule(5_000, (): void => {});
		expect(cancelCapture).not.toHaveBeenCalled();
		renderWakes.retire();
		renderWakes.retire();
		expect(cancelCapture).toHaveBeenCalledOnce();
		expect(renderWakes.pendingWakeCount()).toBe(0);
	});
});

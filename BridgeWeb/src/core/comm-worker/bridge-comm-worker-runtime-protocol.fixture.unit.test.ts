import { describe, expect, test, vi } from 'vitest';

import { createTestBridgeCommWorkerRenderWakes } from './bridge-comm-worker-runtime-protocol.fixture.test-support.js';

describe('Comm runtime fixture render-wake ownership', () => {
	test('rejects an unexpected undelivered capture and still cancels it', () => {
		const renderWakes = createTestBridgeCommWorkerRenderWakes();
		const delivered: string[] = [];
		renderWakes.schedule(5_000, (): void => {
			delivered.push('unexpected callback');
		});
		const capturedWake = renderWakes.clock.activeDeadline();
		expect((): void => renderWakes.retire()).toThrow(/Unexpected retained render wakes/);
		expect(renderWakes.retirementRemainderCount()).toBe(1);
		expect(renderWakes.pendingWakeCount()).toBe(0);
		expect((): void => capturedWake.fire()).toThrow('Expected an armed batch deadline.');
		expect(delivered).toEqual([]);
	});

	test('cancels a declared intentional remainder without a native timer', () => {
		const scheduleTimer = vi.spyOn(globalThis, 'setTimeout');
		try {
			const renderWakes = createTestBridgeCommWorkerRenderWakes();
			renderWakes.expectRetainedWakes({
				count: 1,
				reason: 'This case intentionally retains its lease.',
			});
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

	test('permits a discharged declared lease but rejects an extra capture', () => {
		const discharged = createTestBridgeCommWorkerRenderWakes();
		discharged.expectRetainedWakes({
			count: 1,
			allowFullyDischarged: true,
			reason: 'The renderer may finish before teardown.',
		});
		discharged.schedule(5_000, (): void => {})();
		discharged.retire();
		expect(discharged.retirementRemainderCount()).toBe(0);
		const extraCapture = createTestBridgeCommWorkerRenderWakes();
		extraCapture.expectRetainedWakes({
			count: 1,
			allowFullyDischarged: true,
			reason: 'Only one lease is declared.',
		});
		extraCapture.schedule(5_000, (): void => {});
		extraCapture.schedule(25, (): void => {});
		expect((): void => extraCapture.retire()).toThrow(/Unexpected retained render wakes/);
		expect(extraCapture.retirementRemainderCount()).toBe(2);
		expect(extraCapture.pendingWakeCount()).toBe(0);
	});

	test('delivers only the captured deadline and discharges its pending ownership', () => {
		const renderWakes = createTestBridgeCommWorkerRenderWakes();
		renderWakes.expectRetainedWakes({
			count: 1,
			reason: 'Only the receipt expiry is delivered in this case.',
		});
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
		renderWakes.expectRetainedWakes({
			count: 1,
			reason: 'This case proves cancellation of a retained custom capture.',
		});
		renderWakes.schedule(5_000, (): void => {});
		expect(cancelCapture).not.toHaveBeenCalled();
		renderWakes.retire();
		renderWakes.retire();
		expect(cancelCapture).toHaveBeenCalledOnce();
		expect(renderWakes.pendingWakeCount()).toBe(0);
	});
});

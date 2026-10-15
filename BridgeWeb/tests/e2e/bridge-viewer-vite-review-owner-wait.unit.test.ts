import { describe, expect, test } from 'vitest';

import { reviewWaitTerminalOwner } from './bridge-viewer-vite-review-owner-wait.ts';

describe('Review wait terminal owner disposition', () => {
	test.each([
		'awaiting_bootstrap',
		'bootstrapping',
		'ready',
		'replacement_requested',
		'disposed',
		'failedRetryable',
		'recovering',
		null,
	])('keeps %s pending without an inactive refusal', (workerSessionState) => {
		expect(reviewWaitTerminalOwner({ inactiveSession: false, workerSessionState })).toBeNull();
	});
	test('ends on the worker owner replacement budget exhaustion', () => {
		expect(reviewWaitTerminalOwner({ inactiveSession: false, workerSessionState: 'failed' })).toBe(
			'worker-recovery-exhausted',
		);
	});
	test('the inactive refusal ends the document even if an old worker was ready', () => {
		expect(reviewWaitTerminalOwner({ inactiveSession: true, workerSessionState: 'ready' })).toBe(
			'open-elsewhere',
		);
	});
});

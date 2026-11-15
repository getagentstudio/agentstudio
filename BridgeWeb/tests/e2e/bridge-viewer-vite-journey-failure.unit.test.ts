import { expect, test } from 'vitest';

import { appendJourneyFailureDiagnostics } from './bridge-viewer-vite-journey-failure.ts';

test('a failed page read preserves the primary owner error and records the diagnostic gap', async () => {
	const ownerFailure = new Error('selected content: descriptor_rejected');
	const primaryError = new Error('File metadata direct failed', { cause: ownerFailure });
	await appendJourneyFailureDiagnostics({
		primaryError,
		reads: [
			{
				name: 'page',
				read: (): never => {
					throw new Error('Target page has been closed');
				},
			},
			{ name: 'backend', read: (): string => 'backend still listening' },
		],
	});
	expect(primaryError.cause).toBe(ownerFailure);
	expect(primaryError.message).toContain('Target page has been closed');
	expect(primaryError.message).toContain('backend still listening');
	expect(primaryError.message).toContain('unavailable');
});

test('a rejected asynchronous diagnostic cannot replace the primary error', async () => {
	const ownerFailure = new Error('worker-recovery-exhausted');
	const primaryError = new Error('Tab ownership failed', { cause: ownerFailure });
	await appendJourneyFailureDiagnostics({
		primaryError,
		reads: [
			{ name: 'page', read: (): Promise<never> => Promise.reject(new Error('page retired')) },
		],
	});
	expect(primaryError.cause).toBe(ownerFailure);
	expect(primaryError.message).toContain('page retired');
});

test('an unserializable diagnostic is a gap and does not lose the other results', async () => {
	const primaryError = new Error('original failure');
	await appendJourneyFailureDiagnostics({
		primaryError,
		reads: [
			{ name: 'unsupported', read: (): bigint => 1n },
			{ name: 'wire', read: (): string => 'metadata accepted' },
		],
	});
	expect(primaryError.message).toContain('metadata accepted');
	expect(primaryError.message).toContain('unavailable');
});

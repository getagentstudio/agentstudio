import { describe, expect, test } from 'vitest';

import { BridgeTestFactRecorder } from './bridge-test-fact-recorder.js';

type OperationFact = {
	readonly kind: 'opened' | 'forbidden' | 'closed';
	readonly operation: string;
};

const closesOperation = (fact: OperationFact): boolean =>
	fact.kind === 'closed' && fact.operation === 'target';
const isForbidden = (fact: OperationFact): boolean =>
	fact.kind === 'forbidden' && fact.operation === 'target';

describe('BridgeTestFactRecorder', (): void => {
	test('resolves a wait on a past fact', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		const opened = { kind: 'opened', operation: 'target' } satisfies OperationFact;
		recorder.record(opened);
		const result = recorder.waitFor((fact): boolean => fact.kind === 'opened', 'past opening');
		recorder.close(new Error('source ended'));
		expect(await result).toBe(opened);
	});

	test('resolves a wait on a future fact', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		const result = recorder.waitFor(closesOperation, 'future close');
		recorder.record({ kind: 'closed', operation: 'unrelated' });
		const closing = { kind: 'closed', operation: 'target' } satisfies OperationFact;
		recorder.record(closing);
		recorder.close(new Error('source ended'));
		expect(await result).toBe(closing);
	});

	test('rejects pending waits on close with their labels and last facts', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		recorder.record({ kind: 'opened', operation: 'target' });
		const first = expect(recorder.waitFor(closesOperation, 'target closing')).rejects.toThrow(
			/Awaiting target closing: owner retired; last recorded facts=.*opened.*target/,
		);
		const second = expect(recorder.waitFor(isForbidden, 'forbidden arrival')).rejects.toThrow(
			/Awaiting forbidden arrival: owner retired; last recorded facts=.*opened.*target/,
		);
		recorder.close(new Error('owner retired'));
		await Promise.all([first, second]);
	});

	test('expectNone passes only through its correlated closing fact', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		recorder.record({ kind: 'opened', operation: 'target' });
		const result = recorder.expectNone(isForbidden, closesOperation, 'target negative');
		recorder.record({ kind: 'closed', operation: 'unrelated' });
		recorder.record({ kind: 'closed', operation: 'target' });
		recorder.record({ kind: 'forbidden', operation: 'target' });
		recorder.close(new Error('source ended'));
		await result;
		// Buffered observation must stop at the same closing fact.
		await recorder.expectNone(isForbidden, closesOperation, 'buffered target negative');
	});

	test('expectNone fails when a forbidden fact arrives before close', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		const result = expect(
			recorder.expectNone(isForbidden, closesOperation, 'no target write'),
		).rejects.toThrow(/Awaiting no target write: Forbidden fact.*forbidden.*target/);
		recorder.record({ kind: 'closed', operation: 'unrelated' });
		recorder.record({ kind: 'forbidden', operation: 'target' });
		recorder.record({ kind: 'closed', operation: 'target' });
		await result;
		await expect(recorder.expectNone(isForbidden, closesOperation)).rejects.toThrow(
			'Forbidden fact',
		);
		recorder.close(new Error('source ended'));
	});

	test('does not prove a negative when the source closes before the closing fact', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		const result = expect(
			recorder.expectNone(isForbidden, closesOperation, 'negative needs close'),
		).rejects.toThrow('negative needs close');
		recorder.close(new Error('source truncated'));
		await result;
	});

	test('counts distinct matching owner facts', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<string>();
		recorder.record('first');
		const result = recorder.waitFor((): boolean => true, 'second observation', 2);
		recorder.record('second');
		recorder.close(new Error('source ended'));
		expect(await result).toBe('second');
	});
});

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
	test('a marked negative ignores forbidden facts from an earlier operation', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		recorder.record({ kind: 'forbidden', operation: 'target' });
		recorder.record({ kind: 'closed', operation: 'target' });
		const from = recorder.mark();
		const result = recorder.expectNone(isForbidden, closesOperation, {
			from,
			label: 'later clean close',
		});
		recorder.record({ kind: 'closed', operation: 'target' });
		await result;
		recorder.close(new Error('source ended'));
	});

	test('rejects an unmatched wait attached after close with its label and facts', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<string>();
		recorder.record('before-close');
		recorder.close(new Error('already retired'));
		await expect(
			recorder.waitFor((fact): boolean => fact === 'missing', 'closed attachment'),
		).rejects.toThrow(
			/Awaiting closed attachment: already retired; last recorded facts=.*before-close/,
		);
	});

	test.each([0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY])(
		'rejects invalid occurrence %s before attaching',
		async (occurrence: number): Promise<void> => {
			const recorder = new BridgeTestFactRecorder<string>();
			recorder.record('available');
			const result = expect(
				recorder.waitFor((): boolean => true, 'invalid occurrence', occurrence),
			).rejects.toThrow(`Invalid fact occurrence for invalid occurrence: ${occurrence}`);
			recorder.close(new Error('source ended'));
			await result;
		},
	);

	test('a negative failure names its offending fact and expected close outside recent history', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		const from = recorder.mark();
		recorder.record({ kind: 'forbidden', operation: 'target' });
		for (let index = 0; index < 20; index += 1)
			recorder.record({ kind: 'opened', operation: `recent-${index}` });
		recorder.record({ kind: 'closed', operation: 'target' });
		const result = await recorder
			.expectNone(isForbidden, closesOperation, {
				from,
				label: 'target completion without forbidden writes',
			})
			.catch((error: unknown): unknown => error);
		if (!(result instanceof Error)) throw new Error('Expected a negative diagnostic failure.');
		expect(result.message).toContain('Forbidden fact {"kind":"forbidden","operation":"target"}');
		expect(result.message).toContain(
			'before closing fact (target completion without forbidden writes)',
		);
		expect(result.message).toContain('last recorded facts=');
		expect(result.message).toContain('recent-19');
		recorder.close(new Error('source ended'));
	});

	test('the second operation negative cannot pass on the first operation close', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		recorder.record({ kind: 'opened', operation: 'target' });
		recorder.record({ kind: 'closed', operation: 'target' });
		const from = recorder.mark();
		expect(from).toBe(2);
		recorder.record({ kind: 'forbidden', operation: 'target' });
		recorder.record({ kind: 'closed', operation: 'target' });
		await expect(
			recorder.expectNone(isForbidden, closesOperation, { from, label: 'second operation close' }),
		).rejects.toThrow('Forbidden fact');
		recorder.close(new Error('source ended'));
	});

	test('late facts are diagnostic only after the recorder closes', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<string>();
		recorder.record('before-close');
		recorder.close(new Error('owner retired'));
		expect((): void => recorder.record('late-fact')).not.toThrow();
		await expect(
			recorder.waitFor((fact): boolean => fact === 'late-fact', 'late cannot reopen'),
		).rejects.toThrow(
			/Awaiting late cannot reopen: owner retired; last recorded facts=.*late-fact/,
		);
		expect(
			await recorder.waitFor((fact): boolean => fact === 'before-close', 'past stays available'),
		).toBe('before-close');
	});

	test('bounds each fact description without changing retained facts', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<string>();
		const largeFact = 'x'.repeat(2_000);
		recorder.record(largeFact);
		recorder.close(new Error('large source retired'));
		const result = await recorder
			.waitFor((): boolean => false, 'bounded history')
			.catch((error: unknown): unknown => error);
		if (!(result instanceof Error)) throw new Error('Expected bounded diagnostic rejection.');
		expect(result.message).toContain(
			'Awaiting bounded history: large source retired; last recorded facts=',
		);
		const factDescription = /last recorded facts=\[(.*)\]$/u.exec(result.message)?.[1];
		if (factDescription === undefined) throw new Error('Expected a recorded fact description.');
		expect(factDescription.length).toBeLessThanOrEqual(400);
		expect(factDescription.startsWith('"xxxxxxxxxx')).toBe(true);
		expect(factDescription.endsWith('...')).toBe(true);
		expect(
			await recorder.waitFor((fact): boolean => fact === largeFact, 'retained large fact'),
		).toBe(largeFact);
	});

	test('close rejects every pending waiter when both fact conversions throw', async (): Promise<void> => {
		type CyclicFact = { readonly kind: 'opened'; self?: CyclicFact };
		const fact: CyclicFact = { kind: 'opened' };
		fact.self = fact;
		Object.setPrototypeOf(fact, null);
		const recorder = new BridgeTestFactRecorder<CyclicFact>();
		recorder.record(fact);
		const failure = new Error('cyclic source retired');
		const first = recorder
			.waitFor((): boolean => false, 'first cyclic wait')
			.catch((error: unknown): unknown => error);
		const second = recorder
			.waitFor((): boolean => false, 'second cyclic wait')
			.catch((error: unknown): unknown => error);
		expect((): void => recorder.close(failure)).not.toThrow();
		const results = await Promise.all([first, second]);
		for (const [index, result] of results.entries()) {
			expect(result).toBeInstanceOf(Error);
			if (!(result instanceof Error)) throw new Error('Expected a rejected cyclic wait.');
			expect(result.message).toContain(index === 0 ? 'first cyclic wait' : 'second cyclic wait');
			expect(result.message).toContain('last recorded facts=[<unformattable fact>]');
			expect(result.cause).toBe(failure);
		}
		expect((): void => recorder.close(new Error('second retirement'))).not.toThrow();
	});

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
		const from = recorder.mark();
		recorder.record({ kind: 'opened', operation: 'target' });
		const result = recorder.expectNone(isForbidden, closesOperation, {
			from,
			label: 'target negative',
		});
		recorder.record({ kind: 'closed', operation: 'unrelated' });
		recorder.record({ kind: 'closed', operation: 'target' });
		recorder.record({ kind: 'forbidden', operation: 'target' });
		recorder.close(new Error('source ended'));
		await result;
		// Buffered observation must stop at the same closing fact.
		await recorder.expectNone(isForbidden, closesOperation, {
			from,
			label: 'buffered target negative',
		});
	});

	test('expectNone fails when a forbidden fact arrives before close', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		const from = recorder.mark();
		const result = expect(
			recorder.expectNone(isForbidden, closesOperation, { from, label: 'no target write' }),
		).rejects.toThrow(/Awaiting no target write: Forbidden fact.*forbidden.*target/);
		recorder.record({ kind: 'closed', operation: 'unrelated' });
		recorder.record({ kind: 'forbidden', operation: 'target' });
		recorder.record({ kind: 'closed', operation: 'target' });
		await result;
		await expect(
			recorder.expectNone(isForbidden, closesOperation, {
				from,
				label: 'buffered no target write',
			}),
		).rejects.toThrow('Forbidden fact');
		recorder.close(new Error('source ended'));
	});

	test('does not prove a negative when the source closes before the closing fact', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<OperationFact>();
		const from = recorder.mark();
		const result = expect(
			recorder.expectNone(isForbidden, closesOperation, { from, label: 'negative needs close' }),
		).rejects.toThrow('negative needs close');
		recorder.close(new Error('source truncated'));
		await result;
	});

	test('counts distinct matching owner facts', async (): Promise<void> => {
		const recorder = new BridgeTestFactRecorder<string>();
		recorder.record('first');
		recorder.record('unrelated-before');
		const result = recorder.waitFor(
			(fact): boolean => fact === 'first' || fact === 'second',
			'second observation',
			2,
		);
		recorder.record('unrelated-after');
		recorder.record('second');
		recorder.close(new Error('source ended'));
		expect(await result).toBe('second');
	});
});

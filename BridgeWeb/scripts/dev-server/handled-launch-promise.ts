export type LaunchPromiseOutcome<TValue> =
	| { readonly kind: 'succeeded'; readonly value: TValue }
	| { readonly kind: 'failed'; readonly error: Error };

export interface HandledLaunchPromise<TValue> {
	readonly settled: Promise<LaunchPromiseOutcome<TValue>>;
	readonly value: () => Promise<TValue>;
}

// Observations start before navigation and are consumed later. Store rejection
// as a value immediately; only the caller's awaited value() rethrows it.
export function handleLaunchPromise<TValue>(
	promise: Promise<TValue>,
	stepName: string,
): HandledLaunchPromise<TValue> {
	const settled = promise.then(
		(value): LaunchPromiseOutcome<TValue> => ({ kind: 'succeeded', value }),
		(cause: unknown): LaunchPromiseOutcome<TValue> => ({
			kind: 'failed',
			error: new Error(
				`BridgeWeb launch step failed: ${stepName}${cause instanceof Error ? `: ${cause.message}` : ''}`,
				{ cause },
			),
		}),
	);
	return {
		settled,
		value: async (): Promise<TValue> => {
			const outcome = await settled;
			if (outcome.kind === 'failed') throw outcome.error;
			return outcome.value;
		},
	};
}

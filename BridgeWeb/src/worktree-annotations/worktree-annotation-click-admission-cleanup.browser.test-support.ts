type CleanupAction = () => void | Promise<void>;

export async function completeCleanup(actions: readonly CleanupAction[]): Promise<void> {
	const failures: unknown[] = [];
	for (const action of actions) {
		try {
			// oxlint-disable-next-line no-await-in-loop -- Cleanup actions have ordering dependencies and all must be attempted.
			await action();
		} catch (error) {
			failures.push(error);
		}
	}
	throwCleanupFailures(failures);
}

function throwCleanupFailures(failures: readonly unknown[]): void {
	if (failures.length === 1) throw failures[0];
	if (failures.length > 1) {
		throw new AggregateError(failures, 'Click-admission cleanup failed.', { cause: failures[0] });
	}
}

/** Keep the body failure first; a cleanup failure must never replace it. */
export async function runWithOwnedCleanup<TValue>(
	action: () => Promise<TValue>,
	cleanup: CleanupAction,
): Promise<TValue> {
	let outcome:
		| { readonly kind: 'value'; readonly value: TValue }
		| { readonly kind: 'error'; readonly error: unknown };
	let cleanupFailure: { readonly error: unknown } | undefined;
	try {
		outcome = { kind: 'value', value: await action() };
	} catch (error) {
		outcome = { kind: 'error', error };
	} finally {
		try {
			await cleanup();
		} catch (error) {
			cleanupFailure = { error };
		}
	}
	if (cleanupFailure !== undefined) {
		if (outcome.kind === 'error') {
			throw new AggregateError(
				[outcome.error, cleanupFailure.error],
				'Click-admission body and cleanup failed.',
				{ cause: outcome.error },
			);
		}
		throw cleanupFailure.error;
	}
	if (outcome.kind === 'error') throw outcome.error;
	return outcome.value;
}

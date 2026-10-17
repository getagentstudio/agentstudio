export interface JourneyDiagnosticRead {
	readonly name: string;
	readonly read: () => unknown;
}

/** Retain the original cause even when an optional page diagnostic cannot be read. */
export async function appendJourneyFailureDiagnostics(props: {
	readonly primaryError: Error;
	readonly reads: readonly JourneyDiagnosticRead[];
}): Promise<void> {
	const values = await Promise.all(
		props.reads.map(async ({ name, read }): Promise<string> => {
			try {
				return `${name}=${JSON.stringify({ status: 'read', value: await read() })}`;
			} catch (error: unknown) {
				return `${name}=${JSON.stringify({
					status: 'unavailable',
					reason: error instanceof Error ? error.message : String(error),
				})}`;
			}
		}),
	);
	props.primaryError.message += ` Diagnostics: ${values.join('; ')}`;
}

import { endToEndTestTimeoutMilliseconds } from '../../tests/vitest-hang-bounds.ts';

export function createOwnedVerifierJourneyDeadline(props: {
	readonly closePages: (reason: string) => Promise<void>;
	readonly pendingSteps: () => readonly string[];
}): { readonly signal: AbortSignal; readonly dispose: () => Promise<void> } {
	const controller = new AbortController();
	let cleanup: Promise<void> | undefined;
	const deadline = setTimeout((): void => {
		const reason = `BRIDGE_VERIFIER_JOURNEY_DEADLINE_EXCEEDED waiting=${props.pendingSteps().join(', ') || 'verifier journey'}`;
		process.stderr.write(`${reason}\n`);
		controller.abort(new Error(reason));
		cleanup = props.closePages(reason);
		void cleanup.catch((): void => {});
	}, endToEndTestTimeoutMilliseconds);
	return {
		signal: controller.signal,
		dispose: async (): Promise<void> => {
			clearTimeout(deadline);
			await cleanup;
		},
	};
}

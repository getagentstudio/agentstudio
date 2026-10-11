import { endToEndTestTimeoutMilliseconds } from '../../tests/vitest-hang-bounds.ts';

export function createOwnedVerifierJourneyDeadline(
	props: {
		readonly closePages: (reason: string) => Promise<void>;
		readonly pendingSteps: () => readonly string[];
	},
	scheduling?: {
		readonly schedule: (expire: () => void, durationMilliseconds: number) => () => void;
	},
): {
	readonly signal: AbortSignal;
	readonly cancel: () => void;
	readonly dispose: () => Promise<void>;
} {
	const controller = new AbortController();
	let cleanup: Promise<void> | undefined;
	const expire = (): void => {
		const reason = `BRIDGE_VERIFIER_JOURNEY_DEADLINE_EXCEEDED waiting=${props.pendingSteps().join(', ') || 'verifier journey'}`;
		process.stderr.write(`${reason}\n`);
		controller.abort(new Error(reason));
		cleanup = props.closePages(reason);
		void cleanup.catch((): void => {});
	};
	const cancel =
		scheduling?.schedule(expire, endToEndTestTimeoutMilliseconds) ??
		(() => {
			const deadline = setTimeout(expire, endToEndTestTimeoutMilliseconds);
			return (): void => clearTimeout(deadline);
		})();
	return {
		signal: controller.signal,
		cancel,
		dispose: async (): Promise<void> => {
			cancel();
			await cleanup;
		},
	};
}

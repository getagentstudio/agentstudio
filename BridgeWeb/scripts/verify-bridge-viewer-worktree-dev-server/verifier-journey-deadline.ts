import { endToEndTestTimeoutMilliseconds } from '../../tests/vitest-hang-bounds.ts';

export type VerifierJourneyDeadlineSchedule = (
	expire: () => void,
	durationMilliseconds: number,
) => () => void;

export function createOwnedVerifierJourneyDeadline(
	props: {
		readonly closePages: (reason: string) => Promise<void>;
		readonly pendingSteps: () => readonly string[];
	},
	scheduling?: { readonly schedule: VerifierJourneyDeadlineSchedule },
): {
	readonly signal: AbortSignal;
	readonly cancel: () => void;
	readonly dispose: () => Promise<void>;
	readonly renew: () => void;
} {
	const controller = new AbortController();
	let cleanup: Promise<void> | undefined;
	let cancelSchedule: () => void = (): void => {};
	const expire = (): void => {
		const reason = `BRIDGE_VERIFIER_JOURNEY_DEADLINE_EXCEEDED waiting=${props.pendingSteps().join(', ') || 'verifier journey'}`;
		process.stderr.write(`${reason}\n`);
		controller.abort(new Error(reason));
		cleanup = props.closePages(reason);
		void cleanup.catch((): void => {});
	};
	const schedule =
		scheduling?.schedule ??
		((callback: () => void, durationMilliseconds: number): (() => void) => {
			const deadline = setTimeout(callback, durationMilliseconds);
			return (): void => clearTimeout(deadline);
		});
	const renew = (): void => {
		if (controller.signal.aborted) return;
		cancelSchedule();
		cancelSchedule = schedule(expire, endToEndTestTimeoutMilliseconds);
	};
	cancelSchedule = schedule(expire, endToEndTestTimeoutMilliseconds);
	return {
		signal: controller.signal,
		cancel: (): void => cancelSchedule(),
		dispose: async (): Promise<void> => {
			cancelSchedule();
			await cleanup;
		},
		renew,
	};
}

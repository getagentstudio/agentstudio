import { BridgeProductRequestTransportError } from './bridge-product-command-post.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import type { BridgeProductSessionBootstrap } from './bridge-product-session-contracts.js';

export class BridgeProductSessionSuspectError extends Error {
	shouldNotify = true;

	constructor(readonly phase: 'admission' | 'result') {
		super(`Bridge product session ${phase} did not settle within its bounded retry window.`);
		this.name = 'BridgeProductSessionSuspectError';
	}
}

export class BridgeProductRequestDeadlineError extends Error {}

export async function postBridgeProductExactAdmissionWithRetry<TResult>(props: {
	readonly policy: BridgeProductSessionBootstrap['policy'];
	readonly deadlineClock: BridgeProductDeadlineClock;
	readonly onAttemptFailure?: (error: unknown) => void;
	readonly run: (signal: AbortSignal) => Promise<TResult>;
	readonly signal?: AbortSignal;
}): Promise<TResult> {
	for (let attempt = 0; attempt <= props.policy.admissionRetryCount; attempt += 1) {
		try {
			return await withBridgeProductDeadline({
				clock: props.deadlineClock,
				delayMilliseconds: props.policy.workerSettlementDeadlineMilliseconds,
				run: props.run,
				...(props.signal === undefined ? {} : { signal: props.signal }),
			});
		} catch (error: unknown) {
			props.onAttemptFailure?.(error);
			props.signal?.throwIfAborted();
			if (
				!(error instanceof BridgeProductRequestDeadlineError) &&
				!(error instanceof BridgeProductRequestTransportError)
			)
				throw error;
		}
	}
	throw new BridgeProductSessionSuspectError('admission');
}

export async function withBridgeProductDeadline<TResult>(props: {
	readonly clock: BridgeProductDeadlineClock;
	readonly delayMilliseconds: number;
	readonly run: (signal: AbortSignal) => Promise<TResult>;
	readonly signal?: AbortSignal;
}): Promise<TResult> {
	props.signal?.throwIfAborted();
	const controller = new AbortController();
	const abortForCaller = (): void => controller.abort(props.signal?.reason);
	props.signal?.addEventListener('abort', abortForCaller, { once: true });
	let cancelDeadline = (): void => {};
	const deadline = new Promise<never>((_resolve, reject): void => {
		cancelDeadline = props.clock.schedule(props.delayMilliseconds, (): void => {
			controller.abort();
			reject(new BridgeProductRequestDeadlineError());
		});
	});
	try {
		return await Promise.race([props.run(controller.signal), deadline]);
	} finally {
		cancelDeadline();
		props.signal?.removeEventListener('abort', abortForCaller);
	}
}

import {
	BridgeProductResponseSizeLimitError,
	BridgeProductRequestTransportError,
} from './bridge-product-command-post.js';
import { BridgeProductRequestDeadlineError } from './bridge-product-control-retry.js';
import type { BridgeWorkerControlAttemptOutcome } from './bridge-worker-ack-diagnostic-contracts.js';

export class BridgeProductAmbiguousControlReplyError extends BridgeProductRequestTransportError {
	constructor(readonly outcome: BridgeWorkerControlAttemptOutcome) {
		super('Bridge product control reply was ambiguous.');
	}
}

/** A failed control exchange is retryable when its correlated reply cannot be read. */
export function bridgeProductAmbiguousControlReply(props: {
	readonly error: unknown;
	readonly failureKind: 'parse' | 'identity' | 'transport';
	readonly response?: Response | null;
	readonly signal?: AbortSignal | undefined;
}): BridgeProductAmbiguousControlReplyError {
	if (props.error instanceof BridgeProductResponseSizeLimitError) throw props.error;
	props.signal?.throwIfAborted();
	if (props.error instanceof BridgeProductAmbiguousControlReplyError) return props.error;
	if (props.response !== null && props.response !== undefined && props.response.status >= 500) {
		return new BridgeProductAmbiguousControlReplyError({
			kind: 'httpStatus',
			code: props.response.status,
		});
	}
	return new BridgeProductAmbiguousControlReplyError({
		kind:
			props.error instanceof BridgeProductRequestTransportError ? 'transport' : props.failureKind,
	});
}

export function bridgeProductControlAttemptOutcome(
	error: unknown,
): BridgeWorkerControlAttemptOutcome {
	if (error instanceof BridgeProductRequestDeadlineError) return { kind: 'deadline' };
	if (error instanceof BridgeProductAmbiguousControlReplyError) return error.outcome;
	return { kind: 'transport' };
}

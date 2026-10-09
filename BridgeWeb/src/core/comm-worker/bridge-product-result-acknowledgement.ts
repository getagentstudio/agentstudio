import { bridgeProductAckHTTPFailureOutcome } from './bridge-product-ack-failure-classification.js';
import {
	BridgeProductResponseSizeLimitError,
	BridgeProductRequestTransportError,
	postBridgeProductCommandBody,
} from './bridge-product-command-post.js';
import { bridgeProductAmbiguousControlReply } from './bridge-product-control-reply-classification.js';
import {
	BridgeProductRequestDeadlineError,
	postBridgeProductExactAdmissionWithRetry,
} from './bridge-product-control-retry.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import {
	bridgeProductOperationResultAcknowledgedResponseSchema,
	bridgeProductOperationResultAcknowledgementSchema,
} from './bridge-product-operation-wire-contracts.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import type { BridgeProductSessionBootstrap } from './bridge-product-session-contracts.js';
import {
	BridgeProductStrictJSONError,
	parseBridgeProductStrictJSON,
} from './bridge-product-strict-json.js';
import type { BridgeWorkerAckAttemptOutcome } from './bridge-worker-ack-diagnostic-contracts.js';

class BridgeProductAckAttemptTransportError extends BridgeProductRequestTransportError {
	constructor(readonly outcome: BridgeWorkerAckAttemptOutcome) {
		super('Bridge acknowledgement reply ambiguous.');
	}
}

export async function postBridgeProductResultAcknowledgement(props: {
	readonly policy: BridgeProductSessionBootstrap['policy'];
	readonly acknowledgement: ReturnType<
		typeof bridgeProductOperationResultAcknowledgementSchema.parse
	>;
	readonly capabilityHeader: string;
	readonly deadlineClock: BridgeProductDeadlineClock;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly recordAttemptFailure?: (outcome: BridgeWorkerAckAttemptOutcome) => void;
}): Promise<ReturnType<typeof bridgeProductOperationResultAcknowledgedResponseSchema.parse>> {
	return await postBridgeProductExactAdmissionWithRetry({
		policy: props.policy,
		deadlineClock: props.deadlineClock,
		onAttemptFailure: (error): void => {
			props.recordAttemptFailure?.(
				bridgeProductAckAttemptOutcome(error, props.acknowledgement.requestSequence),
			);
		},
		run: async (
			signal,
		): Promise<ReturnType<typeof bridgeProductOperationResultAcknowledgedResponseSchema.parse>> => {
			const observedReply: { response: Response | null } = { response: null };
			try {
				const responseBytes = await postBridgeProductCommandBody({
					body: props.acknowledgement,
					capabilityHeader: props.capabilityHeader,
					executeProductRequest: props.executeProductRequest,
					observeResponse: (response): void => {
						observedReply.response = response;
					},
					signal,
				});
				const parsed = bridgeProductOperationResultAcknowledgedResponseSchema.safeParse(
					parseBridgeProductStrictJSON(responseBytes),
				);
				if (!parsed.success) {
					throw new BridgeProductAckAttemptTransportError({
						kind: 'parseFailure',
						requestSequence: props.acknowledgement.requestSequence,
					});
				}
				const response = parsed.data;
				if (
					response.operationId !== props.acknowledgement.operationId ||
					response.requestSequence !== props.acknowledgement.requestSequence ||
					response.requestId !== props.acknowledgement.requestId
				) {
					throw new BridgeProductAckAttemptTransportError({
						kind: 'identityMismatch',
						requestSequence: props.acknowledgement.requestSequence,
					});
				}
				return response;
			} catch (error: unknown) {
				if (
					error instanceof BridgeProductResponseSizeLimitError ||
					error instanceof BridgeProductAckAttemptTransportError
				)
					throw error;
				if (observedReply.response !== null && !observedReply.response.ok) {
					throw new BridgeProductAckAttemptTransportError(
						await bridgeProductAckHTTPFailureOutcome(observedReply.response, props.acknowledgement),
					);
				}
				const ambiguous = bridgeProductAmbiguousControlReply({
					error,
					failureKind: error instanceof BridgeProductStrictJSONError ? 'parse' : 'transport',
					response: observedReply.response,
					signal,
				});
				throw new BridgeProductAckAttemptTransportError({
					kind: ambiguous.outcome.kind === 'parse' ? 'parseFailure' : 'transportFailure',
					requestSequence: props.acknowledgement.requestSequence,
				});
			}
		},
	});
}

function bridgeProductAckAttemptOutcome(
	error: unknown,
	requestSequence: number,
): BridgeWorkerAckAttemptOutcome {
	if (error instanceof BridgeProductRequestDeadlineError)
		return { kind: 'deadlineExpired', requestSequence };
	if (error instanceof BridgeProductAckAttemptTransportError) return error.outcome;
	if (error instanceof BridgeProductResponseSizeLimitError)
		return { kind: 'responseSizeLimit', requestSequence };
	return { kind: 'transportFailure', requestSequence };
}

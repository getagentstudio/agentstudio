import { postBridgeProductAdmissionBody } from './bridge-product-command-post.js';
import {
	bridgeProductAmbiguousControlReply,
	bridgeProductControlAttemptOutcome,
} from './bridge-product-control-reply-classification.js';
import { assertBridgeProductResponseCorrelation } from './bridge-product-control-response-correlation.js';
import { postBridgeProductExactAdmissionWithRetry } from './bridge-product-control-retry.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import { bridgeProductAdmissionResponseSchema } from './bridge-product-operation-wire-contracts.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import {
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
	type BridgeProductSessionBootstrap,
} from './bridge-product-session-contracts.js';
import { parseBridgeProductStrictJSON } from './bridge-product-strict-json.js';
import type { BridgeWorkerControlAttemptOutcome } from './bridge-worker-ack-diagnostic-contracts.js';

export async function postBridgeProductControlRequestWithExactRetry(props: {
	readonly policy: BridgeProductSessionBootstrap['policy'];
	readonly capabilityHeader: string;
	readonly deadlineClock: BridgeProductDeadlineClock;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly request: ReturnType<typeof bridgeProductControlRequestSchema.parse>;
	readonly recordAttemptFailure?: (outcome: BridgeWorkerControlAttemptOutcome) => void;
	readonly signal?: AbortSignal;
}): Promise<ReturnType<typeof bridgeProductAdmissionResponseSchema.parse>> {
	return await postBridgeProductExactAdmissionWithRetry({
		policy: props.policy,
		deadlineClock: props.deadlineClock,
		onAttemptFailure: (error): void => {
			props.recordAttemptFailure?.(bridgeProductControlAttemptOutcome(error));
		},
		run: (signal): Promise<ReturnType<typeof bridgeProductAdmissionResponseSchema.parse>> =>
			postBridgeProductControlRequest({
				capabilityHeader: props.capabilityHeader,
				executeProductRequest: props.executeProductRequest,
				request: props.request,
				signal,
			}),
		...(props.signal === undefined ? {} : { signal: props.signal }),
	});
}

async function postBridgeProductControlRequest(props: {
	readonly capabilityHeader: string;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly request: ReturnType<typeof bridgeProductControlRequestSchema.parse>;
	readonly signal?: AbortSignal;
}): Promise<ReturnType<typeof bridgeProductAdmissionResponseSchema.parse>> {
	let observedResponse: Response | null = null;
	try {
		const response = await postBridgeProductAdmissionBody({
			body: props.request,
			capabilityHeader: props.capabilityHeader,
			executeProductRequest: props.executeProductRequest,
			observeResponse: (received): void => {
				observedResponse = received;
			},
			...(props.signal === undefined ? {} : { signal: props.signal }),
		});
		const admitted = bridgeProductAdmissionResponseSchema.parse(
			parseBridgeProductStrictJSON(response.bytes),
		);
		if (response.status >= 400 && admitted.kind !== 'request.error') {
			throw new Error('A client refusal must carry request.error.');
		}
		try {
			assertBridgeProductResponseCorrelation({ request: props.request, response: admitted });
		} catch (error: unknown) {
			throw bridgeProductAmbiguousControlReply({
				error,
				failureKind: 'identity',
				response: observedResponse,
				signal: props.signal,
			});
		}
		return admitted;
	} catch (error: unknown) {
		throw bridgeProductAmbiguousControlReply({
			error,
			failureKind: 'parse',
			response: observedResponse,
			signal: props.signal,
		});
	}
}

export async function postBridgeProductEscapeControlRequest(props: {
	readonly policy: BridgeProductSessionBootstrap['policy'];
	readonly capabilityHeader: string;
	readonly deadlineClock: BridgeProductDeadlineClock;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly request: ReturnType<typeof bridgeProductControlRequestSchema.parse>;
	readonly recordAttemptFailure?: (outcome: BridgeWorkerControlAttemptOutcome) => void;
	readonly signal?: AbortSignal;
}): Promise<ReturnType<typeof bridgeProductControlResponseSchema.parse>> {
	return await postBridgeProductExactAdmissionWithRetry({
		policy: props.policy,
		deadlineClock: props.deadlineClock,
		onAttemptFailure: (error): void => {
			props.recordAttemptFailure?.(bridgeProductControlAttemptOutcome(error));
		},
		run: async (signal): Promise<ReturnType<typeof bridgeProductControlResponseSchema.parse>> => {
			let observedResponse: Response | null = null;
			try {
				const reply = await postBridgeProductAdmissionBody({
					body: props.request,
					capabilityHeader: props.capabilityHeader,
					executeProductRequest: props.executeProductRequest,
					observeResponse: (received): void => {
						observedResponse = received;
					},
					signal,
				});
				const response = bridgeProductControlResponseSchema.parse(
					parseBridgeProductStrictJSON(reply.bytes),
				);
				if (reply.status >= 400 && response.kind !== 'request.error') {
					throw new Error('A client refusal must carry request.error.');
				}
				try {
					assertBridgeProductResponseCorrelation({ request: props.request, response });
				} catch (error: unknown) {
					throw bridgeProductAmbiguousControlReply({
						error,
						failureKind: 'identity',
						response: observedResponse,
						signal,
					});
				}
				return response;
			} catch (error: unknown) {
				throw bridgeProductAmbiguousControlReply({
					error,
					failureKind: 'parse',
					response: observedResponse,
					signal,
				});
			}
		},
		...(props.signal === undefined ? {} : { signal: props.signal }),
	});
}

import { readBridgeProductControlResponseBytes } from './bridge-product-command-post.js';
import { BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES } from './bridge-product-contract-primitives.js';
import {
	defaultBridgeProductDeadlineClock,
	type BridgeProductDeadlineClock,
} from './bridge-product-deadline-clock.js';
import {
	bridgeProductContentAcknowledgementRefusedSchema,
	bridgeProductFrameAcknowledgementRejectedStatusSchema,
	type BridgeProductFrameAcknowledgementRequest,
} from './bridge-product-frame-acknowledgement-contracts.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import { parseBridgeProductStrictJSON } from './bridge-product-strict-json.js';

export async function sendBridgeProductFrameAcknowledgement(props: {
	readonly capabilityHeader: string;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly deadlineClock?: BridgeProductDeadlineClock;
	readonly request: BridgeProductFrameAcknowledgementRequest;
	readonly timeoutMilliseconds: number;
}): Promise<void> {
	const abortController = new AbortController();
	let cancelDeadline: (() => void) | undefined;
	try {
		await Promise.race([
			(async (): Promise<void> => {
				const response = await props.executeProductRequest('command', {
					body: encodeRequestBody(props.request),
					headers: {
						'Content-Type': 'application/json',
						'X-AgentStudio-Bridge-Product-Capability': props.capabilityHeader,
					},
					method: 'POST',
					signal: abortController.signal,
				});
				await assertAccepted(response, props.request);
			})(),
			new Promise<void>((_, reject): void => {
				cancelDeadline = (props.deadlineClock ?? defaultBridgeProductDeadlineClock).schedule(
					props.timeoutMilliseconds,
					(): void => {
						abortController.abort();
						reject(
							new BridgeProductFrameAcknowledgementFailure(
								'request_timeout',
								null,
								'Bridge product frame acknowledgement request timed out.',
							),
						);
					},
				);
			}),
		]);
	} catch (error) {
		if (error instanceof BridgeProductFrameAcknowledgementFailure) throw error;
		throw new BridgeProductFrameAcknowledgementFailure(
			'request_failed',
			null,
			'Bridge product frame acknowledgement request failed.',
		);
	} finally {
		cancelDeadline?.();
	}
}

function encodeRequestBody(request: BridgeProductFrameAcknowledgementRequest): ArrayBuffer {
	const body = new TextEncoder().encode(JSON.stringify(request));
	if (body.byteLength > BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES) {
		throw new Error('Bridge product request exceeds its body ceiling.');
	}
	return Uint8Array.from(body).buffer;
}

async function assertAccepted(
	response: Response,
	request: BridgeProductFrameAcknowledgementRequest,
): Promise<void> {
	const status = response.status;
	if (status === 204) return;
	if (status === 404) {
		try {
			const refusal = bridgeProductContentAcknowledgementRefusedSchema.parse(
				parseBridgeProductStrictJSON(await readBridgeProductControlResponseBytes(response)),
			);
			if (
				refusal.contentRequestId === request.contentRequestId &&
				refusal.leaseId === request.leaseId &&
				refusal.paneSessionId === request.paneSessionId &&
				refusal.workerInstanceId === request.workerInstanceId &&
				refusal.wireVersion === request.wireVersion &&
				refusal.receivedThroughContentSequence === request.receivedThroughContentSequence
			) {
				throw new BridgeProductFrameAcknowledgementFailure(
					'unknown_read',
					404,
					'Bridge product content acknowledgement addressed an ended read.',
				);
			}
		} catch (error) {
			if (error instanceof BridgeProductFrameAcknowledgementFailure) throw error;
			throw new BridgeProductFrameAcknowledgementFailure(
				'ambiguous_refusal',
				404,
				'Bridge product content acknowledgement refusal could not be validated.',
			);
		}
		throw new BridgeProductFrameAcknowledgementFailure(
			'ambiguous_refusal',
			404,
			'Bridge product content acknowledgement refusal did not match its request.',
		);
	}
	const rejected = bridgeProductFrameAcknowledgementRejectedStatusSchema.safeParse(status);
	throw new BridgeProductFrameAcknowledgementFailure(
		rejected.success ? 'rejected_status' : 'unsupported_status',
		status,
		rejected.success
			? `Bridge product frame acknowledgement was rejected with status ${status}.`
			: `Bridge product frame acknowledgement returned unsupported status ${status}.`,
	);
}

type FailureCode =
	| 'ambiguous_refusal'
	| 'rejected_status'
	| 'request_failed'
	| 'request_timeout'
	| 'unknown_read'
	| 'unsupported_status';

export class BridgeProductFrameAcknowledgementFailure extends Error {
	constructor(
		readonly failureCode: FailureCode,
		readonly status: number | null,
		message: string,
	) {
		super(message);
		this.name = 'BridgeProductFrameAcknowledgementFailure';
	}
}

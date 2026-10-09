import { bridgeProductAdmissionResponseSchema } from './bridge-product-operation-wire-contracts.js';
import {
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
} from './bridge-product-session-contracts.js';

/** A typed refusal and a successful admission must answer the exact issued control. */
export function assertBridgeProductResponseCorrelation(props: {
	readonly request: ReturnType<typeof bridgeProductControlRequestSchema.parse>;
	readonly response:
		| ReturnType<typeof bridgeProductControlResponseSchema.parse>
		| ReturnType<typeof bridgeProductAdmissionResponseSchema.parse>;
}): void {
	if (
		props.response.wireVersion !== props.request.wireVersion ||
		props.response.paneSessionId !== props.request.paneSessionId ||
		props.response.workerInstanceId !== props.request.workerInstanceId ||
		props.response.requestId !== props.request.requestId ||
		props.response.requestSequence !== props.request.requestSequence
	) {
		throw new Error('Bridge product response does not match its issued request.');
	}
}

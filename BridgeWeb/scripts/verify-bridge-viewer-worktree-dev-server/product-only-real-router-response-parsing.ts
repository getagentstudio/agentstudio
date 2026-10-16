import {
	bridgeProductContentAcknowledgementRefusedSchema,
	bridgeProductFrameAcknowledgementRequestSchema,
} from '../../src/core/comm-worker/bridge-product-frame-acknowledgement-contracts.ts';
import { parseBridgeProductStrictJSON } from '../../src/core/comm-worker/bridge-product-strict-json.ts';

export function correlatedContentUnknownReadRefusal(
	requestBodyText: string | null,
	responseBytes: Uint8Array,
): boolean {
	if (requestBodyText === null) return false;
	try {
		const request = bridgeProductFrameAcknowledgementRequestSchema.parse(
			parseBridgeProductStrictJSON(new TextEncoder().encode(requestBodyText)),
		);
		const refusal = bridgeProductContentAcknowledgementRefusedSchema.parse(
			parseBridgeProductStrictJSON(responseBytes),
		);
		return (
			request.contentRequestId === refusal.contentRequestId &&
			request.leaseId === refusal.leaseId &&
			request.paneSessionId === refusal.paneSessionId &&
			request.workerInstanceId === refusal.workerInstanceId &&
			request.wireVersion === refusal.wireVersion &&
			request.receivedThroughContentSequence === refusal.receivedThroughContentSequence
		);
	} catch {
		return false;
	}
}

export function parseJSONOrNull(value: string | null): unknown {
	if (value === null || value.length === 0) return null;
	try {
		return JSON.parse(value) as unknown;
	} catch {
		return null;
	}
}

export function unknownRecord(value: unknown): Readonly<Record<string, unknown>> | null {
	return isUnknownRecord(value) ? value : null;
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function stringValue(value: unknown): string | null {
	return typeof value === 'string' ? value : null;
}

export function integerValue(value: unknown): number | null {
	return typeof value === 'number' && Number.isSafeInteger(value) ? value : null;
}

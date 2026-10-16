import { BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES } from './bridge-product-contract-primitives.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';

export class BridgeProductRequestTransportError extends Error {}
export class BridgeProductResponseSizeLimitError extends Error {}

export async function postBridgeProductCommandBody(props: {
	readonly body: object;
	readonly capabilityHeader: string;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly observeResponse?: (response: Response) => void;
	readonly signal?: AbortSignal;
}): Promise<Uint8Array> {
	const response = await executeBridgeProductCommand(props);
	props.observeResponse?.(response);
	if (!response.ok) {
		if (response.status < 400 || response.status >= 500) {
			throw new BridgeProductRequestTransportError(
				`Bridge product command reply was ambiguous: HTTP ${response.status}.`,
			);
		}
		throw new Error(`Bridge product control request failed with status ${response.status}.`);
	}
	if (response.status === 204) return new Uint8Array();
	return await readBridgeProductControlResponseBytes(response);
}

/** Keeps a 4xx body only long enough for the admission parser to prove a typed refusal. */
export async function postBridgeProductAdmissionBody(props: {
	readonly body: object;
	readonly capabilityHeader: string;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly observeResponse?: (response: Response) => void;
	readonly signal?: AbortSignal;
}): Promise<{ readonly bytes: Uint8Array; readonly status: number }> {
	const response = await executeBridgeProductCommand(props);
	props.observeResponse?.(response);
	if (!response.ok && (response.status < 400 || response.status >= 500)) {
		throw new BridgeProductRequestTransportError(
			`Bridge product admission reply was ambiguous: HTTP ${response.status}.`,
		);
	}
	try {
		return {
			bytes: await readBridgeProductControlResponseBytes(response),
			status: response.status,
		};
	} catch (error: unknown) {
		if (error instanceof BridgeProductResponseSizeLimitError) throw error;
		throw new BridgeProductRequestTransportError('Bridge product admission reply was unreadable.');
	}
}

async function executeBridgeProductCommand(props: {
	readonly body: object;
	readonly capabilityHeader: string;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly signal?: AbortSignal;
}): Promise<Response> {
	const body = new TextEncoder().encode(JSON.stringify(props.body));
	if (body.byteLength > BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES) {
		throw new Error('Bridge product control request exceeds the encoded body limit.');
	}
	let response: Response;
	try {
		response = await props.executeProductRequest('command', {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				'X-AgentStudio-Bridge-Product-Capability': props.capabilityHeader,
			},
			body,
			signal: props.signal ?? null,
		});
	} catch {
		props.signal?.throwIfAborted();
		throw new BridgeProductRequestTransportError('Bridge product command transport failed.');
	}
	return response;
}

export async function readBridgeProductControlResponseBytes(
	response: Response,
): Promise<Uint8Array> {
	if (response.body === null) {
		throw new Error('Bridge product control response did not expose a body stream.');
	}
	const reader = response.body.getReader();
	const responseBytes = new Uint8Array(BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES);
	let responseByteLength = 0;
	try {
		while (true) {
			// oxlint-disable-next-line eslint/no-await-in-loop -- Response chunks must be consumed in order.
			const chunk = await reader.read();
			if (chunk.done) {
				break;
			}
			if (chunk.value.byteLength > BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES - responseByteLength) {
				// oxlint-disable-next-line eslint/no-await-in-loop -- Cancel must settle before releasing the reader lock.
				await reader.cancel().catch((): void => {});
				throw new BridgeProductResponseSizeLimitError(
					'Bridge product control response exceeds the encoded body limit.',
				);
			}
			responseBytes.set(chunk.value, responseByteLength);
			responseByteLength += chunk.value.byteLength;
		}
	} finally {
		reader.releaseLock();
	}
	const declaredLength = response.headers.get('Content-Length');
	if (declaredLength !== null) {
		const expectedLength = Number(declaredLength);
		if (
			!/^\d+$/.test(declaredLength) ||
			!Number.isSafeInteger(expectedLength) ||
			expectedLength !== responseByteLength
		) {
			throw new BridgeProductRequestTransportError(
				'Bridge product control response length was not verified.',
			);
		}
	}
	return responseBytes.slice(0, responseByteLength);
}

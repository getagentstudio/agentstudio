import { BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES } from './bridge-product-contract-primitives.js';

export function encodeBridgeProductRequestBody(request: object): ArrayBuffer {
	const body = new TextEncoder().encode(JSON.stringify(request));
	if (body.byteLength > BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES) {
		throw new Error('Bridge product request exceeds its body ceiling.');
	}
	return Uint8Array.from(body).buffer;
}

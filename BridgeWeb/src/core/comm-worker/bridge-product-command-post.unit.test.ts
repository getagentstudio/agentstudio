import { describe, expect, test } from 'vitest';

import {
	BridgeProductRequestTransportError,
	postBridgeProductCommandBody,
} from './bridge-product-command-post.js';

describe('Bridge product command response body', () => {
	test('a clean short body against Content-Length is transport loss', async () => {
		await expect(
			postBridgeProductCommandBody({
				body: { kind: 'operation.result' },
				capabilityHeader: 'capability',
				executeProductRequest: async () =>
					new Response('x', { headers: { 'Content-Length': '2' }, status: 200 }),
			}),
		).rejects.toBeInstanceOf(BridgeProductRequestTransportError);
	});
});

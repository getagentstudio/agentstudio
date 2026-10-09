import { expect, test } from 'vitest';

import fixture from '../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import {
	bridgePageConfigurationSchema,
	readBridgePageConfiguration,
} from './bridge-page-configuration.js';

test('reads validated pre-session configuration by synchronous handshake replay without requesting bootstrap', () => {
	const target = new EventTarget();
	let productBootstrapRequests = 0;
	target.addEventListener('__bridge_product_session_bootstrap_request', (): void => {
		productBootstrapRequests += 1;
	});
	target.addEventListener('__bridge_handshake_request', (): void => {
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', { detail: { pageConfiguration: fixture } }),
		);
	});
	expect(readBridgePageConfiguration(target)).toEqual(fixture);
	expect(productBootstrapRequests).toBe(0);
});

test('rejects missing and malformed pre-session policy rather than starting an unconfigured bootstrap', () => {
	const target = new EventTarget();
	expect(() => readBridgePageConfiguration(target)).toThrow('before bootstrap');
	for (const workerBootstrapDeadlineMilliseconds of [0, -1, 1.5, '5000']) {
		expect(
			bridgePageConfigurationSchema.safeParse({ ...fixture, workerBootstrapDeadlineMilliseconds })
				.success,
		).toBe(false);
	}
	for (const readyAcknowledgementDeadlineMilliseconds of [0, -1, 1.5, '5000']) {
		expect(
			bridgePageConfigurationSchema.safeParse({
				...fixture,
				readyAcknowledgementDeadlineMilliseconds,
			}).success,
		).toBe(false);
	}
	expect(bridgePageConfigurationSchema.safeParse({ ...fixture, unexpected: true }).success).toBe(
		false,
	);
});

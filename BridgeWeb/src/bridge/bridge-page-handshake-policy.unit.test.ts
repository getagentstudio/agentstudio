import { afterEach, expect, test, vi } from 'vitest';

import fixture from '../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import {
	installBridgePageHandshakeSession,
	type BridgePageReadyError,
} from './bridge-page-handshake.js';

afterEach((): void => {
	vi.useRealTimers();
});

test.each([undefined, { readyAcknowledgementDeadlineMilliseconds: -1 }])(
	'missing or invalid configuration ends readiness without sending ready (%j)',
	async (pageConfiguration): Promise<void> => {
		const target = new EventTarget();
		const errors: BridgePageReadyError[] = [];
		let readyRequestCount = 0;
		target.addEventListener('__bridge_ready', (): void => {
			readyRequestCount += 1;
		});
		target.addEventListener('__bridge_handshake_request', (): void => {
			target.dispatchEvent(
				new CustomEvent('__bridge_handshake', { detail: { pageConfiguration } }),
			);
		});
		const session = installBridgePageHandshakeSession(target, {
			onReadyError: (error): void => {
				errors.push(error);
			},
		});
		try {
			await Promise.resolve();
			expect(errors).toEqual([expect.objectContaining({ kind: 'configuration_error' })]);
			expect(readyRequestCount).toBe(0);
			target.dispatchEvent(
				new CustomEvent('__bridge_handshake', { detail: { pageConfiguration: fixture } }),
			);
			await Promise.resolve();
			expect(errors).toHaveLength(1);
			expect(readyRequestCount).toBe(0);
		} finally {
			session.uninstall();
		}
	},
);

test('reads the ready-ACK deadline from pre-session replay before sending ready', async () => {
	vi.useFakeTimers();
	const target = new EventTarget();
	const errors: BridgePageReadyError[] = [];
	target.addEventListener('__bridge_handshake_request', (): void => {
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: {
					pageConfiguration: { ...fixture, readyAcknowledgementDeadlineMilliseconds: 31 },
				},
			}),
		);
	});
	const readySent = new Promise<void>((resolve): void => {
		target.addEventListener('__bridge_ready', (): void => resolve(), { once: true });
	});
	const session = installBridgePageHandshakeSession(target, {
		onReadyError: (error): void => {
			errors.push(error);
		},
	});
	try {
		await readySent;
		await vi.advanceTimersByTimeAsync(30);
		expect(errors).toHaveLength(0);
		await vi.advanceTimersByTimeAsync(1);
		expect(errors).toEqual([expect.objectContaining({ kind: 'ack_timeout' })]);
	} finally {
		session.uninstall();
	}
});

import { act } from 'react';

import { bridgePageConfigurationSchema } from '../bridge/bridge-page-configuration.js';
import pageConfigurationFixture from '../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };

const pageConfiguration = bridgePageConfigurationSchema.parse(pageConfigurationFixture);

export async function pollWithinAct<TValue>(props: {
	readonly getValue: () => TValue;
	readonly isSatisfied: (value: TValue) => boolean;
	readonly pollIntervalMilliseconds?: number;
	readonly timeoutMilliseconds?: number;
}): Promise<TValue> {
	const timeoutMilliseconds = props.timeoutMilliseconds ?? 5_000;
	const pollIntervalMilliseconds = props.pollIntervalMilliseconds ?? 20;
	const deadlineMilliseconds = Date.now() + timeoutMilliseconds;
	// oxlint-disable-next-line no-unreachable-loop -- Bounded polling returns at success or deadline.
	for (;;) {
		const value = props.getValue();
		if (props.isSatisfied(value) || Date.now() >= deadlineMilliseconds) return value;
		// oxlint-disable-next-line no-await-in-loop -- UI settling must drain sequentially inside act().
		await act(async (): Promise<void> => {
			await new Promise<void>((resolve): void => {
				setTimeout(resolve, pollIntervalMilliseconds);
			});
		});
	}
}

export function pollWithinActUntilTruthy<TValue>(getValue: () => TValue): Promise<TValue> {
	return pollWithinAct({ getValue, isSatisfied: (value): boolean => Boolean(value) });
}

export function pollWithinActUntilEqual<TValue>(
	getValue: () => TValue,
	expectedValue: TValue,
): Promise<TValue> {
	return pollWithinAct({ getValue, isSatisfied: (value): boolean => value === expectedValue });
}

export function actClick(element: { readonly click: () => void }): Promise<void> {
	return act(async (): Promise<void> => {
		element.click();
		await Promise.resolve();
	});
}

export function actWait<TValue>(wait: () => Promise<TValue>): Promise<TValue> {
	return act(wait);
}

export async function actUpdate(update: () => void | Promise<void>): Promise<void> {
	await act(async (): Promise<void> => {
		await update();
		await Promise.resolve();
	});
}

export interface InstalledBridgeReadyHandshake {
	readonly dispose: () => void;
}

export interface InstalledControlledBridgeReadyHandshake extends InstalledBridgeReadyHandshake {
	readonly acknowledgeReady: () => void;
	readonly readyRequestId: () => string | null;
}

function dispatchBridgeHandshakeWithoutTelemetryConfig(): void {
	document.dispatchEvent(new CustomEvent('__bridge_handshake', { detail: { pageConfiguration } }));
}

export function installControlledBridgeReadyHandshake(): InstalledControlledBridgeReadyHandshake {
	let readyRequestId: string | null = null;
	const handleBridgeReady = (event: Event): void => {
		if (!('detail' in event)) return;
		const detail = event.detail;
		if (
			typeof detail !== 'object' ||
			detail === null ||
			!('requestId' in detail) ||
			typeof detail.requestId !== 'string'
		) {
			return;
		}
		readyRequestId = detail.requestId;
	};
	document.addEventListener(
		'__bridge_handshake_request',
		dispatchBridgeHandshakeWithoutTelemetryConfig,
	);
	document.addEventListener('__bridge_ready', handleBridgeReady);
	return {
		acknowledgeReady: (): void => {
			if (readyRequestId === null) {
				throw new Error('Expected a pending Bridge ready request.');
			}
			document.dispatchEvent(
				new CustomEvent('__bridge_ready_ack', {
					detail: { jsonrpc: '2.0', id: readyRequestId, result: null },
				}),
			);
		},
		dispose: (): void => {
			document.removeEventListener(
				'__bridge_handshake_request',
				dispatchBridgeHandshakeWithoutTelemetryConfig,
			);
			document.removeEventListener('__bridge_ready', handleBridgeReady);
		},
		readyRequestId: (): string | null => readyRequestId,
	};
}

export function installBridgeReadyHandshake(
	props: {
		readonly readyErrorMessage?: string;
		readonly telemetryConfig?: unknown;
	} = {},
): InstalledBridgeReadyHandshake {
	const handleBridgeHandshakeRequest = (): void => {
		document.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration, telemetryConfig: props.telemetryConfig },
			}),
		);
	};
	const handleBridgeReady = (event: Event): void => {
		if (!('detail' in event)) return;
		const detail = event.detail;
		if (
			typeof detail !== 'object' ||
			detail === null ||
			!('requestId' in detail) ||
			typeof detail.requestId !== 'string'
		) {
			return;
		}
		document.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail:
					props.readyErrorMessage === undefined
						? { jsonrpc: '2.0', id: detail.requestId, result: null }
						: {
								jsonrpc: '2.0',
								id: detail.requestId,
								error: { code: -32_000, message: props.readyErrorMessage },
							},
			}),
		);
	};
	document.addEventListener('__bridge_handshake_request', handleBridgeHandshakeRequest);
	document.addEventListener('__bridge_ready', handleBridgeReady);
	return {
		dispose: (): void => {
			document.removeEventListener('__bridge_handshake_request', handleBridgeHandshakeRequest);
			document.removeEventListener('__bridge_ready', handleBridgeReady);
		},
	};
}

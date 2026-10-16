import { act } from 'react';
import { afterEach, beforeEach } from 'vitest';

import { bridgePageConfigurationSchema } from '../bridge/bridge-page-configuration.js';
import { BridgeProductTestFactRecorder } from '../core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';
import pageConfigurationFixture from '../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };

const pageConfiguration = bridgePageConfigurationSchema.parse(pageConfigurationFixture);
const activeHandshakes = new Set<() => void>();
let currentTestSignal: AbortSignal | undefined;

beforeEach((context): void => {
	currentTestSignal = context.signal;
});

afterEach((): void => {
	for (const dispose of activeHandshakes) dispose();
	activeHandshakes.clear();
	currentTestSignal = undefined;
});

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
	readonly acknowledgeReady: (requestId: string) => void;
	readonly waitForReadyRequest: () => Promise<string>;
}

function dispatchBridgeHandshakeWithoutTelemetryConfig(): void {
	document.dispatchEvent(new CustomEvent('__bridge_handshake', { detail: { pageConfiguration } }));
}

export function installControlledBridgeReadyHandshake(): InstalledControlledBridgeReadyHandshake {
	const ownerSignal = currentTestSignal;
	const readyRequests = new BridgeProductTestFactRecorder<string>();
	const readyRequestIds = new Set<string>();
	let isDisposed = false;
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
		if (!isDisposed) {
			readyRequestIds.add(detail.requestId);
			readyRequests.record(detail.requestId);
		}
	};
	document.addEventListener(
		'__bridge_handshake_request',
		dispatchBridgeHandshakeWithoutTelemetryConfig,
	);
	document.addEventListener('__bridge_ready', handleBridgeReady);
	const dispose = (): void => {
		if (isDisposed) return;
		isDisposed = true;
		document.removeEventListener(
			'__bridge_handshake_request',
			dispatchBridgeHandshakeWithoutTelemetryConfig,
		);
		document.removeEventListener('__bridge_ready', handleBridgeReady);
		readyRequests.close(new Error('Controlled Bridge ready handshake closed.'));
		ownerSignal?.removeEventListener('abort', dispose);
		activeHandshakes.delete(dispose);
	};
	activeHandshakes.add(dispose);
	ownerSignal?.addEventListener('abort', dispose, { once: true });
	return {
		acknowledgeReady: (readyRequestId): void => {
			if (isDisposed || !readyRequestIds.has(readyRequestId)) {
				throw new Error('Expected a pending Bridge ready request.');
			}
			document.dispatchEvent(
				new CustomEvent('__bridge_ready_ack', {
					detail: { jsonrpc: '2.0', id: readyRequestId, result: null },
				}),
			);
		},
		dispose,
		waitForReadyRequest: (): Promise<string> => readyRequests.waitFor(),
	};
}

export function installBridgeReadyHandshake(
	props: {
		readonly readyErrorMessage?: string;
		readonly telemetryConfig?: unknown;
	} = {},
): InstalledBridgeReadyHandshake {
	const ownerSignal = currentTestSignal;
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
	const dispose = (): void => {
		document.removeEventListener('__bridge_handshake_request', handleBridgeHandshakeRequest);
		document.removeEventListener('__bridge_ready', handleBridgeReady);
		activeHandshakes.delete(dispose);
		ownerSignal?.removeEventListener('abort', dispose);
	};
	activeHandshakes.add(dispose);
	ownerSignal?.addEventListener('abort', dispose, { once: true });
	return {
		dispose,
	};
}

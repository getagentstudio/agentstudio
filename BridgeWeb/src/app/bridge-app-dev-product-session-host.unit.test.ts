import { readFile } from 'node:fs/promises';

import { describe, expect, test, vi } from 'vitest';

import {
	BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
	BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
	BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from '../core/comm-worker/bridge-product-contract-primitives.js';
import {
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_REQUEST_MEDIA_TYPE,
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE,
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE,
	BRIDGE_PRODUCT_DEV_HEALTH_ROUTE,
	encodeBridgeProductDevBootstrapDelivery,
	type BridgeProductDevBootstrapDelivery,
} from '../core/comm-worker/bridge-product-dev-bootstrap.js';
import { bridgeProductSessionBootstrapSchema } from '../core/comm-worker/bridge-product-session-contracts.js';
import validProductSessionCorpus from '../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { installBridgeAppDevProductSessionHost } from './bridge-app-dev-product-session-host.js';

const navigationIntent = {
	commandId: 'dev:worktree:files',
	commandKind: 'activateContext',
	surface: 'file',
} as const;

describe('Bridge app dev product session host', () => {
	test('reports an occupied dev session without polling health or delivering a bootstrap', async () => {
		// Arrange
		const target = new EventTarget();
		const onSessionInUse = vi.fn();
		const fetchHealth = vi.fn<typeof fetch>();
		const delivered = vi.fn();
		target.addEventListener('__bridge_product_session_bootstrap', delivered);
		const props = {
			fetchBootstrap: vi.fn<typeof fetch>(async () => new Response(null, { status: 409 })),
			fetchHealth,
			navigationIntent,
			onSessionInUse,
			target,
		};
		const host = installBridgeAppDevProductSessionHost(props);
		try {
			// Act
			target.dispatchEvent(
				new CustomEvent('__bridge_product_session_bootstrap_request', {
					detail: { reason: 'initial', requestId: 'occupied-session' },
				}),
			);
			// Assert
			await vi.waitFor(() => expect(onSessionInUse).toHaveBeenCalledOnce());
			expect(delivered).not.toHaveBeenCalled();
			expect(fetchHealth).not.toHaveBeenCalled();
		} finally {
			host.dispose();
		}
	});

	test('keeps product capability minting out of page JavaScript', async () => {
		// Arrange
		const source = await readFile(
			new URL('./bridge-app-dev-product-session-host.ts', import.meta.url),
			'utf8',
		);

		// Act
		const pageMintsProductCapability =
			source.includes('crypto.getRandomValues') ||
			source.includes('BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH');

		// Assert
		expect(pageMintsProductCapability).toBe(false);
		expect(source).toContain('props.fetchBootstrap(');
		expect(source).toContain('BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE');
	});

	test('obtains fresh registered bootstraps from the server-owned POST route', async () => {
		// Arrange
		const target = new EventTarget();
		const deliveries = [productBootstrapDelivery(1), productBootstrapDelivery(2)];
		let deliveryIndex = 0;
		const fetchBootstrap = vi.fn<typeof fetch>(async () => {
			const delivery = deliveries[deliveryIndex];
			if (delivery === undefined) throw new Error('Unexpected bootstrap request.');
			deliveryIndex += 1;
			const envelope = encodeBridgeProductDevBootstrapDelivery(delivery);
			return new Response(envelope.buffer as ArrayBuffer, {
				headers: { 'Content-Type': BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE },
				status: 200,
			});
		});
		const responses: unknown[] = [];
		const waitForResponse = (): Promise<void> =>
			new Promise<void>((resolve): void => {
				target.addEventListener(
					'__bridge_product_session_bootstrap',
					(event): void => {
						responses.push('detail' in event ? event.detail : null);
						resolve();
					},
					{ once: true },
				);
			});
		const host = installBridgeAppDevProductSessionHost({
			fetchBootstrap,
			navigationIntent,
			tabId: 'tab-owner-1',
			target,
		});

		// Act
		const firstResponse = waitForResponse();
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'initial', requestId: 'request-1' },
			}),
		);
		await firstResponse;
		const secondResponse = waitForResponse();
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'workerReplacement', requestId: 'request-2' },
			}),
		);
		await secondResponse;

		// Assert
		expect(responses).toHaveLength(2);
		const first = parseResponse(responses[0]);
		const second = parseResponse(responses[1]);
		expect(first.requestId).toBe('request-1');
		expect(second.requestId).toBe('request-2');
		expect(first.bootstrap.workerInstanceId).not.toBe(second.bootstrap.workerInstanceId);
		expect(first.productCapability.byteLength).toBe(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH);
		expect(second.productCapability.byteLength).toBe(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH);
		expect([...new Uint8Array(first.productCapability)]).not.toEqual([
			...new Uint8Array(second.productCapability),
		]);
		expect(fetchBootstrap).toHaveBeenCalledTimes(2);
		const firstFetch = fetchBootstrap.mock.calls[0];
		const secondFetch = fetchBootstrap.mock.calls[1];
		expect(firstFetch?.[0]).toBe(BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE);
		expect(firstFetch?.[1]).toMatchObject({
			body: JSON.stringify({ navigationIntent, reason: 'initial', tabId: 'tab-owner-1' }),
			cache: 'no-store',
			credentials: 'same-origin',
			headers: { 'Content-Type': BRIDGE_PRODUCT_DEV_BOOTSTRAP_REQUEST_MEDIA_TYPE },
			method: 'POST',
		});
		expect(secondFetch?.[1]).toMatchObject({
			body: JSON.stringify({
				navigationIntent,
				paneSessionId: first.bootstrap.paneSessionId,
				reason: 'workerReplacement',
				tabId: 'tab-owner-1',
			}),
			method: 'POST',
		});

		host.dispose();
	});

	test('binds the default browser fetch receiver before requesting the initial bootstrap', async () => {
		// Arrange
		const target = new EventTarget();
		const delivery = productBootstrapDelivery(1);
		const envelope = encodeBridgeProductDevBootstrapDelivery(delivery);
		const originalFetch = globalThis.fetch;
		const observedFetchReceivers: unknown[] = [];
		globalThis.fetch = vi.fn(function (this: unknown): Promise<Response> {
			observedFetchReceivers.push(this);
			return Promise.resolve(
				new Response(envelope.buffer as ArrayBuffer, {
					headers: { 'Content-Type': BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE },
					status: 200,
				}),
			);
		});
		const response = new Promise<void>((resolve): void => {
			target.addEventListener('__bridge_product_session_bootstrap', (): void => resolve(), {
				once: true,
			});
		});
		const host = installBridgeAppDevProductSessionHost({ navigationIntent, target });

		try {
			// Act
			target.dispatchEvent(
				new CustomEvent('__bridge_product_session_bootstrap_request', {
					detail: { reason: 'initial', requestId: 'request-default-fetch' },
				}),
			);
			await response;

			// Assert
			expect(observedFetchReceivers).toEqual([globalThis]);
		} finally {
			host.dispose();
			globalThis.fetch = originalFetch;
		}
	});

	test('acknowledges page readiness only after the initial bootstrap succeeds', async () => {
		// Arrange
		const target = new EventTarget();
		const envelope = encodeBridgeProductDevBootstrapDelivery(productBootstrapDelivery(1));
		const fetchBootstrap = vi.fn<typeof fetch>(
			async () =>
				new Response(envelope.buffer as ArrayBuffer, {
					headers: { 'Content-Type': BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE },
					status: 200,
				}),
		);
		const fetchHealth = vi.fn<typeof fetch>();
		const reloadPage = vi.fn();
		const acknowledgement = waitForReadyAcknowledgement(target);
		const host = installBridgeAppDevProductSessionHost({
			fetchBootstrap,
			fetchHealth,
			navigationIntent,
			reloadPage,
			target,
		});

		// Act
		target.dispatchEvent(
			new CustomEvent('__bridge_ready', { detail: { requestId: 'bridge-ready-success' } }),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'initial', requestId: 'bootstrap-success' },
			}),
		);

		// Assert
		expect(await acknowledgement).toEqual({
			jsonrpc: '2.0',
			id: 'bridge-ready-success',
			result: null,
		});
		expect(fetchHealth).not.toHaveBeenCalled();
		expect(reloadPage).not.toHaveBeenCalled();
		host.dispose();
	});

	test('acknowledges a fresh ready request after React reinstalls the handshake', async () => {
		// Arrange
		const target = new EventTarget();
		const deliveries = [productBootstrapDelivery(1), productBootstrapDelivery(2)];
		const fetchBootstrap = vi.fn<typeof fetch>(async () => {
			const delivery = deliveries.shift();
			if (delivery === undefined) throw new Error('Unexpected bootstrap request.');
			const envelope = encodeBridgeProductDevBootstrapDelivery(delivery);
			return new Response(envelope.buffer as ArrayBuffer, {
				headers: { 'Content-Type': BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE },
				status: 200,
			});
		});
		const host = installBridgeAppDevProductSessionHost({
			fetchBootstrap,
			navigationIntent,
			target,
		});

		// Act
		const firstAcknowledgement = waitForReadyAcknowledgement(target);
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'initial', requestId: 'bootstrap-first-handshake' },
			}),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_ready', { detail: { requestId: 'bridge-ready-first' } }),
		);
		await firstAcknowledgement;
		const secondAcknowledgement = waitForReadyAcknowledgement(target);
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'initial', requestId: 'bootstrap-second-handshake' },
			}),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_ready', { detail: { requestId: 'bridge-ready-second' } }),
		);

		// Assert
		expect(await secondAcknowledgement).toEqual({
			jsonrpc: '2.0',
			id: 'bridge-ready-second',
			result: null,
		});
		expect(fetchBootstrap).toHaveBeenCalledTimes(2);
		host.dispose();
	});

	test('acknowledges initial failure and reloads once after the backend becomes healthy', async () => {
		// Arrange
		const target = new EventTarget();
		const fetchBootstrap = vi.fn<typeof fetch>(
			async () =>
				new Response(null, {
					headers: { 'Content-Type': 'text/plain' },
					status: 502,
				}),
		);
		const fetchHealth = vi
			.fn<typeof fetch>()
			.mockRejectedValueOnce(new Error('still unavailable'))
			.mockResolvedValueOnce(new Response(null, { status: 503 }))
			.mockResolvedValueOnce(new Response(null, { status: 204 }));
		const probeWaits = createControlledHealthProbeWaits();
		const reloadPage = vi.fn();
		const acknowledgement = waitForReadyAcknowledgement(target);
		const host = installBridgeAppDevProductSessionHost({
			fetchBootstrap,
			fetchHealth,
			navigationIntent,
			reloadPage,
			target,
			waitForHealthProbe: probeWaits.wait,
		});

		// Act
		target.dispatchEvent(
			new CustomEvent('__bridge_ready', { detail: { requestId: 'bridge-ready-failure' } }),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'initial', requestId: 'bootstrap-failure' },
			}),
		);

		// Assert
		expect(await acknowledgement).toEqual({
			jsonrpc: '2.0',
			id: 'bridge-ready-failure',
			error: { code: -32_000, message: 'Bridge development backend unavailable' },
		});
		await probeWaits.releaseNext();
		expect(fetchHealth).toHaveBeenNthCalledWith(
			1,
			BRIDGE_PRODUCT_DEV_HEALTH_ROUTE,
			expect.objectContaining({ method: 'GET' }),
		);
		await probeWaits.releaseNext();
		await probeWaits.releaseNext();
		expect(fetchHealth).toHaveBeenCalledTimes(3);
		expect(reloadPage).toHaveBeenCalledOnce();
		host.dispose();
	});

	test('recovers a failed replacement bootstrap after the backend becomes healthy', async () => {
		// Arrange — a live pane has already received its first native-owned capability.
		const target = new EventTarget();
		const envelope = encodeBridgeProductDevBootstrapDelivery(productBootstrapDelivery(1));
		const fetchBootstrap = vi
			.fn<typeof fetch>()
			.mockResolvedValueOnce(
				new Response(Uint8Array.from(envelope).buffer, {
					headers: { 'Content-Type': BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE },
					status: 200,
				}),
			)
			.mockResolvedValueOnce(
				new Response(null, { headers: { 'Content-Type': 'text/plain' }, status: 502 }),
			);
		const initialBootstrap = new Promise<void>((resolve): void => {
			target.addEventListener('__bridge_product_session_bootstrap', (): void => resolve(), {
				once: true,
			});
		});
		const fetchHealth = vi.fn<typeof fetch>(async () => new Response(null, { status: 204 }));
		const reloadPage = vi.fn();
		const host = installBridgeAppDevProductSessionHost({
			fetchBootstrap,
			fetchHealth,
			navigationIntent,
			reloadPage,
			target,
			waitForHealthProbe: async (): Promise<void> => {},
		});

		try {
			// Act — replacement retires the worker, then its bootstrap encounters a proxy outage.
			target.dispatchEvent(
				new CustomEvent('__bridge_product_session_bootstrap_request', {
					detail: { reason: 'initial', requestId: 'initial-before-replacement' },
				}),
			);
			await initialBootstrap;
			target.dispatchEvent(
				new CustomEvent('__bridge_product_session_bootstrap_request', {
					detail: { reason: 'workerReplacement', requestId: 'replacement-outage' },
				}),
			);

			// Assert — restored backend availability rebinds the page once without another UI action.
			await vi.waitFor((): void => expect(reloadPage).toHaveBeenCalledOnce());
			expect(fetchBootstrap).toHaveBeenCalledTimes(2);
			expect(fetchHealth).toHaveBeenCalledOnce();
		} finally {
			host.dispose();
		}
	});

	test('reloads after the backend truncates an accepted bootstrap response', async () => {
		// Arrange
		const target = new EventTarget();
		const truncatedResponse = new Response(new Uint8Array([1]), {
			headers: { 'Content-Type': BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE },
			status: 200,
		});
		vi.spyOn(truncatedResponse, 'arrayBuffer').mockRejectedValue(
			new TypeError('terminated while reading response body'),
		);
		const fetchBootstrap = vi.fn<typeof fetch>(async () => truncatedResponse);
		const fetchHealth = vi.fn<typeof fetch>(async () => new Response(null, { status: 204 }));
		const reloadPage = vi.fn();
		const acknowledgement = waitForReadyAcknowledgement(target);
		const host = installBridgeAppDevProductSessionHost({
			fetchBootstrap,
			fetchHealth,
			navigationIntent,
			reloadPage,
			target,
			waitForHealthProbe: async (): Promise<void> => {},
		});

		// Act
		target.dispatchEvent(
			new CustomEvent('__bridge_ready', { detail: { requestId: 'bridge-ready-truncated' } }),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'initial', requestId: 'bootstrap-truncated' },
			}),
		);

		// Assert
		expect(await acknowledgement).toEqual({
			jsonrpc: '2.0',
			id: 'bridge-ready-truncated',
			error: { code: -32_000, message: 'Bridge development backend unavailable' },
		});
		await vi.waitFor((): void => {
			expect(fetchHealth).toHaveBeenCalledOnce();
			expect(reloadPage).toHaveBeenCalledOnce();
		});
		host.dispose();
	});

	test.each([
		{
			label: 'live backend rejection',
			response: (): Response => new Response(null, { status: 503 }),
		},
		{
			label: 'non-empty 502 response',
			response: (): Response =>
				new Response('application rejection', {
					headers: { 'Content-Type': 'text/plain' },
					status: 502,
				}),
		},
	])('does not reload after an application bootstrap rejection: $label', async ({ response }) => {
		// Arrange
		const target = new EventTarget();
		const fetchBootstrap = vi.fn<typeof fetch>(async () => response());
		const fetchHealth = vi.fn<typeof fetch>(async () => new Response(null, { status: 204 }));
		const reloadPage = vi.fn();
		const acknowledgement = waitForReadyAcknowledgement(target);
		const host = installBridgeAppDevProductSessionHost({
			fetchBootstrap,
			fetchHealth,
			navigationIntent,
			reloadPage,
			target,
			waitForHealthProbe: async (): Promise<void> => {},
		});

		// Act
		target.dispatchEvent(
			new CustomEvent('__bridge_ready', { detail: { requestId: 'bridge-ready-rejected' } }),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'initial', requestId: 'bootstrap-rejected' },
			}),
		);
		await acknowledgement;
		await Promise.resolve();

		// Assert
		expect(fetchHealth).not.toHaveBeenCalled();
		expect(reloadPage).not.toHaveBeenCalled();
		host.dispose();
	});

	test('disposal cancels readiness probing before a page reload', async () => {
		// Arrange
		const target = new EventTarget();
		const fetchBootstrap = vi.fn<typeof fetch>(async () => {
			throw new Error('backend unavailable');
		});
		const fetchHealth = vi.fn<typeof fetch>();
		const probeWaits = createControlledHealthProbeWaits();
		const reloadPage = vi.fn();
		const acknowledgement = waitForReadyAcknowledgement(target);
		const host = installBridgeAppDevProductSessionHost({
			fetchBootstrap,
			fetchHealth,
			navigationIntent,
			reloadPage,
			target,
			waitForHealthProbe: probeWaits.wait,
		});
		target.dispatchEvent(
			new CustomEvent('__bridge_ready', { detail: { requestId: 'bridge-ready-dispose' } }),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'initial', requestId: 'bootstrap-dispose' },
			}),
		);
		await acknowledgement;

		// Act
		host.dispose();
		await probeWaits.releaseNext();

		// Assert
		expect(fetchHealth).not.toHaveBeenCalled();
		expect(reloadPage).not.toHaveBeenCalled();
	});

	test('ignores malformed requests and stops after disposal', () => {
		// Arrange
		const target = new EventTarget();
		const fetchBootstrap = vi.fn<typeof fetch>();
		let responseCount = 0;
		target.addEventListener('__bridge_product_session_bootstrap', (): void => {
			responseCount += 1;
		});
		const host = installBridgeAppDevProductSessionHost({
			fetchBootstrap,
			navigationIntent,
			target,
		});

		// Act
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'unknown', requestId: 'request-1' },
			}),
		);
		host.dispose();
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap_request', {
				detail: { reason: 'initial', requestId: 'request-2' },
			}),
		);

		// Assert
		expect(responseCount).toBe(0);
		expect(fetchBootstrap).not.toHaveBeenCalled();
	});
});

function waitForReadyAcknowledgement(target: EventTarget): Promise<unknown> {
	return new Promise<unknown>((resolve): void => {
		target.addEventListener(
			'__bridge_ready_ack',
			(event): void => resolve('detail' in event ? event.detail : null),
			{ once: true },
		);
	});
}

function createControlledHealthProbeWaits(): {
	readonly releaseNext: () => Promise<void>;
	readonly wait: (signal: AbortSignal) => Promise<void>;
} {
	const pendingWaits: Array<() => void> = [];
	return {
		releaseNext: async (): Promise<void> => {
			await vi.waitFor((): void => {
				expect(pendingWaits.length).toBeGreaterThan(0);
			});
			pendingWaits.shift()?.();
			for (let microtask = 0; microtask < 4; microtask += 1) {
				await Promise.resolve();
			}
		},
		wait: async (signal): Promise<void> => {
			await new Promise<void>((resolve): void => {
				if (signal.aborted) {
					resolve();
					return;
				}
				pendingWaits.push(resolve);
				signal.addEventListener('abort', (): void => resolve(), { once: true });
			});
		},
	};
}

function productBootstrapDelivery(sequence: number): BridgeProductDevBootstrapDelivery {
	return {
		bootstrap: bridgeProductSessionBootstrapSchema.parse({
			kind: 'productSession.bootstrap',
			paneSessionId: 'vite-dev-pane-session',
			policy: {
				...validProductSessionCorpus.bootstrap.policy,
				admissionRetryCount: validProductSessionCorpus.bootstrap.policy.admissionRetryCount,
				contentAcknowledgementDeadlineMilliseconds: 5_000,
				contentProgressDeadlineMilliseconds: 5_000,
				maximumContentBytes: BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
				maximumMetadataFrameBytes: BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
				maximumQueuedStreamBytes: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
				maximumQueuedStreamFrames: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
				maximumRequestBodyBytes: BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
				terminalFrameReserve: BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
				telemetryPreReadyBufferMaxBytes:
					validProductSessionCorpus.bootstrap.policy.telemetryPreReadyBufferMaxBytes,
				telemetryPreReadyBufferMaxSamples:
					validProductSessionCorpus.bootstrap.policy.telemetryPreReadyBufferMaxSamples,
				workerSettlementDeadlineMilliseconds:
					validProductSessionCorpus.bootstrap.policy.workerSettlementDeadlineMilliseconds,
			},
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerInstanceId: `vite-dev-worker-${sequence}`,
		}),
		productCapability: Uint8Array.from(
			{ length: BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH },
			(_, index): number => (index + sequence) % 256,
		).buffer,
	};
}

function parseResponse(value: unknown): {
	readonly bootstrap: ReturnType<typeof bridgeProductSessionBootstrapSchema.parse>;
	readonly productCapability: ArrayBuffer;
	readonly requestId: string;
} {
	if (
		typeof value !== 'object' ||
		value === null ||
		!('bootstrap' in value) ||
		!('productCapability' in value) ||
		!('requestId' in value) ||
		!(value.productCapability instanceof ArrayBuffer) ||
		typeof value.requestId !== 'string'
	) {
		throw new Error('Invalid dev product session response.');
	}
	return {
		bootstrap: bridgeProductSessionBootstrapSchema.parse(value.bootstrap),
		productCapability: value.productCapability,
		requestId: value.requestId,
	};
}

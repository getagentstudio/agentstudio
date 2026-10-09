import { runInNewContext } from 'node:vm';

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
import type { BridgeTelemetryWorkerBootstrap } from '../core/telemetry-worker/bridge-telemetry-worker-contracts.js';
import pageConfigurationFixture from '../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import validProductSessionCorpus from '../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import {
	installBridgePageHandshake,
	installBridgePageHandshakeSession,
} from './bridge-page-handshake.js';

describe('bridge page handshake', () => {
	test('requests handshake replay and emits bridge ready after bootstrap context arrives', async () => {
		const target = new EventTarget();
		const eventNames: string[] = [];

		target.addEventListener('__bridge_handshake_request', () => {
			eventNames.push('__bridge_handshake_request');
			target.dispatchEvent(
				new CustomEvent('__bridge_handshake', {
					detail: { pageConfiguration: pageConfigurationFixture },
				}),
			);
		});
		target.addEventListener('__bridge_ready', () => {
			eventNames.push('__bridge_ready');
		});

		const uninstall = installBridgePageHandshake(target);
		expect(eventNames).toEqual(['__bridge_handshake_request']);
		await Promise.resolve();
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		uninstall();

		expect(eventNames).toEqual(['__bridge_handshake_request', '__bridge_ready']);
	});

	test('does not emit bridge ready until bootstrap context arrives', async () => {
		const target = new EventTarget();
		const eventNames: string[] = [];

		target.addEventListener('__bridge_ready', () => {
			eventNames.push('__bridge_ready');
		});

		const session = installBridgePageHandshakeSession(target);
		expect(eventNames).toEqual([]);

		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		expect(eventNames).toEqual([]);
		await Promise.resolve();
		session.uninstall();

		expect(eventNames).toEqual(['__bridge_ready']);
	});

	test('emits bridge ready only once when bootstrap context is replayed', async () => {
		const target = new EventTarget();
		const eventNames: string[] = [];

		target.addEventListener('__bridge_ready', () => {
			eventNames.push('__bridge_ready');
		});

		const session = installBridgePageHandshakeSession(target);
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		await Promise.resolve();
		session.uninstall();

		expect(eventNames).toEqual(['__bridge_ready']);
	});

	test('retains telemetry config from the first valid handshake config', () => {
		const target = new EventTarget();

		target.addEventListener('__bridge_handshake_request', () => {
			target.dispatchEvent(
				new CustomEvent('__bridge_handshake', {
					detail: {
						pageConfiguration: pageConfigurationFixture,
						telemetryConfig: {
							enabledScopes: ['web', 'webkit'],
							scenario: 'bridge-runtime',
						},
					},
				}),
			);
		});

		const session = installBridgePageHandshakeSession(target);
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture, telemetryConfig: null },
			}),
		);
		session.uninstall();

		expect(session.getTelemetryConfig()?.enabledScopes.has('web')).toBe(true);
		expect(session.getTelemetryConfig()?.scenario).toBe('bridge-runtime');
	});

	test('notifies when the first valid telemetry config arrives after install', () => {
		const target = new EventTarget();
		const scenarios: string[] = [];

		const session = installBridgePageHandshakeSession(target, {
			onTelemetryConfig: (telemetryConfig): void => {
				scenarios.push(telemetryConfig.scenario);
			},
		});
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: {
					pageConfiguration: pageConfigurationFixture,
					telemetryConfig: {
						enabledScopes: ['web'],
						scenario: 'metadata_apply_content_fetch_v1',
					},
				},
			}),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: {
					pageConfiguration: pageConfigurationFixture,
					telemetryConfig: {
						enabledScopes: ['web'],
						scenario: 'ignored_later_config',
					},
				},
			}),
		);
		session.uninstall();

		expect(scenarios).toEqual(['metadata_apply_content_fetch_v1']);
		expect(session.getTelemetryConfig()?.scenario).toBe('metadata_apply_content_fetch_v1');
	});

	test('notifies ready callback only after native acknowledges bridge ready', async () => {
		const target = new EventTarget();
		const events: string[] = [];
		let readyRequestId: string | null = null;

		target.addEventListener('__bridge_ready', (event) => {
			readyRequestId = extractReadyRequestId(event);
			events.push('ready-event');
		});

		const session = installBridgePageHandshakeSession(target, {
			onReady: (): void => {
				events.push('ready-callback');
			},
		});
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		await Promise.resolve();
		expect(events).toEqual(['ready-event']);
		expect(readyRequestId).not.toBeNull();
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail: { jsonrpc: '2.0', id: readyRequestId, result: null },
			}),
		);
		session.uninstall();

		expect(events).toEqual(['ready-event', 'ready-callback']);
	});

	test('does not dispatch bridge-ready over ordinary page command RPC', async () => {
		const target = new EventTarget();
		const events: string[] = [];
		let readyRequestId: string | null = null;

		target.addEventListener('__bridge_ready', (event) => {
			readyRequestId = extractReadyRequestId(event);
			events.push('ready-event');
		});
		target.addEventListener('__bridge_command', (): void => {
			events.push('bridge-ready-command');
		});

		const session = installBridgePageHandshakeSession(target, {
			onReady: (): void => {
				events.push('ready-callback');
			},
		});
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		await Promise.resolve();
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail: { jsonrpc: '2.0', id: readyRequestId, result: null },
			}),
		);
		session.uninstall();

		expect(events).toEqual(['ready-event', 'ready-callback']);
	});

	test('ignores bridge ready acknowledgements for a different request id', async () => {
		const target = new EventTarget();
		const events: string[] = [];
		let readyRequestId: string | null = null;

		target.addEventListener('__bridge_ready', (event) => {
			readyRequestId = extractReadyRequestId(event);
			events.push('ready-event');
		});

		const session = installBridgePageHandshakeSession(target, {
			onReady: (): void => {
				events.push('ready-callback');
			},
		});
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		await Promise.resolve();
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail: { jsonrpc: '2.0', id: 'wrong-ready-id', result: null },
			}),
		);
		expect(events).toEqual(['ready-event']);
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail: { jsonrpc: '2.0', id: readyRequestId, result: null },
			}),
		);
		session.uninstall();

		expect(events).toEqual(['ready-event', 'ready-callback']);
	});

	test('ignores malformed bridge ready acknowledgement envelopes', async () => {
		const target = new EventTarget();
		const events: string[] = [];
		let readyRequestId: string | null = null;

		target.addEventListener('__bridge_ready', (event) => {
			readyRequestId = extractReadyRequestId(event);
			events.push('ready-event');
		});

		const session = installBridgePageHandshakeSession(target, {
			onReady: (): void => {
				events.push('ready-callback');
			},
		});
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		await Promise.resolve();
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail: { id: readyRequestId },
			}),
		);
		expect(events).toEqual(['ready-event']);
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail: { jsonrpc: '2.0', id: readyRequestId, result: null },
			}),
		);
		session.uninstall();

		expect(events).toEqual(['ready-event', 'ready-callback']);
	});

	test('reports missing bridge ready acknowledgements instead of waiting forever', async () => {
		vi.useFakeTimers();
		const target = new EventTarget();
		const events: string[] = [];

		const session = installBridgePageHandshakeSession(target, {
			onReady: (): void => {
				events.push('ready-callback');
			},
			onReadyError: (error): void => {
				events.push(
					`${error.kind}:${error.requestId !== null && error.requestId.length > 0 ? 'request' : 'missing'}`,
				);
			},
			readyAcknowledgementTimeoutMilliseconds: 25,
		});
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		await Promise.resolve();

		vi.advanceTimersByTime(25);
		session.uninstall();
		vi.useRealTimers();

		expect(events).toEqual(['ack_timeout:request']);
	});

	test('recovers when the exact ready acknowledgement succeeds after the local timeout', async () => {
		vi.useFakeTimers();
		const target = new EventTarget();
		const events: string[] = [];
		let readyRequestId: string | null = null;

		target.addEventListener('__bridge_ready', (event) => {
			readyRequestId = extractReadyRequestId(event);
		});
		const session = installBridgePageHandshakeSession(target, {
			onReady: (): void => {
				events.push('ready');
			},
			onReadyError: (error): void => {
				events.push(error.kind);
			},
			readyAcknowledgementTimeoutMilliseconds: 25,
		});
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		await Promise.resolve();

		vi.advanceTimersByTime(25);
		expect(events).toEqual(['ack_timeout']);
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail: { jsonrpc: '2.0', id: readyRequestId, result: null },
			}),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail: { jsonrpc: '2.0', id: readyRequestId, result: null },
			}),
		);
		session.uninstall();
		vi.useRealTimers();

		expect(events).toEqual(['ack_timeout', 'ready']);
	});

	test('notifies ready callback at most once for duplicate acknowledgements', async () => {
		const target = new EventTarget();
		const events: string[] = [];
		let readyRequestId: string | null = null;

		target.addEventListener('__bridge_ready', (event) => {
			readyRequestId = extractReadyRequestId(event);
		});

		const session = installBridgePageHandshakeSession(target, {
			onReady: (): void => {
				events.push('ready-callback');
			},
		});
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { pageConfiguration: pageConfigurationFixture },
			}),
		);
		await Promise.resolve();
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail: { jsonrpc: '2.0', id: readyRequestId, result: null },
			}),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail: { jsonrpc: '2.0', id: readyRequestId, result: null },
			}),
		);
		session.uninstall();

		expect(events).toEqual(['ready-callback']);
	});

	test('correlates initial and replacement product bootstraps while ignoring duplicates', () => {
		const target = new EventTarget();
		const deliveredWorkerInstanceIds: string[] = [];
		const bootstrapRequests: Array<{ readonly reason: string; readonly requestId: string }> = [];
		target.addEventListener('__bridge_product_session_bootstrap_request', (event): void => {
			const request = extractProductBootstrapRequest(event);
			bootstrapRequests.push(request);
			const workerInstanceId = `worker-${bootstrapRequests.length.toString()}`;
			const detail = makeProductBootstrapDetail(request.requestId, workerInstanceId);
			target.dispatchEvent(new CustomEvent('__bridge_product_session_bootstrap', { detail }));
			target.dispatchEvent(new CustomEvent('__bridge_product_session_bootstrap', { detail }));
		});
		const session = installBridgePageHandshakeSession(target, {
			onProductSessionBootstrap: ({ bootstrap }): void => {
				deliveredWorkerInstanceIds.push(bootstrap.workerInstanceId);
			},
		});

		session.requestProductSessionReplacement();
		session.uninstall();

		expect(bootstrapRequests).toEqual([
			expect.objectContaining({ reason: 'initial' }),
			expect.objectContaining({ reason: 'workerReplacement' }),
		]);
		expect(bootstrapRequests[0]?.requestId).not.toBe(bootstrapRequests[1]?.requestId);
		expect(deliveredWorkerInstanceIds).toEqual(['worker-1', 'worker-2']);
	});

	test('reports one correlated typed product bootstrap failure and ignores uncorrelated replies', () => {
		// Arrange
		const target = new EventTarget();
		const bootstrapRequests: Array<{ readonly reason: string; readonly requestId: string }> = [];
		target.addEventListener('__bridge_product_session_bootstrap_request', (event): void => {
			bootstrapRequests.push(extractProductBootstrapRequest(event));
		});
		const failures: unknown[] = [];
		const deliveredWorkerInstanceIds: string[] = [];
		const session = installBridgePageHandshakeSession(target, {
			onProductSessionBootstrap: ({ bootstrap }): void => {
				deliveredWorkerInstanceIds.push(bootstrap.workerInstanceId);
			},
			onProductSessionBootstrapFailure: (failure): void => {
				failures.push(failure);
			},
		});
		const initialRequest = bootstrapRequests[0];
		if (initialRequest === undefined) {
			throw new Error('Expected initial bootstrap request.');
		}
		const dispatchFailure = (detail: object): void => {
			target.dispatchEvent(new CustomEvent('__bridge_product_session_bootstrap', { detail }));
		};

		// Act
		dispatchFailure({ failure: { reason: 'retirement_failed' }, requestId: 'uncorrelated' });
		dispatchFailure({ failure: { reason: 'unknown_reason' }, requestId: initialRequest.requestId });
		target.dispatchEvent(
			new CustomEvent('__bridge_product_session_bootstrap', {
				detail: makeProductBootstrapDetail(initialRequest.requestId, 'worker-initial'),
			}),
		);
		session.requestProductSessionReplacement();
		const replacementRequest = bootstrapRequests[1];
		if (replacementRequest === undefined)
			throw new Error('Expected replacement bootstrap request.');
		dispatchFailure({
			failure: { reason: 'retirement_failed' },
			requestId: replacementRequest.requestId,
		});
		dispatchFailure({
			failure: { reason: 'retirement_failed' },
			requestId: replacementRequest.requestId,
		});
		session.uninstall();

		// Assert: a malformed failure leaves its request pending for the real answer.
		expect(failures).toEqual([{ reason: 'retirement_failed', requestReason: 'workerReplacement' }]);
		expect(deliveredWorkerInstanceIds).toEqual(['worker-initial']);
	});

	test('copies an isolated-world product capability into the page realm', () => {
		const target = new EventTarget();
		const isolatedWorldCapability: unknown = runInNewContext(
			'Uint8Array.from({ length: 32 }, () => 7).buffer',
		);
		let deliveredCapability: ArrayBuffer | null = null;
		target.addEventListener('__bridge_product_session_bootstrap_request', (event): void => {
			const request = extractProductBootstrapRequest(event);
			target.dispatchEvent(
				new CustomEvent('__bridge_product_session_bootstrap', {
					detail: makeProductBootstrapDetail(
						request.requestId,
						'worker-isolated-world',
						isolatedWorldCapability,
					),
				}),
			);
		});

		const session = installBridgePageHandshakeSession(target, {
			onProductSessionBootstrap: ({ productCapability }): void => {
				deliveredCapability = productCapability;
			},
		});
		session.uninstall();

		expect(isolatedWorldCapability).not.toBeInstanceOf(ArrayBuffer);
		expect(deliveredCapability).toBeInstanceOf(ArrayBuffer);
		expect(deliveredCapability).not.toBe(isolatedWorldCapability);
		expect([...new Uint8Array(deliveredCapability ?? new ArrayBuffer(0))]).toEqual(
			Array.from({ length: BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH }, () => 7),
		);
	});

	test('independently correlates initial and replacement telemetry bootstrap results', () => {
		const target = new EventTarget();
		const telemetryRequests: Array<{ readonly reason: string; readonly requestId: string }> = [];
		const deliveredResults: string[] = [];
		let productRequestCount = 0;
		target.addEventListener('__bridge_product_session_bootstrap_request', (): void => {
			productRequestCount += 1;
		});
		target.addEventListener('__bridge_telemetry_session_bootstrap_request', (event): void => {
			telemetryRequests.push(extractTelemetryBootstrapRequest(event));
		});
		const session = installBridgePageHandshakeSession(target, {
			onTelemetrySessionBootstrap: (result): void => {
				deliveredResults.push(
					result.kind === 'available'
						? `available:${result.workerBootstrap.telemetrySessionId}`
						: `unavailable:${result.reason}`,
				);
			},
		});
		const initialRequest = telemetryRequests[0];
		if (initialRequest === undefined) throw new Error('expected initial telemetry request');
		target.dispatchEvent(
			new CustomEvent('__bridge_telemetry_session_bootstrap', {
				detail: {
					requestId: 'uncorrelated-telemetry-request',
					result: {
						kind: 'available',
						workerBootstrap: { ...makeTelemetryWorkerBootstrap('ignored'), extra: true },
					},
				},
			}),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_telemetry_session_bootstrap', {
				detail: {
					requestId: initialRequest.requestId,
					result: {
						kind: 'available',
						workerBootstrap: makeTelemetryWorkerBootstrap('telemetry-initial'),
					},
				},
			}),
		);
		target.dispatchEvent(
			new CustomEvent('__bridge_telemetry_session_bootstrap', {
				detail: {
					requestId: initialRequest.requestId,
					result: { kind: 'unavailable', reason: 'failed' },
				},
			}),
		);

		session.requestTelemetrySessionReplacement();
		const replacementRequest = telemetryRequests[1];
		if (replacementRequest === undefined) throw new Error('expected replacement telemetry request');
		target.dispatchEvent(
			new CustomEvent('__bridge_telemetry_session_bootstrap', {
				detail: {
					requestId: replacementRequest.requestId,
					result: { kind: 'unavailable', reason: 'disabled' },
				},
			}),
		);
		session.uninstall();

		expect(productRequestCount).toBe(1);
		expect(telemetryRequests).toEqual([
			expect.objectContaining({ reason: 'initial' }),
			expect.objectContaining({ reason: 'sidecarReplacement' }),
		]);
		expect(initialRequest.requestId).not.toBe(replacementRequest.requestId);
		expect(deliveredResults).toEqual(['available:telemetry-initial', 'unavailable:disabled']);
	});

	test('rejects a correlated telemetry bootstrap result with extra fields', () => {
		const target = new EventTarget();
		let initialRequest: { readonly reason: string; readonly requestId: string } | null = null;
		const deliveredResults: string[] = [];
		target.addEventListener('__bridge_telemetry_session_bootstrap_request', (event): void => {
			initialRequest = extractTelemetryBootstrapRequest(event);
		});
		const session = installBridgePageHandshakeSession(target, {
			onTelemetrySessionBootstrap: (result): void => {
				deliveredResults.push(result.kind);
			},
		});
		const correlatedRequest = requireTelemetryBootstrapRequest(initialRequest);
		target.dispatchEvent(
			new CustomEvent('__bridge_telemetry_session_bootstrap', {
				detail: {
					requestId: correlatedRequest.requestId,
					result: {
						kind: 'available',
						workerBootstrap: {
							...makeTelemetryWorkerBootstrap('telemetry-malformed'),
							extra: true,
						},
					},
				},
			}),
		);
		session.uninstall();

		expect(correlatedRequest.reason).toBe('initial');
		expect(deliveredResults).toEqual([]);
	});
});

function requireTelemetryBootstrapRequest(
	request: { readonly reason: string; readonly requestId: string } | null,
): { readonly reason: string; readonly requestId: string } {
	if (request === null) throw new Error('expected initial telemetry request');
	return request;
}

function extractReadyRequestId(event: Event): string {
	if (!('detail' in event)) {
		throw new Error('expected ready detail');
	}
	const detail = event.detail;
	if (typeof detail !== 'object' || detail === null || !('requestId' in detail)) {
		throw new Error('expected ready request id');
	}
	if (typeof detail.requestId !== 'string') {
		throw new Error('expected string ready request id');
	}
	return detail.requestId;
}

function extractProductBootstrapRequest(event: Event): {
	readonly reason: string;
	readonly requestId: string;
} {
	if (!('detail' in event)) {
		throw new Error('expected product bootstrap request detail');
	}
	const detail = event.detail;
	if (
		typeof detail !== 'object' ||
		detail === null ||
		!('reason' in detail) ||
		!('requestId' in detail) ||
		typeof detail.reason !== 'string' ||
		typeof detail.requestId !== 'string'
	) {
		throw new Error('expected typed product bootstrap request');
	}
	return { reason: detail.reason, requestId: detail.requestId };
}

function extractTelemetryBootstrapRequest(event: Event): {
	readonly reason: string;
	readonly requestId: string;
} {
	if (!('detail' in event)) throw new Error('expected telemetry bootstrap request detail');
	const detail = event.detail;
	if (
		typeof detail !== 'object' ||
		detail === null ||
		!('reason' in detail) ||
		!('requestId' in detail) ||
		typeof detail.reason !== 'string' ||
		typeof detail.requestId !== 'string'
	) {
		throw new Error('expected typed telemetry bootstrap request');
	}
	return { reason: detail.reason, requestId: detail.requestId };
}

function makeTelemetryWorkerBootstrap(telemetrySessionId: string): BridgeTelemetryWorkerBootstrap {
	return {
		enabledScopes: ['web'],
		endpointUrl: 'agentstudio://telemetry/batch',
		telemetryCapability: 'telemetry-capability-0123456789abcd',
		telemetryCapabilityDigest: 'telemetry-capability-digest-01234567',
		telemetrySessionId,
		policy: {
			initialControlCredits: 2,
			initialSampleCredits: 2,
			compactSampleMaxEncodedBytes: 1_024,
			producerLossKeyCap: 16,
			producerPreReadyBufferMaxBytes: 4 * 1024,
			producerPreReadyBufferMaxSamples: 2,
			workerBufferMaxBytes: 8_192,
			workerBufferMaxSamples: 8,
			batchMaxBytes: 4_096,
			batchMaxSamples: 4,
			outboxMaxBytes: 8_192,
			outboxMaxCount: 2,
			maxRetryAttempts: 2,
			drainTimeoutMilliseconds: 1_000,
			minimumFlushIntervalMilliseconds: 0,
		},
	};
}

function makeProductBootstrapDetail(
	requestId: string,
	workerInstanceId: string,
	productCapability: unknown = new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
): object {
	return {
		requestId,
		bootstrap: {
			kind: 'productSession.bootstrap',
			paneSessionId: 'pane-session-1',
			policy: {
				...validProductSessionCorpus.bootstrap.policy,
				admissionRetryCount: validProductSessionCorpus.bootstrap.policy.admissionRetryCount,
				contentAcknowledgementDeadlineMilliseconds: 5_000,
				contentProgressDeadlineMilliseconds: 5_000,
				maximumContentBytes: BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
				maximumRequestBodyBytes: BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
				maximumMetadataFrameBytes: BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
				maximumQueuedStreamBytes: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
				maximumQueuedStreamFrames: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
				terminalFrameReserve: BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
				telemetryPreReadyBufferMaxBytes:
					validProductSessionCorpus.bootstrap.policy.telemetryPreReadyBufferMaxBytes,
				telemetryPreReadyBufferMaxSamples:
					validProductSessionCorpus.bootstrap.policy.telemetryPreReadyBufferMaxSamples,
				workerSettlementDeadlineMilliseconds:
					validProductSessionCorpus.bootstrap.policy.workerSettlementDeadlineMilliseconds,
			},
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerInstanceId,
		},
		productCapability,
	};
}

import { uuidv7 } from 'uuidv7';

import { bridgeProductIdentifierSchema } from '../core/comm-worker/bridge-product-contract-primitives.js';
import {
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_REQUEST_MEDIA_TYPE,
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE,
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE,
	BRIDGE_PRODUCT_DEV_HEALTH_ROUTE,
	decodeBridgeProductDevBootstrapDelivery,
	type BridgeProductDevBootstrapRequest,
	type BridgeProductDevNavigationIntent,
} from '../core/comm-worker/bridge-product-dev-bootstrap.js';

type BridgeAppDevProductSessionTarget = Pick<
	EventTarget,
	'addEventListener' | 'dispatchEvent' | 'removeEventListener'
>;

export interface BridgeAppDevProductSessionHost {
	readonly dispose: () => void;
}

export interface BridgeAppDevProductSessionHostProps {
	readonly fetchBootstrap?: typeof fetch;
	readonly fetchHealth?: typeof fetch;
	readonly navigationIntent: BridgeProductDevNavigationIntent;
	readonly onSessionInUse?: () => void;
	readonly reloadPage?: () => void;
	readonly target?: BridgeAppDevProductSessionTarget;
	readonly tabId?: string;
	readonly waitForHealthProbe?: (signal: AbortSignal) => Promise<void>;
}

type InitialBootstrapOutcome = 'failed' | 'pending' | 'succeeded';

class BridgeDevelopmentBootstrapTransportUnavailableError extends Error {}
class BridgeDevelopmentSessionInUseError extends Error {}

const bridgeDevelopmentBackendUnavailableMessage = 'Bridge development backend unavailable';
const bridgeDevelopmentTabIdentityStorageKey = 'bridge.product.dev.tabId';
const bridgeDevelopmentHealthProbeIntervalMilliseconds = 250;

export function installBridgeAppDevProductSessionHost(
	props: BridgeAppDevProductSessionHostProps,
): BridgeAppDevProductSessionHost {
	const target = props.target ?? document;
	const fetchBootstrap = props.fetchBootstrap ?? globalThis.fetch.bind(globalThis);
	const fetchHealth = props.fetchHealth ?? globalThis.fetch.bind(globalThis);
	const reloadPage = props.reloadPage ?? ((): void => globalThis.location.reload());
	const waitForHealthProbe = props.waitForHealthProbe ?? defaultHealthProbeWait;
	const tabId = props.tabId ?? readOrCreateDevelopmentTabId();
	let activeRequestController: AbortController | null = null;
	let healthProbeController: AbortController | null = null;
	let initialBootstrapOutcome: InitialBootstrapOutcome = 'pending';
	let isInstalled = true;
	let paneSessionId: string | null = null;
	let requestSequence = 0;
	const acknowledgedReadyRequestIds = new Set<string>();
	const pendingReadyRequestIds = new Set<string>();

	const acknowledgeReadyRequest = (requestId: string): void => {
		if (!isInstalled || acknowledgedReadyRequestIds.has(requestId)) return;
		acknowledgedReadyRequestIds.add(requestId);
		pendingReadyRequestIds.delete(requestId);
		target.dispatchEvent(
			new CustomEvent('__bridge_ready_ack', {
				detail:
					initialBootstrapOutcome === 'succeeded'
						? { jsonrpc: '2.0', id: requestId, result: null }
						: {
								jsonrpc: '2.0',
								id: requestId,
								error: {
									code: -32_000,
									message: bridgeDevelopmentBackendUnavailableMessage,
								},
							},
			}),
		);
	};

	const acknowledgePendingReadyRequestsIfResolved = (): void => {
		if (!isInstalled || initialBootstrapOutcome === 'pending') return;
		for (const requestId of pendingReadyRequestIds) {
			acknowledgeReadyRequest(requestId);
		}
	};

	const startHealthProbing = (): void => {
		if (!isInstalled || healthProbeController !== null) return;
		const controller = new AbortController();
		healthProbeController = controller;
		void probeUntilBridgeDevelopmentBackendIsHealthy({
			fetchHealth,
			reloadPage: (): void => {
				if (!isInstalled || healthProbeController !== controller) return;
				healthProbeController = null;
				reloadPage();
			},
			signal: controller.signal,
			waitForHealthProbe,
		});
	};

	const handleReadyRequest = (event: Event): void => {
		if (!isInstalled || !('detail' in event)) return;
		const requestId = readyRequestIdentifier(event.detail);
		if (requestId === null || acknowledgedReadyRequestIds.has(requestId)) return;
		pendingReadyRequestIds.add(requestId);
		acknowledgePendingReadyRequestsIfResolved();
	};

	const handleBootstrapRequest = (event: Event): void => {
		if (!isInstalled || !('detail' in event)) return;
		const request = productBootstrapRequest(event.detail);
		if (request === null) return;
		const bootstrapRequest = bridgeProductDevBootstrapRequest({
			navigationIntent: props.navigationIntent,
			paneSessionId,
			reason: request.reason,
			tabId,
		});
		if (bootstrapRequest === null) return;
		if (request.reason === 'initial') {
			initialBootstrapOutcome = 'pending';
			healthProbeController?.abort();
			healthProbeController = null;
		}
		requestSequence += 1;
		const issuedRequestSequence = requestSequence;
		activeRequestController?.abort();
		const requestController = new AbortController();
		activeRequestController = requestController;
		void fetchRegisteredBootstrap({
			fetchBootstrap,
			request: bootstrapRequest,
			signal: requestController.signal,
		})
			.then(
				(delivery): void => {
					if (!isInstalled || issuedRequestSequence !== requestSequence) {
						new Uint8Array(delivery.productCapability).fill(0);
						return;
					}
					paneSessionId = delivery.bootstrap.paneSessionId;
					target.dispatchEvent(
						new CustomEvent('__bridge_product_session_bootstrap', {
							detail: {
								bootstrap: delivery.bootstrap,
								productCapability: delivery.productCapability,
								requestId: request.requestId,
							},
						}),
					);
					if (request.reason === 'initial') {
						initialBootstrapOutcome = 'succeeded';
						acknowledgePendingReadyRequestsIfResolved();
					}
				},
				(error: unknown): void => {
					if (!isInstalled || issuedRequestSequence !== requestSequence) return;
					if (error instanceof BridgeDevelopmentSessionInUseError) {
						props.onSessionInUse?.();
						return;
					}
					if (request.reason === 'initial') {
						initialBootstrapOutcome = 'failed';
						acknowledgePendingReadyRequestsIfResolved();
					}
					if (error instanceof BridgeDevelopmentBootstrapTransportUnavailableError) {
						startHealthProbing();
					}
				},
			)
			.finally((): void => {
				if (activeRequestController === requestController) activeRequestController = null;
			});
	};

	target.addEventListener('__bridge_ready', handleReadyRequest);
	target.addEventListener('__bridge_product_session_bootstrap_request', handleBootstrapRequest);
	return {
		dispose: (): void => {
			if (!isInstalled) return;
			isInstalled = false;
			requestSequence += 1;
			activeRequestController?.abort();
			activeRequestController = null;
			healthProbeController?.abort();
			healthProbeController = null;
			target.removeEventListener('__bridge_ready', handleReadyRequest);
			target.removeEventListener(
				'__bridge_product_session_bootstrap_request',
				handleBootstrapRequest,
			);
		},
	};
}

async function probeUntilBridgeDevelopmentBackendIsHealthy(props: {
	readonly fetchHealth: typeof fetch;
	readonly reloadPage: () => void;
	readonly signal: AbortSignal;
	readonly waitForHealthProbe: (signal: AbortSignal) => Promise<void>;
}): Promise<void> {
	while (!props.signal.aborted) {
		// oxlint-disable-next-line no-await-in-loop -- Recovery probes must stay sequential so only one request can decide to reload.
		await props.waitForHealthProbe(props.signal);
		if (props.signal.aborted) return;
		try {
			// oxlint-disable-next-line no-await-in-loop -- A later probe starts only after this request has resolved or failed.
			const response = await props.fetchHealth(BRIDGE_PRODUCT_DEV_HEALTH_ROUTE, {
				cache: 'no-store',
				credentials: 'same-origin',
				method: 'GET',
				signal: props.signal,
			});
			// oxlint-disable-next-line no-await-in-loop -- Release this response before evaluating or scheduling another probe.
			await response.body?.cancel();
			if (response.status === 204) {
				props.reloadPage();
				return;
			}
		} catch {
			if (props.signal.aborted) return;
		}
	}
}

function defaultHealthProbeWait(signal: AbortSignal): Promise<void> {
	return new Promise<void>((resolve): void => {
		if (signal.aborted) {
			resolve();
			return;
		}
		const timeout = globalThis.setTimeout(
			resolve,
			bridgeDevelopmentHealthProbeIntervalMilliseconds,
		);
		signal.addEventListener(
			'abort',
			(): void => {
				globalThis.clearTimeout(timeout);
				resolve();
			},
			{ once: true },
		);
	});
}

function readyRequestIdentifier(detail: unknown): string | null {
	if (
		typeof detail !== 'object' ||
		detail === null ||
		!('requestId' in detail) ||
		typeof detail.requestId !== 'string' ||
		detail.requestId.length === 0
	) {
		return null;
	}
	return detail.requestId;
}

async function fetchRegisteredBootstrap(props: {
	readonly fetchBootstrap: typeof fetch;
	readonly request: BridgeProductDevBootstrapRequest;
	readonly signal: AbortSignal;
}): Promise<ReturnType<typeof decodeBridgeProductDevBootstrapDelivery>> {
	let response: Response;
	try {
		response = await props.fetchBootstrap(BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE, {
			body: JSON.stringify(props.request),
			cache: 'no-store',
			credentials: 'same-origin',
			headers: { 'Content-Type': BRIDGE_PRODUCT_DEV_BOOTSTRAP_REQUEST_MEDIA_TYPE },
			method: 'POST',
			signal: props.signal,
		});
	} catch {
		throw new BridgeDevelopmentBootstrapTransportUnavailableError(
			'Bridge product development backend is unavailable.',
		);
	}
	if (await isViteProxyUpstreamUnavailableResponse(response)) {
		throw new BridgeDevelopmentBootstrapTransportUnavailableError(
			'Bridge product development backend is unavailable.',
		);
	}
	if (response.status === 409) {
		await response.body?.cancel();
		throw new BridgeDevelopmentSessionInUseError('This dev server is open elsewhere.');
	}
	if (
		!response.ok ||
		response.headers.get('content-type') !== BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE
	) {
		throw new Error('Bridge product dev bootstrap request was rejected.');
	}
	let responseBody: ArrayBuffer;
	try {
		responseBody = await response.arrayBuffer();
	} catch {
		throw new BridgeDevelopmentBootstrapTransportUnavailableError(
			'Bridge product development backend is unavailable.',
		);
	}
	return decodeBridgeProductDevBootstrapDelivery(responseBody);
}

async function isViteProxyUpstreamUnavailableResponse(response: Response): Promise<boolean> {
	if (response.status !== 502 || response.headers.get('content-type') !== 'text/plain') {
		return false;
	}
	return (await response.arrayBuffer()).byteLength === 0;
}

function bridgeProductDevBootstrapRequest(props: {
	readonly navigationIntent: BridgeProductDevNavigationIntent;
	readonly paneSessionId: string | null;
	readonly reason: 'initial' | 'workerReplacement';
	readonly tabId: string;
}): BridgeProductDevBootstrapRequest | null {
	if (props.reason === 'initial') {
		return { navigationIntent: props.navigationIntent, reason: props.reason, tabId: props.tabId };
	}
	return props.paneSessionId === null
		? null
		: {
				navigationIntent: props.navigationIntent,
				paneSessionId: props.paneSessionId,
				reason: props.reason,
				tabId: props.tabId,
			};
}

function readOrCreateDevelopmentTabId(): string {
	const generatedId = uuidv7();
	try {
		const storedId = globalThis.sessionStorage?.getItem(bridgeDevelopmentTabIdentityStorageKey);
		if (
			storedId !== null &&
			storedId !== undefined &&
			bridgeProductIdentifierSchema.safeParse(storedId).success
		) {
			return storedId;
		}
		globalThis.sessionStorage?.setItem(bridgeDevelopmentTabIdentityStorageKey, generatedId);
	} catch {
		// A restricted dev browser can still bootstrap for this page lifetime.
	}
	return generatedId;
}

function productBootstrapRequest(detail: unknown): {
	readonly reason: BridgeProductDevBootstrapRequest['reason'];
	readonly requestId: string;
} | null {
	if (
		typeof detail !== 'object' ||
		detail === null ||
		!('requestId' in detail) ||
		!('reason' in detail) ||
		typeof detail.requestId !== 'string' ||
		detail.requestId.length === 0 ||
		(detail.reason !== 'initial' && detail.reason !== 'workerReplacement')
	) {
		return null;
	}
	return { reason: detail.reason, requestId: detail.requestId };
}

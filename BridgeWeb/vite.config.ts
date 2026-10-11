import { Buffer } from 'node:buffer';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import react from '@vitejs/plugin-react';
import { defineConfig, type Plugin, type ProxyOptions } from 'vite';

import { bridgeViteOptimizedDependencies } from './bridge-vite-optimized-dependencies.js';
import {
	createBridgeDevTelemetrySink,
	type BridgeDevTelemetrySink,
	type BridgeDevTelemetrySnapshot,
} from './scripts/dev-server/bridge-dev-telemetry.js';
import { bridgeDevelopmentInstallationReleaseRoute } from './scripts/dev-server/bridge-development-installation-release.ts';
import { reserveBridgeDevelopmentServerPort } from './scripts/dev-server/bridge-development-server-process.js';
import { createBridgeDevelopmentServerVitePlugin } from './scripts/dev-server/bridge-development-server-vite-plugin.js';
import {
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE,
	BRIDGE_PRODUCT_DEV_HEALTH_ROUTE,
} from './src/core/comm-worker/bridge-product-dev-bootstrap.js';
import {
	BRIDGE_PRODUCT_HTTP_COMMAND_ENDPOINT,
	BRIDGE_PRODUCT_HTTP_CONTENT_ENDPOINT,
	BRIDGE_PRODUCT_HTTP_STREAM_ENDPOINT,
} from './src/core/comm-worker/bridge-product-http-request-executor.js';

const bridgeWebPackageRoot = dirname(fileURLToPath(import.meta.url));
export default defineConfig(async () => {
	const bridgeProductDevBackendOrigin = await resolveBridgeProductDevBackendOrigin(process.env);
	const bridgeProductDevBackendIsSupervised = bridgeProductDevBackendShouldBeSupervised(
		process.env,
	);
	const bridgeWebViteCacheDirectory = resolveBridgeWebViteCacheDirectory(process.env);
	return {
		base: './',
		...(bridgeWebViteCacheDirectory === null ? {} : { cacheDir: bridgeWebViteCacheDirectory }),
		resolve: {
			alias: [{ find: '@', replacement: `${bridgeWebPackageRoot}/src` }],
		},
		optimizeDeps: {
			include: [...bridgeViteOptimizedDependencies],
		},
		plugins: [
			react(),
			{
				name: 'bridge-dev-telemetry',
				configureServer(server) {
					const telemetrySink = createBridgeDevTelemetrySink();
					server.middlewares.use('/__bridge-dev-telemetry/batch', (request, response) => {
						void handleBridgeDevTelemetryBatchRequest({
							request,
							response,
							telemetrySink,
						});
					});
					server.middlewares.use('/__bridge-dev-telemetry/status', (request, response) => {
						handleBridgeDevTelemetryStatusRequest({
							request,
							response,
							telemetrySink,
						});
					});
				},
			} satisfies Plugin,
			...(bridgeProductDevBackendIsSupervised
				? [
						createBridgeDevelopmentServerVitePlugin({
							backendOrigin: bridgeProductDevBackendOrigin,
							repoRootPath: dirname(bridgeWebPackageRoot),
						}),
					]
				: []),
		],
		server: {
			host: '127.0.0.1',
			proxy: bridgeProductDevProxyConfiguration(bridgeProductDevBackendOrigin),
		},
		build: {
			outDir: '../Sources/AgentStudio/Resources/BridgeWeb/app',
			emptyOutDir: true,
			sourcemap: false,
		},
	};
});

export function resolveBridgeWebViteCacheDirectory(
	env: Readonly<Record<string, string | undefined>>,
): string | null {
	const configuredCacheDirectory = env['BRIDGE_WEB_VITE_CACHE_DIR'];
	return configuredCacheDirectory === undefined || configuredCacheDirectory.length === 0
		? null
		: configuredCacheDirectory;
}

export function bridgeProductDevBackendShouldBeSupervised(
	env: Readonly<Record<string, string | undefined>>,
): boolean {
	return env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] === undefined;
}

const bridgeDevTelemetryMaxBodyBytes = 256 * 1024;
const bridgeDevTelemetryCapability = 'dev-telemetry-capability-0123456789abcdef';

async function handleBridgeDevTelemetryBatchRequest(props: {
	readonly request: IncomingMessage;
	readonly response: ServerResponse;
	readonly telemetrySink: BridgeDevTelemetrySink;
}): Promise<void> {
	if (props.request.method !== 'POST') {
		props.response.statusCode = 405;
		props.response.end('Method Not Allowed');
		return;
	}
	if (
		props.request.headers['x-agentstudio-bridge-telemetry-capability'] !==
		bridgeDevTelemetryCapability
	) {
		writeJsonResponse(props.response, 401, { error: 'unauthorized' });
		return;
	}
	try {
		const body = await readJsonRequestBody(props.request, bridgeDevTelemetryMaxBodyBytes);
		const admission = await props.telemetrySink.ingestWorkerBatch(body);
		writeJsonResponse(props.response, bridgeTelemetryAdmissionStatusCode(admission), admission);
	} catch (error: unknown) {
		writeJsonResponse(props.response, 400, {
			error: error instanceof Error ? error.message : 'invalid_telemetry_request',
			snapshot: props.telemetrySink.snapshot(),
		});
	}
}

function bridgeTelemetryAdmissionStatusCode(
	admission: Awaited<ReturnType<BridgeDevTelemetrySink['ingestWorkerBatch']>>,
): number {
	if (admission.type === 'accepted' || admission.type === 'accepted_with_loss') {
		return 202;
	}
	if (admission.type === 'duplicate') {
		return 200;
	}
	if (admission.reason === 'unavailable') {
		return 503;
	}
	return admission.reason === 'invalid_body' ? 400 : 409;
}

function handleBridgeDevTelemetryStatusRequest(props: {
	readonly request: IncomingMessage;
	readonly response: ServerResponse;
	readonly telemetrySink: BridgeDevTelemetrySink;
}): void {
	if (props.request.method !== 'GET') {
		props.response.statusCode = 405;
		props.response.end('Method Not Allowed');
		return;
	}
	writeJsonResponse(props.response, 200, props.telemetrySink.snapshot());
}

export async function resolveBridgeProductDevBackendOrigin(
	env: Readonly<Record<string, string | undefined>>,
	reservePort: () => Promise<number> = reserveBridgeDevelopmentServerPort,
): Promise<string> {
	const configuredOrigin = env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'];
	if (configuredOrigin === undefined) {
		return `http://127.0.0.1:${await reservePort()}`;
	}
	const origin = new URL(configuredOrigin);
	if (
		origin.protocol !== 'http:' ||
		!bridgeProductDevBackendHostnameIsLoopback(origin.hostname) ||
		origin.username !== '' ||
		origin.password !== '' ||
		origin.pathname !== '/' ||
		origin.search !== '' ||
		origin.hash !== ''
	) {
		throw new Error('BRIDGE_WEB_DEV_BACKEND_ORIGIN must be a loopback HTTP origin.');
	}
	return origin.origin;
}

export function bridgeProductDevProxyConfiguration(
	backendOrigin: string,
): Readonly<Record<string, ProxyOptions>> {
	const proxy: ProxyOptions = { target: backendOrigin };
	return {
		[BRIDGE_PRODUCT_DEV_HEALTH_ROUTE]: proxy,
		[BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE]: proxy,
		[bridgeDevelopmentInstallationReleaseRoute]: proxy,
		[BRIDGE_PRODUCT_HTTP_COMMAND_ENDPOINT]: proxy,
		[BRIDGE_PRODUCT_HTTP_STREAM_ENDPOINT]: {
			...proxy,
			configure(metadataProxy): void {
				metadataProxy.on('proxyReq', (upstreamRequest, _request, response): void => {
					const upstreamSocket = upstreamRequest.socket;
					const cancelAbandonedResponse = (): void => {
						if (!response.writableFinished && upstreamSocket?.destroyed === false) {
							// A FIN permits a response after request half-close. Browser abandonment
							// must instead cancel the idle Swift response before the proxy's destroy().
							upstreamSocket.resetAndDestroy();
						}
					};
					response.prependOnceListener('close', cancelAbandonedResponse);
					upstreamRequest.once('close', (): void => {
						response.off('close', cancelAbandonedResponse);
					});
				});
			},
		},
		[BRIDGE_PRODUCT_HTTP_CONTENT_ENDPOINT]: proxy,
	};
}

function bridgeProductDevBackendHostnameIsLoopback(hostname: string): boolean {
	return hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '[::1]';
}

async function readJsonRequestBody(request: IncomingMessage, maxBytes: number): Promise<unknown> {
	let byteCount = 0;
	const chunks: Buffer[] = [];
	for await (const chunk of request) {
		const buffer = typeof chunk === 'string' ? Buffer.from(chunk) : chunk;
		byteCount += buffer.byteLength;
		if (byteCount > maxBytes) {
			throw new Error('telemetry_request_too_large');
		}
		chunks.push(buffer);
	}
	try {
		const parsedJson: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'));
		return parsedJson;
	} catch {
		throw new Error('invalid_telemetry_json');
	}
}

function writeJsonResponse(
	response: ServerResponse,
	statusCode: number,
	body: BridgeDevTelemetrySnapshot | Readonly<Record<string, unknown>>,
): void {
	response.statusCode = statusCode;
	response.setHeader('Content-Type', 'application/json; charset=utf-8');
	response.end(JSON.stringify(body));
}

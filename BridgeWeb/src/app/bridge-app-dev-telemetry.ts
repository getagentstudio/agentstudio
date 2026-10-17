import { bridgePageConfigurationSchema } from '../bridge/bridge-page-configuration.js';
import type { BridgeTelemetryBootstrapHandshakeConfig } from '../foundation/telemetry/bridge-telemetry-bootstrap-config.js';
import pageConfigurationFixture from '../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };

export type BridgeAppDevTelemetryBootstrapConfig = BridgeTelemetryBootstrapHandshakeConfig;

export interface BridgeAppDevTelemetryHost {
	readonly dispose: () => void;
}

export interface InstallBridgeAppDevTelemetryHostProps {
	readonly createTelemetrySessionId?: () => string;
	readonly respondToHandshakeRequests?: boolean;
	readonly scenario: string;
	readonly target?: EventTarget;
}

const devTelemetryEndpoint = '/__bridge-dev-telemetry/batch';
const devTelemetryCapability = 'dev-telemetry-capability-0123456789abcdef';

export function createBridgeAppDevTelemetryBootstrapConfig(
	scenario: string,
	createTelemetrySessionId: () => string = createBridgeAppDevTelemetrySessionId,
): BridgeAppDevTelemetryBootstrapConfig {
	return {
		enabledScopes: ['web'],
		scenario,
		workerBootstrap: {
			enabledScopes: ['web'],
			endpointUrl: devTelemetryEndpoint,
			telemetryCapability: devTelemetryCapability,
			telemetryCapabilityDigest: 'dev-telemetry-capability-digest-0123456',
			telemetrySessionId: createTelemetrySessionId(),
			policy: {
				initialControlCredits: 4,
				initialSampleCredits: 128,
				compactSampleMaxEncodedBytes: 16 * 1024,
				producerLossKeyCap: 64,
				producerPreReadyBufferMaxBytes: 64 * 1024,
				producerPreReadyBufferMaxSamples: 128,
				workerBufferMaxBytes: 256 * 1024,
				workerBufferMaxSamples: 256,
				batchMaxBytes: 64 * 1024,
				batchMaxSamples: 128,
				outboxMaxBytes: 256 * 1024,
				outboxMaxCount: 4,
				maxRetryAttempts: 3,
				drainTimeoutMilliseconds: 5_000,
				minimumFlushIntervalMilliseconds: 250,
			},
		},
	};
}

export function installBridgeAppDevTelemetryHost(
	props: InstallBridgeAppDevTelemetryHostProps,
): BridgeAppDevTelemetryHost {
	const target = props.target ?? document;
	const pageConfiguration = bridgePageConfigurationSchema.parse(pageConfigurationFixture);
	const telemetryConfig = createBridgeAppDevTelemetryBootstrapConfig(
		props.scenario,
		props.createTelemetrySessionId,
	);
	const handleHandshakeRequest = (): void => {
		target.dispatchEvent(
			new CustomEvent('__bridge_handshake', {
				detail: { telemetryConfig, pageConfiguration },
			}),
		);
	};
	if (props.respondToHandshakeRequests ?? true) {
		target.addEventListener('__bridge_handshake_request', handleHandshakeRequest);
	}
	return {
		dispose: (): void => {
			if (props.respondToHandshakeRequests ?? true) {
				target.removeEventListener('__bridge_handshake_request', handleHandshakeRequest);
			}
		},
	};
}

function createBridgeAppDevTelemetrySessionId(): string {
	return `dev-telemetry-${crypto.randomUUID()}`;
}

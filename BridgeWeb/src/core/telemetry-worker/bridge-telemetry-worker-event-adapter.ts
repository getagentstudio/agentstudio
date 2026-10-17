// oxlint-disable unicorn/require-post-message-target-origin -- MessagePort postMessage has no target origin.
import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import type { BridgeTelemetryScope } from '../../foundation/telemetry/bridge-telemetry-scope.js';
import type {
	BridgeTelemetryCompactSample,
	BridgeTelemetryLossReason,
} from './bridge-telemetry-worker-contracts.js';
export type BridgeTelemetryEventCompactSample = Extract<
	BridgeTelemetryCompactSample,
	{ readonly type: 'event.required' | 'event.optional' }
>;
import {
	createBridgeTelemetryWorkerProducer,
	type BridgeTelemetryWorkerProducer,
} from './bridge-telemetry-worker-producer.js';

export interface BridgeTelemetryWorkerEventProducer {
	readonly isEnabled: (scope: BridgeTelemetryScope) => boolean;
	readonly record: (sample: BridgeTelemetrySample) => void;
	readonly recordCompact: (sample: BridgeTelemetryEventCompactSample) => void;
	readonly recordPriorLoss: (input: {
		readonly requiredCount: number;
		readonly optionalCount: number;
		readonly reason: BridgeTelemetryLossReason;
	}) => void;
	readonly close: () => void;
}

export interface CreateBridgeTelemetryWorkerEventProducerProps {
	readonly enabledScopes: ReadonlySet<BridgeTelemetryScope>;
	readonly now?: () => number;
	readonly port: MessagePort;
	readonly preReadyRequiredSampleCapacity: number;
	readonly preReadyRequiredSampleMaxEncodedBytes: number;
}

export function createBridgeTelemetryWorkerEventProducer(
	props: CreateBridgeTelemetryWorkerEventProducerProps,
): BridgeTelemetryWorkerEventProducer {
	const now = props.now ?? (() => performance.timeOrigin + performance.now());
	const producer = createBridgeTelemetryWorkerProducer({
		initialSampleCredits: 0,
		initialControlCredits: 0,
		preReadyRequiredSampleCapacity: props.preReadyRequiredSampleCapacity,
		preReadyRequiredSampleMaxEncodedBytes: props.preReadyRequiredSampleMaxEncodedBytes,
		send: (message): void => props.port.postMessage(message),
	});
	installCreditListener(props.port, producer);
	return {
		isEnabled: (scope): boolean => props.enabledScopes.has(scope),
		record: (sample): void => {
			if (!props.enabledScopes.has(sample.scope)) {
				return;
			}
			producer.record(bridgeTelemetryCompactSampleForEvent(sample, now()));
		},
		recordCompact: (sample): void => {
			if (props.enabledScopes.has(sample.sample.scope)) producer.record(sample);
		},
		recordPriorLoss: (input): void => producer.recordPriorLoss(input),
		close: (): void => {
			producer.close();
			props.port.close();
		},
	};
}

export function bridgeTelemetryCompactSampleForEvent(
	sample: BridgeTelemetrySample,
	timestampMilliseconds: number,
): BridgeTelemetryEventCompactSample {
	const priority = sample.stringAttributes['agentstudio.bridge.priority'];
	return {
		type: priority === 'best_effort' ? 'event.optional' : 'event.required',
		timestampMilliseconds,
		sample,
	};
}

function installCreditListener(port: MessagePort, producer: BridgeTelemetryWorkerProducer): void {
	port.addEventListener('message', (event: MessageEvent<unknown>): void => {
		producer.acceptWorkerCommand(event.data);
	});
	port.start();
}

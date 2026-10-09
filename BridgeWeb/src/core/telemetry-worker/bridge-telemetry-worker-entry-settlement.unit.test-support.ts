import type { BridgeTelemetryBootstrapConfig } from '../../foundation/telemetry/bridge-telemetry-bootstrap-config.js';
// oxlint-disable unicorn/require-post-message-target-origin -- MessagePort.postMessage has no target origin.
import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import {
	createBridgeTelemetryRecorderFromClient,
	type BridgeTelemetryRecorder,
} from '../../foundation/telemetry/bridge-telemetry-recorder.js';
import type { BridgeTelemetryScope } from '../../foundation/telemetry/bridge-telemetry-scope.js';
import type {
	BridgeTelemetryWorkerBatchRequest,
	BridgeTelemetryWorkerProducerMessage,
} from './bridge-telemetry-worker-contracts.js';
import {
	createBridgeTelemetryWorkerPortHost,
	type BridgeTelemetryWorkerPortHost,
} from './bridge-telemetry-worker-entry.js';
import {
	bridgeTelemetryCompactSampleForEvent,
	createBridgeTelemetryWorkerEventProducer,
} from './bridge-telemetry-worker-event-adapter.js';
import { createBridgeTelemetryWorkerProducer } from './bridge-telemetry-worker-producer.js';
import { acceptedTransport, makeBootstrap } from './bridge-telemetry-worker.unit.test-support.js';

interface ProducerSettlementGate {
	readonly held: Promise<void>;
	readonly port: MessagePort;
	readonly release: () => void;
}

interface SettlementSkewHarness {
	readonly capturedBatches: BridgeTelemetryWorkerBatchRequest[];
	readonly commChannel: MessageChannel;
	readonly commSettlementGate: ProducerSettlementGate;
	readonly host: BridgeTelemetryWorkerPortHost;
	readonly mainChannel: MessageChannel;
	readonly mainProducerMessages: BridgeTelemetryWorkerProducerMessage[];
	readonly mainWorkerCommands: unknown[];
	readonly mainRecorder: BridgeTelemetryRecorder;
}

export async function createSettlementSkewHarness(): Promise<SettlementSkewHarness> {
	const bootstrap = makeBootstrap();
	const mainChannel = new MessageChannel();
	const commChannel = new MessageChannel();
	const commSettlementGate = gateNextProducerSettlement(commChannel.port1);
	const capturedBatches: BridgeTelemetryWorkerBatchRequest[] = [];
	const host = createBridgeTelemetryWorkerPortHost({
		bootstrap,
		transport: acceptedTransport(capturedBatches),
		mainPort: mainChannel.port1,
		commPort: commSettlementGate.port,
		scheduleFlush: (): void => {},
	});
	const producerStates = host.runtime.snapshot().producers;
	const mainGeneration = producerStates.main?.generation;
	const commGeneration = producerStates.comm?.generation;
	if (
		mainGeneration === null ||
		mainGeneration === undefined ||
		commGeneration === null ||
		commGeneration === undefined
	) {
		throw new Error('Settlement skew test requires both producer installations.');
	}

	const mainProducerMessages: BridgeTelemetryWorkerProducerMessage[] = [];
	const mainWorkerCommands: unknown[] = [];
	const mainProducer = createBridgeTelemetryWorkerProducer({
		initialSampleCredits: 0,
		initialControlCredits: 0,
		preReadyRequiredSampleCapacity: bootstrap.policy.producerPreReadyBufferMaxSamples,
		preReadyRequiredSampleMaxEncodedBytes: bootstrap.policy.producerPreReadyBufferMaxBytes,
		send: (message): void => {
			mainProducerMessages.push(message);
			mainChannel.port2.postMessage(message);
		},
	});
	mainChannel.port2.addEventListener('message', (event: MessageEvent<unknown>): void => {
		mainWorkerCommands.push(event.data);
		mainProducer.acceptWorkerCommand(event.data);
	});
	mainChannel.port2.start();
	const mainRecorderConfig: BridgeTelemetryBootstrapConfig = {
		enabledScopes: new Set<BridgeTelemetryScope>(['web']),
		scenario: 'telemetry_settlement_test',
	};
	const mainRecorder = createBridgeTelemetryRecorderFromClient(
		mainRecorderConfig,
		{
			record: (sample): void => {
				mainProducer.record(bridgeTelemetryCompactSampleForEvent(sample, 42));
			},
			flush: (): boolean => mainProducer.flushLossSummary(),
		},
		(): number => 42,
	);

	createBridgeTelemetryWorkerEventProducer({
		enabledScopes: new Set<BridgeTelemetryScope>(['web']),
		now: (): number => 42,
		port: commChannel.port2,
		preReadyRequiredSampleCapacity: bootstrap.policy.producerPreReadyBufferMaxSamples,
		preReadyRequiredSampleMaxEncodedBytes: bootstrap.policy.producerPreReadyBufferMaxBytes,
	});
	const mainReady = nextPortMessageOfType(mainChannel.port2, 'producer.ready');
	const commReady = nextPortMessageOfType(commChannel.port2, 'producer.ready');
	const readyCommand = (generation: number): object => ({
		type: 'producer.ready',
		generation,
		initialSampleCredits: bootstrap.policy.initialSampleCredits,
		initialControlCredits: bootstrap.policy.initialControlCredits,
	});
	mainChannel.port1.postMessage(readyCommand(mainGeneration));
	commSettlementGate.port.postMessage(readyCommand(commGeneration));
	await Promise.all([mainReady, commReady]);

	return {
		capturedBatches,
		commChannel,
		commSettlementGate,
		host,
		mainChannel,
		mainProducerMessages,
		mainWorkerCommands,
		mainRecorder,
	};
}

export function gateNextProducerSettlement(port: MessagePort): ProducerSettlementGate {
	let shouldHoldNextSettlement = true;
	let heldMessage: { readonly value: unknown } | null = null;
	let resolveHeld!: () => void;
	const held = new Promise<void>((resolve): void => {
		resolveHeld = resolve;
	});
	const gatedPort = new Proxy(port, {
		get(target, property): unknown {
			if (property === 'postMessage') {
				return (message: unknown): void => {
					if (shouldHoldNextSettlement && isMessageOfType(message, 'producer.settlement.request')) {
						shouldHoldNextSettlement = false;
						heldMessage = { value: message };
						resolveHeld();
						return;
					}
					target.postMessage(message);
				};
			}
			const value: unknown = Reflect.get(target, property, target);
			return typeof value === 'function' ? value.bind(target) : value;
		},
	});
	return {
		held,
		port: gatedPort,
		release: (): void => {
			if (heldMessage === null) return;
			const message = heldMessage.value;
			heldMessage = null;
			port.postMessage(message);
		},
	};
}

export function nextPortMessageOfType(port: MessagePort, type: string): Promise<unknown> {
	return nextPortMessagesOfType(port, type, 1).then(([message]) => message);
}

export function nextPortMessagesOfType(
	port: MessagePort,
	type: string,
	count: number,
): Promise<readonly unknown[]> {
	return new Promise((resolve): void => {
		const messages: unknown[] = [];
		const listener = (event: MessageEvent<unknown>): void => {
			if (!isMessageOfType(event.data, type)) return;
			messages.push(event.data);
			if (messages.length !== count) return;
			port.removeEventListener('message', listener);
			resolve(messages);
		};
		port.addEventListener('message', listener);
		port.start();
	});
}

export function makeRequiredMainRecorderEvent(): BridgeTelemetrySample {
	return {
		scope: 'web',
		name: 'performance.bridge.web.selected_content_painted',
		durationMilliseconds: 1,
		traceContext: null,
		stringAttributes: { 'agentstudio.bridge.priority': 'hot' },
		numericAttributes: {},
		booleanAttributes: {},
	};
}

function isMessageOfType(value: unknown, type: string): boolean {
	return typeof value === 'object' && value !== null && 'type' in value && value.type === type;
}

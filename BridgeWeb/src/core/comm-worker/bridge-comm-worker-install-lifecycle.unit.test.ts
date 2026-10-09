import { afterEach, describe, expect, test, vi } from 'vitest';

import {
	bootstrapBridgeCommWorkerEntry,
	type BridgeCommWorkerEntryDependencies,
	type BridgeCommWorkerInstalledProductSession,
	type BridgeCommWorkerPort,
} from './bridge-comm-worker-entry.js';
import { encodeBridgeWorkerSelectCommand } from './bridge-comm-worker-protocol.js';
import { executeAgentStudioBridgeProductRequest } from './bridge-product-agent-studio-request-executor.js';
import {
	BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
	BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
	BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from './bridge-product-contract-primitives.js';
import { bridgeProductMetadataApplicationRegistry } from './bridge-product-metadata-application-registry.js';
import { BridgeProductControlMux } from './bridge-product-session-authority.js';
import {
	type BridgePaneCommWorkerInstall,
	bridgePaneCommWorkerInstallSchema,
} from './bridge-product-session-contracts.js';
import { createBridgeProductTransport } from './bridge-product-transport.js';
import type {
	BridgeCommWorkerBootstrapRequest,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

interface PostedGlobalWorkerMessage {
	readonly message: BridgeWorkerServerToMainMessage;
	readonly transferList: readonly Transferable[] | undefined;
}

type BridgeCommWorkerProductSessionInstallInput = Parameters<
	BridgeCommWorkerEntryDependencies['installProductSession']
>[0];

function makeTestInstalledProductSession(
	input: BridgeCommWorkerProductSessionInstallInput,
	open: Promise<void> = Promise.resolve(),
): BridgeCommWorkerInstalledProductSession {
	const authority = {
		bootstrap: input.bootstrap,
		capabilityHeader: 'test-capability',
		open,
	};
	const controlMux = new BridgeProductControlMux({
		authority,
		executeProductRequest: executeAgentStudioBridgeProductRequest,
	});
	return {
		open,
		productTransport: createBridgeProductTransport({
			authority,
			controlMux,
			executeProductRequest: executeAgentStudioBridgeProductRequest,
			metadataApplicationRegistry: bridgeProductMetadataApplicationRegistry,
		}),
	};
}

function makeTestEntryDependencies(): BridgeCommWorkerEntryDependencies {
	return {
		installProductSession: (input): BridgeCommWorkerInstalledProductSession =>
			makeTestInstalledProductSession(input),
	};
}

describe('Bridge comm worker one-shot install lifecycle', () => {
	afterEach((): void => {
		vi.restoreAllMocks();
	});

	test('accepts one typed install and binds the runtime only to its transferred port', () => {
		const globalScope = createRecordingBridgeCommWorkerGlobalScope();
		const productChannel = new MessageChannel();
		const addEventListenerSpy = vi.spyOn(productChannel.port1, 'addEventListener');
		const startSpy = vi.spyOn(productChannel.port1, 'start');
		bootstrapBridgeCommWorkerEntry(globalScope.port, makeTestEntryDependencies());

		globalScope.dispatch(makePaneWorkerInstall(productChannel.port1));

		expect(globalScope.postedMessages).toEqual([]);
		expect(addEventListenerSpy).toHaveBeenCalledWith('message', expect.any(Function));
		expect(startSpy).toHaveBeenCalledOnce();

		productChannel.port1.close();
		productChannel.port2.close();
	});

	test('rejects a duplicate install without attaching the replacement port', () => {
		const globalScope = createRecordingBridgeCommWorkerGlobalScope();
		const acceptedChannel = new MessageChannel();
		const duplicateChannel = new MessageChannel();
		const acceptedPortListenerSpy = vi.spyOn(acceptedChannel.port1, 'addEventListener');
		const duplicatePortListenerSpy = vi.spyOn(duplicateChannel.port1, 'addEventListener');
		bootstrapBridgeCommWorkerEntry(globalScope.port, makeTestEntryDependencies());
		globalScope.dispatch(makePaneWorkerInstall(acceptedChannel.port1));
		globalScope.postedMessages.splice(0, globalScope.postedMessages.length);

		globalScope.dispatch(makePaneWorkerInstall(duplicateChannel.port1));

		expect(acceptedPortListenerSpy).toHaveBeenCalledOnce();
		expect(duplicatePortListenerSpy).not.toHaveBeenCalled();
		expect(globalScope.postedMessages).toHaveLength(1);
		expect(globalScope.postedMessages[0]?.message).toMatchObject({
			kind: 'health',
			status: 'degraded',
			message: expect.stringMatching(/already installed/u),
		});

		acceptedChannel.port1.close();
		acceptedChannel.port2.close();
		duplicateChannel.port1.close();
		duplicateChannel.port2.close();
	});

	test('rejects forged product ports without the full MessagePort receive contract', () => {
		const productChannel = new MessageChannel();
		const install = makePaneWorkerInstall(productChannel.port1);
		const forgedPorts = [
			{
				close: (): void => {},
				postMessage: (): void => {},
				start: (): void => {},
			},
			{
				addEventListener: (): void => {},
				close: (): void => {},
				postMessage: (): void => {},
			},
		];

		for (const forgedPort of forgedPorts) {
			expect(
				bridgePaneCommWorkerInstallSchema.safeParse({
					...install,
					productPort: forgedPort,
				}).success,
			).toBe(false);
		}

		productChannel.port1.close();
		productChannel.port2.close();
	});

	test('hands native bootstrap identity and capability to the product-session install seam', () => {
		const globalScope = createRecordingBridgeCommWorkerGlobalScope();
		const productChannel = new MessageChannel();
		const installProductSession = vi.fn(
			(
				input: BridgeCommWorkerProductSessionInstallInput,
			): BridgeCommWorkerInstalledProductSession => makeTestInstalledProductSession(input),
		);
		bootstrapBridgeCommWorkerEntry(globalScope.port, { installProductSession });
		const install = makePaneWorkerInstall(productChannel.port1);

		globalScope.dispatch(install);

		expect(installProductSession).toHaveBeenCalledOnce();
		expect(installProductSession).toHaveBeenCalledWith({
			bootstrap: install.bootstrap,
			productCapability: install.productCapability,
			publishSessionSuspect: expect.any(Function),
			publishViewRecoveryStatus: expect.any(Function),
		});
		expect(install.productCapability.byteLength).toBe(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH);

		productChannel.port1.close();
		productChannel.port2.close();
	});

	test('does not publish runtime ready before the product session open is accepted', async () => {
		const globalScope = createRecordingBridgeCommWorkerGlobalScope();
		const productChannel = new MessageChannel();
		const productPortPostSpy = vi.spyOn(productChannel.port1, 'postMessage');
		const addEventListenerSpy = vi.spyOn(productChannel.port1, 'addEventListener');
		let acceptProductSessionOpen: () => void = (): void => {};
		const productSessionOpen = new Promise<void>((resolve): void => {
			acceptProductSessionOpen = resolve;
		});
		bootstrapBridgeCommWorkerEntry(globalScope.port, {
			installProductSession: (input): BridgeCommWorkerInstalledProductSession =>
				makeTestInstalledProductSession(input, productSessionOpen),
		});
		globalScope.dispatch(makePaneWorkerInstall(productChannel.port1));
		const runtimeBootstrap = makeRuntimeBootstrapRequest();

		dispatchInstalledPortMessage(addEventListenerSpy.mock.calls, runtimeBootstrap);
		await flushMicrotasks();

		expect(productPortPostSpy).not.toHaveBeenCalledWith(
			expect.objectContaining({
				kind: 'health',
				requestId: runtimeBootstrap.requestId,
				status: 'ready',
			}),
		);
		acceptProductSessionOpen();
		await flushMicrotasks();
		expect(productPortPostSpy).toHaveBeenCalledWith(
			expect.objectContaining({
				kind: 'health',
				requestId: runtimeBootstrap.requestId,
				status: 'ready',
			}),
		);

		productChannel.port1.close();
		productChannel.port2.close();
	});

	test('rejects global ordinary commands and handles them only on the installed port', async () => {
		const globalScope = createRecordingBridgeCommWorkerGlobalScope();
		const productChannel = new MessageChannel();
		const productPortPostSpy = vi.spyOn(productChannel.port1, 'postMessage');
		const addEventListenerSpy = vi.spyOn(productChannel.port1, 'addEventListener');
		bootstrapBridgeCommWorkerEntry(globalScope.port, {
			installProductSession: (input): BridgeCommWorkerInstalledProductSession =>
				makeTestInstalledProductSession(input),
		});
		globalScope.dispatch(makePaneWorkerInstall(productChannel.port1));
		globalScope.postedMessages.splice(0, globalScope.postedMessages.length);
		const command = encodeBridgeWorkerSelectCommand({
			requestId: 'installed-port-command-1',
			epoch: 1,
			selectedItemId: 'item-1',
			selectedSource: 'user',
			surface: 'review',
		});

		globalScope.dispatch(command);

		expect(globalScope.postedMessages).toHaveLength(1);
		expect(globalScope.postedMessages[0]?.message).toMatchObject({
			kind: 'health',
			requestId: command.requestId,
			status: 'degraded',
			message: expect.stringMatching(/installed port/u),
		});

		const runtimeBootstrap = makeRuntimeBootstrapRequest();
		dispatchInstalledPortMessage(addEventListenerSpy.mock.calls, runtimeBootstrap);
		await flushMicrotasks();
		expect(productPortPostSpy.mock.calls.map(([message]) => message)).toContainEqual({
			wireVersion: 1,
			direction: 'serverWorkerToMain',
			kind: 'health',
			requestId: runtimeBootstrap.requestId,
			status: 'ready',
			transferDescriptors: [],
		});
		productPortPostSpy.mockClear();

		dispatchInstalledPortMessage(addEventListenerSpy.mock.calls, command);
		const commandReplies = productPortPostSpy.mock.calls.map(([message]) => message);
		expect(commandReplies).toContainEqual(
			expect.objectContaining({
				kind: 'slicePatch',
				epoch: command.epoch,
				patches: expect.arrayContaining([
					expect.objectContaining({
						operation: 'upsert',
						slice: 'selection',
						payload: { selectedItemId: command.selectedItemId },
					}),
				]),
			}),
		);
		expect(commandReplies).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: command.requestId,
				status: 'ready',
			}),
		);
		expect(commandReplies).not.toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: command.requestId,
				status: 'degraded',
			}),
		);

		productChannel.port1.close();
		productChannel.port2.close();
	});
});

function createRecordingBridgeCommWorkerGlobalScope(): {
	readonly dispatch: (data: unknown) => void;
	readonly port: BridgeCommWorkerPort;
	readonly postedMessages: PostedGlobalWorkerMessage[];
} {
	const postedMessages: PostedGlobalWorkerMessage[] = [];
	const eventTarget = new EventTarget();
	return {
		dispatch: (data: unknown): void => {
			eventTarget.dispatchEvent(new MessageEvent('message', { data }));
		},
		port: {
			postMessage: (
				message: BridgeWorkerServerToMainMessage,
				transferList?: Transferable[],
			): void => {
				postedMessages.push({ message, transferList });
			},
			addEventListener: (
				type: 'message',
				listener: (event: MessageEvent<unknown>) => void,
			): void => {
				expect(type).toBe('message');
				eventTarget.addEventListener(type, (event: Event): void => {
					if (event instanceof MessageEvent) {
						listener(event);
					}
				});
			},
		},
		postedMessages,
	};
}

function makePaneWorkerInstall(productPort: MessagePort): BridgePaneCommWorkerInstall {
	return bridgePaneCommWorkerInstallSchema.parse({
		bootstrap: {
			kind: 'productSession.bootstrap',
			paneSessionId: 'pane-session-1',
			policy: {
				maximumContentBytes: BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
				maximumRequestBodyBytes: BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
				maximumMetadataFrameBytes: BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
				maximumQueuedStreamBytes: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
				admissionRetryCount: 2,
				contentAcknowledgementDeadlineMilliseconds: 5_000,
				contentProgressDeadlineMilliseconds: 5_000,
				viewBatchProgressDeadlineMilliseconds: 5_000,
				streamKeepaliveIntervalMilliseconds: 350,
				telemetryPreReadyBufferMaxBytes: 64 * 1024,
				telemetryPreReadyBufferMaxSamples: 128,
				workerSettlementDeadlineMilliseconds: 5_000,
				viewAcknowledgementDeadlineMilliseconds: 4_000,
				viewCreditBytes: 524_288,
				viewCreditParts: 8,
				viewMaximumConsecutiveResnapshots: 3,
				viewMaximumDirtyKeys: 4_096,
				maximumQueuedStreamFrames: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
				terminalFrameReserve: BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
			},
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerInstanceId: 'worker-instance-1',
		},
		kind: 'bridgePaneCommWorker.install',
		productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
		productPort,
	});
}

function makeRuntimeBootstrapRequest(): BridgeCommWorkerBootstrapRequest {
	return {
		schemaVersion: 1,
		method: 'bridgeCommWorker.bootstrap',
		requestId: 'installed-port-runtime-bootstrap-1',
		runtime: {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 400,
			},
		},
	};
}

function dispatchInstalledPortMessage(
	listenerCalls: readonly (readonly [string, EventListenerOrEventListenerObject, ...unknown[]])[],
	data: unknown,
): void {
	const listeners = listenerCalls
		.filter(([eventType]) => eventType === 'message')
		.map(([, listener]) => listener);
	if (listeners.length === 0) {
		throw new Error('Expected the comm worker runtime to listen on the installed MessagePort.');
	}
	for (const listener of listeners) {
		const event = new MessageEvent('message', { data });
		if (typeof listener === 'function') {
			listener(event);
		} else {
			listener.handleEvent(event);
		}
	}
}

async function flushMicrotasks(): Promise<void> {
	await Promise.resolve();
	await Promise.resolve();
	await Promise.resolve();
}

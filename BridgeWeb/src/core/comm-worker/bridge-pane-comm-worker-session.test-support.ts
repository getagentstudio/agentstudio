import { expect } from 'vitest';

import { bridgeWorkerPierreRenderPolicy } from '../demand/bridge-content-demand-policy.js';
import {
	encodeBridgeWorkerActiveViewerModeUpdateCommand,
	encodeBridgeWorkerSelectCommand,
} from './bridge-comm-worker-protocol.js';
import type { BridgePaneCommWorkerNativeBootstrap } from './bridge-pane-comm-worker-session.js';
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
import { bridgePaneCommWorkerInstallSchema } from './bridge-product-session-contracts.js';
import {
	bridgeWorkerServerToMainMessageSchema,
	type BridgeCommWorkerBootstrapRequest,
	type BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

export interface RecordedGlobalWorkerPost {
	readonly message: unknown;
	readonly transferredCapability: boolean;
	readonly transferredPort: boolean;
	readonly transferListLength: number;
}

export class RecordingPaneCommWorker extends EventTarget implements Worker {
	onmessage: ((this: Worker, event: MessageEvent) => void) | null = null;
	onmessageerror: ((this: Worker, event: MessageEvent) => void) | null = null;
	onerror: ((this: AbstractWorker, event: ErrorEvent) => void) | null = null;
	readonly globalPosts: RecordedGlobalWorkerPost[] = [];
	terminateCount = 0;

	override addEventListener<KEventName extends keyof WorkerEventMap>(
		type: KEventName,
		listener: (this: Worker, event: WorkerEventMap[KEventName]) => void,
		options?: boolean | AddEventListenerOptions,
	): void;
	override addEventListener(
		type: string,
		listener: EventListenerOrEventListenerObject | null,
		options?: boolean | AddEventListenerOptions,
	): void;
	override addEventListener(
		type: string,
		listener: EventListenerOrEventListenerObject | null,
		options?: boolean | AddEventListenerOptions,
	): void {
		super.addEventListener(type, listener, options);
	}

	override removeEventListener<KEventName extends keyof WorkerEventMap>(
		type: KEventName,
		listener: (this: Worker, event: WorkerEventMap[KEventName]) => void,
		options?: boolean | EventListenerOptions,
	): void;
	override removeEventListener(
		type: string,
		listener: EventListenerOrEventListenerObject | null,
		options?: boolean | EventListenerOptions,
	): void;
	override removeEventListener(
		type: string,
		listener: EventListenerOrEventListenerObject | null,
		options?: boolean | EventListenerOptions,
	): void {
		super.removeEventListener(type, listener, options);
	}

	postMessage(message: unknown, transferList: Transferable[]): void;
	postMessage(message: unknown, options?: StructuredSerializeOptions): void;
	postMessage(
		message: unknown,
		transferListOrOptions: Transferable[] | StructuredSerializeOptions = [],
	): void {
		const transferList = Array.isArray(transferListOrOptions)
			? transferListOrOptions
			: (transferListOrOptions.transfer ?? []);
		const parsedInstall = bridgePaneCommWorkerInstallSchema.safeParse(message);
		const transferredCapability =
			parsedInstall.success && transferList.includes(parsedInstall.data.productCapability);
		const transferredPort =
			parsedInstall.success && transferList.includes(parsedInstall.data.productPort);
		const clonedMessage = structuredClone(message, { transfer: transferList });
		this.globalPosts.push({
			message: clonedMessage,
			transferredCapability,
			transferredPort,
			transferListLength: transferList.length,
		});
	}

	terminate(): void {
		this.terminateCount += 1;
	}
}

export class MessagePortRecorder {
	readonly #messages: unknown[] = [];
	readonly #port: MessagePort;
	readonly #waiters: Array<{
		readonly count: number;
		readonly resolve: (messages: readonly unknown[]) => void;
	}> = [];

	constructor(port: MessagePort) {
		this.#port = port;
		port.addEventListener('message', (event: MessageEvent<unknown>): void => {
			this.#messages.push(event.data);
			this.#resolveWaiters();
		});
		port.start();
	}

	waitForCount(count: number): Promise<readonly unknown[]> {
		if (this.#messages.length >= count) {
			return Promise.resolve([...this.#messages]);
		}
		return new Promise((resolve) => {
			this.#waiters.push({ count, resolve });
		});
	}

	close(): void {
		this.#port.close();
	}

	#resolveWaiters(): void {
		for (let index = this.#waiters.length - 1; index >= 0; index -= 1) {
			const waiter = this.#waiters[index];
			if (waiter !== undefined && this.#messages.length >= waiter.count) {
				this.#waiters.splice(index, 1);
				waiter.resolve([...this.#messages]);
			}
		}
	}
}

export class RecordingPaneCommWorkerClient {
	readonly messages: BridgeWorkerServerToMainMessage[] = [];
	readonly #waiters: Array<{
		readonly count: number;
		readonly resolve: (messages: readonly BridgeWorkerServerToMainMessage[]) => void;
	}> = [];

	readonly publish = (messages: readonly BridgeWorkerServerToMainMessage[]): void => {
		this.messages.push(...messages);
		this.#resolveWaiters();
	};

	waitForCount(count: number): Promise<readonly BridgeWorkerServerToMainMessage[]> {
		if (this.messages.length >= count) {
			return Promise.resolve([...this.messages]);
		}
		return new Promise((resolve) => {
			this.#waiters.push({ count, resolve });
		});
	}

	clear(): void {
		this.messages.splice(0, this.messages.length);
	}

	#resolveWaiters(): void {
		for (let index = this.#waiters.length - 1; index >= 0; index -= 1) {
			const waiter = this.#waiters[index];
			if (waiter !== undefined && this.messages.length >= waiter.count) {
				this.#waiters.splice(index, 1);
				waiter.resolve([...this.messages]);
			}
		}
	}
}

export function makeNativeBootstrap(
	workerInstanceId = 'worker-instance-1',
): BridgePaneCommWorkerNativeBootstrap {
	return {
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
			workerInstanceId,
		},
		productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
	};
}

export function makeRuntimeBootstrapRequest(requestId: string): BridgeCommWorkerBootstrapRequest {
	return {
		schemaVersion: 1,
		method: 'bridgeCommWorker.bootstrap',
		requestId,
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

export function expectPaneSurfacePolicies(): ReturnType<typeof expect.objectContaining> {
	return expect.objectContaining({
		fileView: {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: bridgeWorkerPierreRenderPolicy.fileViewSelectedRenderBudget,
		},
		review: {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: bridgeWorkerPierreRenderPolicy.reviewInteractiveRenderBudget,
		},
	});
}

export function makeSelectCommand(
	requestId: string,
	epoch: number,
	selectedItemId: string,
	surface: 'fileView' | 'review',
): ReturnType<typeof encodeBridgeWorkerSelectCommand> {
	return encodeBridgeWorkerSelectCommand({
		requestId,
		epoch,
		surface,
		selectedItemId,
		selectedSource: 'user',
	});
}

export function makeActiveViewerModeUpdateCommand(
	requestId: string,
	epoch: number,
): ReturnType<typeof encodeBridgeWorkerActiveViewerModeUpdateCommand> {
	return encodeBridgeWorkerActiveViewerModeUpdateCommand({
		epoch,
		requestId,
		update: {
			activeSource: null,
			mode: 'file',
			nativeSelectionRequestId: null,
			sequence: epoch,
			sessionId: 'private-file-mode-session',
		},
	});
}

export function makeReadyHealth(requestId: string): BridgeWorkerServerToMainMessage {
	return bridgeWorkerServerToMainMessageSchema.parse({
		wireVersion: 1,
		direction: 'serverWorkerToMain',
		kind: 'health',
		requestId,
		status: 'ready',
		transferDescriptors: [],
	});
}

export function expectRecordedGlobalPost(
	post: RecordedGlobalWorkerPost | undefined,
): RecordedGlobalWorkerPost {
	if (post === undefined) {
		throw new Error('Expected one global typed install post.');
	}
	return post;
}

export async function flushMicrotasks(): Promise<void> {
	await Promise.resolve();
	await Promise.resolve();
	await Promise.resolve();
}

export function createDeferredVoid(): {
	readonly promise: Promise<void>;
	readonly resolve: () => void;
} {
	let resolvePromise: (() => void) | null = null;
	const promise = new Promise<void>((resolve): void => {
		resolvePromise = resolve;
	});
	return {
		promise,
		resolve: (): void => {
			if (resolvePromise === null) {
				throw new Error('Deferred promise resolver was not initialized.');
			}
			resolvePromise();
		},
	};
}

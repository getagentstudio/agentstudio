import { readBridgePageConfiguration } from '../../bridge/bridge-page-configuration.js';
import type {
	BridgePaneCommWorkerSessionDiagnosticSnapshot,
	BridgePaneCommWorkerSessionDiagnosticState,
	BridgeDiagnosticDispatchDisposition,
} from '../../foundation/diagnostics/bridge-review-selection-diagnostic.js';
import type { BridgeWorkerReplacementReason } from '../../foundation/diagnostics/bridge-worker-replacement-reason.js';
import type { BridgeTelemetryScope } from '../../foundation/telemetry/bridge-telemetry-scope.js';
import { bridgeWorkerPierreRenderPolicy } from '../demand/bridge-content-demand-policy.js';
import { postBridgeCommTelemetryProducerInstall } from '../telemetry-worker/bridge-comm-telemetry-producer-install.js';
// oxlint-disable unicorn/require-post-message-target-origin -- Worker and MessagePort postMessage do not accept target origins.
import { readBridgeCommWorkerAbsoluteNowMilliseconds } from './bridge-comm-worker-clock.js';
import {
	postBridgePaneCommWorkerInstall,
	type BridgeProductSessionBootstrap,
} from './bridge-product-session-contracts.js';
import {
	bridgeWorkerMainToServerMessageSchema,
	bridgeWorkerServerToMainWireMessageSchema,
	type BridgeCommWorkerBootstrapRequest,
	type BridgeWorkerMainToServerMessage,
	type BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

export interface BridgePaneCommWorkerNativeBootstrap {
	readonly bootstrap: BridgeProductSessionBootstrap;
	readonly productCapability: ArrayBuffer;
}

export interface BridgePaneCommWorkerDispatcher {
	readonly dispatch: (message: BridgeWorkerMainToServerMessage) => void;
	readonly dispose: () => void;
}

export interface BridgePaneCommWorkerTelemetryProducerInstall {
	readonly enabledScopes: readonly BridgeTelemetryScope[];
	readonly preReadyRequiredSampleCapacity: number;
	readonly preReadyRequiredSampleMaxEncodedBytes: number;
	readonly producerPort: MessagePort;
}

export interface BridgePaneCommWorkerSessionProps {
	readonly bootstrapTimeoutMilliseconds?: number;
	readonly createObjectURL?: (blob: Blob) => string;
	readonly now?: () => number;
	readonly recordDiagnosticSnapshot?: (
		snapshot: BridgePaneCommWorkerSessionDiagnosticSnapshot,
	) => void;
	readonly requestNativeBootstrap?: (reason: 'workerReplacement') => void;
	readonly revokeObjectURL?: (url: string) => void;
	readonly workerFactory?: () => Promise<Worker> | Worker;
	readonly workerScriptUrl?: string;
}

interface BridgePaneCommWorkerClient {
	readonly bootstrapRequest: BridgeCommWorkerBootstrapRequest;
	readonly publishWorkerMessages: (messages: readonly BridgeWorkerServerToMainMessage[]) => void;
}

const defaultWorkerScriptUrl = 'agentstudio://app/assets/bridge-comm-worker.js';
// One initial replacement and three further attempts may fail before a ready worker
// renews the budget. Native replies and worker failures both consume this count.
const maximumReplacementBootstrapRequestCount = 4;

export class BridgePaneCommWorkerSession {
	readonly #clients = new Set<BridgePaneCommWorkerClient>();
	readonly #bootstrapTimeoutMilliseconds: number;
	readonly #now: () => number;
	readonly #queuedCommands: BridgeWorkerMainToServerMessage[] = [];
	readonly #recordDiagnosticSnapshot: (
		snapshot: BridgePaneCommWorkerSessionDiagnosticSnapshot,
	) => void;
	#requestNativeBootstrap: (reason: 'workerReplacement') => void;
	#onReplacementBootstrapExhausted: () => void = (): void => {};
	#prepareForWorkerReplacement: () => void = (): void => {};
	readonly #workerFactory: () => Promise<Worker> | Worker;
	#bootstrapClient: BridgePaneCommWorkerClient | null = null;
	#bootstrapTimeout: ReturnType<typeof globalThis.setTimeout> | null = null;
	#isDisposed = false;
	#isRestartRequested = false;
	#isRuntimeReady = false;
	#failureReason: 'bootstrapBudgetExhausted' | null = null;
	#latestFileModeDispatchDisposition: BridgeDiagnosticDispatchDisposition | null = null;
	#latestFileSelectDispatchDisposition: BridgeDiagnosticDispatchDisposition | null = null;
	#latestReviewSelectDispatchDisposition: BridgeDiagnosticDispatchDisposition | null = null;
	#lastReplacementReason: BridgeWorkerReplacementReason | null = null;
	#mainPort: MessagePort | null = null;
	#nativeBootstrap: BridgePaneCommWorkerNativeBootstrap | null = null;
	#nativeBootstrapInstallCount = 0;
	#replacementAttemptsSinceReady = 0;
	#replacementRequestCount = 0;
	#state: BridgePaneCommWorkerSessionDiagnosticState = 'awaiting_bootstrap';
	#telemetryProducerInstall: BridgePaneCommWorkerTelemetryProducerInstall | null = null;
	#worker: Worker | null = null;
	#workerPromise: Promise<Worker> | null = null;

	constructor(props: BridgePaneCommWorkerSessionProps = {}) {
		this.#bootstrapTimeoutMilliseconds =
			props.bootstrapTimeoutMilliseconds ??
			readBridgePageConfiguration().workerBootstrapDeadlineMilliseconds;
		this.#now = props.now ?? readBridgeCommWorkerAbsoluteNowMilliseconds;
		this.#recordDiagnosticSnapshot = props.recordDiagnosticSnapshot ?? ((): void => {});
		this.#requestNativeBootstrap = props.requestNativeBootstrap ?? ((): void => {});
		this.#workerFactory =
			props.workerFactory ??
			createBridgePaneCommWorkerFactory({
				workerScriptUrl: props.workerScriptUrl ?? defaultWorkerScriptUrl,
				...(props.createObjectURL === undefined ? {} : { createObjectURL: props.createObjectURL }),
				...(props.revokeObjectURL === undefined ? {} : { revokeObjectURL: props.revokeObjectURL }),
			});
		this.#publishDiagnosticSnapshot();
	}

	installNativeBootstrap(nativeBootstrap: BridgePaneCommWorkerNativeBootstrap): void {
		if (this.#state === 'failed') {
			throw new Error('Bridge worker replacement requires a user Retry after budget exhaustion.');
		}
		if (this.#isDisposed || this.#nativeBootstrap !== null) {
			throw new Error('Bridge pane comm worker native bootstrap was already consumed.');
		}
		this.#clearBootstrapTimeout();
		if (this.#worker !== null || this.#workerPromise !== null) {
			this.#retireCurrentWorker();
		}
		this.#nativeBootstrap = nativeBootstrap;
		this.#nativeBootstrapInstallCount += 1;
		this.#isRestartRequested = false;
		this.#state = 'bootstrapping';
		this.#failureReason = null;
		this.#publishDiagnosticSnapshot();
		void this.#ensureWorker().catch((): void => {});
	}

	/**
	 * Native answered a bootstrap request with a typed failure. While a replacement is
	 * outstanding, or before the first capability, reuse the same bounded request budget.
	 */
	handleNativeBootstrapFailure(): void {
		if (
			this.#isDisposed ||
			(this.#state !== 'replacement_requested' && this.#state !== 'awaiting_bootstrap')
		)
			return;
		this.#isRestartRequested = false;
		this.#requestWorkerReplacementBootstrap();
	}

	setNativeBootstrapRequester(requestNativeBootstrap: (reason: 'workerReplacement') => void): void {
		if (this.#isDisposed) {
			return;
		}
		this.#requestNativeBootstrap = requestNativeBootstrap;
	}

	setReplacementBootstrapExhaustionHandler(onExhausted: () => void): void {
		if (this.#isDisposed) return;
		this.#onReplacementBootstrapExhausted = onExhausted;
	}

	setWorkerReplacementPreparer(prepareForWorkerReplacement: () => void): void {
		if (this.#isDisposed) return;
		this.#prepareForWorkerReplacement = prepareForWorkerReplacement;
	}

	requestWorkerReplacement(reason: BridgeWorkerReplacementReason): void {
		if (this.#isDisposed || this.#isRestartRequested || this.#state === 'failed') return;
		this.#lastReplacementReason = reason;
		this.#prepareForWorkerReplacement();
		this.#retireCurrentWorker();
		this.#requestWorkerReplacementBootstrap();
	}

	installTelemetryProducer(install: BridgePaneCommWorkerTelemetryProducerInstall): void {
		if (this.#isDisposed) {
			install.producerPort.close();
			return;
		}
		this.#telemetryProducerInstall?.producerPort.close();
		this.#telemetryProducerInstall = install;
		if (this.#worker !== null) {
			this.#postTelemetryProducerInstall(this.#worker);
		}
	}

	createDispatcher(props: {
		readonly bootstrapRequest: BridgeCommWorkerBootstrapRequest;
		readonly publishWorkerMessages: (messages: readonly BridgeWorkerServerToMainMessage[]) => void;
	}): BridgePaneCommWorkerDispatcher {
		const client: BridgePaneCommWorkerClient = props;
		this.#clients.add(client);
		this.#bootstrapClient ??= client;
		return {
			dispatch: (message): void => {
				if (this.#isDisposed || !this.#clients.has(client)) {
					this.#recordDiagnosticDispatch(message, 'dropped_detached');
					return;
				}
				if (
					message.command === 'viewRecoveryRetry' &&
					(this.#state === 'failed' || this.#state === 'replacement_requested')
				) {
					if (this.#state === 'failed') {
						this.#replacementAttemptsSinceReady = 0;
						this.#requestWorkerReplacementBootstrap();
					}
					this.#publishWorkerMessages([
						{
							direction: 'serverWorkerToMain',
							kind: 'health',
							requestId: message.requestId,
							status: 'ready',
							transferDescriptors: [],
							wireVersion: 1,
						},
					]);
					return;
				}
				if (this.#state === 'failed') {
					this.#publishWorkerMessages([this.#workerUnavailableReply(message.requestId)]);
					return;
				}
				if (!this.#isRuntimeReady || this.#mainPort === null) {
					this.#queuedCommands.push(message);
					this.#recordDiagnosticDispatch(message, 'queued_not_ready');
					void this.#ensureWorker().catch((): void => {});
					return;
				}
				this.#postCommand(message);
			},
			dispose: (): void => {
				this.#clients.delete(client);
			},
		};
	}

	dispose(): void {
		this.#isDisposed = true;
		this.#lastReplacementReason = { kind: 'explicitDispose' };
		this.#clearBootstrapTimeout();
		this.#clients.clear();
		this.#queuedCommands.splice(0, this.#queuedCommands.length);
		this.#state = 'disposed';
		this.#publishDiagnosticSnapshot();
		this.#telemetryProducerInstall?.producerPort.close();
		this.#telemetryProducerInstall = null;
		this.#retireCurrentWorker();
	}

	async #ensureWorker(): Promise<Worker> {
		if (this.#worker !== null) {
			return this.#worker;
		}
		if (this.#workerPromise !== null) {
			return await this.#workerPromise;
		}
		if (this.#nativeBootstrap === null || this.#bootstrapClient === null) {
			throw new Error('Bridge pane comm worker is waiting for native bootstrap.');
		}
		const nativeBootstrap = this.#nativeBootstrap;
		const bootstrapClient = this.#bootstrapClient;
		this.#nativeBootstrap = null;
		let candidateWorker: Worker | null = null;
		const workerPromise = Promise.resolve()
			.then((): Promise<Worker> | Worker => this.#workerFactory())
			.then((worker): Worker => {
				candidateWorker = worker;
				if (this.#isDisposed || this.#workerPromise !== workerPromise) {
					eraseBridgeProductCapability(nativeBootstrap.productCapability);
					worker.terminate();
					return worker;
				}
				const productChannel = new MessageChannel();
				const mainPort = productChannel.port2;
				this.#mainPort = mainPort;
				mainPort.addEventListener('message', (event): void => {
					if (this.#worker !== worker || this.#mainPort !== mainPort) {
						return;
					}
					const parsedMessage = bridgeWorkerServerToMainWireMessageSchema.safeParse(event.data);
					if (!parsedMessage.success) {
						this.#publishWorkerMessages([
							{
								wireVersion: 1,
								direction: 'serverWorkerToMain',
								kind: 'health',
								status: 'degraded',
								message: 'Bridge pane comm worker returned an invalid message.',
								transferDescriptors: [],
							},
						]);
						return;
					}
					if (parsedMessage.data.kind === 'sessionSuspect') {
						const installed = nativeBootstrap.bootstrap;
						if (
							installed.paneSessionId === parsedMessage.data.paneSessionId &&
							installed.workerInstanceId === parsedMessage.data.workerInstanceId
						) {
							this.requestWorkerReplacement({
								ackAttemptOutcomes: parsedMessage.data.ackAttemptOutcomes,
								droppedPriorControlRequestCount: parsedMessage.data.droppedPriorControlRequestCount,
								kind: 'sessionSuspect',
								priorControlRequests: parsedMessage.data.priorControlRequests,
								reason: parsedMessage.data.reason,
							});
						}
						return;
					}
					if (parsedMessage.data.kind === 'fileQueryOutcome') return;
					if (
						parsedMessage.data.kind === 'health' &&
						parsedMessage.data.requestId === bootstrapClient.bootstrapRequest.requestId &&
						parsedMessage.data.status === 'ready'
					) {
						this.#isRuntimeReady = true;
						this.#state = 'ready';
						this.#replacementAttemptsSinceReady = 0;
						this.#clearBootstrapTimeout();
						this.#flushQueuedCommands();
						this.#publishDiagnosticSnapshot();
					}
					this.#publishWorkerMessages([parsedMessage.data]);
				});
				mainPort.start();
				worker.addEventListener('error', (): void =>
					this.#handleWorkerFailure(worker, { kind: 'workerError' }),
				);
				worker.addEventListener('messageerror', (): void =>
					this.#handleWorkerFailure(worker, { kind: 'messageError' }),
				);
				postBridgePaneCommWorkerInstall(worker, {
					bootstrap: nativeBootstrap.bootstrap,
					kind: 'bridgePaneCommWorker.install',
					productCapability: nativeBootstrap.productCapability,
					productPort: productChannel.port1,
				});
				this.#postTelemetryProducerInstall(worker);
				mainPort.postMessage(
					bridgePaneCommWorkerBootstrapRequest(bootstrapClient.bootstrapRequest),
				);
				this.#worker = worker;
				this.#workerPromise = null;
				return worker;
			})
			.catch((error: unknown): never => {
				eraseBridgeProductCapability(nativeBootstrap.productCapability);
				if (candidateWorker !== null && this.#worker !== candidateWorker) {
					candidateWorker.terminate();
				}
				if (this.#workerPromise === workerPromise) {
					this.requestWorkerReplacement({ kind: 'workerError' });
				}
				throw error;
			});
		this.#workerPromise = workerPromise;
		// Construction includes the packaged asset fetch and body read. The page
		// owns this same bootstrap ender before any Worker or port exists.
		this.#bootstrapTimeout = globalThis.setTimeout((): void => {
			if (
				this.#workerPromise !== workerPromise &&
				(candidateWorker === null || this.#worker !== candidateWorker)
			)
				return;
			if (candidateWorker === null) eraseBridgeProductCapability(nativeBootstrap.productCapability);
			this.requestWorkerReplacement({ kind: 'bootstrapTimeout' });
		}, this.#bootstrapTimeoutMilliseconds);
		return await workerPromise;
	}

	#postCommand(message: BridgeWorkerMainToServerMessage): void {
		this.#mainPort?.postMessage(
			bridgeWorkerMainToServerMessageSchema.parse({
				...message,
				issuedAtMilliseconds: this.#now(),
			}),
		);
		this.#recordDiagnosticDispatch(message, 'posted');
	}

	#postTelemetryProducerInstall(worker: Worker): void {
		const install = this.#telemetryProducerInstall;
		if (install === null) {
			return;
		}
		this.#telemetryProducerInstall = null;
		postBridgeCommTelemetryProducerInstall(worker, {
			type: 'bridgePaneCommWorker.telemetryProducer.install',
			enabledScopes: install.enabledScopes,
			preReadyRequiredSampleCapacity: install.preReadyRequiredSampleCapacity,
			preReadyRequiredSampleMaxEncodedBytes: install.preReadyRequiredSampleMaxEncodedBytes,
			producerPort: install.producerPort,
		});
	}

	#flushQueuedCommands(): void {
		for (const command of this.#queuedCommands.splice(0, this.#queuedCommands.length)) {
			this.#postCommand(command);
		}
	}

	#publishWorkerMessages(messages: readonly BridgeWorkerServerToMainMessage[]): void {
		for (const client of this.#clients) {
			client.publishWorkerMessages(messages);
		}
	}

	#workerUnavailableReply(requestId: string): BridgeWorkerServerToMainMessage {
		return {
			direction: 'serverWorkerToMain',
			errorKind: 'workerUnavailable',
			kind: 'health',
			requestId,
			status: 'degraded',
			transferDescriptors: [],
			wireVersion: 1,
		};
	}

	#clearBootstrapTimeout(): void {
		if (this.#bootstrapTimeout === null) {
			return;
		}
		globalThis.clearTimeout(this.#bootstrapTimeout);
		this.#bootstrapTimeout = null;
	}

	#handleWorkerFailure(worker: Worker, reason: BridgeWorkerReplacementReason): void {
		if (this.#isDisposed || this.#worker !== worker) {
			return;
		}
		this.requestWorkerReplacement(reason);
	}

	#requestWorkerReplacementBootstrap(): void {
		if (this.#isDisposed || this.#isRestartRequested) {
			return;
		}
		this.#clearBootstrapTimeout();
		if (this.#replacementAttemptsSinceReady >= maximumReplacementBootstrapRequestCount) {
			this.#failReplacementBudget();
			return;
		}
		this.#isRestartRequested = true;
		this.#replacementAttemptsSinceReady += 1;
		this.#failureReason = null;
		this.#replacementRequestCount += 1;
		this.#state = 'replacement_requested';
		this.#publishDiagnosticSnapshot();
		// Arm before dispatch: a native reply can be synchronous, or never arrive.
		this.#bootstrapTimeout = globalThis.setTimeout((): void => {
			if (this.#state !== 'replacement_requested' || !this.#isRestartRequested) return;
			this.#lastReplacementReason = { kind: 'bootstrapTimeout' };
			this.handleNativeBootstrapFailure();
		}, this.#bootstrapTimeoutMilliseconds);
		this.#requestNativeBootstrap('workerReplacement');
	}

	#failReplacementBudget(): void {
		this.#isRestartRequested = false;
		this.#state = 'failed';
		this.#failureReason = 'bootstrapBudgetExhausted';
		for (const command of this.#queuedCommands.splice(0)) {
			this.#publishWorkerMessages([this.#workerUnavailableReply(command.requestId)]);
		}
		this.#publishDiagnosticSnapshot();
		this.#onReplacementBootstrapExhausted();
	}

	#retireCurrentWorker(): void {
		this.#clearBootstrapTimeout();
		this.#isRuntimeReady = false;
		this.#mainPort?.close();
		this.#mainPort = null;
		this.#worker?.terminate();
		this.#worker = null;
		this.#workerPromise = null;
	}

	#recordDiagnosticDispatch(
		message: BridgeWorkerMainToServerMessage,
		disposition: BridgeDiagnosticDispatchDisposition,
	): void {
		if (message.command === 'activeViewerModeUpdate' && message.update.mode === 'file') {
			this.#latestFileModeDispatchDisposition = disposition;
		} else if (message.command === 'select' && message.surface === 'fileView') {
			this.#latestFileSelectDispatchDisposition = disposition;
		} else if (message.command === 'select' && message.surface === 'review') {
			this.#latestReviewSelectDispatchDisposition = disposition;
		} else {
			return;
		}
		this.#publishDiagnosticSnapshot();
	}

	#publishDiagnosticSnapshot(): void {
		try {
			this.#recordDiagnosticSnapshot({
				failureReason: this.#failureReason,
				latestFileModeDispatchDisposition: this.#latestFileModeDispatchDisposition,
				latestFileSelectDispatchDisposition: this.#latestFileSelectDispatchDisposition,
				latestReviewSelectDispatchDisposition: this.#latestReviewSelectDispatchDisposition,
				lastReplacementReason: this.#lastReplacementReason,
				nativeBootstrapInstallCount: this.#nativeBootstrapInstallCount,
				queuedCommandCount: this.#queuedCommands.length,
				replacementRequestCount: this.#replacementRequestCount,
				state: this.#state,
			});
		} catch {
			// Diagnostics are observational and cannot own the pane session lifecycle.
		}
	}
}

function bridgePaneCommWorkerBootstrapRequest(
	request: BridgeCommWorkerBootstrapRequest,
): BridgeCommWorkerBootstrapRequest {
	return {
		...request,
		runtime: {
			...request.runtime,
			surfacePolicies: {
				fileView: {
					bridgeDemandRank: { lane: 'selected', priority: 0 },
					budget: bridgeWorkerPierreRenderPolicy.fileViewSelectedRenderBudget,
				},
				review: {
					bridgeDemandRank: { lane: 'selected', priority: 0 },
					budget: bridgeWorkerPierreRenderPolicy.reviewInteractiveRenderBudget,
				},
			},
		},
	};
}

function eraseBridgeProductCapability(productCapability: ArrayBuffer): void {
	new Uint8Array(productCapability).fill(0);
}

let defaultPaneSession: BridgePaneCommWorkerSession | null = null;

export function installBridgePaneCommWorkerSessionForHost(
	session: BridgePaneCommWorkerSession,
): void {
	if (defaultPaneSession !== null) {
		throw new Error('Bridge pane comm worker session host was already installed.');
	}
	defaultPaneSession = session;
}

export function getBridgePaneCommWorkerSession(): BridgePaneCommWorkerSession {
	defaultPaneSession ??= new BridgePaneCommWorkerSession();
	return defaultPaneSession;
}

export function createBridgePaneCommWorkerDispatcher(props: {
	readonly bootstrapRequest: BridgeCommWorkerBootstrapRequest;
	readonly publishWorkerMessages: (messages: readonly BridgeWorkerServerToMainMessage[]) => void;
}): BridgePaneCommWorkerDispatcher {
	return getBridgePaneCommWorkerSession().createDispatcher(props);
}

export function disposeBridgePaneCommWorkerSession(): void {
	defaultPaneSession?.dispose();
	defaultPaneSession = null;
}

function createBridgePaneCommWorkerFactory(props: {
	readonly createObjectURL?: (blob: Blob) => string;
	readonly revokeObjectURL?: (url: string) => void;
	readonly workerScriptUrl: string;
}): () => Promise<Worker> {
	const createObjectURL = props.createObjectURL ?? URL.createObjectURL.bind(URL);
	const revokeObjectURL = props.revokeObjectURL ?? URL.revokeObjectURL.bind(URL);
	let workerScriptBlobUrl: string | null = null;

	return async (): Promise<Worker> => {
		if (workerScriptBlobUrl === null) {
			const response = await fetch(props.workerScriptUrl);
			if (!response.ok) {
				throw new Error(`Failed to load bridge comm worker: ${response.status}`);
			}
			const workerSource = await response.text();
			workerScriptBlobUrl = createObjectURL(
				new Blob([workerSource], { type: 'application/javascript' }),
			);
		}
		const worker = new Worker(workerScriptBlobUrl, { type: 'module' });
		worker.addEventListener(
			'error',
			(): void => {
				if (workerScriptBlobUrl !== null) {
					revokeObjectURL(workerScriptBlobUrl);
					workerScriptBlobUrl = null;
				}
			},
			{ once: true },
		);
		return worker;
	};
}

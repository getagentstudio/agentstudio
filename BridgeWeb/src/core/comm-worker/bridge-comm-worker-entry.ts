import { bridgeCommTelemetryProducerInstallSchema } from '../telemetry-worker/bridge-comm-telemetry-producer-install.js';
import {
	createBridgeTelemetryWorkerEventProducer,
	type BridgeTelemetryWorkerEventProducer,
} from '../telemetry-worker/bridge-telemetry-worker-event-adapter.js';
// oxlint-disable unicorn/require-post-message-target-origin -- WorkerGlobalScope.postMessage does not accept a targetOrigin argument.
import {
	buildBridgeWorkerReadyHealthEvent,
	buildBridgeWorkerViewRecoveryStatusEvent,
} from './bridge-comm-worker-protocol.js';
import {
	registerBridgeCommWorkerRuntimePortProtocol,
	type RegisterBridgeCommWorkerRuntimePortProtocolProps,
} from './bridge-comm-worker-runtime-protocol.js';
import { BridgeCommWorkerStartupTelemetryBuffer } from './bridge-comm-worker-startup-telemetry.js';
import type { BridgeCommWorkerTelemetryRecorder } from './bridge-comm-worker-telemetry.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import { bridgeProductMetadataApplicationRegistry } from './bridge-product-metadata-application-registry.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import {
	BridgeProductControlMux,
	BridgeProductSessionAuthorityStore,
	BridgeProductSessionSuspectError,
	type BridgeProductSessionAuthorityInstallInput,
} from './bridge-product-session-authority.js';
import { bridgePaneCommWorkerInstallSchema } from './bridge-product-session-contracts.js';
import {
	createBridgeProductTransport,
	type BridgeProductTransportSession,
} from './bridge-product-transport.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeCommWorkerBootstrapRequestSchema,
	bridgeWorkerMainToServerMessageSchema,
	type BridgeCommWorkerBootstrapRequest,
	type BridgeWorkerAckAttemptOutcome,
	type BridgeWorkerPriorControlRequest,
	type BridgeWorkerServerToMainMessage,
	type BridgeWorkerServerToMainWireMessage,
	type BridgeWorkerViewRecoveryStatusEvent,
} from './bridge-worker-contracts.js';
import type { PreparedBridgeWorkerStructuredMessage } from './bridge-worker-transfer-list.js';

export interface BridgeCommWorkerPort {
	postMessage(message: BridgeWorkerServerToMainWireMessage): void;
	postMessage(message: BridgeWorkerServerToMainWireMessage, transferList: Transferable[]): void;
	readonly addEventListener: (
		type: 'message',
		listener: (event: MessageEvent<unknown>) => void,
	) => void;
	readonly dispatchEvent?: (event: Event) => boolean;
	readonly start?: () => void;
}

export interface BridgeCommWorkerGlobalScope {
	postMessage(message: BridgeWorkerServerToMainWireMessage): void;
	postMessage(message: BridgeWorkerServerToMainWireMessage, transferList: Transferable[]): void;
	readonly addEventListener: (
		type: 'message',
		listener: (event: MessageEvent<unknown>) => void,
	) => void;
	readonly dispatchEvent?: (event: Event) => boolean;
}

export interface BridgeCommWorkerEntryDependencies {
	readonly installProductSession: (
		input: BridgeProductSessionAuthorityInstallInput & {
			readonly publishSessionSuspect?: (
				reason: 'admissionReplyExhausted' | 'resultAcknowledgementExhausted',
				ackAttemptOutcomes: readonly BridgeWorkerAckAttemptOutcome[],
				priorControlRequests: readonly BridgeWorkerPriorControlRequest[],
				droppedPriorControlRequestCount: number,
			) => void;
			readonly publishViewRecoveryStatus?: (
				status: Pick<BridgeWorkerViewRecoveryStatusEvent, 'status' | 'view'>,
			) => void;
		},
	) => BridgeCommWorkerInstalledProductSession;
}

export interface RegisterBridgeCommWorkerEntryProps {
	readonly deadlineClock?: BridgeProductDeadlineClock;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly maximumConcurrentContentResponses?: number;
}

export interface BridgeCommWorkerInstalledProductSession {
	readonly open: Promise<void>;
	readonly productTransport: BridgeProductTransportSession;
}

export function postPreparedBridgeCommWorkerMessage(
	port: BridgeCommWorkerPort,
	preparedMessage: PreparedBridgeWorkerStructuredMessage<BridgeWorkerServerToMainMessage>,
): void {
	port.postMessage(preparedMessage.message, [...preparedMessage.transferList]);
}

export function registerInertBridgeCommWorkerPortProtocol(port: BridgeCommWorkerPort): void {
	port.addEventListener('message', (event: MessageEvent<unknown>): void => {
		const parsedMessage = bridgeWorkerMainToServerMessageSchema.safeParse(event.data);
		if (!parsedMessage.success) {
			port.postMessage({
				wireVersion: 1,
				direction: 'serverWorkerToMain',
				transferDescriptors: [],
				kind: 'health',
				status: 'degraded',
				message: 'Bridge comm worker received invalid message.',
			});
			return;
		}
		port.postMessage(buildBridgeWorkerReadyHealthEvent(parsedMessage.data.requestId));
	});
	port.start?.();
}

export function createBridgeCommWorkerScopePortAdapter(
	scope: BridgeCommWorkerGlobalScope,
): BridgeCommWorkerPort {
	return {
		postMessage: (
			message: BridgeWorkerServerToMainMessage,
			transferList?: Transferable[],
		): void => {
			if (transferList === undefined) {
				scope.postMessage(message);
				return;
			}
			scope.postMessage(message, transferList);
		},
		addEventListener: (type: 'message', listener: (event: MessageEvent<unknown>) => void): void => {
			scope.addEventListener(type, listener);
		},
		...(scope.dispatchEvent === undefined
			? {}
			: {
					dispatchEvent: (event: Event): boolean => scope.dispatchEvent?.(event) ?? false,
				}),
	};
}

export function bootstrapInertBridgeCommWorkerEntry(scope: BridgeCommWorkerGlobalScope): void {
	registerInertBridgeCommWorkerPortProtocol(createBridgeCommWorkerScopePortAdapter(scope));
}

export function bootstrapBridgeCommWorkerEntry(
	port: BridgeCommWorkerPort,
	dependencies: BridgeCommWorkerEntryDependencies,
): void {
	let installedProductPort: MessagePort | null = null;
	let installedTelemetryProducer: BridgeTelemetryWorkerEventProducer | null = null;
	const startupTelemetry = new BridgeCommWorkerStartupTelemetryBuffer();
	let startupTelemetryLimits: {
		readonly maximumBytes: number;
		readonly maximumSamples: number;
	} | null = null;
	const telemetryRecorder: BridgeCommWorkerTelemetryRecorder = {
		record: (sample): void => {
			if (installedTelemetryProducer === null) startupTelemetry.record(sample);
			else installedTelemetryProducer.record(sample);
		},
	};

	port.addEventListener('message', (event: MessageEvent<unknown>): void => {
		const parsedTelemetryInstall = bridgeCommTelemetryProducerInstallSchema.safeParse(event.data);
		if (parsedTelemetryInstall.success) {
			event.stopImmediatePropagation();
			if (installedTelemetryProducer !== null) {
				parsedTelemetryInstall.data.producerPort.close();
				port.postMessage(
					buildBridgeWorkerEntryDegradedHealthEvent({
						message: 'Bridge comm telemetry producer was already installed.',
					}),
				);
				return;
			}
			const telemetryLimits = startupTelemetryLimits;
			installedTelemetryProducer = createBridgeTelemetryWorkerEventProducer({
				enabledScopes: new Set(parsedTelemetryInstall.data.enabledScopes),
				port: parsedTelemetryInstall.data.producerPort,
				preReadyRequiredSampleCapacity: Math.min(
					telemetryLimits?.maximumSamples ??
						parsedTelemetryInstall.data.preReadyRequiredSampleCapacity,
					parsedTelemetryInstall.data.preReadyRequiredSampleCapacity,
				),
				preReadyRequiredSampleMaxEncodedBytes: Math.min(
					telemetryLimits?.maximumBytes ??
						parsedTelemetryInstall.data.preReadyRequiredSampleMaxEncodedBytes,
					parsedTelemetryInstall.data.preReadyRequiredSampleMaxEncodedBytes,
				),
			});
			startupTelemetry.drainInto(installedTelemetryProducer);
			return;
		}
		const parsedInstall = bridgePaneCommWorkerInstallSchema.safeParse(event.data);
		if (parsedInstall.success) {
			event.stopImmediatePropagation();
			if (installedProductPort !== null) {
				parsedInstall.data.productPort.close();
				port.postMessage(
					buildBridgeWorkerEntryDegradedHealthEvent({
						message: 'Bridge pane comm worker was already installed.',
					}),
				);
				return;
			}
			startupTelemetryLimits = {
				maximumBytes: parsedInstall.data.bootstrap.policy.telemetryPreReadyBufferMaxBytes,
				maximumSamples: parsedInstall.data.bootstrap.policy.telemetryPreReadyBufferMaxSamples,
			};
			startupTelemetry.configure(startupTelemetryLimits);
			const productSession = dependencies.installProductSession({
				bootstrap: parsedInstall.data.bootstrap,
				productCapability: parsedInstall.data.productCapability,
				publishSessionSuspect: (
					reason,
					ackAttemptOutcomes,
					priorControlRequests,
					droppedPriorControlRequestCount,
				): void =>
					parsedInstall.data.productPort.postMessage({
						ackAttemptOutcomes,
						droppedPriorControlRequestCount,
						direction: 'serverWorkerToMain',
						kind: 'sessionSuspect',
						paneSessionId: parsedInstall.data.bootstrap.paneSessionId,
						priorControlRequests,
						reason,
						transferDescriptors: [],
						wireVersion: BRIDGE_WORKER_WIRE_VERSION,
						workerInstanceId: parsedInstall.data.bootstrap.workerInstanceId,
					}),
				publishViewRecoveryStatus: (status): void =>
					parsedInstall.data.productPort.postMessage(
						buildBridgeWorkerViewRecoveryStatusEvent(status),
					),
			});
			installedProductPort = parsedInstall.data.productPort;
			bootstrapBridgeCommWorkerRuntimeEntry(
				installedProductPort,
				productSession,
				telemetryRecorder,
				{
					paneSessionId: parsedInstall.data.bootstrap.paneSessionId,
					workerInstanceId: parsedInstall.data.bootstrap.workerInstanceId,
				},
			);
			return;
		}

		const parsedCommand = bridgeWorkerMainToServerMessageSchema.safeParse(event.data);
		port.postMessage(
			buildBridgeWorkerEntryDegradedHealthEvent({
				...(parsedCommand.success ? { requestId: parsedCommand.data.requestId } : {}),
				message:
					installedProductPort === null
						? 'Bridge pane comm worker requires a typed install message.'
						: 'Bridge pane comm worker accepts ordinary commands only on the installed port.',
			}),
		);
	});
	port.start?.();
}

export function registerBridgeCommWorkerEntry(
	scope: BridgeCommWorkerGlobalScope,
	props: RegisterBridgeCommWorkerEntryProps,
): void {
	bootstrapBridgeCommWorkerEntry(
		createBridgeCommWorkerScopePortAdapter(scope),
		bridgeCommWorkerEntryDependencies(props),
	);
}

function bridgeCommWorkerEntryDependencies(
	props: RegisterBridgeCommWorkerEntryProps,
): BridgeCommWorkerEntryDependencies {
	const productSessionAuthority = new BridgeProductSessionAuthorityStore(
		props.executeProductRequest,
		props.deadlineClock,
	);
	return {
		installProductSession: (input): BridgeCommWorkerInstalledProductSession => {
			const authority = productSessionAuthority.install({
				bootstrap: input.bootstrap,
				productCapability: input.productCapability,
			});
			const controlMux = new BridgeProductControlMux({
				authority,
				...(props.deadlineClock === undefined ? {} : { deadlineClock: props.deadlineClock }),
				executeProductRequest: props.executeProductRequest,
				...(input.publishSessionSuspect === undefined
					? {}
					: { onSessionSuspect: input.publishSessionSuspect }),
			});
			return {
				open: authority.open,
				productTransport: createBridgeProductTransport({
					authority,
					controlMux,
					executeProductRequest: props.executeProductRequest,
					metadataApplicationRegistry: bridgeProductMetadataApplicationRegistry,
					...(input.publishViewRecoveryStatus === undefined
						? {}
						: { onViewRecoveryStatus: input.publishViewRecoveryStatus }),
					...(props.maximumConcurrentContentResponses === undefined
						? {}
						: {
								maximumConcurrentContentResponses: props.maximumConcurrentContentResponses,
							}),
				}),
			};
		},
	};
}

function bootstrapBridgeCommWorkerRuntimeEntry(
	port: BridgeCommWorkerPort,
	productSession: BridgeCommWorkerInstalledProductSession,
	telemetryRecorder: BridgeCommWorkerTelemetryRecorder,
	renderFulfillmentContext: {
		readonly paneSessionId: string;
		readonly workerInstanceId: string;
	},
): void {
	let didBootstrapRuntime = false;
	let didReceiveBootstrap = false;
	const pendingMessagesBeforeBootstrap: unknown[] = [];

	port.addEventListener('message', (event: MessageEvent<unknown>): void => {
		const parsedBootstrap = bridgeCommWorkerBootstrapRequestSchema.safeParse(event.data);
		if (parsedBootstrap.success) {
			event.stopImmediatePropagation();
			if (didReceiveBootstrap) {
				port.postMessage(
					buildBridgeWorkerEntryDegradedHealthEvent({
						requestId: parsedBootstrap.data.requestId,
						message: 'Bridge comm worker runtime was already bootstrapped.',
					}),
				);
				return;
			}
			didReceiveBootstrap = true;
			void productSession.open
				.then((): void => {
					didBootstrapRuntime = true;
					registerBridgeCommWorkerRuntimePortProtocol(
						port,
						runtimePropsFromBootstrapRequest(
							parsedBootstrap.data,
							productSession.productTransport,
							telemetryRecorder,
							renderFulfillmentContext,
						),
					);
					port.postMessage(buildBridgeWorkerReadyHealthEvent(parsedBootstrap.data.requestId));
					for (const pendingMessage of pendingMessagesBeforeBootstrap.splice(
						0,
						pendingMessagesBeforeBootstrap.length,
					)) {
						dispatchPendingMessageToRuntime(port, pendingMessage);
					}
				})
				.catch((error: unknown): void => {
					pendingMessagesBeforeBootstrap.splice(0, pendingMessagesBeforeBootstrap.length);
					if (error instanceof BridgeProductSessionSuspectError && error.shouldNotify) {
						port.postMessage({
							ackAttemptOutcomes: [],
							droppedPriorControlRequestCount: 0,
							direction: 'serverWorkerToMain',
							kind: 'sessionSuspect',
							paneSessionId: renderFulfillmentContext.paneSessionId,
							priorControlRequests: [],
							reason:
								error.phase === 'admission' ? 'admissionReplyExhausted' : 'resultDeadlineExhausted',
							transferDescriptors: [],
							wireVersion: BRIDGE_WORKER_WIRE_VERSION,
							workerInstanceId: renderFulfillmentContext.workerInstanceId,
						});
					}
					port.postMessage(
						buildBridgeWorkerEntryDegradedHealthEvent({
							requestId: parsedBootstrap.data.requestId,
							message: 'Bridge product session open was rejected.',
						}),
					);
				});
			return;
		}

		if (didBootstrapRuntime) {
			return;
		}

		const parsedCommand = bridgeWorkerMainToServerMessageSchema.safeParse(event.data);
		if (parsedCommand.success) {
			pendingMessagesBeforeBootstrap.push(parsedCommand.data);
			port.postMessage(
				buildBridgeWorkerEntryDegradedHealthEvent({
					requestId: parsedCommand.data.requestId,
					message: 'Bridge comm worker command received before bootstrap.',
				}),
			);
			return;
		}

		port.postMessage(
			buildBridgeWorkerEntryDegradedHealthEvent({
				message: 'Bridge comm worker received invalid bootstrap message.',
			}),
		);
	});
	port.start?.();
}

function runtimePropsFromBootstrapRequest(
	request: BridgeCommWorkerBootstrapRequest,
	productTransport: BridgeProductTransportSession,
	telemetryClient: BridgeCommWorkerTelemetryRecorder | undefined,
	renderFulfillmentContext: {
		readonly paneSessionId: string;
		readonly workerInstanceId: string;
	},
): RegisterBridgeCommWorkerRuntimePortProtocolProps {
	const reviewPolicy = request.runtime.surfacePolicies?.review;
	const fileViewPolicy = request.runtime.surfacePolicies?.fileView;
	return {
		bridgeDemandRank: reviewPolicy?.bridgeDemandRank ?? request.runtime.bridgeDemandRank,
		budget: reviewPolicy?.budget ?? request.runtime.budget,
		...(fileViewPolicy === undefined
			? {}
			: {
					fileViewBridgeDemandRank: fileViewPolicy.bridgeDemandRank,
					fileViewBudget: fileViewPolicy.budget,
				}),
		...(request.runtime.maxPreparationSliceMs === undefined
			? {}
			: { maxPreparationSliceMs: request.runtime.maxPreparationSliceMs }),
		productTransport,
		renderFulfillmentContext,
		...(telemetryClient === undefined ? {} : { telemetryClient }),
	};
}

function dispatchPendingMessageToRuntime(port: BridgeCommWorkerPort, data: unknown): void {
	if (port.dispatchEvent === undefined) {
		return;
	}
	port.dispatchEvent(new MessageEvent('message', { data }));
}

function buildBridgeWorkerEntryDegradedHealthEvent(props: {
	readonly requestId?: string;
	readonly message: string;
}): BridgeWorkerServerToMainMessage {
	return {
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'health',
		...(props.requestId === undefined ? {} : { requestId: props.requestId }),
		status: 'degraded',
		message: props.message,
	};
}

import { publishBridgeProductMetadataStreamDiagnostic } from '../../foundation/diagnostics/bridge-product-metadata-stream-diagnostic.js';
import {
	recordBridgePaneCommWorkerSessionDiagnosticSnapshot,
	recordBridgePaneRuntimeDiagnosticSnapshot,
	type BridgePaneRuntimeDiagnosticSnapshot,
} from '../../foundation/diagnostics/bridge-review-selection-diagnostic.js';
import type {
	BridgeWorkerReplacementReason,
	BridgeWorkerRuntimeRecoverySource,
} from '../../foundation/diagnostics/bridge-worker-replacement-reason.js';
import { bridgeWorkerPierreRenderPolicy } from '../demand/bridge-content-demand-policy.js';
import type { BridgePaneFailedStartFact } from '../models/bridge-pane-failed-start.js';
import { encodeBridgeWorkerRenderDispositionCommand } from './bridge-comm-worker-protocol.js';
import type { BridgeCommWorkerTelemetryRecorder } from './bridge-comm-worker-telemetry.js';
import {
	createBridgeMainRenderDispositionAdmission,
	type BridgeMainRenderDispositionAdmission,
} from './bridge-main-render-disposition-admission.js';
import {
	BRIDGE_PAINTED_PUBLICATION_ID_ATTRIBUTE,
	createBridgeMainRenderFulfillmentCoordinator,
	stampBridgeRenderDispositionSettlementEvidence,
	type BridgeMainRenderFulfillmentCoordinator,
} from './bridge-main-render-fulfillment-coordinator.js';
import {
	createBridgeMainRenderSnapshotStore,
	type BridgeMainRenderSnapshotStore,
	type BridgeMainRenderSnapshotStoreProps,
} from './bridge-main-render-snapshot-store.js';
import {
	BridgePaneCommWorkerSession,
	type BridgePaneCommWorkerDispatcher,
	type BridgePaneCommWorkerNativeBootstrap,
	type BridgePaneCommWorkerSessionProps,
	type BridgePaneCommWorkerTelemetryProducerInstall,
} from './bridge-pane-comm-worker-session.js';
import {
	type BridgeCommWorkerBootstrapRequest,
	type BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import {
	createBridgeWorkerRpcClient,
	type BridgePaneSurface,
	type BridgeWorkerRpcClient,
	type BridgeWorkerRpcCommandInput,
} from './bridge-worker-rpc-client.js';
import {
	createBridgeWorkerRpcLifecycleStore,
	type BridgeWorkerRpcLifecycleSnapshot,
	type BridgeWorkerRpcLifecycleStore,
} from './bridge-worker-rpc-lifecycle-store.js';

export interface BridgePaneSessionPort {
	readonly createDispatcher: (props: {
		readonly publishWorkerMessages: (messages: readonly BridgeWorkerServerToMainMessage[]) => void;
	}) => BridgePaneCommWorkerDispatcher;
	readonly dispose: () => void;
	readonly handleNativeBootstrapFailure?: () => void;
	readonly installNativeBootstrap: (bootstrap: BridgePaneCommWorkerNativeBootstrap) => void;
	readonly installTelemetryProducer?: (
		install: BridgePaneCommWorkerTelemetryProducerInstall,
	) => void;
	readonly requestWorkerReplacement?: (reason: BridgeWorkerReplacementReason) => void;
	readonly setNativeBootstrapRequester?: (requester: (reason: 'workerReplacement') => void) => void;
	readonly setReplacementBootstrapExhaustionHandler?: (onExhausted: () => void) => void;
	readonly setWorkerReplacementPreparer?: (prepare: () => void) => void;
}

export interface BridgePaneSurfaceLifecycleView {
	readonly getSnapshot: () => BridgeWorkerRpcLifecycleSnapshot;
	readonly getServerSnapshot: () => BridgeWorkerRpcLifecycleSnapshot;
	readonly subscribe: (listener: () => void) => () => void;
}

export interface BridgePaneSurfaceClient {
	readonly requestWorkerReplacement: (source: BridgeWorkerRuntimeRecoverySource) => void;
	readonly lifecycle: BridgePaneSurfaceLifecycleView;
	readonly renderFulfillmentCoordinator: BridgeMainRenderFulfillmentCoordinator;
	readonly renderStore: BridgeMainRenderSnapshotStore;
	readonly send: (command: BridgeWorkerRpcCommandInput) => string;
	readonly subscribeMessages: (
		listener: (message: BridgeWorkerServerToMainMessage) => void,
	) => () => void;
	readonly subscribeWorkerReplacement?: (listener: () => void) => () => void;
	readonly surface: BridgePaneSurface;
}

export interface BridgePaneClient {
	readonly lifecycle: BridgePaneSurfaceLifecycleView;
	readonly send: (command: BridgeWorkerRpcCommandInput) => string;
	readonly subscribeMessages: (
		listener: (message: BridgeWorkerServerToMainMessage) => void,
	) => () => void;
}

export interface BridgePaneRuntime {
	readonly setPaneFailedStartHandler: (
		handler: ((fact: BridgePaneFailedStartFact) => void) | null,
	) => void;
	readonly lifecycleStore: BridgeWorkerRpcLifecycleStore;
	readonly paneClient: BridgePaneClient;
	readonly dispose: () => void;
	readonly handleNativeBootstrapFailure: () => void;
	readonly installNativeBootstrap: (bootstrap: BridgePaneCommWorkerNativeBootstrap) => void;
	readonly installTelemetryProducer: (
		install: BridgePaneCommWorkerTelemetryProducerInstall,
	) => void;
	readonly installMainTelemetryRecorder: (recorder: BridgeCommWorkerTelemetryRecorder) => void;
	readonly setNativeBootstrapRequester: (requester: (reason: 'workerReplacement') => void) => void;
	readonly surfaceClient: (surface: BridgePaneSurface) => BridgePaneSurfaceClient;
}

export interface CreateBridgePaneRuntimeProps {
	readonly lifecycleStoreFactory?: () => BridgeWorkerRpcLifecycleStore;
	readonly recordDiagnosticSnapshot?: (snapshot: BridgePaneRuntimeDiagnosticSnapshot) => void;
	readonly renderStoreFactory?: (
		storeProps?: BridgeMainRenderSnapshotStoreProps,
	) => BridgeMainRenderSnapshotStore;
	readonly sessionFactory?: () => BridgePaneSessionPort;
	readonly sessionProps?: BridgePaneCommWorkerSessionProps;
}

export function createBridgePaneRuntime(
	props: CreateBridgePaneRuntimeProps = {},
): BridgePaneRuntime {
	const lifecycleStore = (props.lifecycleStoreFactory ?? createBridgeWorkerRpcLifecycleStore)();
	const renderStoreFactory = props.renderStoreFactory ?? createBridgeMainRenderSnapshotStore;
	const session =
		props.sessionFactory?.() ?? createDefaultBridgePaneSessionPort(props.sessionProps);
	const recordDiagnosticSnapshot =
		props.recordDiagnosticSnapshot ?? recordBridgePaneRuntimeDiagnosticSnapshot;
	const rpcClients = new Map<BridgePaneSurface | 'pane', BridgeWorkerRpcClient>();
	const surfaceClients = new Map<BridgePaneSurface, BridgePaneSurfaceClient>();
	const renderFulfillmentCoordinators = new Set<BridgeMainRenderFulfillmentCoordinator>();
	const renderDispositionAdmissions = new Set<BridgeMainRenderDispositionAdmission>();
	const renderStores = new Set<BridgeMainRenderSnapshotStore>();
	const workerUnavailableViews = new Map<
		Extract<BridgeWorkerServerToMainMessage, { kind: 'viewRecoveryStatus' }>['view']['kind'],
		Extract<BridgeWorkerServerToMainMessage, { kind: 'viewRecoveryStatus' }>['view']
	>();
	const workerReplacementListeners = new Set<() => void>();
	let isDisposed = false;
	let paneFailedStartFact: BridgePaneFailedStartFact | null = null;
	let paneFailedStartHandler: ((fact: BridgePaneFailedStartFact) => void) | null = null;
	let nativeBootstrapInstalled = false;
	let nativeBootstrapReplacementRequested = false;
	let nativeBootstrapInstallAcceptedCount = 0;
	let nativeBootstrapInstallAttemptCount = 0;
	let nativeBootstrapInstallRejectedCount = 0;
	let nextRequestSequence = 0;
	let fileRpcClient: BridgeWorkerRpcClient | null = null;
	let latestFileDisplayEpoch = 0;
	let mainTelemetryRecorder: BridgeCommWorkerTelemetryRecorder | undefined;
	const admissionTelemetryRecorder: BridgeCommWorkerTelemetryRecorder = {
		record: (sample): void => mainTelemetryRecorder?.record(sample),
	};
	const currentReplacementReplayEntryByKey = new Map<string, BridgePaneReplacementReplayEntry>();
	let pendingReplacementReplayEntryByKey: Map<string, BridgePaneReplacementReplayEntry> | null =
		null;

	const recordReplacementReplayEntry = (
		command: BridgeWorkerRpcCommandInput,
		send: (command: BridgeWorkerRpcCommandInput) => string,
	): void => {
		const identity = bridgePaneReplacementReplayIdentity(command);
		if (identity === null) return;
		const entry = { ...identity, command, send } satisfies BridgePaneReplacementReplayEntry;
		currentReplacementReplayEntryByKey.set(identity.key, entry);
		pendingReplacementReplayEntryByKey?.delete(identity.key);
	};

	const replayCurrentIntentAfterReplacement = (): void => {
		const pendingEntries = pendingReplacementReplayEntryByKey;
		if (pendingEntries === null) return;
		pendingReplacementReplayEntryByKey = null;
		for (const entry of [...pendingEntries.values()].toSorted(compareReplacementReplayEntries)) {
			entry.send(entry.command);
		}
	};

	const failPendingRequestsForWorkerReplacement = (): void => {
		const pendingRequests = Object.values(lifecycleStore.getSnapshot().requestsById).filter(
			(request) => request.state === 'pending',
		);
		for (const request of pendingRequests) {
			rpcClients.get(request.surface)?.receive({
				direction: 'serverWorkerToMain',
				kind: 'health',
				message: 'Bridge comm worker was replaced before request settlement.',
				requestId: request.requestId,
				status: 'degraded',
				transferDescriptors: [],
				wireVersion: 1,
			});
		}
	};
	const prepareRuntimeForWorkerReplacement = (): void => {
		if (isDisposed || nativeBootstrapReplacementRequested) return;
		nativeBootstrapReplacementRequested = true;
		for (const admission of renderDispositionAdmissions) {
			admission.prepareForWorkerReplacement();
		}
		failPendingRequestsForWorkerReplacement();
		pendingReplacementReplayEntryByKey = new Map(currentReplacementReplayEntryByKey);
		latestFileDisplayEpoch = 0;
		for (const renderStore of renderStores) renderStore.prepareForWorkerReplacement();
		for (const listener of workerReplacementListeners) listener();
		for (const coordinator of renderFulfillmentCoordinators) {
			coordinator.retireWorkerInstance();
		}
	};
	session.setWorkerReplacementPreparer?.(prepareRuntimeForWorkerReplacement);
	const publishViewRecoveryStatus = (
		event: Extract<BridgeWorkerServerToMainMessage, { kind: 'viewRecoveryStatus' }>,
	): void => {
		const targetSurface = bridgePaneSurfaceForViewRecoveryStatusKind(event.view.kind);
		surfaceClients.get(targetSurface)?.renderStore.applyViewRecoveryStatusEvent(event);
		for (const client of rpcClients.values()) client.receive(event);
	};
	const failRenderView = (surface: 'fileView' | 'review'): void => {
		const kind = surface === 'fileView' ? 'file.metadata' : 'review.metadata';
		const current = surfaceClients.get(surface)?.renderStore.getViewRecoveryStatus(kind);
		if (current === null || current === undefined) return;
		publishViewRecoveryStatus({
			direction: 'serverWorkerToMain',
			kind: 'viewRecoveryStatus',
			status: 'failedRetryable',
			transferDescriptors: [],
			view: current.view,
			wireVersion: 1,
		});
	};

	const publishDiagnosticSnapshot = (): void => {
		try {
			recordDiagnosticSnapshot({
				nativeBootstrapInstallAcceptedCount,
				nativeBootstrapInstallAttemptCount,
				nativeBootstrapInstallRejectedCount,
			});
		} catch {
			// Diagnostics are observational and cannot own the pane runtime lifecycle.
		}
	};
	publishDiagnosticSnapshot();

	const dispatcher = session.createDispatcher({
		publishWorkerMessages: (messages): void => {
			for (const message of messages) {
				if (message.kind === 'health') publishBridgeProductMetadataStreamDiagnostic(message);
				if (message.kind === 'viewRecoveryStatus') {
					publishViewRecoveryStatus(message);
					continue;
				}
				for (const client of rpcClients.values()) client.receive(message);
				if (
					message.kind === 'health' &&
					message.requestId === 'pane-runtime-bootstrap' &&
					message.status === 'ready'
				) {
					for (const view of workerUnavailableViews.values()) {
						const store = surfaceClients.get(
							bridgePaneSurfaceForViewRecoveryStatusKind(view.kind),
						)?.renderStore;
						const current = store?.getViewRecoveryStatus(view.kind);
						if (
							current?.view.subscriptionId === view.subscriptionId &&
							current.status === 'failedRetryable'
						) {
							publishViewRecoveryStatus({
								direction: 'serverWorkerToMain',
								kind: 'viewRecoveryStatus',
								status: 'ready',
								transferDescriptors: [],
								view,
								wireVersion: 1,
							});
						}
					}
					workerUnavailableViews.clear();
					replayCurrentIntentAfterReplacement();
				}
			}
		},
	});

	const requestWorkerReplacement = (source: BridgeWorkerRuntimeRecoverySource): void => {
		if (isDisposed) return;
		if (session.requestWorkerReplacement === undefined) {
			throw new Error('Bridge pane runtime session cannot replace an overloaded worker.');
		}
		prepareRuntimeForWorkerReplacement();
		session.requestWorkerReplacement({ kind: 'runtimeRecovery', source });
	};

	for (const surface of ['fileView', 'review'] as const) {
		let renderFulfillmentCoordinatorForStore: BridgeMainRenderFulfillmentCoordinator | null = null;
		const renderStore = renderStoreFactory(
			surface === 'fileView'
				? {
						requestResync: (request): void => {
							if (fileRpcClient === null) {
								throw new Error('Bridge pane runtime File RPC client is not installed.');
							}
							fileRpcClient.send({
								command: 'fileDisplayResync',
								epoch: latestFileDisplayEpoch,
								reason: request.reason,
								transactionId: request.transactionId,
							});
						},
					}
				: {
						onReviewPaintedCopyReleased: (itemId): boolean => {
							return renderFulfillmentCoordinatorForStore?.releasePaintedCopy(itemId) ?? false;
						},
					},
		);
		renderStores.add(renderStore);
		const rpcClient = createBridgeWorkerRpcClient({
			dispatch: dispatcher.dispatch,
			lifecycleStore,
			requestIdFactory: (): string => {
				nextRequestSequence += 1;
				return `bridge-${surface}-rpc-${nextRequestSequence}`;
			},
			surface,
		});
		if (surface === 'fileView') {
			fileRpcClient = rpcClient;
			rpcClient.subscribe((message): void => {
				if (message.kind === 'fileDisplayPatch') latestFileDisplayEpoch = message.epoch;
			});
		}
		rpcClients.set(surface, rpcClient);
		const renderDispositionAdmission = createBridgeMainRenderDispositionAdmission({
			dispatchBatch: (receipts): string =>
				rpcClient.send(
					encodeBridgeWorkerRenderDispositionCommand({
						epoch: receipts[0]?.workerDerivationEpoch ?? 0,
						receipts,
						requestId: 'bridge-main-render-fulfillment',
					}),
				),
			lifecycleStore,
			onProbeExhausted: (): void => failRenderView(surface),
			onPublicationSettled: (settlement): void => {
				if (typeof document === 'undefined') return;
				stampBridgeRenderDispositionSettlementEvidence({
					elements: document.querySelectorAll(`[${BRIDGE_PAINTED_PUBLICATION_ID_ATTRIBUTE}]`),
					outcome: settlement.outcome,
					publicationId: settlement.publicationId,
				});
			},
			requestWorkerReplacement,
			surface,
			telemetryClient: admissionTelemetryRecorder,
		});
		const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
			sendDisposition: (receipt): void => renderDispositionAdmission.enqueue(receipt),
			sendPaintRelease: (receipt): void => renderDispositionAdmission.enqueue(receipt),
		});
		renderFulfillmentCoordinatorForStore = renderFulfillmentCoordinator;
		renderDispositionAdmissions.add(renderDispositionAdmission);
		renderFulfillmentCoordinators.add(renderFulfillmentCoordinator);
		const sendSurfaceCommand = (command: BridgeWorkerRpcCommandInput): string => {
			if (
				command.command === 'viewRecoveryRetry' &&
				command.view.kind === (surface === 'fileView' ? 'file.metadata' : 'review.metadata')
			) {
				renderDispositionAdmission.resumeAfterViewRecovery();
			}
			recordReplacementReplayEntry(command, rpcClient.send);
			return rpcClient.send(command);
		};
		surfaceClients.set(surface, {
			requestWorkerReplacement,
			lifecycle: createBridgePaneSurfaceLifecycleView({ lifecycleStore, rpcClient }),
			renderFulfillmentCoordinator,
			renderStore,
			send: sendSurfaceCommand,
			subscribeMessages: rpcClient.subscribe,
			subscribeWorkerReplacement: (listener): (() => void) => {
				workerReplacementListeners.add(listener);
				return (): void => {
					workerReplacementListeners.delete(listener);
				};
			},
			surface,
		});
	}
	session.setReplacementBootstrapExhaustionHandler?.((): void => {
		let hasRecordedView = false;
		for (const kind of [
			'file.metadata',
			'file.annotations',
			'review.metadata',
			'review.annotations',
		] as const) {
			const store = surfaceClients.get(
				bridgePaneSurfaceForViewRecoveryStatusKind(kind),
			)?.renderStore;
			const current = store?.getViewRecoveryStatus(kind);
			if (current === null || current === undefined) continue;
			hasRecordedView = true;
			workerUnavailableViews.set(kind, current.view);
			publishViewRecoveryStatus({
				direction: 'serverWorkerToMain',
				kind: 'viewRecoveryStatus',
				status: 'failedRetryable',
				transferDescriptors: [],
				view: current.view,
				wireVersion: 1,
			});
		}
		if (
			!hasRecordedView &&
			nativeBootstrapInstallAcceptedCount === 0 &&
			paneFailedStartFact === null
		) {
			paneFailedStartFact = { kind: 'failedStart', cause: 'bootstrapBudgetExhausted' };
			paneFailedStartHandler?.(paneFailedStartFact);
		}
	});
	const paneRpcClient = createBridgeWorkerRpcClient({
		dispatch: dispatcher.dispatch,
		lifecycleStore,
		requestIdFactory: (): string => {
			nextRequestSequence += 1;
			return `bridge-pane-rpc-${nextRequestSequence}`;
		},
		surface: 'pane',
	});
	rpcClients.set('pane', paneRpcClient);
	const paneClient: BridgePaneClient = {
		lifecycle: createBridgePaneSurfaceLifecycleView({ lifecycleStore, rpcClient: paneRpcClient }),
		send: (command): string => {
			recordReplacementReplayEntry(command, paneRpcClient.send);
			return paneRpcClient.send(command);
		},
		subscribeMessages: paneRpcClient.subscribe,
	};

	return {
		lifecycleStore,
		paneClient,
		dispose: (): void => {
			if (isDisposed) return;
			isDisposed = true;
			for (const coordinator of renderFulfillmentCoordinators) coordinator.dispose();
			for (const admission of renderDispositionAdmissions) admission.dispose();
			for (const client of rpcClients.values()) client.dispose();
			for (const renderStore of renderStores) renderStore.dispose();
			lifecycleStore.dispose();
			rpcClients.clear();
			renderFulfillmentCoordinators.clear();
			renderDispositionAdmissions.clear();
			surfaceClients.clear();
			renderStores.clear();
			workerReplacementListeners.clear();
			paneFailedStartHandler = null;
			dispatcher.dispose();
			session.dispose();
		},
		handleNativeBootstrapFailure: (): void => {
			if (isDisposed) return;
			session.handleNativeBootstrapFailure?.();
		},
		installNativeBootstrap: (bootstrap): void => {
			nativeBootstrapInstallAttemptCount += 1;
			const installsReplacement = nativeBootstrapReplacementRequested;
			try {
				if (isDisposed) throw new Error('Bridge pane runtime is disposed.');
				if (nativeBootstrapInstalled && !nativeBootstrapReplacementRequested) {
					throw new Error('Bridge pane runtime native capability claim was already installed.');
				}
				session.installNativeBootstrap(bootstrap);
				nativeBootstrapInstalled = true;
				nativeBootstrapReplacementRequested = false;
				nativeBootstrapInstallAcceptedCount += 1;
				if (installsReplacement) {
					for (const admission of renderDispositionAdmissions) {
						admission.resumeAfterWorkerReplacement();
					}
				}
			} catch (error: unknown) {
				nativeBootstrapInstallRejectedCount += 1;
				publishDiagnosticSnapshot();
				throw error;
			}
			publishDiagnosticSnapshot();
		},
		installTelemetryProducer: (install): void => {
			if (isDisposed) {
				install.producerPort.close();
				return;
			}
			if (session.installTelemetryProducer === undefined) {
				install.producerPort.close();
				throw new Error('Bridge pane runtime session cannot install a telemetry producer.');
			}
			session.installTelemetryProducer(install);
		},
		installMainTelemetryRecorder: (recorder): void => {
			if (isDisposed) return;
			mainTelemetryRecorder = recorder;
		},
		setNativeBootstrapRequester: (requester): void => {
			if (isDisposed) return;
			if (session.setNativeBootstrapRequester === undefined) {
				throw new Error('Bridge pane runtime session cannot install a native bootstrap requester.');
			}
			session.setNativeBootstrapRequester((reason): void => {
				if (isDisposed) return;
				prepareRuntimeForWorkerReplacement();
				requester(reason);
			});
		},
		setPaneFailedStartHandler: (handler): void => {
			if (isDisposed) return;
			paneFailedStartHandler = handler;
			if (handler !== null && paneFailedStartFact !== null) handler(paneFailedStartFact);
		},
		surfaceClient: (surface): BridgePaneSurfaceClient => {
			const client = surfaceClients.get(surface);
			if (client === undefined) throw new Error('Bridge pane runtime is disposed.');
			return client;
		},
	};
}

function bridgePaneSurfaceForViewRecoveryStatusKind(
	kind: 'file.annotations' | 'file.metadata' | 'review.annotations' | 'review.metadata',
): BridgePaneSurface {
	return kind === 'file.annotations' || kind === 'file.metadata' ? 'fileView' : 'review';
}

interface BridgePaneReplacementReplayEntry {
	readonly command: BridgeWorkerRpcCommandInput;
	readonly key: string;
	readonly priority: number;
	readonly send: (command: BridgeWorkerRpcCommandInput) => string;
}

function bridgePaneReplacementReplayIdentity(
	command: BridgeWorkerRpcCommandInput,
): Pick<BridgePaneReplacementReplayEntry, 'key' | 'priority'> | null {
	switch (command.command) {
		case 'reviewIntakeReady':
			return { key: 'review:intake-ready', priority: 0 };
		case 'activeViewerModeUpdate':
		case 'mode':
			return { key: 'pane:mode', priority: 10 };
		case 'fileQueryUpdate':
			return { key: 'file:query', priority: 20 };
		case 'reviewProjectionUpdate':
			return { key: 'review:projection', priority: 20 };
		case 'reviewPublicationInstalled':
			return { key: 'review:publication-installed', priority: 25 };
		case 'select':
			return { key: `${command.surface}:selection`, priority: 30 };
		case 'viewport':
			return { key: `${command.surface}:viewport`, priority: 40 };
		case 'metadataInterestUpdate':
			return { key: `review:interest:${command.request.lane}`, priority: 50 };
		case 'annotationCommand':
		case 'annotationOutputInspect':
		case 'annotationProjectionRetry':
		case 'viewRecoveryRetry':
		case 'fileDisplayResync':
		case 'fileRefreshRetry':
		case 'hover':
		case 'markFileViewed':
		case 'renderDisposition':
		case 'reviewComparisonTargetsQuery':
		case 'reviewComparisonTargetsQueryCancel':
		case 'reviewComparisonUpdate':
		case 'reviewInvalidate':
		case 'reviewPublicationInstallAdmit':
			return null;
		default:
			return assertNeverReplacementReplayCommand(command);
	}
}

function compareReplacementReplayEntries(
	left: BridgePaneReplacementReplayEntry,
	right: BridgePaneReplacementReplayEntry,
): number {
	return left.priority - right.priority || left.key.localeCompare(right.key);
}

function assertNeverReplacementReplayCommand(_command: never): never {
	throw new Error('Unhandled Bridge replacement replay command.');
}

function createDefaultBridgePaneSessionPort(
	props: BridgePaneCommWorkerSessionProps = {},
): BridgePaneSessionPort {
	const session = new BridgePaneCommWorkerSession({
		...props,
		recordDiagnosticSnapshot:
			props.recordDiagnosticSnapshot ?? recordBridgePaneCommWorkerSessionDiagnosticSnapshot,
	});
	const bootstrapRequest = createPaneOwnedBridgeCommWorkerBootstrapRequest();
	return {
		createDispatcher: (dispatcherProps): BridgePaneCommWorkerDispatcher =>
			session.createDispatcher({
				bootstrapRequest,
				publishWorkerMessages: dispatcherProps.publishWorkerMessages,
			}),
		dispose: (): void => session.dispose(),
		handleNativeBootstrapFailure: (): void => session.handleNativeBootstrapFailure(),
		installNativeBootstrap: (bootstrap): void => session.installNativeBootstrap(bootstrap),
		installTelemetryProducer: (install): void => session.installTelemetryProducer(install),
		requestWorkerReplacement: (reason): void => session.requestWorkerReplacement(reason),
		setNativeBootstrapRequester: (requester): void =>
			session.setNativeBootstrapRequester(requester),
		setReplacementBootstrapExhaustionHandler: (onExhausted): void =>
			session.setReplacementBootstrapExhaustionHandler(onExhausted),
		setWorkerReplacementPreparer: (prepare): void => session.setWorkerReplacementPreparer(prepare),
	};
}

function createPaneOwnedBridgeCommWorkerBootstrapRequest(): BridgeCommWorkerBootstrapRequest {
	return {
		method: 'bridgeCommWorker.bootstrap',
		requestId: 'pane-runtime-bootstrap',
		runtime: {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: bridgeWorkerPierreRenderPolicy.reviewInteractiveRenderBudget,
		},
		schemaVersion: 1,
	};
}

function createBridgePaneSurfaceLifecycleView(props: {
	readonly lifecycleStore: BridgeWorkerRpcLifecycleStore;
	readonly rpcClient: BridgeWorkerRpcClient;
}): BridgePaneSurfaceLifecycleView {
	return {
		getSnapshot: props.rpcClient.getLifecycleSnapshot,
		getServerSnapshot: props.rpcClient.getLifecycleSnapshot,
		subscribe: (listener): (() => void) => {
			let previousSnapshot = props.rpcClient.getLifecycleSnapshot();
			return props.lifecycleStore.subscribe((): void => {
				const nextSnapshot = props.rpcClient.getLifecycleSnapshot();
				if (nextSnapshot.requestsById === previousSnapshot.requestsById) return;
				if (bridgeWorkerRpcSnapshotsEqual(previousSnapshot, nextSnapshot)) return;
				previousSnapshot = nextSnapshot;
				listener();
			});
		},
	};
}

function bridgeWorkerRpcSnapshotsEqual(
	left: BridgeWorkerRpcLifecycleSnapshot,
	right: BridgeWorkerRpcLifecycleSnapshot,
): boolean {
	const leftEntries = Object.entries(left.requestsById);
	const rightEntries = Object.entries(right.requestsById);
	if (leftEntries.length !== rightEntries.length) return false;
	return leftEntries.every(([requestId, request], index): boolean => {
		const rightEntry = rightEntries[index];
		return rightEntry?.[0] === requestId && rightEntry[1] === request;
	});
}

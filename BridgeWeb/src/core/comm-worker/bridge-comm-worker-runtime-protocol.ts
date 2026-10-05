import {
	bridgeCommWorkerAnnotationCatalogStagingEvents,
	bridgeCommWorkerAnnotationProjectionConvergenceEvent,
} from './bridge-comm-worker-annotation-runtime-events.js';
import { readBridgeCommWorkerAbsoluteNowMilliseconds } from './bridge-comm-worker-clock.js';
import {
	createBridgeCommWorkerCommandHandler,
	type BridgeCommWorkerFileMetadataDemand,
	type BridgeCommWorkerFileViewRuntimeSource,
	type BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest,
} from './bridge-comm-worker-command-handler.js';
import type { BridgeCommWorkerPort } from './bridge-comm-worker-entry.js';
import { ensureBridgeCommWorkerFileMetadataInBackground } from './bridge-comm-worker-file-background-warmup.js';
import { createBridgeCommWorkerFileContentCancellation } from './bridge-comm-worker-file-content-cancellation.js';
import { BridgeCommWorkerFileDisplayEventAuthority } from './bridge-comm-worker-file-display-event-authority.js';
import {
	applyBridgeCommWorkerFileQueryUpdateCommand,
	BridgeCommWorkerFileQueryProjection,
} from './bridge-comm-worker-file-query-projection.js';
import { settleBridgeCommWorkerExhaustedFileRender } from './bridge-comm-worker-file-render-fulfillment-lifecycle.js';
import { enqueueSelectedBridgeWorkerFileViewContentReadyPreparation } from './bridge-comm-worker-file-view-preparation.js';
import { createEmptyBridgeCommWorkerFileViewRuntimeSource } from './bridge-comm-worker-file-view-runtime-source.js';
import { createBridgeCommWorkerInstalledReviewSource } from './bridge-comm-worker-installed-review-source.js';
import { bridgeWorkerNativeSurfaceSelectionRequestFromMetadataFrame } from './bridge-comm-worker-native-surface-selection.js';
import {
	BridgeCommWorkerSelectedFileLifecycleTelemetry,
	trackSelectedFilePreparationCompletion,
} from './bridge-comm-worker-operation-lifecycle.js';
import { BridgeCommWorkerPanePresentationAuthority } from './bridge-comm-worker-pane-presentation.js';
import { applyBridgeCommWorkerPostResponseOwnerEffects } from './bridge-comm-worker-post-response-owner-effects.js';
import { drainBridgeCommWorkerPreparations } from './bridge-comm-worker-preparation-drain.js';
import { installBridgeCommWorkerProductBatchRuntime } from './bridge-comm-worker-product-batch-runtime-install.js';
import { callCurrentFileSourceWithTelemetry } from './bridge-comm-worker-product-control-runtime.js';
import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import {
	BridgeCommWorkerRenderFulfillmentLifecycleDriver,
	type BridgeCommWorkerRenderFulfillmentSurface,
} from './bridge-comm-worker-render-fulfillment-lifecycle-driver.js';
import {
	bridgeWorkerComparisonTargetsContentOpen,
	createBridgeWorkerComparisonTargetsQueryRunner,
	settleBridgeWorkerComparisonTargetsControlRequest,
} from './bridge-comm-worker-review-comparison-target-query.js';
import { createBridgeCommWorkerReviewDemandScheduling } from './bridge-comm-worker-review-demand-scheduling.js';
import {
	BridgeCommWorkerReviewDisplayLifecyclePublisher,
	BridgeCommWorkerReviewOperationLifecycleTelemetry,
} from './bridge-comm-worker-review-operation-lifecycle.js';
import { BridgeCommWorkerReviewQueryProjection } from './bridge-comm-worker-review-query-projection.js';
import { createBridgeCommWorkerReviewRenderPublicationAuthority } from './bridge-comm-worker-review-render-publication-authority.js';
import {
	bridgeCommWorkerSemanticClassForMessage,
	bridgeCommWorkerTelemetryLaneForMessage,
} from './bridge-comm-worker-runtime-command-routing.js';
import {
	publishBridgeCommWorkerPostCommitFailureBestEffort,
	resolveBridgeCommWorkerFileContentOpen,
	resolveBridgeCommWorkerPreparationPump,
	resolveBridgeCommWorkerReviewContentOpen,
	rejectUninstalledBridgeProductControl,
	scheduleDefaultBridgeRenderFulfillmentWake,
} from './bridge-comm-worker-runtime-defaults.js';
import {
	bridgeWorkerRuntimeMessagesContainReadyRequest,
	buildBridgeWorkerFileMetadataFailureHealthEvent,
	buildBridgeWorkerFileMetadataInterestFailureHealthEvent,
	buildBridgeWorkerRuntimeDegradedHealthEvent,
} from './bridge-comm-worker-runtime-health.js';
import { dispatchBridgeCommWorkerRuntimeProductControl } from './bridge-comm-worker-runtime-product-control-dispatch.js';
import type {
	BridgeCommWorkerPreparationDrain,
	RegisterBridgeCommWorkerRuntimePortProtocolProps,
} from './bridge-comm-worker-runtime-protocol-contracts.js';
import {
	bridgeProductMetadataStreamHealthDiagnostic,
	createBridgeWorkerRuntimeSequenceCounter,
	readBridgeCommWorkerRuntimeNowMilliseconds,
	scheduleDefaultBridgeCommWorkerPreparationDrain,
} from './bridge-comm-worker-runtime-support.js';
import {
	BridgeCommWorkerSelectedFileContentOperationController,
	settleAcceptedSelectedFileRenderDisposition,
	settleSelectedFileDescriptorWaitAtMetadataTerminal,
} from './bridge-comm-worker-selected-file-content-operation.js';
import type { BridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import {
	bridgeCommWorkerComparisonTelemetryFacts,
	recordBridgeCommWorkerPanePresentationTelemetry,
	recordBridgeCommWorkerTaskTelemetry,
} from './bridge-comm-worker-telemetry.js';
import { retryBridgeCommWorkerViewDependencies } from './bridge-comm-worker-view-recovery-retry.js';
import { bridgeProductStreamHealthEvent } from './bridge-product-stream-health-event.js';
import { recordBridgeWorkerOutstandingPublicationTelemetry } from './bridge-render-disposition-telemetry.js';
import {
	isBridgeWorkerFileViewContentMetadata,
	bridgeWorkerMainToServerMessageSchema,
	bridgeWorkerAnnotationProjectionConvergenceEventSchema,
	type BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

export type {
	BridgeCommWorkerPreparationDrain,
	BridgeCommWorkerProductControlSender,
	RegisterBridgeCommWorkerRuntimePortProtocolProps,
} from './bridge-comm-worker-runtime-protocol-contracts.js';
export function registerBridgeCommWorkerRuntimePortProtocol(
	port: BridgeCommWorkerPort,
	props: RegisterBridgeCommWorkerRuntimePortProtocolProps,
): void {
	const createSequence = props.createSequence ?? createBridgeWorkerRuntimeSequenceCounter();
	const pump = resolveBridgeCommWorkerPreparationPump(props);
	const schedulePreparationDrain =
		props.schedulePreparationDrain ?? scheduleDefaultBridgeCommWorkerPreparationDrain;
	const scheduleRenderFulfillmentWake =
		props.scheduleRenderFulfillmentWake ?? scheduleDefaultBridgeRenderFulfillmentWake;
	let sendProductControl = props.sendProductControl ?? rejectUninstalledBridgeProductControl;
	const productTransport = props.productTransport;
	const openFileViewContent = resolveBridgeCommWorkerFileContentOpen(props);
	const openReviewContent = resolveBridgeCommWorkerReviewContentOpen(props);
	const openComparisonTargetsContent = bridgeWorkerComparisonTargetsContentOpen(productTransport);
	const productControlTimeoutMilliseconds = props.productControlTimeoutMilliseconds ?? 5000;
	const preparationCompletions: Promise<void>[] = [];
	let drainScheduled = false;
	let shouldRequestDrainAfterMessage = false;
	let advanceRenderFulfillmentLifecycle = (
		_surface: BridgeCommWorkerRenderFulfillmentSurface,
	): void => {};
	let activeComparisonTargetsProductControlRequestId: string | null = null;
	const panePresentationAuthority = new BridgeCommWorkerPanePresentationAuthority();
	const comparisonTargetsQueryRunner = createBridgeWorkerComparisonTargetsQueryRunner({
		getWorkAdmission: () => ({
			generation: panePresentationAuthority.snapshot.workAdmissionGeneration,
			signal: panePresentationAuthority.workSignal,
		}),
		isCurrentWorkAdmission: (generation): boolean =>
			panePresentationAuthority.isCurrentWorkAdmission(generation),
		onSettled: (requestId): void => {
			activeComparisonTargetsProductControlRequestId =
				settleBridgeWorkerComparisonTargetsControlRequest(
					activeComparisonTargetsProductControlRequestId,
					requestId,
				);
		},
		openContent: openComparisonTargetsContent,
		publish: (event): void => port.postMessage(event),
	});
	let fileViewRuntimeSource: BridgeCommWorkerFileViewRuntimeSource =
		createEmptyBridgeCommWorkerFileViewRuntimeSource();
	const fileContentCancellation = createBridgeCommWorkerFileContentCancellation();
	const fileContentAbortControllersByItemId = fileContentCancellation.abortControllersByItemId;
	const fileContentPreparationGenerationByItemId = fileContentCancellation.generationByItemId;
	let latestSelectedFilePreparationRequest: BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest | null =
		null;
	const runtimeTelemetryClient = props.telemetryClient;
	const selectedFileContentOperationController =
		new BridgeCommWorkerSelectedFileContentOperationController({
			...(props.now === undefined ? {} : { now: props.now }),
			...(runtimeTelemetryClient === undefined
				? {}
				: {
						observeOutstandingPublications: (observation): void => {
							recordBridgeWorkerOutstandingPublicationTelemetry({
								observation,
								surface: 'file',
								telemetryClient: runtimeTelemetryClient,
							});
						},
					}),
		});
	let selectedFileContentOperationStore: BridgeCommWorkerStore | null = null;
	const selectedFileLifecycleTelemetry = new BridgeCommWorkerSelectedFileLifecycleTelemetry(
		props.telemetryClient,
	);
	const cancelSelectedFileContentOperation = (): void => {
		const operation = selectedFileContentOperationController.cancel();
		if (operation !== null) selectedFileLifecycleTelemetry.cancelled(operation);
	};
	const retriedSelectedFilePreparationRequests =
		new WeakSet<BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest>();
	const abortFileContentPreparation = fileContentCancellation.abort;
	const abortAllFileContentPreparations = fileContentCancellation.abortAll;
	let activeFileWorkerDerivationEpoch: number | null = null;
	let hasAcceptedFileSource = false;
	let activeReviewWorkerDerivationEpoch: number | null = null;
	const reviewOperationLifecycleTelemetry = new BridgeCommWorkerReviewOperationLifecycleTelemetry(
		props.telemetryClient,
	);
	let activeViewerMode: 'file' | 'review' | null = null;
	let admittedViewerMode: 'file' | 'review' | null = null;
	const reviewRenderPublicationAuthority = createBridgeCommWorkerReviewRenderPublicationAuthority({
		activeFileWorkerDerivationEpoch: () => activeFileWorkerDerivationEpoch,
		activeReviewWorkerDerivationEpoch: () => activeReviewWorkerDerivationEpoch,
		activeViewerMode: () => activeViewerMode,
		currentReviewWorkerDerivationEpoch: () =>
			productTransport?.workerDerivationEpoch('review') ?? null,
		readReviewDisplayPublisher: () => reviewDisplayLifecyclePublisher,
		createSequence,
		publish: (message): void => port.postMessage(message),
		telemetryClient: props.telemetryClient,
	});
	const publishUpdatingChrome = (): void =>
		reviewRenderPublicationAuthority.publishUpdatingChrome(panePresentationAuthority.snapshot);
	const fileDisplayEventAuthority = new BridgeCommWorkerFileDisplayEventAuthority({
		createSequence,
	});
	const reviewQueryProjection = new BridgeCommWorkerReviewQueryProjection();
	const reviewDisplayLifecyclePublisher = new BridgeCommWorkerReviewDisplayLifecyclePublisher({
		createSequence,
		lifecycle: reviewOperationLifecycleTelemetry,
		onReviewComparison: (reviewComparison, workerDerivationEpoch, isUpdatingReview): void => {
			reviewRenderPublicationAuthority.recordReviewComparison(
				reviewComparison,
				workerDerivationEpoch,
				isUpdatingReview,
			);
		},
		onSourceIdentity: (sourceIdentity): void => {
			reviewRenderPublicationAuthority.recordReviewSourceIdentity(sourceIdentity);
		},
		panePresentationAuthority,
		postMessage: (message): void => port.postMessage(message),
		queryProjection: reviewQueryProjection,
		readActiveViewerMode: (): 'file' | 'review' | null => activeViewerMode,
	});
	const postReviewDisplayPatches = (
		publication: Parameters<typeof reviewDisplayLifecyclePublisher.post>[0],
	): void => {
		reviewRenderPublicationAuthority.recordReviewPublicationIdentity(
			publication.reviewPublicationIdentity,
		);
		reviewDisplayLifecyclePublisher.post(publication);
	};
	const publishReviewDisplayPatches = (
		publication: Parameters<typeof reviewDisplayLifecyclePublisher.publish>[0],
	): void => {
		reviewRenderPublicationAuthority.recordReviewPublicationIdentity(
			publication.reviewPublicationIdentity,
		);
		reviewDisplayLifecyclePublisher.publish(publication);
	};
	const fileQueryProjection = new BridgeCommWorkerFileQueryProjection();
	let updateFileMetadataDemand: ((demand: BridgeCommWorkerFileMetadataDemand) => void) | null =
		null;
	let currentFileMetadataSelectedPath: string | null | undefined;
	let productController: BridgeCommWorkerProductController | null = null;
	let productBatchApplication: ReturnType<
		typeof installBridgeCommWorkerProductBatchRuntime
	> | null = null;
	let currentFileSourceWarmupKey: string | null = null;
	let releasedReviewWarmupKey: string | null = null;
	let reviewWarmupInFlightKey: string | null = null;
	const startFileMetadataInBackground = (): void =>
		ensureBridgeCommWorkerFileMetadataInBackground({
			controller: productController,
			productTransport,
			publish: (message): void => port.postMessage(message),
		});
	const requestReviewBackgroundWarmup = (warmupKey: string): void => {
		const controller = productController;
		if (
			controller === null ||
			admittedViewerMode !== 'file' ||
			releasedReviewWarmupKey === warmupKey ||
			reviewWarmupInFlightKey === warmupKey
		) {
			return;
		}
		reviewWarmupInFlightKey = warmupKey;
		void controller
			.sendProductControl({
				method: 'bridge.intakeReady',
				params: {
					protocolId: 'review',
					reason: 'background-warmup',
					streamId: null,
				},
			})
			.then((): void => {
				if (reviewWarmupInFlightKey !== warmupKey) return;
				reviewWarmupInFlightKey = null;
				releasedReviewWarmupKey = warmupKey;
			})
			.catch((): void => {
				if (reviewWarmupInFlightKey === warmupKey) {
					reviewWarmupInFlightKey = null;
				}
			});
	};
	const installedReviewSource = createBridgeCommWorkerInstalledReviewSource(
		() => productController,
	);
	const drainPreparation: BridgeCommWorkerPreparationDrain = async () => {
		drainScheduled = false;
		return await drainBridgeCommWorkerPreparations({
			advanceRenderFulfillmentLifecycle,
			pendingCompletions: preparationCompletions,
			pump,
			requestPreparationDrain,
		});
	};
	const requestPreparationDrain = (): void => {
		if (drainScheduled) {
			return;
		}
		drainScheduled = true;
		schedulePreparationDrain(drainPreparation);
	};
	const reviewDemandScheduling = createBridgeCommWorkerReviewDemandScheduling({
		bridgeDemandRank: props.bridgeDemandRank,
		budget: props.budget,
		createSequence,
		isWorkAdmitted: (): boolean => panePresentationAuthority.admitsWork,
		markPreparationDrainRequired: (): void => {
			shouldRequestDrainAfterMessage = true;
		},
		...(props.now === undefined ? {} : { now: props.now }),
		operationCorrelationId: (): string | null =>
			reviewOperationLifecycleTelemetry.currentOperationCorrelationId,
		...(openReviewContent === undefined ? {} : { openReviewContent }),
		port,
		pump,
		recordPreparationCompletion: (completion: Promise<void>): void => {
			preparationCompletions.push(completion);
		},
		replaceReviewMetadataInterests: (snapshot): Promise<void> => {
			const controller = productController;
			if (controller === null) {
				return Promise.reject(
					new Error('Bridge Review demand interests have no installed product controller.'),
				);
			}
			return controller.replaceReviewMetadataInterestsFromActiveDemand(snapshot);
		},
		requestPreparationDrain,
		...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
		usesProductTransport: productTransport !== undefined,
		workSignal: (): AbortSignal => panePresentationAuthority.workSignal,
	});
	const publishReviewMetadataPostCommitFailure = (): void =>
		publishBridgeCommWorkerPostCommitFailureBestEffort((): void => {
			port.postMessage(buildBridgeWorkerRuntimeDegradedHealthEvent());
		});
	const scheduleSelectedFileViewContentReadyPreparation = (
		request: BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest,
	): void => {
		const selectedState = request.store.getState();
		if (selectedState.selectedId !== request.itemId) return;
		const previousOperation = selectedFileContentOperationController.current;
		latestSelectedFilePreparationRequest = request;
		if (
			previousOperation !== null &&
			previousOperation.renderReceiptIdentity !== null &&
			(previousOperation.itemId !== request.itemId ||
				previousOperation.selectionEpoch !== selectedState.selectedEpoch)
		) {
			return;
		}
		const selectedOperation = selectedFileContentOperationController.admitSelection({
			itemId: request.itemId,
			selectionEpoch: selectedState.selectedEpoch,
		});
		if (previousOperation?.generation !== selectedOperation.generation) {
			if (previousOperation !== null) {
				selectedFileLifecycleTelemetry.cancelled(previousOperation);
			}
			selectedFileLifecycleTelemetry.admitted(selectedOperation);
			abortAllFileContentPreparations();
			selectedFileContentOperationStore = request.store;
		}
		if (!panePresentationAuthority.admitsWork || activeViewerMode !== 'file') return;
		const workerDerivationEpoch = activeFileWorkerDerivationEpoch;
		if (workerDerivationEpoch === null) return;
		const sourceBoundOperation = selectedFileContentOperationController.bindSource({
			generation: selectedOperation.generation,
			workerDerivationEpoch,
		});
		if (sourceBoundOperation === null) return;
		if (sourceBoundOperation.generation !== selectedOperation.generation) {
			abortAllFileContentPreparations();
		}
		const contentRequest = fileViewRuntimeSource.contentRequestsByItemId?.get(request.itemId);
		if (fileContentCancellation.retainOrSupersede(request.itemId, contentRequest, request.epoch))
			return;
		const metadata = selectedState.contentMetadataByItemId.get(request.itemId) ?? null;
		if (!isBridgeWorkerFileViewContentMetadata(metadata) || contentRequest === undefined) return;
		selectedFileLifecycleTelemetry.descriptorReady(sourceBoundOperation);
		selectedFileContentOperationController.advance(
			sourceBoundOperation.generation,
			'preparingContent',
		);
		abortAllFileContentPreparations();
		const abortController = new AbortController();
		fileContentAbortControllersByItemId.set(request.itemId, abortController);
		const preparationGeneration =
			(fileContentPreparationGenerationByItemId.get(request.itemId) ?? 0) + 1;
		fileContentPreparationGenerationByItemId.set(request.itemId, preparationGeneration);
		const ticket = enqueueSelectedBridgeWorkerFileViewContentReadyPreparation({
			bridgeDemandRank: props.fileViewBridgeDemandRank ?? props.bridgeDemandRank,
			budget: props.fileViewBudget ?? props.budget,
			contentRequestsByItemId: fileViewRuntimeSource.contentRequestsByItemId ?? new Map(),
			epoch: request.epoch,
			itemId: request.itemId,
			isPreparationCurrent: () =>
				panePresentationAuthority.admitsWork &&
				fileContentPreparationGenerationByItemId.get(request.itemId) === preparationGeneration,
			onPreparationOutcome: (outcome): void => {
				if (
					selectedFileLifecycleTelemetry.handlePreparationOutcome({
						controller: selectedFileContentOperationController,
						operation: sourceBoundOperation,
						outcome,
					})
				) {
					selectedFileContentOperationStore = null;
				}
			},
			openContent: openFileViewContent,
			operationCorrelationId: sourceBoundOperation.operationCorrelationId,
			port,
			pump,
			requestPreparationDrain,
			sequence: createSequence(),
			signal: abortController.signal,
			store: request.store,
			workerDerivationEpoch,
		});
		if (ticket.enqueued) {
			const cancellationCompletion = fileContentCancellation.trackSettlement({
				request: contentRequest,
				abortController,
				completion: ticket.completion,
				demandEpoch: request.epoch,
				itemId: request.itemId,
				onSupersessionSettled: (): void => {
					resumeLatestSelectedFileViewContentReadyPreparation();
					requestPreparationDrain();
				},
			});
			const trackedCompletion = trackSelectedFilePreparationCompletion({
				abortController,
				abortControllerByItemId: fileContentAbortControllersByItemId,
				completion: cancellationCompletion,
				isPaneWorkAdmitted: (): boolean => panePresentationAuthority.admitsWork,
				isRequestLatest: (): boolean => latestSelectedFilePreparationRequest === request,
				onClearLatest: (): void => {
					latestSelectedFilePreparationRequest = null;
				},
				request,
				requestDrain: requestPreparationDrain,
				retriedRequests: retriedSelectedFilePreparationRequests,
				retry: (): void => scheduleSelectedFileViewContentReadyPreparation(request),
			});
			preparationCompletions.push(trackedCompletion);
			shouldRequestDrainAfterMessage = true;
		} else {
			fileContentAbortControllersByItemId.delete(request.itemId);
		}
	};
	const resumeLatestSelectedFileViewContentReadyPreparation = (): void => {
		const latestFileRequest = latestSelectedFilePreparationRequest;
		if (latestFileRequest === null) return;
		if (latestFileRequest.store.getState().selectedId !== latestFileRequest.itemId) return;
		scheduleSelectedFileViewContentReadyPreparation(latestFileRequest);
	};
	const handler = createBridgeCommWorkerCommandHandler({
		contentItems: [],
		contentRequestDescriptors: [],
		renderSemantics: [],
		reviewPublicationIdentity: null,
		rows: [],
		createSequence,
		...(props.now === undefined ? {} : { renderFulfillmentNow: props.now }),
		...(props.renderFulfillmentContext === undefined
			? {}
			: { renderFulfillmentContext: props.renderFulfillmentContext }),
		...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
		onReviewMetadataPostCommitFailure: publishReviewMetadataPostCommitFailure,
		onReviewVisibleRenderExhausted: (): void => productTransport?.failReviewRender?.(),
		onFileVisibleRenderExhausted: (itemIds, store): void => {
			if (
				settleBridgeCommWorkerExhaustedFileRender({
					controller: selectedFileContentOperationController,
					createSequence,
					itemIds,
					port,
					store,
					telemetry: selectedFileLifecycleTelemetry,
				})
			)
				selectedFileContentOperationStore = null;
			productTransport?.failFileRender?.();
		},
		scheduleSelectedReviewContentReadyPreparation:
			reviewDemandScheduling.scheduleSelectedContentReadyPreparation,
		scheduleReviewMetadataReset: reviewDemandScheduling.scheduleMetadataReset,
		releaseExpiredReviewPublication: reviewDemandScheduling.releaseExpiredPublication,
		scheduleSelectedFileViewContentReadyPreparation,
		scheduleDemandExecution: (request): void => {
			shouldRequestDrainAfterMessage =
				reviewDemandScheduling.scheduleDemandExecution(request) || shouldRequestDrainAfterMessage;
		},
		updateReviewRuntimeSource: reviewDemandScheduling.updateRuntimeSource,
		updateReviewDisplayProjection: (command) => {
			const patches = reviewQueryProjection.updateQuery(command.query);
			if (patches.length > 0) {
				postReviewDisplayPatches({
					patches,
					workerDerivationEpoch: activeReviewWorkerDerivationEpoch ?? command.epoch,
				});
			}
			return [];
		},
		updateFileViewRuntimeSource: (source: BridgeCommWorkerFileViewRuntimeSource): void => {
			fileViewRuntimeSource = source;
		},
		updateFileMetadataDemand: (demand): void => {
			currentFileMetadataSelectedPath = demand.selectedPath;
			updateFileMetadataDemand?.(demand);
		},
		...(props.productTransport === undefined
			? {}
			: {
					requestFileDisplayResync: () => {
						const workerDerivationEpoch = activeFileWorkerDerivationEpoch;
						return workerDerivationEpoch === null
							? [buildBridgeWorkerFileMetadataFailureHealthEvent()]
							: fileDisplayEventAuthority.publish({
									epoch: workerDerivationEpoch,
									patches: fileQueryProjection.snapshotDisplayPatches(),
								});
					},
					updateFileDisplayQuery: (command) =>
						applyBridgeCommWorkerFileQueryUpdateCommand({
							command,
							eventAuthority: fileDisplayEventAuthority,
							getWorkerDerivationEpoch: () => activeFileWorkerDerivationEpoch ?? 0,
							projection: fileQueryProjection,
							publishMessages: (messages): void => {
								for (const message of messages) port.postMessage(message);
							},
						}),
				}),
		retryAnnotationProjection: (surface): void => {
			productController?.retryAnnotationProjection(surface);
		},
		retryView: (view): void => {
			const viewRetry = productTransport?.retryView?.(view.subscriptionId) ?? Promise.resolve();
			void Promise.all([
				viewRetry,
				retryBridgeCommWorkerViewDependencies(productController, view.kind),
			]).catch((): void => {
				port.postMessage({
					direction: 'serverWorkerToMain',
					kind: 'viewRecoveryStatus',
					status: 'failedRetryable',
					transferDescriptors: [],
					view,
					wireVersion: 1,
				});
				port.postMessage(buildBridgeWorkerRuntimeDegradedHealthEvent());
			});
		},
	});
	if (productTransport !== undefined) {
		productBatchApplication = installBridgeCommWorkerProductBatchRuntime({
			applyCommentCatalog: (catalog, surface): void => {
				productController?.acceptInstalledCommentCatalog(catalog, surface);
			},
			applyFileRuntimeMutation: (epoch, mutation) =>
				handler.applyFileViewRuntimeMutation({ epoch, mutation }),
			prepareReviewRuntimeApplication: (application) => {
				let messages: readonly BridgeWorkerServerToMainMessage[] = [];
				const transaction = reviewOperationLifecycleTelemetry.wrapApplication(application, () =>
					(() => {
						const prepared = handler.prepareReviewMetadataApplication(application);
						messages = prepared.messages;
						return prepared;
					})(),
				);
				return {
					commit: transaction.commit,
					messages,
					rollback: transaction.rollback,
					runPostCommitEffects: transaction.runPostCommitEffects,
				};
			},
			beforeApplyFile: (view): void => {
				// Source mutation can schedule selected content before didInstallFile runs.
				activeFileWorkerDerivationEpoch = productTransport.workerDerivationEpoch('file');
				const source = view.memberStatus.source;
				const warmupKey = `${source.sourceId}:${source.subscriptionGeneration.toString()}`;
				if (currentFileSourceWarmupKey !== warmupKey) {
					const replacesAcceptedSource = hasAcceptedFileSource;
					currentFileSourceWarmupKey = warmupKey;
					abortAllFileContentPreparations();
					if (replacesAcceptedSource) {
						cancelSelectedFileContentOperation();
						selectedFileContentOperationStore = null;
					}
				}
				const mutation = view.runtimeMutation;
				if (mutation?.kind === 'delta') {
					for (const itemId of mutation.contentRequestRemovals) {
						abortFileContentPreparation(itemId);
					}
					for (const request of mutation.contentRequestUpserts) {
						abortFileContentPreparation(request.itemId);
					}
				}
			},
			didInstallFile: (view, begin, certified): void => {
				const workerDerivationEpoch = productTransport.workerDerivationEpoch('file');
				productController?.acceptInstalledFileBatch({
					certified,
					source: view.memberStatus.source,
					subscriptionId: begin.subscriptionId,
					workerDerivationEpoch,
				});
				productController?.refreshInstalledFileAnnotationPlacement();
				hasAcceptedFileSource = true;
				publishUpdatingChrome();
				if (
					currentFileSourceWarmupKey !== null &&
					(view.contentRequests.some(
						(request) => request.path === currentFileMetadataSelectedPath,
					) ||
						view.displayTreeRows.length === 0)
				) {
					requestReviewBackgroundWarmup(currentFileSourceWarmupKey);
				}
				if (view.runtimeMutation?.kind === 'reset') {
					resumeLatestSelectedFileViewContentReadyPreparation();
				}
				if (pump.getPendingWorkIds().length > 0) requestPreparationDrain();
			},
			didInstallReview: (_presentation, begin): void => {
				activeReviewWorkerDerivationEpoch = productTransport.workerDerivationEpoch('review');
				reviewDemandScheduling.updateWorkerDerivationEpoch(activeReviewWorkerDerivationEpoch);
				productController?.acceptInstalledReviewBatch({
					subscriptionId: begin.subscriptionId,
					workerDerivationEpoch: activeReviewWorkerDerivationEpoch,
				});
				startFileMetadataInBackground();
			},
			fileDisplayAuthority: fileDisplayEventAuthority,
			fileQueryProjection,
			createSequence,
			productTransport,
			publishMessage: (message): void => port.postMessage(message),
			publishReviewDisplay: publishReviewDisplayPatches,
			reportResnapshotFailure: (): void =>
				port.postMessage(buildBridgeWorkerRuntimeDegradedHealthEvent()),
			reportReviewPostCommitFailure: publishReviewMetadataPostCommitFailure,
		});
	}
	const renderFulfillmentLifecycleDriver = new BridgeCommWorkerRenderFulfillmentLifecycleDriver({
		advanceBySurface: {
			file: handler.advanceFileRenderFulfillmentLifecycle,
			review: handler.advanceReviewRenderFulfillmentLifecycle,
		},
		needsPreparationDrain: (): boolean =>
			shouldRequestDrainAfterMessage || pump.getPendingWorkIds().length > 0,
		now: props.now ?? readBridgeCommWorkerAbsoluteNowMilliseconds,
		requestPreparationDrain,
		scheduleWake: scheduleRenderFulfillmentWake,
	});
	advanceRenderFulfillmentLifecycle = (surface): void =>
		renderFulfillmentLifecycleDriver.advance(surface);
	if (productTransport !== undefined) {
		productTransport.setMetadataStreamHealthSink?.((observation): void => {
			port.postMessage(bridgeProductStreamHealthEvent(observation));
		});
		productTransport.setPaneSurfaceSelectionFrameSink?.((frame): void => {
			port.postMessage(bridgeWorkerNativeSurfaceSelectionRequestFromMetadataFrame(frame));
		});
		productTransport.setPanePresentationFrameSink?.((frame): void => {
			const wasRefreshingFile = panePresentationAuthority.snapshot.refreshingLanes.includes('file');
			const application = panePresentationAuthority.apply(frame);
			recordBridgeCommWorkerPanePresentationTelemetry({
				...bridgeCommWorkerComparisonTelemetryFacts(application.snapshot),
				disposition:
					application.disposition === 'idempotentReplay' ? 'idempotent_replay' : 'applied',
				phase: 'pane_presentation_applied',
				presentationRevision: application.snapshot.presentationRevision,
				refreshingReview: application.snapshot.refreshingLanes.includes('review'),
				telemetryClient: props.telemetryClient,
			});
			const fileRefreshSettled =
				wasRefreshingFile &&
				application.snapshot.nativeActivity === 'foreground' &&
				!application.snapshot.refreshingLanes.includes('file');
			if (application.leftForeground) {
				if (activeComparisonTargetsProductControlRequestId !== null) {
					comparisonTargetsQueryRunner.fail(activeComparisonTargetsProductControlRequestId);
				}
				comparisonTargetsQueryRunner.abort();
				activeComparisonTargetsProductControlRequestId = null;
				abortAllFileContentPreparations();
				cancelSelectedFileContentOperation();
				selectedFileContentOperationStore = null;
				reviewDemandScheduling.suspend();
			}
			if (application.enteredForeground) {
				if (activeViewerMode === 'review') reviewDemandScheduling.resume();
				if (activeViewerMode === 'file') {
					resumeLatestSelectedFileViewContentReadyPreparation();
				}
			}
			if (fileRefreshSettled) {
				void productController?.ensureFileSource().catch((): void => {});
				const descriptorWaitOperation = selectedFileContentOperationController.current;
				const settlement = settleSelectedFileDescriptorWaitAtMetadataTerminal({
					activeWorkerDerivationEpoch: activeFileWorkerDerivationEpoch,
					controller: selectedFileContentOperationController,
					createSequence,
					fileViewRuntimeSource,
					request: latestSelectedFilePreparationRequest,
				});
				if (settlement.terminalPatch !== null) port.postMessage(settlement.terminalPatch);
				if (settlement.settled) {
					if (descriptorWaitOperation !== null) {
						selectedFileLifecycleTelemetry.descriptorMissing(descriptorWaitOperation);
					}
					latestSelectedFilePreparationRequest = null;
					selectedFileContentOperationStore = null;
				}
			}
			publishUpdatingChrome();
		});
		const installedProductController = new BridgeCommWorkerProductController({
			...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
			callCurrentFileSource: () =>
				callCurrentFileSourceWithTelemetry({
					productTransport,
					...(props.now === undefined ? {} : { now: props.now }),
					...(props.telemetryClient === undefined
						? {}
						: { telemetryClient: props.telemetryClient }),
				}),
			onActiveViewerModeAdmitted: (mode): void => {
				admittedViewerMode = mode;
			},
			onAnnotationCatalog: (publication): void => {
				for (const message of bridgeCommWorkerAnnotationCatalogStagingEvents({
					catalog: publication.catalog,
					surface: publication.surface,
				})) {
					port.postMessage(message);
				}
			},
			onAnnotationProjectionConvergence: ({ operationCorrelationId, state, surface }): void => {
				port.postMessage(
					bridgeWorkerAnnotationProjectionConvergenceEventSchema.parse(
						bridgeCommWorkerAnnotationProjectionConvergenceEvent({
							operationCorrelationId,
							state,
							surface,
						}),
					),
				);
			},
			onFileMetadataDemandFailure: (): void => {
				port.postMessage(buildBridgeWorkerFileMetadataInterestFailureHealthEvent());
			},
			onFileSourceUnavailable: (): void => {
				const displayProjection = fileQueryProjection.applyDisplayPatches([
					{ operation: 'upsert', payload: { state: 'noSource' }, slice: 'fileStatus' },
				]);
				for (const message of fileDisplayEventAuthority.publish({
					epoch: productTransport.workerDerivationEpoch('file'),
					patches: displayProjection.patches,
				}))
					port.postMessage(message);
				requestReviewBackgroundWarmup('file-source-unavailable');
			},
			onFileMetadataFailure: (_error, workerDerivationEpoch): void => {
				activeFileWorkerDerivationEpoch = null;
				productController?.setAnnotationProjectionSourceUnavailable('file', _error);
				publishUpdatingChrome();
				abortAllFileContentPreparations();
				cancelSelectedFileContentOperation();
				selectedFileContentOperationStore = null;
				latestSelectedFilePreparationRequest = null;
				// A failed delivery retires preparation authority, not the last complete display.
				const displayProjection = fileQueryProjection.applyDisplayPatches([
					{ operation: 'upsert', payload: { state: 'failed' }, slice: 'fileStatus' },
				]);
				for (const message of fileDisplayEventAuthority.publish({
					epoch: workerDerivationEpoch,
					patches: displayProjection.patches,
				})) {
					port.postMessage(message);
				}
				requestReviewBackgroundWarmup(
					currentFileSourceWarmupKey ?? `file-metadata-failure:${workerDerivationEpoch.toString()}`,
				);
				port.postMessage(
					buildBridgeWorkerFileMetadataFailureHealthEvent(
						bridgeProductMetadataStreamHealthDiagnostic(productTransport),
					),
				);
			},
			onReviewMetadataFailure: (_error, workerDerivationEpoch): void => {
				installedReviewSource.handleMetadataFailure(_error);
				publishUpdatingChrome();
				const failureDisposition =
					productBatchApplication?.handleMetadataFailure(workerDerivationEpoch) ?? 'noActive';
				if (failureDisposition === 'noActive') {
					publishReviewDisplayPatches({
						patches: [
							{
								operation: 'failed',
								payload: { error: 'metadataUnavailable', status: 'failed' },
								slice: 'reviewSource',
							},
						],
						workerDerivationEpoch,
					});
				}
				startFileMetadataInBackground();
			},
			onReviewWorkerDerivationEpochChanged: (workerDerivationEpoch): void => {
				activeReviewWorkerDerivationEpoch = workerDerivationEpoch;
				reviewDemandScheduling.updateWorkerDerivationEpoch(workerDerivationEpoch);
			},
			productTransport,
		});
		productController = installedProductController;
		try {
			installedProductController.ensureAnnotationSubscriptions();
		} catch {
			port.postMessage(buildBridgeWorkerRuntimeDegradedHealthEvent());
		}
		updateFileMetadataDemand = (demand): void => {
			void installedProductController.updateFileMetadataDemand(demand).catch((): void => {});
		};
		if (props.sendProductControl === undefined) {
			sendProductControl = (command): Promise<unknown> =>
				installedProductController.sendProductControl(command);
		}
	}
	port.addEventListener('message', (event: MessageEvent<unknown>): void => {
		const parsedMessage = bridgeWorkerMainToServerMessageSchema.safeParse(event.data);
		if (!parsedMessage.success) {
			port.postMessage(buildBridgeWorkerRuntimeDegradedHealthEvent());
			return;
		}

		shouldRequestDrainAfterMessage = false;
		currentFileMetadataSelectedPath = undefined;
		const handlerStartedAtMilliseconds = readBridgeCommWorkerRuntimeNowMilliseconds(props.now);
		const queueWaitMilliseconds =
			handlerStartedAtMilliseconds -
			(parsedMessage.data.issuedAtMilliseconds ?? handlerStartedAtMilliseconds);
		const renderDispositionApplication =
			parsedMessage.data.command === 'renderDisposition'
				? handler.applyRenderDispositionCommand(parsedMessage.data)
				: null;
		const messages =
			renderDispositionApplication?.messages ?? handler.handleMessage(parsedMessage.data);
		if (parsedMessage.data.command === 'viewport' && parsedMessage.data.surface === 'review') {
			advanceRenderFulfillmentLifecycle('review');
		}
		if (parsedMessage.data.command === 'reviewPublicationInstalled') {
			installedReviewSource.recordInstallation(parsedMessage.data);
		}
		if (
			parsedMessage.data.command === 'select' &&
			parsedMessage.data.surface === 'fileView' &&
			parsedMessage.data.selectedItemId === null
		) {
			abortAllFileContentPreparations();
			latestSelectedFilePreparationRequest = null;
			cancelSelectedFileContentOperation();
			selectedFileContentOperationStore = null;
		}
		if (parsedMessage.data.command === 'reviewComparisonTargetsQueryCancel') {
			if (activeComparisonTargetsProductControlRequestId === parsedMessage.data.queryRequestId) {
				comparisonTargetsQueryRunner.abort();
				activeComparisonTargetsProductControlRequestId = null;
			}
		}
		if (
			parsedMessage.data.command === 'activeViewerModeUpdate' &&
			bridgeWorkerRuntimeMessagesContainReadyRequest({
				messages,
				requestId: parsedMessage.data.requestId,
			})
		) {
			const activeSource = parsedMessage.data.update.activeSource;
			admittedViewerMode = parsedMessage.data.update.mode;
			productController?.setAnnotationProjectionSurfaceActive(
				'file',
				parsedMessage.data.update.mode === 'file' && activeSource?.protocol === 'worktree-file',
				activeSource?.protocol === 'worktree-file' ? activeSource.generation : null,
			);
			productController?.setReviewAnnotationProjectionActive(
				parsedMessage.data.update.mode === 'review',
			);
			if (activeViewerMode === parsedMessage.data.update.mode) {
				publishUpdatingChrome();
			} else {
				activeViewerMode = parsedMessage.data.update.mode;
				if (activeViewerMode !== 'review') {
					comparisonTargetsQueryRunner.abort();
					activeComparisonTargetsProductControlRequestId = null;
				}
				if (activeViewerMode === 'file') {
					reviewDemandScheduling.suspend();
					resumeLatestSelectedFileViewContentReadyPreparation();
				} else {
					abortAllFileContentPreparations();
					cancelSelectedFileContentOperation();
					selectedFileContentOperationStore = null;
					reviewDemandScheduling.resume();
				}
				publishUpdatingChrome();
			}
		}
		const handlerDurationMilliseconds =
			readBridgeCommWorkerRuntimeNowMilliseconds(props.now) - handlerStartedAtMilliseconds;
		recordBridgeCommWorkerTaskTelemetry({
			command: parsedMessage.data.command,
			durationMilliseconds: handlerDurationMilliseconds,
			...(parsedMessage.data.command === 'select' && parsedMessage.data.surface === 'fileView'
				? {
						fileMetadataSelectedPathResolved: typeof currentFileMetadataSelectedPath === 'string',
					}
				: {}),
			lane: bridgeCommWorkerTelemetryLaneForMessage(parsedMessage.data),
			queueWaitMilliseconds,
			semanticClass: bridgeCommWorkerSemanticClassForMessage(parsedMessage.data),
			taskKind: 'message_handler',
			...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
		});
		dispatchBridgeCommWorkerRuntimeProductControl({
			activeReviewWorkerDerivationEpoch,
			comparisonTargetsQueryRunner,
			getActiveComparisonTargetsRequestId: () => activeComparisonTargetsProductControlRequestId,
			mainCommand: parsedMessage.data,
			messages,
			paneWorkSignal: panePresentationAuthority.workSignal,
			publish: (message, transfer): void => {
				if (transfer === undefined) port.postMessage(message);
				else port.postMessage(message, [...transfer]);
			},
			publishSessionSuspect: (message): void => port.postMessage(message),
			productControlTimeoutMilliseconds,
			productController,
			productTransport,
			publishReviewMetadataInterests: reviewDemandScheduling.publishCurrentMetadataInterests,
			reviewSuccessorSettlementOwner: productBatchApplication,
			sendProductControl,
			...(props.renderFulfillmentContext === undefined
				? {}
				: { sessionIdentity: props.renderFulfillmentContext }),
			setActiveComparisonTargetsRequestId: (requestId): void => {
				activeComparisonTargetsProductControlRequestId = requestId;
			},
		});
		if (parsedMessage.data.command === 'renderDisposition') {
			if (renderDispositionApplication === null) {
				throw new Error('Bridge render disposition application result is unavailable.');
			}
			applyBridgeCommWorkerPostResponseOwnerEffects({
				advanceRenderFulfillmentLifecycle,
				currentFileOperationCorrelationId: () =>
					selectedFileContentOperationController.current?.operationCorrelationId ?? null,
				onFileOperationSettled: (): void => {
					selectedFileContentOperationStore = null;
					resumeLatestSelectedFileViewContentReadyPreparation();
				},
				publish: (message): void => port.postMessage(message),
				recordFileDisposition: (receipt): void => {
					const currentOperation = selectedFileContentOperationController.current;
					if (currentOperation !== null) {
						selectedFileLifecycleTelemetry.disposition(currentOperation, receipt.disposition);
					}
				},
				releaseReviewPosition: reviewDemandScheduling.applyPublishedDisposition,
				readmitReviewPaintRelease: (receipt): void =>
					reviewDemandScheduling.readmitPaintRelease(receipt.itemId),
				receiptResults: renderDispositionApplication.receiptResults,
				settleFileDisposition: (receipt) =>
					settleAcceptedSelectedFileRenderDisposition({
						controller: selectedFileContentOperationController,
						createSequence,
						receipt,
						store: selectedFileContentOperationStore,
					}),
			});
		}
		if (shouldRequestDrainAfterMessage) {
			requestPreparationDrain();
		}
	});
	port.start?.();
}

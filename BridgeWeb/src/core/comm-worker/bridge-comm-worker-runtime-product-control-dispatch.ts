import { runBridgeCommWorkerAnnotationOutputInspection } from './bridge-comm-worker-annotation-output-inspection.js';
import {
	completeBridgeCommWorkerProductControlSuccess,
	notifyBridgeCommWorkerProductControlFailure,
} from './bridge-comm-worker-product-control-completion.js';
import type { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import type { BridgeWorkerComparisonTargetsQueryRunner } from './bridge-comm-worker-review-comparison-target-query.js';
import type { BridgeCommWorkerReviewSuccessorReExposureSettlement } from './bridge-comm-worker-review-publication-types.js';
import { bridgeWorkerRuntimeProductControlCommandForMessage } from './bridge-comm-worker-runtime-command-routing.js';
import {
	bridgeCommWorkerProductControlFailureMessage,
	rejectUninstalledReviewMetadataInterestUpdate,
} from './bridge-comm-worker-runtime-defaults.js';
import {
	bridgeWorkerRuntimeMessageIsReadyRequest,
	bridgeWorkerRuntimeMessagesContainReadyRequest,
	buildBridgeWorkerRuntimeCommandFailedHealthEvent,
} from './bridge-comm-worker-runtime-health.js';
import type { BridgeCommWorkerProductControlSender } from './bridge-comm-worker-runtime-protocol-contracts.js';
import { sendBridgeCommWorkerActionWithTimeout } from './bridge-comm-worker-runtime-support.js';
import { BridgeProductRequestTransportError } from './bridge-product-command-post.js';
import {
	BridgeProductControlRequestError,
	BridgeProductSessionSuspectError,
} from './bridge-product-session-authority.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import type {
	BridgeWorkerMainToServerMessage,
	BridgeWorkerServerToMainMessage,
	BridgeWorkerSessionSuspectEvent,
} from './bridge-worker-contracts.js';

export function dispatchBridgeCommWorkerRuntimeProductControl(props: {
	readonly activeReviewWorkerDerivationEpoch: number | null;
	readonly comparisonTargetsQueryRunner: BridgeWorkerComparisonTargetsQueryRunner;
	readonly getActiveComparisonTargetsRequestId: () => string | null;
	readonly mainCommand: BridgeWorkerMainToServerMessage;
	readonly messages: readonly BridgeWorkerServerToMainMessage[];
	readonly paneWorkSignal: AbortSignal;
	readonly publish: (
		message: BridgeWorkerServerToMainMessage,
		transfer?: readonly Transferable[],
	) => void;
	readonly publishSessionSuspect?: (message: BridgeWorkerSessionSuspectEvent) => void;
	readonly productControlTimeoutMilliseconds: number;
	readonly productController: BridgeCommWorkerProductController | null;
	readonly productTransport: BridgeProductTransportSession | undefined;
	readonly publishReviewMetadataInterests: () => Promise<void>;
	readonly reviewSuccessorSettlementOwner: {
		handleSuccessorReExposureSettlement: (
			settlement: BridgeCommWorkerReviewSuccessorReExposureSettlement,
			workerDerivationEpoch: number | null,
		) => boolean;
	} | null;
	readonly sendProductControl: BridgeCommWorkerProductControlSender;
	readonly sessionIdentity?: {
		readonly paneSessionId: string;
		readonly workerInstanceId: string;
	};
	readonly setActiveComparisonTargetsRequestId: (requestId: string | null) => void;
}): void {
	const productControlCommand = bridgeWorkerRuntimeProductControlCommandForMessage(
		props.mainCommand,
	);
	const metadataInterestUpdateCommand =
		props.mainCommand.command === 'metadataInterestUpdate' ? props.mainCommand : null;
	const deferredRequestId =
		metadataInterestUpdateCommand?.requestId ?? productControlCommand?.requestId ?? null;
	const shouldSendProductControl =
		productControlCommand !== null &&
		bridgeWorkerRuntimeMessagesContainReadyRequest({
			messages: props.messages,
			requestId: productControlCommand.requestId,
		});
	const shouldUpdateReviewMetadataInterests =
		metadataInterestUpdateCommand !== null &&
		bridgeWorkerRuntimeMessagesContainReadyRequest({
			messages: props.messages,
			requestId: metadataInterestUpdateCommand.requestId,
		});
	const immediateMessages =
		(shouldSendProductControl || shouldUpdateReviewMetadataInterests) && deferredRequestId !== null
			? props.messages.filter(
					(message): boolean =>
						!bridgeWorkerRuntimeMessageIsReadyRequest({ message, requestId: deferredRequestId }),
				)
			: props.messages;
	for (const message of immediateMessages) props.publish(message);
	if (
		productControlCommand?.command.method === 'review.comparisonTargets.query' &&
		!shouldSendProductControl
	)
		props.comparisonTargetsQueryRunner.fail(productControlCommand.requestId);
	if (props.mainCommand.command === 'annotationOutputInspect' && props.messages.length === 0)
		runBridgeCommWorkerAnnotationOutputInspection({
			command: props.mainCommand,
			publishFailure: props.publish,
			publishInspection: (inspection): void =>
				props.publish(inspection.message, inspection.transferList),
			productTransport: props.productTransport,
			signal: props.paneWorkSignal,
			timeoutMilliseconds: props.productControlTimeoutMilliseconds,
		});
	if (productControlCommand !== null && shouldSendProductControl) {
		if (productControlCommand.command.method === 'review.comparisonTargets.query') {
			props.comparisonTargetsQueryRunner.abort();
			props.setActiveComparisonTargetsRequestId(productControlCommand.requestId);
		}
		const send = (): Promise<unknown> => props.sendProductControl(productControlCommand.command);
		// W1 owns result and admission deadlines. A declared human wait has no
		// result deadline; only its admission reply remains bounded.
		const completion = Promise.resolve().then(send);
		void completion
			.then((actionResult): void => {
				if (
					productControlCommand.command.method === 'review.comparisonTargets.query' &&
					props.getActiveComparisonTargetsRequestId() === productControlCommand.requestId
				)
					void props.comparisonTargetsQueryRunner.run(
						productControlCommand.requestId,
						actionResult,
					);
				completeBridgeCommWorkerProductControlSuccess({
					actionResult,
					command: productControlCommand.command,
					mainCommand: props.mainCommand,
					messages: props.messages,
					publish: props.publish,
					requestId: productControlCommand.requestId,
					reviewSuccessorSettlementOwner: props.reviewSuccessorSettlementOwner,
					reviewWorkerDerivationEpoch: props.activeReviewWorkerDerivationEpoch,
				});
			})
			.catch((error: unknown): void => {
				if (
					error instanceof BridgeProductSessionSuspectError &&
					error.shouldNotify &&
					props.sessionIdentity !== undefined &&
					props.publishSessionSuspect !== undefined
				) {
					props.publishSessionSuspect({
						ackAttemptOutcomes: [],
						droppedPriorControlRequestCount: 0,
						direction: 'serverWorkerToMain',
						kind: 'sessionSuspect',
						paneSessionId: props.sessionIdentity.paneSessionId,
						priorControlRequests: [],
						reason:
							error.phase === 'admission' ? 'admissionReplyExhausted' : 'resultDeadlineExhausted',
						transferDescriptors: [],
						wireVersion: 1,
						workerInstanceId: props.sessionIdentity.workerInstanceId,
					});
				}
				if (
					error instanceof BridgeProductSessionSuspectError ||
					(error instanceof BridgeProductControlRequestError && error.outcome === 'outcomeUnknown')
				) {
					props.publish(
						buildBridgeWorkerRuntimeCommandFailedHealthEvent({
							deliveryStatus: 'unknownAfterDispatch',
							message: `Bridge comm worker has not received the outcome of ${productControlCommand.command.method}.`,
							requestId: productControlCommand.requestId,
						}),
					);
					if (
						error instanceof BridgeProductControlRequestError &&
						error.outcome === 'outcomeUnknown' &&
						error.observeLateOutcome !== undefined
					) {
						void error
							.observeLateOutcome()
							.then(async (observation): Promise<void> => {
								if (
									observation.evidence.outcome === 'succeeded' &&
									observation.actionResult !== null
								) {
									completeBridgeCommWorkerProductControlSuccess({
										actionResult: observation.actionResult,
										command: productControlCommand.command,
										mainCommand: props.mainCommand,
										messages: props.messages,
										publish: props.publish,
										requestId: productControlCommand.requestId,
										reviewSuccessorSettlementOwner: props.reviewSuccessorSettlementOwner,
										reviewWorkerDerivationEpoch: props.activeReviewWorkerDerivationEpoch,
									});
								} else {
									props.publish(
										buildBridgeWorkerRuntimeCommandFailedHealthEvent({
											requestId: productControlCommand.requestId,
											message: `Bridge product operation later settled as ${observation.evidence.outcome}.`,
										}),
									);
								}
								await observation.acknowledge();
							})
							.catch((): void => {
								// The initial unknown report remains authoritative if observation is lost.
							});
					}
					return;
				}
				if (
					productControlCommand.command.method === 'review.comparisonTargets.query' &&
					props.getActiveComparisonTargetsRequestId() === productControlCommand.requestId
				) {
					props.comparisonTargetsQueryRunner.abort();
					props.comparisonTargetsQueryRunner.fail(productControlCommand.requestId);
					props.setActiveComparisonTargetsRequestId(null);
				}
				props.publish(
					buildBridgeWorkerRuntimeCommandFailedHealthEvent({
						requestId: productControlCommand.requestId,
						errorKind: classifyProductControlForwardingError(error),
						message: bridgeCommWorkerProductControlFailureMessage({
							command: productControlCommand.command,
						}),
						...(productControlCommand.command.method === 'bridge.activeViewerMode.update'
							? { deliveryStatus: 'unknownAfterDispatch' }
							: {}),
					}),
				);
				notifyBridgeCommWorkerProductControlFailure({
					command: productControlCommand.command,
					reviewSuccessorSettlementOwner: props.reviewSuccessorSettlementOwner,
					reviewWorkerDerivationEpoch: props.activeReviewWorkerDerivationEpoch,
				});
			});
	}
	if (metadataInterestUpdateCommand !== null && shouldUpdateReviewMetadataInterests) {
		void sendBridgeCommWorkerActionWithTimeout({
			send:
				props.productController === null
					? rejectUninstalledReviewMetadataInterestUpdate
					: props.publishReviewMetadataInterests,
			timeoutMilliseconds: props.productControlTimeoutMilliseconds,
		})
			.then((): void => {
				for (const message of props.messages)
					if (
						bridgeWorkerRuntimeMessageIsReadyRequest({
							message,
							requestId: metadataInterestUpdateCommand.requestId,
						})
					)
						props.publish(message);
			})
			.catch((): void =>
				props.publish(
					buildBridgeWorkerRuntimeCommandFailedHealthEvent({
						requestId: metadataInterestUpdateCommand.requestId,
						message: 'Bridge comm worker failed to update Review metadata interests.',
					}),
				),
			);
	}
}

function classifyProductControlForwardingError(
	error: unknown,
): 'transport' | 'requestRefused' | 'invalidResult' | 'unexpected' {
	if (error instanceof BridgeProductRequestTransportError) return 'transport';
	if (error instanceof BridgeProductControlRequestError) return 'requestRefused';
	if (error instanceof SyntaxError || (error instanceof Error && error.name === 'ZodError')) {
		return 'invalidResult';
	}
	return 'unexpected';
}

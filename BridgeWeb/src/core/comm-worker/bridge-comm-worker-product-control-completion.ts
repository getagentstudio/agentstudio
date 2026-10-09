import { bridgeCommWorkerAnnotationCommandAcceptedEvent } from './bridge-comm-worker-annotation-runtime-events.js';
import { buildBridgeWorkerReviewPublicationInstallAdmissionEvent } from './bridge-comm-worker-protocol.js';
import type { BridgeCommWorkerReviewSuccessorReExposureSettlement } from './bridge-comm-worker-review-publication-types.js';
import { bridgeWorkerRuntimeMessageIsReadyRequest } from './bridge-comm-worker-runtime-health.js';
import { bridgeProductReviewPublicationInstallAdmissionResultSchema } from './bridge-product-call-contracts.js';
import type { BridgeProductControlCommand } from './bridge-product-control-contracts.js';
import type {
	BridgeWorkerMainToServerMessage,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

interface BridgeCommWorkerReviewSuccessorSettlementNotification {
	readonly reviewSuccessorSettlementOwner?:
		| {
				handleSuccessorReExposureSettlement: (
					settlement: BridgeCommWorkerReviewSuccessorReExposureSettlement,
					workerDerivationEpoch: number | null,
				) => boolean;
		  }
		| null
		| undefined;
	readonly reviewWorkerDerivationEpoch?: number | null | undefined;
}

export interface PublishBridgeCommWorkerProductControlCompletionProps extends BridgeCommWorkerReviewSuccessorSettlementNotification {
	readonly actionResult: unknown;
	readonly command: BridgeProductControlCommand;
	readonly mainCommand: BridgeWorkerMainToServerMessage;
	readonly messages: readonly BridgeWorkerServerToMainMessage[];
	readonly publish: (message: BridgeWorkerServerToMainMessage) => void;
	readonly requestId: string;
}

export function publishBridgeCommWorkerProductControlCompletion(
	props: PublishBridgeCommWorkerProductControlCompletionProps,
): void {
	if (props.command.method === 'review.publication.install.admit') {
		const admissionResult = bridgeProductReviewPublicationInstallAdmissionResultSchema.parse(
			props.actionResult,
		);
		props.publish(
			buildBridgeWorkerReviewPublicationInstallAdmissionEvent({
				candidatePublicationId: props.command.params.candidatePublicationId,
				requestId: props.requestId,
				status: admissionResult.status,
			}),
		);
		if (admissionResult.status === 'rejected') {
			notifyReviewSuccessorSettlement(props, {
				candidatePublicationId: props.command.params.candidatePublicationId,
				kind: 'admissionRejected',
			});
		}
		return;
	}
	if (props.mainCommand.command === 'reviewPublicationInstalled') {
		notifyReviewSuccessorSettlement(props, {
			identity: props.mainCommand,
			kind: 'publicationApplied',
		});
	}

	for (const message of props.messages) {
		if (
			bridgeWorkerRuntimeMessageIsReadyRequest({
				message,
				requestId: props.requestId,
			})
		) {
			props.publish(message);
		}
	}
}

export function completeBridgeCommWorkerProductControlSuccess(
	props: PublishBridgeCommWorkerProductControlCompletionProps,
): void {
	const annotationAcceptedEvent = bridgeCommWorkerAnnotationCommandAcceptedEvent({
		actionResult: props.actionResult,
		command: props.command,
		requestId: props.requestId,
	});
	if (annotationAcceptedEvent !== null) props.publish(annotationAcceptedEvent);
	publishBridgeCommWorkerProductControlCompletion(props);
}

export function notifyBridgeCommWorkerProductControlFailure(
	props: BridgeCommWorkerReviewSuccessorSettlementNotification & {
		readonly command: BridgeProductControlCommand;
	},
): void {
	if (props.command.method !== 'review.publication.install.admit') return;
	notifyReviewSuccessorSettlement(props, {
		candidatePublicationId: props.command.params.candidatePublicationId,
		kind: 'admissionFailed',
	});
}

function notifyReviewSuccessorSettlement(
	props: BridgeCommWorkerReviewSuccessorSettlementNotification,
	settlement: BridgeCommWorkerReviewSuccessorReExposureSettlement,
): void {
	props.reviewSuccessorSettlementOwner?.handleSuccessorReExposureSettlement(
		settlement,
		props.reviewWorkerDerivationEpoch ?? null,
	);
}

import type {
	BridgeCommWorkerTelemetryLane,
	BridgeCommWorkerTelemetrySemanticClass,
} from './bridge-comm-worker-telemetry.js';
import type { BridgeProductWorktreeAnnotationOperation } from './bridge-product-call-contracts.js';
import type { BridgeProductControlCommand } from './bridge-product-control-contracts.js';
import type { BridgeWorkerMainToServerMessage } from './bridge-worker-contracts.js';

export function bridgeWorkerRuntimeProductControlCommandForMessage(
	message: BridgeWorkerMainToServerMessage,
): { readonly command: BridgeProductControlCommand; readonly requestId: string } | null {
	switch (message.command) {
		case 'fileRefreshRetry':
			return {
				command: { method: 'file.refresh.retry', params: {} },
				requestId: message.requestId,
			};
		case 'annotationCommand':
			return message.surface === 'fileView'
				? {
						command: {
							method: 'file.annotations.command',
							params: { operation: message.operation },
						},
						requestId: message.requestId,
					}
				: {
						command: {
							method: 'review.annotations.command',
							params: {
								operation: message.operation,
								reviewPublicationIdentity: requireReviewPublicationIdentity(message),
							},
						},
						requestId: message.requestId,
					};
		case 'markFileViewed':
			return {
				command: {
					method: 'review.markFileViewed',
					params: { fileId: message.fileId },
				},
				requestId: message.requestId,
			};
		case 'activeViewerModeUpdate':
			return {
				command: {
					method: 'bridge.activeViewerMode.update',
					params: message.update,
				},
				requestId: message.requestId,
			};
		case 'reviewIntakeReady':
			return {
				command: {
					method: 'bridge.intakeReady',
					params: {
						protocolId: message.protocolId,
						reason: message.reason,
						streamId: message.streamId,
					},
				},
				requestId: message.requestId,
			};
		case 'reviewComparisonUpdate':
			return {
				command: {
					method: 'review.comparison.update',
					params: { target: message.target },
				},
				requestId: message.requestId,
			};
		case 'reviewComparisonTargetsQuery':
			return {
				command: {
					method: 'review.comparisonTargets.query',
					params: {},
				},
				requestId: message.requestId,
			};
		case 'reviewPublicationInstallAdmit':
			return {
				command: {
					method: 'review.publication.install.admit',
					params: {
						candidatePublicationId: message.candidatePublicationId,
						expectedDisplayedPublicationId: message.expectedDisplayedPublicationId,
					},
				},
				requestId: message.requestId,
			};
		case 'reviewPublicationInstalled':
			return {
				command: {
					method: 'review.publication.applied',
					params: { publicationId: message.publicationId },
				},
				requestId: message.requestId,
			};
		case 'reviewComparisonTargetsQueryCancel':
		case 'annotationOutputInspect':
		case 'annotationProjectionRetry':
		case 'viewRecoveryRetry':
		case 'hover':
		case 'metadataInterestUpdate':
		case 'fileQueryUpdate':
		case 'fileDisplayResync':
		case 'mode':
		case 'reviewInvalidate':
		case 'reviewProjectionUpdate':
		case 'renderDisposition':
		case 'select':
		case 'viewport':
			return null;
		default:
			return assertNeverBridgeWorkerMessage(message);
	}
}

function requireReviewPublicationIdentity(
	message: Extract<BridgeWorkerMainToServerMessage, { readonly command: 'annotationCommand' }>,
): NonNullable<typeof message.reviewPublicationIdentity> {
	if (message.reviewPublicationIdentity === undefined) {
		throw new Error('Review annotation command has no installed publication identity.');
	}
	return message.reviewPublicationIdentity;
}

export function bridgeCommWorkerTelemetryLaneForMessage(
	message: BridgeWorkerMainToServerMessage,
): BridgeCommWorkerTelemetryLane {
	switch (message.command) {
		case 'annotationCommand':
		case 'annotationOutputInspect':
		case 'annotationProjectionRetry':
		case 'viewRecoveryRetry':
			return 'selected';
		case 'select':
			return 'selected';
		case 'viewport':
		case 'fileQueryUpdate':
		case 'fileDisplayResync':
		case 'fileRefreshRetry':
		case 'hover':
		case 'reviewInvalidate':
		case 'reviewProjectionUpdate':
		case 'renderDisposition':
			return 'visible';
		case 'metadataInterestUpdate':
			return message.request.lane === 'foreground' ? 'selected' : 'visible';
		case 'activeViewerModeUpdate':
			return 'background';
		case 'markFileViewed':
		case 'mode':
		case 'reviewIntakeReady':
		case 'reviewComparisonUpdate':
		case 'reviewComparisonTargetsQuery':
		case 'reviewComparisonTargetsQueryCancel':
		case 'reviewPublicationInstallAdmit':
		case 'reviewPublicationInstalled':
			return 'background';
		default:
			return assertNeverBridgeWorkerMessage(message);
	}
}

export function bridgeCommWorkerSemanticClassForMessage(
	message: BridgeWorkerMainToServerMessage,
): BridgeCommWorkerTelemetrySemanticClass {
	switch (message.command) {
		case 'annotationCommand':
			return bridgeCommWorkerAnnotationOperationSemanticClass(message.operation);
		case 'markFileViewed':
			return 'urgent_action';
		case 'annotationOutputInspect':
		case 'fileQueryUpdate':
		case 'hover':
		case 'metadataInterestUpdate':
		case 'reviewComparisonTargetsQuery':
		case 'reviewComparisonUpdate':
		case 'reviewInvalidate':
		case 'reviewProjectionUpdate':
		case 'select':
		case 'viewport':
			return 'demand';
		case 'renderDisposition':
			return 'settlement';
		case 'activeViewerModeUpdate':
		case 'annotationProjectionRetry':
		case 'fileDisplayResync':
		case 'fileRefreshRetry':
		case 'viewRecoveryRetry':
		case 'mode':
		case 'reviewComparisonTargetsQueryCancel':
		case 'reviewIntakeReady':
		case 'reviewPublicationInstallAdmit':
		case 'reviewPublicationInstalled':
			return 'lifecycle_control';
		default:
			return assertNeverBridgeWorkerMessage(message);
	}
}

function bridgeCommWorkerAnnotationOperationSemanticClass(
	operation: BridgeProductWorktreeAnnotationOperation,
): BridgeCommWorkerTelemetrySemanticClass {
	switch (operation.kind) {
		case 'continuity.choose':
		case 'draft.edit.acquire':
		case 'draft.edit.release':
		case 'draft.flush':
		case 'draft.revert':
		case 'draft.save':
		case 'message.viewed.mark':
		case 'output.handled.clear':
		case 'output.preference.changeFolder':
		case 'output.reveal':
		case 'output.scope.commit':
		case 'recovery.acknowledge':
		case 'reply.create':
		case 'root.create':
		case 'thread.resolution.set':
			return 'urgent_action';
		case 'demand.acquire':
		case 'demand.release':
		case 'output.history':
		case 'output.repeat':
		case 'session.discover':
		case 'source.refresh':
			return 'demand';
		default:
			return assertNeverBridgeAnnotationOperation(operation);
	}
}

function assertNeverBridgeAnnotationOperation(_operation: never): never {
	throw new Error('Unhandled Bridge annotation operation.');
}

function assertNeverBridgeWorkerMessage(_message: never): never {
	throw new Error('Unhandled bridge worker message.');
}

import type { BridgeCommWorkerAnnotationCatalog } from './bridge-comm-worker-annotation-catalog-applicator.js';
import type { BridgeWorkerAnnotationProjectionSnapshot } from './bridge-comm-worker-annotation-projection-decoder.js';
import { packBridgeMetadataCatalogTransfer } from './bridge-metadata-catalog-transfer-packer.js';
import { bridgeProductWorktreeAnnotationDecodedCommandResultSchema } from './bridge-product-call-contracts.js';
import type { BridgeProductControlCommand } from './bridge-product-control-contracts.js';
import { BridgeProductControlRequestError } from './bridge-product-session-authority.js';
import { bridgeProductWorktreeAnnotationCatalogEntrySchema } from './bridge-product-worktree-annotation-contracts.js';
import type { BridgeProductReviewAnnotationPublicationIdentity } from './bridge-product-worktree-annotation-projection-query-contracts.js';
import type {
	BridgeWorkerAnnotationCatalogStagingEvent,
	BridgeWorkerAnnotationCommandAcceptedEvent,
	BridgeWorkerAnnotationProjectionConvergenceEvent,
} from './bridge-worker-annotation-contracts.js';
import { bridgeWorkerAnnotationCatalogStagingEventSchema } from './bridge-worker-annotation-contracts.js';

const annotationCatalogStagingEncoder = new TextEncoder();

export function bridgeCommWorkerAnnotationCatalogStagingEvents(publication: {
	readonly catalog: BridgeCommWorkerAnnotationCatalog;
	readonly surface: 'file' | 'review';
}): readonly BridgeWorkerAnnotationCatalogStagingEvent[] {
	const buildEvent = (
		transfer: BridgeWorkerAnnotationCatalogStagingEvent['transfer'],
	): BridgeWorkerAnnotationCatalogStagingEvent =>
		bridgeWorkerAnnotationCatalogStagingEventSchema.parse({
			authority: publication.catalog.authority,
			direction: 'serverWorkerToMain',
			kind: 'annotationCatalogStaging',
			surface: publication.surface === 'file' ? 'fileView' : 'review',
			transfer,
			transferDescriptors: [],
			wireVersion: 1,
		});
	const transfers = packBridgeMetadataCatalogTransfer({
		catalogRevision: publication.catalog.catalogRevision,
		encodeEnvelope: (transfer): Uint8Array =>
			annotationCatalogStagingEncoder.encode(JSON.stringify(buildEvent(transfer))),
		entries: publication.catalog.entries,
		entrySchema: bridgeProductWorktreeAnnotationCatalogEntrySchema,
		transferId: publication.catalog.transferId,
	});
	return Object.freeze(transfers.map((transfer) => buildEvent(transfer)));
}

export function bridgeCommWorkerAnnotationCommandAcceptedEvent(props: {
	readonly actionResult: unknown;
	readonly command: BridgeProductControlCommand;
	readonly requestId: string;
}): BridgeWorkerAnnotationCommandAcceptedEvent | null {
	if (
		props.command.method !== 'file.annotations.command' &&
		props.command.method !== 'review.annotations.command'
	) {
		return null;
	}
	const annotationResult = bridgeProductWorktreeAnnotationDecodedCommandResultSchema.parse(
		props.actionResult,
	);
	return {
		direction: 'serverWorkerToMain',
		kind: 'annotationCommandAccepted',
		outcome: annotationResult.outcome,
		productRequestId: annotationResult.outcome.requestId,
		requestId: props.requestId,
		surface: props.command.method === 'file.annotations.command' ? 'fileView' : 'review',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

export function bridgeCommWorkerAnnotationProjectionConvergenceEvent(props: {
	readonly operationCorrelationId: string | null;
	readonly state:
		| {
				readonly contentSessionIds: readonly string[];
				readonly kind: 'ready';
				readonly stageAttempt: number;
				readonly reviewPublicationIdentity?:
					| BridgeProductReviewAnnotationPublicationIdentity
					| undefined;
				readonly snapshot: BridgeWorkerAnnotationProjectionSnapshot;
		  }
		| {
				readonly catalogAuthorityRetired: boolean;
				readonly error: unknown;
				readonly kind: 'unavailable';
		  }
		| { readonly catalogAuthorityRetired: boolean; readonly kind: 'refreshing' };
	readonly surface: 'file' | 'review';
}): BridgeWorkerAnnotationProjectionConvergenceEvent {
	const state =
		props.state.kind === 'unavailable'
			? {
					catalogAuthorityRetired: props.state.catalogAuthorityRetired,
					kind: 'unavailable' as const,
					retryable:
						props.state.error instanceof BridgeProductControlRequestError &&
						props.state.error.retryable,
				}
			: props.state;
	return {
		direction: 'serverWorkerToMain',
		kind: 'annotationProjectionConvergence',
		operationCorrelationId: props.operationCorrelationId,
		state,
		surface: props.surface === 'file' ? 'fileView' : 'review',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

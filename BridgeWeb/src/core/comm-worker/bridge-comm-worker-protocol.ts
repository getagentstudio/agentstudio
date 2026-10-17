import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerActiveViewerModeUpdateCommandSchema,
	bridgeWorkerFileDisplayResyncCommandSchema,
	bridgeWorkerFileQueryUpdateCommandSchema,
	bridgeWorkerHoverCommandSchema,
	bridgeWorkerMarkFileViewedCommandSchema,
	bridgeWorkerMetadataInterestUpdateCommandSchema,
	bridgeWorkerModeCommandSchema,
	bridgeWorkerReviewIntakeReadyCommandSchema,
	bridgeWorkerReviewComparisonUpdateCommandSchema,
	bridgeWorkerReviewComparisonTargetsQueryCancelCommandSchema,
	bridgeWorkerReviewComparisonTargetsQueryCommandSchema,
	bridgeWorkerReviewInvalidateCommandSchema,
	bridgeWorkerReviewProjectionUpdateCommandSchema,
	bridgeWorkerReviewCandidateReadyEventSchema,
	bridgeWorkerReviewCandidateFailedEventSchema,
	bridgeWorkerReviewCandidateStartedEventSchema,
	bridgeWorkerReviewPublicationInstallAdmissionEventSchema,
	bridgeWorkerReviewPublicationInstallAdmitCommandSchema,
	bridgeWorkerReviewPublicationInstalledCommandSchema,
	bridgeWorkerViewRecoveryRetryCommandSchema,
	bridgeWorkerViewRecoveryStatusEventSchema,
	bridgeWorkerSelectCommandSchema,
	bridgeWorkerViewportCommandSchema,
	type BridgeWorkerHealthEvent,
	type BridgeWorkerActiveViewerModeUpdateCommand,
	type BridgeWorkerFileDisplayResyncCommand,
	type BridgeWorkerFileQueryUpdateCommand,
	type BridgeWorkerHoverCommand,
	type BridgeWorkerMainToServerCommand,
	type BridgeWorkerMarkFileViewedCommand,
	type BridgeWorkerMetadataInterestRequest,
	type BridgeWorkerMetadataInterestUpdateCommand,
	type BridgeWorkerModeCommand,
	type BridgeWorkerRenderDispositionCommand,
	type BridgeWorkerReviewIntakeReadyCommand,
	type BridgeWorkerReviewComparisonUpdateCommand,
	type BridgeWorkerReviewComparisonTargetsQueryCommand,
	type BridgeWorkerReviewComparisonTargetsQueryCancelCommand,
	type BridgeWorkerReviewInvalidateCommand,
	type BridgeWorkerReviewProjectionUpdateCommand,
	type BridgeWorkerReviewCandidateReadyEvent,
	type BridgeWorkerReviewCandidateFailedEvent,
	type BridgeWorkerReviewCandidateStartedEvent,
	type BridgeWorkerReviewCandidateStartDisposition,
	type BridgeWorkerReviewPublicationInstallAdmissionEvent,
	type BridgeWorkerReviewPublicationInstallAdmitCommand,
	type BridgeWorkerReviewPublicationInstalledCommand,
	type BridgeWorkerViewRecoveryRetryCommand,
	type BridgeWorkerViewRecoveryStatusEvent,
	type BridgeWorkerSelectCommand,
	type BridgeWorkerViewportCommand,
} from './bridge-worker-contracts.js';
import { bridgeWorkerRenderDispositionCommandSchema } from './bridge-worker-render-disposition-command-contract.js';

export type BridgeWorkerCommandName = BridgeWorkerMainToServerCommand['command'];

export interface EncodeBridgeWorkerCommandBaseProps {
	readonly requestId: string;
	readonly epoch: number;
	readonly issuedAtMilliseconds?: number;
}

export interface EncodeBridgeWorkerSelectCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly surface: BridgeWorkerSelectCommand['surface'];
	readonly selectedItemId: BridgeWorkerSelectCommand['selectedItemId'];
	readonly selectedSource: BridgeWorkerSelectCommand['selectedSource'];
}

export interface EncodeBridgeWorkerViewportCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly surface: BridgeWorkerViewportCommand['surface'];
	readonly visibleItemIds: readonly string[];
	readonly firstVisibleIndex: number;
	readonly lastVisibleIndex: number;
	readonly phase: BridgeWorkerViewportCommand['phase'];
}

export interface EncodeBridgeWorkerHoverCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly surface: BridgeWorkerHoverCommand['surface'];
	readonly hoveredItemId: string | null;
}

export interface EncodeBridgeWorkerMarkFileViewedCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly fileId: string;
}

export interface EncodeBridgeWorkerMetadataInterestUpdateCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly request: BridgeWorkerMetadataInterestRequest;
}

export interface EncodeBridgeWorkerReviewIntakeReadyCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly reason?: BridgeWorkerReviewIntakeReadyCommand['reason'];
	readonly streamId: BridgeWorkerReviewIntakeReadyCommand['streamId'];
}

export interface EncodeBridgeWorkerReviewComparisonUpdateCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly target: BridgeWorkerReviewComparisonUpdateCommand['target'];
}

export type EncodeBridgeWorkerReviewComparisonTargetsQueryCommandProps =
	EncodeBridgeWorkerCommandBaseProps;

export type EncodeBridgeWorkerReviewComparisonTargetsQueryCancelCommandProps =
	EncodeBridgeWorkerCommandBaseProps & {
		readonly queryRequestId: string;
	};

export interface EncodeBridgeWorkerActiveViewerModeUpdateCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly update: BridgeWorkerActiveViewerModeUpdateCommand['update'];
}

export interface EncodeBridgeWorkerModeCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly mode: BridgeWorkerModeCommand['mode'];
}

export type EncodeBridgeWorkerFileQueryUpdateCommandProps = EncodeBridgeWorkerCommandBaseProps &
	BridgeWorkerFileQueryUpdateCommand['query'];

export interface EncodeBridgeWorkerFileDisplayResyncCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly reason: BridgeWorkerFileDisplayResyncCommand['reason'];
	readonly transactionId: string | null;
}

export interface EncodeBridgeWorkerViewRecoveryRetryCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly view: BridgeWorkerViewRecoveryRetryCommand['view'];
}

export type BuildBridgeWorkerViewRecoveryStatusEventProps = Pick<
	BridgeWorkerViewRecoveryStatusEvent,
	'status' | 'view'
>;

export interface EncodeBridgeWorkerReviewInvalidateCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly scope: BridgeWorkerReviewInvalidateCommand['scope'];
	readonly itemIds: readonly string[];
	readonly pathHints: readonly string[];
	readonly reason: BridgeWorkerReviewInvalidateCommand['reason'];
}

export interface EncodeBridgeWorkerReviewProjectionUpdateCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly query: BridgeWorkerReviewProjectionUpdateCommand['query'];
}

export interface EncodeBridgeWorkerRenderDispositionCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly receipts: BridgeWorkerRenderDispositionCommand['receipts'];
}

export interface EncodeBridgeWorkerReviewPublicationInstallAdmitCommandProps extends EncodeBridgeWorkerCommandBaseProps {
	readonly expectedDisplayedPublicationId: string | null;
	readonly candidatePublicationId: string;
}

export interface EncodeBridgeWorkerReviewPublicationInstalledCommandProps
	extends
		EncodeBridgeWorkerCommandBaseProps,
		Pick<
			BridgeWorkerReviewPublicationInstalledCommand,
			'packageId' | 'publicationId' | 'reviewGeneration' | 'revision' | 'sourceIdentity'
		> {}

export interface BuildBridgeWorkerReviewCandidateReadyEventProps {
	readonly epoch: number;
	readonly packageId: string;
	readonly publicationId: string;
	readonly reviewGeneration: number;
	readonly revision: number;
	readonly sequence: number;
	readonly sourceIdentity: string;
}

export interface BuildBridgeWorkerReviewCandidateStartedEventProps extends BuildBridgeWorkerReviewCandidateReadyEventProps {
	readonly disposition: BridgeWorkerReviewCandidateStartDisposition;
}

export interface BuildBridgeWorkerReviewCandidateFailedEventProps extends BuildBridgeWorkerReviewCandidateReadyEventProps {
	readonly retryable: boolean;
}

export interface BuildBridgeWorkerReviewPublicationInstallAdmissionEventProps {
	readonly candidatePublicationId: string;
	readonly requestId: string;
	readonly status: BridgeWorkerReviewPublicationInstallAdmissionEvent['status'];
}

export function encodeBridgeWorkerSelectCommand(
	props: EncodeBridgeWorkerSelectCommandProps,
): BridgeWorkerSelectCommand {
	return bridgeWorkerSelectCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'select'),
		surface: props.surface,
		selectedItemId: props.selectedItemId,
		selectedSource: props.selectedSource,
	});
}

export function encodeBridgeWorkerViewportCommand(
	props: EncodeBridgeWorkerViewportCommandProps,
): BridgeWorkerViewportCommand {
	return bridgeWorkerViewportCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'viewport'),
		surface: props.surface,
		visibleItemIds: props.visibleItemIds,
		firstVisibleIndex: props.firstVisibleIndex,
		lastVisibleIndex: props.lastVisibleIndex,
		phase: props.phase,
	});
}

export function encodeBridgeWorkerHoverCommand(
	props: EncodeBridgeWorkerHoverCommandProps,
): BridgeWorkerHoverCommand {
	return bridgeWorkerHoverCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'hover'),
		surface: props.surface,
		hoveredItemId: props.hoveredItemId,
	});
}

export function encodeBridgeWorkerMarkFileViewedCommand(
	props: EncodeBridgeWorkerMarkFileViewedCommandProps,
): BridgeWorkerMarkFileViewedCommand {
	return bridgeWorkerMarkFileViewedCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'markFileViewed'),
		fileId: props.fileId,
	});
}

export function encodeBridgeWorkerMetadataInterestUpdateCommand(
	props: EncodeBridgeWorkerMetadataInterestUpdateCommandProps,
): BridgeWorkerMetadataInterestUpdateCommand {
	return bridgeWorkerMetadataInterestUpdateCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'metadataInterestUpdate'),
		request: props.request,
	});
}

export function encodeBridgeWorkerReviewIntakeReadyCommand(
	props: EncodeBridgeWorkerReviewIntakeReadyCommandProps,
): BridgeWorkerReviewIntakeReadyCommand {
	return bridgeWorkerReviewIntakeReadyCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'reviewIntakeReady'),
		protocolId: 'review',
		streamId: props.streamId,
		reason: props.reason ?? null,
	});
}

export function encodeBridgeWorkerReviewComparisonUpdateCommand(
	props: EncodeBridgeWorkerReviewComparisonUpdateCommandProps,
): BridgeWorkerReviewComparisonUpdateCommand {
	return bridgeWorkerReviewComparisonUpdateCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'reviewComparisonUpdate'),
		target: props.target,
	});
}

export function encodeBridgeWorkerReviewComparisonTargetsQueryCommand(
	props: EncodeBridgeWorkerReviewComparisonTargetsQueryCommandProps,
): BridgeWorkerReviewComparisonTargetsQueryCommand {
	return bridgeWorkerReviewComparisonTargetsQueryCommandSchema.parse(
		bridgeWorkerCommandEnvelope(props, 'reviewComparisonTargetsQuery'),
	);
}

export function encodeBridgeWorkerReviewComparisonTargetsQueryCancelCommand(
	props: EncodeBridgeWorkerReviewComparisonTargetsQueryCancelCommandProps,
): BridgeWorkerReviewComparisonTargetsQueryCancelCommand {
	return bridgeWorkerReviewComparisonTargetsQueryCancelCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'reviewComparisonTargetsQueryCancel'),
		queryRequestId: props.queryRequestId,
	});
}

export function encodeBridgeWorkerActiveViewerModeUpdateCommand(
	props: EncodeBridgeWorkerActiveViewerModeUpdateCommandProps,
): BridgeWorkerActiveViewerModeUpdateCommand {
	return bridgeWorkerActiveViewerModeUpdateCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'activeViewerModeUpdate'),
		update: props.update,
	});
}

export function encodeBridgeWorkerModeCommand(
	props: EncodeBridgeWorkerModeCommandProps,
): BridgeWorkerModeCommand {
	return bridgeWorkerModeCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'mode'),
		mode: props.mode,
	});
}

export function encodeBridgeWorkerFileQueryUpdateCommand(
	props: EncodeBridgeWorkerFileQueryUpdateCommandProps,
): BridgeWorkerFileQueryUpdateCommand {
	return bridgeWorkerFileQueryUpdateCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'fileQueryUpdate'),
		query: {
			filterMode: props.filterMode,
			searchMode: props.searchMode,
			searchText: props.searchText,
		},
	});
}

export function encodeBridgeWorkerFileDisplayResyncCommand(
	props: EncodeBridgeWorkerFileDisplayResyncCommandProps,
): BridgeWorkerFileDisplayResyncCommand {
	return bridgeWorkerFileDisplayResyncCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'fileDisplayResync'),
		reason: props.reason,
		transactionId: props.transactionId,
	});
}

export function encodeBridgeWorkerViewRecoveryRetryCommand(
	props: EncodeBridgeWorkerViewRecoveryRetryCommandProps,
): BridgeWorkerViewRecoveryRetryCommand {
	return bridgeWorkerViewRecoveryRetryCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'viewRecoveryRetry'),
		view: props.view,
	});
}

export function encodeBridgeWorkerReviewInvalidateCommand(
	props: EncodeBridgeWorkerReviewInvalidateCommandProps,
): BridgeWorkerReviewInvalidateCommand {
	return bridgeWorkerReviewInvalidateCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'reviewInvalidate'),
		scope: props.scope,
		itemIds: props.itemIds,
		pathHints: props.pathHints,
		reason: props.reason,
	});
}

export function encodeBridgeWorkerReviewProjectionUpdateCommand(
	props: EncodeBridgeWorkerReviewProjectionUpdateCommandProps,
): BridgeWorkerReviewProjectionUpdateCommand {
	return bridgeWorkerReviewProjectionUpdateCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'reviewProjectionUpdate'),
		query: props.query,
	});
}

export function encodeBridgeWorkerRenderDispositionCommand(
	props: EncodeBridgeWorkerRenderDispositionCommandProps,
): BridgeWorkerRenderDispositionCommand {
	return bridgeWorkerRenderDispositionCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'renderDisposition'),
		receipts: props.receipts,
	});
}

export function encodeBridgeWorkerReviewPublicationInstallAdmitCommand(
	props: EncodeBridgeWorkerReviewPublicationInstallAdmitCommandProps,
): BridgeWorkerReviewPublicationInstallAdmitCommand {
	return bridgeWorkerReviewPublicationInstallAdmitCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'reviewPublicationInstallAdmit'),
		expectedDisplayedPublicationId: props.expectedDisplayedPublicationId,
		candidatePublicationId: props.candidatePublicationId,
	});
}

export function encodeBridgeWorkerReviewPublicationInstalledCommand(
	props: EncodeBridgeWorkerReviewPublicationInstalledCommandProps,
): BridgeWorkerReviewPublicationInstalledCommand {
	return bridgeWorkerReviewPublicationInstalledCommandSchema.parse({
		...bridgeWorkerCommandEnvelope(props, 'reviewPublicationInstalled'),
		packageId: props.packageId,
		publicationId: props.publicationId,
		reviewGeneration: props.reviewGeneration,
		revision: props.revision,
		sourceIdentity: props.sourceIdentity,
	});
}

export function buildBridgeWorkerReviewCandidateReadyEvent(
	props: BuildBridgeWorkerReviewCandidateReadyEventProps,
): BridgeWorkerReviewCandidateReadyEvent {
	return bridgeWorkerReviewCandidateReadyEventSchema.parse({
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'reviewCandidateReady',
		surface: 'review',
		epoch: props.epoch,
		sequence: props.sequence,
		publicationId: props.publicationId,
		packageId: props.packageId,
		sourceIdentity: props.sourceIdentity,
		reviewGeneration: props.reviewGeneration,
		revision: props.revision,
	});
}

export function buildBridgeWorkerReviewCandidateStartedEvent(
	props: BuildBridgeWorkerReviewCandidateStartedEventProps,
): BridgeWorkerReviewCandidateStartedEvent {
	return bridgeWorkerReviewCandidateStartedEventSchema.parse({
		direction: 'serverWorkerToMain',
		disposition: props.disposition,
		epoch: props.epoch,
		kind: 'reviewCandidateStarted',
		packageId: props.packageId,
		publicationId: props.publicationId,
		reviewGeneration: props.reviewGeneration,
		revision: props.revision,
		sequence: props.sequence,
		sourceIdentity: props.sourceIdentity,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	});
}

export function buildBridgeWorkerReviewCandidateFailedEvent(
	props: BuildBridgeWorkerReviewCandidateFailedEventProps,
): BridgeWorkerReviewCandidateFailedEvent {
	return bridgeWorkerReviewCandidateFailedEventSchema.parse({
		direction: 'serverWorkerToMain',
		epoch: props.epoch,
		kind: 'reviewCandidateFailed',
		packageId: props.packageId,
		publicationId: props.publicationId,
		retryable: props.retryable,
		reviewGeneration: props.reviewGeneration,
		revision: props.revision,
		sequence: props.sequence,
		sourceIdentity: props.sourceIdentity,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	});
}

export function buildBridgeWorkerReviewPublicationInstallAdmissionEvent(
	props: BuildBridgeWorkerReviewPublicationInstallAdmissionEventProps,
): BridgeWorkerReviewPublicationInstallAdmissionEvent {
	return bridgeWorkerReviewPublicationInstallAdmissionEventSchema.parse({
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'reviewPublicationInstallAdmission',
		requestId: props.requestId,
		candidatePublicationId: props.candidatePublicationId,
		status: props.status,
	});
}

export function buildBridgeWorkerViewRecoveryStatusEvent(
	props: BuildBridgeWorkerViewRecoveryStatusEventProps,
): BridgeWorkerViewRecoveryStatusEvent {
	return bridgeWorkerViewRecoveryStatusEventSchema.parse({
		direction: 'serverWorkerToMain',
		kind: 'viewRecoveryStatus',
		status: props.status,
		transferDescriptors: [],
		view: props.view,
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	});
}

export function buildBridgeWorkerReadyHealthEvent(requestId?: string): BridgeWorkerHealthEvent {
	return {
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'health',
		...(requestId === undefined ? {} : { requestId }),
		status: 'ready',
	};
}

function bridgeWorkerCommandEnvelope(
	props: EncodeBridgeWorkerCommandBaseProps,
	command: BridgeWorkerCommandName,
): Pick<
	BridgeWorkerMainToServerCommand,
	| 'wireVersion'
	| 'direction'
	| 'kind'
	| 'requestId'
	| 'epoch'
	| 'issuedAtMilliseconds'
	| 'transferDescriptors'
> & {
	readonly command: BridgeWorkerCommandName;
} {
	return {
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		direction: 'mainToServerWorker',
		kind: 'command',
		requestId: props.requestId,
		epoch: props.epoch,
		...(props.issuedAtMilliseconds === undefined
			? {}
			: { issuedAtMilliseconds: props.issuedAtMilliseconds }),
		transferDescriptors: [],
		command,
	};
}

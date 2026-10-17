import type { BridgeMainReviewSourceDisplaySlice } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgeProductNavigationCommand } from '../core/comm-worker/bridge-product-session-contracts.js';

export type BridgeAppNavigationSource = Extract<
	Extract<BridgeProductNavigationCommand, { readonly commandKind: 'activateTarget' }>,
	{ readonly source: unknown }
>['source'];

export type BridgeAppNavigationTargetCommand = Extract<
	BridgeProductNavigationCommand,
	{ readonly commandKind: 'activateTarget' }
>;
type BridgeAppFileNavigationTargetCommand = Extract<
	BridgeAppNavigationTargetCommand,
	{ readonly surface: 'file' }
>;
type BridgeAppReviewNavigationTargetCommand = Extract<
	BridgeAppNavigationTargetCommand,
	{ readonly surface: 'review' }
>;

export interface BridgeAppNavigationAdmissionState {
	readonly acceptedSources: Readonly<Record<'file' | 'review', BridgeAppNavigationSource | null>>;
	readonly activeSurface: 'file' | 'review';
	readonly latestBindingRevision: number;
	readonly latestCommandId: string | null;
	readonly pendingCommand: BridgeAppNavigationTargetCommand | null;
	readonly targetCommands: {
		readonly file: BridgeAppFileNavigationTargetCommand | undefined;
		readonly review: BridgeAppReviewNavigationTargetCommand | undefined;
	};
}

export function createBridgeAppNavigationAdmissionState(
	activeSurface: 'file' | 'review',
): BridgeAppNavigationAdmissionState {
	return {
		acceptedSources: { file: null, review: null },
		activeSurface,
		latestBindingRevision: 0,
		latestCommandId: null,
		pendingCommand: null,
		targetCommands: { file: undefined, review: undefined },
	};
}

export function bridgeAppReviewNavigationSourceForDisplaySlice(
	sourceSlice: BridgeMainReviewSourceDisplaySlice | null,
): Extract<BridgeAppNavigationSource, { readonly sourceKind: 'review' }> | null {
	if (
		sourceSlice === null ||
		sourceSlice.status === 'failed' ||
		sourceSlice.status === 'readyEmpty'
	)
		return null;
	return {
		generation: sourceSlice.reviewGeneration,
		metadataSourceId: sourceSlice.metadataSourceId,
		packageId: sourceSlice.packageId,
		sourceKind: 'review',
	};
}

export function applyBridgeAppNavigationCommand(
	state: BridgeAppNavigationAdmissionState,
	command: BridgeProductNavigationCommand,
): BridgeAppNavigationAdmissionState {
	if (command.bindingRevision < state.latestBindingRevision) return state;
	if (command.bindingRevision === state.latestBindingRevision) return state;
	const nextIdentity = {
		latestBindingRevision: command.bindingRevision,
		latestCommandId: command.commandId,
	};
	if (command.commandKind === 'activateContext') {
		return {
			...state,
			...nextIdentity,
			activeSurface: command.surface,
			pendingCommand: null,
		};
	}
	const acceptedSource = state.acceptedSources[command.surface];
	if (acceptedSource === null || !bridgeAppNavigationSourcesEqual(acceptedSource, command.source)) {
		return {
			...state,
			...nextIdentity,
			pendingCommand: command,
			targetCommands: { ...state.targetCommands, [command.surface]: undefined },
		};
	}
	return {
		...state,
		...nextIdentity,
		activeSurface: command.surface,
		pendingCommand: null,
		targetCommands: { ...state.targetCommands, [command.surface]: command },
	};
}

export function reportBridgeAppAcceptedNavigationSource(
	state: BridgeAppNavigationAdmissionState,
	source: BridgeAppNavigationSource,
): BridgeAppNavigationAdmissionState {
	const surface = source.sourceKind;
	const currentSource = state.acceptedSources[surface];
	if (currentSource !== null && bridgeAppNavigationSourcesEqual(currentSource, source)) {
		return state;
	}
	const currentTargetCommand = state.targetCommands[surface];
	const targetCommands =
		currentTargetCommand === undefined ||
		bridgeAppNavigationSourcesEqual(currentTargetCommand.source, source)
			? state.targetCommands
			: { ...state.targetCommands, [surface]: undefined };
	const pendingCommand = state.pendingCommand;
	const nextState: BridgeAppNavigationAdmissionState = {
		...state,
		acceptedSources: { ...state.acceptedSources, [surface]: source },
		pendingCommand:
			pendingCommand?.surface === surface &&
			!bridgeAppNavigationSourcesEqual(pendingCommand.source, source)
				? null
				: pendingCommand,
		targetCommands,
	};
	if (
		pendingCommand?.surface !== surface ||
		!bridgeAppNavigationSourcesEqual(pendingCommand.source, source)
	) {
		return nextState;
	}
	return {
		...nextState,
		activeSurface: surface,
		pendingCommand: null,
		targetCommands: { ...targetCommands, [surface]: pendingCommand },
	};
}

export function clearBridgeAppAcceptedNavigationSource(
	state: BridgeAppNavigationAdmissionState,
	surface: 'file' | 'review',
): BridgeAppNavigationAdmissionState {
	if (state.acceptedSources[surface] === null && state.targetCommands[surface] === undefined) {
		return state;
	}
	const clearedSource = state.acceptedSources[surface];
	const pendingCommand = state.pendingCommand;
	return {
		...state,
		acceptedSources: { ...state.acceptedSources, [surface]: null },
		pendingCommand:
			pendingCommand?.surface === surface &&
			clearedSource !== null &&
			bridgeAppNavigationSourcesEqual(pendingCommand.source, clearedSource)
				? null
				: pendingCommand,
		targetCommands: { ...state.targetCommands, [surface]: undefined },
	};
}

export function bridgeAppRememberedNavigationTargetIsEligible(
	state: BridgeAppNavigationAdmissionState,
	command: BridgeAppNavigationTargetCommand,
): boolean {
	if (state.activeSurface !== command.surface) return false;
	const rememberedCommand = state.targetCommands[command.surface];
	return (
		rememberedCommand !== undefined &&
		rememberedCommand.commandId === command.commandId &&
		rememberedCommand.bindingRevision === command.bindingRevision &&
		bridgeAppNavigationSourcesEqual(rememberedCommand.source, command.source)
	);
}

function bridgeAppNavigationSourcesEqual(
	left: BridgeAppNavigationSource,
	right: BridgeAppNavigationSource,
): boolean {
	if (left.sourceKind !== right.sourceKind) return false;
	if (left.sourceKind === 'file' && right.sourceKind === 'file') {
		return (
			left.sourceId === right.sourceId &&
			left.subscriptionGeneration === right.subscriptionGeneration
		);
	}
	if (left.sourceKind === 'review' && right.sourceKind === 'review') {
		return (
			left.metadataSourceId === right.metadataSourceId &&
			left.generation === right.generation &&
			left.packageId === right.packageId
		);
	}
	return false;
}

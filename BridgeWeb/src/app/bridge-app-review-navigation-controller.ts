import { useCallback, useEffect, useRef } from 'react';

import type { BridgeProductNavigationCommand } from '../core/comm-worker/bridge-product-session-contracts.js';
import type {
	BridgeWorkerReviewDisplayItem,
	BridgeWorkerSelectCommand,
} from '../core/comm-worker/bridge-worker-contracts.js';
import { recordBridgeReviewSelectionDiagnosticStage } from '../foundation/diagnostics/bridge-review-selection-diagnostic.js';

type BridgeReviewNavigationCommand = Extract<
	BridgeProductNavigationCommand,
	{ readonly commandKind: 'activateTarget'; readonly surface: 'review' }
>;

export type BridgeReviewNavigationSelectionSource = NonNullable<
	BridgeWorkerSelectCommand['selectedSource']
>;

export interface BridgeReviewNavigationTarget {
	readonly commandId: string;
	readonly applicationKey: string;
	readonly itemId: string | null;
	readonly path: string | null;
}

export type BridgeReviewNavigationTargetResolution =
	| { readonly status: 'none' }
	| {
			readonly itemId: string;
			readonly status: 'accepted';
			readonly target: BridgeReviewNavigationTarget;
	  }
	| {
			readonly status: 'outsideAcceptedProjection';
			readonly target: BridgeReviewNavigationTarget;
	  };

export interface UseBridgeReviewNavigationControllerProps {
	readonly catalogRevision: number;
	readonly clearReviewSelection: () => void;
	readonly getReviewItem: (itemId: string) => BridgeWorkerReviewDisplayItem | undefined;
	readonly isActive: boolean;
	readonly isNavigationCommandStillEligible: (command: BridgeReviewNavigationCommand) => boolean;
	readonly navigationCommand: BridgeReviewNavigationCommand | undefined;
	readonly onTargetOutsideAcceptedProjection: (target: BridgeReviewNavigationTarget) => void;
	readonly orderedItemIds: readonly string[];
	readonly selectedItemId: string | null;
	readonly selectInitialReviewItem: (
		itemId: string,
		selectedSource: BridgeReviewNavigationSelectionSource,
	) => boolean | void;
	readonly selectReviewItem: (
		itemId: string,
		selectedSource: BridgeReviewNavigationSelectionSource,
	) => boolean | void;
}

export interface BridgeReviewNavigationController {
	readonly notifyUserSelection: () => void;
}

export function useBridgeReviewNavigationController(
	props: UseBridgeReviewNavigationControllerProps,
): BridgeReviewNavigationController {
	const {
		catalogRevision,
		clearReviewSelection,
		getReviewItem,
		isActive,
		isNavigationCommandStillEligible,
		navigationCommand,
		onTargetOutsideAcceptedProjection,
		orderedItemIds,
		selectedItemId,
		selectInitialReviewItem,
		selectReviewItem,
	} = props;
	const consumedNavigationCommandIdsRef = useRef(new Set<string>());
	const retainedNavigationCommandIdRef = useRef<string | null>(null);
	const pendingLocalSelectionItemIdRef = useRef<string | null>(null);
	const projectionExclusionClearedSelectionRef = useRef(false);

	useEffect((): void => {
		if (
			!isActive ||
			navigationCommand === undefined ||
			!isNavigationCommandStillEligible(navigationCommand) ||
			consumedNavigationCommandIdsRef.current.has(navigationCommand.commandId)
		) {
			return;
		}
		const resolution = resolveBridgeReviewNavigationTarget({
			getReviewItem,
			navigationCommand,
			orderedItemIds,
		});
		if (resolution.status === 'none') {
			return;
		}
		if (resolution.status === 'outsideAcceptedProjection') {
			retainedNavigationCommandIdRef.current = navigationCommand.commandId;
			onTargetOutsideAcceptedProjection(resolution.target);
			return;
		}
		if (selectReviewItem(resolution.itemId, 'programmatic') !== false) {
			// Binding/source changes authorize transport replay, not a second navigation.
			consumedNavigationCommandIdsRef.current.add(navigationCommand.commandId);
			retainedNavigationCommandIdRef.current = null;
			pendingLocalSelectionItemIdRef.current = resolution.itemId;
		}
	}, [
		catalogRevision,
		getReviewItem,
		isActive,
		isNavigationCommandStillEligible,
		navigationCommand,
		onTargetOutsideAcceptedProjection,
		orderedItemIds,
		selectReviewItem,
	]);

	useEffect((): void => {
		if (!isActive) {
			return;
		}
		if (selectedItemId !== null) {
			if (orderedItemIds.includes(selectedItemId)) {
				pendingLocalSelectionItemIdRef.current = null;
				projectionExclusionClearedSelectionRef.current = false;
				return;
			}
			pendingLocalSelectionItemIdRef.current = null;
			projectionExclusionClearedSelectionRef.current = true;
			clearReviewSelection();
			return;
		}
		if (projectionExclusionClearedSelectionRef.current) return;
		const pendingLocalSelectionItemId = pendingLocalSelectionItemIdRef.current;
		if (pendingLocalSelectionItemId !== null) {
			if (orderedItemIds.includes(pendingLocalSelectionItemId)) {
				return;
			}
			pendingLocalSelectionItemIdRef.current = null;
		}
		if (
			navigationCommand !== undefined &&
			!consumedNavigationCommandIdsRef.current.has(navigationCommand.commandId) &&
			bridgeReviewNavigationTargetForCommand(navigationCommand) !== null
		) {
			return;
		}
		const firstProjectedItemId = orderedItemIds[0] ?? null;
		if (firstProjectedItemId === null) {
			pendingLocalSelectionItemIdRef.current = null;
			if (selectedItemId !== null) {
				clearReviewSelection();
			}
			return;
		}
		recordBridgeReviewSelectionDiagnosticStage('initial_selection_requested');
		if (selectInitialReviewItem(firstProjectedItemId, 'programmatic') !== false) {
			recordBridgeReviewSelectionDiagnosticStage('initial_selection_scheduling_accepted');
			pendingLocalSelectionItemIdRef.current = firstProjectedItemId;
		}
	}, [
		catalogRevision,
		clearReviewSelection,
		isActive,
		navigationCommand,
		orderedItemIds,
		selectedItemId,
		selectInitialReviewItem,
	]);
	const notifyUserSelection = useCallback((): void => {
		// User intent wins even when clicking the current item produces no state change.
		if (navigationCommand !== undefined) {
			consumedNavigationCommandIdsRef.current.add(navigationCommand.commandId);
		}
		if (retainedNavigationCommandIdRef.current !== null) {
			consumedNavigationCommandIdsRef.current.add(retainedNavigationCommandIdRef.current);
		}
		retainedNavigationCommandIdRef.current = null;
		pendingLocalSelectionItemIdRef.current = null;
	}, [navigationCommand]);
	return { notifyUserSelection };
}

export function resolveBridgeReviewNavigationTarget(props: {
	readonly getReviewItem: (itemId: string) => BridgeWorkerReviewDisplayItem | undefined;
	readonly navigationCommand: BridgeReviewNavigationCommand;
	readonly orderedItemIds: readonly string[];
}): BridgeReviewNavigationTargetResolution {
	const target = bridgeReviewNavigationTargetForCommand(props.navigationCommand);
	if (target === null) {
		return { status: 'none' };
	}
	const targetItemId =
		target.itemId ??
		props.orderedItemIds.find((itemId): boolean => {
			const item = props.getReviewItem(itemId);
			const displayPath = item?.metadata.headPath ?? item?.metadata.basePath ?? null;
			return displayPath !== null && displayPath === target.path;
		}) ??
		null;
	if (targetItemId === null || !props.orderedItemIds.includes(targetItemId)) {
		return { status: 'outsideAcceptedProjection', target };
	}
	return { itemId: targetItemId, status: 'accepted', target };
}

export function bridgeReviewNavigationTargetForCommand(
	navigationCommand: BridgeReviewNavigationCommand,
): BridgeReviewNavigationTarget | null {
	const target = navigationCommand.target;
	return {
		applicationKey: bridgeReviewNavigationApplicationKey(navigationCommand),
		commandId: navigationCommand.commandId,
		itemId: target.reviewItemId ?? null,
		path: target.path ?? null,
	};
}

function bridgeReviewNavigationApplicationKey(
	navigationCommand: BridgeReviewNavigationCommand,
): string {
	return [
		navigationCommand.commandId,
		navigationCommand.bindingRevision,
		navigationCommand.source.metadataSourceId,
		navigationCommand.source.generation,
		navigationCommand.source.packageId,
	].join('\u0000');
}

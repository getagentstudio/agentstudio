import { useCallback, useState, type ReactElement } from 'react';

import {
	useBridgeReviewNavigationController,
	type BridgeReviewNavigationSelectionSource,
	type BridgeReviewNavigationTarget,
} from '../../app/bridge-app-review-navigation-controller.js';
import type { BridgeProductNavigationCommand } from '../../core/comm-worker/bridge-product-session-contracts.js';

type BridgeReviewTargetNavigationCommand = Extract<
	BridgeProductNavigationCommand,
	{ readonly commandKind: 'activateTarget'; readonly surface: 'review' }
>;
const reviewNavigationCommandIsAlwaysEligible = (): boolean => true;

export function ReviewNavigationControllerProbe(props: {
	readonly events: string[];
	readonly isNavigationCommandStillEligible?: () => boolean;
	readonly initialTargetPending?: boolean;
	readonly initialSelectedItemId?: string;
}): ReactElement {
	const [catalogRevision, setCatalogRevision] = useState(1);
	const [navigationCommand, setNavigationCommand] = useState<BridgeReviewTargetNavigationCommand>(
		() => reviewNavigationCommand('command-one', 'item-one'),
	);
	const [selectedItemId, setSelectedItemId] = useState<string | null>(
		props.initialSelectedItemId ?? null,
	);
	const [orderedItemIds, setOrderedItemIds] = useState<readonly string[]>(
		props.initialTargetPending === true ? ['item-two'] : ['item-one', 'item-two'],
	);
	const clearReviewSelection = useCallback((): void => {
		props.events.push('clear');
		setSelectedItemId(null);
	}, [props.events]);
	const onTargetOutsideAcceptedProjection = useCallback(
		(target: BridgeReviewNavigationTarget): void => {
			props.events.push(`outside:${target.itemId ?? target.path ?? 'unknown'}`);
		},
		[props.events],
	);
	const selectReviewItem = useCallback(
		(itemId: string, selectedSource: BridgeReviewNavigationSelectionSource): true => {
			props.events.push(`select:${itemId}:${selectedSource}`);
			setSelectedItemId(itemId);
			return true;
		},
		[props.events],
	);
	const navigationControllerProps = {
		catalogRevision,
		clearReviewSelection,
		getReviewItem: (): undefined => undefined,
		isNavigationCommandStillEligible:
			props.isNavigationCommandStillEligible ?? reviewNavigationCommandIsAlwaysEligible,
		isActive: true,
		navigationCommand,
		onTargetOutsideAcceptedProjection,
		orderedItemIds,
		selectedItemId,
		selectInitialReviewItem: selectReviewItem,
		selectReviewItem,
	};
	const navigationController = useBridgeReviewNavigationController(navigationControllerProps);
	return (
		<>
			<button
				onClick={(): void => {
					navigationController.notifyUserSelection();
					setSelectedItemId('item-two');
				}}
				type="button"
			>
				Select item-two as user
			</button>
			<button
				onClick={(): void =>
					setNavigationCommand((command) => ({
						...command,
						bindingRevision: command.bindingRevision + 1,
					}))
				}
				type="button"
			>
				Replay binding
			</button>
			<button
				onClick={(): void =>
					setNavigationCommand((command) => ({
						...command,
						source: {
							...command.source,
							generation: command.source.generation + 1,
							metadataSourceId: 'review-successor',
							packageId: 'review-successor-package',
						},
					}))
				}
				type="button"
			>
				Replay source
			</button>
			<button
				onClick={(): void =>
					setNavigationCommand((command) => ({
						...reviewNavigationCommand('command-new', 'item-one'),
						bindingRevision: command.bindingRevision + 1,
					}))
				}
				type="button"
			>
				Navigate with new command
			</button>
			<button
				onClick={(): void =>
					setNavigationCommand((command) => ({
						...reviewNavigationCommand('command-one', 'item-one'),
						bindingRevision: command.bindingRevision + 1,
					}))
				}
				type="button"
			>
				Replay earlier command
			</button>
			<button onClick={(): void => setOrderedItemIds(['item-one', 'item-two'])} type="button">
				Reveal pending target
			</button>
			<button onClick={(): void => setCatalogRevision((revision) => revision + 1)} type="button">
				Advance Review catalog revision
			</button>
			<button onClick={(): void => setOrderedItemIds(['item-one'])} type="button">
				Filter selected Review item
			</button>
			<button
				onClick={(): void =>
					setNavigationCommand(reviewNavigationCommand('command-missing', 'item-missing'))
				}
				type="button"
			>
				Navigate outside Review projection
			</button>
			<output data-testid="review-navigation-selection">{selectedItemId ?? 'none'}</output>
		</>
	);
}

export function reviewNavigationCommand(
	commandId: string,
	reviewItemId: string,
): BridgeReviewTargetNavigationCommand {
	return {
		bindingRevision: 1,
		commandId,
		commandKind: 'activateTarget',
		source: {
			generation: 1,
			metadataSourceId: 'review-fixture',
			packageId: 'review-package',
			sourceKind: 'review',
		},
		surface: 'review',
		target: {
			reviewItemId,
			targetKind: 'review',
		},
	};
}

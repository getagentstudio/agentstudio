import type { CodeViewHandle } from '@pierre/diffs/react';

import {
	bridgeMainPierreItemsHaveEqualPresentationFingerprint,
	prepareBridgeMainPierreItemForPresentation,
} from '../../core/comm-worker/bridge-main-pierre-item-adapter.js';
import type { BridgeCodeViewItem } from './bridge-code-view-materialization.js';
import { isBridgeCodeViewItem } from './bridge-code-view-panel-support.js';
import {
	bridgeCodeViewReanchorBoundFinalItem,
	bridgeCodeViewReanchorContentEquivalentPresentationItem,
	bridgeCodeViewPresentationItemHasExactSource,
	bridgeCodeViewPresentationItemWithExactSource,
	reconcileBridgeCodeViewRenderFulfillment,
	type BridgeCodeViewRenderFulfillmentCoordinator,
} from './bridge-code-view-render-fulfillment.js';

export function prepareBridgeCodeViewPublicationPresentationItem(props: {
	readonly currentItem: BridgeCodeViewItem | undefined;
	readonly getCodeViewHandle: () => CodeViewHandle<undefined> | null;
	readonly metadataItem: BridgeCodeViewItem;
	readonly renderFulfillmentCoordinator: BridgeCodeViewRenderFulfillmentCoordinator;
}): BridgeCodeViewItem {
	if (props.renderFulfillmentCoordinator.isBoundFinalItem(props.metadataItem)) {
		const exactSourceItem = bridgeCodeViewReanchorBoundFinalItem(props.metadataItem);
		const presentation = prepareBridgeMainPierreItemForPresentation({
			currentItem: props.currentItem,
			presentationItem: exactSourceItem,
			reuseCurrentItemWhenFingerprintMatches:
				bridgeCodeViewPresentationItemHasExactSource(props.currentItem, exactSourceItem) ||
				(props.currentItem !== undefined &&
					props.renderFulfillmentCoordinator.isBoundFinalItem(props.currentItem)),
		});
		const retainsAnnotations =
			presentation.residency === 'replaced' &&
			props.currentItem !== undefined &&
			bridgeMainPierreItemsHaveEqualPresentationFingerprint(props.currentItem, presentation.item);
		const presentationItem: BridgeCodeViewItem =
			retainsAnnotations &&
			presentation.item.type === 'diff' &&
			props.currentItem?.type === 'diff' &&
			props.currentItem.annotations !== undefined
				? { ...presentation.item, annotations: props.currentItem.annotations }
				: retainsAnnotations &&
					  presentation.item.type === 'file' &&
					  props.currentItem?.type === 'file' &&
					  props.currentItem.annotations !== undefined
					? { ...presentation.item, annotations: props.currentItem.annotations }
					: presentation.item;
		// Publication binding proves source authority, not the live CodeView invalidation version.
		if (presentation.residency === 'reusedPainted') {
			bridgeCodeViewReanchorContentEquivalentPresentationItem({
				presentationItem,
				sourceItem: exactSourceItem,
			});
			return presentationItem;
		}
		return bridgeCodeViewPresentationItemWithExactSource({
			presentationItem,
			sourceItem: exactSourceItem,
		});
	}
	const preparedItem = prepareBridgeMainPierreItemForPresentation({
		currentItem: props.currentItem,
		presentationItem: props.metadataItem,
		reuseCurrentItemWhenFingerprintMatches:
			bridgeCodeViewPresentationItemHasExactSource(props.currentItem, props.metadataItem) ||
			(props.currentItem !== undefined &&
				props.renderFulfillmentCoordinator.isBoundFinalItem(props.currentItem)),
	});
	props.renderFulfillmentCoordinator.bindPublicationItem({
		finalItem: preparedItem.item,
		publicationItem: props.metadataItem,
		residency: preparedItem.residency,
	});
	bridgeCodeViewReanchorBoundFinalItem(preparedItem.item);
	if (preparedItem.residency === 'reusedPainted') {
		const codeViewHandle = props.getCodeViewHandle();
		const currentHandlePresentationItem = codeViewHandle?.getItem(preparedItem.item.id);
		if (isBridgeCodeViewItem(currentHandlePresentationItem)) {
			bridgeCodeViewReanchorContentEquivalentPresentationItem({
				presentationItem: currentHandlePresentationItem,
				sourceItem: preparedItem.item,
			});
		}
		const renderedPresentationItem = codeViewHandle
			?.getInstance()
			?.getRenderedItems()
			.find((renderedItem): boolean => renderedItem.id === preparedItem.item.id)?.item;
		if (isBridgeCodeViewItem(renderedPresentationItem)) {
			bridgeCodeViewReanchorContentEquivalentPresentationItem({
				presentationItem: renderedPresentationItem,
				sourceItem: preparedItem.item,
			});
		}
		reconcileBridgeCodeViewRenderFulfillment({
			exactPresentationItem: preparedItem.item,
			getCodeViewHandle: props.getCodeViewHandle,
			renderFulfillmentCoordinator: props.renderFulfillmentCoordinator,
		});
	}
	return preparedItem.item;
}

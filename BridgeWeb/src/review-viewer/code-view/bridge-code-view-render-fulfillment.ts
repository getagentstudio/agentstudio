import type { CodeViewItem, PostRenderPhase } from '@pierre/diffs';
import type { CodeViewHandle } from '@pierre/diffs/react';

import { bridgeMainPierreItemsHaveEqualPresentationFingerprint } from '../../core/comm-worker/bridge-main-pierre-item-adapter.js';
import type {
	BridgeMainRenderedItemReadback,
	BridgeMainRenderFulfillmentCoordinator,
	BridgeMainRenderReadback,
} from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import type { BridgeMainCodeViewItem } from '../../core/comm-worker/bridge-main-render-snapshot-store.js';
import { isBridgeCodeViewItem } from './bridge-code-view-panel-support.js';

export type BridgeCodeViewRenderObservationCoordinator = Pick<
	BridgeMainRenderFulfillmentCoordinator,
	'observePostRender' | 'reconcilePublication'
> &
	Partial<Pick<BridgeMainRenderFulfillmentCoordinator, 'isBoundFinalItem' | 'readBoundFinalItem'>>;

export type BridgeCodeViewRenderFulfillmentCoordinator =
	BridgeCodeViewRenderObservationCoordinator &
		Pick<BridgeMainRenderFulfillmentCoordinator, 'bindPublicationItem' | 'isBoundFinalItem'>;

// Pierre annotations require top-level item clones. Keep explicit lineage so paint receipts
// still prove the exact worker metadata and source payload rather than trusting stable IDs alone.
const exactSourceItemByPresentationItem = new WeakMap<object, BridgeMainCodeViewItem>();

export function bridgeCodeViewPresentationItemWithExactSource<
	TBridgeCodeViewItem extends BridgeMainCodeViewItem,
>(props: {
	readonly presentationItem: TBridgeCodeViewItem;
	readonly sourceItem: TBridgeCodeViewItem;
}): TBridgeCodeViewItem {
	const exactSourceItem = exactSourceItemForPresentationItem(props.sourceItem);
	if (!bridgeCodeViewItemsShareExactSource(props.presentationItem, props.sourceItem)) {
		throw new Error('Bridge CodeView presentation item changed its exact worker source payload.');
	}
	exactSourceItemByPresentationItem.set(props.presentationItem, exactSourceItem);
	return props.presentationItem;
}

export function bridgeCodeViewReanchorBoundFinalItem<
	TBridgeCodeViewItem extends BridgeMainCodeViewItem,
>(item: TBridgeCodeViewItem): TBridgeCodeViewItem {
	exactSourceItemByPresentationItem.delete(item);
	return item;
}

export function bridgeCodeViewReanchorContentEquivalentPresentationItem(props: {
	readonly presentationItem: BridgeMainCodeViewItem;
	readonly sourceItem: BridgeMainCodeViewItem;
}): boolean {
	if (
		!bridgeMainPierreItemsHaveEqualPresentationFingerprint(props.presentationItem, props.sourceItem)
	) {
		return false;
	}
	exactSourceItemByPresentationItem.set(props.presentationItem, props.sourceItem);
	return true;
}

export interface ObserveBridgeCodeViewRenderFulfillmentProps {
	readonly contextItem: CodeViewItem;
	readonly getCodeViewHandle: () => CodeViewHandle<undefined> | null;
	readonly itemId: string;
	readonly phase: PostRenderPhase;
	readonly renderedElement?: HTMLElement;
	readonly renderFulfillmentCoordinator: BridgeCodeViewRenderObservationCoordinator;
	readonly selectedCodeViewItem: BridgeMainCodeViewItem | null | undefined;
	readonly visibleCodeViewItems: readonly BridgeMainCodeViewItem[] | undefined;
}

export function observeBridgeCodeViewRenderFulfillment(
	props: ObserveBridgeCodeViewRenderFulfillmentProps,
): void {
	const exactWorkerItem = exactWorkerItemForPostRender(props);
	if (exactWorkerItem === undefined) return;
	const postRenderReadback =
		props.renderedElement === undefined
			? renderReadbackForExactWorkerItem({
					exactWorkerItem,
					getCodeViewHandle: props.getCodeViewHandle,
					itemId: props.itemId,
				})
			: postRenderReadbackForExactWorkerItem({
					exactWorkerItem,
					getCodeViewHandle: props.getCodeViewHandle,
					itemId: props.itemId,
					renderedPresentationItem: props.contextItem,
					renderedElement: props.renderedElement,
				});
	props.renderFulfillmentCoordinator.observePostRender({
		...postRenderReadback,
		contextItem: exactWorkerItem,
		itemId: props.itemId,
		phase: props.phase,
	});
	if (props.phase === 'unmount') return;
	globalThis.queueMicrotask((): void => {
		props.renderFulfillmentCoordinator.reconcilePublication({
			...renderReadbackForExactWorkerItem({
				exactWorkerItem,
				getCodeViewHandle: props.getCodeViewHandle,
				itemId: props.itemId,
			}),
			itemId: props.itemId,
		});
	});
}
export function reconcileBridgeCodeViewRenderFulfillment(props: {
	readonly exactPresentationItem: BridgeMainCodeViewItem;
	readonly getCodeViewHandle: () => CodeViewHandle<undefined> | null;
	readonly renderFulfillmentCoordinator: BridgeCodeViewRenderObservationCoordinator;
}): void {
	props.renderFulfillmentCoordinator.reconcilePublication({
		...renderReadbackForExactWorkerItem({
			exactWorkerItem: props.exactPresentationItem,
			getCodeViewHandle: props.getCodeViewHandle,
			itemId: props.exactPresentationItem.id,
		}),
		itemId: props.exactPresentationItem.id,
	});
}

function exactWorkerItemForPostRender(
	props: ObserveBridgeCodeViewRenderFulfillmentProps,
): BridgeMainCodeViewItem | undefined {
	const boundFinalItem = props.renderFulfillmentCoordinator.readBoundFinalItem?.(props.itemId);
	if (boundFinalItem !== undefined && postRenderContextResolvesSourceItem(props, boundFinalItem)) {
		return boundFinalItem;
	}
	if (isBridgeCodeViewItem(props.contextItem)) {
		const contextSourceItem = exactSourceItemForPresentationItem(props.contextItem);
		if (props.renderFulfillmentCoordinator.isBoundFinalItem?.(contextSourceItem) === true) {
			return contextSourceItem;
		}
	}
	if (props.selectedCodeViewItem !== null && props.selectedCodeViewItem !== undefined) {
		const selectedSourceItem = exactSourceItemForPresentationItem(props.selectedCodeViewItem);
		if (postRenderContextResolvesSourceItem(props, selectedSourceItem)) {
			return selectedSourceItem;
		}
	}
	for (const visibleItem of props.visibleCodeViewItems ?? []) {
		const visibleSourceItem = exactSourceItemForPresentationItem(visibleItem);
		if (postRenderContextResolvesSourceItem(props, visibleSourceItem)) {
			return visibleSourceItem;
		}
	}
	return undefined;
}

function postRenderContextResolvesSourceItem(
	props: ObserveBridgeCodeViewRenderFulfillmentProps,
	exactSourceItem: BridgeMainCodeViewItem,
): boolean {
	if (exactSourceItem.id !== props.itemId) return false;
	if (bridgeCodeViewPresentationItemHasExactSource(props.contextItem, exactSourceItem)) return true;
	if (!isBridgeCodeViewItem(props.contextItem) || props.renderedElement === undefined) return false;
	const codeViewHandle = props.getCodeViewHandle();
	if (codeViewHandle?.getItem(props.itemId) !== props.contextItem) return false;
	const renderedItem = codeViewHandle
		.getInstance()
		?.getRenderedItems()
		.find((candidate): boolean => candidate.id === props.itemId);
	if (
		renderedItem?.item !== props.contextItem ||
		renderedItem.element !== props.renderedElement ||
		!renderedItem.element.isConnected
	) {
		return false;
	}
	return bridgeCodeViewReanchorContentEquivalentPresentationItem({
		presentationItem: props.contextItem,
		sourceItem: exactSourceItem,
	});
}

function postRenderReadbackForExactWorkerItem(props: {
	readonly exactWorkerItem: BridgeMainCodeViewItem;
	readonly getCodeViewHandle: () => CodeViewHandle<undefined> | null;
	readonly itemId: string;
	readonly renderedPresentationItem: CodeViewItem;
	readonly renderedElement: HTMLElement;
}): BridgeMainRenderReadback {
	return {
		readCurrentItem: (): BridgeMainCodeViewItem | undefined => {
			const codeViewHandle = props.getCodeViewHandle();
			if (codeViewHandle === null || codeViewHandle.getInstance() === undefined) {
				return props.exactWorkerItem;
			}
			const currentItem = codeViewHandle.getItem(props.itemId);
			return currentItem === props.renderedPresentationItem ||
				bridgeCodeViewPresentationItemResolvesExactSource(currentItem, props.exactWorkerItem)
				? props.exactWorkerItem
				: undefined;
		},
		readRenderedItem: (): BridgeMainRenderedItemReadback => ({
			element: props.renderedElement,
			item: props.exactWorkerItem,
			readableContentMatchesItem: bridgeCodeViewRenderedItemHasReadableContent({
				element: props.renderedElement,
				item: props.exactWorkerItem,
			}),
		}),
	};
}

function renderReadbackForExactWorkerItem(props: {
	readonly exactWorkerItem: BridgeMainCodeViewItem;
	readonly getCodeViewHandle: () => CodeViewHandle<undefined> | null;
	readonly itemId: string;
}): BridgeMainRenderReadback {
	const exactWorkerItem = exactSourceItemForPresentationItem(props.exactWorkerItem);
	return {
		readCurrentItem: (): BridgeMainCodeViewItem | undefined => {
			const currentItem = props.getCodeViewHandle()?.getItem(props.itemId);
			return bridgeCodeViewPresentationItemResolvesExactSource(currentItem, exactWorkerItem)
				? exactWorkerItem
				: undefined;
		},
		readRenderedItem: (): BridgeMainRenderedItemReadback | null => {
			const renderedItem = props
				.getCodeViewHandle()
				?.getInstance()
				?.getRenderedItems()
				.find((candidate): boolean => candidate.id === props.itemId);
			if (
				renderedItem === undefined ||
				!bridgeCodeViewPresentationItemResolvesExactSource(renderedItem.item, exactWorkerItem)
			) {
				return null;
			}
			return {
				element: renderedItem.element,
				item: exactWorkerItem,
				readableContentMatchesItem: bridgeCodeViewRenderedItemHasReadableContent({
					element: renderedItem.element,
					item: exactWorkerItem,
				}),
			};
		},
	};
}

function bridgeCodeViewPresentationItemResolvesExactSource(
	presentationItem: CodeViewItem | undefined,
	exactSourceItem: BridgeMainCodeViewItem,
): boolean {
	if (bridgeCodeViewPresentationItemHasExactSource(presentationItem, exactSourceItem)) return true;
	return (
		isBridgeCodeViewItem(presentationItem) &&
		bridgeCodeViewReanchorContentEquivalentPresentationItem({
			presentationItem,
			sourceItem: exactSourceItem,
		})
	);
}

function exactSourceItemForPresentationItem(item: BridgeMainCodeViewItem): BridgeMainCodeViewItem {
	return exactSourceItemByPresentationItem.get(item) ?? item;
}

export function bridgeCodeViewPresentationItemHasExactSource(
	presentationItem: CodeViewItem | undefined,
	exactSourceItem: BridgeMainCodeViewItem,
): boolean {
	if (presentationItem === undefined) return false;
	return (
		exactSourceItemByPresentationItem.get(presentationItem) === exactSourceItem ||
		presentationItem === exactSourceItem
	);
}

function bridgeCodeViewItemsShareExactSource(
	presentationItem: BridgeMainCodeViewItem,
	exactSourceItem: BridgeMainCodeViewItem,
): boolean {
	if (
		presentationItem.id !== exactSourceItem.id ||
		presentationItem.type !== exactSourceItem.type ||
		presentationItem.bridgeMetadata !== exactSourceItem.bridgeMetadata
	) {
		return false;
	}
	return presentationItem.type === 'file' && exactSourceItem.type === 'file'
		? presentationItem.file === exactSourceItem.file
		: presentationItem.type === 'diff' &&
				exactSourceItem.type === 'diff' &&
				presentationItem.fileDiff === exactSourceItem.fileDiff;
}

function bridgeCodeViewRenderedItemHasReadableContent(props: {
	readonly element: HTMLElement;
	readonly item: BridgeMainCodeViewItem;
}): boolean {
	const item = props.item;
	if (item.type === 'file') {
		const renderedLineElements = queryOpenShadowRoots(
			props.element,
			'[data-line][data-line-index]',
		);
		if (item.file.contents.length === 0 && item.bridgeMetadata.lineCount !== 0) return false;
		return bridgeCodeViewRenderedSourceHasReadableContent({
			renderedLineElements,
			sourceLineAtNumber: (lineNumber): string | null =>
				bridgeCodeViewFileSourceLineAtIndex(item.file.contents, lineNumber - 1),
			...(item.file.contents.length === 0 ? { sourceLineCount: 0 } : {}),
		});
	}
	const fileDiff = item.fileDiff;
	if (
		fileDiff.deletionLines.length === 0 &&
		fileDiff.additionLines.length === 0 &&
		item.bridgeMetadata.lineCount !== 0
	)
		return false;
	return (
		bridgeCodeViewRenderedSourceHasReadableContent({
			renderedLineElements: queryOpenShadowRoots(
				props.element,
				'[data-deletions] [data-line][data-line-index]',
			),
			sourceLineAtNumber: (lineNumber): string | null =>
				bridgeCodeViewDiffSourceLineAtNumber({
					fileDiff,
					lineNumber,
					side: 'deletions',
				}),
			sourceLineCount: fileDiff.deletionLines.length,
		}) &&
		bridgeCodeViewRenderedSourceHasReadableContent({
			renderedLineElements: queryOpenShadowRoots(
				props.element,
				'[data-additions] [data-line][data-line-index]',
			),
			sourceLineAtNumber: (lineNumber): string | null =>
				bridgeCodeViewDiffSourceLineAtNumber({
					fileDiff,
					lineNumber,
					side: 'additions',
				}),
			sourceLineCount: fileDiff.additionLines.length,
		})
	);
}

function bridgeCodeViewRenderedSourceHasReadableContent(props: {
	readonly renderedLineElements: readonly Element[];
	readonly sourceLineAtNumber: (lineNumber: number) => string | null;
	readonly sourceLineCount?: number;
}): boolean {
	if (props.sourceLineCount === 0) return props.renderedLineElements.length === 0;
	if (props.renderedLineElements.length === 0) return false;
	return props.renderedLineElements.every((lineElement): boolean => {
		const lineNumber = Number.parseInt(lineElement.getAttribute('data-line') ?? '', 10);
		if (!Number.isInteger(lineNumber) || lineNumber <= 0) return false;
		const expectedSourceLine = props.sourceLineAtNumber(lineNumber);
		if (expectedSourceLine === null) return false;
		return (
			bridgeCodeViewNormalizeRenderedLine(lineElement.textContent ?? '') ===
			bridgeCodeViewNormalizeRenderedLine(expectedSourceLine)
		);
	});
}

function bridgeCodeViewNormalizeRenderedLine(line: string): string {
	return line.replace(/(?:\r\n|\r|\n)$/, '');
}

function bridgeCodeViewDiffSourceLineAtNumber(props: {
	readonly fileDiff: Extract<BridgeMainCodeViewItem, { readonly type: 'diff' }>['fileDiff'];
	readonly lineNumber: number;
	readonly side: 'additions' | 'deletions';
}): string | null {
	if (!Number.isInteger(props.lineNumber) || props.lineNumber <= 0) return null;
	const isAddition = props.side === 'additions';
	for (const hunk of props.fileDiff.hunks) {
		const lineStart = isAddition ? hunk.additionStart : hunk.deletionStart;
		const lineCount = isAddition ? hunk.additionCount : hunk.deletionCount;
		if (props.lineNumber < lineStart || props.lineNumber >= lineStart + lineCount) continue;
		const firstSourceLineIndex = isAddition ? hunk.additionLineIndex : hunk.deletionLineIndex;
		const sourceLines = isAddition ? props.fileDiff.additionLines : props.fileDiff.deletionLines;
		return sourceLines[firstSourceLineIndex + props.lineNumber - lineStart] ?? null;
	}
	return null;
}

function bridgeCodeViewFileSourceLineAtIndex(
	contents: string,
	targetLineIndex: number,
): string | null {
	if (!Number.isInteger(targetLineIndex) || targetLineIndex < 0) return null;
	let currentLineIndex = 0;
	let currentLineStart = 0;
	for (let characterIndex = 0; characterIndex < contents.length; characterIndex += 1) {
		const character = contents[characterIndex];
		if (character !== '\n' && character !== '\r') continue;
		if (currentLineIndex === targetLineIndex) {
			return contents.slice(currentLineStart, characterIndex);
		}
		if (character === '\r' && contents[characterIndex + 1] === '\n') {
			characterIndex += 1;
		}
		currentLineIndex += 1;
		currentLineStart = characterIndex + 1;
	}
	return currentLineIndex === targetLineIndex ? contents.slice(currentLineStart) : null;
}

function queryOpenShadowRoots(root: Element | ShadowRoot, selector: string): readonly Element[] {
	const matches = [...root.querySelectorAll(selector)];
	if (root instanceof Element && root.shadowRoot !== null) {
		matches.push(...queryOpenShadowRoots(root.shadowRoot, selector));
	}
	for (const descendant of root.querySelectorAll('*')) {
		if (descendant.shadowRoot !== null) {
			matches.push(...queryOpenShadowRoots(descendant.shadowRoot, selector));
		}
	}
	return matches;
}

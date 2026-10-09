import {
	CodeView,
	parseDiffFromFile,
	type CodeViewDiffItem,
	type CodeViewItem,
	type CodeViewOptions,
	type PostRenderPhase,
} from '@pierre/diffs';
import { act } from 'react';
import { describe, expect, test } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../../app/bridge-app.css';
import { prepareBridgeMainPierreItemForPresentation } from '../../core/comm-worker/bridge-main-pierre-item-adapter.js';
import {
	createBridgeMainRenderFulfillmentCoordinator,
	type BridgeMainRenderPublicationItem,
} from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import { bridgeWorkerTestReviewPublicationIdentity } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.test-support.js';
import {
	bridgeWorkerReviewPierreRenderJobEventSchema,
	type BridgeWorkerReviewPierreRenderJobEvent,
} from '../../core/comm-worker/bridge-worker-contracts.js';
import { buildBridgeWorkerPierreRenderJob } from '../../core/comm-worker/bridge-worker-pierre-render-job.js';
import type { BridgeWorkerRenderDispositionReceipt } from '../../core/comm-worker/bridge-worker-render-fulfillment.js';
import { makeBridgeWorkerRenderReceiptIdentity } from '../../core/comm-worker/bridge-worker-render-fulfillment.test-support.js';
import { makeBridgeReviewPackage } from '../../foundation/review-package/bridge-review-package-test-support.js';
import type { BridgeReviewPackage } from '../../foundation/review-package/bridge-review-package.js';
import { createWorktreeAnnotationBrowserProviderHarness } from '../../worktree-annotations/worktree-annotation-browser-test-support.js';
import { buildBridgeReviewProjection } from '../navigation/review-projection.js';
import { waitForBridgeViewerCodeHeaderCollapseButton } from '../test-support/bridge-viewer-browser-dom.js';
import { bridgePierreOptionalHighlightLanguage } from '../workers/pierre/bridge-pierre-language-normalization.js';
import { BridgeCodeViewPanel } from './bridge-code-view-panel.js';
import {
	assertBridgeCodeViewHeaderGeometry,
	createExactItemReceiptLog,
	paintedSourceCorrelations,
	requireCurrentRenderedReviewRows,
	requireMountedCodeView,
	type ExactItemReceiptLog,
} from './bridge-code-view-panel.render-fulfillment.browser.test-support.js';

type ExactReviewPierreDiffItem = Extract<
	BridgeMainRenderPublicationItem,
	{ readonly type: 'diff' }
> &
	CodeViewDiffItem;

interface CapturedBridgeCodeViewPostRender {
	readonly contextItem: CodeViewItem;
	readonly invoke: (props: {
		readonly contextItem?: CodeViewItem;
		readonly phase: PostRenderPhase;
	}) => void;
}
interface PendingAnimationFrame {
	readonly callback: FrameRequestCallback;
	readonly frameHandle: number;
}
describe('BridgeCodeViewPanel render fulfillment', () => {
	test('keeps Pierre-retained readable content when the same semantic item is selected without a keyed frontend copy', async () => {
		const annotationHarness = createWorktreeAnnotationBrowserProviderHarness('review');
		// Pierre retains a hydrated item after its controller-facing keyed copy disappears.
		const mountedCodeView: { current: CodeView | null } = { current: null };
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetup = CodeView.prototype.setup;
		CodeView.prototype.setup = function captureMountedCodeView(root: HTMLElement): void {
			mountedCodeView.current = this;
			originalSetup.call(this, root);
		};
		const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
			cancelAnimationFrame: (frameHandle): void => cancelAnimationFrame(frameHandle),
			nowMilliseconds: (): number => performance.now(),
			requestAnimationFrame: (callback): number => requestAnimationFrame(callback),
			sendDisposition: (): void => {},
		});
		const publicationItem = requireExactReviewPierreDiffItem(
			makeReviewPublication({
				contentsMarker: 'retained-readable-selection',
				publicationSequence: 1,
				version: 17,
			}).job.payload.item,
		);
		const retainedReadableItem = prepareBridgeMainPierreItemForPresentation({
			currentItem: undefined,
			presentationItem: publicationItem,
		}).item;
		const reviewPackage = makeBridgeReviewPackage();
		const reviewItem = reviewPackage.itemsById[publicationItem.id];
		if (reviewItem === undefined) {
			throw new Error('Expected the Review fixture item for retained-readable selection.');
		}
		const semanticallyCurrentReviewPackage = {
			...reviewPackage,
			itemsById: {
				...reviewPackage.itemsById,
				[publicationItem.id]: {
					...reviewItem,
					cacheKey: publicationItem.bridgeMetadata.cacheKey,
				},
			},
		} satisfies BridgeReviewPackage;
		const projection = buildBridgeReviewProjection({
			reviewPackage: semanticallyCurrentReviewPackage,
			request: { facets: [], mode: { kind: 'normalReview' } },
		});
		const panelProps = {
			presentationPositionKey: 'retained-readable-selection-position',
			projection,
			renderFulfillmentCoordinator,
			reviewPackage: semanticallyCurrentReviewPackage,
			selectedCodeViewItem: null,
			selectedItemId: null,
			visibleCodeViewItems: [retainedReadableItem],
			workerPoolEnabled: false,
		};
		const rendered = await render(annotationHarness.wrap(<BridgeCodeViewPanel {...panelProps} />));

		try {
			await settleBridgeCodeViewState(
				(): boolean =>
					mountedCodeView.current?.getItem(publicationItem.id) === retainedReadableItem,
				'Expected Pierre to retain the hydrated visible Review item before selection.',
			);

			// Act: the same semantic item becomes selected after its keyed frontend copy was reset.
			await act(async (): Promise<void> => {
				await rendered.rerender(
					annotationHarness.wrap(
						<BridgeCodeViewPanel
							{...panelProps}
							selectedContentLoadingItemId={publicationItem.id}
							selectedItemId={publicationItem.id}
							visibleCodeViewItems={[]}
						/>,
					),
				);
				await Promise.resolve();
			});
			await act(async (): Promise<void> => {
				await new Promise<void>((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
				await Promise.resolve();
			});

			// Assert: selection alone must not blank semantically current readable residency.
			const itemAfterSelection = requireCurrentReviewPierreDiffItem(
				requireMountedCodeView(mountedCodeView.current),
				publicationItem.id,
			);
			expect(itemAfterSelection.bridgeMetadata.contentState).toBe('hydrated');
			expect(itemAfterSelection).toBe(retainedReadableItem);

			// Act: the same item id now describes different source content.
			const changedReviewPackage = {
				...semanticallyCurrentReviewPackage,
				revision: semanticallyCurrentReviewPackage.revision + 1,
				itemsById: {
					...semanticallyCurrentReviewPackage.itemsById,
					[publicationItem.id]: {
						...reviewItem,
						cacheKey: 'changed-base-content|changed-head-content',
						itemVersion: reviewItem.itemVersion + 1,
					},
				},
			} satisfies BridgeReviewPackage;
			const changedProjection = buildBridgeReviewProjection({
				reviewPackage: changedReviewPackage,
				request: { facets: [], mode: { kind: 'normalReview' } },
			});
			await act(async (): Promise<void> => {
				await rendered.rerender(
					annotationHarness.wrap(
						<BridgeCodeViewPanel
							{...panelProps}
							projection={changedProjection}
							reviewPackage={changedReviewPackage}
							selectedContentLoadingItemId={publicationItem.id}
							selectedItemId={publicationItem.id}
							visibleCodeViewItems={[]}
						/>,
					),
				);
				await Promise.resolve();
			});

			// Assert: readable residency is not preserved across a content-identity change.
			await settleBridgeCodeViewState((): boolean => {
				const currentItem = mountedCodeView.current?.getItem(publicationItem.id);
				return (
					currentItem !== undefined &&
					isExactReviewPierreDiffItem(currentItem) &&
					currentItem.bridgeMetadata.contentState === 'loading'
				);
			}, 'Expected changed Review content identity to replace retained residency with loading.');
		} finally {
			CodeView.prototype.setup = originalSetup;
			renderFulfillmentCoordinator.dispose();
		}
	});

	test('adapts Review items with main versions, preserves collapse, and reuses exact painted residency', async () => {
		const annotationHarness = createWorktreeAnnotationBrowserProviderHarness('review');
		// Hold Pierre's post-render callback while retaining a real CodeView and public readbacks.
		const mountedCodeView: { current: CodeView | null } = { current: null };
		const capturedPostRenderLog = createExactItemReceiptLog<
			CodeViewItem,
			CapturedBridgeCodeViewPostRender
		>();
		const capturedPostRenders = capturedPostRenderLog.receipts;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetup = CodeView.prototype.setup;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetOptions = CodeView.prototype.setOptions;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalUpdateItem = CodeView.prototype.updateItem;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetItems = CodeView.prototype.setItems;
		const pierreUpdatedItems: CodeViewItem[] = [];
		const pierreSetItemsCalls: Array<readonly CodeViewItem[]> = [];
		CodeView.prototype.setup = function captureMountedCodeView(root: HTMLElement): void {
			mountedCodeView.current = this;
			originalSetup.call(this, root);
		};
		CodeView.prototype.setOptions = function capturePostRender(
			options: CodeViewOptions<undefined> | undefined,
		): void {
			const onPostRender = options?.onPostRender;
			if (onPostRender === undefined) {
				originalSetOptions.call(this, options);
				return;
			}
			const capturedOptions = {
				...options,
				onPostRender: (...callbackArguments: readonly unknown[]): void => {
					captureBridgeCodeViewPostRender({
						callback: onPostRender,
						callbackArguments,
						log: capturedPostRenderLog,
					});
				},
			} satisfies CodeViewOptions<undefined>;
			originalSetOptions.call(this, capturedOptions);
		};
		CodeView.prototype.updateItem = function captureUpdatedItem(item: CodeViewItem): boolean {
			pierreUpdatedItems.push(item);
			return originalUpdateItem.call(this, item);
		};
		CodeView.prototype.setItems = function captureSetItems(items: readonly CodeViewItem[]): void {
			pierreSetItemsCalls.push(items);
			originalSetItems.call(this, items);
		};

		const dispositions: BridgeWorkerRenderDispositionReceipt[] = [];
		const pendingAnimationFrames: PendingAnimationFrame[] = [];
		let nextFrameHandle = 1;
		let nowMilliseconds = 1_000;
		const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
			cancelAnimationFrame: (frameHandle): void => {
				const frameIndex = pendingAnimationFrames.findIndex(
					(frame): boolean => frame.frameHandle === frameHandle,
				);
				if (frameIndex >= 0) pendingAnimationFrames.splice(frameIndex, 1);
			},
			nowMilliseconds: (): number => {
				nowMilliseconds += 1;
				return nowMilliseconds;
			},
			requestAnimationFrame: (callback): number => {
				const frameHandle = nextFrameHandle;
				nextFrameHandle += 1;
				pendingAnimationFrames.push({ callback, frameHandle });
				return frameHandle;
			},
			sendDisposition: (receipt): void => {
				dispositions.push(receipt);
			},
		});
		const firstPublication = makeReviewPublication({
			contentRole: 'head',
			contentsMarker: 'first-attempt',
			publicationSequence: 1,
			version: 37,
		});
		const firstPublicationItem = requireExactReviewPierreDiffItem(
			firstPublication.job.payload.item,
		);
		const defaultReviewPackage = makeBridgeReviewPackage();
		const defaultReviewItem = defaultReviewPackage.itemsById['item-source'];
		if (defaultReviewItem === undefined) {
			throw new Error('Expected the Review fixture descriptor.');
		}
		const reviewPackage = {
			...defaultReviewPackage,
			itemsById: {
				...defaultReviewPackage.itemsById,
				'item-source': { ...defaultReviewItem, additions: 17, deletions: 9 },
			},
			summary: { ...defaultReviewPackage.summary, additions: 17, deletions: 9 },
		};
		const projection = buildBridgeReviewProjection({
			reviewPackage,
			request: { facets: [], mode: { kind: 'normalReview' } },
		});
		renderFulfillmentCoordinator.acceptPublication(firstPublication);
		const firstControllerPreparedItem = prepareBridgeMainPierreItemForPresentation({
			currentItem: undefined,
			presentationItem: firstPublicationItem,
		});
		const firstControllerSeedItem = firstControllerPreparedItem.item;
		renderFulfillmentCoordinator.bindPublicationItem({
			finalItem: firstControllerSeedItem,
			publicationItem: firstPublicationItem,
			residency: firstControllerPreparedItem.residency,
		});
		renderFulfillmentCoordinator.markPublicationQueued(firstPublication);
		expect(dispositionKinds(dispositions)).toEqual(['queued']);

		const panelProps = {
			onOpenFile: (): void => {},
			presentationPositionKey: 'render-fulfillment-position',
			projection,
			renderFulfillmentCoordinator,
			reviewPackage,
			selectedCodeViewItem: firstControllerSeedItem,
			selectedItemId: firstPublicationItem.id,
			visibleCodeViewItems: [firstControllerSeedItem],
			workerPoolEnabled: false,
		};
		const rendered = await render(annotationHarness.wrap(<BridgeCodeViewPanel {...panelProps} />));

		try {
			await settleBridgeCodeViewState((): boolean => {
				const currentItem = mountedCodeView.current?.getItem(firstPublicationItem.id);
				return (
					currentItem !== undefined &&
					isExactReviewPierreDiffItem(currentItem) &&
					currentItem !== firstPublicationItem &&
					currentItem.bridgeMetadata.cacheKey === firstPublicationItem.bridgeMetadata.cacheKey
				);
			}, 'Expected Pierre current item to become the first main-adapted Review object.');
			const firstCodeView = requireMountedCodeView(mountedCodeView.current);
			const firstFinalItem = requireCurrentReviewPierreDiffItem(
				firstCodeView,
				firstPublicationItem.id,
			);
			expect(firstPublicationItem.version).toBe(37);
			expect(firstControllerSeedItem).not.toBe(firstPublicationItem);
			expect(firstControllerSeedItem.version).toBe(1);
			expect(firstFinalItem).not.toBe(firstPublicationItem);
			expect.soft(firstFinalItem.version).toBe(1);
			await settleBridgeCodeViewState(
				(): boolean =>
					firstCodeView
						.getRenderedItems()
						.some(
							(renderedItem): boolean =>
								renderedItem.id === firstFinalItem.id &&
								renderedItem.item === firstFinalItem &&
								renderedItem.element.isConnected,
						),
				'Expected Pierre rendered membership to carry the exact first final Review object.',
			);
			await act(async (): Promise<void> => {
				await capturedPostRenderLog.waitForItem(firstFinalItem);
			});
			await settleBridgeCodeViewState(
				(): boolean =>
					document.querySelector('[data-testid="bridge-code-view-header-metadata"]') !== null,
				'Expected the Bridge descriptor header metadata to render.',
			);
			const metadata = document.querySelector('[data-testid="bridge-code-view-header-metadata"]');
			if (!(metadata instanceof HTMLElement)) {
				throw new Error('Expected mounted Bridge descriptor header metadata.');
			}
			const metadataCounts = [...metadata.querySelectorAll(':scope > span')].filter(
				(element): boolean => element.textContent === '-9' || element.textContent === '+17',
			);
			expect(metadataCounts.map((element): string | null => element.textContent)).toEqual([
				'-9',
				'+17',
			]);
			for (const metadataCount of metadataCounts) {
				const metadataCountBox = metadataCount.getBoundingClientRect();
				expect(getComputedStyle(metadataCount).display).not.toBe('none');
				expect(metadataCountBox.width).toBeGreaterThan(0);
				expect(metadataCountBox.height).toBeGreaterThan(0);
			}
			const pierreContainer = document.querySelector('diffs-container');
			if (!(pierreContainer instanceof HTMLElement) || pierreContainer.shadowRoot === null) {
				throw new Error('Expected mounted Pierre diffs-container shadow DOM.');
			}
			const pierreAdditionCounters = [
				...pierreContainer.shadowRoot.querySelectorAll('[data-additions-count]'),
			];
			const pierreDeletionCounters = [
				...pierreContainer.shadowRoot.querySelectorAll('[data-deletions-count]'),
			];
			const pierreHeaderTitle = pierreContainer.shadowRoot.querySelector('[data-title]');
			if (!(pierreHeaderTitle instanceof HTMLElement)) {
				throw new Error('Expected the surrounding Pierre header navigation title.');
			}
			assertBridgeCodeViewHeaderGeometry({ metadata, pierreHeaderTitle });
			const surroundingNavigationFontSize = Number.parseFloat(
				getComputedStyle(pierreHeaderTitle).fontSize,
			);
			expect(surroundingNavigationFontSize).toBe(12);
			for (const metadataCount of metadataCounts) {
				const metadataCountStyle = getComputedStyle(metadataCount);
				const metadataCountFontSize = Number.parseFloat(metadataCountStyle.fontSize);
				expect(metadataCountFontSize).toBe(9);
				expect(metadataCountFontSize).toBeLessThan(surroundingNavigationFontSize);
				expect(Number.parseFloat(metadataCountStyle.lineHeight)).toBe(12);
				expect(metadataCountStyle.fontVariantNumeric).toContain('tabular-nums');
				const metadataCountBox = metadataCount.getBoundingClientRect();
				const headerTitleBox = pierreHeaderTitle.getBoundingClientRect();
				expect(
					Math.abs(
						metadataCountBox.y +
							metadataCountBox.height / 2 -
							(headerTitleBox.y + headerTitleBox.height / 2),
					),
				).toBeLessThanOrEqual(1);
			}
			expect(pierreAdditionCounters).toHaveLength(1);
			expect(pierreDeletionCounters).toHaveLength(0);
			for (const pierreCounter of [...pierreAdditionCounters, ...pierreDeletionCounters]) {
				const counterBox = pierreCounter.getBoundingClientRect();
				expect(
					getComputedStyle(pierreCounter).display === 'none' ||
						counterBox.width === 0 ||
						counterBox.height === 0,
				).toBe(true);
			}
			const firstPostRender = requirePostRenderForItem(capturedPostRenders, firstFinalItem);

			// The exact main-adapted item is both Pierre's current record and rendered member. The raw
			// structured-clone publication cannot settle the attempt.
			expect(firstCodeView.getItem(firstFinalItem.id)).toBe(firstFinalItem);
			expect(
				firstCodeView
					.getRenderedItems()
					.find((renderedItem): boolean => renderedItem.id === firstFinalItem.id)?.item,
			).toBe(firstFinalItem);
			const dispositionPrefixBeforeManualCallbacks = dispositionKinds(dispositions);
			expect([['queued'], ['queued', 'applied']]).toContainEqual(
				dispositionPrefixBeforeManualCallbacks,
			);
			await invokeCapturedPostRenderWithinAct({ invocation: firstPostRender, phase: 'unmount' });
			expect(dispositionKinds(dispositions)).toEqual(dispositionPrefixBeforeManualCallbacks);
			await invokeCapturedPostRenderWithinAct({
				contextItem: firstPublicationItem,
				invocation: firstPostRender,
				phase: 'update',
			});
			expect(dispositionKinds(dispositions)).toEqual(dispositionPrefixBeforeManualCallbacks);

			const wrongContextItem = { ...firstFinalItem, version: 92 };
			await invokeCapturedPostRenderWithinAct({
				contextItem: wrongContextItem,
				invocation: firstPostRender,
				phase: 'update',
			});
			expect(dispositionKinds(dispositions)).toEqual(dispositionPrefixBeforeManualCallbacks);

			// Exact connected readable reconciliation advances applied; frame validation remains pending.
			const initialRenderedRows = requireCurrentRenderedReviewRows(firstCodeView, firstFinalItem);
			if (initialRenderedRows.baseLines.length !== 0 || initialRenderedRows.headLines.length < 2) {
				throw new Error('Expected added-only Pierre head rows and no base rows.');
			}
			const originalHeadText = initialRenderedRows.headLines.map(
				(line): string => line.textContent ?? '',
			);
			await invokeCapturedPostRenderWithinAct({
				invocation: firstPostRender,
				phase: 'update',
			});
			expect(dispositionKinds(dispositions)).toEqual(['queued', 'applied']);
			expect(pendingAnimationFrames).toHaveLength(1);
			expect(dispositionKinds(dispositions)).not.toContain('painted');
			const pendingPaintFrame = pendingAnimationFrames.shift();
			if (pendingPaintFrame === undefined) {
				throw new Error('Expected matching post-render readback to schedule paint validation.');
			}
			requireCurrentRenderedReviewRows(firstCodeView, firstFinalItem).clearHeadText();
			pendingPaintFrame.callback(nowMilliseconds);
			expect(dispositionKinds(dispositions)).toEqual(['queued', 'applied', 'painted']);
			expect(
				paintedSourceCorrelations(
					requireCurrentRenderedReviewRows(firstCodeView, firstFinalItem).element,
				),
			).toBeNull();
			const restoredRows = requireCurrentRenderedReviewRows(firstCodeView, firstFinalItem);
			for (const [lineIndex, headLine] of restoredRows.headLines.entries()) {
				headLine.textContent = originalHeadText[lineIndex] ?? '';
			}

			// A real user collapse is local presentation state. A changed same-id publication must
			// preserve it while minting the next main-owned version.
			const collapseButton = await waitForBridgeViewerCodeHeaderCollapseButton();
			await act(async (): Promise<void> => {
				collapseButton.click();
				await Promise.resolve();
			});
			await settleBridgeCodeViewState((): boolean => {
				const currentItem = firstCodeView.getItem(firstFinalItem.id);
				return (
					currentItem !== undefined &&
					isExactReviewPierreDiffItem(currentItem) &&
					currentItem !== firstFinalItem &&
					currentItem.collapsed === true
				);
			}, 'Expected the public Review collapse control to install one exact collapsed item.');
			const collapsedItem = requireCurrentReviewPierreDiffItem(firstCodeView, firstFinalItem.id);
			expect(collapsedItem.collapsed).toBe(true);
			expect(collapsedItem.version).toBe((firstFinalItem.version ?? 0) + 1);

			const secondPublication = makeReviewPublication({
				contentsMarker: 'second-attempt',
				publicationSequence: 2,
				version: 93,
			});
			const secondPublicationItem = requireExactReviewPierreDiffItem(
				secondPublication.job.payload.item,
			);
			expect(secondPublicationItem).not.toBe(firstPublicationItem);
			expect(secondPublicationItem.version).toBe(93);
			renderFulfillmentCoordinator.acceptPublication(secondPublication);
			renderFulfillmentCoordinator.markPublicationQueued(secondPublication);
			expect(dispositionKinds(dispositions)).toEqual(['queued', 'applied', 'painted']);
			await invokeCapturedPostRenderWithinAct({ invocation: firstPostRender, phase: 'update' });
			expect(dispositionKinds(dispositions)).toEqual(['queued', 'applied', 'painted']);

			const secondPanelProps = {
				...panelProps,
				selectedCodeViewItem: secondPublicationItem,
				visibleCodeViewItems: [secondPublicationItem],
			};
			await act(async (): Promise<void> => {
				await rendered.rerender(
					annotationHarness.wrap(<BridgeCodeViewPanel {...secondPanelProps} />),
				);
				await Promise.resolve();
			});
			await settleBridgeCodeViewState((): boolean => {
				const currentItem = firstCodeView.getItem(secondPublicationItem.id);
				return (
					currentItem !== undefined &&
					isExactReviewPierreDiffItem(currentItem) &&
					currentItem !== secondPublicationItem &&
					currentItem.collapsed === true &&
					currentItem.bridgeMetadata.cacheKey === secondPublicationItem.bridgeMetadata.cacheKey
				);
			}, 'Expected Pierre current item to become the collapse-preserving second final object.');
			const secondFinalItem = requireCurrentReviewPierreDiffItem(
				firstCodeView,
				secondPublicationItem.id,
			);
			expect(secondFinalItem).not.toBe(secondPublicationItem);
			expect(secondFinalItem.collapsed).toBe(true);
			expect(secondFinalItem.version).toBe((collapsedItem.version ?? 0) + 1);
			await settleBridgeCodeViewState(
				(): boolean =>
					firstCodeView
						.getRenderedItems()
						.some(
							(renderedItem): boolean =>
								renderedItem.id === secondFinalItem.id &&
								renderedItem.item === secondFinalItem &&
								renderedItem.element.isConnected,
						),
				'Expected Pierre rendered membership to carry the exact second final Review object.',
			);
			await act(async (): Promise<void> => {
				await capturedPostRenderLog.waitForItem(secondFinalItem);
			});
			const secondPostRender = requirePostRenderForItem(capturedPostRenders, secondFinalItem);
			expect([
				['queued', 'applied', 'painted', 'queued'],
				['queued', 'applied', 'painted', 'queued', 'applied'],
			]).toContainEqual(dispositionKinds(dispositions));

			await invokeCapturedPostRenderWithinAct({ invocation: firstPostRender, phase: 'update' });
			await invokeCapturedPostRenderWithinAct({ invocation: secondPostRender, phase: 'update' });
			const secondAppliedKinds = ['queued', 'applied', 'painted', 'queued', 'applied'];
			await settleBridgeCodeViewState(
				(): boolean => dispositionKinds(dispositions).length === secondAppliedKinds.length,
				'Expected the second exact Review attempt to reach applied.',
			);
			expect(dispositionKinds(dispositions)).toEqual(secondAppliedKinds);
			expect(pendingAnimationFrames).toHaveLength(1);
			const secondPendingPaintFrame = pendingAnimationFrames.shift();
			if (secondPendingPaintFrame === undefined) {
				throw new Error('Expected the second exact Review attempt to schedule paint validation.');
			}
			secondPendingPaintFrame.callback(nowMilliseconds);
			const secondPaintedKinds = [...secondAppliedKinds, 'painted'];
			expect(dispositionKinds(dispositions)).toEqual(secondPaintedKinds);

			// A fresh worker attempt with an equal final fingerprint binds to the exact connected
			// painted object and settles without asking Pierre for another content render.
			const retryPublication = cloneReviewPublicationForRetry(secondPublication);
			const retryPublicationItem = requireExactReviewPierreDiffItem(
				retryPublication.job.payload.item,
			);
			const pierreUpdateItemCountBeforeRetry = pierreUpdatedItems.length;
			const pierreSetItemsCountBeforeRetry = pierreSetItemsCalls.length;
			expect(retryPublicationItem).not.toBe(secondPublicationItem);
			renderFulfillmentCoordinator.acceptPublication(retryPublication);
			renderFulfillmentCoordinator.markPublicationQueued(retryPublication);
			expect(dispositionKinds(dispositions)).toEqual(secondPaintedKinds);
			await act(async (): Promise<void> => {
				await rendered.rerender(
					annotationHarness.wrap(
						<BridgeCodeViewPanel
							{...secondPanelProps}
							selectedCodeViewItem={retryPublicationItem}
							visibleCodeViewItems={[retryPublicationItem]}
						/>,
					),
				);
				await Promise.resolve();
			});
			await settleBridgeCodeViewState(
				(): boolean => dispositionKinds(dispositions).at(-1) === 'applied',
				'Expected equal-fingerprint Review retry to reconcile from connected painted residency.',
			);
			expect(firstCodeView.getItem(secondFinalItem.id)).toBe(secondFinalItem);
			expect(
				firstCodeView
					.getRenderedItems()
					.find((renderedItem): boolean => renderedItem.id === secondFinalItem.id)?.item,
			).toBe(secondFinalItem);
			expect(pierreUpdatedItems).toHaveLength(pierreUpdateItemCountBeforeRetry);
			expect(pierreSetItemsCalls).toHaveLength(pierreSetItemsCountBeforeRetry);
			expect(pendingAnimationFrames).toHaveLength(1);
			const retryPendingPaintFrame = pendingAnimationFrames.shift();
			if (retryPendingPaintFrame === undefined) {
				throw new Error('Expected reused Review residency to schedule paint validation.');
			}
			retryPendingPaintFrame.callback(nowMilliseconds);
			expect(dispositionKinds(dispositions)).toEqual([
				...secondPaintedKinds,
				'queued',
				'applied',
				'painted',
			]);

			// A full manifest replacement must render a newer record for an already mounted row.
			const manifestPublication = makeReviewPublication({
				contentsMarker: 'second-attempt',
				publicationSequence: 3,
				version: 94,
			});
			const manifestSourceItem = requireExactReviewPierreDiffItem(
				manifestPublication.job.payload.item,
			);
			const manifestPreparedItem = prepareBridgeMainPierreItemForPresentation({
				currentItem: secondFinalItem,
				presentationItem: manifestSourceItem,
				reuseCurrentItemWhenFingerprintMatches: false,
			});
			expect(manifestPreparedItem.item.version).toBe((secondFinalItem.version ?? 0) + 1);
			renderFulfillmentCoordinator.acceptPublication(manifestPublication);
			renderFulfillmentCoordinator.bindPublicationItem({
				finalItem: manifestPreparedItem.item,
				publicationItem: manifestSourceItem,
				residency: manifestPreparedItem.residency,
			});
			renderFulfillmentCoordinator.markPublicationQueued(manifestPublication);
			const setItemsCountBeforeManifest = pierreSetItemsCalls.length;
			await act(async (): Promise<void> => {
				firstCodeView.setItems([manifestPreparedItem.item]);
			});
			expect(pierreSetItemsCalls.length).toBe(setItemsCountBeforeManifest + 1);
			await act(async (): Promise<void> => {
				await capturedPostRenderLog.waitForItem(manifestPreparedItem.item);
			});
			const manifestPostRender = requirePostRenderForItem(
				capturedPostRenders,
				manifestPreparedItem.item,
			);
			await invokeCapturedPostRenderWithinAct({
				invocation: manifestPostRender,
				phase: 'update',
			});
			expect(dispositionKinds(dispositions).slice(-2)).toEqual(['queued', 'applied']);
			const manifestPaintFrame = pendingAnimationFrames.shift();
			if (manifestPaintFrame === undefined) {
				throw new Error('Expected a visible manifest replacement to schedule paint validation.');
			}
			manifestPaintFrame.callback(nowMilliseconds);
			expect(dispositionKinds(dispositions).slice(-3)).toEqual(['queued', 'applied', 'painted']);
		} finally {
			CodeView.prototype.setup = originalSetup;
			CodeView.prototype.setOptions = originalSetOptions;
			CodeView.prototype.updateItem = originalUpdateItem;
			CodeView.prototype.setItems = originalSetItems;
			renderFulfillmentCoordinator.dispose();
		}
	});
});

function makeReviewPublication(props: {
	readonly contentRole?: 'base' | 'head';
	readonly contentsMarker: string;
	readonly publicationSequence: number;
	readonly version: number;
}): BridgeWorkerReviewPierreRenderJobEvent {
	const itemId = 'item-source';
	const baseCacheKey = `base-${props.contentsMarker}`;
	const headCacheKey = `head-${props.contentsMarker}`;
	const contentCacheKey = `${baseCacheKey}|${headCacheKey}`;
	const contentRoles =
		props.contentRole === undefined ? (['base', 'head'] as const) : [props.contentRole];
	const baseSource = `\tlet primaryValue = "base-${props.contentsMarker}"\n\tlet secondaryValue = "base-secondary-${props.contentsMarker}"\n`;
	const headSource = `\tlet primaryValue = "head-${props.contentsMarker}"\n\tlet secondaryValue = "head-secondary-${props.contentsMarker}"\n`;
	const baseContents = props.contentRole === 'head' ? '' : baseSource;
	const headContents = props.contentRole === 'base' ? '' : headSource;
	const lineCount = contentRoles.length * 2;
	const job = buildBridgeWorkerPierreRenderJob({
		bridgeDemandRank: { lane: 'selected', priority: props.publicationSequence },
		budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
		contentCacheKey,
		contentHash: `sha256:${props.contentsMarker}`,
		itemId,
		language: 'swift',
		payload: {
			item: {
				bridgeMetadata: {
					cacheKey: contentCacheKey,
					contentRoles,
					contentState: 'hydrated',
					displayPath: 'Sources/App/View.swift',
					itemId,
					lineCount,
				},
				fileDiff: parseDiffFromFile(
					{
						cacheKey: baseCacheKey,
						contents: baseContents,
						name: 'Sources/App/View.swift',
					},
					{
						cacheKey: headCacheKey,
						contents: headContents,
						name: 'Sources/App/View.swift',
					},
				),
				id: itemId,
				type: 'diff',
				version: props.version,
			},
			kind: 'codeViewDiffItem',
		},
		renderKind: 'reviewDiff',
		sourceCorrelations: contentRoles.map((role) => ({
			descriptorId: `descriptor-${props.contentsMarker}-${role}`,
			itemId,
			observedSha256: (role === 'base' ? 'b' : 'c').repeat(64),
			position: 'whole',
			requestId: `request-${props.contentsMarker}-${role}`,
			role,
			sourceGeneration: props.publicationSequence,
			sourceIdentity: `source-${props.contentsMarker}-${role}`,
		})),
		window: { endLine: lineCount, startLine: 1, totalLineCount: lineCount },
	});
	return {
		direction: 'serverWorkerToMain',
		job,
		kind: 'reviewPierreRenderJob',
		reviewPublicationIdentity: bridgeWorkerTestReviewPublicationIdentity,
		publicationSequence: props.publicationSequence,
		renderReceiptIdentity: makeBridgeWorkerRenderReceiptIdentity({
			itemId,
			publicationSequence: props.publicationSequence,
			surface: 'review',
			workerDerivationEpoch: 1,
		}),
		surface: 'review',
		transferDescriptors: [
			{
				byteLength: job.payloadByteLength,
				fieldPath: ['job', 'payload'],
				messageKind: 'reviewPierreRenderJob',
				mode: 'clone',
			},
		],
		wireVersion: 1,
		workerDerivationEpoch: 1,
	};
}

function cloneReviewPublicationForRetry(
	publication: BridgeWorkerReviewPierreRenderJobEvent,
): BridgeWorkerReviewPierreRenderJobEvent {
	const publicationItem = requireExactReviewPierreDiffItem(publication.job.payload.item);
	const clonedPublicationItem = {
		...publicationItem,
		bridgeMetadata: {
			...publicationItem.bridgeMetadata,
			contentRoles: [...publicationItem.bridgeMetadata.contentRoles],
		},
		fileDiff: { ...publicationItem.fileDiff },
	};
	return bridgeWorkerReviewPierreRenderJobEventSchema.parse({
		...publication,
		job: {
			...publication.job,
			payload: {
				...publication.job.payload,
				item: clonedPublicationItem,
			},
		},
		renderReceiptIdentity: {
			...publication.renderReceiptIdentity,
			attemptId: 'attempt-review-equal-fingerprint-retry',
		},
	});
}

function dispositionKinds(
	dispositions: readonly BridgeWorkerRenderDispositionReceipt[],
): readonly BridgeWorkerRenderDispositionReceipt['disposition'][] {
	return dispositions.map((receipt) => receipt.disposition);
}

async function invokeCapturedPostRenderWithinAct(props: {
	readonly contextItem?: CodeViewItem;
	readonly invocation: CapturedBridgeCodeViewPostRender;
	readonly mutateRenderedContent?: () => void;
	readonly phase: PostRenderPhase;
}): Promise<void> {
	await act(async (): Promise<void> => {
		props.mutateRenderedContent?.();
		props.invocation.invoke({
			phase: props.phase,
			...(props.contextItem === undefined ? {} : { contextItem: props.contextItem }),
		});
		await Promise.resolve();
	});
}

function requirePostRenderForItem(
	invocations: readonly CapturedBridgeCodeViewPostRender[],
	item: CodeViewItem,
): CapturedBridgeCodeViewPostRender {
	const invocation = invocations.findLast((candidate): boolean => candidate.contextItem === item);
	if (invocation === undefined) {
		throw new Error(`Expected Pierre onPostRender callback for exact item ${item.id}.`);
	}
	return invocation;
}

function captureBridgeCodeViewPostRender(props: {
	readonly callback: NonNullable<CodeViewOptions<undefined>['onPostRender']>;
	readonly callbackArguments: readonly unknown[];
	readonly log: ExactItemReceiptLog<CodeViewItem, CapturedBridgeCodeViewPostRender>;
}): void {
	const callbackArguments = requireBridgeCodeViewPostRenderArguments(props.callbackArguments);
	const capturedContextItem = callbackArguments.context.item;
	const capturedContext = { ...callbackArguments.context, item: capturedContextItem };
	props.log.record({
		contextItem: capturedContextItem,
		invoke: (invokeProps): void => {
			Reflect.apply(props.callback, undefined, [
				callbackArguments.element,
				callbackArguments.instance,
				invokeProps.phase,
				{
					...capturedContext,
					item: invokeProps.contextItem ?? capturedContextItem,
				},
			]);
		},
	});
}

function requireBridgeCodeViewPostRenderArguments(callbackArguments: readonly unknown[]): {
	readonly context: Readonly<Record<string, unknown>> & { readonly item: CodeViewItem };
	readonly element: HTMLElement;
	readonly instance: unknown;
} {
	const [element, instance, phase, context] = callbackArguments;
	if (
		!(element instanceof HTMLElement) ||
		!isPostRenderPhase(phase) ||
		!isBridgeCodeViewPostRenderContext(context)
	) {
		throw new Error('Expected Pierre public onPostRender element, instance, phase, and context.');
	}
	return { context, element, instance };
}

function isBridgeCodeViewPostRenderContext(
	value: unknown,
): value is Readonly<Record<string, unknown>> & { readonly item: CodeViewItem } {
	return isUnknownRecord(value) && isCodeViewItem(value['item']);
}

function isCodeViewItem(value: unknown): value is CodeViewItem {
	return (
		isUnknownRecord(value) &&
		typeof value['id'] === 'string' &&
		(value['type'] === 'diff' || value['type'] === 'file')
	);
}

function isPostRenderPhase(value: unknown): value is PostRenderPhase {
	return value === 'mount' || value === 'unmount' || value === 'update';
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null;
}

function requireExactReviewPierreDiffItem(
	item: BridgeMainRenderPublicationItem,
): ExactReviewPierreDiffItem {
	if (!isExactReviewPierreDiffItem(item)) {
		throw new Error('Expected exact Review worker publication to be a public Pierre diff item.');
	}
	return item;
}

function requireCurrentReviewPierreDiffItem(
	codeView: CodeView,
	itemId: string,
): ExactReviewPierreDiffItem {
	const item = codeView.getItem(itemId);
	if (item === undefined || !isExactReviewPierreDiffItem(item)) {
		throw new Error(`Expected current Review item ${itemId} to carry Bridge publication metadata.`);
	}
	return item;
}

function isExactReviewPierreDiffItem(
	item: BridgeMainRenderPublicationItem | CodeViewItem,
): item is ExactReviewPierreDiffItem {
	if (item.type !== 'diff' || !('bridgeMetadata' in item)) return false;
	const language = item.fileDiff.lang;
	return language === undefined
		? !Object.hasOwn(item.fileDiff, 'lang')
		: bridgePierreOptionalHighlightLanguage(language) === language;
}

async function settleBridgeCodeViewState(
	isSettled: () => boolean,
	failureMessage: string,
): Promise<void> {
	for (let frameIndex = 0; frameIndex < 8; frameIndex += 1) {
		if (isSettled()) return;
		// oxlint-disable-next-line no-await-in-loop -- Each iteration is a bounded observable render boundary.
		await act(async (): Promise<void> => {
			await new Promise<void>((resolve): void => {
				setTimeout(resolve, 0);
			});
			await new Promise<void>((resolve): void => {
				requestAnimationFrame((): void => resolve());
			});
			await Promise.resolve();
		});
	}
	if (!isSettled()) throw new Error(failureMessage);
}

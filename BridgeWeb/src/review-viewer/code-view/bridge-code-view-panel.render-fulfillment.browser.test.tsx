import { CodeView, type CodeViewItem, type CodeViewOptions } from '@pierre/diffs';
import { act } from 'react';
import { describe, expect, test } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../../app/bridge-app.css';
import { prepareBridgeMainPierreItemForPresentation } from '../../core/comm-worker/bridge-main-pierre-item-adapter.js';
import { createBridgeMainRenderFulfillmentCoordinator } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import type { BridgeWorkerRenderDispositionReceipt } from '../../core/comm-worker/bridge-worker-render-fulfillment.js';
import { BridgeProductTestFactRecorder } from '../../core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';
import { makeBridgeReviewPackage } from '../../foundation/review-package/bridge-review-package-test-support.js';
import type { BridgeReviewPackage } from '../../foundation/review-package/bridge-review-package.js';
import { createWorktreeAnnotationBrowserProviderHarness } from '../../worktree-annotations/worktree-annotation-browser-test-support.js';
import { buildBridgeReviewProjection } from '../navigation/review-projection.js';
import { waitForBridgeViewerCodeHeaderCollapseButton } from '../test-support/bridge-viewer-browser-dom.js';
import { BridgeCodeViewPanel } from './bridge-code-view-panel.js';
import {
	assertBridgeCodeViewHeaderGeometry,
	makeReviewPublication,
	requireExactReviewPierreDiffItem,
	requireCurrentReviewPierreDiffItem,
	isExactReviewPierreDiffItem,
	captureBridgeCodeViewPostRender,
	cloneReviewPublicationForRetry,
	dispositionKinds,
	invokeCapturedPostRenderWithinAct,
	requirePostRenderForItem,
	assertReviewRenderedMembership,
	waitForReviewAppliedReceipt,
	type CapturedBridgeCodeViewPostRender,
	createExactItemReceiptLog,
	observeReviewHeaderMetadata,
	paintedSourceCorrelations,
	requireCurrentRenderedReviewRows,
	requireMountedCodeView,
} from './bridge-code-view-panel.render-fulfillment.browser.test-support.js';

interface PendingAnimationFrame {
	readonly callback: FrameRequestCallback;
	readonly frameHandle: number;
}
describe('BridgeCodeViewPanel render fulfillment', () => {
	test('closes held exact-item Review receipts when their observation owner retires', async (): Promise<void> => {
		const item = {};
		const log = createExactItemReceiptLog<object, { readonly contextItem: object }>();
		const outcome = log.waitForItem(item).then(
			(): string => 'unexpected callback',
			(error: unknown): string => String(error),
		);
		log.close(new Error('Exact Review post-render owner retired.'));
		expect(await outcome).toContain('Exact Review post-render owner retired');
	});
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
			expect(mountedCodeView.current?.getItem(publicationItem.id)).toBe(retainedReadableItem);

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
			const changedItem = requireCurrentReviewPierreDiffItem(
				requireMountedCodeView(mountedCodeView.current),
				publicationItem.id,
			);
			expect(changedItem.bridgeMetadata.contentState).toBe('loading');
		} finally {
			CodeView.prototype.setup = originalSetup;
			renderFulfillmentCoordinator.dispose();
		}
	});

	test('adapts Review items with main versions, preserves collapse, and reuses exact painted residency', async (context) => {
		const annotationHarness = createWorktreeAnnotationBrowserProviderHarness('review');
		// Hold Pierre's post-render callback while retaining a real CodeView and public readbacks.
		const mountedCodeView: { current: CodeView | null } = { current: null };
		const capturedPostRenderLog = createExactItemReceiptLog<
			CodeViewItem,
			CapturedBridgeCodeViewPostRender
		>();
		const capturedPostRenders = capturedPostRenderLog.receipts;
		const currentItemFacts = new BridgeProductTestFactRecorder<CodeViewItem>();
		const dispositionFacts =
			new BridgeProductTestFactRecorder<BridgeWorkerRenderDispositionReceipt>();
		let observationIsOpen = true;
		let lastWait = 'Review setup';
		const closeObservations = (): void => {
			observationIsOpen = false;
			const error = new Error(`Review fulfillment ended while awaiting ${lastWait}.`);
			capturedPostRenderLog.close(error);
			currentItemFacts.close(error);
			dispositionFacts.close(error);
		};
		context.signal.addEventListener('abort', closeObservations, { once: true });
		context.onTestFinished((): void => {
			if (context.signal.aborted || context.task.result?.state === 'fail')
				console.info(`A12 failed/aborted at ${lastWait}.`);
		});
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
			const result = originalUpdateItem.call(this, item);
			const currentItem = this.getItem(item.id);
			if (observationIsOpen && currentItem !== undefined) currentItemFacts.record(currentItem);
			return result;
		};
		CodeView.prototype.setItems = function captureSetItems(items: readonly CodeViewItem[]): void {
			pierreSetItemsCalls.push(items);
			originalSetItems.call(this, items);
			for (const item of items) {
				const currentItem = this.getItem(item.id);
				if (observationIsOpen && currentItem !== undefined) currentItemFacts.record(currentItem);
			}
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
				if (observationIsOpen) dispositionFacts.record(receipt);
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
			lastWait = `first current Review item ${firstPublicationItem.id}`;
			await act(async (): Promise<void> => {
				await currentItemFacts.waitFor(
					(item): boolean =>
						isExactReviewPierreDiffItem(item) &&
						item.id === firstPublicationItem.id &&
						item !== firstPublicationItem &&
						item.bridgeMetadata.cacheKey === firstPublicationItem.bridgeMetadata.cacheKey,
				);
			});
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
			lastWait = `first exact Review postRender ${firstFinalItem.id}`;
			await act(async (): Promise<void> => {
				await capturedPostRenderLog.waitForItem(firstFinalItem);
			});
			assertReviewRenderedMembership(firstCodeView, firstFinalItem);
			lastWait = 'Review header metadata DOM mount';
			const metadata = await act(() => observeReviewHeaderMetadata(context.signal));
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
			lastWait = `collapsed Review item ${firstFinalItem.id}`;
			await act(async (): Promise<void> => {
				await currentItemFacts.waitFor(
					(item): boolean =>
						isExactReviewPierreDiffItem(item) &&
						item.id === firstFinalItem.id &&
						item !== firstFinalItem &&
						item.collapsed === true,
				);
			});
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
			lastWait = `second current Review item ${secondPublicationItem.id}`;
			await act(async (): Promise<void> => {
				await currentItemFacts.waitFor(
					(item): boolean =>
						isExactReviewPierreDiffItem(item) &&
						item.id === secondPublicationItem.id &&
						item !== secondPublicationItem &&
						item.collapsed === true &&
						item.bridgeMetadata.cacheKey === secondPublicationItem.bridgeMetadata.cacheKey,
				);
			});
			const secondFinalItem = requireCurrentReviewPierreDiffItem(
				firstCodeView,
				secondPublicationItem.id,
			);
			expect(secondFinalItem).not.toBe(secondPublicationItem);
			expect(secondFinalItem.collapsed).toBe(true);
			expect(secondFinalItem.version).toBe((collapsedItem.version ?? 0) + 1);
			lastWait = `second exact Review postRender ${secondFinalItem.id}`;
			await act(async (): Promise<void> => {
				await capturedPostRenderLog.waitForItem(secondFinalItem);
			});
			assertReviewRenderedMembership(firstCodeView, secondFinalItem);
			const secondPostRender = requirePostRenderForItem(capturedPostRenders, secondFinalItem);
			expect([
				['queued', 'applied', 'painted', 'queued'],
				['queued', 'applied', 'painted', 'queued', 'applied'],
			]).toContainEqual(dispositionKinds(dispositions));

			await invokeCapturedPostRenderWithinAct({ invocation: firstPostRender, phase: 'update' });
			await invokeCapturedPostRenderWithinAct({ invocation: secondPostRender, phase: 'update' });
			const secondAppliedKinds = ['queued', 'applied', 'painted', 'queued', 'applied'];
			lastWait = 'second Review applied receipt';
			await act(() => waitForReviewAppliedReceipt(dispositionFacts, secondPublication));
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
			lastWait = 'equal-fingerprint Review retry applied receipt';
			await act(() => waitForReviewAppliedReceipt(dispositionFacts, retryPublication));
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
			context.signal.removeEventListener('abort', closeObservations);
			renderFulfillmentCoordinator.dispose();
			closeObservations();
		}
	});
});

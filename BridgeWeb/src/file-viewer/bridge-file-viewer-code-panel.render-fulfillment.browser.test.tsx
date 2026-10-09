import {
	CodeView,
	type CodeViewFileItem,
	type CodeViewItem,
	type CodeViewOptions,
	type CodeViewScrollTarget,
	type PostRenderPhase,
} from '@pierre/diffs';
import { act } from 'react';
import { describe, expect, test } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import { prepareBridgeMainPierreItemForPresentation } from '../core/comm-worker/bridge-main-pierre-item-adapter.js';
import {
	createBridgeMainRenderFulfillmentCoordinator,
	type BridgeMainRenderPublicationItem,
} from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import type { BridgeWorkerRenderDispositionReceipt } from '../core/comm-worker/bridge-worker-render-fulfillment.js';
import { bridgePierreOptionalHighlightLanguage } from '../review-viewer/workers/pierre/bridge-pierre-language-normalization.js';
import { createWorktreeAnnotationBrowserProviderHarness } from '../worktree-annotations/worktree-annotation-browser-test-support.js';
import {
	BridgeFileViewerCodePanel,
	type BridgeFileViewerCodePanelState,
} from './bridge-file-viewer-code-panel.js';
import {
	bridgeFileViewerCodeViewOptions,
	deriveBridgeFilesCodeViewOptions,
} from './bridge-file-viewer-code-view-options.js';
import { makeFilePublication } from './bridge-file-viewer-render-fulfillment.test-support.js';

type ExactFilePierreItem = Extract<BridgeMainRenderPublicationItem, { readonly type: 'file' }> &
	CodeViewFileItem;

interface CapturedBridgeFilePostRender {
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

describe('BridgeFileViewerCodePanel render fulfillment', () => {
	test('applies Files view settings on the same mounted Pierre owner without changing selection', async () => {
		const annotationHarness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		// Arrange: capture the public CodeView owner and option updates from the production React bridge.
		const mountedInstances: CodeView[] = [];
		const appliedOptions: CodeViewOptions<undefined>[] = [];
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetup = CodeView.prototype.setup;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetOptions = CodeView.prototype.setOptions;
		CodeView.prototype.setup = function captureMountedCodeView(root: HTMLElement): void {
			mountedInstances.push(this);
			originalSetup.call(this, root);
		};
		CodeView.prototype.setOptions = function captureAppliedOptions(
			options: CodeViewOptions<undefined> | undefined,
		): void {
			if (options !== undefined) appliedOptions.push(options);
			originalSetOptions.call(this, options);
		};

		const selectedCodeViewItem = requireExactFilePierreItem(
			makeFilePublication({
				contentsMarker: 'view-settings',
				publicationSequence: 1,
				version: 1,
			}).job.payload.item,
		);
		const panelProps = {
			codeViewWorkerPoolEnabled: false,
			openFileState: {
				displayItem: null,
				fileId: 'file-1',
				path: 'Sources/App/View.swift',
				status: 'ready',
			} satisfies BridgeFileViewerCodePanelState,
			renderFulfillmentCoordinator: {
				observePostRender: (): void => {},
				reconcilePublication: (): void => {},
			},
			selectedCodeViewItem,
			totalHeightPixels: null,
		};

		try {
			const initialOptions = deriveBridgeFilesCodeViewOptions({
				compatibilityOptions: bridgeFileViewerCodeViewOptions,
				viewSettings: { lineNumbers: true, wordWrap: true },
			});
			const rendered = await render(
				annotationHarness.wrap(
					<BridgeFileViewerCodePanel {...panelProps} codeViewOptions={initialOptions} />,
				),
			);
			const initialOwner = mountedInstances.at(-1);
			await settleBridgeCodeViewState(
				(): boolean => initialOwner?.getItem(selectedCodeViewItem.id) === selectedCodeViewItem,
				'Expected the initial Files selection to be owned by the mounted Pierre CodeView.',
			);
			// Act
			const changedOptions = deriveBridgeFilesCodeViewOptions({
				compatibilityOptions: bridgeFileViewerCodeViewOptions,
				viewSettings: { lineNumbers: false, wordWrap: false },
			});
			await act(async (): Promise<void> => {
				await rendered.rerender(
					annotationHarness.wrap(
						<BridgeFileViewerCodePanel {...panelProps} codeViewOptions={changedOptions} />,
					),
				);
				await Promise.resolve();
			});

			// Assert
			expect(mountedInstances).toHaveLength(1);
			expect(mountedInstances[0]).toBe(initialOwner);
			expect(initialOwner?.getItem(selectedCodeViewItem.id)).toBe(selectedCodeViewItem);
			expect(appliedOptions.at(-1)).toMatchObject({
				disableLineNumbers: true,
				overflow: 'scroll',
			});
			expect(
				document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]'),
			).toHaveAttribute('data-bridge-code-view-overflow', 'scroll');
			await act(async (): Promise<void> => {
				annotationHarness.surface.publishProjectionState({
					expectedThreadCount: 0,
					recoveryStatus: 'recovered_degraded',
					revision: 1,
					sessions: [],
				});
				await Promise.resolve();
			});
			expect(
				document.querySelector('[data-testid="worktree-annotation-session-surface"]'),
			).toBeNull();
		} finally {
			CodeView.prototype.setup = originalSetup;
			CodeView.prototype.setOptions = originalSetOptions;
		}
	});

	test('settles File fulfillment only from exact main-adapted public Pierre items', async () => {
		const annotationHarness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		// Arrange: capture Pierre's public callback while retaining a real mounted CodeView and its
		// public current-item and rendered-membership readback APIs.
		const mountedCodeView: { current: CodeView | null } = { current: null };
		const postRenderCapture = new BridgeFilePostRenderCapture();
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetup = CodeView.prototype.setup;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetOptions = CodeView.prototype.setOptions;
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
					postRenderCapture.capture({
						callback: onPostRender,
						callbackArguments,
					});
				},
			} satisfies CodeViewOptions<undefined>;
			originalSetOptions.call(this, capturedOptions);
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

		try {
			const firstPublication = makeFilePublication({
				contentsMarker: 'first-attempt',
				publicationSequence: 1,
				version: 37,
			});
			const firstPublicationItem = requireExactFilePierreItem(firstPublication.job.payload.item);
			expect(firstPublication.job.itemId).toBe('file-1');
			expect(firstPublicationItem.id).toBe('file:file-1');
			expect(firstPublicationItem.version).toBe(37);
			renderFulfillmentCoordinator.acceptPublication(firstPublication);
			const firstPreparedItem = prepareBridgeMainPierreItemForPresentation({
				currentItem: undefined,
				presentationItem: firstPublicationItem,
			});
			const firstFinalItem = requireExactFilePierreItem(firstPreparedItem.item);
			renderFulfillmentCoordinator.bindPublicationItem({
				finalItem: firstFinalItem,
				publicationItem: firstPublicationItem,
				residency: firstPreparedItem.residency,
			});
			renderFulfillmentCoordinator.markPublicationQueued(firstPublication);
			expect(firstPreparedItem.residency).toBe('replaced');
			expect(firstFinalItem).not.toBe(firstPublicationItem);
			expect(firstFinalItem.version).toBe(1);
			expect(dispositionKinds(dispositions)).toEqual(['queued']);

			const panelProps = {
				codeViewWorkerPoolEnabled: false,
				openFileState: {
					displayItem: null,
					fileId: firstPublication.job.itemId,
					path: firstFinalItem.bridgeMetadata.displayPath,
					status: 'ready',
				} satisfies BridgeFileViewerCodePanelState,
				renderFulfillmentCoordinator,
				selectedCodeViewItem: firstFinalItem,
				totalHeightPixels: null,
			};
			const rendered = await render(
				annotationHarness.wrap(<BridgeFileViewerCodePanel {...panelProps} />),
			);

			await settleBridgeCodeViewState(
				(): boolean => mountedCodeView.current?.getItem(firstFinalItem.id) === firstFinalItem,
				'Expected Pierre current item to become the exact first main-adapted File object.',
			);
			const firstCodeView = requireMountedCodeView(mountedCodeView.current);
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
				'Expected Pierre rendered membership to carry the exact main-adapted File object.',
			);
			const firstPostRender = await waitForBridgeFilePostRender(postRenderCapture, firstFinalItem);

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

			await act(async (): Promise<void> => {
				firstCodeView.updateItem(wrongContextItem);
				await Promise.resolve();
			});
			expect(firstCodeView.getItem(firstPublicationItem.id)).toBe(wrongContextItem);
			// The arbitrary wrong-context callback was inert. Once Pierre makes that
			// content-equivalent object current, the exact bound-final callback may re-anchor it.
			await invokeCapturedPostRenderWithinAct({ invocation: firstPostRender, phase: 'update' });
			const appliedPrefix = ['queued', 'applied'];
			expect(dispositionKinds(dispositions)).toEqual(appliedPrefix);
			await act(async (): Promise<void> => {
				firstCodeView.setItems([firstFinalItem]);
				await Promise.resolve();
			});
			await settleBridgeCodeViewState(
				(): boolean => firstCodeView.getItem(firstFinalItem.id) === firstFinalItem,
				'Expected Pierre current File item identity to restore after wrong-current readback.',
			);

			const originalGetRenderedItems = firstCodeView.getRenderedItems.bind(firstCodeView);
			firstCodeView.getRenderedItems = (): [] => [];
			await invokeCapturedPostRenderWithinAct({ invocation: firstPostRender, phase: 'update' });
			expect(dispositionKinds(dispositions)).toEqual(appliedPrefix);
			const matchingRenderedItem = originalGetRenderedItems().find(
				(renderedItem): boolean => renderedItem.item === firstFinalItem,
			);
			if (matchingRenderedItem === undefined) {
				throw new Error('Expected real Pierre rendered membership for the File publication.');
			}
			firstCodeView.getRenderedItems = () => [
				{ ...matchingRenderedItem, element: document.createElement('div') },
			];
			await invokeCapturedPostRenderWithinAct({ invocation: firstPostRender, phase: 'update' });
			expect(dispositionKinds(dispositions)).toEqual(['queued', 'applied']);
			firstCodeView.getRenderedItems = originalGetRenderedItems;
			// Exact connected readable reconciliation advances applied; callbacks cannot weaken it.
			const renderedSourceLines = (): readonly Element[] =>
				queryOpenShadowRoots(matchingRenderedItem.element, '[data-line][data-line-index]');
			const [exactSourceText] = renderedSourceLines().map((line): string => line.textContent ?? '');
			if (exactSourceText === undefined) {
				throw new Error('Expected real Pierre File source rows in its open shadow roots.');
			}
			const writeLiveSourceText = (sourceText: string): void => {
				for (const sourceLine of renderedSourceLines()) sourceLine.textContent = sourceText;
			};
			await invokeCapturedPostRenderWithinAct({
				beforeInvoke: (): void => writeLiveSourceText(''),
				invocation: firstPostRender,
				phase: 'update',
			});
			expect(dispositionKinds(dispositions)).toEqual(['queued', 'applied']);
			expect(pendingAnimationFrames).toHaveLength(1);
			expect(dispositionKinds(dispositions)).not.toContain('painted');
			const pendingPaintFrame = pendingAnimationFrames.shift();
			if (pendingPaintFrame === undefined) {
				throw new Error(
					'Expected matching File post-render readback to schedule paint validation.',
				);
			}
			await act(async (): Promise<void> => {
				writeLiveSourceText('');
				pendingPaintFrame.callback(nowMilliseconds);
				await Promise.resolve();
			});
			expect(dispositionKinds(dispositions)).toEqual(['queued', 'applied', 'painted']);
			expect(paintedSourceCorrelations(matchingRenderedItem.element)).toBeNull();
			await invokeCapturedPostRenderWithinAct({
				beforeInvoke: (): void => writeLiveSourceText('unrelated skeletal content'),
				invocation: firstPostRender,
				phase: 'update',
			});
			expect(paintedSourceCorrelations(matchingRenderedItem.element)).toBeNull();
			await invokeCapturedPostRenderWithinAct({
				beforeInvoke: (): void => writeLiveSourceText(exactSourceText),
				invocation: firstPostRender,
				phase: 'update',
			});
			expect(paintedSourceCorrelations(matchingRenderedItem.element)).not.toBeNull();
			expect(dispositionKinds(dispositions)).toEqual(['queued', 'applied', 'painted']);

			const secondPublication = makeFilePublication({
				contentsMarker: 'second-attempt',
				publicationSequence: 2,
				version: 93,
			});
			const secondPublicationItem = requireExactFilePierreItem(secondPublication.job.payload.item);
			expect(secondPublicationItem).not.toBe(firstPublicationItem);
			expect(secondPublicationItem.version).toBe(93);
			renderFulfillmentCoordinator.acceptPublication(secondPublication);
			const secondPreparedItem = prepareBridgeMainPierreItemForPresentation({
				currentItem: firstFinalItem,
				presentationItem: secondPublicationItem,
			});
			const secondFinalItem = requireExactFilePierreItem(secondPreparedItem.item);
			renderFulfillmentCoordinator.bindPublicationItem({
				finalItem: secondFinalItem,
				publicationItem: secondPublicationItem,
				residency: secondPreparedItem.residency,
			});
			renderFulfillmentCoordinator.markPublicationQueued(secondPublication);
			expect(secondPreparedItem.residency).toBe('replaced');
			expect(secondFinalItem).not.toBe(secondPublicationItem);
			expect(secondFinalItem.version).toBe(2);
			expect(dispositionKinds(dispositions)).toEqual(['queued', 'applied', 'painted', 'queued']);
			await invokeCapturedPostRenderWithinAct({ invocation: firstPostRender, phase: 'update' });
			expect(dispositionKinds(dispositions)).toEqual(['queued', 'applied', 'painted', 'queued']);

			const secondPanelProps = {
				...panelProps,
				selectedCodeViewItem: secondFinalItem,
			};
			await act(async (): Promise<void> => {
				await rendered.rerender(
					annotationHarness.wrap(<BridgeFileViewerCodePanel {...secondPanelProps} />),
				);
				await Promise.resolve();
			});
			await settleBridgeCodeViewState(
				(): boolean => firstCodeView.getItem(secondFinalItem.id) === secondFinalItem,
				'Expected Pierre current File item to become the exact second main-adapted object.',
			);
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
				'Expected Pierre rendered membership to carry the exact second main-adapted File object.',
			);
			const secondPostRender = await waitForBridgeFilePostRender(
				postRenderCapture,
				secondFinalItem,
			);
			await invokeCapturedPostRenderWithinAct({ invocation: firstPostRender, phase: 'update' });
			expect([
				['queued', 'applied', 'painted', 'queued'],
				['queued', 'applied', 'painted', 'queued', 'applied'],
			]).toContainEqual(dispositionKinds(dispositions));
			await invokeCapturedPostRenderWithinAct({ invocation: secondPostRender, phase: 'update' });
			const secondAppliedKinds = ['queued', 'applied', 'painted', 'queued', 'applied'];
			await settleBridgeCodeViewState(
				(): boolean => dispositionKinds(dispositions).length === secondAppliedKinds.length,
				'Expected the second exact File attempt to reach applied.',
			);
			expect(dispositionKinds(dispositions)).toEqual(secondAppliedKinds);
			expect(pendingAnimationFrames).toHaveLength(1);
			const secondPendingPaintFrame = pendingAnimationFrames.shift();
			if (secondPendingPaintFrame === undefined) {
				throw new Error('Expected the second exact File attempt to schedule paint validation.');
			}
			secondPendingPaintFrame.callback(nowMilliseconds);
			const secondPaintedKinds = [...secondAppliedKinds, 'painted'];
			expect(dispositionKinds(dispositions)).toEqual(secondPaintedKinds);
		} finally {
			CodeView.prototype.setup = originalSetup;
			CodeView.prototype.setOptions = originalSetOptions;
			renderFulfillmentCoordinator.dispose();
		}
	});

	test('lets stable same-file items preserve scroll without app-owned retargeting', async () => {
		const annotationHarness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const mountedCodeView: { current: CodeView | null } = { current: null };
		const mountedCodeViewRoot: { current: HTMLElement | null } = { current: null };
		const setItemReceipts: CodeViewItem[][] = [];
		const scrollToReceipts: CodeViewScrollTarget[] = [];
		let setupCount = 0;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetup = CodeView.prototype.setup;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetItems = CodeView.prototype.setItems;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalScrollTo = CodeView.prototype.scrollTo;
		CodeView.prototype.setup = function captureMountedCodeView(root: HTMLElement): void {
			setupCount += 1;
			mountedCodeView.current = this;
			mountedCodeViewRoot.current = root;
			originalSetup.call(this, root);
		};
		CodeView.prototype.setItems = function captureCodeViewItems(
			items: readonly CodeViewItem[],
		): void {
			setItemReceipts.push([...items]);
			originalSetItems.call(this, items);
		};
		CodeView.prototype.scrollTo = function captureCodeViewScrollToReceipt(
			target: CodeViewScrollTarget,
		): void {
			scrollToReceipts.push(target);
		};

		const renderFulfillmentCoordinator = {
			observePostRender: (): void => {},
			reconcilePublication: (): void => {},
		};
		const initialItem = requireExactFilePierreItem(
			makeFilePublication({
				contentsMarker: 'scroll-initial',
				publicationSequence: 1,
				version: 1,
			}).job.payload.item,
		);
		const refreshedItem = requireExactFilePierreItem(
			makeFilePublication({
				contentsMarker: 'scroll-refreshed',
				publicationSequence: 2,
				version: 2,
			}).job.payload.item,
		);
		const initialOpenFileState = {
			displayItem: null,
			fileId: 'file-1',
			path: 'Sources/App/View.swift',
			status: 'ready',
		} satisfies BridgeFileViewerCodePanelState;

		try {
			const rendered = await render(
				annotationHarness.wrap(
					<BridgeFileViewerCodePanel
						codeViewWorkerPoolEnabled={false}
						openFileState={initialOpenFileState}
						renderFulfillmentCoordinator={renderFulfillmentCoordinator}
						selectedCodeViewItem={initialItem}
						totalHeightPixels={null}
					/>,
				),
			);
			await act(async (): Promise<void> => {
				await new Promise<void>((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
			});
			setItemReceipts.length = 0;
			scrollToReceipts.length = 0;

			const capturedCodeView = mountedCodeView.current;
			const capturedCodeViewRoot = mountedCodeViewRoot.current;
			if (capturedCodeView === null || capturedCodeViewRoot === null) {
				throw new Error('Expected the mounted CodeView and its connected scroll owner.');
			}
			await act(async (): Promise<void> => {
				capturedCodeViewRoot.scrollTop = 247;
				capturedCodeViewRoot.dispatchEvent(new Event('scroll'));
				await Promise.resolve();
			});

			await rendered.rerender(
				annotationHarness.wrap(
					<BridgeFileViewerCodePanel
						codeViewWorkerPoolEnabled={false}
						openFileState={{ ...initialOpenFileState, status: 'loading' }}
						renderFulfillmentCoordinator={renderFulfillmentCoordinator}
						selectedCodeViewItem={initialItem}
						totalHeightPixels={null}
					/>,
				),
			);
			expect(
				document
					.querySelector('[data-bridge-region="file-content"]')
					?.getAttribute('data-presentation-state'),
			).toBe('updating');
			expect(
				document.querySelector('[data-bridge-region="file-content"] [data-slot="skeleton"]'),
			).toBeNull();
			const retainedView = rendered.getByTestId('bridge-file-viewer-code-view').element();
			expect(getComputedStyle(retainedView).visibility).toBe('visible');
			expect(mountedCodeView.current).toBe(capturedCodeView);
			expect(setItemReceipts.some((items) => items.length === 0)).toBe(false);
			await act(async (): Promise<void> => {
				await page.screenshot({
					element: rendered.getByTestId('bridge-file-viewer-code-canvas').element(),
					path: '../../../tmp/bridge-file-retained-during-loading.png',
				});
			});
			await rendered.rerender(
				annotationHarness.wrap(
					<BridgeFileViewerCodePanel
						codeViewWorkerPoolEnabled={false}
						openFileState={{ ...initialOpenFileState }}
						renderFulfillmentCoordinator={renderFulfillmentCoordinator}
						selectedCodeViewItem={refreshedItem}
						totalHeightPixels={null}
					/>,
				),
			);
			await act(async (): Promise<void> => {
				await new Promise<void>((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
			});

			expect(setItemReceipts.map((items) => items.map((item) => item.id))).toEqual([
				['file:file-1'],
			]);
			expect(setItemReceipts.some((items) => items.length === 0)).toBe(false);
			expect(mountedCodeView.current).toBe(capturedCodeView);
			expect(setupCount).toBe(1);
			expect(scrollToReceipts).toEqual([]);

			await act(async (): Promise<void> => {
				capturedCodeViewRoot.dispatchEvent(new WheelEvent('wheel', { bubbles: true }));
				capturedCodeViewRoot.scrollTop = 0;
				capturedCodeViewRoot.dispatchEvent(new Event('scroll'));
				await Promise.resolve();
			});
			expect(capturedCodeViewRoot.scrollTop).toBe(0);
			expect(scrollToReceipts).toEqual([]);
		} finally {
			CodeView.prototype.setup = originalSetup;
			CodeView.prototype.setItems = originalSetItems;
			CodeView.prototype.scrollTo = originalScrollTo;
		}
	});
});

function dispositionKinds(
	dispositions: readonly BridgeWorkerRenderDispositionReceipt[],
): readonly BridgeWorkerRenderDispositionReceipt['disposition'][] {
	return dispositions.map((receipt) => receipt.disposition);
}

function paintedSourceCorrelations(element: Element): string | null {
	return element.getAttribute('data-bridge-painted-source-correlations');
}

async function invokeCapturedPostRenderWithinAct(props: {
	readonly beforeInvoke?: () => void;
	readonly contextItem?: CodeViewItem;
	readonly invocation: CapturedBridgeFilePostRender;
	readonly phase: PostRenderPhase;
}): Promise<void> {
	await act(async (): Promise<void> => {
		props.beforeInvoke?.();
		props.invocation.invoke({
			phase: props.phase,
			...(props.contextItem === undefined ? {} : { contextItem: props.contextItem }),
		});
		await Promise.resolve();
	});
}

function requireMountedCodeView(codeView: CodeView | null): CodeView {
	if (codeView === null) {
		throw new Error('Expected production BridgeFileViewerCodePanel to mount a public CodeView.');
	}
	return codeView;
}

function captureBridgeFilePostRender(props: {
	readonly callback: NonNullable<CodeViewOptions<undefined>['onPostRender']>;
	readonly callbackArguments: readonly unknown[];
}): CapturedBridgeFilePostRender {
	const callbackArguments = requireBridgeFilePostRenderArguments(props.callbackArguments);
	return {
		contextItem: callbackArguments.context.item,
		invoke: (invokeProps): void => {
			Reflect.apply(props.callback, undefined, [
				callbackArguments.element,
				callbackArguments.instance,
				invokeProps.phase,
				invokeProps.contextItem === undefined
					? callbackArguments.context
					: { ...callbackArguments.context, item: invokeProps.contextItem },
			]);
		},
	};
}

class BridgeFilePostRenderCapture {
	private readonly invocationByItem = new Map<CodeViewItem, CapturedBridgeFilePostRender>();
	private readonly waiterByItem = new Map<
		CodeViewItem,
		(invocation: CapturedBridgeFilePostRender) => void
	>();

	capture(props: {
		readonly callback: NonNullable<CodeViewOptions<undefined>['onPostRender']>;
		readonly callbackArguments: readonly unknown[];
	}): void {
		const invocation = captureBridgeFilePostRender(props);
		if (!this.invocationByItem.has(invocation.contextItem)) {
			this.invocationByItem.set(invocation.contextItem, invocation);
		}
		const waiter = this.waiterByItem.get(invocation.contextItem);
		if (waiter === undefined) return;
		this.waiterByItem.delete(invocation.contextItem);
		waiter(invocation);
	}

	waitForItem(item: CodeViewItem): Promise<CapturedBridgeFilePostRender> {
		const invocation = this.invocationByItem.get(item);
		if (invocation !== undefined) return Promise.resolve(invocation);
		return new Promise((resolve): void => {
			this.waiterByItem.set(item, resolve);
		});
	}
}

async function waitForBridgeFilePostRender(
	capture: BridgeFilePostRenderCapture,
	item: CodeViewItem,
): Promise<CapturedBridgeFilePostRender> {
	let invocation: CapturedBridgeFilePostRender | undefined;
	await act(async (): Promise<void> => {
		invocation = await capture.waitForItem(item);
	});
	if (invocation === undefined) {
		throw new Error(`Expected Pierre onPostRender callback for exact File item ${item.id}.`);
	}
	return invocation;
}

function requireBridgeFilePostRenderArguments(callbackArguments: readonly unknown[]): {
	readonly context: Readonly<Record<string, unknown>> & { readonly item: CodeViewItem };
	readonly element: HTMLElement;
	readonly instance: unknown;
} {
	const [element, instance, phase, context] = callbackArguments;
	if (
		!(element instanceof HTMLElement) ||
		!isPostRenderPhase(phase) ||
		!isBridgeFilePostRenderContext(context)
	) {
		throw new Error('Expected Pierre public onPostRender element, instance, phase, and context.');
	}
	return { context, element, instance };
}

function isBridgeFilePostRenderContext(
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

function requireExactFilePierreItem(item: BridgeMainRenderPublicationItem): ExactFilePierreItem {
	if (!isExactFilePierreItem(item)) {
		throw new Error('Expected exact File worker publication to be a public Pierre file item.');
	}
	return item;
}

function isExactFilePierreItem(item: BridgeMainRenderPublicationItem): item is ExactFilePierreItem {
	if (item.type !== 'file') return false;
	const language = item.file.lang;
	return language === undefined
		? !Object.hasOwn(item.file, 'lang')
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

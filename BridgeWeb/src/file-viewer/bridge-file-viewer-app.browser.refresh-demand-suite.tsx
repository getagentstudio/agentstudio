import { CodeView, type CodeViewItem } from '@pierre/diffs';
import { useState, type ReactElement } from 'react';
import { afterEach, describe, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the app CSS.
import '../app/bridge-app.css';
import type { BridgeWorkerServerToMainMessage } from '../core/comm-worker/bridge-worker-contracts.js';
import {
	collapseBridgeViewerTreeFolder,
	requireBridgeViewerHTMLElement,
	waitForBridgeViewerTreeItemButton,
} from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import { registerBridgeFileViewerSourceSnapshotDemandTest } from './bridge-file-viewer-app.browser.source-snapshot-demand-suite.js';
import { BridgeFileViewerBrowserHarnessApp as BridgeFileViewerApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatch,
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcome,
	makeBrowserFileDescriptorOutcomeForContent,
	makeBrowserFileRow,
	makeBrowserFileSourceIdentity,
	type BrowserFileDescriptorOutcome,
	type PublishBrowserFileBatch,
} from './bridge-file-viewer-browser-test-batches.js';
import {
	fileNavigationCommandForPath,
	makeFileContent,
} from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actFrame,
	actUpdate,
	actUpdateAndWaitForBridgeFileViewerWorkerPublication,
	makeDeferredContent,
	makeBrowserFileBatchPublisherObservation,
	makeGeneratedFileBody,
	openFileBodyPreview,
	openFileState,
	requireBrowserFileBatchPublisher,
	requireActivateFiles,
	requireDeactivateFiles,
	settleBridgeFileViewerBrowserUpdates,
	waitForFileCodeViewScrollable,
	waitForFileCodeViewScrollOwner,
	waitForFileCodeViewScrollTopAtLeast,
	visibleCodeText,
	waitForFileViewerActiveState,
	waitForBridgeFileViewerWorkerMessageDrain,
	waitForOpenFileBodyPreview,
	waitForOpenFileState,
	waitForOpenedContentCount,
	waitForVisibleCodeText,
} from './bridge-file-viewer-browser-test-harness.js';

describe('BridgeFileViewerApp Browser Mode', () => {
	afterEach(async () => {
		vi.restoreAllMocks();
		await settleBridgeFileViewerBrowserUpdates();
		await actUpdate(cleanup);
		document.body.replaceChildren();
	});

	test('starts fresh and replacement File sources fully expanded', async () => {
		const initialDescriptors = [
			makeBrowserFileDescriptorOutcome({
				fileId: 'file-initial-old',
				path: 'src/old/initial.ts',
			}),
			makeBrowserFileDescriptorOutcome({
				fileId: 'file-initial-other',
				path: 'src/other/initial.ts',
			}),
		] as const;
		const replacementSourceIdentity = makeBrowserFileSourceIdentity({
			sourceCursor: 'cursor-expanded-replacement',
			subscriptionGeneration: 2,
		});
		const replacementDescriptors = [
			makeBrowserFileDescriptorOutcome({
				fileId: 'file-replacement-old',
				path: 'src/old/replacement.ts',
				source: replacementSourceIdentity,
			}),
			makeBrowserFileDescriptorOutcome({
				fileId: 'file-replacement-new',
				path: 'src/new/replacement.ts',
				source: replacementSourceIdentity,
			}),
		] as const;
		let publishFileBatch: PublishBrowserFileBatch | null = null;

		await render(
			<BridgeFileViewerApp
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', ...initialDescriptors)}
				fileProductSession={{
					onFileBatchPublisher: (handler): (() => void) => {
						publishFileBatch = handler;
						return (): void => {
							publishFileBatch = null;
						};
					},
				}}
			/>,
		);

		await waitForBridgeViewerTreeItemButton('src/old/initial.ts');
		await settleBridgeFileViewerBrowserUpdates();
		expect(fileTreeDisclosureRow('src')?.getAttribute('aria-expanded')).toBe('true');
		expect(fileTreeDisclosureRow('src/old')?.getAttribute('aria-expanded')).toBe('true');
		expect(fileTreeDisclosureRow('src/other')?.getAttribute('aria-expanded')).toBe('true');
		await collapseBridgeViewerTreeFolder('src/old');
		expect(fileTreeDisclosureRow('src/old')?.getAttribute('aria-expanded')).toBe('false');

		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishFileBatch)(
				makeCertifiedReplacementBatch(...replacementDescriptors),
			);
		});
		await waitForBridgeViewerTreeItemButton('src/new/replacement.ts');
		await waitForBridgeFileViewerWorkerMessageDrain();

		expect(fileTreeDisclosureRow('src')?.getAttribute('aria-expanded')).toBe('true');
		expect(fileTreeDisclosureRow('src/old')?.getAttribute('aria-expanded')).toBe('true');
		expect(fileTreeDisclosureRow('src/new')?.getAttribute('aria-expanded')).toBe('true');
	});

	test('does not open unselected content after a worker source replacement', async () => {
		const oldFirstDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'old-first-delayed-content',
			fileId: 'file-old-first-delayed',
			path: 'src/old-first-delayed.ts',
		});
		const oldSecondDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'old-second-delayed-content',
			fileId: 'file-old-second-delayed',
			path: 'src/old-second-delayed.ts',
		});
		const resetSourceIdentity = makeBrowserFileSourceIdentity({
			subscriptionGeneration: 2,
			sourceCursor: 'cursor-2',
		});
		const newFirstDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'new-first-content',
			fileId: 'file-new-first',
			path: 'src/new-first.ts',
			source: resetSourceIdentity,
		});
		const newSecondDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'new-second-content',
			fileId: 'file-new-second',
			path: 'src/new-second.ts',
			source: resetSourceIdentity,
		});
		const openedDescriptorIds: string[] = [];
		const publisherObservation = makeBrowserFileBatchPublisherObservation();

		await render(
			<BridgeFileViewerApp
				initialFileBatch={makeBrowserFileBatchWithDescriptors(
					'open',
					oldFirstDescriptor,
					oldSecondDescriptor,
				)}
				fileProductSession={{
					readContent: (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return Promise.resolve(makeFileContent('unexpected visible fetch\n'));
					},
					onFileBatchPublisher: (handler): void => {
						publisherObservation.observe(handler);
					},
				}}
			/>,
		);

		expect(openedDescriptorIds).toEqual([]);
		const publishRequiredFileBatch = await publisherObservation.publisher;
		await actUpdate((): void => {
			publishRequiredFileBatch(
				makeCertifiedReplacementBatch(newFirstDescriptor, newSecondDescriptor),
			);
		});
		await actFrame();
		await actFrame();

		const shell = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		);
		expect(openedDescriptorIds).toEqual([]);
		expect(shell.getAttribute('data-last-demand-dispatch-status')).toBeNull();
		expect(shell.getAttribute('data-last-demand-dispatch-origin')).toBeNull();
		expect(shell.getAttribute('data-last-demand-dispatch-intent-count')).toBeNull();
	});

	test('renders replacement file body after a worker source-update refreshes stale content', async () => {
		const initialContent = makeFileContent('export const initial = true;\n');
		const refreshedContent = makeFileContent('export const refreshed = true;\n');
		const initialDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: initialContent,
			descriptorId: 'refresh-content-1',
			fileId: 'file-refresh-target',
			path: 'src/refresh-target.ts',
		});
		const resetSourceIdentity = makeBrowserFileSourceIdentity({
			subscriptionGeneration: 2,
			sourceCursor: 'cursor-2',
		});
		const replacementDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: refreshedContent,
			descriptorId: 'refresh-content-2',
			fileId: 'file-refresh-target',
			path: 'src/refresh-target.ts',
			source: resetSourceIdentity,
		});
		const openedDescriptorIds: string[] = [];
		let publishFileBatch: PublishBrowserFileBatch | null = null;

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', initialDescriptor)}
				navigationCommand={fileNavigationCommandForPath('src/refresh-target.ts')}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return props.descriptor.descriptorId.includes('refresh-content-2')
							? refreshedContent
							: initialContent;
					},
					onFileBatchPublisher: (handler): (() => void) => {
						publishFileBatch = handler;
						return (): void => {
							publishFileBatch = null;
						};
					},
				}}
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const initial = true;');
		const publishRequiredFileBatch = requireBrowserFileBatchPublisher(publishFileBatch);
		await actUpdate((): void => {
			publishRequiredFileBatch(makeCertifiedReplacementBatch(replacementDescriptor));
		});
		// The worker owns selected File View refresh after a source update:
		// wait on the refreshed content itself, since 'ready' also describes
		// the pre-reset state and the stale/loading states are transient.
		await waitForVisibleCodeText('export const refreshed = true;');
		await waitForOpenFileState('ready');
		expect(document.querySelector('[data-testid="worktree-file-refresh"]')).toBeNull();
		expect(openedDescriptorIds).toContain('refresh-content-2');
		expect(openFileBodyPreview()).toContain('export const refreshed = true;');
		await waitForVisibleCodeText('export const refreshed = true;');

		expect(visibleCodeText()).not.toContain('export const initial = true;');
	});

	test('renders replacement file body after an auto-open worker source refresh', async () => {
		const initialContent = makeFileContent('export const autoInitial = true;\n');
		const refreshedContent = makeFileContent('export const autoRefreshed = true;\n');
		const initialDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: initialContent,
			descriptorId: 'auto-refresh-content-1',
			fileId: 'file-auto-refresh-target',
			path: 'src/auto-refresh-target.ts',
		});
		const resetSourceIdentity = makeBrowserFileSourceIdentity({
			subscriptionGeneration: 2,
			sourceCursor: 'cursor-2',
		});
		const replacementDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: refreshedContent,
			descriptorId: 'auto-refresh-content-2',
			fileId: 'file-auto-refresh-target',
			path: 'src/auto-refresh-target.ts',
			source: resetSourceIdentity,
		});
		const openedDescriptorIds: string[] = [];
		let publishFileBatch: PublishBrowserFileBatch | null = null;

		await render(
			<BridgeFileViewerApp
				autoOpenInitialFile
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', initialDescriptor)}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return props.descriptor.descriptorId.includes('auto-refresh-content-2')
							? refreshedContent
							: initialContent;
					},
					onFileBatchPublisher: (handler): (() => void) => {
						publishFileBatch = handler;
						return (): void => {
							publishFileBatch = null;
						};
					},
				}}
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const autoInitial = true;');
		const publishRequiredFileBatch = requireBrowserFileBatchPublisher(publishFileBatch);
		await actUpdate((): void => {
			publishRequiredFileBatch(makeCertifiedReplacementBatch(replacementDescriptor));
		});
		await waitForVisibleCodeText('export const autoRefreshed = true;');
		await waitForOpenFileState('ready');

		expect(document.querySelector('[data-testid="worktree-file-refresh"]')).toBeNull();
		expect(openedDescriptorIds).toContain('auto-refresh-content-2');
		expect(openFileBodyPreview()).toContain('export const autoRefreshed = true;');
		expect(visibleCodeText()).not.toContain('export const autoInitial = true;');
	});

	test('restores File CodeView scroll position after a same-path worker source refresh', async () => {
		const codeViewByRoot = new Map<HTMLElement, CodeView<undefined>>();
		const setItemReceipts: {
			readonly items: readonly CodeViewItem<undefined>[];
			readonly owner: CodeView<undefined>;
		}[] = [];
		// oxlint-disable-next-line unbound-method -- Browser witness delegates to the exact prototype method.
		const originalSetup = CodeView.prototype.setup;
		// oxlint-disable-next-line unbound-method -- Browser witness delegates to the exact prototype method.
		const originalSetItems = CodeView.prototype.setItems;
		vi.spyOn(CodeView.prototype, 'setup').mockImplementation(function captureCodeViewRoot(
			this: CodeView<undefined>,
			root: HTMLElement,
		): void {
			codeViewByRoot.set(root, this);
			originalSetup.call(this, root);
		});
		vi.spyOn(CodeView.prototype, 'setItems').mockImplementation(function captureCodeViewItems(
			this: CodeView<undefined>,
			items: readonly CodeViewItem<undefined>[],
		): void {
			setItemReceipts.push({ items: [...items], owner: this });
			originalSetItems.call(this, items);
		});
		const initialContent = makeGeneratedFileBody('initialScroll', 140);
		const refreshedContent = makeGeneratedFileBody('refreshedScroll', 140);
		const initialDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: initialContent,
			descriptorId: 'refresh-scroll-content-1',
			fileId: 'file-refresh-scroll-target',
			path: 'src/refresh-scroll-target.ts',
		});
		const resetSourceIdentity = makeBrowserFileSourceIdentity({
			subscriptionGeneration: 2,
			sourceCursor: 'cursor-2',
		});
		const replacementDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: refreshedContent,
			descriptorId: 'refresh-scroll-content-2',
			fileId: 'file-refresh-scroll-target',
			path: 'src/refresh-scroll-target.ts',
			source: resetSourceIdentity,
		});
		let publishFileBatch: PublishBrowserFileBatch | null = null;

		await render(
			<div style={{ display: 'grid', height: '360px', overflow: 'hidden', width: '960px' }}>
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', initialDescriptor)}
					navigationCommand={fileNavigationCommandForPath('src/refresh-scroll-target.ts')}
					fileProductSession={{
						readContent: async (props) =>
							props.descriptor.descriptorId.includes('refresh-scroll-content-2')
								? refreshedContent
								: initialContent,
						onFileBatchPublisher: (handler): (() => void) => {
							publishFileBatch = handler;
							return (): void => {
								publishFileBatch = null;
							};
						},
					}}
				/>
			</div>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const initialScrollLine001 = true;');
		const scrollOwner = await waitForFileCodeViewScrollOwner();
		const codeViewOwner = codeViewByRoot.get(scrollOwner);
		if (codeViewOwner === undefined) {
			throw new Error('Expected the File CodeView owner for the selected scroll element.');
		}
		await waitForFileCodeViewScrollable(scrollOwner);
		await actUpdate((): void => {
			scrollOwner.scrollTop = 320;
			scrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
		});
		const scrollTopBeforeRefresh = scrollOwner.scrollTop;
		expect(scrollTopBeforeRefresh).toBeGreaterThan(0);
		await actFrame();
		const visibleInitialText = visibleCodeText();
		const visibleInitialLine = /initialScrollLine(\d{3})/u.exec(visibleInitialText)?.[1];
		if (visibleInitialLine === undefined) {
			throw new Error(`Expected a visible initial scroll line; actual=${visibleInitialText}`);
		}

		setItemReceipts.length = 0;
		const publishRequiredFileBatch = requireBrowserFileBatchPublisher(publishFileBatch);
		await actUpdate((): void => {
			publishRequiredFileBatch(makeCertifiedReplacementBatch(replacementDescriptor));
		});
		await waitForOpenFileBodyPreview('export const refreshedScrollLine001 = true;');
		await waitForVisibleCodeText(`export const refreshedScrollLine${visibleInitialLine} = true;`);
		await waitForOpenFileState('ready');
		await waitForBridgeFileViewerWorkerMessageDrain();
		const refreshedScrollOwner = await waitForFileCodeViewScrollOwner();
		await waitForFileCodeViewScrollTopAtLeast({
			minimumScrollTop: scrollTopBeforeRefresh - 1,
			scrollOwner: refreshedScrollOwner,
		});

		expect(openFileBodyPreview()).toContain('export const refreshedScrollLine001 = true;');
		expect(refreshedScrollOwner).toBe(scrollOwner);
		expect(
			setItemReceipts.some(
				(receipt) => receipt.owner === codeViewOwner && receipt.items.length === 0,
			),
		).toBe(false);
		expect(refreshedScrollOwner.scrollTop).toBeGreaterThanOrEqual(scrollTopBeforeRefresh - 1);
		expect(visibleCodeText()).not.toContain('export const initialScrollLine001 = true;');
	});

	test('reissues a persistently failing replacement content open exactly once', async () => {
		const initialContent = makeFileContent('export const failedRefreshInitial = true;\n');
		const initialDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: initialContent,
			descriptorId: 'failed-refresh-content-1',
			fileId: 'file-failed-refresh-target',
			path: 'src/failed-refresh-target.ts',
		});
		const resetSourceIdentity = makeBrowserFileSourceIdentity({
			subscriptionGeneration: 2,
			sourceCursor: 'cursor-2',
		});
		const replacementDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'failed-refresh-content-2',
			fileId: 'file-failed-refresh-target',
			path: 'src/failed-refresh-target.ts',
			source: resetSourceIdentity,
		});
		const openedDescriptorIds: string[] = [];
		let publishFileBatch: PublishBrowserFileBatch | null = null;

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', initialDescriptor)}
				navigationCommand={fileNavigationCommandForPath('src/failed-refresh-target.ts')}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						if (props.descriptor.descriptorId.includes('failed-refresh-content-2')) {
							throw new Error('failed refresh canary');
						}
						return initialContent;
					},
					onFileBatchPublisher: (handler): (() => void) => {
						publishFileBatch = handler;
						return (): void => {
							publishFileBatch = null;
						};
					},
				}}
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('failedRefreshInitial');
		const publishRequiredFileBatch = requireBrowserFileBatchPublisher(publishFileBatch);
		await actUpdate((): void => {
			publishRequiredFileBatch(makeCertifiedReplacementBatch(replacementDescriptor));
		});
		await waitForOpenedContentCount({
			expectedCount: 3,
			openedDescriptorIds: openedDescriptorIds,
		});
		await waitForOpenFileState('failed');
		await actFrame();
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		expect(openFileState()).toBe('failed');
		expect(visibleCodeText()).not.toContain('failedRefreshReplacement');
		expect(
			openedDescriptorIds.filter((url) => url.includes('failed-refresh-content-2')),
		).toHaveLength(2);
	});

	test('keeps selected File loading through unscoped worker health and accepts content completion', async () => {
		const completedContent = makeFileContent('export const completedAfterWorkerHealth = true;\n');
		const targetDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: completedContent,
			descriptorId: 'degraded-worker-content',
			fileId: 'file-degraded-worker-target',
			path: 'src/degraded-worker-target.ts',
		});
		const deferredContent = makeDeferredContent();
		let publishWorkerMessages:
			| ((messages: readonly BridgeWorkerServerToMainMessage[]) => void)
			| null = null;

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', targetDescriptor)}
				navigationCommand={fileNavigationCommandForPath('src/degraded-worker-target.ts')}
				fileProductSession={{
					readContent: () => deferredContent.promise,
					onWorkerMessagesPublisher: (publisher) => {
						publishWorkerMessages = publisher;
					},
				}}
			/>,
		);

		await waitForOpenFileState('loading');
		await actUpdateAndWaitForBridgeFileViewerWorkerPublication((): void => {
			const publisher = publishWorkerMessages;
			if (publisher === null) throw new Error('Expected File worker message publisher.');
			publisher([
				{
					direction: 'serverWorkerToMain',
					kind: 'health',
					message: 'browser worker startup failed',
					requestId: 'browser-degraded-worker',
					status: 'degraded',
					transferDescriptors: [],
					wireVersion: 1,
				},
			]);
		});
		expect(openFileState()).toBe('loading');

		await actUpdate((): void => {
			deferredContent.resolve(completedContent);
		});
		await waitForVisibleCodeText('completedAfterWorkerHealth');
		expect(openFileState()).toBe('ready');
	});

	test('reissues a failed same-file source replacement exactly once', async () => {
		const initialContent = makeFileContent('export const failedNavigationRetryInitial = true;\n');
		const replacementContent = makeFileContent(
			'export const failedNavigationRetryReplacement = true;\n',
		);
		const initialDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: initialContent,
			descriptorId: 'failed-navigation-retry-content-1',
			fileId: 'file-failed-navigation-retry-target',
			path: 'src/failed-navigation-retry-target.ts',
		});
		const resetSourceIdentity = makeBrowserFileSourceIdentity({
			subscriptionGeneration: 2,
			sourceCursor: 'cursor-2',
		});
		const replacementDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: replacementContent,
			descriptorId: 'failed-navigation-retry-content-2',
			fileId: 'file-failed-navigation-retry-target',
			path: 'src/failed-navigation-retry-target.ts',
			source: resetSourceIdentity,
		});
		const openedDescriptorIds: string[] = [];
		let publishFileBatch: PublishBrowserFileBatch | null = null;
		let replacementFetchAttemptCount = 0;

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', initialDescriptor)}
				navigationCommand={fileNavigationCommandForPath('src/failed-navigation-retry-target.ts')}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						if (props.descriptor.descriptorId.includes('failed-navigation-retry-content-2')) {
							replacementFetchAttemptCount += 1;
							if (replacementFetchAttemptCount === 1) {
								throw new Error('failed navigation retry canary');
							}
							return replacementContent;
						}
						return initialContent;
					},
					onFileBatchPublisher: (handler): (() => void) => {
						publishFileBatch = handler;
						return (): void => {
							publishFileBatch = null;
						};
					},
				}}
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('failedNavigationRetryInitial');
		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishFileBatch)(
				makeCertifiedReplacementBatch(replacementDescriptor),
			);
		});
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('failedNavigationRetryReplacement');
		await waitForOpenedContentCount({
			expectedCount: 3,
			openedDescriptorIds: openedDescriptorIds,
		});
		await actFrame();
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();
		expect(
			openedDescriptorIds.filter((url) => url.includes('failed-navigation-retry-content-2')),
		).toHaveLength(2);
	});

	test('reissues a failed initial navigation target exactly once', async () => {
		const recoveredContent = makeFileContent('export const failedOpenRetryRecovered = true;\n');
		const targetDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: recoveredContent,
			descriptorId: 'failed-open-retry-content',
			fileId: 'file-failed-open-retry-target',
			path: 'src/failed-open-retry-target.ts',
		});
		const openedDescriptorIds: string[] = [];
		let fetchAttemptCount = 0;

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', targetDescriptor)}
				navigationCommand={fileNavigationCommandForPath('src/failed-open-retry-target.ts')}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						fetchAttemptCount += 1;
						if (fetchAttemptCount === 1) {
							throw new Error('failed open retry canary');
						}
						return recoveredContent;
					},
				}}
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('failedOpenRetryRecovered');
		await waitForOpenedContentCount({
			expectedCount: 2,
			openedDescriptorIds: openedDescriptorIds,
		});
		await actFrame();
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();
		expect(openedDescriptorIds).toEqual(['failed-open-retry-content', 'failed-open-retry-content']);
	});

	test('continues worker-owned replacement content completion while Files is inactive', async () => {
		const initialContent = makeFileContent('export const inactiveRefreshInitial = true;\n');
		const replacementContent = makeFileContent('export const inactiveRefreshReplacement = true;\n');
		const initialDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: initialContent,
			descriptorId: 'inactive-refresh-content-1',
			fileId: 'file-inactive-refresh-target',
			path: 'src/inactive-refresh-target.ts',
		});
		const resetSourceIdentity = makeBrowserFileSourceIdentity({
			subscriptionGeneration: 2,
			sourceCursor: 'cursor-2',
		});
		const replacementDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: replacementContent,
			descriptorId: 'inactive-refresh-content-2',
			fileId: 'file-inactive-refresh-target',
			path: 'src/inactive-refresh-target.ts',
			source: resetSourceIdentity,
		});
		const deferredRefreshContent = makeDeferredContent();
		let activateFiles: (() => void) | null = null;
		let deactivateFiles: (() => void) | null = null;
		let publishFileBatch: PublishBrowserFileBatch | null = null;

		function ControlledFileViewer(): ReactElement {
			const [isActive, setIsActive] = useState(true);
			activateFiles = (): void => {
				setIsActive(true);
			};
			deactivateFiles = (): void => {
				setIsActive(false);
			};
			return (
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', initialDescriptor)}
					isActive={isActive}
					navigationCommand={fileNavigationCommandForPath('src/inactive-refresh-target.ts')}
					fileProductSession={{
						readContent: (props) => {
							if (props.descriptor.descriptorId.includes('inactive-refresh-content-2')) {
								return deferredRefreshContent.promise;
							}
							return Promise.resolve(initialContent);
						},
						onFileBatchPublisher: (handler): (() => void) => {
							publishFileBatch = handler;
							return (): void => {
								publishFileBatch = null;
							};
						},
					}}
				/>
			);
		}

		await render(<ControlledFileViewer />);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('inactiveRefreshInitial');
		const publishRequiredFileBatch = requireBrowserFileBatchPublisher(publishFileBatch);
		await actUpdate((): void => {
			publishRequiredFileBatch(makeCertifiedReplacementBatch(replacementDescriptor));
		});
		await waitForOpenFileState('loading');
		await actUpdate(requireDeactivateFiles(deactivateFiles));
		await waitForFileViewerActiveState('false');

		await actUpdate((): void => {
			deferredRefreshContent.resolve(replacementContent);
		});
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('inactiveRefreshReplacement');

		expect(openFileState()).toBe('ready');
		expect(visibleCodeText()).not.toContain('inactiveRefreshInitial');
		expect(visibleCodeText()).toContain('inactiveRefreshReplacement');
		const shell = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		);
		expect(shell.getAttribute('data-file-viewer-active')).toBe('false');
		expect(shell.getAttribute('data-last-refresh-commit-state')).toBeNull();

		await actUpdate(requireActivateFiles(activateFiles));
	});

	test('keeps selected file ready when reset metadata carries the same content descriptor', async () => {
		const stableContent = makeFileContent('export const stable = true;\n');
		const initialDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: stableContent,
			descriptorId: 'stable-content',
			fileId: 'file-stable-target',
			path: 'src/stable-target.ts',
		});
		const resetSourceIdentity = makeBrowserFileSourceIdentity({
			subscriptionGeneration: 2,
			sourceCursor: 'cursor-2',
		});
		const sameContentDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: stableContent,
			descriptorId: 'stable-content',
			fileId: 'file-stable-target',
			path: 'src/stable-target.ts',
			source: resetSourceIdentity,
		});
		let publishFileBatch: PublishBrowserFileBatch | null = null;

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', initialDescriptor)}
				navigationCommand={fileNavigationCommandForPath('src/stable-target.ts')}
				fileProductSession={{
					readContent: async () => stableContent,
					onFileBatchPublisher: (handler): (() => void) => {
						publishFileBatch = handler;
						return (): void => {
							publishFileBatch = null;
						};
					},
				}}
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const stable = true;');
		const publishRequiredFileBatch = requireBrowserFileBatchPublisher(publishFileBatch);
		await actUpdate((): void => {
			publishRequiredFileBatch(makeCertifiedReplacementBatch(sameContentDescriptor));
		});

		await actFrame();
		await actFrame();
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const stable = true;');
		expect(openFileState()).toBe('ready');
	});

	test('retains selected content while a new source snapshot replaces the active stream', async () => {
		const initialContent = makeFileContent('export const sourceSnapshotInitial = true;\n');
		const replacementContent = makeFileContent('export const sourceSnapshotFresh = true;\n');
		const initialDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: initialContent,
			descriptorId: 'source-snapshot-content-1',
			fileId: 'file-source-less-reset-target',
			path: 'src/source-less-reset-target.ts',
		});
		const replacementSourceIdentity = makeBrowserFileSourceIdentity({
			subscriptionGeneration: 2,
			sourceCursor: 'cursor-2',
		});
		const replacementDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: replacementContent,
			descriptorId: 'source-snapshot-content-2',
			fileId: 'file-source-less-reset-target',
			path: 'src/source-less-reset-target.ts',
			source: replacementSourceIdentity,
		});
		let publishFileBatch: PublishBrowserFileBatch | null = null;

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', initialDescriptor)}
				navigationCommand={fileNavigationCommandForPath('src/source-less-reset-target.ts')}
				fileProductSession={{
					readContent: async (props) =>
						props.descriptor.descriptorId.includes('source-snapshot-content-2')
							? replacementContent
							: initialContent,
					onFileBatchPublisher: (handler): (() => void) => {
						publishFileBatch = handler;
						return (): void => {
							publishFileBatch = null;
						};
					},
				}}
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('sourceSnapshotInitial');
		const publishRequiredFileBatch = requireBrowserFileBatchPublisher(publishFileBatch);
		// W4 receiver tests cover partial replacement staging. This page assertion covers
		// readable old content before the next certified batch is installed.
		expect(visibleCodeText()).toContain('sourceSnapshotInitial');

		await actUpdate((): void => {
			publishRequiredFileBatch(makeCertifiedReplacementBatch(replacementDescriptor));
		});
		await waitForVisibleCodeText('sourceSnapshotFresh');
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('sourceSnapshotFresh');
		expect(visibleCodeText()).not.toContain('sourceSnapshotInitial');
	});

	registerBridgeFileViewerSourceSnapshotDemandTest();
});

function fileTreeDisclosureRow(path: string): HTMLButtonElement | null {
	const fileTreeContainer = document.querySelector('file-tree-container');
	const row = fileTreeContainer?.shadowRoot?.querySelector(
		`button[data-item-path="${CSS.escape(`${path}/`)}"][aria-expanded]`,
	);
	return row instanceof HTMLButtonElement ? row : null;
}

function makeCertifiedReplacementBatch(
	...outcomes: readonly BrowserFileDescriptorOutcome[]
): ReturnType<typeof makeBrowserFileBatch> {
	return makeBrowserFileBatch({
		snapshotCause: 'open',
		rows: outcomes.map((descriptorOutcome) =>
			makeBrowserFileRow({ path: descriptorOutcome.path, descriptorOutcome }),
		),
		revision: 2,
		...(outcomes[0] === undefined ? {} : { source: outcomes[0].source }),
	});
}

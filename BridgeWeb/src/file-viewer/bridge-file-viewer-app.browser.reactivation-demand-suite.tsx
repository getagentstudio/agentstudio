import { act, useState, type ReactElement } from 'react';
import { afterEach, describe, expect, test } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the app CSS.
import '../app/bridge-app.css';
import { createBridgeProductDeferred } from '../core/comm-worker/bridge-product-async-queue.js';
import {
	findBridgeViewerTreeItemButton,
	requireBridgeViewerHTMLElement,
	waitForBridgeViewerTreeItemButton,
} from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import { BridgeFileViewerBrowserHarnessApp as BridgeFileViewerApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcome,
	makeBrowserFileDescriptorOutcomeForContent,
	makeBrowserFileRow,
	makeBrowserMetadataOnlyFileBatch,
	replaceBrowserFileBatchRows,
	type BrowserFileViewScope,
	type PublishBrowserFileBatch,
} from './bridge-file-viewer-browser-test-batches.js';
import { makeFileContent } from './bridge-file-viewer-browser-test-fixtures.js';
import { fileNavigationCommandForPath } from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actClick,
	actFrame,
	actUpdate,
	makeDeferredContent,
	openFileBodyPreview,
	openFilePath,
	openFileState,
	renderedFilePath,
	requireActivateFiles,
	requireDeactivateFiles,
	requireBrowserFileBatchPublisher,
	selectedDisplayPath,
	visibleCodeText,
	waitForMetadataInterestUpdateCount,
	waitForFileViewerActiveState,
	waitForMetadataSubscriptionOpenCount,
	waitForMetadataTreeRowCount,
	waitForBridgeFileViewerWorkerMessageDrain,
	waitForOpenFileState,
	waitForOpenedContentCount,
	waitForSelectedDisplayPath,
	waitForVisibleCodeText,
} from './bridge-file-viewer-browser-test-harness.js';

describe('BridgeFileViewerApp Browser Mode', () => {
	afterEach(async () => {
		await waitForBridgeFileViewerWorkerMessageDrain();
	});

	test('recovers a slow foreground navigation open after Files reactivates', async () => {
		const loadedWhileInactiveContent = makeFileContent(
			'export const loadedWhileInactive = true;\n',
		);
		const slowDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: loadedWhileInactiveContent,
			contentHandle: 'inactive-open-content',
			fileId: 'file-inactive-open',
			path: 'src/inactive-open.ts',
		});
		const firstDeferredContent = makeDeferredContent();
		const openedDescriptorIds: string[] = [];
		let activateFiles: (() => void) | null = null;
		let deactivateFiles: (() => void) | null = null;

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
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', slowDescriptor)}
					isActive={isActive}
					navigationCommand={fileNavigationCommandForPath('src/inactive-open.ts')}
					fileProductSession={{
						readContent: (props) => {
							openedDescriptorIds.push(props.descriptor.descriptorId);
							return firstDeferredContent.promise;
						},
					}}
				/>
			);
		}

		await act(async (): Promise<void> => {
			await render(<ControlledFileViewer />);
			await import('./bridge-file-viewer-shell.js');
			await Promise.resolve();
		});
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		await waitForOpenFileState('loading');
		await waitForOpenedContentCount({
			expectedCount: 1,
			openedDescriptorIds: openedDescriptorIds,
		});
		await actUpdate(requireDeactivateFiles(deactivateFiles));
		await waitForFileViewerActiveState('false');
		await actUpdate((): void => {
			firstDeferredContent.resolve(loadedWhileInactiveContent);
		});
		await actFrame();
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		const shell = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		);
		expect(shell.getAttribute('data-file-viewer-active')).toBe('false');
		expect(openFileState()).toBe('ready');
		expect(openFileBodyPreview()).toContain('loadedWhileInactive');
		expect(visibleCodeText()).toContain('loadedWhileInactive');

		await actUpdate(requireActivateFiles(activateFiles));
		await waitForFileViewerActiveState('true');
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('loadedWhileInactive');
		await waitForBridgeFileViewerWorkerMessageDrain();
		expect(openFilePath()).toBe('src/inactive-open.ts');
		expect(openFileBodyPreview()).toContain('loadedWhileInactive');
	});

	test('reissues an aborted still-selected content open exactly once', async () => {
		const retriedContent = makeFileContent('export const autoOpenRetried = true;\n');
		const initialDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: retriedContent,
			contentHandle: 'auto-open-aborted-content',
			fileId: 'file-auto-open-aborted',
			path: 'src/auto-open-aborted.ts',
		});
		const firstFetchController: { reject: ((reason?: unknown) => void) | null } = {
			reject: null,
		};
		const firstFetchPromise = new Promise<never>((_resolve, reject): void => {
			firstFetchController.reject = reject;
		});
		const openedDescriptorIds: string[] = [];

		await render(
			<BridgeFileViewerApp
				autoOpenInitialFile
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', initialDescriptor)}
				fileProductSession={{
					readContent: (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						if (openedDescriptorIds.length === 1) {
							return firstFetchPromise;
						}
						return Promise.resolve(retriedContent);
					},
				}}
			/>,
		);
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		await waitForOpenFileState('loading');
		await waitForOpenedContentCount({
			expectedCount: 1,
			openedDescriptorIds: openedDescriptorIds,
		});
		const rejectFirstFetch = firstFetchController.reject;
		if (rejectFirstFetch === null) {
			throw new Error('Expected first fetch reject callback to be registered.');
		}
		await actUpdate((): void => {
			rejectFirstFetch(new DOMException('Context switch aborted', 'AbortError'));
		});
		await waitForOpenedContentCount({
			expectedCount: 2,
			openedDescriptorIds: openedDescriptorIds,
		});
		await waitForOpenFileState('ready');
		await actFrame();
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();
		expect(openedDescriptorIds).toHaveLength(2);
		expect(openFileState()).toBe('ready');
		expect(openFilePath()).toBe('src/auto-open-aborted.ts');
		expect(openFileBodyPreview()).toContain('autoOpenRetried');
	});

	test('preserves the streamed surface when Files becomes active again', async () => {
		let activateFiles: (() => void) | null = null;
		let deactivateFiles: (() => void) | null = null;
		let metadataSubscriptionOpenCount = 0;

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
					initialFileBatch={makeBrowserFileBatchWithDescriptors(
						'open',
						makeBrowserFileDescriptorOutcome({
							descriptorId: 'content-1',
							fileId: 'file-1',
							path: 'src/file-1.ts',
						}),
					)}
					isActive={isActive}
					fileProductSession={{
						onMetadataSubscriptionOpen: () => {
							metadataSubscriptionOpenCount += 1;
						},
					}}
				/>
			);
		}

		await render(<ControlledFileViewer />);
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		await waitForMetadataSubscriptionOpenCount({
			expectedCount: 1,
			getLoadCount: () => metadataSubscriptionOpenCount,
		});
		await actUpdate(requireDeactivateFiles(deactivateFiles));
		await waitForFileViewerActiveState('false');
		await actUpdate(requireActivateFiles(activateFiles));
		await waitForFileViewerActiveState('true');
		await actFrame();
		await actFrame();
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		expect(metadataSubscriptionOpenCount).toBe(1);
		await waitForBridgeViewerTreeItemButton('src/file-1.ts');
		await waitForBridgeFileViewerWorkerMessageDrain();
	});

	test('applies a tree delta pushed while Files is hidden without reloading the surface', async () => {
		let activateFiles: (() => void) | null = null;
		let deactivateFiles: (() => void) | null = null;
		let metadataSubscriptionOpenCount = 0;
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const initialBatch = makeBrowserFileBatchWithDescriptors(
			'open',
			makeBrowserFileDescriptorOutcome({
				descriptorId: 'content-existing',
				fileId: 'file-existing',
				path: 'src/existing.ts',
			}),
			makeBrowserFileDescriptorOutcome({
				descriptorId: 'content-removed',
				fileId: 'file-removed',
				path: 'src/removed.ts',
			}),
		);

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
					initialFileBatch={initialBatch}
					isActive={isActive}
					fileProductSession={{
						onMetadataSubscriptionOpen: () => {
							metadataSubscriptionOpenCount += 1;
						},
						onFileBatchPublisher: (handler): (() => void) => {
							publishMetadataEvents = handler;
							return (): void => {
								publishMetadataEvents = null;
							};
						},
					}}
				/>
			);
		}

		await render(<ControlledFileViewer />);
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		await waitForMetadataSubscriptionOpenCount({
			expectedCount: 1,
			getLoadCount: () => metadataSubscriptionOpenCount,
		});
		await waitForMetadataTreeRowCount(3);
		await waitForBridgeViewerTreeItemButton('src/existing.ts');
		await waitForBridgeViewerTreeItemButton('src/removed.ts');

		// Hide Files (switch to Review), then push a tree delta while hidden.
		await actUpdate(requireDeactivateFiles(deactivateFiles));
		await waitForFileViewerActiveState('false');
		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishMetadataEvents)(
				replaceBrowserFileBatchRows({
					snapshotCause: 'newerInput',
					previous: initialBatch,
					upserts: [
						makeBrowserFileRow({ path: 'src/added.ts', fileId: 'file-added', lineCount: 12 }),
					],
					deletedPaths: ['src/removed.ts'],
					revision: 2,
				}),
			);
		});
		await waitForBridgeFileViewerWorkerMessageDrain();

		// Show Files again (switch back to Review -> Files).
		await actUpdate(requireActivateFiles(activateFiles));
		await waitForFileViewerActiveState('true');
		await waitForBridgeViewerTreeItemButton('src/added.ts');
		await waitForBridgeFileViewerWorkerMessageDrain();

		expect(findBridgeViewerTreeItemButton('src/removed.ts')).toBeNull();
		expect(findBridgeViewerTreeItemButton('src/existing.ts')).not.toBeNull();
		expect(metadataSubscriptionOpenCount).toBe(1);
	});

	test('opens clicked file content after Files reactivates with the preserved streamed surface', async () => {
		let activateFiles: (() => void) | null = null;
		let deactivateFiles: (() => void) | null = null;
		let metadataSubscriptionOpenCount = 0;
		const openedDescriptorIds: string[] = [];
		const reactivatedContent = makeDeferredContent();
		const reactivatedContentBody = makeFileContent(
			'export const reactivatedPreservedFile = true;\n',
		);
		const reactivatedDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: reactivatedContentBody,
			contentHandle: 'content-1',
			fileId: 'file-1',
			path: 'src/file-1.ts',
		});

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
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', reactivatedDescriptor)}
					isActive={isActive}
					fileProductSession={{
						readContent: (props) => {
							openedDescriptorIds.push(props.descriptor.descriptorId);
							return reactivatedContent.promise;
						},
						onMetadataSubscriptionOpen: () => {
							metadataSubscriptionOpenCount += 1;
						},
					}}
				/>
			);
		}

		await render(<ControlledFileViewer />);
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		await waitForMetadataSubscriptionOpenCount({
			expectedCount: 1,
			getLoadCount: () => metadataSubscriptionOpenCount,
		});
		await actUpdate(requireDeactivateFiles(deactivateFiles));
		await waitForFileViewerActiveState('false');
		await actUpdate(requireActivateFiles(activateFiles));
		await waitForFileViewerActiveState('true');
		await actFrame();
		await actFrame();
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		expect(metadataSubscriptionOpenCount).toBe(1);
		const reactivatedFileButton = await waitForBridgeViewerTreeItemButton('src/file-1.ts');
		await actClick(reactivatedFileButton);
		await waitForOpenedContentCount({
			expectedCount: 1,
			openedDescriptorIds: openedDescriptorIds,
		});
		await actUpdate((): void => {
			reactivatedContent.resolve(reactivatedContentBody);
		});

		await waitForOpenFileState('ready');
		await waitForSelectedDisplayPath('src/file-1.ts');
		await waitForVisibleCodeText('reactivatedPreservedFile');
		await actFrame();
		await actFrame();
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		expect(selectedDisplayPath()).toBe('src/file-1.ts');
		expect(openFilePath()).toBe('src/file-1.ts');
		expect(renderedFilePath()).toBe('src/file-1.ts');
		expect(openFileBodyPreview()).toContain('reactivatedPreservedFile');
		expect(openedDescriptorIds).toContain('content-1');
	});

	test('opens the inactive metadata subscription without main-thread demand', async () => {
		let metadataSubscriptionOpenCount = 0;
		const observedScopes: BrowserFileViewScope[] = [];

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserMetadataOnlyFileBatch('open')}
				isActive={false}
				fileProductSession={{
					onMetadataSubscriptionOpen: () => {
						metadataSubscriptionOpenCount += 1;
					},
					onFileScopeChange: (scope) => {
						observedScopes.push(scope);
					},
				}}
			/>,
		);
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		expect(metadataSubscriptionOpenCount).toBe(1);
		expect(observedScopes).toEqual([]);
	});

	test('does not open unselected descriptors while Files is inactive', async () => {
		const visibleDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'visible-content',
			fileId: 'file-visible',
			path: 'src/visible.ts',
		});
		const updatedDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'recently-updated-content',
			fileId: 'file-recently-updated',
			path: 'src/recently-updated.ts',
		});
		const openedDescriptorIds: string[] = [];

		await render(
			<BridgeFileViewerApp
				initialFileBatch={makeBrowserFileBatchWithDescriptors(
					'open',
					visibleDescriptor,
					updatedDescriptor,
				)}
				isActive={false}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return makeFileContent('unexpected page-level event content open\n');
					},
				}}
			/>,
		);
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();
		expect(openFileState()).toBeNull();
		expect(openedDescriptorIds).toEqual([]);
	});

	test('requests visible metadata-only descriptors without opening their content', async () => {
		const metadataInterestUpdates: BrowserFileViewScope[] = [];
		const openedDescriptorIds: string[] = [];
		const workerCommandNames: string[] = [];
		const viewportCommandObserved = createBridgeProductDeferred<void>();

		await render(
			<div style={{ height: '720px', overflow: 'hidden', width: '1280px' }}>
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserMetadataOnlyFileBatch('open')}
					fileProductSession={{
						onWorkerCommand: (message) => {
							workerCommandNames.push(message.command);
							if (message.command === 'viewport') viewportCommandObserved.resolve();
						},
						readContent: async (props) => {
							openedDescriptorIds.push(props.descriptor.descriptorId);
							return makeFileContent('export const recentlyUpdatedMetadataOnly = true;\n');
						},
						onFileScopeChange: (request) => {
							metadataInterestUpdates.push(request);
						},
					}}
				/>
			</div>,
		);
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		await waitForBridgeViewerTreeItemButton('Sources/AgentStudio/App/AppDelegate.swift');
		await viewportCommandObserved.promise;
		expect(workerCommandNames).toContain('viewport');
		await waitForMetadataInterestUpdateCount({
			expectedCount: 1,
			metadataInterestUpdates: metadataInterestUpdates,
		});
		await actFrame();
		await actFrame();
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		expect(metadataInterestUpdates.at(-1)).toMatchObject({
			interests: [{ lane: 'visible', paths: ['Sources/AgentStudio/App/AppDelegate.swift'] }],
			pathScope: [],
		});
		expect(openedDescriptorIds).toEqual([]);
		expect(openFileState()).toBeNull();
	});

	test('keeps metadata-only fulfillment from opening content while Files is inactive', async () => {
		const firstDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'recently-updated-inactive-content',
			fileId: 'file-app-delegate',
			path: 'Sources/AgentStudio/App/AppDelegate.swift',
		});
		const metadataInterestUpdates: BrowserFileViewScope[] = [];
		const openedDescriptorIds: string[] = [];
		let deactivateFiles: (() => void) | null = null;
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const initialBatch = makeBrowserMetadataOnlyFileBatch('open');

		function ControlledFileViewer(): ReactElement {
			const [isActive, setIsActive] = useState(true);
			deactivateFiles = (): void => {
				setIsActive(false);
			};
			return (
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={initialBatch}
					isActive={isActive}
					fileProductSession={{
						readContent: (props) => {
							openedDescriptorIds.push(props.descriptor.descriptorId);
							return Promise.resolve(
								makeFileContent('export const visibleAfterReactivate = true;\n'),
							);
						},
						onFileScopeChange: (request) => {
							metadataInterestUpdates.push(request);
						},
						onFileBatchPublisher: (handler): (() => void) => {
							publishMetadataEvents = handler;
							return (): void => {
								publishMetadataEvents = null;
							};
						},
					}}
				/>
			);
		}

		await render(
			<div style={{ height: '720px', overflow: 'hidden', width: '1280px' }}>
				<ControlledFileViewer />
			</div>,
		);
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		await waitForBridgeViewerTreeItemButton('Sources/AgentStudio/App/AppDelegate.swift');
		await actUpdate((): void => {
			window.dispatchEvent(
				new CustomEvent('bridge-worktree-file-recently-updated', {
					detail: {
						path: 'Sources/AgentStudio/App/AppDelegate.swift',
						proximity: 'nearby',
						sourceIdentity: 'dev-worktree-source',
					},
				}),
			);
		});
		await waitForBridgeFileViewerWorkerMessageDrain();
		await waitForMetadataInterestUpdateCount({
			expectedCount: 1,
			metadataInterestUpdates: metadataInterestUpdates,
		});
		await actUpdate(requireDeactivateFiles(deactivateFiles));
		await waitForFileViewerActiveState('false');
		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishMetadataEvents)(
				replaceBrowserFileBatchRows({
					snapshotCause: 'newerInput',
					previous: initialBatch,
					upserts: [
						makeBrowserFileRow({ path: firstDescriptor.path, descriptorOutcome: firstDescriptor }),
					],
					revision: 2,
				}),
			);
		});
		await waitForBridgeFileViewerWorkerMessageDrain();

		await actFrame();
		await actFrame();
		await actFrame();
		await waitForBridgeFileViewerWorkerMessageDrain();

		expect(openedDescriptorIds).toEqual([]);
	});
});

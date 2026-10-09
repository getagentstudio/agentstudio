import { useState, type ReactElement } from 'react';
import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the app CSS.
import '../app/bridge-app.css';
import {
	requireBridgeViewerHTMLElement,
	waitForBridgeViewerAnimationFrame,
	waitForBridgeViewerTreeItemButton,
} from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import { terminateBridgePierreWorkerPoolSingletonForTest } from '../review-viewer/workers/pierre/bridge-pierre-worker-pool.js';
import { BridgeFileViewerBrowserHarnessApp as BridgeFileViewerApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatch,
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcomeForContent,
	makeBrowserFileRow,
	makeBrowserMetadataOnlyFileBatch,
	replaceBrowserFileBatchRows,
	type BrowserFileViewScope,
	type PublishBrowserFileBatch,
} from './bridge-file-viewer-browser-test-batches.js';
import { makeFileContent } from './bridge-file-viewer-browser-test-fixtures.js';
import {
	fileNavigationCommandForPath,
	type FileNavigationCommand,
} from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actClick,
	actFrame,
	actUpdate,
	fileCanvasRenderedTextOffset,
	makeDeferredContent,
	makeGeneratedFileBody,
	metadataInterestPathsForLane,
	openFileBodyPreview,
	openFilePath,
	renderedFilePath,
	requireBrowserFileBatchPublisher,
	requireOpenSlowFile,
	settleBridgeFileViewerBrowserInteraction,
	settleBridgeFileViewerBrowserUpdates,
	selectedDisplayPath,
	visibleCodeText,
	waitForMetadataInterestUpdateCount,
	waitForFileCodeViewScrollable,
	waitForFileCodeViewScrollOwner,
	waitForFileCodeViewViewport,
	waitForOpenFileBodyPreview,
	waitForOpenFileState,
	waitForOpenedContentCount,
	waitForSelectedDisplayPath,
	waitForVisibleCodeText,
} from './bridge-file-viewer-browser-test-harness.js';

describe('BridgeFileViewerApp Browser Mode', () => {
	afterEach(async () => {
		await actUpdate(async (): Promise<void> => {
			await cleanup();
		});
		await settleBridgeFileViewerBrowserUpdates();
		await actFrame();
		document.body.replaceChildren();
		terminateBridgePierreWorkerPoolSingletonForTest();
	});

	test('advances selected path immediately while metadata-only content converges', async () => {
		const initiallyOpenContent = makeFileContent('export const initiallyOpen = true;\n');
		const clickedContent = makeFileContent('export const clickedSelection = true;\n');
		const initiallyOpenDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: initiallyOpenContent,
			contentHandle: 'initial-content',
			fileId: 'file-000',
			path: 'File-000.swift',
		});
		const clickedDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: clickedContent,
			contentHandle: 'clicked-content',
			fileId: 'file-001',
			path: 'File-001.swift',
		});
		const metadataInterestUpdates: BrowserFileViewScope[] = [];
		const openedDescriptorIds: string[] = [];
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const initialBatch = makeBrowserFileBatchWithDescriptors('open', initiallyOpenDescriptor);
		const clickedMetadataBatch = replaceBrowserFileBatchRows({
			snapshotCause: 'newerInput',
			previous: initialBatch,
			upserts: [makeBrowserFileRow({ path: 'File-001.swift', fileId: 'file-001' })],
			revision: 2,
		});
		const selectedMetadataBatch = replaceBrowserFileBatchRows({
			snapshotCause: 'newerInput',
			previous: clickedMetadataBatch,
			upserts: [makeBrowserFileRow({ path: 'File-002.swift' })],
			revision: 3,
		});

		await render(
			<BridgeFileViewerApp
				autoOpenInitialFile
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={initialBatch}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return props.descriptor.descriptorId.includes('clicked-content')
							? clickedContent
							: initiallyOpenContent;
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
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('initiallyOpen');

		const publishRequiredMetadataEvents = requireBrowserFileBatchPublisher(publishMetadataEvents);
		await actUpdate((): void => {
			publishRequiredMetadataEvents(clickedMetadataBatch);
		});
		const clickedButton = await waitForBridgeViewerTreeItemButton('File-001.swift');
		await actClick(clickedButton);
		await waitForMetadataInterestUpdateCount({
			expectedCount: 1,
			metadataInterestUpdates: metadataInterestUpdates,
		});

		await actUpdate((): void => {
			publishRequiredMetadataEvents(selectedMetadataBatch);
		});
		await actFrame();
		await actFrame();
		expect(selectedDisplayPath()).toBe('File-001.swift');
		expect(openFilePath()).toBe('File-001.swift');
		expect(renderedFilePath()).toBeNull();
		expect(openFileBodyPreview()).toBeNull();
		expect(visibleCodeText()).not.toContain('export const initiallyOpen = true;');

		await actUpdate((): void => {
			publishRequiredMetadataEvents(
				replaceBrowserFileBatchRows({
					snapshotCause: 'newerInput',
					previous: selectedMetadataBatch,
					upserts: [
						makeBrowserFileRow({
							path: clickedDescriptor.path,
							descriptorOutcome: clickedDescriptor,
						}),
					],
					revision: 4,
				}),
			);
		});
		await waitForOpenFileState('ready');
		await waitForSelectedDisplayPath('File-001.swift');
		await waitForVisibleCodeText('clickedSelection');

		const finalInterestUpdate = metadataInterestUpdates.at(-1);
		if (finalInterestUpdate === undefined)
			throw new Error('Expected final File metadata interest.');
		expect(metadataInterestPathsForLane(finalInterestUpdate, 'foreground')).toEqual([
			'File-001.swift',
		]);
		expect(finalInterestUpdate?.pathScope).toEqual([]);
		expect(openedDescriptorIds).toContain('clicked-content');
	});

	test('keeps one foreground interest for a selected metadata-only descriptor until it converges', async () => {
		const initiallyOpenContent = makeFileContent('export const initiallyOpen = true;\n');
		const initiallyOpenDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: initiallyOpenContent,
			contentHandle: 'initial-content',
			fileId: 'file-000',
			path: 'File-000.swift',
		});
		const metadataInterestUpdates: BrowserFileViewScope[] = [];
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const initialBatch = makeBrowserFileBatchWithDescriptors('open', initiallyOpenDescriptor);

		await render(
			<BridgeFileViewerApp
				autoOpenInitialFile
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={initialBatch}
				fileProductSession={{
					readContent: async () => initiallyOpenContent,
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
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('initiallyOpen');
		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishMetadataEvents)(
				replaceBrowserFileBatchRows({
					snapshotCause: 'newerInput',
					previous: initialBatch,
					upserts: [makeBrowserFileRow({ path: 'File-001.swift', fileId: 'file-001' })],
					revision: 2,
				}),
			);
		});

		const clickedButton = await waitForBridgeViewerTreeItemButton('File-001.swift');
		const updateCountBeforeClick = metadataInterestUpdates.length;
		await actClick(clickedButton);
		await waitForMetadataInterestUpdateCount({
			expectedCount: updateCountBeforeClick + 1,
			metadataInterestUpdates: metadataInterestUpdates,
		});
		await waitForSelectedDisplayPath('File-001.swift');
		await settleBridgeFileViewerBrowserInteraction();
		const settledUpdateCountAfterFirstSelection = metadataInterestUpdates.length;
		await actClick(clickedButton);
		await settleBridgeFileViewerBrowserInteraction();

		expect(metadataInterestUpdates).toHaveLength(settledUpdateCountAfterFirstSelection);
		const selectedInterestUpdate = metadataInterestUpdates.at(-1);
		if (selectedInterestUpdate === undefined) {
			throw new Error('Expected selected File metadata interest.');
		}
		expect(metadataInterestPathsForLane(selectedInterestUpdate, 'foreground')).toEqual([
			'File-001.swift',
		]);
		expect(selectedInterestUpdate?.pathScope).toEqual([]);
	});

	test('auto-opens the first metadata-only file row by requesting its descriptor', async () => {
		const content = makeFileContent('export const autoOpenedMetadataRow = true;\n');
		const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content,
			contentHandle: 'app-delegate-content',
			fileId: 'file-app-delegate',
			path: 'Sources/AgentStudio/App/AppDelegate.swift',
		});
		const metadataInterestUpdates: BrowserFileViewScope[] = [];
		const openedDescriptorIds: string[] = [];
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const initialBatch = makeBrowserMetadataOnlyFileBatch('open');

		await render(
			<BridgeFileViewerApp
				autoOpenInitialFile
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={initialBatch}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return content;
					},
					onFileScopeChange: async (request) => {
						metadataInterestUpdates.push(request);
						const publishRequiredMetadataEvents =
							requireBrowserFileBatchPublisher(publishMetadataEvents);
						await actUpdate((): void => {
							publishRequiredMetadataEvents(
								replaceBrowserFileBatchRows({
									snapshotCause: 'newerInput',
									previous: initialBatch,
									upserts: [
										makeBrowserFileRow({ path: descriptor.path, descriptorOutcome: descriptor }),
									],
									revision: 2,
								}),
							);
						});
					},
					onFileBatchPublisher: (handler): (() => void) => {
						publishMetadataEvents = handler;
						return (): void => {
							publishMetadataEvents = null;
						};
					},
				}}
			/>,
		);

		await waitForMetadataInterestUpdateCount({
			expectedCount: 1,
			metadataInterestUpdates: metadataInterestUpdates,
		});
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('autoOpenedMetadataRow');

		expect(metadataInterestUpdates.at(-1)).toMatchObject({
			interests: [{ lane: 'foreground', paths: ['Sources/AgentStudio/App/AppDelegate.swift'] }],
			pathScope: [],
		});
		expect(openedDescriptorIds).toEqual(['app-delegate-content']);
	});

	test('opens a file navigation target in the browser without auto-opening the first descriptor', async () => {
		const firstContent = makeFileContent('export const first = true;\n');
		const targetContent = makeFileContent('export const target = true;\n');
		const firstDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: firstContent,
			contentHandle: 'first-content',
			fileId: 'file-first',
			path: 'src/first.ts',
		});
		const targetDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: targetContent,
			contentHandle: 'target-content',
			fileId: 'file-target',
			path: 'docs/target.ts',
		});
		const openedDescriptorIds: string[] = [];

		await render(
			<BridgeFileViewerApp
				autoOpenInitialFile={true}
				initialFileBatch={makeBrowserFileBatchWithDescriptors(
					'open',
					firstDescriptor,
					targetDescriptor,
				)}
				navigationCommand={fileNavigationCommandForPath('docs/target.ts')}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return props.descriptor.descriptorId.includes('target-content')
							? targetContent
							: firstContent;
					},
				}}
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('target = true');

		expect(openFilePath()).toBe('docs/target.ts');
		const shell = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		);
		expect(shell.getAttribute('data-last-open-load-disposition')).toBeNull();
		expect(openedDescriptorIds).toEqual(['target-content']);
	});

	test('requests a metadata-only navigation target descriptor on the foreground lane', async () => {
		const content = makeFileContent('export const navigationTargetFromMetadata = true;\n');
		const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content,
			contentHandle: 'app-delegate-navigation-content',
			fileId: 'file-app-delegate',
			path: 'Sources/AgentStudio/App/AppDelegate.swift',
		});
		const metadataInterestUpdates: BrowserFileViewScope[] = [];
		const openedDescriptorIds: string[] = [];
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const initialBatch = makeBrowserMetadataOnlyFileBatch('open');

		await render(
			<BridgeFileViewerApp
				autoOpenInitialFile={true}
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={initialBatch}
				navigationCommand={fileNavigationCommandForPath(
					'Sources/AgentStudio/App/AppDelegate.swift',
				)}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return content;
					},
					onFileScopeChange: async (request) => {
						metadataInterestUpdates.push(request);
						await actUpdate((): void => {
							requireBrowserFileBatchPublisher(publishMetadataEvents)(
								replaceBrowserFileBatchRows({
									snapshotCause: 'newerInput',
									previous: initialBatch,
									upserts: [
										makeBrowserFileRow({ path: descriptor.path, descriptorOutcome: descriptor }),
									],
									revision: 2,
								}),
							);
						});
					},
					onFileBatchPublisher: (handler): (() => void) => {
						publishMetadataEvents = handler;
						return (): void => {
							publishMetadataEvents = null;
						};
					},
				}}
			/>,
		);

		await waitForMetadataInterestUpdateCount({
			expectedCount: 1,
			metadataInterestUpdates: metadataInterestUpdates,
		});
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('navigationTargetFromMetadata');

		expect(metadataInterestUpdates.at(-1)).toMatchObject({
			interests: [{ lane: 'foreground', paths: ['Sources/AgentStudio/App/AppDelegate.swift'] }],
			pathScope: [],
		});
		expect(openedDescriptorIds).toEqual(['app-delegate-navigation-content']);
		expect(openFilePath()).toBe('Sources/AgentStudio/App/AppDelegate.swift');
	});

	test('auto-opens the first descriptor when native metadata streams after the initial snapshot', async () => {
		const content = makeFileContent('export const streamed = true;\n');
		const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content,
			contentHandle: 'streamed-content',
			fileId: 'file-streamed',
			path: 'src/streamed.ts',
		});
		const initialBatch = makeBrowserFileBatch({ snapshotCause: 'open', rows: [] });
		const streamedBatch = makeBrowserFileBatch({
			snapshotCause: 'open',
			rows: [makeBrowserFileRow({ path: descriptor.path, descriptorOutcome: descriptor })],
			revision: 2,
		});
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const openedDescriptorIds: string[] = [];

		await render(
			<BridgeFileViewerApp
				autoOpenInitialFile={true}
				initialFileBatch={initialBatch}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return content;
					},
					onFileBatchPublisher: (handler): (() => void) => {
						publishMetadataEvents = handler;
						return (): void => {
							publishMetadataEvents = null;
						};
					},
				}}
			/>,
		);

		await actFrame();
		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishMetadataEvents)(streamedBatch);
		});

		await waitForOpenFileState('ready');

		expect(openFilePath()).toBe('src/streamed.ts');
		expect(openedDescriptorIds).toEqual(['streamed-content']);
	});

	test('renders file body without Pierre file header chrome inside the File canvas', async () => {
		const content = makeFileContent('export const plain = true;\n');
		const targetDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content,
			contentHandle: 'plain-content',
			fileId: 'file-plain',
			path: 'src/plain.ts',
		});

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', targetDescriptor)}
				navigationCommand={fileNavigationCommandForPath('src/plain.ts')}
				fileProductSession={{
					readContent: async () => content,
				}}
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const plain = true;');

		expect(fileCanvasRenderedTextOffset('export const plain')).not.toBeNull();
		expect(fileCanvasRenderedTextOffset('export const plain')).toBeLessThanOrEqual(4);
	});

	test('keeps the File CodeView viewport mounted after a warmed shell while selected file content loads', async () => {
		const warmContent = makeFileContent('export const warm = true;\n');
		const warmDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: warmContent,
			contentHandle: 'warm-content',
			fileId: 'file-warm',
			path: 'src/warm.ts',
		});
		await render(
			<BridgeFileViewerApp
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', warmDescriptor)}
				fileProductSession={{
					readContent: async () => warmContent,
				}}
			/>,
		);
		await waitForFileCodeViewViewport();
		await actUpdate(async (): Promise<void> => {
			await cleanup();
		});
		await actFrame();

		const slowContent = makeFileContent('export const slow = true;\n');
		const targetDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: slowContent,
			contentHandle: 'slow-content',
			fileId: 'file-slow',
			path: 'src/slow.ts',
		});
		const deferredContent = makeDeferredContent();
		const openedDescriptorIds: string[] = [];
		let currentSourceSettled = false;
		let openSlowFile: (() => void) | null = null;

		function ControlledFileViewer(): ReactElement {
			const [navigationCommand, setNavigationCommand] = useState<
				FileNavigationCommand | undefined
			>();
			openSlowFile = (): void => {
				setNavigationCommand(fileNavigationCommandForPath('src/slow.ts'));
			};
			return (
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', targetDescriptor)}
					{...(navigationCommand === undefined ? {} : { navigationCommand })}
					fileProductSession={{
						currentSource: async () => {
							await waitForBridgeViewerAnimationFrame();
							currentSourceSettled = true;
							return {
								status: 'available',
								source: {
									cwdScope: null,
									freshness: 'live',
									includeStatuses: true,
									repoId: '00000000-0000-4000-8000-000000000001',
									rootPathToken: 'browser-test-root',
									worktreeId: '00000000-0000-4000-8000-000000000002',
								},
							};
						},
						readContent: (props) => {
							openedDescriptorIds.push(props.descriptor.descriptorId);
							return deferredContent.promise;
						},
					}}
				/>
			);
		}

		await render(<ControlledFileViewer />);

		const idleViewport = await waitForFileCodeViewViewport();
		expect(currentSourceSettled).toBe(true);
		const openRequiredSlowFile = requireOpenSlowFile(openSlowFile);
		await actUpdate(openRequiredSlowFile);
		await waitForOpenFileState('loading');
		await waitForOpenedContentCount({
			expectedCount: 1,
			openedDescriptorIds: openedDescriptorIds,
		});
		expect(document.querySelector('[data-testid="bridge-file-viewer-code-view"]')).toBe(
			idleViewport,
		);
		expect(openedDescriptorIds).toContain('slow-content');
		expect(
			document
				.querySelector('[data-bridge-region="file-content"]')
				?.getAttribute('data-presentation-state'),
		).toBe('loading');
		expect(
			document.querySelector('[data-bridge-region="file-content"] [data-slot="skeleton"]'),
		).not.toBeNull();
		expect(document.querySelectorAll('diffs-container')).toHaveLength(0);

		await actUpdate((): void => {
			deferredContent.resolve(slowContent);
		});
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const slow = true;');
		expect(document.querySelector('[data-testid="bridge-file-viewer-code-view"]')).toBe(
			idleViewport,
		);
	});

	test('does not fabricate selected file scroll extent from metadata while content loads', async () => {
		const loadingContent = makeFileContent(`${makeGeneratedFileBody('largeLoading', 160)}\n`);
		const targetDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: loadingContent,
			contentHandle: 'large-loading-content',
			fileId: 'file-large-loading',
			path: 'src/large-loading.ts',
		});
		const deferredContent = makeDeferredContent();

		await render(
			<div style={{ display: 'grid', height: '360px', overflow: 'hidden', width: '960px' }}>
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', targetDescriptor)}
					navigationCommand={fileNavigationCommandForPath('src/large-loading.ts')}
					fileProductSession={{
						readContent: () => deferredContent.promise,
					}}
				/>
			</div>,
		);

		await waitForOpenFileState('loading');
		const scrollOwner = await waitForFileCodeViewScrollOwner();

		expect(scrollOwner.scrollHeight).toBeLessThanOrEqual(scrollOwner.clientHeight + 32);
		expect(document.querySelectorAll('diffs-container')).toHaveLength(0);
		expect(
			document
				.querySelector('[data-bridge-region="file-content"]')
				?.getAttribute('data-presentation-state'),
		).toBe('loading');
		expect(
			document.querySelector('[data-bridge-region="file-content"] [data-slot="skeleton"]'),
		).not.toBeNull();

		await actUpdate((): void => {
			deferredContent.resolve(loadingContent);
		});
	});

	test('keeps the viewport mounted without rendering the previous file while the next file loads', async () => {
		const firstContent = makeFileContent('export const firstRetained = true;\n');
		const secondContent = makeFileContent('export const secondSlow = true;\n');
		const firstDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: firstContent,
			contentHandle: 'first-retained-content',
			fileId: 'file-first-retained',
			path: 'src/first-retained.ts',
		});
		const secondDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: secondContent,
			contentHandle: 'second-slow-content',
			fileId: 'file-second-slow',
			path: 'src/second-slow.ts',
		});
		const deferredSecondContent = makeDeferredContent();
		let openSecondFile: (() => void) | null = null;

		function ControlledFileViewer(): ReactElement {
			const [navigationCommand, setNavigationCommand] = useState<FileNavigationCommand>(
				fileNavigationCommandForPath('src/first-retained.ts'),
			);
			openSecondFile = (): void => {
				setNavigationCommand(fileNavigationCommandForPath('src/second-slow.ts'));
			};
			return (
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors(
						'open',
						firstDescriptor,
						secondDescriptor,
					)}
					navigationCommand={navigationCommand}
					fileProductSession={{
						readContent: (props) =>
							props.descriptor.descriptorId.includes('second-slow-content')
								? deferredSecondContent.promise
								: Promise.resolve(firstContent),
					}}
				/>
			);
		}

		await render(
			<div style={{ height: '360px', width: '960px' }}>
				<ControlledFileViewer />
			</div>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const firstRetained = true;');
		const readyViewport = await waitForFileCodeViewViewport();
		const openRequiredSecondFile = requireOpenSlowFile(openSecondFile);
		await actUpdate(openRequiredSecondFile);

		await waitForOpenFileState('loading');

		expect(document.querySelector('[data-testid="bridge-file-viewer-code-view"]')).toBe(
			readyViewport,
		);
		expect(visibleCodeText()).not.toContain('export const firstRetained = true;');
		expect(openFileBodyPreview()).toBeNull();

		await actUpdate((): void => {
			deferredSecondContent.resolve(secondContent);
		});
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const secondSlow = true;');

		expect(document.querySelector('[data-testid="bridge-file-viewer-code-view"]')).toBe(
			readyViewport,
		);
		expect(visibleCodeText()).not.toContain('export const firstRetained = true;');
	});

	test('shows honest loading state without retained content or fabricated scroll extent', async () => {
		const firstContent = makeFileContent(`${makeGeneratedFileBody('firstRetainedScroll', 8)}\n`);
		const secondContent = makeFileContent(
			`${makeGeneratedFileBody('secondLargeRetainedTarget', 575)}\n`,
		);
		const firstDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: firstContent,
			contentHandle: 'first-retained-scroll-content',
			fileId: 'file-first-retained-scroll',
			path: 'src/first-retained-scroll.ts',
		});
		const secondDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: secondContent,
			contentHandle: 'second-large-retained-target-content',
			fileId: 'file-second-large-retained-target',
			path: 'src/second-large-retained-target.ts',
		});
		const deferredSecondContent = makeDeferredContent();
		let openSecondFile: (() => void) | null = null;

		function ControlledFileViewer(): ReactElement {
			const [navigationCommand, setNavigationCommand] = useState<FileNavigationCommand>(
				fileNavigationCommandForPath('src/first-retained-scroll.ts'),
			);
			openSecondFile = (): void => {
				setNavigationCommand(fileNavigationCommandForPath('src/second-large-retained-target.ts'));
			};
			return (
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors(
						'open',
						firstDescriptor,
						secondDescriptor,
					)}
					navigationCommand={navigationCommand}
					fileProductSession={{
						readContent: (props) =>
							props.descriptor.descriptorId.includes('second-large-retained-target-content')
								? deferredSecondContent.promise
								: Promise.resolve(firstContent),
					}}
				/>
			);
		}

		await render(
			<div style={{ display: 'grid', height: '360px', overflow: 'hidden', width: '960px' }}>
				<ControlledFileViewer />
			</div>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const firstRetainedScrollLine001 = true;');
		const scrollOwner = await waitForFileCodeViewScrollOwner();
		const openRequiredSecondFile = requireOpenSlowFile(openSecondFile);
		await actUpdate(openRequiredSecondFile);

		await waitForOpenFileState('loading');

		expect(visibleCodeText()).not.toContain('export const firstRetainedScrollLine001 = true;');
		expect(scrollOwner.scrollHeight).toBeLessThanOrEqual(scrollOwner.clientHeight + 32);
		expect(document.querySelectorAll('diffs-container')).toHaveLength(0);
		expect(
			document
				.querySelector('[data-bridge-region="file-content"]')
				?.getAttribute('data-presentation-state'),
		).toBe('loading');
		expect(
			document.querySelector('[data-bridge-region="file-content"] [data-slot="skeleton"]'),
		).not.toBeNull();

		await actUpdate((): void => {
			deferredSecondContent.resolve(secondContent);
		});
		await waitForOpenFileState('ready');
		await waitForOpenFileBodyPreview('export const secondLargeRetainedTargetLine001 = true;');
		await actFrame();

		expect(scrollOwner.scrollHeight).toBeGreaterThan(scrollOwner.clientHeight + 32);
	});

	test('does not render retained file body while the next selected file content loads', async () => {
		const firstContent = makeFileContent(makeGeneratedFileBody('firstScrolled', 120));
		const secondContent = makeFileContent('export const secondScrollTarget = true;\n');
		const firstDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: firstContent,
			contentHandle: 'first-scrolled-content',
			fileId: 'file-first-scrolled',
			path: 'src/first-scrolled.ts',
		});
		const secondDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: secondContent,
			contentHandle: 'second-scroll-target-content',
			fileId: 'file-second-scroll-target',
			path: 'src/second-scroll-target.ts',
		});
		const deferredSecondContent = makeDeferredContent();
		let openSecondFile: (() => void) | null = null;

		function ControlledFileViewer(): ReactElement {
			const [navigationCommand, setNavigationCommand] = useState<FileNavigationCommand>(
				fileNavigationCommandForPath('src/first-scrolled.ts'),
			);
			openSecondFile = (): void => {
				setNavigationCommand(fileNavigationCommandForPath('src/second-scroll-target.ts'));
			};
			return (
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors(
						'open',
						firstDescriptor,
						secondDescriptor,
					)}
					navigationCommand={navigationCommand}
					fileProductSession={{
						readContent: (props) =>
							props.descriptor.descriptorId.includes('second-scroll-target-content')
								? deferredSecondContent.promise
								: Promise.resolve(firstContent),
					}}
				/>
			);
		}

		await render(
			<div style={{ display: 'grid', height: '360px', overflow: 'hidden', width: '960px' }}>
				<ControlledFileViewer />
			</div>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const firstScrolledLine001 = true;');
		const scrollOwner = await waitForFileCodeViewScrollOwner();
		await waitForFileCodeViewScrollable(scrollOwner);
		await actUpdate((): void => {
			scrollOwner.scrollTop = 320;
			scrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
		});
		expect(scrollOwner.scrollTop).toBeGreaterThan(0);

		const openRequiredSecondFile = requireOpenSlowFile(openSecondFile);
		await actUpdate(openRequiredSecondFile);
		await waitForOpenFileState('loading');
		await actFrame();
		await actFrame();

		expect(openFileBodyPreview()).toBeNull();

		await actUpdate((): void => {
			deferredSecondContent.resolve(secondContent);
		});
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('export const secondScrollTarget = true;');
		await actFrame();

		expect(scrollOwner.scrollTop).toBeLessThanOrEqual(1);
	});
});

import { act } from 'react';
import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

import type { BridgeTelemetrySample } from '../foundation/telemetry/bridge-telemetry-event.js';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the app CSS.
import '../app/bridge-app.css';
import {
	findBridgeViewerTreeScrollOwner,
	requireBridgeViewerHTMLElement,
	waitForBridgeViewerTreeItemButton,
} from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import { terminateBridgePierreWorkerPoolSingletonForTest } from '../review-viewer/workers/pierre/bridge-pierre-worker-pool.js';
import { registerFileSourceDiscoveryTest } from './bridge-file-viewer-app-startup-source.browser.test-support.js';
import {
	actInteractAndSettleFileViewerCheckedMenuOption,
	actClickAndSettleFileViewerMenu,
	type FileFilterActDiagnostic,
	recordFileFilterActDiagnostic,
	waitForFileViewerHTMLElement,
	waitForFileViewerMenuOptionContaining,
	waitForFileViewerTreeItemButtonInAct,
} from './bridge-file-viewer-app-startup.browser.test-support.js';
import { BridgeFileViewerBrowserHarnessApp as BridgeFileViewerApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatch,
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcome,
	makeBrowserFileDescriptorOutcomeForContent,
	makeBrowserFileRow,
	makeBrowserMetadataOnlyFileBatch,
	makeBrowserSequentialFileRows,
	replaceBrowserFileBatchRows,
	type BrowserFileViewScope,
	type PublishBrowserFileBatch,
} from './bridge-file-viewer-browser-test-batches.js';
import { makeFileContent } from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actClick,
	actFrame,
	actUpdate,
	interactAndWaitForBridgeFileViewerQueryCompletion,
	metadataInterestPathsForLane,
	makeBrowserFileBatchPublisherObservation,
	makeTestTelemetryRecorder,
	openFileBodyPreview,
	openFilePath,
	renderedFilePath,
	requireBrowserFileBatchPublisher,
	settleBridgeFileViewerBrowserUpdates,
	waitForBridgeFileViewerWorkerMessageDrain,
	selectedDisplayPath,
	waitForMetadataInterestUpdateCount,
	waitForMetadataTreeRowCount,
	waitForOpenFileState,
	waitForSelectedDisplayPath,
	waitForTelemetrySampleCount,
	waitForTreeScrollHeightAtLeast,
	waitForVisibleCodeText,
} from './bridge-file-viewer-browser-test-harness.js';

describe('BridgeFileViewerApp Browser Mode', () => {
	let fileFilterActDiagnostic: FileFilterActDiagnostic | null = null;

	afterEach(async () => {
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'local-teardown-before-settle');
		await settleBridgeFileViewerBrowserUpdates();
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'local-teardown-after-settle');
		await act(async (): Promise<void> => {
			recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'local-teardown-before-cleanup');
			await cleanup();
			await Promise.resolve();
		});
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'local-teardown-after-cleanup');
		await actFrame();
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'local-teardown-complete');
		fileFilterActDiagnostic = null;
		document.body.replaceChildren();
		terminateBridgePierreWorkerPoolSingletonForTest();
	});

	registerFileSourceDiscoveryTest();

	test('continues worker-owned metadata intake while File View is inactive', async () => {
		let publishMetadata: PublishBrowserFileBatch | null = null;
		const { rerender } = await render(
			<BridgeFileViewerApp
				isActive={true}
				fileProductSession={{
					onFileBatchPublisher: (publisher) => {
						publishMetadata = publisher;
					},
				}}
			/>,
		);
		await actFrame();
		await actFrame();
		await rerender(
			<BridgeFileViewerApp
				isActive={false}
				fileProductSession={{
					onFileBatchPublisher: (publisher) => {
						publishMetadata = publisher;
					},
				}}
			/>,
		);
		await actUpdate(() => {
			requireBrowserFileBatchPublisher(publishMetadata)(
				makeBrowserFileBatchWithDescriptors(
					'open',
					makeBrowserFileDescriptorOutcome({ path: 'src/app.ts' }),
				),
			);
		});
		await waitForMetadataTreeRowCount(2);
		expect(await waitForBridgeViewerTreeItemButton('src/app.ts')).not.toBeNull();
	});

	test('uses the shared compact rail chrome before opening tree search', async () => {
		await act(async (): Promise<void> => {
			await render(
				<BridgeFileViewerApp
					initialFileBatch={makeBrowserFileBatchWithDescriptors(
						'open',
						makeBrowserFileDescriptorOutcome({ path: 'src/app.ts' }),
						makeBrowserFileDescriptorOutcome({
							descriptorId: 'docs-content',
							fileId: 'file-docs',
							path: 'docs/readme.md',
						}),
					)}
				/>,
			);
		});
		await waitForFileViewerTreeItemButtonInAct({ path: 'src/app.ts' });

		const toolbar = await waitForFileViewerHTMLElement({
			selector: '[data-testid="bridge-file-viewer-rail-toolbar"]',
		});
		expect(toolbar.getAttribute('data-bridge-shared-rail-toolbar')).toBe('true');
		const leadingControls = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-rail-toolbar-leading"]'),
		);
		expect(leadingControls.getAttribute('role')).toBeNull();
		expect(leadingControls.getAttribute('aria-live')).toBeNull();
		const fileStatus = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="worktree-file-status"]'),
		);
		expect(fileStatus.getAttribute('role')).toBe('status');
		expect(fileStatus.getAttribute('aria-live')).toBe('polite');
		expect(
			document.querySelector('[data-testid="bridge-file-viewer-rail-toolbar-trailing"]'),
		).not.toBeNull();
		expect(document.querySelector('[data-testid="worktree-file-search-control"]')).not.toBeNull();
		expect(document.querySelector('[data-testid="worktree-file-search-toggle"]')).not.toBeNull();
		expect(document.querySelector('[data-testid="worktree-file-regex-toggle"]')).toBeNull();
		expect(document.querySelector('[data-testid="worktree-file-filter-menu"]')).not.toBeNull();
		expect(document.querySelector('[data-testid="worktree-file-search-input"]')).toBeNull();
		const filterMenu = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="worktree-file-filter-menu"]'),
		);
		const searchToggle = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="worktree-file-search-toggle"]'),
		);
		const filterGlyph = document.querySelector(
			'[data-testid="worktree-file-filter-menu-trigger-glyph"]',
		);
		if (!(filterGlyph instanceof SVGElement)) {
			throw new Error('Expected the File filter trigger SVG glyph.');
		}
		const filterBox = filterMenu.getBoundingClientRect();
		const searchBox = searchToggle.getBoundingClientRect();
		const filterGlyphBox = filterGlyph.getBoundingClientRect();
		const toolbarBox = toolbar.getBoundingClientRect();
		const trailingControls = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-rail-toolbar-trailing"]'),
		);
		const trailingControlsBox = trailingControls.getBoundingClientRect();
		for (const controlBox of [filterBox, searchBox]) {
			expect(Math.round(controlBox.width)).toBe(24);
			expect(Math.round(controlBox.height)).toBe(24);
			expect(Math.abs(controlBox.top - filterBox.top)).toBeLessThanOrEqual(1);
			expect(
				Math.abs(controlBox.y + controlBox.height / 2 - (filterBox.y + filterBox.height / 2)),
			).toBeLessThanOrEqual(1);
		}
		expect(Math.abs(searchBox.left - filterBox.right - 4)).toBeLessThanOrEqual(1);
		expect(filterBox.left).toBeLessThan(searchBox.left);
		expect(Math.abs(toolbarBox.right - trailingControlsBox.right - 8)).toBeLessThanOrEqual(1);
		expect(trailingControlsBox.left).toBeGreaterThan(toolbarBox.left + toolbarBox.width / 2);
		expect(Math.round(filterGlyphBox.width)).toBe(12);
		expect(Math.round(filterGlyphBox.height)).toBe(12);
		expect(filterGlyph.classList.contains('lucide-sliders-horizontal')).toBe(true);
		expect(getComputedStyle(searchToggle).fontSize).toBe('11px');
		const filterCount = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="worktree-file-filter-count"]'),
		);
		const sourceProvenance = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="worktree-file-provenance"]'),
		);
		expect(filterCount.getBoundingClientRect().width).toBeLessThanOrEqual(1);
		expect(filterCount.getBoundingClientRect().height).toBeLessThanOrEqual(1);
		expect(sourceProvenance.getBoundingClientRect().width).toBeLessThanOrEqual(1);
		expect(sourceProvenance.getBoundingClientRect().height).toBeLessThanOrEqual(1);

		await actClickAndSettleFileViewerMenu(filterMenu);
		const filterPopover = await waitForFileViewerHTMLElement({
			selector: '[data-testid="worktree-file-filter-menu-popover"]',
		});
		const filterOption = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="worktree-file-filter-menu-option"]'),
		);
		const filterClear = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="worktree-file-filter-menu-clear"]'),
		);
		expect(filterOption.offsetHeight).toBe(28);
		expect(filterClear.offsetHeight).toBe(28);
		expect(
			Math.abs(filterPopover.getBoundingClientRect().right - filterBox.right),
		).toBeLessThanOrEqual(1);
		await actClickAndSettleFileViewerMenu(filterMenu);

		await actClick(searchToggle);

		const searchInput = await waitForFileViewerHTMLElement({
			selector: '[data-testid="worktree-file-search-input"]',
		});
		if (!(searchInput instanceof HTMLInputElement)) {
			throw new Error('Expected the shared File search input.');
		}
		const regexToggle = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="worktree-file-regex-toggle"]'),
		);
		const searchField = requireBridgeViewerHTMLElement(
			document.querySelector('[data-bridge-viewer-search-field="true"]'),
		);
		await act(async (): Promise<void> => {
			searchInput.focus();
			searchInput.value = 'padding proof';
			searchInput.dispatchEvent(new Event('input', { bubbles: true }));
		});
		const searchIcon = document.querySelector('[data-bridge-viewer-search-icon="true"]');
		if (!(searchIcon instanceof SVGElement)) {
			throw new Error('Expected the shared search icon SVG.');
		}
		const clearButton = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="worktree-file-search-clear"]'),
		);
		const searchFieldBox = searchField.getBoundingClientRect();
		const searchIconBox = searchIcon.getBoundingClientRect();
		const inputBox = searchInput.getBoundingClientRect();
		const regexBox = regexToggle.getBoundingClientRect();
		const clearBox = clearButton.getBoundingClientRect();
		expect(Math.round(searchInput.getBoundingClientRect().height)).toBe(28);
		expect(Math.round(searchField.getBoundingClientRect().height)).toBe(28);
		expect(searchField.className).toContain('m-2');
		expect(searchField.className).not.toContain('mx-2');
		expect(searchField.className).not.toContain('mb-2');
		expect(Math.round(regexToggle.getBoundingClientRect().width)).toBe(20);
		expect(regexToggle.getBoundingClientRect().left).toBeGreaterThan(
			searchInput.getBoundingClientRect().left,
		);
		expect(regexToggle.getBoundingClientRect().right).toBeLessThanOrEqual(
			searchField.getBoundingClientRect().right,
		);
		expect(regexBox.right).toBeLessThan(clearBox.left);
		expect(Math.abs(searchFieldBox.right - clearBox.right - 6)).toBeLessThanOrEqual(1);
		expect(searchIconBox.left - searchFieldBox.left).toBeGreaterThanOrEqual(6);
		expect(inputBox.left - searchIconBox.right).toBeGreaterThanOrEqual(4);
		for (const controlBox of [searchIconBox, inputBox, regexBox, clearBox]) {
			expect(
				Math.abs(
					controlBox.y + controlBox.height / 2 - (searchFieldBox.y + searchFieldBox.height / 2),
				),
			).toBeLessThanOrEqual(1);
		}
		expect(getComputedStyle(searchInput).fontSize).toBe('12px');
		expect(getComputedStyle(searchInput).lineHeight).toBe('16px');
		expect(searchInput.getBoundingClientRect().left).toBeGreaterThanOrEqual(
			toolbar.getBoundingClientRect().left,
		);
		expect(searchInput.getBoundingClientRect().right).toBeLessThanOrEqual(
			toolbar.getBoundingClientRect().right,
		);
	});

	test('renders FileView rail in the shared resizable panel layout with stable geometry', async () => {
		await render(
			<div style={{ display: 'grid', height: '360px', overflow: 'hidden', width: '960px' }}>
				<BridgeFileViewerApp
					initialFileBatch={makeBrowserFileBatchWithDescriptors(
						'open',
						makeBrowserFileDescriptorOutcome({ path: 'src/app.ts' }),
						makeBrowserFileDescriptorOutcome({
							descriptorId: 'docs-content',
							fileId: 'file-docs',
							path: 'docs/readme.md',
						}),
					)}
				/>
			</div>,
		);

		await waitForMetadataTreeRowCount(4);
		await waitForFileViewerHTMLElement({ selector: '[data-slot="resizable-panel-group"]' });

		const layout = requireBridgeViewerHTMLElement(
			document.querySelector('[data-slot="resizable-panel-group"]'),
		);
		const contentPanel = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-content-panel"]'),
		);
		const resizeHandle = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-rail-resize-handle"]'),
		);
		const railPanel = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-resizable-rail"]'),
		);
		const treePanel = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-pierre-file-tree"]'),
		);

		const layoutBox = layout.getBoundingClientRect();
		const contentBox = contentPanel.getBoundingClientRect();
		const handleBox = resizeHandle.getBoundingClientRect();
		const railBox = railPanel.getBoundingClientRect();
		const treeBox = treePanel.getBoundingClientRect();
		const railWidthRatio = railBox.width / layoutBox.width;
		const appButton = await waitForFileViewerTreeItemButtonInAct({ path: 'src/app.ts' });
		const readmeButton = await waitForFileViewerTreeItemButtonInAct({ path: 'docs/readme.md' });

		expect(layout.getAttribute('data-panel-group-direction')).toBe('horizontal');
		expect(layoutBox.width).toBeGreaterThan(900);
		expect(contentBox.width).toBeGreaterThan(railBox.width);
		expect(handleBox.width).toBeGreaterThanOrEqual(1);
		expect(railBox.width).toBeGreaterThanOrEqual(240);
		expect(railBox.height).toBeGreaterThan(200);
		expect(treeBox.width).toBeGreaterThan(200);
		expect(treeBox.height).toBeGreaterThan(150);
		expect(appButton.getAttribute('data-item-path')).toBe('src/app.ts');
		expect(readmeButton.getAttribute('data-item-path')).toBe('docs/readme.md');
		const pierreTreeHost = treePanel.querySelector('file-tree-container');
		if (!(pierreTreeHost instanceof HTMLElement) || pierreTreeHost.shadowRoot === null) {
			throw new Error('Expected the real File Pierre tree host with an open shadow root.');
		}
		const renderedTreeRow = pierreTreeHost.shadowRoot.querySelector(
			'button[data-item-path="src/app.ts"]',
		);
		if (!(renderedTreeRow instanceof HTMLButtonElement)) {
			throw new Error('Expected the real rendered File Pierre tree row.');
		}
		expect(pierreTreeHost.style.getPropertyValue('--trees-density-override')).toBe('0.8');
		expect(
			getComputedStyle(pierreTreeHost).getPropertyValue('--trees-density-override').trim(),
		).toBe('0.8');
		expect(pierreTreeHost.style.getPropertyValue('--trees-item-height')).toBe('24px');
		expect(Math.round(renderedTreeRow.getBoundingClientRect().height)).toBe(24);
		expect(railWidthRatio).toBeGreaterThan(0.24);
		expect(railWidthRatio).toBeLessThan(0.32);
	});

	test('renders streamed metadata tree rows before file descriptors arrive', async () => {
		const openedDescriptorIds: string[] = [];

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserMetadataOnlyFileBatch('open')}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return makeFileContent('should not be requested\n');
					},
				}}
			/>,
		);

		await waitForBridgeViewerTreeItemButton('Sources/AgentStudio/App/AppDelegate.swift');

		const shell = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		);
		const tree = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-pierre-file-tree"]'),
		);
		expect(shell.getAttribute('data-last-demand-dispatch-status')).toBeNull();
		expect(tree.getAttribute('data-worktree-tree-total-size-source')).toBe('localProjection');
		expect(openedDescriptorIds).toEqual([]);
		await actFrame();
	});

	test('filters metadata-only rows by native file class before descriptor metadata arrives', async () => {
		fileFilterActDiagnostic = {
			oldCheckedIndicator: null,
			selectedOption: null,
		};
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'test-before-render');
		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserMetadataOnlyFileBatch('open')}
			/>,
		);
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'test-after-render');

		await waitForFileViewerTreeItemButtonInAct({
			path: 'Sources/AgentStudio/App/AppDelegate.swift',
		});
		expect(
			document.querySelector(
				'[data-worktree-file-path="Sources/AgentStudio/App/AppDelegate.swift"]',
			),
		).toBeNull();
		const filterMenuTrigger = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="worktree-file-filter-menu"]'),
		);
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'test-before-menu-open');
		await actClickAndSettleFileViewerMenu(filterMenuTrigger);
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'test-after-menu-open');
		const sourceFilterOption = await waitForFileViewerMenuOptionContaining({ text: 'Source' });
		fileFilterActDiagnostic.selectedOption = sourceFilterOption;
		fileFilterActDiagnostic.oldCheckedIndicator = document.querySelector(
			'[data-testid="worktree-file-filter-menu-option"][aria-checked="true"] [data-checked]',
		);
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'test-before-source-interaction');
		await actInteractAndSettleFileViewerCheckedMenuOption({
			interaction: async (): Promise<void> => {
				recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'test-before-source-click');
				await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
					sourceFilterOption.click();
				});
				recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'test-after-query-completion');
			},
			onDiagnosticPhase: (phase): void => {
				recordFileFilterActDiagnostic(fileFilterActDiagnostic, `helper-${phase}`);
			},
			option: sourceFilterOption,
		});
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'test-after-checked-helper');
		await waitForFileFilterCount('1/6');
		await waitForFileViewerTreeItemButtonInAct({
			path: 'Sources/AgentStudio/App/AppDelegate.swift',
		});
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'test-before-final-assertions');

		expect(
			document.querySelector(
				'[data-worktree-file-path="Sources/AgentStudio/App/AppDelegate.swift"]',
			),
		).toBeNull();
		expect(fileFilterCount()).toBe('1/6');
		recordFileFilterActDiagnostic(fileFilterActDiagnostic, 'test-after-final-assertions');
	});

	test('keeps the requested path selected while metadata interest reconciliation retries', async () => {
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
					onFileScopeChange: async (request) => {
						metadataInterestUpdates.push(request);
						throw new Error('descriptor request failed');
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
		await actClick(clickedButton);

		await waitForMetadataInterestUpdateCount({
			expectedCount: 1,
			metadataInterestUpdates: metadataInterestUpdates,
		});
		await waitForSelectedDisplayPath('File-001.swift');
		await waitForBridgeFileViewerWorkerMessageDrain();
		expect(openFilePath()).toBe('File-001.swift');
		expect(renderedFilePath()).toBeNull();
		expect(openFileBodyPreview()).toBeNull();
	});

	test('applies a larger certified tree snapshot after startup', async () => {
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const initialBatch = makeBrowserFileBatch({
			snapshotCause: 'open',
			rows: makeBrowserSequentialFileRows({ count: 200 }),
		});

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={initialBatch}
				fileProductSession={{
					onFileBatchPublisher: (handler): (() => void) => {
						publishMetadataEvents = handler;
						return (): void => {
							publishMetadataEvents = null;
						};
					},
				}}
			/>,
		);

		await waitForMetadataTreeRowCount(200);
		await waitForTreeScrollHeightAtLeast(200 * 24);
		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishMetadataEvents)(
				replaceBrowserFileBatchRows({
					snapshotCause: 'newerInput',
					previous: initialBatch,
					upserts: makeBrowserSequentialFileRows({ count: 60, startIndex: 200 }),
					revision: 2,
				}),
			);
		});

		await waitForMetadataTreeRowCount(260);
		await waitForTreeScrollHeightAtLeast(260 * 24);
		await waitForBridgeFileViewerWorkerMessageDrain();
		await actFrame();
		await actFrame();
		const shell = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		);
		const tree = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-pierre-file-tree"]'),
		);
		expect(shell.getAttribute('data-worktree-metadata-file-row-count')).toBe('0');
		expect(shell.getAttribute('data-worktree-metadata-tree-row-count')).toBe('260');
		expect(tree.getAttribute('data-worktree-tree-total-size-source')).toBe('localProjection');
	});

	test('applies subscribed tree delta updates to the visible FileView tree', async () => {
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const initialBatch = makeBrowserMetadataOnlyFileBatch('open');

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={initialBatch}
				fileProductSession={{
					onFileBatchPublisher: (handler): (() => void) => {
						publishMetadataEvents = handler;
						return (): void => {
							publishMetadataEvents = null;
						};
					},
				}}
			/>,
		);

		await waitForMetadataTreeRowCount(6);
		await waitForBridgeViewerTreeItemButton('Sources/AgentStudio/App/AppDelegate.swift');
		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishMetadataEvents)(
				replaceBrowserFileBatchRows({
					snapshotCause: 'newerInput',
					previous: initialBatch,
					deletedPaths: ['Sources/AgentStudio/App/AppDelegate.swift'],
					upserts: [
						makeBrowserFileRow({
							path: 'Sources/AgentStudio/Features/Bridge/BridgeRuntime.swift',
							fileId: 'file-bridge-runtime',
							lineCount: 64,
						}),
					],
					revision: 2,
				}),
			);
		});

		await waitForMetadataTreeRowCount(6);
		await waitForBridgeViewerTreeItemButton(
			'Sources/AgentStudio/Features/Bridge/BridgeRuntime.swift',
		);
		expect(
			document.querySelector(
				'[data-worktree-file-path="Sources/AgentStudio/App/AppDelegate.swift"]',
			),
		).toBeNull();
	});

	test('opens content for a file discovered through a subscribed tree window', async () => {
		const initialContent = makeFileContent('export const initialWindowSelection = true;\n');
		const continuedContent = makeFileContent('export const continuedWindowSelection = true;\n');
		const initialDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: initialContent,
			contentHandle: 'initial-window-content',
			fileId: 'file-000',
			path: 'File-000.swift',
		});
		const continuedDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: continuedContent,
			contentHandle: 'continued-window-content',
			fileId: 'file-250',
			path: 'File-250.swift',
		});
		const metadataInterestUpdates: BrowserFileViewScope[] = [];
		const openedDescriptorIds: string[] = [];
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const initialBatch = makeBrowserFileBatch({
			snapshotCause: 'open',
			rows: makeBrowserSequentialFileRows({ count: 200 }).map((row) =>
				row.displayKey === initialDescriptor.path
					? makeBrowserFileRow({
							path: initialDescriptor.path,
							descriptorOutcome: initialDescriptor,
						})
					: row,
			),
		});
		const continuedBatch = replaceBrowserFileBatchRows({
			snapshotCause: 'newerInput',
			previous: initialBatch,
			upserts: makeBrowserSequentialFileRows({ count: 60, startIndex: 200 }),
			revision: 2,
		});

		await render(
			<BridgeFileViewerApp
				autoOpenInitialFile
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={initialBatch}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return props.descriptor.descriptorId.includes('continued-window-content')
							? continuedContent
							: initialContent;
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
		await waitForVisibleCodeText('initialWindowSelection');
		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishMetadataEvents)(continuedBatch);
		});
		await waitForMetadataTreeRowCount(260);
		await waitForTreeScrollHeightAtLeast(260 * 24);
		const treeScrollOwner = findBridgeViewerTreeScrollOwner();
		if (treeScrollOwner === null) {
			throw new Error('Expected FileView tree scroll owner for continued window click.');
		}
		await actUpdate((): void => {
			treeScrollOwner.scrollTo({ top: 250 * 24 });
			treeScrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
		});
		await actFrame();
		await actFrame();

		const continuedButton = await waitForBridgeViewerTreeItemButton('File-250.swift');
		expect(document.querySelector('[data-worktree-file-path="ignored-output/log.txt"]')).toBeNull();
		await actClick(continuedButton);

		await waitForMetadataInterestUpdateCount({
			expectedCount: 1,
			metadataInterestUpdates: metadataInterestUpdates,
		});
		expect(selectedDisplayPath()).toBe('File-250.swift');
		expect(openFilePath()).toBe('File-250.swift');
		expect(openFileBodyPreview()).toBeNull();

		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishMetadataEvents)(
				replaceBrowserFileBatchRows({
					snapshotCause: 'newerInput',
					previous: continuedBatch,
					upserts: [
						makeBrowserFileRow({
							path: continuedDescriptor.path,
							descriptorOutcome: continuedDescriptor,
						}),
					],
					revision: 3,
				}),
			);
		});
		await waitForOpenFileState('ready');
		await waitForSelectedDisplayPath('File-250.swift');
		await waitForVisibleCodeText('continuedWindowSelection');

		const finalInterestUpdate = metadataInterestUpdates.at(-1);
		if (finalInterestUpdate === undefined)
			throw new Error('Expected final File metadata interest.');
		expect(metadataInterestPathsForLane(finalInterestUpdate, 'foreground')).toEqual([
			'File-250.swift',
		]);
		expect(finalInterestUpdate?.pathScope).toEqual([]);
		expect(openFilePath()).toBe('File-250.swift');
		expect(renderedFilePath()).toBe('File-250.swift');
		expect(openedDescriptorIds).toContain('continued-window-content');
	});

	test('keeps tree identity while invalidating a file descriptor without replacement metadata', async () => {
		const keptDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'kept-content',
			fileId: 'file-kept',
			path: 'src/kept.ts',
		});
		const deletedDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'deleted-content',
			fileId: 'file-deleted',
			path: 'src/deleted.ts',
		});
		let publishMetadataEvents: PublishBrowserFileBatch | null = null;
		const initialBatch = makeBrowserFileBatchWithDescriptors(
			'open',
			keptDescriptor,
			deletedDescriptor,
		);

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={initialBatch}
				fileProductSession={{
					onFileBatchPublisher: (handler): (() => void) => {
						publishMetadataEvents = handler;
						return (): void => {
							publishMetadataEvents = null;
						};
					},
				}}
			/>,
		);

		await waitForMetadataTreeRowCount(3);
		await actUpdate((): void => {
			requireBrowserFileBatchPublisher(publishMetadataEvents)(
				replaceBrowserFileBatchRows({
					snapshotCause: 'newerInput',
					previous: initialBatch,
					upserts: [makeBrowserFileRow({ path: 'src/deleted.ts', fileId: 'file-deleted' })],
					revision: 2,
				}),
			);
		});

		await waitForMetadataTreeRowCount(3);
		await waitForBridgeViewerTreeItemButton('src/kept.ts');
		expect(await waitForBridgeViewerTreeItemButton('src/deleted.ts')).not.toBeNull();
	});

	test('requests and opens a descriptor when clicking a metadata-only file row', async () => {
		const content = makeFileContent('export const appDelegateFixture = true;\n');
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
		const publisherObservation = makeBrowserFileBatchPublisherObservation();

		await render(
			<BridgeFileViewerApp
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
						publisherObservation.observe(handler);
						return (): void => {
							publishMetadataEvents = null;
						};
					},
				}}
			/>,
		);

		await publisherObservation.publisher;
		await waitForBridgeFileViewerWorkerMessageDrain();
		const fileButton = await waitForBridgeViewerTreeItemButton(
			'Sources/AgentStudio/App/AppDelegate.swift',
		);
		await actClick(fileButton);
		await waitForBridgeFileViewerWorkerMessageDrain();

		await waitForMetadataInterestUpdateCount({
			expectedCount: 1,
			metadataInterestUpdates: metadataInterestUpdates,
		});
		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('appDelegateFixture');

		expect(metadataInterestUpdates.at(-1)).toMatchObject({
			interests: [{ lane: 'foreground', paths: ['Sources/AgentStudio/App/AppDelegate.swift'] }],
			pathScope: [],
		});
		expect(openedDescriptorIds).toEqual(['app-delegate-content']);
		expect(openFilePath()).toBe('Sources/AgentStudio/App/AppDelegate.swift');
		await actFrame();
	});

	test('renders selected content after the typed content stream completes', async () => {
		const content = makeFileContent('export const fileOpenReady = true;\n');
		const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content,
			contentHandle: 'file-open-ready-content',
			fileId: 'file-open-ready',
			path: 'src/file-open-ready.ts',
		});
		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', descriptor)}
				fileProductSession={{
					readContent: async () => content,
				}}
			/>,
		);

		await waitForBridgeFileViewerWorkerMessageDrain();
		const fileButton = await waitForBridgeViewerTreeItemButton('src/file-open-ready.ts');
		await actClick(fileButton);
		await waitForBridgeFileViewerWorkerMessageDrain();

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('fileOpenReady');
		expect(openFilePath()).toBe('src/file-open-ready.ts');
		expect(openFileBodyPreview()).toContain('fileOpenReady');
	});

	test('records visible demand telemetry when the File tree scroll path settles demand', async () => {
		const descriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'scroll-visible-demand-content',
			fileId: 'file-scroll-visible-demand',
			path: 'src/scroll-visible-demand.ts',
		});
		const telemetrySamples: BridgeTelemetrySample[] = [];

		await import('./bridge-file-viewer-shell.js');
		await act(async (): Promise<void> => {
			await render(
				<div style={{ height: '720px', overflow: 'hidden', width: '1280px' }}>
					<BridgeFileViewerApp
						initialFileBatch={makeBrowserFileBatchWithDescriptors('open', descriptor)}
						telemetryRecorder={makeTestTelemetryRecorder(telemetrySamples)}
						fileProductSession={{
							readContent: async () =>
								makeFileContent('export const scrollVisibleDemand = true;\n'),
						}}
					/>
				</div>,
			);
			await Promise.resolve();
		});

		await actFrame();
		await actFrame();
		await waitForBridgeViewerTreeItemButton('src/scroll-visible-demand.ts');
		const initialSampleCount = telemetrySamples.filter(
			(sample): boolean => sample.name === 'performance.bridge.trees.scroll_visible_demand',
		).length;
		const treeScrollOwner = findBridgeViewerTreeScrollOwner();
		if (treeScrollOwner === null) {
			throw new Error('Expected FileView tree scroll owner for visible demand telemetry.');
		}
		await actUpdate((): void => {
			treeScrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
		});

		const sample = await waitForTelemetrySampleCount({
			count: initialSampleCount + 1,
			name: 'performance.bridge.trees.scroll_visible_demand',
			samples: telemetrySamples,
		});

		expect(sample.durationMilliseconds).not.toBeNull();
		expect(sample.durationMilliseconds ?? -1).toBeGreaterThanOrEqual(0);
		expect(sample.stringAttributes).toMatchObject({
			'agentstudio.bridge.demand.disposition': 'published',
			'agentstudio.bridge.demand.lane': 'visible',
			'agentstudio.bridge.phase': 'scroll_visible_demand',
			'agentstudio.bridge.result': 'success',
			'agentstudio.bridge.result_reason': 'none',
			'agentstudio.bridge.slice': 'tree_prepare_input',
			'agentstudio.bridge.viewer': 'file',
		});
		expect(sample.numericAttributes['agentstudio.bridge.visible_item.count']).toBeGreaterThan(0);
		expect(
			telemetrySamples.some(
				(settledSample): boolean =>
					settledSample.name === 'performance.bridge.web.visible_demand_settled',
			),
		).toBe(false);
	});
});

async function waitForFileFilterCount(expectedCount: string, attempt = 0): Promise<void> {
	if (fileFilterCount() === expectedCount) return;
	if (attempt >= 60) {
		throw new Error(
			`Expected File filter count ${expectedCount}; actual=${fileFilterCount() ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForFileFilterCount(expectedCount, attempt + 1);
}

function fileFilterCount(): string | null {
	return document.querySelector('[data-testid="worktree-file-filter-count"]')?.textContent ?? null;
}

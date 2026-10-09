import { act } from 'react';
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';
import { userEvent } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode mounts the production File shell.
import '../app/bridge-app.css';
import { bridgeAppControlProbeSchema } from '../app/bridge-app-control.js';
import type { BridgeWorkerMainToServerMessage } from '../core/comm-worker/bridge-worker-contracts.js';
import {
	settleFileViewerMenuTransition,
	waitForFileViewerMenuOptionContaining,
} from './bridge-file-viewer-app-startup.browser.test-support.js';
import { BridgeFileViewerBrowserHarnessApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatch,
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcome,
	makeBrowserFileDescriptorOutcomeForContent,
	makeBrowserFileRow,
} from './bridge-file-viewer-browser-test-batches.js';
import {
	fileNavigationCommandForPath,
	makeFileContent,
} from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actClick,
	actFrame,
	actUpdate,
	interactAndWaitForBridgeFileViewerQueryCompletion,
	installBridgeFileViewerNoopResizeObserver,
	makeDeferredContent,
	settleBridgeFileViewerBrowserUpdates,
	waitForMetadataTreeRowCount,
	waitForOpenFileState,
	selectedDisplayPath,
	waitForSelectedDisplayPath,
	waitForBridgeFileViewerWorkerMessageDrain,
} from './bridge-file-viewer-browser-test-harness.js';

describe('BridgeFileViewerApp query and content lifecycle Browser Mode', () => {
	beforeEach((): void => {
		installBridgeFileViewerNoopResizeObserver();
	});

	afterEach(async (): Promise<void> => {
		await actUpdate(cleanup);
		await waitForBridgeFileViewerWorkerMessageDrain();
		document.body.replaceChildren();
	});

	test('does not reschedule the unchanged query when content publications update the snapshot', async () => {
		// Arrange
		const content = makeFileContent('export const queryLifecycle = "settled";\n');
		const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content,
			descriptorId: 'query-lifecycle-content',
			fileId: 'file-query-lifecycle',
			path: 'src/query-lifecycle.ts',
		});
		const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
		const deferredContent = makeDeferredContent();

		// Act
		await render(
			<BridgeFileViewerBrowserHarnessApp
				autoOpenInitialFile={true}
				fileProductSession={{
					onWorkerCommand: (message): void => {
						dispatchedMessages.push(message);
					},
					readContent: (): Promise<string> => deferredContent.promise,
				}}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', descriptor)}
			/>,
		);
		await waitForMetadataTreeRowCount(2);
		await waitForOpenFileState('loading');
		await actUpdate((): void => {
			deferredContent.resolve(content);
		});
		await waitForOpenFileState('ready');
		await settleBridgeFileViewerBrowserUpdates();

		// Assert
		const queryUpdates = dispatchedMessages.filter(
			(message): boolean => message.command === 'fileQueryUpdate',
		);
		expect(queryUpdates).toHaveLength(1);
		expect(
			dispatchedMessages.filter((message): boolean => message.command === 'select'),
		).toHaveLength(1);
	});

	test('clears an excluded File selection without auto-selecting a filtered replacement', async () => {
		// Arrange
		await render(
			<BridgeFileViewerBrowserHarnessApp
				initialFileBatch={makeMixedFileClassBatch()}
				navigationCommand={fileNavigationCommandForPath('Sources/App/TextFile.ts')}
			/>,
		);
		await waitForMetadataTreeRowCount(19);
		await waitForSelectedDisplayPath('Sources/App/TextFile.ts');

		// Act
		await interactAndWaitForBridgeFileViewerQueryCompletion(async (): Promise<void> => {
			window.dispatchEvent(
				new CustomEvent('__bridge_review_control', {
					detail: {
						filter: { categoryFilter: 'docs', surface: 'files' },
						method: 'bridge.fileTree.setFilter',
					},
				}),
			);
			await Promise.resolve();
		});
		await waitForMetadataTreeRowCount(1);

		// Assert
		await expect.poll(selectedDisplayPath, { timeout: 1_000 }).toBeNull();
		await expect
			.poll((): readonly string[] => mountedFileTreePaths())
			.toEqual(['Docs', 'Docs/Guide.md']);
		const probe = bridgeAppControlProbeSchema.safeParse(window.bridgeReviewControlProbe);
		expect(probe.success).toBe(true);
		if (!probe.success) return;
		expect(probe.data).toMatchObject({
			categoryFilter: 'docs',
			filterSurface: 'files',
			status: 'accepted',
		});
	});

	test('projects text and regex matches with required ancestors through the visible File search', async () => {
		// Arrange
		const renderResult = await render(
			<BridgeFileViewerBrowserHarnessApp initialFileBatch={makeTreeRowsOnlyBatch()} />,
		);
		await waitForMetadataTreeRowCount(6);
		expect(document.querySelector('[data-testid="worktree-file-search-toggle"]')).not.toBeNull();
		const fileTree = renderResult.getByTestId('bridge-file-viewer-pierre-file-tree').element();
		if (!(fileTree instanceof HTMLElement)) throw new Error('Expected the Files tree focus owner.');
		await actUpdate((): void => fileTree.focus());

		// Act: Command-Shift-F opens the active Files Search control.
		await dispatchFileViewerShortcut({ shiftKey: true });

		// Assert: the toggle remains available to cancel an empty search and the field owns focus.
		const searchToggle = renderResult.getByTestId('worktree-file-search-toggle');
		await expect.element(searchToggle).toHaveAttribute('aria-pressed', 'true');
		await expect.element(searchToggle).toHaveAttribute('aria-label', 'Search files');
		await expect.element(searchToggle).toHaveAttribute('title', 'Close file search (⌘⇧F)');
		let searchInput = renderResult.getByTestId('worktree-file-search-input').element();
		if (!(searchInput instanceof HTMLInputElement)) {
			throw new Error('Expected the visible File search input.');
		}
		expect(document.activeElement).toBe(searchInput);

		// Act: the active toolbar toggle cancels an empty search and can reopen it.
		await actClick(requireHTMLElement(searchToggle.element()));
		expect(document.querySelector('[data-testid="worktree-file-search-input"]')).toBeNull();
		expect(document.activeElement).toBe(fileTree);
		await expect.element(searchToggle).toHaveAttribute('aria-pressed', 'false');
		await expect.element(searchToggle).toHaveAttribute('aria-label', 'Search files');
		await actClick(requireHTMLElement(searchToggle.element()));
		searchInput = renderResult.getByTestId('worktree-file-search-input').element();
		if (!(searchInput instanceof HTMLInputElement)) {
			throw new Error('Expected the reopened File search input.');
		}
		expect(document.activeElement).toBe(searchInput);

		// Act: foreground Escape closes Search without relying on a surface-global handler.
		await dispatchFileViewerSearchEscape(searchInput);

		// Assert: focus returns to the still-eligible Files tree and Search can reopen normally.
		expect(document.querySelector('[data-testid="worktree-file-search-input"]')).toBeNull();
		expect(document.activeElement).toBe(fileTree);
		await actClick(requireHTMLElement(searchToggle.element()));

		// Act: enter a text query.
		await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
			setBridgeFileViewerSearchInputValue(
				renderResult.getByTestId('worktree-file-search-input').element(),
				'AppDelegate',
			);
		});

		// Assert: only the matching file and required ancestors remain painted.
		await expect
			.poll((): readonly string[] => mountedFileTreePaths())
			.toEqual(['Sources/AgentStudio/App', 'Sources/AgentStudio/App/AppDelegate.swift']);

		// Act: an empty directory whose own path matches must not survive.
		await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
			setBridgeFileViewerSearchInputValue(
				renderResult.getByTestId('worktree-file-search-input').element(),
				'Bridge',
			);
		});

		// Assert
		await expect.poll((): readonly string[] => mountedFileTreePaths()).toEqual([]);

		// Act: regex is selected from inside the compound search field.
		await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
			requireHTMLElement(renderResult.getByTestId('worktree-file-regex-toggle').element()).click();
		});
		await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
			setBridgeFileViewerSearchInputValue(
				renderResult.getByTestId('worktree-file-search-input').element(),
				String.raw`AppDelegate\.swift$`,
			);
		});

		// Assert
		await expect
			.poll((): readonly string[] => mountedFileTreePaths())
			.toEqual(['Sources/AgentStudio/App', 'Sources/AgentStudio/App/AppDelegate.swift']);

		// Act: invalid regex leaves the last accepted projection visible and the input correctable.
		await actUpdate((): void => {
			setBridgeFileViewerSearchInputValue(
				renderResult.getByTestId('worktree-file-search-input').element(),
				'[',
			);
		});

		// Assert
		await expect
			.poll((): readonly string[] => mountedFileTreePaths())
			.toEqual(['Sources/AgentStudio/App', 'Sources/AgentStudio/App/AppDelegate.swift']);
		await expect
			.element(renderResult.getByTestId('worktree-file-filter-status'))
			.toHaveTextContent('Invalid regex');
		await expect
			.element(renderResult.getByTestId('worktree-file-search-input'))
			.toHaveAttribute('aria-invalid', 'true');
		await expect.element(renderResult.getByTestId('worktree-file-search-input')).toHaveValue('[');

		// Act: oversized visible input is rejected without replacing entered or accepted state.
		await actUpdate((): void => {
			setBridgeFileViewerSearchInputValue(
				renderResult.getByTestId('worktree-file-search-input').element(),
				'a'.repeat(4_097),
			);
		});

		// Assert
		await expect.element(renderResult.getByTestId('worktree-file-search-input')).toHaveValue('[');
		await expect
			.element(renderResult.getByTestId('worktree-file-filter-status'))
			.toHaveTextContent('Search query is too long');
		await expect
			.poll((): readonly string[] => mountedFileTreePaths())
			.toEqual(['Sources/AgentStudio/App', 'Sources/AgentStudio/App/AppDelegate.swift']);

		// Act: the far-right Clear action resets the visible query.
		await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
			requireHTMLElement(renderResult.getByTestId('worktree-file-search-clear').element()).click();
		});

		// Assert
		await expect.element(renderResult.getByTestId('worktree-file-search-input')).toHaveValue('');
		await expect
			.poll((): readonly string[] => mountedFileTreePaths())
			.toContain('Sources/AgentStudio/App/AppDelegate.swift');
		await expect
			.poll((): readonly string[] => mountedFileTreePaths())
			.toContain('Sources/AgentStudio/Features/Bridge');

		// Act: close a populated search through the persistent toggle.
		await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
			setBridgeFileViewerSearchInputValue(
				renderResult.getByTestId('worktree-file-search-input').element(),
				'AppDelegate',
			);
		});
		await interactAndWaitForBridgeFileViewerQueryCompletion(
			(): Promise<void> => actClick(requireHTMLElement(searchToggle.element())),
		);

		// Assert: closing clears the query, and reopening starts empty.
		expect(document.querySelector('[data-testid="worktree-file-search-input"]')).toBeNull();
		await expect.element(searchToggle).toHaveAttribute('aria-pressed', 'false');
		await expect.element(searchToggle).toHaveAttribute('aria-label', 'Search files');
		await actClick(requireHTMLElement(searchToggle.element()));
		await expect.element(renderResult.getByTestId('worktree-file-search-input')).toHaveValue('');
	});

	test('routes active Files toolbar shortcuts through its scoped control target', async () => {
		// Arrange
		const controlTarget = new EventTarget();
		await render(
			<BridgeFileViewerBrowserHarnessApp
				controlTarget={controlTarget}
				initialFileBatch={makeTreeRowsOnlyBatch()}
			/>,
		);
		await waitForMetadataTreeRowCount(6);

		// Act: the document is outside this viewer's command scope.
		await dispatchFileViewerShortcut({ shiftKey: true });

		// Assert
		expect(document.querySelector('[data-testid="worktree-file-search-input"]')).toBeNull();

		// Act: the scoped target owns both toolbar shortcuts.
		await dispatchFileViewerShortcut({ shiftKey: true }, controlTarget);

		// Assert
		expect(document.querySelector('[data-testid="worktree-file-search-input"]')).not.toBeNull();

		// Act
		await dispatchFileViewerShortcut({ altKey: true }, controlTarget);

		// Assert
		expect(
			document.querySelector('[data-testid="worktree-file-filter-menu-popover"][data-open]'),
		).not.toBeNull();
	});

	test('announces closed semantic rejection and clears it on the next admitted Search', async () => {
		// Arrange
		const renderResult = await render(
			<BridgeFileViewerBrowserHarnessApp initialFileBatch={makeTreeRowsOnlyBatch()} />,
		);
		await waitForMetadataTreeRowCount(6);
		const fileTree = requireHTMLElement(
			renderResult.getByTestId('bridge-file-viewer-pierre-file-tree').element(),
		);
		await actUpdate((): void => fileTree.focus());

		// Act: reject a complete semantic candidate while Search is closed.
		await dispatchFileViewerSearchCommand({ mode: 'text', query: 'a'.repeat(4_097) });

		// Assert: Search and focus stay put while the persistent live region announces rejection.
		expect(document.querySelector('[data-testid="worktree-file-search-input"]')).toBeNull();
		expect(document.activeElement).toBe(fileTree);
		await expect
			.element(renderResult.getByTestId('worktree-file-filter-status'))
			.toHaveTextContent('Search query is too long');

		// Act: an admitted semantic Search clears the stale rejection.
		await dispatchFileViewerSearchCommand({ mode: 'regex', query: 'AppDelegate' });

		// Assert
		await expect
			.element(renderResult.getByTestId('worktree-file-search-input'))
			.toHaveValue('AppDelegate');
		await expect
			.element(renderResult.getByTestId('worktree-file-filter-status'))
			.toHaveTextContent('');

		// Act: a later invalid regex must replace, not be masked by, the oversized status.
		await dispatchFileViewerSearchCommand({
			expectsQueryCompletion: false,
			mode: 'regex',
			query: '[',
		});

		// Assert
		await expect.element(renderResult.getByTestId('worktree-file-search-input')).toHaveValue('[');
		await expect
			.element(renderResult.getByTestId('worktree-file-filter-status'))
			.toHaveTextContent('Invalid regex');
	});

	test('returns focus to the Search trigger when no earlier semantic owner was recorded', async () => {
		// Arrange
		const renderResult = await render(
			<BridgeFileViewerBrowserHarnessApp initialFileBatch={makeTreeRowsOnlyBatch()} />,
		);
		await waitForMetadataTreeRowCount(6);
		const searchToggle = renderResult.getByTestId('worktree-file-search-toggle');

		// Act: open directly from the trigger, then close from the focused field.
		await actClick(requireHTMLElement(searchToggle.element()));
		const searchInput = requireHTMLElement(
			renderResult.getByTestId('worktree-file-search-input').element(),
		);
		await dispatchFileViewerSearchEscape(searchInput);

		// Assert
		expect(document.querySelector('[data-testid="worktree-file-search-input"]')).toBeNull();
		expect(document.activeElement).toBe(searchToggle.element());
	});

	test('restores Files focus by eligible path and falls back when the path is excluded', async () => {
		// Arrange
		const renderResult = await render(
			<BridgeFileViewerBrowserHarnessApp initialFileBatch={makeTreeRowsOnlyBatch()} />,
		);
		await waitForMetadataTreeRowCount(6);
		const focusedPath = 'Sources/AgentStudio/App/AppDelegate.swift';
		await expect.poll(() => mountedFileTreeRow(focusedPath)).not.toBeNull();
		const originalRow = requireHTMLElement(mountedFileTreeRow(focusedPath));
		await actUpdate((): void => originalRow.focus());
		await expect.poll(deepActiveElement).toBe(originalRow);

		// Act: Search keeps the focused semantic path eligible.
		await dispatchFileViewerShortcut({ shiftKey: true });
		await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
			setBridgeFileViewerSearchInputValue(
				renderResult.getByTestId('worktree-file-search-input').element(),
				'AppDelegate',
			);
		});
		const searchInput = requireHTMLElement(
			renderResult.getByTestId('worktree-file-search-input').element(),
		);
		await dispatchFileViewerSearchEscape(searchInput, true);

		// Assert: the owner resolves the current row, not a stale DOM node.
		await expect
			.poll((): string | undefined =>
				deepActiveElement()?.getAttribute('data-item-path')?.replace(/\/$/u, ''),
			)
			.toBe(focusedPath);

		// Act: exclude the recorded path before closing the next Search.
		const eligibleRow = requireHTMLElement(mountedFileTreeRow(focusedPath));
		await actUpdate((): void => eligibleRow.focus());
		await dispatchFileViewerShortcut({ shiftKey: true });
		await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
			setBridgeFileViewerSearchInputValue(
				renderResult.getByTestId('worktree-file-search-input').element(),
				'NoSuchPath',
			);
		});
		const excludedSearchInput = requireHTMLElement(
			renderResult.getByTestId('worktree-file-search-input').element(),
		);
		await dispatchFileViewerSearchEscape(excludedSearchInput, true);

		// Assert: an ineligible path falls back to the Search trigger.
		await expect
			.poll(() => document.activeElement)
			.toBe(renderResult.getByTestId('worktree-file-search-toggle').element());
	});

	test('File category filters use real native classes, preserve ancestors, and Clear restores the tree', async () => {
		// Arrange
		const renderResult = await render(
			<BridgeFileViewerBrowserHarnessApp initialFileBatch={makeMixedFileClassBatch()} />,
		);
		await waitForMetadataTreeRowCount(19);
		await expect
			.poll((): readonly string[] => mountedFileTreePaths())
			.toEqual(allClassifiedFileTreePaths);

		// Act: Command-Option-F opens the production Base UI menu.
		await dispatchFileViewerShortcut({ altKey: true });
		const filterPopover = requireHTMLElement(
			renderResult.getByTestId('worktree-file-filter-menu-popover').element(),
		);

		// Assert: Files exposes exactly the native path-and-size-backed taxonomy.
		expect(filterPopover.textContent).toContain('File category');
		expect(filterPopover.textContent).not.toContain('Git status');
		expect(filterPopover.textContent).not.toContain('Binary');
		expect(filterPopover.textContent).not.toContain('Large');
		for (const fileClassLabel of [
			'All',
			'Source code',
			'Tests',
			'Documentation',
			'Configuration',
			'Test data',
		]) {
			expect(filterPopover.textContent).toContain(fileClassLabel);
		}

		// Act: repeating the shortcut closes and reopens the same menu.
		await dispatchFileViewerShortcut({ altKey: true });
		expect(
			document.querySelector('[data-testid="worktree-file-filter-menu-popover"][data-open]'),
		).toBeNull();
		await dispatchFileViewerShortcut({ altKey: true });

		// Act: Base UI Escape dismissal closes the menu and preserves its filter state.
		await dispatchFileViewerMenuKey('Escape');
		expect(
			document.querySelector('[data-testid="worktree-file-filter-menu-popover"][data-open]'),
		).toBeNull();
		await dispatchFileViewerShortcut({ altKey: true });

		// Act: Base UI owns menu focus, highlighted-option navigation, and Return selection.
		await waitForFileViewerMenuFocus();
		await dispatchFileViewerMenuKey('ArrowDown');
		await expect.poll(highlightedFileViewerMenuOptionLabel).toBe('All');
		await navigateFileViewerMenuTo('Test data');
		const focusedFixtureOption = highlightedFileViewerMenuOption();
		expect(focusedFixtureOption.textContent).toContain('Test data');
		expect(document.activeElement).toBe(focusedFixtureOption);
		await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
			dispatchFileViewerMenuEnter();
		});
		await actFrame();
		await expect.poll(() => focusedFixtureOption.getAttribute('aria-checked')).toBe('true');

		// Assert: the matching file and only its required ancestor remain.
		await expect
			.poll((): readonly string[] => mountedFileTreePaths())
			.toEqual(['Fixtures', 'Fixtures/sample.txt']);

		// Act / Assert: every exposed category selects real metadata-backed rows.
		// oxlint-disable no-await-in-loop -- Each selection mutates one shared Base UI menu and must settle before the next.
		for (const categoryCase of categoryFilterCases) {
			await clickFileViewerMenuOptionAndWaitForQuery(
				await waitForFileViewerMenuOptionContaining({ text: categoryCase.label }),
			);
			await expect
				.poll((): readonly string[] => mountedFileTreePaths())
				.toEqual(categoryCase.expectedPaths);
		}
		// oxlint-enable no-await-in-loop

		// Act: Clear is the product reset path, not a test-only state mutation.
		await clickFileViewerMenuOptionAndWaitForQuery(
			requireHTMLElement(renderResult.getByTestId('worktree-file-filter-menu-clear').element()),
		);

		// Assert
		await expect
			.poll((): readonly string[] => mountedFileTreePaths())
			.toEqual(allClassifiedFileTreePaths);
	});
});

function makeTreeRowsOnlyBatch(): ReturnType<typeof makeBrowserFileBatch> {
	const paths = [
		'Sources',
		'Sources/AgentStudio',
		'Sources/AgentStudio/App',
		'Sources/AgentStudio/App/AppDelegate.swift',
		'Sources/AgentStudio/Features',
		'Sources/AgentStudio/Features/Bridge',
	] as const;
	return makeBrowserFileBatch({
		snapshotCause: 'open',
		rows: paths.map((path) =>
			makeBrowserFileRow({ path, kind: path.endsWith('.swift') ? 'file' : 'directory' }),
		),
	});
}

function makeMixedFileClassBatch(): ReturnType<typeof makeBrowserFileBatch> {
	const textDescriptor = makeBrowserFileDescriptorOutcome({
		descriptorId: 'mixed-text-content',
		fileId: 'file-mixed-text',
		path: 'Sources/App/TextFile.ts',
	});
	const categories = [
		['Tests/TextFile.test.ts', 'test'],
		['Docs/Guide.md', 'docs'],
		['Config/package.json', 'config'],
		['Generated/API.generated.swift', 'generated'],
		['Large/blob.txt', 'large'],
		['Fixtures/sample.txt', 'fixture'],
		['Assets/logo.png', 'unknown'],
		['Vendor/Library.js', 'vendor'],
	] as const;
	return makeBrowserFileBatch({
		snapshotCause: 'open',
		rows: [
			makeBrowserFileRow({ path: 'Sources', kind: 'directory' }),
			makeBrowserFileRow({ path: 'Sources/App', kind: 'directory' }),
			makeBrowserFileRow({ path: textDescriptor.path, descriptorOutcome: textDescriptor }),
			...categories.flatMap(([path, fileClass]) => [
				makeBrowserFileRow({ path: path.split('/')[0] ?? path, kind: 'directory' }),
				makeBrowserFileRow({
					path,
					fileClass,
					sizeBytes: fileClass === 'large' ? 1_000_000 : 64,
					...(fileClass === 'vendor'
						? {
								descriptorOutcome: makeBrowserFileDescriptorOutcome({
									path,
									availability: 'unavailable',
								}),
							}
						: {}),
				}),
			]),
		],
	});
}

const categoryFilterCases = [
	{ expectedPaths: ['Sources/App', 'Sources/App/TextFile.ts'], label: 'Source code' },
	{ expectedPaths: ['Tests', 'Tests/TextFile.test.ts'], label: 'Tests' },
	{ expectedPaths: ['Docs', 'Docs/Guide.md'], label: 'Documentation' },
	{ expectedPaths: ['Config', 'Config/package.json'], label: 'Configuration' },
	{ expectedPaths: ['Fixtures', 'Fixtures/sample.txt'], label: 'Test data' },
] as const;

const allClassifiedFileTreePaths = categoryFilterCases
	.flatMap((categoryCase): readonly string[] => categoryCase.expectedPaths)
	.concat([
		'Large',
		'Large/blob.txt',
		'Generated',
		'Generated/API.generated.swift',
		'Vendor',
		'Vendor/Library.js',
		'Assets',
		'Assets/logo.png',
	])
	.toSorted();

function requireHTMLElement(element: Element | null): HTMLElement {
	if (!(element instanceof HTMLElement)) throw new Error('Expected a real Browser Mode element.');
	return element;
}

async function dispatchFileViewerShortcut(
	modifiers: Readonly<{ altKey?: boolean; shiftKey?: boolean }>,
	target: EventTarget = document,
): Promise<void> {
	await act(async (): Promise<void> => {
		target.dispatchEvent(
			new KeyboardEvent('keydown', {
				altKey: modifiers.altKey ?? false,
				bubbles: true,
				cancelable: true,
				key: 'f',
				metaKey: true,
				shiftKey: modifiers.shiftKey ?? false,
			}),
		);
	});
	await actFrame();
	if (modifiers.altKey) await settleFileViewerMenuTransition();
}

async function dispatchFileViewerSearchCommand(props: {
	readonly expectsQueryCompletion?: boolean;
	readonly mode: 'regex' | 'text';
	readonly query: string;
}): Promise<void> {
	const dispatch = async (): Promise<void> => {
		window.dispatchEvent(
			new CustomEvent('__bridge_review_control', {
				detail: {
					method: 'bridge.fileTree.search',
					searchMode: { kind: props.mode },
					searchText: props.query,
				},
			}),
		);
	};
	if (props.expectsQueryCompletion === false || props.query.length > 4_096) {
		await act(dispatch);
		return;
	}
	await interactAndWaitForBridgeFileViewerQueryCompletion((): Promise<void> => act(dispatch));
}

async function dispatchFileViewerSearchEscape(
	searchInput: HTMLElement,
	expectsQueryCompletion = false,
): Promise<void> {
	const dispatch = async (): Promise<void> => {
		searchInput.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Escape' }));
	};
	if (expectsQueryCompletion) {
		await interactAndWaitForBridgeFileViewerQueryCompletion((): Promise<void> => act(dispatch));
		return;
	}
	await act(dispatch);
}

async function clickFileViewerMenuOptionAndWaitForQuery(element: HTMLElement): Promise<void> {
	await interactAndWaitForBridgeFileViewerQueryCompletion((): void => {
		element.click();
	});
	// Base UI captures animations on this frame; their completion can unmount MenuRoot later.
	await actFrame();
	await settleFileViewerMenuTransition();
}

function setBridgeFileViewerSearchInputValue(element: Element, value: string): void {
	if (!(element instanceof HTMLInputElement)) {
		throw new Error('Expected the File Viewer search input.');
	}
	// oxlint-disable-next-line unbound-method -- The native setter is deliberately rebound to the controlled input below.
	const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
	if (valueSetter === undefined) {
		throw new Error('Expected the native HTMLInputElement value setter.');
	}
	valueSetter.call(element, value);
	element.dispatchEvent(
		new InputEvent('input', {
			bubbles: true,
			data: value,
			inputType: 'insertText',
		}),
	);
}

function dispatchFileViewerMenuEnter(): void {
	const activeElement = document.activeElement;
	if (!(activeElement instanceof HTMLElement)) {
		throw new Error('Expected a focused File Viewer menu option.');
	}
	activeElement.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter' }));
	activeElement.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Enter' }));
}

async function dispatchFileViewerMenuKey(key: 'ArrowDown' | 'Enter' | 'Escape'): Promise<void> {
	await act(async (): Promise<void> => {
		await userEvent.keyboard(`{${key}}`);
	});
	// Base UI applies the selected value from an effect after the keyboard
	// event returns. Commit that effect in an act-scoped frame before polling
	// the resulting DOM state, so CI load cannot expose an unwrapped update.
	await actFrame();
	await settleFileViewerMenuTransition();
}

async function waitForFileViewerMenuFocus(): Promise<void> {
	await expect
		.poll((): boolean => {
			const openFilterMenu = document.querySelector(
				'[data-testid="worktree-file-filter-menu-popover"][data-open]',
			);
			return (
				document.activeElement !== null && openFilterMenu?.contains(document.activeElement) === true
			);
		})
		.toBe(true);
}

async function navigateFileViewerMenuTo(label: string): Promise<void> {
	for (let optionIndex = 0; optionIndex < 9; optionIndex += 1) {
		if (highlightedFileViewerMenuOptionLabel() === label) {
			return;
		}
		await dispatchFileViewerMenuKey('ArrowDown');
	}
	throw new Error(`Expected Base UI arrow navigation to focus ${label}.`);
}

function highlightedFileViewerMenuOption(): HTMLElement {
	return requireHTMLElement(
		document.querySelector('[data-testid="worktree-file-filter-menu-option"][data-highlighted]'),
	);
}

function highlightedFileViewerMenuOptionLabel(): string {
	const highlightedOption = document.querySelector(
		'[data-testid="worktree-file-filter-menu-option"][data-highlighted]',
	);
	return (
		highlightedOption
			?.querySelector('[data-testid="worktree-file-filter-menu-option-label"]')
			?.textContent?.trim() ?? ''
	);
}

function mountedFileTreePaths(): readonly string[] {
	const treeHost = document.querySelector(
		'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
	);
	if (!(treeHost instanceof HTMLElement) || treeHost.shadowRoot === null) return [];
	return [...treeHost.shadowRoot.querySelectorAll<HTMLElement>('[data-item-path]')]
		.map((row): string => row.dataset['itemPath']?.replace(/\/$/u, '') ?? '')
		.filter((path): boolean => path.length > 0)
		.filter((path, index, paths): boolean => paths.indexOf(path) === index)
		.toSorted();
}

function mountedFileTreeRow(path: string): HTMLElement | null {
	const treeHost = document.querySelector(
		'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
	);
	const row = [
		...(treeHost?.shadowRoot?.querySelectorAll<HTMLElement>('[data-item-path]') ?? []),
	].find((candidate): boolean => candidate.dataset['itemPath']?.replace(/\/$/u, '') === path);
	return row instanceof HTMLElement ? row : null;
}

function deepActiveElement(): Element | null {
	let activeElement = document.activeElement;
	while (activeElement instanceof HTMLElement) {
		const shadowActiveElement = activeElement.shadowRoot?.activeElement;
		if (shadowActiveElement === null || shadowActiveElement === undefined) break;
		activeElement = shadowActiveElement;
	}
	return activeElement;
}

// Register at the Browser Mode entry; the shared module owns the pure pass-through wrapper.
vi.mock('../components/ui/dropdown-menu.js', async (importOriginal) => {
	const original = await importOriginal<typeof import('../components/ui/dropdown-menu.js')>();
	const { withFileMenuCompletion } =
		await import('./bridge-file-viewer-menu-completion.browser.test-support.js');
	return withFileMenuCompletion(original);
});

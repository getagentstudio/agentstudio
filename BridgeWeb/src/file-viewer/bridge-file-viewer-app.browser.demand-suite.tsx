import { describe, expect, test } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the app CSS.
import '../app/bridge-app.css';
import type {
	BridgeWorkerMainToServerMessage,
	BridgeWorkerViewportCommand,
} from '../core/comm-worker/bridge-worker-contracts.js';
import {
	findBridgeViewerTreeScrollOwner,
	requireBridgeViewerHTMLElement,
	waitForBridgeViewerTreeItemButton,
} from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import { BridgeFileViewerBrowserHarnessApp as BridgeFileViewerApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcome,
} from './bridge-file-viewer-browser-test-batches.js';
import { makeFileContent } from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actFrame,
	actUpdate,
	openFilePath,
	openFileState,
	waitForMetadataTreeRowCount,
	waitForTreeScrollHeightAtLeast,
} from './bridge-file-viewer-browser-test-harness.js';

describe('BridgeFileViewerApp Browser Mode', () => {
	test('does not fetch visible file tree demand on the main thread', async () => {
		const firstDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'first-visible-content',
			fileId: 'file-first-visible',
			path: 'src/first-visible.ts',
		});
		const secondDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'second-visible-content',
			fileId: 'file-second-visible',
			path: 'src/second-visible.ts',
		});
		const openedDescriptorIds: string[] = [];

		await render(
			<BridgeFileViewerApp
				initialFileBatch={makeBrowserFileBatchWithDescriptors(
					'open',
					firstDescriptor,
					secondDescriptor,
				)}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return makeFileContent(
							props.descriptor.descriptorId.includes('second-visible-content')
								? 'export const secondVisible = true;\n'
								: 'export const firstVisible = true;\n',
						);
					},
				}}
			/>,
		);

		await waitForMetadataTreeRowCount(3);
		await actFrame();
		await actFrame();
		await actFrame();

		const shell = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		);
		expect(shell.getAttribute('data-last-demand-dispatch-status')).toBeNull();
		expect(shell.getAttribute('data-last-demand-dispatch-first-lane')).toBeNull();
		expect(openFileState()).toBeNull();
		expect(openFilePath()).toBeNull();
		expect(openedDescriptorIds).toEqual([]);
	});

	test('publishes visible viewport facts to the comm worker on File tree scroll', async () => {
		const firstDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'first-worker-viewport-content',
			fileId: 'file-first-worker-viewport',
			path: 'src/first-worker-viewport.ts',
		});
		const secondDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'second-worker-viewport-content',
			fileId: 'file-second-worker-viewport',
			path: 'src/second-worker-viewport.ts',
		});
		const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
		const viewportCommands = createBridgeFileViewerViewportCommandObserver();

		await render(
			<div style={{ height: '720px', overflow: 'hidden', width: '1280px' }}>
				<BridgeFileViewerApp
					fileProductSession={{
						onWorkerCommand: (message): void => {
							dispatchedMessages.push(message);
							viewportCommands.record(message);
						},
					}}
					initialFileBatch={makeBrowserFileBatchWithDescriptors(
						'open',
						firstDescriptor,
						secondDescriptor,
					)}
				/>
			</div>,
		);

		await waitForMetadataTreeRowCount(3);
		await waitForBridgeViewerTreeItemButton('src/first-worker-viewport.ts');
		await waitForBridgeViewerTreeItemButton('src/second-worker-viewport.ts');
		const initialViewportCommand = await viewportCommands.waitForFirst();
		const treeScrollOwner = findBridgeViewerTreeScrollOwner();
		if (treeScrollOwner === null) {
			throw new Error('Expected File View tree scroll owner for worker viewport demand.');
		}

		await actUpdate((): void => {
			treeScrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
		});
		const viewportCommandAfterScroll =
			await viewportCommands.waitForNewerThan(initialViewportCommand);

		expect(dispatchedMessages.map((message) => message.command)).not.toContain(
			'fileViewSourceUpdate',
		);
		expect(viewportCommandAfterScroll.message).toMatchObject({
			command: 'viewport',
			phase: 'settled',
			visibleItemIds: ['file-first-worker-viewport', 'file-second-worker-viewport'],
		});
		expect(
			viewportCommandAfterScroll.message.lastVisibleIndex -
				viewportCommandAfterScroll.message.firstVisibleIndex,
		).toBe(1);
	});

	test('publishes real scrolled File tree viewport indices to the comm worker', async () => {
		const descriptors = Array.from({ length: 80 }, (_value, index) => {
			const paddedIndex = index.toString().padStart(3, '0');
			return makeBrowserFileDescriptorOutcome({
				descriptorId: `scrolled-worker-viewport-content-${paddedIndex}`,
				fileId: `file-scrolled-worker-viewport-${paddedIndex}`,
				path: `File-${paddedIndex}.swift`,
			});
		});
		const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
		const viewportCommands = createBridgeFileViewerViewportCommandObserver();

		await render(
			<div style={{ height: '720px', overflow: 'hidden', width: '1280px' }}>
				<BridgeFileViewerApp
					fileProductSession={{
						onWorkerCommand: (message): void => {
							dispatchedMessages.push(message);
							viewportCommands.record(message);
						},
					}}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', ...descriptors)}
				/>
			</div>,
		);

		await waitForMetadataTreeRowCount(80);
		await waitForTreeScrollHeightAtLeast(80 * 24);
		await waitForBridgeViewerTreeItemButton('File-000.swift');
		const initialViewportCommand = await viewportCommands.waitForFirst();
		const treeScrollOwner = findBridgeViewerTreeScrollOwner();
		if (treeScrollOwner === null) {
			throw new Error('Expected File View tree scroll owner for scrolled worker viewport demand.');
		}

		await actUpdate((): void => {
			treeScrollOwner.scrollTop = 24 * 30;
			treeScrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
		});
		const viewportMessage = (await viewportCommands.waitForNewerThan(initialViewportCommand))
			.message;
		expect(viewportMessage.firstVisibleIndex).toBeGreaterThan(0);
		expect(viewportMessage.lastVisibleIndex).toBeGreaterThanOrEqual(
			viewportMessage.firstVisibleIndex,
		);
		expect(viewportMessage.visibleItemIds.length).toBeGreaterThan(0);
	});

	test('does not patch global fetch for worker-backed content loading', async () => {
		const descriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'global-fetch-isolation-content',
			fileId: 'file-global-fetch-isolation',
			path: 'src/global-fetch-isolation.ts',
		});
		const originalFetch = window.fetch;

		await render(
			<BridgeFileViewerApp
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', descriptor)}
				fileProductSession={{
					readContent: async () => makeFileContent('export const globalFetchIsolation = true;\n'),
				}}
			/>,
		);

		await waitForMetadataTreeRowCount(2);
		expect(window.fetch).toBe(originalFetch);
	});

	test('keeps non-text visible demand from falling back to legacy fetch', async () => {
		const textDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'text-visible-content',
			fileId: 'file-text-visible',
			path: 'src/text-visible.ts',
		});
		const binaryDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'binary-visible-content',
			fileId: 'file-binary-visible',
			availability: 'binary',
			path: 'assets/logo.png',
		});
		const unavailableDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'unavailable-visible-content',
			fileId: 'file-unavailable-visible',
			path: 'generated/huge.log',
			availability: 'unavailable',
		});
		const openedDescriptorIds: string[] = [];

		await render(
			<BridgeFileViewerApp
				initialFileBatch={makeBrowserFileBatchWithDescriptors(
					'open',
					textDescriptor,
					binaryDescriptor,
					unavailableDescriptor,
				)}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return makeFileContent('export const textVisible = true;\n');
					},
				}}
			/>,
		);

		await waitForMetadataTreeRowCount(6);
		await actFrame();
		await actFrame();
		await actFrame();

		const shell = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		);
		expect(shell.getAttribute('data-last-demand-dispatch-status')).toBeNull();
		expect(shell.getAttribute('data-last-demand-dispatch-first-lane')).toBeNull();
		expect(openedDescriptorIds).toEqual([]);
	});

	test('does not start visible demand fetch work before Files becomes inactive', async () => {
		const visibleDescriptor = makeBrowserFileDescriptorOutcome({
			descriptorId: 'inactive-visible-content',
			fileId: 'file-inactive-visible',
			path: 'src/inactive-visible.ts',
		});
		const openedDescriptorIds: string[] = [];

		await render(
			<BridgeFileViewerApp
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', visibleDescriptor)}
				isActive={false}
				fileProductSession={{
					readContent: async (props) => {
						openedDescriptorIds.push(props.descriptor.descriptorId);
						return makeFileContent('export const inactiveVisible = true;\n');
					},
				}}
			/>,
		);

		await waitForMetadataTreeRowCount(2);
		await actFrame();
		await actFrame();

		const shell = requireBridgeViewerHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		);
		expect(shell.getAttribute('data-file-viewer-active')).toBe('false');
		expect(shell.getAttribute('data-last-demand-dispatch-status')).toBeNull();
		expect(shell.getAttribute('data-last-demand-dispatch-first-lane')).toBeNull();
		expect(openedDescriptorIds).toEqual([]);
	});
});

interface BridgeFileViewerObservedViewportCommand {
	readonly message: BridgeWorkerViewportCommand;
	readonly sequence: number;
}

interface BridgeFileViewerViewportCommandObserver {
	record: (message: BridgeWorkerMainToServerMessage) => void;
	waitForFirst: () => Promise<BridgeFileViewerObservedViewportCommand>;
	waitForNewerThan: (
		previous: BridgeFileViewerObservedViewportCommand,
	) => Promise<BridgeFileViewerObservedViewportCommand>;
}

function createBridgeFileViewerViewportCommandObserver(): BridgeFileViewerViewportCommandObserver {
	const commands: BridgeFileViewerObservedViewportCommand[] = [];
	const waiters: Array<{
		readonly afterSequence: number;
		readonly resolve: (command: BridgeFileViewerObservedViewportCommand) => void;
	}> = [];
	const waitForCommandAfter = (
		afterSequence: number,
	): Promise<BridgeFileViewerObservedViewportCommand> => {
		const recordedCommand = commands.find((command): boolean => command.sequence > afterSequence);
		if (recordedCommand !== undefined) {
			return Promise.resolve(recordedCommand);
		}
		return new Promise<BridgeFileViewerObservedViewportCommand>((resolve): void => {
			waiters.push({ afterSequence, resolve });
		});
	};
	return {
		record(message: BridgeWorkerMainToServerMessage): void {
			if (message.command !== 'viewport') {
				return;
			}
			const command = { message, sequence: commands.length + 1 };
			commands.push(command);
			for (let waiterIndex = waiters.length - 1; waiterIndex >= 0; waiterIndex -= 1) {
				const waiter = waiters[waiterIndex];
				if (waiter === undefined || command.sequence <= waiter.afterSequence) {
					continue;
				}
				waiters.splice(waiterIndex, 1);
				waiter.resolve(command);
			}
		},
		waitForFirst: (): Promise<BridgeFileViewerObservedViewportCommand> => waitForCommandAfter(0),
		waitForNewerThan: (
			previous: BridgeFileViewerObservedViewportCommand,
		): Promise<BridgeFileViewerObservedViewportCommand> => waitForCommandAfter(previous.sequence),
	};
}

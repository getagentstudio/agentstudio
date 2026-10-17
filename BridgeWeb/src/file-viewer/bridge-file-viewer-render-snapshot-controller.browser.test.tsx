// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must prove owned shadcn styling.
import '../app/bridge-app.css';
import { act, type ReactElement } from 'react';
import { afterAll, afterEach, beforeEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

import { createBridgePaneRuntime } from '../core/comm-worker/bridge-pane-runtime.js';
import type {
	BridgeWorkerMainToServerMessage,
	BridgeWorkerServerToMainMessage,
	BridgeWorkerViewRecoveryStatusEvent,
} from '../core/comm-worker/bridge-worker-contracts.js';
import { BridgeFileViewerBrowserHarnessApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcomeForContent,
} from './bridge-file-viewer-browser-test-batches.js';
import {
	actUpdateAndWaitForBridgeFileViewerWorkerPublication,
	installBridgeFileViewerNoopResizeObserver,
	waitForBridgeFileViewerWorkerMessageDrain,
} from './bridge-file-viewer-browser-test-harness.js';
import {
	BridgeFileViewerSurfaceClientProvider,
	useBridgeFileViewerRenderSnapshotController,
} from './bridge-file-viewer-render-snapshot-controller.js';
const originalResizeObserver = globalThis.ResizeObserver;
beforeEach((): void => installBridgeFileViewerNoopResizeObserver());
afterAll((): void => {
	Object.assign(globalThis, { ResizeObserver: originalResizeObserver });
});
afterEach(async (): Promise<void> => {
	await act(async (): Promise<void> => {
		await cleanup();
	});
});

describe('Bridge File viewer render snapshot controller Browser Mode', () => {
	test('requests the retained worker display snapshot when the File viewer mounts late', async () => {
		// Arrange
		const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
		const paneRuntime = createBridgePaneRuntime({
			sessionFactory: () => ({
				createDispatcher: () => ({
					dispatch: (message): void => {
						dispatchedMessages.push(message);
					},
					dispose: (): void => {},
				}),
				dispose: (): void => {},
				installNativeBootstrap: (): void => {},
			}),
		});

		// Act
		await render(
			<BridgeFileViewerSurfaceClientProvider surfaceClient={paneRuntime.surfaceClient('fileView')}>
				<BridgeFileViewerRenderSnapshotProbe />
			</BridgeFileViewerSurfaceClientProvider>,
		);

		// Assert
		expect(dispatchedMessages.map(({ command }) => command)).toEqual(['fileDisplayResync']);
	});

	test('shows one Retry for the failed File surface, dispatches both jobs, and keeps actual last good bytes', async () => {
		const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
		const existingFileContent = 'Last good file contents stay visible.';
		const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
			path: 'src/retained.ts',
			content: existingFileContent,
		});
		let publishWorkerMessages:
			| ((messages: readonly BridgeWorkerServerToMainMessage[]) => void)
			| null = null;
		const rendered = await render(
			<BridgeFileViewerBrowserHarnessApp
				autoOpenInitialFile
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', descriptor)}
				fileProductSession={{
					readContent: async (): Promise<string> => existingFileContent,
					onWorkerCommand: (message): void => {
						dispatchedMessages.push(message);
					},
					onWorkerMessagesPublisher: (publisher): void => {
						publishWorkerMessages = publisher;
					},
				}}
			/>,
		);
		await waitForBridgeFileViewerWorkerMessageDrain();
		await expect
			.element(rendered.getByTestId('bridge-file-viewer-shell'))
			.toHaveAttribute('data-worktree-open-file-state', 'ready');
		await expect.element(rendered.getByText(existingFileContent, { exact: true })).toBeVisible();
		if (publishWorkerMessages === null)
			throw new Error('Expected the real File worker message publisher');
		const publisher: (messages: readonly BridgeWorkerServerToMainMessage[]) => void =
			publishWorkerMessages;
		await actUpdateAndWaitForBridgeFileViewerWorkerPublication((): void =>
			publisher([
				{
					wireVersion: 1,
					direction: 'serverWorkerToMain',
					transferDescriptors: [],
					kind: 'viewRecoveryStatus',
					view: { kind: 'file.metadata', subscriptionId: 'browser-file-metadata-subscription' },
					status: 'failedRetryable',
				} satisfies BridgeWorkerViewRecoveryStatusEvent,
			]),
		);
		for (const region of ['file-tree', 'file-content']) {
			const element = document.querySelector(`[data-bridge-region="${region}"]`);
			expect(element?.getAttribute('data-presentation-state')).toBe('failed');
			expect(element?.querySelectorAll('button[aria-label="Retry"]')).toHaveLength(0);
			expect(element?.querySelector('[data-slot="skeleton"]')).toBeNull();
		}
		await actUpdateAndWaitForBridgeFileViewerWorkerPublication((): void => {
			const button = rendered.getByRole('button', { name: 'Retry' }).first().element();
			if (!(button instanceof HTMLElement)) throw new Error('Expected File Retry button');
			button.click();
		});
		await waitForBridgeFileViewerWorkerMessageDrain();
		expect(
			dispatchedMessages
				.filter(({ command }) => command === 'viewRecoveryRetry' || command === 'fileRefreshRetry')
				.map(({ command }) => command),
		).toEqual(['viewRecoveryRetry', 'fileRefreshRetry']);
		await expect.element(rendered.getByText(existingFileContent, { exact: true })).toBeVisible();
		expect(
			getComputedStyle(rendered.getByTestId('bridge-file-viewer-code-view').element()).visibility,
		).toBe('visible');
		await page.screenshot({ path: '../../../tmp/bridgeweb-file-view-retry.png' });
	});
});

function BridgeFileViewerRenderSnapshotProbe(): ReactElement {
	useBridgeFileViewerRenderSnapshotController({ selection: null });
	return <div />;
}

import { act, type ReactElement } from 'react';
import { afterAll, afterEach, beforeEach, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise the production File layout.
import '../app/bridge-app.css';
import type { BridgeMarkdownRenderWorkerClient } from '../app/markdown/worker/bridge-markdown-render-worker-client.js';
import {
	createBridgeMarkdownRenderModuleWorkerFactory,
	createBridgeMarkdownRenderWebWorkerClient,
} from '../app/markdown/worker/bridge-markdown-render-worker-transport.js';
import type { BridgeProductFileContentDescriptor } from '../core/comm-worker/bridge-product-content-contracts.js';
import { waitForBridgeReviewRecoveryDomState } from '../review-viewer/test-support/bridge-review-recovery-dom-state.test-support.js';
import { terminateBridgePierreWorkerPoolSingletonForTest } from '../review-viewer/workers/pierre/bridge-pierre-worker-pool.js';
import {
	BridgeFileViewerBrowserHarnessApp,
	type BridgeFileViewerBrowserHarnessAppProps,
} from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcomeForContent,
} from './bridge-file-viewer-browser-test-batches.js';
import { fileNavigationCommandForPath } from './bridge-file-viewer-browser-test-fixtures.js';
import {
	installBridgeFileViewerNoopResizeObserver,
	waitForBridgeFileViewerWorkerMessageDrain,
} from './bridge-file-viewer-browser-test-harness.js';

const originalResizeObserver = globalThis.ResizeObserver;
beforeEach((): void => installBridgeFileViewerNoopResizeObserver());
afterAll((): void => {
	Object.assign(globalThis, { ResizeObserver: originalResizeObserver });
});

afterEach(async (): Promise<void> => {
	await act(async (): Promise<void> => {
		await waitForBridgeFileViewerWorkerMessageDrain();
		await cleanup();
	});
	terminateBridgePierreWorkerPoolSingletonForTest();
});

test.each([{ persistentFailure: false }, { persistentFailure: true }])(
	'File tree survives Markdown settlement and still opens code (persistent failure $persistentFailure)',
	async ({ persistentFailure }): Promise<void> => {
		const codeContent = 'let stableTree = true;\n';
		const markdownContent = '# Stable tree document\n';
		const codeDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: codeContent,
			descriptorId: 'stable-tree-code',
			fileId: 'stable-code',
			path: 'First.swift',
		});
		const markdownDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: markdownContent,
			descriptorId: 'stable-tree-markdown',
			fileId: 'stable-markdown',
			path: 'Readme.md',
		});
		const markdownWorkerClient = createBridgeMarkdownRenderWebWorkerClient({
			workerFactory: createBridgeMarkdownRenderModuleWorkerFactory(),
		});
		if (markdownWorkerClient === null) throw new Error('Expected the real Markdown worker.');
		let releaseMarkdown: (() => void) | undefined;
		const markdownSettlement = new Promise<void>((resolve): void => {
			releaseMarkdown = resolve;
		});
		const controlledMarkdownClient: BridgeMarkdownRenderWorkerClient = {
			startRender: (request) => {
				const task = markdownWorkerClient.startRender(request);
				return { ...task, completed: markdownSettlement.then(() => task.completed) };
			},
			abort: markdownWorkerClient.abort,
			dispose: markdownWorkerClient.dispose,
		};
		const appProps = {
			codeViewWorkerPoolEnabled: false,
			initialFileBatch: makeBrowserFileBatchWithDescriptors(
				'open',
				codeDescriptor,
				markdownDescriptor,
			),
			markdownWorkerClient: controlledMarkdownClient,
			navigationCommand: fileNavigationCommandForPath('First.swift'),
			fileProductSession: {
				readContent: async ({
					descriptor,
				}: {
					readonly descriptor: BridgeProductFileContentDescriptor;
				}): Promise<string> =>
					descriptor.fileId === 'stable-markdown' ? markdownContent : codeContent,
			},
		} satisfies BridgeFileViewerBrowserHarnessAppProps;
		const paneFailedStart = { kind: 'failedStart', cause: 'configurationUnavailable' } as const;
		const summaryCounts: number[] = [];
		const summaryObserver = new MutationObserver((): void => {
			summaryCounts.push(
				document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]').length,
			);
		});
		try {
			const rendered = await render(<TreeLifetimeFixture {...appProps} />);
			await act(async (): Promise<void> => {
				await waitForBridgeFileViewerWorkerMessageDrain();
			});
			const originalTree = await waitForBridgeReviewRecoveryDomState({
				readState: (): Element | null =>
					document.querySelector(
						'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
					),
				isExpected: (tree): boolean =>
					tree?.shadowRoot?.querySelector('button[data-item-path="Readme.md"]') instanceof
					HTMLButtonElement,
			});
			if (originalTree === null) throw new Error('Expected the mounted File tree.');
			if (persistentFailure) {
				await act(async (): Promise<void> => {
					await rendered.rerender(
						<TreeLifetimeFixture {...appProps} paneFailedStart={paneFailedStart} />,
					);
				});
				expect(
					document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]'),
				).toHaveLength(1);
				summaryObserver.observe(document.body, { childList: true, subtree: true });
			}
			await act(async (): Promise<void> => {
				requireTreeButton(originalTree, 'Readme.md').click();
			});
			await waitForBridgeReviewRecoveryDomState({
				readState: (): string | null =>
					document
						.querySelector('[data-bridge-region="markdown"]')
						?.getAttribute('data-presentation-state') ?? null,
				isExpected: (state): boolean => state === (persistentFailure ? 'failed' : 'loading'),
			});
			expect(
				document.querySelector(
					'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
				),
			).toBe(originalTree);
			expect(document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]')).toHaveLength(
				persistentFailure ? 1 : 0,
			);
			await act(async (): Promise<void> => {
				releaseMarkdown?.();
			});
			await waitForBridgeReviewRecoveryDomState({
				readState: (): string =>
					document.querySelector('[data-testid="bridge-markdown-canvas"] h1')?.textContent ?? '',
				isExpected: (text): boolean => text === 'Stable tree document',
			});
			expect(
				document.querySelector(
					'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
				),
			).toBe(originalTree);
			await act(async (): Promise<void> => {
				await rendered.rerender(
					<TreeLifetimeFixture {...appProps} paneFailedStart={paneFailedStart} />,
				);
			});
			await waitForBridgeReviewRecoveryDomState({
				readState: (): string | null =>
					document
						.querySelector('[data-bridge-region="file-tree"]')
						?.getAttribute('data-presentation-state') ?? null,
				isExpected: (state): boolean => state === 'failed',
			});
			expect(
				document.querySelector(
					'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
				),
			).toBe(originalTree);
			expect(document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]')).toHaveLength(
				1,
			);
			if (!persistentFailure) {
				await act(async (): Promise<void> => {
					await rendered.rerender(<TreeLifetimeFixture {...appProps} />);
				});
			}
			await act(async (): Promise<void> => {
				requireTreeButton(originalTree, 'First.swift').click();
			});
			await waitForBridgeReviewRecoveryDomState({
				readState: (): string | null =>
					document
						.querySelector('[data-testid="bridge-file-viewer-code-canvas"]')
						?.getAttribute('data-worktree-open-file-path') ?? null,
				isExpected: (path): boolean => path === 'First.swift',
			});
			expect(
				document.querySelector(
					'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
				),
			).toBe(originalTree);
			if (persistentFailure) {
				expect(
					document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]'),
				).toHaveLength(1);
				expect(summaryCounts.length).toBeGreaterThan(0);
				expect(summaryCounts.every((count): boolean => count === 1)).toBe(true);
				await act(async (): Promise<void> => {
					await page.screenshot({ path: '../../../tmp/g1-F-stable-tree-persistent-failure.png' });
				});
			}
		} finally {
			summaryObserver.disconnect();
			releaseMarkdown?.();
			await act(async (): Promise<void> => {
				await cleanup();
			});
			markdownWorkerClient.dispose();
		}
	},
);

function requireTreeButton(tree: Element, path: string): HTMLButtonElement {
	const button = tree.shadowRoot?.querySelector(`button[data-item-path="${path}"]`);
	if (!(button instanceof HTMLButtonElement))
		throw new Error(`Expected the mounted tree row ${path}.`);
	return button;
}

function TreeLifetimeFixture(props: BridgeFileViewerBrowserHarnessAppProps): ReactElement {
	return (
		<div className="h-[600px] w-[960px]">
			<BridgeFileViewerBrowserHarnessApp {...props} />
		</div>
	);
}

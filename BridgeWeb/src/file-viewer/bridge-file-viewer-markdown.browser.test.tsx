import {
	afterAll,
	afterEach,
	beforeEach,
	describe,
	expect,
	test,
	vi,
	type TestContext,
} from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the product Markdown styles.
import '../app/bridge-app.css';
import { createBridgeMermaidRenderer } from '../app/markdown/bridge-mermaid-renderer.js';
import {
	createBridgeMarkdownRenderWorkerClient,
	type BridgeMarkdownRenderWorkerClient,
	type BridgeMarkdownRenderWorkerTask,
	type BridgeMarkdownRenderWorkerTransport,
} from '../app/markdown/worker/bridge-markdown-render-worker-client.js';
import {
	identityFromMarkdownRenderWorkerRequest,
	type BridgeMarkdownRenderWorkerRequest,
} from '../app/markdown/worker/bridge-markdown-render-worker-rpc.js';
import {
	createBridgeMarkdownRenderModuleWorkerFactory,
	createBridgeMarkdownRenderWebWorkerClient,
} from '../app/markdown/worker/bridge-markdown-render-worker-transport.js';
import { createBridgeProductDeferred } from '../core/comm-worker/bridge-product-async-queue.js';
import type {
	BridgeWorkerMainToServerMessage,
	BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import { terminateBridgePierreWorkerPoolSingletonForTest } from '../review-viewer/workers/pierre/bridge-pierre-worker-pool.js';
import { BridgeFileViewerBrowserHarnessApp as BridgeFileViewerApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcomeForContent,
} from './bridge-file-viewer-browser-test-batches.js';
import { fileNavigationCommandForPath } from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actFrame,
	actClick,
	actUpdate,
	actUpdateAndWaitForBridgeFileViewerWorkerPublication,
	installBridgeFileViewerNoopResizeObserver,
} from './bridge-file-viewer-browser-test-harness.js';
import {
	createHeldFileMarkdownReadiness,
	observeFileMarkdownArticle,
	observeFileMermaidReady,
	recordFileMarkdownWaits,
} from './bridge-file-viewer-markdown-ready.browser.test-support.js';

const originalResizeObserver = globalThis.ResizeObserver;

describe('BridgeFileViewerApp Markdown Browser Mode', () => {
	beforeEach(() => {
		installBridgeFileViewerNoopResizeObserver();
	});

	afterEach(async () => {
		await actUpdate(async (): Promise<void> => cleanup());
		await actFrame();
		document.body.replaceChildren();
		terminateBridgePierreWorkerPoolSingletonForTest();
	});

	afterAll(() => {
		Object.assign(globalThis, { ResizeObserver: originalResizeObserver });
	});

	test('mounts the complete semantic Markdown document instead of Pierre', async (testContext: TestContext): Promise<void> => {
		const beginWait = recordFileMarkdownWaits(testContext);
		const markdownContent = [
			'# File Markdown proof',
			'',
			'> Complete current document',
			'',
			'- Heading',
			'- List',
			'',
			'| Surface | Projection |',
			'| --- | --- |',
			'| File | Rendered |',
			'',
			'[Inert reference](https://example.com/escape)',
			'',
			'```swift',
			'let markdownProof: String = "This intentionally long Swift line proves horizontal code overflow rather than wrapping the source text."',
			'```',
			'',
			'```mermaid',
			'flowchart LR',
			'File --> Markdown',
			'```',
			'',
		].join('\n');
		beginWait('Markdown descriptor preparation');
		const markdownDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: markdownContent,
			descriptorId: 'file-markdown-browser-content',
			fileId: 'file-markdown-browser',
			path: 'docs/markdown-proof.md',
		});
		const markdownWorkerClient = createBridgeMarkdownRenderWebWorkerClient({
			workerFactory: createBridgeMarkdownRenderModuleWorkerFactory(),
		});
		if (markdownWorkerClient === null) {
			throw new Error('Expected Browser Mode to support the Markdown worker.');
		}
		const readiness = createHeldFileMarkdownReadiness({
			workerClient: markdownWorkerClient,
			mermaidRenderer: createBridgeMermaidRenderer(),
		});

		try {
			beginWait('File Viewer mount');
			await render(
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', markdownDescriptor)}
					markdownWorkerClient={readiness.workerClient}
					mermaidRenderer={readiness.mermaidRenderer}
					navigationCommand={fileNavigationCommandForPath('docs/markdown-proof.md')}
					fileProductSession={{
						readContent: async (): Promise<string> => markdownContent,
						onWorkerCommand: readiness.observeCommand,
					}}
				/>,
			);

			beginWait('Markdown worker start');
			const markdownTask = await readiness.workerStarted;
			beginWait('real Markdown worker completion');
			const completion = await readiness.workerCompleted;
			expect(completion.status).toBe('success');
			if (completion.status !== 'success') throw new Error('Expected real Markdown completion.');
			await actUpdate(async (): Promise<void> => {
				beginWait('held Markdown worker completion delivery');
				readiness.releaseWorker();
				await markdownTask.completed;
			});
			beginWait('request-correlated Markdown article installation');
			const article = await observeFileMarkdownArticle(markdownTask);
			const diagramId = completion.response.mermaidDiagrams[0]?.id;
			if (diagramId === undefined) throw new Error('Expected the Markdown Mermaid diagram.');
			await actUpdate(async (): Promise<void> => {
				beginWait('request-correlated Markdown painted publication');
				await readiness.waitForPainted(markdownTask, article);
				beginWait(`Mermaid READY for diagram ${diagramId}`);
				await observeFileMermaidReady({
					article,
					task: markdownTask,
					diagramId,
					release: readiness.releaseMermaid,
				});
			});

			beginWait('semantic Markdown assertions after readiness');
			const markdownCanvas = requireHTMLElement(
				document.querySelector('[data-testid="bridge-markdown-canvas"]'),
			);
			expect(markdownCanvas.querySelector('h1')?.textContent).toBe('File Markdown proof');
			expect(
				document
					.querySelector('[data-worktree-open-file-state]')
					?.getAttribute('data-worktree-open-file-state'),
			).toBe('ready');
			const inertLink = requireHTMLElement(markdownCanvas.querySelector('a'));
			const codeBlock = requireHTMLElement(
				markdownCanvas.querySelector('.bridge-markdown-code-block'),
			);
			const swiftCode = requireHTMLElement(codeBlock.querySelector('.bridge-markdown-code-lines'));
			const highlightedTokens = Array.from(
				markdownCanvas.querySelectorAll<HTMLElement>(
					'.bridge-markdown-code-lines span[style*="color"]',
				),
			);
			const highlightedColors = new Set(
				highlightedTokens
					.map((token): string => token.style.color)
					.filter((color): boolean => color.length > 0),
			);
			const diagram = markdownCanvas.querySelector('svg[role="img"]');

			expect(markdownCanvas.textContent).toContain('File Markdown proof');
			expect(markdownCanvas.querySelector('blockquote')).not.toBeNull();
			expect(markdownCanvas.querySelector('ul')).not.toBeNull();
			expect(markdownCanvas.querySelector('table')).not.toBeNull();
			expect(markdownCanvas.querySelector('th')?.textContent).toBe('Surface');
			expect(markdownCanvas.querySelector('tr[data-bridge-markdown-target] td')?.textContent).toBe(
				'File',
			);
			expect(inertLink.hasAttribute('href')).toBe(false);
			expect(swiftCode.textContent).toContain('let markdownProof: String');
			expect(highlightedColors.size).toBeGreaterThan(1);
			expect(getComputedStyle(codeBlock).overflowX).toBe('auto');
			expect(diagram?.getAttribute('aria-label')).toBe('Diagram 1 in docs/markdown-proof.md');
			expect(document.querySelector('[data-testid="bridge-file-viewer-code-view"]')).toBeNull();
		} finally {
			readiness.close();
			markdownWorkerClient.dispose();
		}
	});

	test('preserves the rendered document and Mermaid SVG across File search rerenders', async () => {
		const markdownContent =
			'# Stable Markdown\n\n```mermaid\nflowchart LR\nFile --> Markdown\n```\n';
		const markdownDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: markdownContent,
			descriptorId: 'stable-markdown-content',
			fileId: 'stable-markdown',
			path: 'docs/stable.md',
		});
		const markdownWorkerClient = createBridgeMarkdownRenderWebWorkerClient({
			workerFactory: createBridgeMarkdownRenderModuleWorkerFactory(),
		});
		if (markdownWorkerClient === null) throw new Error('expected markdown worker client');

		try {
			await render(
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', markdownDescriptor)}
					markdownWorkerClient={markdownWorkerClient}
					mermaidRenderer={createBridgeMermaidRenderer()}
					navigationCommand={fileNavigationCommandForPath('docs/stable.md')}
					fileProductSession={{ readContent: async (): Promise<string> => markdownContent }}
				/>,
			);
			await waitForMarkdownOpenFileState('ready');
			await waitForMarkdownSelector('[data-bridge-mermaid-state="ready"] svg');
			const originalCanvas = requireHTMLElement(
				document.querySelector('[data-testid="bridge-markdown-canvas"]'),
			);
			const originalSvg = originalCanvas.querySelector('svg');
			const markdownScrollOwner = originalCanvas.parentElement;
			if (!(markdownScrollOwner instanceof HTMLElement)) {
				throw new Error('Expected the Markdown scroll owner.');
			}

			const searchToggle = requireHTMLElement(
				document.querySelector('[data-testid="worktree-file-search-toggle"]'),
			);
			await actClick(searchToggle);
			await actClick(searchToggle);
			await actFrame();

			expect(document.querySelector('[data-testid="bridge-markdown-canvas"]')).toBe(originalCanvas);
			expect(originalCanvas.parentElement).toBe(markdownScrollOwner);
			expect(originalCanvas.querySelector('svg')).toBe(originalSvg);
			expect(originalCanvas.querySelector('[data-bridge-mermaid-state="ready"]')).not.toBeNull();
			expect(
				document.querySelector(
					'[data-bridge-region="markdown"][data-presentation-state="loading"]',
				),
			).toBeNull();
		} finally {
			markdownWorkerClient.dispose();
		}
	});

	test('aborts in-flight Markdown preparation when retained File view becomes inactive', async () => {
		const markdownContent = '# Suspended Markdown\n';
		const markdownDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: markdownContent,
			descriptorId: 'suspended-markdown-content',
			fileId: 'suspended-markdown',
			path: 'docs/suspended.md',
		});
		const sendRenderRequest = vi.fn<BridgeMarkdownRenderWorkerTransport['send']>(
			(): Promise<unknown> => new Promise<unknown>(() => {}),
		);
		const abortRenderRequest = vi.fn<NonNullable<BridgeMarkdownRenderWorkerTransport['abort']>>();
		const markdownWorkerClient = createBridgeMarkdownRenderWorkerClient({
			transport: { send: sendRenderRequest, abort: abortRenderRequest },
		});
		const activeApp = (
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', markdownDescriptor)}
				isActive={true}
				markdownWorkerClient={markdownWorkerClient}
				navigationCommand={fileNavigationCommandForPath('docs/suspended.md')}
				fileProductSession={{ readContent: async (): Promise<string> => markdownContent }}
			/>
		);

		try {
			const rendered = await render(activeApp);
			await waitForMarkdownOpenFileState('ready');
			await waitForMarkdownSelector(
				'[data-bridge-region="markdown"][data-presentation-state="loading"]',
			);
			expect(sendRenderRequest).toHaveBeenCalledOnce();

			await rendered.rerender(
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', markdownDescriptor)}
					isActive={false}
					markdownWorkerClient={markdownWorkerClient}
					navigationCommand={fileNavigationCommandForPath('docs/suspended.md')}
					fileProductSession={{ readContent: async (): Promise<string> => markdownContent }}
				/>,
			);

			expect(abortRenderRequest).toHaveBeenCalledOnce();
			expect(sendRenderRequest).toHaveBeenCalledOnce();
		} finally {
			markdownWorkerClient.dispose();
		}
	});

	test('recovers a failed File Markdown render through the visible Retry action', async () => {
		// Arrange
		const markdownContent = '# Retry Markdown\n';
		const markdownDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: markdownContent,
			descriptorId: 'retry-markdown-content',
			fileId: 'retry-markdown',
			path: 'docs/retry.md',
		});
		let sendCount = 0;
		const transport: BridgeMarkdownRenderWorkerTransport = {
			send: async (request: BridgeMarkdownRenderWorkerRequest): Promise<unknown> => {
				sendCount += 1;
				if (sendCount === 1) {
					throw new Error('Expected first render failure');
				}
				return {
					schemaVersion: 1,
					method: request.method,
					ok: true,
					...identityFromMarkdownRenderWorkerRequest(request),
					htmlCandidate: '<h1>Recovered Markdown</h1>',
					mermaidDiagrams: [],
					annotationTargets: [],
					metrics: {
						durationMilliseconds: 1,
						inputBytes: markdownContent.length,
						outputBytes: 27,
						mermaidDiagramCount: 0,
					},
				};
			},
		};
		const markdownWorkerClient = createBridgeMarkdownRenderWorkerClient({
			transport,
			createRequestId: (): string => `retry-${(sendCount + 1).toString()}`,
		});

		try {
			await render(
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', markdownDescriptor)}
					markdownWorkerClient={markdownWorkerClient}
					navigationCommand={fileNavigationCommandForPath('docs/retry.md')}
					fileProductSession={{ readContent: async (): Promise<string> => markdownContent }}
				/>,
			);
			await waitForMarkdownOpenFileState('ready');
			await waitForMarkdownSelector('[role="alert"]');

			// Act
			const retryButton = requireHTMLElement(document.querySelector('[role="alert"] button'));
			await actClick(retryButton);

			// Assert
			await waitForMarkdownSelector('[data-testid="bridge-markdown-canvas"] h1');
			expect(document.querySelector('[data-testid="bridge-markdown-canvas"] h1')?.textContent).toBe(
				'Recovered Markdown',
			);
			expect(document.querySelector('[role="alert"]')).toBeNull();
			expect(sendCount).toBe(2);
		} finally {
			markdownWorkerClient.dispose();
		}
	});

	test('a File surface failure over Markdown retries File recovery and retains its document', async (): Promise<void> => {
		const markdownContent = '# Retained File Markdown\n';
		const markdownRenderStarted = createBridgeProductDeferred<BridgeMarkdownRenderWorkerTask>();
		const markdownWorkerCompleted = createBridgeProductDeferred<void>();
		const releaseMarkdownCompletion = createBridgeProductDeferred<void>();
		const initialDocumentPainted = createBridgeProductDeferred<void>();
		const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: markdownContent,
			path: 'docs/retained.md',
		});
		const commands: BridgeWorkerMainToServerMessage[] = [];
		const workerPublication: {
			publish: ((messages: readonly BridgeWorkerServerToMainMessage[]) => void) | null;
		} = { publish: null };
		const realMarkdownWorkerClient = createBridgeMarkdownRenderWebWorkerClient({
			workerFactory: createBridgeMarkdownRenderModuleWorkerFactory(),
		});
		if (realMarkdownWorkerClient === null) throw new Error('Expected the Markdown worker.');
		const markdownWorkerClient: BridgeMarkdownRenderWorkerClient = {
			...realMarkdownWorkerClient,
			startRender: (props): BridgeMarkdownRenderWorkerTask => {
				const task = realMarkdownWorkerClient.startRender(props);
				const heldTask: BridgeMarkdownRenderWorkerTask = {
					...task,
					completed: task.completed.then(async (completion) => {
						markdownWorkerCompleted.resolve();
						await releaseMarkdownCompletion.promise;
						return completion;
					}),
				};
				markdownRenderStarted.resolve(heldTask);
				return heldTask;
			},
		};
		try {
			const rendered = await render(
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', descriptor)}
					markdownWorkerClient={markdownWorkerClient}
					navigationCommand={fileNavigationCommandForPath('docs/retained.md')}
					fileProductSession={{
						readContent: async (): Promise<string> => markdownContent,
						onWorkerCommand: (command): void => {
							commands.push(command);
							if (
								command.command === 'renderDisposition' &&
								command.receipts.some(
									(receipt) =>
										receipt.kind === 'render.disposition' && receipt.disposition === 'painted',
								)
							)
								initialDocumentPainted.resolve();
						},
						onWorkerMessagesPublisher: (publish): void => {
							workerPublication.publish = publish;
						},
					}}
				/>,
			);
			const markdownRender = await markdownRenderStarted.promise;
			await markdownWorkerCompleted.promise;
			await actUpdate(async (): Promise<void> => {
				releaseMarkdownCompletion.resolve();
				expect((await markdownRender.completed).status).toBe('success');
			});
			// useBridgeMarkdownAnnotationLayout queues one measurement rAF when annotation targets mount.
			await actFrame();
			await initialDocumentPainted.promise;
			await waitForMarkdownOpenFileState('ready');
			await waitForMarkdownSelector('[data-testid="bridge-markdown-canvas"] h1');
			await expect
				.element(rendered.getByRole('heading', { name: 'Retained File Markdown' }))
				.toBeVisible();
			const canvas = rendered.getByTestId('bridge-markdown-canvas').element();
			await actUpdateAndWaitForBridgeFileViewerWorkerPublication((): void => {
				if (workerPublication.publish === null)
					throw new Error('Expected the File message publisher.');
				workerPublication.publish([
					{
						wireVersion: 1,
						direction: 'serverWorkerToMain',
						transferDescriptors: [],
						kind: 'viewRecoveryStatus',
						view: { kind: 'file.metadata', subscriptionId: 'browser-file-metadata-subscription' },
						status: 'failedRetryable',
					},
				]);
			});
			await expect.element(rendered.getByRole('alert')).toBeVisible();
			expect(rendered.getByRole('button', { name: 'Retry', exact: true }).all()).toHaveLength(1);
			await actUpdateAndWaitForBridgeFileViewerWorkerPublication((): void => {
				requireHTMLElement(
					rendered.getByRole('button', { name: 'Retry', exact: true }).element(),
				).click();
			});
			expect(
				commands
					.filter(
						({ command }) => command === 'viewRecoveryRetry' || command === 'fileRefreshRetry',
					)
					.map(({ command }) => command),
			).toEqual(['viewRecoveryRetry', 'fileRefreshRetry']);
			expect(rendered.getByTestId('bridge-markdown-canvas').element()).toBe(canvas);
			await expect
				.element(rendered.getByRole('heading', { name: 'Retained File Markdown' }))
				.toBeVisible();
		} finally {
			releaseMarkdownCompletion.resolve();
			markdownWorkerClient.dispose();
		}
	});

	test('unmounts a pending Markdown publication after its readiness tap closes', async (testContext: TestContext): Promise<void> => {
		const beginWait = recordFileMarkdownWaits(testContext);
		const markdownContent = '# Unmounted Markdown\n';
		beginWait('unmount regression descriptor preparation');
		const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: markdownContent,
			fileId: 'file-unmounted-markdown',
			path: 'docs/unmounted.md',
		});
		const workerClient = createBridgeMarkdownRenderWebWorkerClient({
			workerFactory: createBridgeMarkdownRenderModuleWorkerFactory(),
		});
		if (workerClient === null) throw new Error('Expected the real Markdown worker.');
		const readiness = createHeldFileMarkdownReadiness({
			workerClient,
			mermaidRenderer: createBridgeMermaidRenderer(),
		});
		const retiredPublication = createBridgeProductDeferred<BridgeWorkerMainToServerMessage>();
		let readinessClosed = false;
		try {
			beginWait('pending-publication File Viewer mount');
			const rendered = await render(
				<BridgeFileViewerApp
					codeViewWorkerPoolEnabled={false}
					initialFileBatch={makeBrowserFileBatchWithDescriptors('open', descriptor)}
					markdownWorkerClient={readiness.workerClient}
					navigationCommand={fileNavigationCommandForPath('docs/unmounted.md')}
					fileProductSession={{
						readContent: async (): Promise<string> => markdownContent,
						onWorkerCommand: (command: BridgeWorkerMainToServerMessage): void => {
							if (
								readinessClosed &&
								command.command === 'renderDisposition' &&
								command.receipts.some(
									(receipt): boolean =>
										receipt.kind === 'render.disposition' &&
										receipt.disposition === 'superseded' &&
										receipt.itemId === 'file-unmounted-markdown',
								)
							)
								retiredPublication.resolve(command);
							readiness.observeCommand(command);
						},
					}}
				/>,
			);
			beginWait('pending-publication Markdown worker start');
			const task = await readiness.workerStarted;
			beginWait('pending-publication real Markdown worker completion');
			expect((await readiness.workerCompleted).status).toBe('success');
			beginWait('pending-publication unmount after readiness close');
			await expect(
				actUpdate(async (): Promise<void> => {
					readiness.close();
					readinessClosed = true;
					await rendered.unmount();
				}),
			).resolves.toBeUndefined();
			beginWait('closed-tap publication retirement on unmount');
			const retirement = await retiredPublication.promise;
			expect(retirement.command).toBe('renderDisposition');
			expect(task.identity.sourceIdentity.fileId).toBe('file-unmounted-markdown');
			expect(document.querySelector('[data-testid="bridge-file-viewer-shell"]')).toBeNull();
		} finally {
			readiness.close();
			workerClient.dispose();
		}
	});
});

function requireHTMLElement(element: Element | null): HTMLElement {
	if (!(element instanceof HTMLElement)) {
		throw new Error('Expected an HTMLElement.');
	}
	return element;
}

async function waitForMarkdownOpenFileState(expectedState: string): Promise<void> {
	const currentState = document
		.querySelector('[data-worktree-open-file-state]')
		?.getAttribute('data-worktree-open-file-state');
	if (currentState === expectedState) return;
	await actFrame();
	await waitForMarkdownOpenFileState(expectedState);
}

async function waitForMarkdownSelector(selector: string): Promise<void> {
	if (document.querySelector(selector) !== null) {
		return;
	}
	const terminalFailure =
		selector === '[role="alert"]'
			? null
			: (document.querySelector('[data-bridge-region="markdown"][data-presentation-state="failed"]')
					?.textContent ??
				document.querySelector('[data-bridge-mermaid-state="failed"]')?.textContent);
	if (terminalFailure !== null && terminalFailure !== undefined) {
		throw new Error(
			`Expected Markdown selector to appear: ${selector}; terminal failure: ${terminalFailure}`,
		);
	}
	await actFrame();
	await waitForMarkdownSelector(selector);
}

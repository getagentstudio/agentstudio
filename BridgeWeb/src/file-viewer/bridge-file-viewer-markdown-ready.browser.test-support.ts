import type { BridgeMermaidRenderer } from '../app/markdown/bridge-mermaid-renderer.js';
import type {
	BridgeMarkdownRenderWorkerClient,
	BridgeMarkdownRenderWorkerClientCompletion,
	BridgeMarkdownRenderWorkerTask,
	StartBridgeMarkdownRenderWorkerTaskProps,
} from '../app/markdown/worker/bridge-markdown-render-worker-client.js';
import { createBridgeProductDeferred } from '../core/comm-worker/bridge-product-async-queue.js';
import type { BridgeWorkerMainToServerMessage } from '../core/comm-worker/bridge-worker-contracts.js';
import type { BridgeWorkerRenderDispositionReceipt } from '../core/comm-worker/bridge-worker-render-fulfillment.js';
import { BridgeProductTestFactRecorder } from '../core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';

interface HeldFileMarkdownReadiness {
	readonly workerClient: BridgeMarkdownRenderWorkerClient;
	readonly mermaidRenderer: BridgeMermaidRenderer;
	readonly workerStarted: Promise<BridgeMarkdownRenderWorkerTask>;
	readonly workerCompleted: Promise<BridgeMarkdownRenderWorkerClientCompletion>;
	readonly releaseWorker: () => void;
	readonly releaseMermaid: () => void;
	readonly observeCommand: (message: BridgeWorkerMainToServerMessage) => void;
	readonly waitForPainted: (
		task: BridgeMarkdownRenderWorkerTask,
		article: HTMLElement,
	) => Promise<void>;
	readonly close: () => void;
}

/** Hold delivery, preserving the real worker result and real Mermaid SVG. */
export function createHeldFileMarkdownReadiness(props: {
	readonly workerClient: BridgeMarkdownRenderWorkerClient;
	readonly mermaidRenderer: BridgeMermaidRenderer;
}): HeldFileMarkdownReadiness {
	const workerStarted = createBridgeProductDeferred<BridgeMarkdownRenderWorkerTask>();
	const workerCompleted = createBridgeProductDeferred<BridgeMarkdownRenderWorkerClientCompletion>();
	const releaseWorker = createBridgeProductDeferred<void>();
	const releaseMermaid = createBridgeProductDeferred<void>();
	const receipts = new BridgeProductTestFactRecorder<BridgeWorkerRenderDispositionReceipt>();
	const workerClient: BridgeMarkdownRenderWorkerClient = {
		...props.workerClient,
		startRender: (
			request: StartBridgeMarkdownRenderWorkerTaskProps,
		): BridgeMarkdownRenderWorkerTask => {
			const task = props.workerClient.startRender(request);
			const heldTask = {
				...task,
				completed: task.completed.then(
					async (
						completion: BridgeMarkdownRenderWorkerClientCompletion,
					): Promise<BridgeMarkdownRenderWorkerClientCompletion> => {
						workerCompleted.resolve(completion);
						await releaseWorker.promise;
						return completion;
					},
				),
			} satisfies BridgeMarkdownRenderWorkerTask;
			workerStarted.resolve(heldTask);
			return heldTask;
		},
	};
	const mermaidRenderer: BridgeMermaidRenderer = {
		render: async (request: Parameters<BridgeMermaidRenderer['render']>[0]): Promise<string> => {
			const svg = await props.mermaidRenderer.render(request);
			await releaseMermaid.promise;
			return svg;
		},
	};
	return {
		workerClient,
		mermaidRenderer,
		workerStarted: workerStarted.promise,
		workerCompleted: workerCompleted.promise,
		releaseWorker: (): void => releaseWorker.resolve(),
		releaseMermaid: (): void => releaseMermaid.resolve(),
		observeCommand: (message: BridgeWorkerMainToServerMessage): void => {
			if (message.command !== 'renderDisposition') return;
			for (const receipt of message.receipts) {
				if (receipt.kind === 'render.disposition') receipts.record(receipt);
			}
		},
		waitForPainted: async (
			task: BridgeMarkdownRenderWorkerTask,
			article: HTMLElement,
		): Promise<void> => {
			const receipt = await receipts.waitFor(
				(candidate: BridgeWorkerRenderDispositionReceipt): boolean =>
					candidate.surface === task.identity.sourceIdentity.surface &&
					candidate.itemId === task.identity.sourceIdentity.fileId &&
					(candidate.disposition === 'painted' ||
						candidate.disposition === 'rejected' ||
						candidate.disposition === 'superseded'),
			);
			if (
				receipt.disposition !== 'painted' ||
				!articleMatchesMarkdownRequest(article, task) ||
				article.getAttribute('data-bridge-painted-publication-id') !== receipt.publicationId
			) {
				throw new Error(
					`Markdown request ${task.identity.requestId} lacks its painted publication.`,
				);
			}
		},
		close: (): void => {
			releaseWorker.resolve();
			releaseMermaid.resolve();
			receipts.close(new Error('File Markdown readiness observation closed.'));
		},
	};
}

function articleMatchesMarkdownRequest(
	article: HTMLElement,
	task: BridgeMarkdownRenderWorkerTask,
): boolean {
	const identity = task.identity;
	const source = identity.sourceIdentity;
	return (
		article.isConnected &&
		article.dataset['bridgeMarkdownRequestId'] === identity.requestId &&
		article.dataset['bridgeMarkdownContentCacheKey'] === identity.contentCacheKey &&
		article.dataset['bridgeMarkdownContentHash'] === identity.contentHash &&
		article.dataset['bridgeMarkdownFileId'] === source.fileId &&
		article.dataset['bridgeMarkdownFileVersion'] === source.fileVersion.toString() &&
		article.dataset['bridgeMarkdownSourceGeneration'] === source.sourceGeneration.toString() &&
		article.dataset['bridgeMarkdownSourceId'] === source.sourceId &&
		article.dataset['bridgeMarkdownSourcePath'] === task.request.sourcePath
	);
}

export async function observeFileMarkdownArticle(
	task: BridgeMarkdownRenderWorkerTask,
): Promise<HTMLElement> {
	const articleReady = createBridgeProductDeferred<HTMLElement>();
	const readArticle = (): void => {
		const article = document.querySelector(
			`[data-bridge-markdown-request-id="${CSS.escape(task.identity.requestId)}"]`,
		);
		if (article instanceof HTMLElement && articleMatchesMarkdownRequest(article, task)) {
			articleReady.resolve(article);
		}
		const failure = document.querySelector(
			'[data-bridge-region="markdown"][data-presentation-state="failed"]',
		);
		if (failure !== null) articleReady.reject(new Error(`Markdown failed: ${failure.textContent}`));
	};
	const observer = new MutationObserver(readArticle);
	observer.observe(document.body, { attributes: true, childList: true, subtree: true });
	try {
		readArticle();
		return await articleReady.promise;
	} finally {
		observer.disconnect();
	}
}

/** Arm before release; the owner inserts SVG and stamps READY without a React commit. */
export async function observeFileMermaidReady(props: {
	readonly article: HTMLElement;
	readonly task: BridgeMarkdownRenderWorkerTask;
	readonly diagramId: string;
	readonly release: () => void;
}): Promise<void> {
	const ready = createBridgeProductDeferred<void>();
	const readReady = (): void => {
		if (!articleMatchesMarkdownRequest(props.article, props.task)) {
			ready.reject(new Error('Mermaid article no longer matches its Markdown request.'));
			return;
		}
		const diagram = props.article.querySelector(
			`[data-bridge-mermaid-id="${CSS.escape(props.diagramId)}"]`,
		);
		const state = diagram?.getAttribute('data-bridge-mermaid-state');
		if (state === 'failed') ready.reject(new Error(`Mermaid failed: ${diagram?.textContent}`));
		if (state === 'ready' && diagram !== null && diagram.querySelector('svg') !== null)
			ready.resolve();
	};
	const observer = new MutationObserver(readReady);
	observer.observe(props.article, { attributes: true, childList: true, subtree: true });
	try {
		readReady();
		props.release();
		await ready.promise;
	} finally {
		observer.disconnect();
	}
}

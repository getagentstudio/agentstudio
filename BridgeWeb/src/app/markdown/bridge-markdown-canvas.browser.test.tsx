import { act, type ReactElement } from 'react';
import { afterEach, describe, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the product Markdown styles.
import '../bridge-app.css';
import { BridgePaneFailureMessage } from '../bridge-region-presentation.js';
import { BridgeViewerRecoveryRetryButton } from '../bridge-viewer-recovery-retry-button.js';
import { BridgeMarkdownCanvas } from './bridge-markdown-canvas.js';
import {
	createBridgeMermaidRenderer,
	type BridgeMermaidRenderer,
} from './bridge-mermaid-renderer.js';
import type { BridgeMarkdownPresentationState } from './use-bridge-markdown-presentation.js';

describe('BridgeMarkdownCanvas Browser Mode', () => {
	test.each(['idle', 'loading'] as const)('projects Markdown %s through W6', async (status) => {
		await render(
			<BridgeMarkdownCanvas
				isActive={true}
				presentationState={status === 'idle' ? { status } : { status, sourcePath: 'docs/a.md' }}
				retry={() => undefined}
			/>,
		);
		expect(
			document
				.querySelector('[data-bridge-region="markdown"]')
				?.getAttribute('data-presentation-state'),
		).toBe(status === 'idle' ? 'empty' : 'loading');
		expect(document.querySelector('[data-slot="skeleton"]') !== null).toBe(status === 'loading');
	});
	afterEach(async () => {
		await cleanup();
		document.body.replaceChildren();
	});

	test('composes document failure into one pane Retry while the Markdown region stays quiet', async () => {
		const retry = vi.fn();
		await render(
			<BridgeMarkdownCanvas
				isActive={true}
				renderRegion={({ body, state }): ReactElement => (
					<>
						<BridgePaneFailureMessage
							entries={[{ part: 'markdown', fileName: 'markdown-proof.md', state, retry }]}
							retryControl={(onClick): ReactElement => (
								<BridgeViewerRecoveryRetryButton surface="pane" onClick={onClick} />
							)}
						/>
						{body}
					</>
				)}
				presentationState={{ status: 'failed', sourcePath: 'docs/markdown-proof.md' }}
				retry={retry}
			/>,
		);

		const retryButton = requireHTMLElement(
			[...document.querySelectorAll('button')].find(
				(button): boolean => button.textContent === 'Retry',
			) ?? null,
		);
		expect(retryButton.tagName).toBe('BUTTON');
		expect(retryButton.dataset['slot']).toBe('tooltip-trigger');
		expect(
			document
				.querySelector('[data-bridge-region="markdown"]')
				?.getAttribute('data-presentation-state'),
		).toBe('failed');
		retryButton.click();
		expect(retry).toHaveBeenCalledOnce();
	});

	test('renders semantic document structure, inert links, and preserved Shiki colors', async () => {
		await render(
			<BridgeMarkdownCanvas
				isActive={true}
				presentationState={readyPresentation({
					htmlCandidate: `
						<h1>Markdown proof</h1>
						<p><a href="https://example.com/escape" role="link">Inert reference</a></p>
						<pre class="shiki"><code><span style="color: #ff7b72; background-image: url(https://example.com/x)">let</span> value</code></pre>
						<script>globalThis.markdownScriptExecuted = true</script>
						<img src="https://example.com/tracker.png" />
					`,
				})}
				retry={(): void => {}}
			/>,
		);

		const article = requireHTMLElement(
			document.querySelector('[data-testid="bridge-markdown-canvas"]'),
		);
		const heading = requireHTMLElement(article.querySelector('h1'));
		const link = requireHTMLElement(article.querySelector('a'));
		const highlightedToken = requireHTMLElement(article.querySelector('pre code span'));

		expect(heading.textContent).toBe('Markdown proof');
		expect(link.textContent).toBe('Inert reference');
		expect(link.hasAttribute('href')).toBe(false);
		expect(link.hasAttribute('role')).toBe(false);
		expect(link.classList.contains('bridge-markdown-inert-link')).toBe(true);
		expect(highlightedToken.style.color).not.toBe('');
		expect(highlightedToken.style.backgroundImage).toBe('');
		expect(article.querySelector('script')).toBeNull();
		expect(article.querySelector('img')).toBeNull();
		expect(document.querySelector('[data-testid="bridge-file-viewer-code-view"]')).toBeNull();
	});

	test('lazily renders an admitted Mermaid diagram as labeled sanitized SVG', async () => {
		await render(
			<BridgeMarkdownCanvas
				isActive={true}
				mermaidRenderer={createBridgeMermaidRenderer()}
				presentationState={readyPresentation({
					htmlCandidate:
						'<div class="bridge-markdown-mermaid" data-bridge-mermaid-id="diagram-0"></div>',
					mermaidDiagrams: [{ id: 'diagram-0', source: 'flowchart LR\nA --> B' }],
				})}
				retry={(): void => {}}
			/>,
		);

		const renderedSvg = await waitForSelector(
			'[data-bridge-mermaid-state="ready"] svg',
			SVGElement,
		);

		expect(renderedSvg.getAttribute('role')).toBe('img');
		expect(renderedSvg.getAttribute('aria-label')).toBe('Diagram 1 in docs/markdown-proof.md');
		expect(renderedSvg.querySelector('script, foreignObject, image')).toBeNull();
	});

	test('sanitizes Mermaid output again at the DOM insertion boundary', async () => {
		const mermaidRenderer: BridgeMermaidRenderer = {
			render: async (): Promise<string> => `
				<svg role="img" onload="globalThis.mermaidOutputExecuted = true">
					<script>globalThis.mermaidOutputExecuted = true</script>
					<image href="https://example.com/tracker.png" />
					<text>Safe diagram label</text>
				</svg>
			`,
		};
		await render(
			<BridgeMarkdownCanvas
				isActive={true}
				mermaidRenderer={mermaidRenderer}
				presentationState={readyPresentation({
					htmlCandidate:
						'<div class="bridge-markdown-mermaid" data-bridge-mermaid-id="diagram-sink"></div>',
					mermaidDiagrams: [{ id: 'diagram-sink', source: 'flowchart LR\nA --> B' }],
				})}
				retry={(): void => {}}
			/>,
		);

		const renderedSvg = await waitForSelector(
			'[data-bridge-mermaid-state="ready"] svg',
			SVGElement,
		);

		expect(renderedSvg.textContent).toContain('Safe diagram label');
		expect(renderedSvg.hasAttribute('onload')).toBe(false);
		expect(renderedSvg.querySelector('script, image')).toBeNull();
	});

	test('rejects resource-bearing Mermaid before renderer invocation and contains failure locally', async () => {
		const renderDiagram = vi.fn<BridgeMermaidRenderer['render']>();
		await render(
			<BridgeMarkdownCanvas
				isActive={true}
				mermaidRenderer={{ render: renderDiagram }}
				presentationState={readyPresentation({
					htmlCandidate:
						'<div class="bridge-markdown-mermaid" data-bridge-mermaid-id="diagram-unsafe"></div>',
					mermaidDiagrams: [
						{
							id: 'diagram-unsafe',
							source: 'flowchart LR\nA@{ img: "https://example.com/tracker.png" }',
						},
					],
				})}
				retry={(): void => {}}
			/>,
		);

		await act(async (): Promise<void> => {
			await waitForSelector('[data-bridge-mermaid-state="failed"]', HTMLElement);
		});
		expect(renderDiagram).not.toHaveBeenCalled();
		expect(document.body.textContent).toContain("Couldn't draw this diagram");
		expect(document.body.textContent).toContain('Retry diagram');
	});

	test('renders diagram Retry with the owned Button primitive and recovers in place', async () => {
		let renderAttemptCount = 0;
		const mermaidRenderer: BridgeMermaidRenderer = {
			render: async (): Promise<string> => {
				renderAttemptCount += 1;
				if (renderAttemptCount === 1) {
					throw new Error('diagram bootstrap failed');
				}
				return '<svg role="img"><text>Recovered diagram</text></svg>';
			},
		};
		await render(
			<BridgeMarkdownCanvas
				isActive={true}
				mermaidRenderer={mermaidRenderer}
				presentationState={readyPresentation({
					htmlCandidate:
						'<div class="bridge-markdown-mermaid" data-bridge-mermaid-id="diagram-retry"></div>',
					mermaidDiagrams: [{ id: 'diagram-retry', source: 'flowchart LR\nA --> B' }],
				})}
				retry={(): void => {}}
			/>,
		);

		await act(async (): Promise<void> => {
			await waitForSelector('[data-bridge-mermaid-state="failed"] button', HTMLElement);
		});
		const article = requireHTMLElement(
			document.querySelector('[data-testid="bridge-markdown-canvas"]'),
		);
		const placeholder = requireHTMLElement(
			document.querySelector('[data-bridge-mermaid-id="diagram-retry"]'),
		);
		const retryButton = requireHTMLElement(placeholder.querySelector('button'));
		expect(retryButton.dataset['slot']).toBe('button');

		await act(async (): Promise<void> => {
			retryButton.click();
			await waitForSelector('[data-bridge-mermaid-state="ready"] svg', SVGElement);
		});

		expect(renderAttemptCount).toBe(2);
		expect(document.querySelector('[data-testid="bridge-markdown-canvas"]')).toBe(article);
		expect(document.querySelector('[data-bridge-mermaid-id="diagram-retry"]')).toBe(placeholder);
		expect(document.body.textContent).toContain('Recovered diagram');
		expect(document.body.textContent).not.toContain('Retry diagram');
	});

	test('does not insert a completed diagram into a superseded document', async () => {
		const pendingDiagram = { resolve: null as ((svg: string) => void) | null };
		const mermaidRenderer: BridgeMermaidRenderer = {
			render: () =>
				new Promise<string>((resolve): void => {
					pendingDiagram.resolve = resolve;
				}),
		};
		const rendered = await render(
			<BridgeMarkdownCanvas
				isActive={true}
				mermaidRenderer={mermaidRenderer}
				presentationState={readyPresentation({
					htmlCandidate:
						'<div class="bridge-markdown-mermaid" data-bridge-mermaid-id="diagram-stale"></div>',
					mermaidDiagrams: [{ id: 'diagram-stale', source: 'flowchart LR\nA --> B' }],
					requestId: 'markdown-request-stale',
				})}
				retry={(): void => {}}
			/>,
		);
		await waitForSelector('[data-bridge-mermaid-state="rendering"]', HTMLElement);

		await rendered.rerender(
			<BridgeMarkdownCanvas
				isActive={true}
				mermaidRenderer={mermaidRenderer}
				presentationState={readyPresentation({
					htmlCandidate: '<h1>Current document</h1>',
					requestId: 'markdown-request-current',
				})}
				retry={(): void => {}}
			/>,
		);
		if (pendingDiagram.resolve === null) {
			throw new Error('Expected the first Mermaid render to be pending.');
		}
		pendingDiagram.resolve('<svg role="img"><text>Stale diagram</text></svg>');
		await Promise.resolve();

		expect(document.body.textContent).toContain('Current document');
		expect(document.body.textContent).not.toContain('Stale diagram');
		expect(document.querySelector('[data-bridge-mermaid-id="diagram-stale"]')).toBeNull();
	});

	test('does not commit an in-flight Mermaid result while File view is inactive', async () => {
		const pendingDiagram = { resolve: null as ((svg: string) => void) | null };
		const mermaidRenderer: BridgeMermaidRenderer = {
			render: () =>
				new Promise<string>((resolve): void => {
					pendingDiagram.resolve = resolve;
				}),
		};
		const presentation = readyPresentation({
			htmlCandidate:
				'<div class="bridge-markdown-mermaid" data-bridge-mermaid-id="diagram-inactive"></div>',
			mermaidDiagrams: [{ id: 'diagram-inactive', source: 'flowchart LR\nA --> B' }],
			requestId: 'markdown-request-inactive',
		});
		const rendered = await render(
			<BridgeMarkdownCanvas
				isActive={true}
				mermaidRenderer={mermaidRenderer}
				presentationState={presentation}
				retry={(): void => {}}
			/>,
		);
		await waitForSelector('[data-bridge-mermaid-state="rendering"]', HTMLElement);

		await rendered.rerender(
			<BridgeMarkdownCanvas
				isActive={false}
				mermaidRenderer={mermaidRenderer}
				presentationState={presentation}
				retry={(): void => {}}
			/>,
		);
		if (pendingDiagram.resolve === null) {
			throw new Error('Expected the Mermaid render to be pending.');
		}
		await act(async (): Promise<void> => {
			pendingDiagram.resolve?.('<svg role="img"><text>Hidden result</text></svg>');
			await Promise.resolve();
		});

		expect(document.body.textContent).not.toContain('Hidden result');
		expect(document.querySelector('[data-bridge-mermaid-id="diagram-inactive"] svg')).toBeNull();
	});
});

function readyPresentation(props: {
	readonly htmlCandidate: string;
	readonly mermaidDiagrams?: readonly { readonly id: string; readonly source: string }[];
	readonly requestId?: string;
}): Extract<BridgeMarkdownPresentationState, { readonly status: 'ready' }> {
	const requestId = props.requestId ?? 'markdown-request-browser';
	const identity = {
		requestId,
		sourceIdentity: {
			surface: 'file' as const,
			sourceId: 'worktree-source',
			sourceGeneration: 1,
			fileId: 'markdown-proof',
			fileVersion: 1,
		},
		contentCacheKey: 'markdown-proof-cache',
		contentHash: 'markdown-proof-hash',
		abortKey: 'bridge-markdown-file',
	};
	return {
		status: 'ready',
		refresh: { kind: 'current' },
		sourcePath: 'docs/markdown-proof.md',
		identity,
		renderResult: {
			schemaVersion: 1,
			method: 'markdown.render',
			ok: true,
			...identity,
			htmlCandidate: props.htmlCandidate,
			mermaidDiagrams: [...(props.mermaidDiagrams ?? [])],
			annotationTargets: [],
			metrics: {
				durationMilliseconds: 1,
				inputBytes: 1,
				outputBytes: props.htmlCandidate.length,
				mermaidDiagramCount: props.mermaidDiagrams?.length ?? 0,
			},
		},
	};
}

function requireHTMLElement(element: Element | null): HTMLElement {
	if (!(element instanceof HTMLElement)) {
		throw new Error('Expected an HTMLElement.');
	}
	return element;
}

async function waitForSelector<TElement extends Element>(
	selector: string,
	elementType: abstract new () => TElement,
): Promise<TElement> {
	const readMatchingElement = (): TElement | null => {
		const matchingElement = document.querySelector(selector);
		return matchingElement instanceof elementType ? matchingElement : null;
	};
	const existingElement = readMatchingElement();
	if (existingElement !== null) {
		return existingElement;
	}
	return await new Promise<TElement>((resolve): void => {
		const observer = new MutationObserver((): void => {
			const matchingElement = readMatchingElement();
			if (matchingElement === null) {
				return;
			}
			observer.disconnect();
			resolve(matchingElement);
		});
		observer.observe(document.body, {
			attributes: true,
			childList: true,
			subtree: true,
		});
	});
}

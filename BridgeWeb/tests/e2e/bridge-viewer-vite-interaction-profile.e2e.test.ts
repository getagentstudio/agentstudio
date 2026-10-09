import { execFileSync } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import type { Browser, Page } from 'playwright';
import { expect, test } from 'vitest';

import { drainAnnotationLifecycleTelemetry } from './bridge-viewer-vite-annotation-lifecycle-telemetry.ts';
import {
	observeAnnotationMainProjection,
	readAnnotationMainProjectionObservation,
} from './bridge-viewer-vite-annotation-main-projection-observation.ts';
import {
	selectReviewFile,
	waitForSelectedReviewReady,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { observeInteractionProfileFailures } from './bridge-viewer-vite-interaction-profile-diagnostics.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { bridgeViewerViteProductReviewUrl } from './bridge-viewer-vite-product-url.ts';
import { observeBrowserRuntimeDiagnostics } from './bridge-viewer-vite-review-comparison-observation.ts';

interface InteractionProfileSample {
	readonly durationMilliseconds: number;
	readonly longTaskCount: number;
	readonly longestTaskMilliseconds: number;
	readonly markdownReadyMilliseconds: number | null;
	readonly name: string;
}

interface InteractionProfileTarget {
	readonly kind: 'file' | 'markdown' | 'review';
	readonly name: string;
	readonly path: string;
}

declare global {
	interface Window {
		bridgeInteractionProfileProbe?: {
			readonly dispose: () => void;
			result: InteractionProfileSample | null;
		};
	}
}

test('profiles repeated mode switches, Open in Files, Markdown and Mermaid through the real backend', async () => {
	// Arrange — a real disposable worktree, Swift backend and production worker/renderers.
	const iterationCount = Number(process.env['BRIDGE_INTERACTION_PROFILE_ITERATIONS'] ?? '10');
	if (!Number.isSafeInteger(iterationCount) || iterationCount < 1 || iterationCount > 100) {
		throw new Error('Interaction profile iterations must be an integer from 1 to 100.');
	}
	const fixture = await createBridgeViewerViteProductFixture();
	const markdownPath = '000-interaction-profile.md';
	let browser: Browser | null = null;
	let server: BridgeViewerOwnedViteProductServer | null = null;
	let diagnostics: ReturnType<typeof observeBrowserRuntimeDiagnostics> | null = null;
	let failureDiagnostics: Awaited<ReturnType<typeof observeInteractionProfileFailures>> | null =
		null;
	const samples: InteractionProfileSample[] = [];
	let annotationMainProjection: unknown = null;
	let annotationLifecycleTelemetry: unknown = null;
	let profilePage: Page | null = null;
	let completed = false;
	let failure: string | null = null;
	try {
		await writeFile(
			join(fixture.oracle.worktreeRoot, markdownPath),
			[
				'# Interaction profile document',
				'',
				'A real Markdown document fetched through the product content route.',
				'',
				'| Boundary | Owner |',
				'| --- | --- |',
				'| Metadata | Comm worker |',
				'',
				'```typescript',
				'const currentDocument = "profile";',
				'```',
				'',
				'```mermaid',
				'flowchart LR',
				'Backend --> Worker --> UI',
				'```',
				'',
			].join('\n'),
		);
		browser = await launchBridgeViewerE2EChromium();
		server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
		const page = await browser.newPage({ viewport: { width: 1728, height: 980 } });
		profilePage = page;
		const mainProjectionObservation = observeAnnotationMainProjection(page);
		diagnostics = observeBrowserRuntimeDiagnostics(page);
		failureDiagnostics = await observeInteractionProfileFailures(page);
		const pageErrors: string[] = [];
		page.on('pageerror', (error): void => {
			pageErrors.push(error.message);
		});
		const reviewFile = fixture.oracle.reviewFiles[0];
		if (reviewFile === undefined) throw new Error('Profile requires a real changed source file.');
		await page.goto(bridgeViewerViteProductReviewUrl(server.origin, reviewFile.path), {
			waitUntil: 'domcontentloaded',
		});
		await selectReviewFile({ page, path: reviewFile.path });
		await waitForSelectedReviewReady({ page, itemId: reviewFile.itemId });
		await mainProjectionObservation.install();
		const fileHost = page.getByTestId('bridge-viewer-mode-host-file');
		const reviewHost = page.getByTestId('bridge-viewer-mode-host-review');

		// Act — each sample starts on the actual DOM click, not automation dispatch.
		// oxlint-disable eslint/no-await-in-loop -- One page's samples must settle serially before the next action.
		for (let iteration = 0; iteration < iterationCount; iteration += 1) {
			samples.push(
				await measureInteraction(
					page,
					{
						kind: 'file',
						name: 'review-open-in-files',
						path: reviewFile.path,
					},
					async (): Promise<void> => {
						await reviewHost
							.getByRole('button', { name: `Open ${reviewFile.path} in Files`, exact: true })
							.click();
					},
				),
			);
			samples.push(
				await measureInteraction(
					page,
					{
						kind: 'markdown',
						name: iteration === 0 ? 'markdown-mermaid-first-open' : 'markdown-mermaid-revisit',
						path: markdownPath,
					},
					async (): Promise<void> => {
						await clickMountedFileTreePath({ fileHost, path: markdownPath });
					},
				),
			);
			samples.push(
				await measureInteraction(
					page,
					{
						kind: 'review',
						name: 'file-to-review',
						path: reviewFile.path,
					},
					async (): Promise<void> => {
						await fileHost.getByTestId('bridge-viewer-context-review').click();
					},
				),
			);
			samples.push(
				await measureInteraction(
					page,
					{
						kind: 'file',
						name: 'review-to-file',
						path: '',
					},
					async (): Promise<void> => {
						await reviewHost.getByTestId('bridge-viewer-context-file').click();
					},
				),
			);
			await fileHost.getByTestId('bridge-viewer-context-review').click();
			await waitForSelectedReviewReady({ page, itemId: reviewFile.itemId });
		}

		// oxlint-enable eslint/no-await-in-loop
		// Assert — diagnostic timing samples are not a statistically accepted SLO cohort.
		expect(samples).toHaveLength(iterationCount * 4);
		expect(pageErrors).toEqual([]);
		expect(samples.every((sample): boolean => Number.isFinite(sample.durationMilliseconds))).toBe(
			true,
		);
		completed = true;
	} catch (error: unknown) {
		failure = String(error);
		const pageState =
			profilePage !== null && !profilePage.isClosed()
				? await profilePage.evaluate((): unknown => {
						const fileHost = document.querySelector<HTMLElement>(
							'[data-testid="bridge-viewer-mode-host-file"]',
						);
						const reviewHost = document.querySelector<HTMLElement>(
							'[data-testid="bridge-viewer-mode-host-review"]',
						);
						const fileCanvas = fileHost?.querySelector(
							'[data-testid="bridge-file-viewer-code-canvas"]',
						);
						const markdown = fileHost?.querySelector('[data-testid="bridge-markdown-canvas"]');
						const mermaid = markdown?.querySelector('[data-bridge-mermaid-state]');
						return {
							fileHostActive: fileHost?.getAttribute('data-bridge-viewer-mode-active') ?? null,
							fileHostInert: fileHost?.inert ?? null,
							fileOpenPath: fileCanvas?.getAttribute('data-worktree-open-file-path') ?? null,
							fileOpenState: fileCanvas?.getAttribute('data-worktree-open-file-state') ?? null,
							markdownSourcePath:
								markdown?.getAttribute('data-bridge-markdown-source-path') ?? null,
							markdownText: markdown?.textContent?.slice(0, 160) ?? null,
							mermaidState: mermaid?.getAttribute('data-bridge-mermaid-state') ?? null,
							reviewHostActive: reviewHost?.getAttribute('data-bridge-viewer-mode-active') ?? null,
							url: location.href,
						};
					})
				: { kind: 'page-unavailable' };
		throw new Error(
			`Interaction profile failed after ${samples.length} samples. Page: ${JSON.stringify(pageState)}. Browser: ${await diagnostics?.describe()}. Backend: ${server?.diagnostics() ?? 'not started'}`,
			{ cause: error },
		);
	} finally {
		try {
			if (profilePage !== null && !profilePage.isClosed()) {
				annotationMainProjection = await readAnnotationMainProjectionObservation(profilePage);
				annotationLifecycleTelemetry = await readAnnotationLifecycleDiagnostic(profilePage);
			}
			const reportDirectory = new URL('../../../tmp/bridge-interaction-profile/', import.meta.url);
			const report = {
				profileKind: 'diagnostic-click-to-ready-frame',
				fixture: '16-changed-files-plus-markdown-mermaid',
				acceptanceCohort: false,
				iterationCount,
				completed,
				failure,
				annotationMainProjection,
				annotationLifecycleTelemetry,
				failureDiagnostics: await failureDiagnostics?.read(),
				sourceHead: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
				dirtyTrackedPaths: execFileSync('git', ['diff', '--name-only'], { encoding: 'utf8' })
					.trim()
					.split('\n')
					.filter(Boolean),
				samples,
			};
			await mkdir(reportDirectory, { recursive: true });
			await writeFile(
				new URL(`${new Date().toISOString().replaceAll(':', '-')}.json`, reportDirectory),
				`${JSON.stringify(report, null, 2)}\n`,
			);
		} finally {
			try {
				await browser?.close();
			} finally {
				try {
					await server?.stop();
				} finally {
					await fixture.dispose();
				}
			}
		}
	}
});

async function clickMountedFileTreePath(props: {
	readonly fileHost: ReturnType<Page['getByTestId']>;
	readonly path: string;
}): Promise<void> {
	const tree = props.fileHost.getByTestId('bridge-file-viewer-pierre-file-tree');
	const row = tree.locator(
		`button[data-item-type="file"][data-item-path=${JSON.stringify(props.path)}]:not([data-file-tree-sticky-row]):not([data-item-parked])`,
	);
	await row.scrollIntoViewIfNeeded();
	await row.evaluate((mountedRow): void => {
		const root = mountedRow.getRootNode();
		const scrollOwner =
			root instanceof ShadowRoot
				? root.querySelector('[data-file-tree-virtualized-scroll="true"]')
				: null;
		if (!(scrollOwner instanceof HTMLElement)) {
			throw new Error('File tree scroll owner is unavailable.');
		}
		const rowRect = mountedRow.getBoundingClientRect();
		const ownerRect = scrollOwner.getBoundingClientRect();
		scrollOwner.scrollTop +=
			rowRect.top + rowRect.height / 2 - (ownerRect.top + ownerRect.height / 2);
		scrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
	});
	await row.waitFor({ state: 'visible' });
	await tree.evaluate((treeElement): void => {
		treeElement.addEventListener(
			'click',
			(event): void => {
				const clickedRow = event
					.composedPath()
					.find(
						(candidate): candidate is Element =>
							candidate instanceof Element &&
							candidate.getAttribute('data-item-type') === 'file' &&
							candidate.hasAttribute('data-item-path'),
					);
				treeElement.setAttribute(
					'data-profile-clicked-path',
					clickedRow?.getAttribute('data-item-path') ?? '',
				);
			},
			{ capture: true, once: true },
		);
	});
	await row.click();
	expect(await tree.getAttribute('data-profile-clicked-path')).toBe(props.path);
	await tree.evaluate((treeElement): void => {
		treeElement.removeAttribute('data-profile-clicked-path');
	});
}

async function readAnnotationLifecycleDiagnostic(page: Page): Promise<unknown> {
	try {
		const drainReport = await drainAnnotationLifecycleTelemetry(page);
		const response = await fetch(new URL('/__bridge-dev-telemetry/status', page.url()), {
			cache: 'no-store',
			signal: AbortSignal.timeout(5_000),
		});
		if (!response.ok) return { kind: 'status-unavailable', status: response.status };
		const status: unknown = await response.json();
		if (typeof status !== 'object' || status === null) return { kind: 'malformed-status' };
		const recentSamples: unknown = Reflect.get(status, 'recentSamples');
		return {
			drainReport,
			kind: 'report',
			operationLifecycle: Reflect.get(status, 'operationLifecycle'),
			samples: Array.isArray(recentSamples)
				? recentSamples.filter((sample: unknown): boolean => {
						if (typeof sample !== 'object' || sample === null) return false;
						const name: unknown = Reflect.get(sample, 'name');
						return typeof name === 'string' && name.endsWith('.annotation_lifecycle');
					})
				: null,
		};
	} catch (error: unknown) {
		// Keep observation failure in the report without replacing the original journey failure.
		return { kind: 'observation-failed', message: String(error) };
	}
}

async function measureInteraction(
	page: Page,
	target: InteractionProfileTarget,
	act: () => Promise<void>,
): Promise<InteractionProfileSample> {
	await page.evaluate((expected): void => {
		window.bridgeInteractionProfileProbe?.dispose();
		if (!PerformanceObserver.supportedEntryTypes.includes('longtask')) {
			throw new Error('Interaction profiling requires browser Long Tasks support.');
		}
		let startedAt: number | null = null;
		let markdownReadyMilliseconds: number | null = null;
		let readyFrameCount = 0;
		let animationFrame = 0;
		const longTasks: PerformanceEntry[] = [];
		const observer = new PerformanceObserver((entries): void => {
			longTasks.push(...entries.getEntries());
		});
		observer.observe({ type: 'longtask', buffered: false });
		const onClick = (): void => {
			startedAt = performance.now();
		};
		document.addEventListener('click', onClick, { once: true, capture: true });
		const probe: NonNullable<Window['bridgeInteractionProfileProbe']> = {
			dispose: (): void => {
				cancelAnimationFrame(animationFrame);
				observer.disconnect();
				document.removeEventListener('click', onClick, true);
			},
			result: null,
		};
		window.bridgeInteractionProfileProbe = probe;
		const observeFrame = (): void => {
			const surface = expected.kind === 'review' ? 'review' : 'file';
			const host = document.querySelector(`[data-testid="bridge-viewer-mode-host-${surface}"]`);
			const hostIsActive =
				host instanceof HTMLElement &&
				!host.inert &&
				host.getAttribute('data-bridge-viewer-mode-active') === 'true';
			const markdown = host?.querySelector('[data-testid="bridge-markdown-canvas"]');
			const markdownVisible =
				markdown instanceof HTMLElement &&
				markdown.getBoundingClientRect().height > 0 &&
				(markdown.textContent?.includes('Interaction profile document') ?? false);
			if (startedAt !== null && markdownVisible && markdownReadyMilliseconds === null) {
				markdownReadyMilliseconds = performance.now() - startedAt;
			}
			const fileCanvas = host?.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
			const fileIsReady =
				fileCanvas?.getAttribute('data-worktree-open-file-state') === 'ready' &&
				(expected.path === '' ||
					fileCanvas.getAttribute('data-worktree-open-file-path') === expected.path) &&
				[...fileCanvas.querySelectorAll('diffs-container')].some(
					(container): boolean =>
						(container.shadowRoot?.querySelectorAll('[data-content] [data-line-index]').length ??
							0) > 0,
				);
			const reviewShell = host?.querySelector('[data-testid="review-viewer-shell"]');
			const reviewIsReady =
				reviewShell?.getAttribute('data-selected-content-state') === 'ready' &&
				[...(host?.querySelectorAll('diffs-container') ?? [])].some(
					(container): boolean =>
						(container.shadowRoot?.querySelectorAll('[data-content] [data-line-index]').length ??
							0) > 0,
				);
			const targetIsReady =
				expected.kind === 'markdown'
					? markdownVisible &&
						markdown.querySelector('[data-bridge-mermaid-state="ready"] svg') !== null
					: expected.kind === 'review'
						? reviewIsReady
						: fileIsReady || (expected.path === '' && markdownVisible);
			readyFrameCount =
				startedAt !== null && hostIsActive && targetIsReady ? readyFrameCount + 1 : 0;
			if (readyFrameCount >= 2 && startedAt !== null) {
				const interactionStartedAt = startedAt;
				longTasks.push(...observer.takeRecords());
				const relevantTasks = longTasks.filter(
					(entry): boolean => entry.startTime + entry.duration > interactionStartedAt,
				);
				probe.result = {
					durationMilliseconds: performance.now() - startedAt,
					longTaskCount: relevantTasks.length,
					longestTaskMilliseconds: Math.max(
						0,
						...relevantTasks.map((entry): number => entry.duration),
					),
					markdownReadyMilliseconds,
					name: expected.name,
				};
				probe.dispose();
				return;
			}
			animationFrame = requestAnimationFrame(observeFrame);
		};
		animationFrame = requestAnimationFrame(observeFrame);
	}, target);
	try {
		await act();
		const result = await page.waitForFunction(
			() => window.bridgeInteractionProfileProbe?.result ?? null,
			undefined,
			{ timeout: 30_000 },
		);
		const sample = await result.jsonValue();
		if (sample === null) throw new Error('Interaction profile completed without a sample.');
		return sample;
	} finally {
		await page.evaluate((): void => {
			window.bridgeInteractionProfileProbe?.dispose();
		});
	}
}

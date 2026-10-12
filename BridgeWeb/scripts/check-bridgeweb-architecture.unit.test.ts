import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, test } from 'vitest';

import {
	type ArchitectureViolation,
	checkBridgeWebArchitecture,
} from './check-bridgeweb-architecture.ts';
import { registerWaitBudgetArchitectureFixtures } from './check-bridgeweb-architecture.wait-budgets.test-support.ts';

registerWaitBudgetArchitectureFixtures();

describe('BridgeWeb architecture checker', () => {
	test('reports every TypeScript and TSX file over one thousand lines', async () => {
		await withFixtureTree(
			{
				'src/app/large-controller.ts': generatedLineSource(1001),
				'src/app/large-controller.unit.test.ts': generatedLineSource(1001),
				'vite.config.ts': generatedLineSource(1001),
				'src/app/large-view.tsx': generatedLineSource(1001),
				'src/app/limit.ts': generatedLineSource(1000),
				'node_modules/package/large.ts': generatedLineSource(1001),
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toEqual(
					expect.arrayContaining([
						expect.objectContaining({
							ruleId: 'max-file-lines',
							relativePath: 'src/app/large-controller.ts',
						}),
						expect.objectContaining({
							ruleId: 'max-file-lines',
							relativePath: 'src/app/large-controller.unit.test.ts',
						}),
						expect.objectContaining({
							ruleId: 'max-file-lines',
							relativePath: 'src/app/large-view.tsx',
						}),
						expect.objectContaining({
							ruleId: 'max-file-lines',
							relativePath: 'vite.config.ts',
						}),
					]),
				);
				expect(report.violations).not.toContainEqual(
					expect.objectContaining({
						ruleId: 'max-file-lines',
						relativePath: 'src/app/limit.ts',
					}),
				);
				expect(report.violations).not.toContainEqual(
					expect.objectContaining({
						ruleId: 'max-file-lines',
						relativePath: 'node_modules/package/large.ts',
					}),
				);
			},
		);
	});

	test('reports private Pierre imports and misplaced Trees runtime imports', async () => {
		await withFixtureTree(
			{
				'src/review-viewer/code-view/bad-private-parser.ts': `
					import { parseDiffFromFile } from '@pierre/diffs/dist/parseDiffFromFile';
					export const value = parseDiffFromFile;
				`,
				'src/review-viewer/shell/bad-tree-import.ts': `
					import { prepareFileTreeInput } from '@pierre/trees';
					import type { FileTreeNode } from '@pierre/trees/dist/model/publicTypes';
					export const value = prepareFileTreeInput([]);
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toEqual(
					expect.arrayContaining([
						expect.objectContaining({
							relativePath: 'src/review-viewer/code-view/bad-private-parser.ts',
							ruleId: 'no-private-pierre-imports',
						}),
					]),
				);
				expect(report.violations.map(ruleIdForViolation)).toEqual(
					expect.arrayContaining(['no-private-pierre-imports', 'pierre-trees-import-boundary']),
				);
			},
		);
	});

	test('keeps endpoint adapters and environment detection out of shared product runtime sources', async () => {
		await withFixtureTree(
			{
				'src/core/comm-worker/bridge-product-transport.ts': `
					import { executeAgentStudioBridgeProductRequest } from './bridge-product-agent-studio-request-executor.js';
					import { executeHttpBridgeProductRequest } from './bridge-product-http-request-executor.js';
					export const execute = import.meta.env.DEV
						? executeHttpBridgeProductRequest
						: executeAgentStudioBridgeProductRequest;
					export const computedImportMetaMode = import.meta['env'].DEV;
					export const computedProcessMode = process['env'].NODE_ENV;
					export const call = (props) =>
						props.executeProductRequest('command', { method: 'GET', headers: {} });
				`,
				'src/core/comm-worker/bridge-comm-worker-packaged-entry.ts': `
					import { executeAgentStudioBridgeProductRequest } from './bridge-product-agent-studio-request-executor.js';
					export const execute = executeAgentStudioBridgeProductRequest;
				`,
				'src/core/comm-worker/bridge-comm-worker-vite-entry.ts': `
					import { executeHttpBridgeProductRequest } from './bridge-product-http-request-executor.js';
					export const execute = executeHttpBridgeProductRequest;
				`,
				'src/core/comm-worker/bridge-comm-worker-runtime-protocol.ts': `
					import { executeHttpBridgeProductRequest } from './bridge-product-http-request-executor.js';
					export const execute = executeHttpBridgeProductRequest;
				`,
				'src/core/comm-worker/bridge-worker-runtime.ts': `
					export const transportOrigin = globalThis.location.origin;
					export const computedTransportOrigin = globalThis['location']['origin'];
				`,
				'src/file-viewer/file-product-runtime.ts': `
					export const endpoint = '/__bridge-product/content';
				`,
				'src/app/bridge-app-file-viewer-mode.tsx': `
					export const transportOrigin = window.location.origin;
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });
				const endpointViolations = report.violations.filter(
					(violation): boolean => violation.ruleId === 'product-endpoint-boundary',
				);

				expect(endpointViolations).toHaveLength(11);
				expect(endpointViolations).toEqual(
					expect.arrayContaining([
						expect.objectContaining({
							relativePath: 'src/core/comm-worker/bridge-product-transport.ts',
						}),
						expect.objectContaining({
							relativePath: 'src/core/comm-worker/bridge-product-transport.ts',
						}),
						expect.objectContaining({
							relativePath: 'src/core/comm-worker/bridge-product-transport.ts',
						}),
						expect.objectContaining({
							relativePath: 'src/core/comm-worker/bridge-comm-worker-runtime-protocol.ts',
						}),
						expect.objectContaining({
							relativePath: 'src/core/comm-worker/bridge-worker-runtime.ts',
						}),
						expect.objectContaining({
							relativePath: 'src/file-viewer/file-product-runtime.ts',
						}),
						expect.objectContaining({
							relativePath: 'src/app/bridge-app-file-viewer-mode.tsx',
						}),
					]),
				);
			},
		);
	});

	test('covers every comm-worker runtime and qualified fetch while allowing worker script loading', async () => {
		await withFixtureTree(
			{
				'src/core/comm-worker/bridge-pane-runtime-environment.ts': `
					export const transportOrigin = globalThis.location.origin;
					export const productEndpoint = '/__bridge-product/content';
				`,
				'src/core/comm-worker/bridge-product-runtime-fetches.ts': `
					export const first = globalThis.fetch('/one');
					export const second = self['fetch']('/two');
					export const third = window.fetch('/three');
				`,
				'src/core/comm-worker/bridge-pane-comm-worker-session.ts': `
					export const loadWorkerScript = (workerScriptUrl: string) => fetch(workerScriptUrl);
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });
				const endpointViolations = report.violations.filter(
					(violation): boolean => violation.ruleId === 'product-endpoint-boundary',
				);

				expect(endpointViolations).toHaveLength(5);
				expect(endpointViolations).toEqual(
					expect.arrayContaining([
						expect.objectContaining({
							relativePath: 'src/core/comm-worker/bridge-pane-runtime-environment.ts',
						}),
						expect.objectContaining({
							relativePath: 'src/core/comm-worker/bridge-product-runtime-fetches.ts',
						}),
					]),
				);
				expect(endpointViolations).not.toContainEqual(
					expect.objectContaining({
						relativePath: 'src/core/comm-worker/bridge-pane-comm-worker-session.ts',
					}),
				);
			},
		);
	});

	test('ignores Pierre strings in assertions while still reporting real imports', async () => {
		await withFixtureTree(
			{
				'src/review-viewer/dependencies/source-structure.guard.unit.test.ts': `
					import { expect, test } from 'vitest';

					test('guards source boundaries', () => {
						const source = 'import type { FileTreeNode } from "forbidden";';

						expect(source).not.toContain('@pierre/diffs/dist/');
						expect(source).not.toContain('@pierre/trees/dist/model/publicTypes');
					});
				`,
				'src/review-viewer/shell/bad-private-import.ts': `
					import type { FileTreeNode } from '@pierre/trees/dist/model/publicTypes';
					export type Value = FileTreeNode;
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).not.toEqual(
					expect.arrayContaining([
						expect.objectContaining({
							relativePath: 'src/review-viewer/dependencies/source-structure.guard.unit.test.ts',
						}),
					]),
				);
				expect(report.violations).toEqual(
					expect.arrayContaining([
						expect.objectContaining({
							ruleId: 'no-private-pierre-imports',
							relativePath: 'src/review-viewer/shell/bad-private-import.ts',
						}),
					]),
				);
			},
		);
	});

	test('allows public Pierre imports in their owning viewer slices and tests', async () => {
		await withFixtureTree(
			{
				'src/core/comm-worker/bridge-worker-review-pierre-job-planner.ts': `
					import { parseDiffFromFile } from '@pierre/diffs';
					export const value = parseDiffFromFile;
				`,
				'src/review-viewer/trees/tree-controller.ts': `
					import { preparePresortedFileTreeInput } from '@pierre/trees';
					export const value = preparePresortedFileTreeInput([]);
				`,
				'src/file-viewer/file-tree-panel.tsx': `
					import { FileTree } from '@pierre/trees/react';
					export const value = FileTree;
				`,
				'src/app/bridge-viewer-tree-theme.ts': `
					import { themeToTreeStyles } from '@pierre/trees';
					export const value = themeToTreeStyles;
				`,
				'src/review-viewer/code-view/code-view-controller.ts': `
					import { CodeView } from '@pierre/diffs/react';
					export const value = CodeView;
				`,
				'src/file-viewer/file-code-panel.tsx': `
					import { CodeView } from '@pierre/diffs/react';
					export const value = CodeView;
				`,
				'src/review-viewer/workers/pierre/pierre-worker-pool.ts': `
					import { WorkerPoolManager } from '@pierre/diffs/worker';
					export const value = WorkerPoolManager;
				`,
				'src/review-viewer/dependencies/public-package-exports.unit.test.ts': `
					import { FileTree } from '@pierre/trees/react';
					import { File } from '@pierre/diffs/react';
					export const values = [FileTree, File];
				`,
				'src/review-viewer/test-support/bridge-viewer.browser.benchmark.tsx': `
					import portableWorkerSource from '@pierre/diffs/worker/worker-portable.js?raw';
					export const value = portableWorkerSource;
				`,
				'src/review-viewer/test-support/example.browser.test.tsx': `
					const worker = new Worker(new URL('./fixture-worker.js', import.meta.url));
					worker.postMessage({ ok: true });
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report).toEqual({ ok: true, violations: [] });
			},
		);
	});

	test('reports query-suffixed Pierre worker imports outside the worker owner', async () => {
		await withFixtureTree(
			{
				'src/review-viewer/shell/bad-worker-import.ts': `
					import portableWorkerSource from '@pierre/diffs/worker/worker-portable.js?raw';
					export const value = portableWorkerSource;
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toEqual([
					expect.objectContaining({
						ruleId: 'pierre-worker-import-boundary',
						relativePath: 'src/review-viewer/shell/bad-worker-import.ts',
					}),
				]);
			},
		);
	});

	test('reports effectful review-viewer state and raw loaded file bodies', async () => {
		await withFixtureTree(
			{
				'src/review-viewer/state/review-viewer-store.ts': `
					import { createBridgeRpcClient } from '../../bridge/bridge-rpc-client.js';
					import { WorkerPoolManager } from '@pierre/diffs/worker';
					const loadedFileBody = 'raw file text';
					const worker = new Worker(new URL('./worker.js', import.meta.url));
					const telemetry = { record: () => undefined };
					export const state = { createBridgeRpcClient, loadedFileBody, WorkerPoolManager };
					fetch('agentstudio://resource/content/handle?generation=1');
					worker.postMessage({ ok: true });
					telemetry.record('store-action');
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations.map(ruleIdForViolation)).toEqual(
					expect.arrayContaining([
						'review-viewer-state-has-effects',
						'no-raw-file-bodies-in-state',
						'worker-boundary',
						'telemetry-boundary',
					]),
				);
			},
		);
	});

	test('reports generic core imports of app protocol and viewer modules', async () => {
		await withFixtureTree(
			{
				'src/core/demand/bad-review-policy-import.ts': `
					import { mapReviewDemandStimulusToIntents } from '../../features/review/demand/review-demand-policy.js';
					export const value = mapReviewDemandStimulusToIntents;
				`,
				'src/core/resources/bad-worktree-import.ts': `
					import type { WorktreeFileDescriptor } from '../../features/worktree-file/models/worktree-file-protocol-models.js';
					export type Value = WorktreeFileDescriptor;
				`,
				'src/core/intake/bad-viewer-import.ts': `
					import { createBridgeReviewViewerStore } from '../../review-viewer/state/review-viewer-store.js';
					export const value = createBridgeReviewViewerStore;
				`,
				'src/core/models/bad-legacy-package-import.ts': `
					import type { BridgeReviewPackage } from '../../foundation/review-package/bridge-review-package.js';
					export type Value = BridgeReviewPackage;
				`,
				'src/core/models/bad-aliased-worktree-import.ts': `
					import type { WorktreeFileDescriptor } from '@/features/worktree-file/models/worktree-file-protocol-models.js';
					export type Value = WorktreeFileDescriptor;
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toEqual([
					expect.objectContaining({
						ruleId: 'core-imports-app-protocol',
						relativePath: 'src/core/demand/bad-review-policy-import.ts',
					}),
					expect.objectContaining({
						ruleId: 'core-imports-app-protocol',
						relativePath: 'src/core/intake/bad-viewer-import.ts',
					}),
					expect.objectContaining({
						ruleId: 'core-imports-app-protocol',
						relativePath: 'src/core/models/bad-aliased-worktree-import.ts',
					}),
					expect.objectContaining({
						ruleId: 'core-imports-app-protocol',
						relativePath: 'src/core/models/bad-legacy-package-import.ts',
					}),
					expect.objectContaining({
						ruleId: 'core-imports-app-protocol',
						relativePath: 'src/core/resources/bad-worktree-import.ts',
					}),
				]);
			},
		);
	});

	test('reports raw bodies and runtime handles in Worktree/File state', async () => {
		await withFixtureTree(
			{
				'src/features/worktree-file/state/worktree-file-state.ts': `
					export interface WorktreeFileSurfaceState {
						readonly selectedContentText: string;
						readonly contentPromise: Promise<string>;
						readonly abortController: AbortController;
						readonly workerHandle: Worker;
						readonly pierreInstance: object;
					}
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toEqual([
					expect.objectContaining({
						ruleId: 'no-raw-file-bodies-in-state',
						relativePath: 'src/features/worktree-file/state/worktree-file-state.ts',
					}),
				]);
			},
		);
	});

	test('reports a TypeScript development server that reintroduces live product authority', async () => {
		await withFixtureTree(
			{
				'scripts/dev-server/rogue-live-product-provider.ts': `
					import type { BridgeReviewPackage } from '../../src/foundation/review-package/bridge-review-package.js';
					export interface RogueLiveProductProvider {
						readonly loadReviewPackage: () => Promise<BridgeReviewPackage>;
						readonly loadContent: () => Promise<string>;
					}
					export const reviewContentEndpoint = '/__bridge-product/content';
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toEqual([
					expect.objectContaining({
						ruleId: 'no-typescript-live-product-authority',
						relativePath: 'scripts/dev-server/rogue-live-product-provider.ts',
					}),
				]);
			},
		);
	});

	test('reports vague review-viewer runtime and workers/rpc folders', async () => {
		await withFixtureTree(
			{
				'src/review-viewer/runtime/review-content-loader.ts': `
					export const value = 'content';
				`,
				'src/review-viewer/workers/rpc/review-projection-worker-client.ts': `
					export const value = 'projection';
				`,
				'src/review-viewer/content/review-content-loader.ts': `
					export const content = 'content';
				`,
				'src/review-viewer/projections/use-review-projection-coordinator.ts': `
					export const projection = 'projection';
				`,
				'src/review-viewer/workers/projection/review-projection-worker-client.ts': `
					export const projectionWorker = 'projection-worker';
				`,
				'src/review-viewer/workers/shared-rpc/shared-worker-rpc.ts': `
					export const sharedRpc = 'shared-rpc';
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toEqual([
					expect.objectContaining({
						ruleId: 'review-viewer-folder-boundary',
						relativePath: 'src/review-viewer/runtime/review-content-loader.ts',
					}),
					expect.objectContaining({
						ruleId: 'review-viewer-folder-boundary',
						relativePath: 'src/review-viewer/workers/rpc/review-projection-worker-client.ts',
					}),
				]);
			},
		);
	});

	test('reports Worker and postMessage usage outside worker lanes', async () => {
		await withFixtureTree(
			{
				'src/review-viewer/shell/bad-worker.ts': `
					const worker = new Worker(new URL('./worker.js', import.meta.url));
					worker.postMessage({ ok: true });
				`,
				'src/review-viewer/workers/projection/projection-worker-client.ts': `
					const worker = new Worker(new URL('./projection-worker.js', import.meta.url));
					worker.postMessage({ ok: true });
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toEqual([
					expect.objectContaining({
						ruleId: 'worker-boundary',
						relativePath: 'src/review-viewer/shell/bad-worker.ts',
					}),
					expect.objectContaining({
						ruleId: 'worker-boundary',
						relativePath: 'src/review-viewer/shell/bad-worker.ts',
					}),
				]);
			},
		);
	});

	test('allows only owned comm-worker and diagnostic message boundaries', async () => {
		await withFixtureTree(
			{
				'src/core/comm-worker/bridge-comm-worker-client.ts': `
					const worker = new Worker(new URL('./bridge-comm-worker.js', import.meta.url));
					worker.postMessage({ kind: 'client' });
				`,
				'src/core/comm-worker/bridge-comm-worker-entry.ts': `
					self.postMessage({ kind: 'entry' });
				`,
				'src/core/comm-worker/bridge-comm-worker-runtime-protocol.ts': `
					const port = { postMessage: (_message: unknown): void => undefined };
					port.postMessage({ kind: 'runtime' });
				`,
				'src/core/comm-worker/bridge-comm-worker-task-boundary.ts': `
					const port = { postMessage: (_message: unknown): void => undefined };
					port.postMessage({ kind: 'task-boundary' });
				`,
				'src/core/comm-worker/bridge-product-session-contracts.ts': `
					const port = { postMessage: (_message: unknown): void => undefined };
					port.postMessage({ kind: 'product-session' });
				`,
				'src/app/diagnostics/bridge-product-stream-webkit-feasibility-worker-entry.ts': `
					self.postMessage({ kind: 'product-stream-feasibility' });
				`,
				'src/app/diagnostics/bridge-product-stream-webkit-feasibility-probe.ts': `
					const worker = { postMessage: (_message: unknown): void => undefined };
					worker.postMessage({ kind: 'product-stream-probe' });
				`,
				'src/core/comm-worker/unowned-message-boundary.ts': `
					const port = { postMessage: (_message: unknown): void => undefined };
					port.postMessage({ kind: 'unowned-comm-message' });
				`,
				'src/app/diagnostics/unowned-diagnostic-message-boundary.ts': `
					const worker = { postMessage: (_message: unknown): void => undefined };
					worker.postMessage({ kind: 'unowned-diagnostic-message' });
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toHaveLength(3);
				expect(report.violations).toEqual(
					expect.arrayContaining([
						expect.objectContaining({
							ruleId: 'worker-boundary',
							relativePath: 'src/core/comm-worker/bridge-comm-worker-client.ts',
							message: expect.stringContaining('Worker construction'),
						}),
						expect.objectContaining({
							ruleId: 'worker-boundary',
							relativePath: 'src/core/comm-worker/unowned-message-boundary.ts',
							message: expect.stringContaining('postMessage usage'),
						}),
						expect.objectContaining({
							ruleId: 'worker-boundary',
							relativePath: 'src/app/diagnostics/unowned-diagnostic-message-boundary.ts',
							message: expect.stringContaining('postMessage usage'),
						}),
					]),
				);
			},
		);
	});

	test('reports content loading imports from review-viewer shell files', async () => {
		await withFixtureTree(
			{
				'src/review-viewer/shell/review-viewer-shell.tsx': `
					import { loadBridgeContentResource } from '../../foundation/content/content-resource-loader.js';
					export const value = loadBridgeContentResource;
				`,
				'src/review-viewer/content/review-content-loader.ts': `
					import { loadBridgeContentResource } from '../../foundation/content/content-resource-loader.js';
					export const value = loadBridgeContentResource;
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toEqual([
					expect.objectContaining({
						ruleId: 'review-viewer-shell-has-content-effects',
						relativePath: 'src/review-viewer/shell/review-viewer-shell.tsx',
					}),
				]);
			},
		);
	});

	test('reports markdown and Shiki rendering imports outside the markdown worker renderer', async () => {
		await withFixtureTree(
			{
				'src/file-viewer/bridge-file-viewer-shell.tsx': `
					import { createMarkdownExit } from 'markdown-exit';
					import { codeToHtml } from 'shiki';
					export const values = [createMarkdownExit, codeToHtml];
				`,
				'src/app/markdown/worker/bridge-markdown-render-worker-client.ts': `
					import { createMarkdownExit } from 'markdown-exit';
					export const value = createMarkdownExit;
				`,
				'src/app/markdown/worker/bridge-markdown-render-worker-renderer.ts': `
					import { fromAsyncCodeToHtml } from '@shikijs/markdown-exit/core';
					export const value = fromAsyncCodeToHtml;
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				expect(report.ok).toBe(false);
				expect(report.violations).toEqual([
					expect.objectContaining({
						ruleId: 'markdown-render-worker-boundary',
						relativePath: 'src/app/markdown/worker/bridge-markdown-render-worker-client.ts',
					}),
					expect.objectContaining({
						ruleId: 'markdown-render-worker-boundary',
						relativePath: 'src/file-viewer/bridge-file-viewer-shell.tsx',
					}),
					expect.objectContaining({
						ruleId: 'markdown-render-worker-boundary',
						relativePath: 'src/file-viewer/bridge-file-viewer-shell.tsx',
					}),
				]);
			},
		);
	});

	test('reports timed waits in configured test files and every non-production module they reach', async () => {
		await withFixtureTree(
			{
				...timedWaitFixturePackage,
				'index.html': '<script type="module" src="/src/app/main.tsx"></script>',
				'src/app/main.tsx': `
					import { productDeadline } from './product-deadline.ts';
					void productDeadline;
				`,
				'src/app/journey.unit.test.ts': `
					import { settleJourney } from './journey.test-support.ts';
					import { readyFixture } from '../../scripts/verify-fixture/ready-fixture.js';
					import { productDeadline } from './product-deadline.ts';
					import { mountHarness } from '../file-viewer/bridge-file-viewer-browser-test-harness.ts';
					export async function run(page: { waitForTimeout(ms: number): Promise<void> }): Promise<void> {
						await page.waitForTimeout(25);
						await settleJourney();
						await readyFixture();
						await productDeadline();
						await mountHarness();
					}
				`,
				'src/file-viewer/bridge-file-viewer-browser-test-harness.ts': `
					export async function mountHarness(): Promise<void> {
						await new Promise<void>((resolve) => setTimeout(resolve, 0));
					}
				`,
				'src/app/journey.test-support.ts': `
					import { sleepMilliseconds } from '@/app/test-support/sleep-helper.ts';
					export async function settleJourney(): Promise<void> {
						await sleepMilliseconds(10);
					}
				`,
				'src/app/test-support/sleep-helper.ts': `
					import { setTimeout } from 'node:timers/promises';
					export async function sleepMilliseconds(milliseconds: number): Promise<void> {
						await setTimeout(milliseconds);
					}
				`,
				'scripts/verify-fixture/ready-fixture.ts': `
					export async function readyFixture(): Promise<void> {
						await new Promise<void>((resolve): void => {
							setTimeout(resolve, 0);
						});
						await new Promise<void>((resolve) => window.setTimeout(() => resolve(), 50));
					}
				`,
				'src/app/product-deadline.ts': `
					export async function productDeadline(): Promise<void> {
						await new Promise<void>((resolve) => setTimeout(resolve, 10));
					}
				`,
				'scripts/unreachable-poller.ts': `
					export async function poll(): Promise<void> {
						await new Promise<void>((resolve) => setTimeout(resolve, 10));
					}
				`,
				'src/app/not-a-configured-test.spec.ts': `
					export async function poll(): Promise<void> {
						await new Promise<void>((resolve) => setTimeout(resolve, 10));
					}
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				// A module the product's index.html reaches is production: its timer is
				// product behavior and is not reported even though a test imports it. Every
				// other module a test reaches is test support, whatever its name, and is.
				expect(report.ok).toBe(false);
				expect(
					report.violations.map(
						(violation: ArchitectureViolation): string =>
							`${violation.ruleId} ${violation.relativePath}:${violation.line}`,
					),
				).toEqual([
					'no-timed-wait-in-tests scripts/verify-fixture/ready-fixture.ts:3',
					'no-timed-wait-in-tests scripts/verify-fixture/ready-fixture.ts:6',
					'no-timed-wait-in-tests src/app/journey.test-support.ts:4',
					'no-timed-wait-in-tests src/app/journey.unit.test.ts:7',
					'no-timed-wait-in-tests src/app/test-support/sleep-helper.ts:4',
					'no-timed-wait-in-tests src/file-viewer/bridge-file-viewer-browser-test-harness.ts:3',
				]);
				expect(report.violations[0]?.message).toContain(
					'imported by test file src/app/journey.unit.test.ts',
				);
			},
		);
	});

	test('reconciles timed waits against the BridgeWeb debt ledger by rule, file and count', async () => {
		const twoTimedWaits = `
			export async function run(page: { waitForTimeout(ms: number): Promise<void> }): Promise<void> {
				await page.waitForTimeout(1);
				await page.waitForTimeout(2);
			}
		`;
		const ledger = (rows: readonly string[]): string =>
			['rule_id\tpath\tcount', ...rows].map((row: string): string => `${row}\n`).join('');
		const reconcile = async (files: Record<string, string>): Promise<readonly string[]> => {
			let messages: readonly string[] = [];
			await withFixtureTree(
				{ ...timedWaitFixturePackage, ...files },
				async (packageRootPath: string): Promise<void> => {
					const report = await checkBridgeWebArchitecture({ packageRootPath });
					messages = report.violations.map(
						(violation: ArchitectureViolation): string =>
							`${violation.relativePath}:${violation.line} ${violation.message}`,
					);
				},
			);
			return messages;
		};

		// Exact count: passes.
		expect(
			await reconcile({
				'src/app/waits.unit.test.ts': twoTimedWaits,
				'architecture-debt-ledger.tsv': ledger([
					'no-timed-wait-in-tests\tBridgeWeb/src/app/waits.unit.test.ts\t2',
				]),
			}),
		).toEqual([]);
		// Over the count: every site fails, naming the count.
		expect(
			await reconcile({
				'src/app/waits.unit.test.ts': twoTimedWaits,
				'architecture-debt-ledger.tsv': ledger([
					'no-timed-wait-in-tests\tBridgeWeb/src/app/waits.unit.test.ts\t1',
				]),
			}),
		).toEqual([
			expect.stringMatching(/^src\/app\/waits\.unit\.test\.ts:3 .*count 2 exceeds 1 permitted/u),
			expect.stringMatching(/^src\/app\/waits\.unit\.test\.ts:4 .*count 2 exceeds 1 permitted/u),
		]);
		// Under the count: fails until the row is lowered.
		expect(
			await reconcile({
				'src/app/waits.unit.test.ts': twoTimedWaits,
				'architecture-debt-ledger.tsv': ledger([
					'no-timed-wait-in-tests\tBridgeWeb/src/app/waits.unit.test.ts\t3',
				]),
			}),
		).toEqual([
			expect.stringMatching(/^src\/app\/waits\.unit\.test\.ts:1 .*lower the row to 2 in/u),
		]);
		// Paid off: fails until the row is removed.
		expect(
			await reconcile({
				'src/app/waits.unit.test.ts': 'export {};',
				'architecture-debt-ledger.tsv': ledger([
					'no-timed-wait-in-tests\tBridgeWeb/src/app/waits.unit.test.ts\t2',
				]),
			}),
		).toEqual([
			expect.stringMatching(/^src\/app\/waits\.unit\.test\.ts:1 .*none remain; remove the row/u),
		]);
		// A row for a file that no longer exists fails at the ledger row.
		expect(
			await reconcile({
				'architecture-debt-ledger.tsv': ledger([
					'no-timed-wait-in-tests\tBridgeWeb/src/app/deleted.unit.test.ts\t1',
				]),
			}),
		).toEqual([
			expect.stringMatching(
				/^architecture-debt-ledger\.tsv:2 .*deleted\.unit\.test\.ts, which no longer exists/u,
			),
		]);
		// A new site in a file without a row fails immediately.
		expect(
			await reconcile({
				'src/app/waits.unit.test.ts': twoTimedWaits,
				'src/app/new-waits.unit.test.ts': twoTimedWaits,
				'architecture-debt-ledger.tsv': ledger([
					'no-timed-wait-in-tests\tBridgeWeb/src/app/waits.unit.test.ts\t2',
				]),
			}),
		).toEqual([
			expect.stringMatching(/^src\/app\/new-waits\.unit\.test\.ts:3 waitForTimeout\(\)/u),
			expect.stringMatching(/^src\/app\/new-waits\.unit\.test\.ts:4 waitForTimeout\(\)/u),
		]);
		// A malformed ledger fails closed, naming the file and line.
		await expect(
			reconcile({
				'architecture-debt-ledger.tsv':
					'rule_id\tpath\tcount\nno-timed-wait-in-tests\tBridgeWeb/x.ts\t0\n',
			}),
		).rejects.toThrow(/architecture-debt-ledger\.tsv:2: malformed debt ledger: count must be/u);
	});

	test('permits a timer only as a direct Promise.race element whose delay is a bare hang bound', async () => {
		await withFixtureTree(
			{
				...timedWaitFixturePackage,
				'tests/e2e/bounded-journey.e2e.test.ts': `
					import { endToEndTestTimeoutMilliseconds as hangBound } from '../vitest-hang-bounds.ts';
					import type { SleepOptions } from './type-only-sleep.ts';
					const stepDeadlineMilliseconds = 2_000;
					export async function run(condition: Promise<void>, options: SleepOptions): Promise<void> {
						await Promise.race([
							condition,
							new Promise<never>((_resolve, reject) => setTimeout(() => reject(new Error('hang')), hangBound)),
						]);
						await Promise.race([
							condition,
							new Promise<void>((resolve) => setTimeout(resolve, stepDeadlineMilliseconds)),
						]);
						await new Promise<void>((resolve, reject) => {
							const timer = setTimeout(() => reject(new Error('hang bound')), hangBound * 2);
							condition.then(() => {
								clearTimeout(timer);
								resolve();
							});
						});
						const delayed = new Promise<void>((resolve) => setTimeout(resolve, hangBound));
						await delayed;
						void options;
					}
				`,
				'tests/vitest-hang-bounds.ts': `
					export const endToEndTestTimeoutMilliseconds = 600_000;
				`,
				'tests/e2e/type-only-sleep.ts': `
					import type { Sleeper } from '../../scripts/sleeper.ts';
					export interface SleepOptions { readonly sleeper?: Sleeper }
				`,
				'scripts/sleeper.ts': `
					export type Sleeper = () => Promise<void>;
					export async function sleep(): Promise<void> {
						await new Promise<void>((resolve) => setTimeout(resolve, 10));
					}
				`,
			},
			async (packageRootPath: string): Promise<void> => {
				const report = await checkBridgeWebArchitecture({ packageRootPath });

				// Only the direct race with the bare hang bound (line 8) passes: a step
				// deadline, arithmetic on the bound, and a timer promise awaited later fail.
				expect(
					report.violations.map(
						(violation: ArchitectureViolation): string =>
							`${violation.relativePath}:${violation.line} ${violation.message.split(' in a ')[0]}`,
					),
				).toEqual([
					'tests/e2e/bounded-journey.e2e.test.ts:12 timer promise that is not a Promise.race hang bound',
					'tests/e2e/bounded-journey.e2e.test.ts:14 timer promise that is not a Promise.race hang bound',
					'tests/e2e/bounded-journey.e2e.test.ts:21 timer promise that is not a Promise.race hang bound',
				]);
			},
		);
	});
});

// A package shape with the Vitest configs and tsconfig the timed-wait rule reads.
const timedWaitFixturePackage: Record<string, string> = {
	'tsconfig.json': JSON.stringify({
		compilerOptions: {
			allowImportingTsExtensions: true,
			module: 'NodeNext',
			moduleResolution: 'NodeNext',
			noEmit: true,
			paths: { '@/*': ['./src/*'] },
		},
	}),
	'vitest.config.ts': `
		export default { test: { include: ['src/**/*.unit.test.ts'], setupFiles: ['./tests/setup.ts'] } };
	`,
	'vitest.e2e.config.ts': `
		export default { test: { include: ['tests/e2e/**/*.e2e.test.ts'] } };
	`,
	'tests/setup.ts': `
		export {};
	`,
};

async function withFixtureTree(
	files: Record<string, string>,
	runTest: (packageRootPath: string) => Promise<void>,
): Promise<void> {
	const packageRootPath = await mkdtemp(join(tmpdir(), 'bridgeweb-architecture-'));

	try {
		await Promise.all(
			Object.entries(files).map(async ([relativePath, content]) => {
				const filePath = join(packageRootPath, relativePath);
				await mkdir(join(filePath, '..'), { recursive: true });
				await writeFile(filePath, content, 'utf8');
			}),
		);
		await runTest(packageRootPath);
	} finally {
		await rm(packageRootPath, { force: true, recursive: true });
	}
}

function ruleIdForViolation(violation: ArchitectureViolation): string {
	return violation.ruleId;
}

function generatedLineSource(lineCount: number): string {
	return Array.from(
		{ length: lineCount },
		(_value: undefined, index: number): string => `export const value${index} = ${index};`,
	).join('\n');
}

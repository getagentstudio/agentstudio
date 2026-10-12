import { readFile } from 'node:fs/promises';

import { describe, expect, test } from 'vitest';

import {
	reviewStartupLoadTimingSatisfied,
	worktreeInteractionPerformanceSatisfied,
	worktreeStartupLoadTimingSatisfied,
} from '../verify-bridge-viewer-worktree-review-proof-performance.ts';
import {
	summarizeInteractionSamples,
	type WorktreeInteractionPerformanceProof,
	type WorktreeStartupLoadTimingProof,
} from '../verify-bridge-viewer-worktree-review-proof.ts';
import {
	makePassingInteractionPerformanceProof,
	makePassingReviewInteractionPerformanceProof,
} from './unit-test-fixtures.ts';

describe('Bridge Viewer startup load timing', () => {
	test('observes initial File milestones before complete metadata bootstrap', async () => {
		// Arrange
		const source = await readFile(new URL('./startup-load-timing.ts', import.meta.url), 'utf8');
		const functionStart = source.indexOf(
			'export async function collectWorktreeStartupLoadTimingProof',
		);
		const functionEnd = source.indexOf('export async function collectReviewStartupLoadTimingProof');
		// Act / Assert
		expect(functionStart).toBeGreaterThanOrEqual(0);
		expect(functionEnd).toBeGreaterThan(functionStart);
		expect(source).toContain("page.goto(worktreeDevServerUrl, { waitUntil: 'domcontentloaded'");
		expect(source).toContain('waitForBridgeHandshakeWorkerMilliseconds');
		expect(source).not.toContain('reloadWorktreeDevServerPage');
	});

	test('requires every causal File startup milestone', () => {
		// Arrange
		const completeTiming = {
			pageLoadToHandshakeWorker: summarizeInteractionSamples([20]),
			pageLoadToPageApplication: summarizeInteractionSamples([10]),
			pageLoadToContentReady: summarizeInteractionSamples([80]),
			pageLoadToContentRequestStarted: summarizeInteractionSamples([50]),
			pageLoadToContentResponseStarted: summarizeInteractionSamples([60]),
			pageLoadToFirstVisibleContentWindow: summarizeInteractionSamples([90]),
			pageLoadToMetadata: summarizeInteractionSamples([30]),
			pageLoadToSelectedPath: summarizeInteractionSamples([40]),
			pageLoadToShellMounted: summarizeInteractionSamples([10]),
			pageLoadToSourceAccepted: summarizeInteractionSamples([20]),
		} satisfies WorktreeStartupLoadTimingProof;

		// Act / Assert
		expect(worktreeStartupLoadTimingSatisfied({ startupLoadTiming: completeTiming })).toBe(true);
		for (const timingKey of Object.keys(completeTiming)) {
			const incompleteTiming = { ...completeTiming } as Record<string, unknown>;
			delete incompleteTiming[timingKey];
			expect(
				worktreeStartupLoadTimingSatisfied({
					startupLoadTiming: incompleteTiming as unknown as WorktreeStartupLoadTimingProof,
				}),
			).toBe(false);
		}
	});

	test('requires File click phase and startup attribution in interaction proof', () => {
		// Arrange
		const {
			clickPhaseDurations: _clickPhaseDurations,
			startupLoadTiming: _startupLoadTiming,
			...proofWithoutAttribution
		} = makePassingInteractionPerformanceProof();

		// Act / Assert
		expect(
			worktreeInteractionPerformanceSatisfied(
				proofWithoutAttribution as WorktreeInteractionPerformanceProof,
			),
		).toBe(false);
		expect(worktreeInteractionPerformanceSatisfied(makePassingInteractionPerformanceProof())).toBe(
			true,
		);
	});

	test('requires File startup load timing and tree scroll breakdowns', () => {
		// Arrange
		const passingProof = makePassingInteractionPerformanceProof();

		// Act / Assert
		expect(worktreeStartupLoadTimingSatisfied(passingProof)).toBe(true);
		expect(
			worktreeInteractionPerformanceSatisfied({
				...passingProof,
				startupLoadTiming: {
					...passingProof.startupLoadTiming,
					pageLoadToContentReady: summarizeInteractionSamples([]),
				},
			}),
		).toBe(false);
		expect(
			worktreeInteractionPerformanceSatisfied({
				...passingProof,
				treeScrollSettleFrameCount: summarizeInteractionSamples([]),
			}),
		).toBe(false);
	});

	test('rejects File startup phases at the one-second boundary', () => {
		// Arrange
		const passingProof = makePassingInteractionPerformanceProof();

		// Act / Assert
		for (const timingKey of Object.keys(passingProof.startupLoadTiming)) {
			expect(
				worktreeStartupLoadTimingSatisfied({
					startupLoadTiming: {
						...passingProof.startupLoadTiming,
						[timingKey]: summarizeInteractionSamples([1_000]),
					},
				}),
			).toBe(false);
		}
	});

	test('rejects Review startup phases at the one-second boundary', () => {
		// Arrange
		const passingProof = makePassingReviewInteractionPerformanceProof();

		// Act / Assert
		for (const timingKey of ['pageLoadToMetadata', 'pageLoadToSelectedContentReady'] as const) {
			expect(
				reviewStartupLoadTimingSatisfied({
					reviewStartupLoadTiming: {
						...passingProof.reviewStartupLoadTiming,
						[timingKey]: summarizeInteractionSamples([1_000]),
					},
				}),
			).toBe(false);
		}
	});

	test('routes startup-only proof without the broad descriptor corpus', async () => {
		// Arrange
		const [registeredVerifierSource, runnerSource] = await Promise.all([
			readFile(new URL('../verify-bridge-viewer-worktree-dev-server.ts', import.meta.url), 'utf8'),
			readFile(new URL('./runner.ts', import.meta.url), 'utf8'),
		]);

		// Act / Assert
		expect(registeredVerifierSource).toContain('startupOnlyMode');
		expect(registeredVerifierSource).toContain('runColdStartupSurfaceLifecycle');
		expect(runnerSource).toContain('runBridgeViewerWorktreeDevServerStartupSurfaceVerifier');
		expect(runnerSource).toContain('collectWorktreeStartupLoadTimingProof');
		expect(runnerSource).toContain('collectReviewStartupLoadTimingProof');
		expect(registeredVerifierSource.indexOf('if (startupOnlyMode)')).toBeLessThan(
			registeredVerifierSource.indexOf('const viteServer = await launch.startViteChild('),
		);
	});

	test('runs File and Review through independent cold Vite lifecycles', async () => {
		// Arrange
		const registeredVerifierSource = await readFile(
			new URL('../verify-bridge-viewer-worktree-dev-server.ts', import.meta.url),
			'utf8',
		);

		// Act
		const fileLifecycle = registeredVerifierSource.indexOf(
			"runColdStartupSurfaceLifecycle({ surface: 'file'",
		);
		const reviewLifecycle = registeredVerifierSource.indexOf(
			"runColdStartupSurfaceLifecycle({ surface: 'review'",
		);

		// Assert
		expect(fileLifecycle).toBeGreaterThanOrEqual(0);
		expect(reviewLifecycle).toBeGreaterThan(fileLifecycle);
		expect(registeredVerifierSource).toContain('const launch = await BridgeWebTestLaunch.start()');
		expect(registeredVerifierSource).toContain('bridgeDevelopmentServerOrigin:');
		expect(registeredVerifierSource).toContain('await launch.dispose()');
		expect(registeredVerifierSource).toContain('viteServer.startProof.origin');
	});

	test('cold collectors make repeated warm samples unrepresentable', async () => {
		// Arrange
		const source = await readFile(new URL('./startup-load-timing.ts', import.meta.url), 'utf8');

		// Act / Assert
		expect(source).not.toContain('sampleCount');
		expect(source).not.toContain('sampleIndex');
	});

	test('reserves an explicit loopback port for the self-hosted Vite server', async () => {
		// Arrange
		const registeredVerifierSource = await readFile(
			new URL('../verify-bridge-viewer-worktree-dev-server.ts', import.meta.url),
			'utf8',
		);

		// Act / Assert
		const harnessSource = await readFile(
			new URL('./product-only-real-router-regression.ts', import.meta.url),
			'utf8',
		);
		expect(harnessSource).toContain('const port = await reserveLoopbackPort()');
		expect(harnessSource).toContain("'127.0.0.1'");
		expect(harnessSource).toContain("'--strictPort'");
		expect(registeredVerifierSource).not.toContain('reserveLoopbackPort');
	});

	test('waits for owned backend health before loading the startup runner', async () => {
		// Arrange
		const registeredVerifierSource = await readFile(
			new URL('../verify-bridge-viewer-worktree-dev-server.ts', import.meta.url),
			'utf8',
		);

		// Act / Assert
		expect(registeredVerifierSource).toMatch(
			/await waitForBridgeProductBackendReady\([\s\S]*await loadRunner/u,
		);
		expect(registeredVerifierSource).toContain('/__bridge-product/health');
		expect(registeredVerifierSource).not.toContain('setTimeout');
		expect(registeredVerifierSource).not.toContain('while (Date.now()');
	});

	test('uses the one prebuilt owned backend instead of asking Vite to build it again', async () => {
		// Arrange
		const registeredVerifierSource = await readFile(
			new URL('../verify-bridge-viewer-worktree-dev-server.ts', import.meta.url),
			'utf8',
		);
		const performanceVerifierStart = registeredVerifierSource.indexOf(
			'async function runSelfHostedBridgeViewerPerformanceVerifier',
		);
		const performanceVerifierSource = registeredVerifierSource.slice(performanceVerifierStart);

		// Act / Assert
		expect(performanceVerifierStart).toBeGreaterThanOrEqual(0);
		expect(performanceVerifierSource).toContain('BridgeWebTestLaunch.start');
		expect(performanceVerifierSource).toContain("process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN']");
		expect(performanceVerifierSource).toMatch(
			/BridgeWebTestLaunch.start[\s\S]*BRIDGE_WEB_DEV_BACKEND_ORIGIN[\s\S]*launch.startVite/u,
		);
		expect(performanceVerifierSource).toContain('await launch.dispose()');
		expect(performanceVerifierSource).not.toContain('middlewareMode: true');
	});
});

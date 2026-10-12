import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

import { describe, expect, test, vi } from 'vitest';

import { createBridgeProductDeferred } from '../../src/core/comm-worker/bridge-product-async-queue.js';
import type { BridgeTelemetrySample } from '../../src/foundation/telemetry/bridge-telemetry-event.js';
import { endToEndTestTimeoutMilliseconds } from '../../tests/vitest-hang-bounds.ts';
import { createBridgeDevTelemetrySink } from '../dev-server/bridge-dev-telemetry.js';
import { worktreeDevServerOrigin } from './config.js';
import { assertSelectedContentRouteProof } from './content-state.js';
import {
	installReviewRouteProbe,
	mapBridgeTelemetrySampleToProof,
	waitForReviewContentRouteHitAfterIndex,
	waitForReviewContentRouteHitContaining,
	waitForReviewContentRouteHitCountAbove,
	type ReviewRouteProbePage,
} from './route-probes.ts';
import { bridgeDevTelemetryStatusSchema } from './types.js';
import type { WorktreeFileContentRouteProbe } from './types.js';
import { createOwnedVerifierJourneyDeadline } from './verifier-journey-deadline.ts';

const routeProbesSourcePath = fileURLToPath(new URL('./route-probes.ts', import.meta.url));

describe('Bridge dev telemetry status contract', () => {
	test('verifier schema accepts the product telemetry snapshot lifecycle contract', async () => {
		// Arrange
		const operationCorrelationId = 'a'.repeat(64);
		const sink = createBridgeDevTelemetrySink({
			collectorLogsUrl: 'http://127.0.0.1:4318/v1/logs',
			collectorMetricsUrl: 'http://127.0.0.1:4318/v1/metrics',
			fetchImpl: async (): Promise<Response> => new Response('', { status: 200 }),
			marker: 'vite-dev-schema-test',
			nowUnixNano: () => '1782218790000000000',
			serviceVersion: 'vite-dev',
			worktreeHash: 'worktree-hash',
		});
		const lifecycleSample = (phase: string): BridgeTelemetrySample => ({
			booleanAttributes: {},
			durationMilliseconds: null,
			name: 'performance.bridge.web.operation_lifecycle',
			numericAttributes: { 'agentstudio.bridge.stage.attempt': 0 },
			scope: 'web',
			stringAttributes: {
				'agentstudio.bridge.operation.id': operationCorrelationId,
				'agentstudio.bridge.phase': phase,
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': phase.endsWith('_started') ? 'started' : 'success',
				'agentstudio.bridge.slice': 'review_projection',
				'agentstudio.bridge.transport': 'worker',
				'agentstudio.bridge.viewer': 'review',
			},
			traceContext: null,
		});

		// Act
		await expect(
			sink.recordNativeObservation({
				source: 'server',
				scenario: 'schema-test',
				samples: [
					lifecycleSample('metadata_enqueue_started'),
					lifecycleSample('metadata_enqueue_terminal'),
					lifecycleSample('metadata_enqueue_started'),
				],
			}),
		).resolves.toBe(true);

		// Assert
		const parsed = bridgeDevTelemetryStatusSchema.safeParse(
			JSON.parse(JSON.stringify(sink.snapshot())),
		);
		if (!parsed.success)
			throw new Error(
				`Verifier telemetry schema rejected the product snapshot: ${parsed.error.message}`,
			);
		expect(parsed.data.operationLifecycle.completedOperationIds).toEqual([]);
		expect(parsed.data.operationLifecycle.malformed).toEqual([
			{
				kind: 'duplicate_start',
				operationCorrelationId,
				phaseFamily: 'metadata_enqueue',
				stageAttempt: 0,
			},
		]);
	});
});

describe('Bridge viewer product File content route probe', () => {
	test('correlates multiplexed product POST hits by typed descriptor identity', () => {
		// Arrange
		const productContentUrl =
			'http://127.0.0.1:5173/__bridge-product/content?scenario=current-worktree';
		const probe: WorktreeFileContentRouteProbe = {
			dispose: async (): Promise<void> => undefined,
			foreignHitCount: (): number => 0,
			foreignHitUrls: (): readonly string[] => [],
			hitCount: (): number => 2,
			hits: () => [
				{
					contentRequestId: 'request-old',
					descriptorId: 'descriptor-old',
					leaseId: 'lease-old',
					url: productContentUrl,
				},
				{
					contentRequestId: 'request-target',
					descriptorId: 'descriptor-target',
					leaseId: 'lease-target',
					url: productContentUrl,
				},
			],
			hitUrls: (): readonly string[] => [productContentUrl, productContentUrl],
		};

		// Act
		const proof = assertSelectedContentRouteProof({
			expectedContentHandle: 'descriptor-target',
			probe,
		});

		// Assert
		expect(proof.selectedResourceUrlContainsHandle).toBe(true);
		expect(proof.selectedResourceUrlUsesDevServerFrontDoor).toBe(true);
	});

	test('contains no legacy File content route matcher', async () => {
		const source = await readFile(routeProbesSourcePath, 'utf8');

		expect(source).toContain('parseBridgeWorktreeDevFileContentRouteRequest');
		expect(source).toContain("'**/__bridge-product/content**'");
		expect(source).not.toContain('/__bridge-worktree/file-content');
		expect(source).not.toContain('MatchesHandle');
	});

	test('retains worker queue correlation attributes from dev telemetry', () => {
		const proof = mapBridgeTelemetrySampleToProof({
			booleanAttributes: {},
			durationMilliseconds: 1,
			name: 'performance.bridge.worker.task',
			numericAttributes: { 'agentstudio.bridge.worker.queue_wait_ms': 9 },
			scope: 'web',
			stringAttributes: {
				'agentstudio.bridge.phase': 'worker_task',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.slice': 'worker_task',
				'agentstudio.bridge.transport': 'worker',
				'agentstudio.bridge.worker.command': 'select',
				'agentstudio.bridge.worker.lane': 'selected',
				'agentstudio.bridge.worker.task_kind': 'message_handler',
			},
			traceContext: null,
		});

		expect(proof.workerCommand).toBe('select');
		expect(proof.workerLane).toBe('selected');
		expect(proof.workerTaskKind).toBe('message_handler');
		expect(proof.numericAttributes['agentstudio.bridge.worker.queue_wait_ms']).toBe(9);
	});
});

describe('Review route probe owner completion', () => {
	test('the standalone runner deadline closes a withheld probe and its owned page', async (): Promise<void> => {
		vi.useFakeTimers();
		const page = recordingReviewProbePage();
		const closePage = vi.fn(async (): Promise<void> => {
			for (const [event, listener] of page.on.mock.calls) if (event === 'close') listener();
		});
		const deadline = createOwnedVerifierJourneyDeadline({
			closePages: closePage,
			pendingSteps: (): readonly string[] => ['withheld Review route'],
		});
		const probe = await installReviewRouteProbe(page, { signal: deadline.signal });
		const outcome = waitForReviewContentRouteHitAfterIndex({
			beforeHitCount: 0,
			expectedItemId: 'withheld-item',
			routeProbe: probe,
		}).then(
			(): string => 'unexpected completion',
			(error: unknown): string => String(error),
		);
		try {
			await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
			expect(await outcome).toContain('BRIDGE_VERIFIER_JOURNEY_DEADLINE_EXCEEDED');
			expect(await outcome).toContain('withheld-item');
			expect(await outcome).toContain('contentHitUrls=[]');
			expect(closePage).toHaveBeenCalledOnce();
		} finally {
			await probe.dispose();
			await deadline.dispose();
			vi.useRealTimers();
		}
		expect(page.unroute).toHaveBeenCalledTimes(2);
	});

	test('runner cancellation names the withheld request and observed URL history before cleanup', async (): Promise<void> => {
		const page = recordingReviewProbePage();
		const controller = new AbortController();
		const probe = await installReviewRouteProbe(page, { signal: controller.signal });
		const observed = waitForReviewContentRouteHitContaining({
			needle: 'withheld-target',
			routeProbe: probe,
		}).then(
			(): string => 'unexpected completion',
			(error: unknown): string => String(error),
		);
		controller.abort(new Error('BRIDGE_VERIFIER_JOURNEY_DEADLINE_EXCEEDED'));
		// Old implementation ignores the runner signal; release its pending wait too.
		for (const [event, listener] of page.on.mock.calls) if (event === 'close') listener();
		try {
			expect(await observed).toContain('BRIDGE_VERIFIER_JOURNEY_DEADLINE_EXCEEDED');
			expect(await observed).toContain('withheld-target');
			expect(await observed).toContain('contentHitUrls=[]');
		} finally {
			await probe.dispose();
		}
		expect(page.unroute).toHaveBeenCalledTimes(2);
	});

	test.each(['containing', 'count', 'descriptorDelta'] as const)(
		'closes a pending %s observation when its probe is disposed',
		async (waitKind): Promise<void> => {
			vi.useFakeTimers();
			const page = recordingReviewProbePage();
			const probe = await installReviewRouteProbe(page);
			const operation =
				waitKind === 'containing'
					? waitForReviewContentRouteHitContaining({ needle: 'target', routeProbe: probe })
					: waitKind === 'count'
						? waitForReviewContentRouteHitCountAbove({ minHitCount: 1, routeProbe: probe })
						: waitForReviewContentRouteHitAfterIndex({
								beforeHitCount: 0,
								expectedItemId: 'target',
								routeProbe: probe,
							});
			const outcome = operation.then(
				(): string => 'unexpected completion',
				(error: unknown): string => String(error),
			);
			try {
				await probe.dispose();
				// Exercise the old poll's complete virtual budget, never real elapsed time.
				await vi.advanceTimersByTimeAsync(10_000);
				expect(await outcome).toContain('Review content route probe closed');
			} finally {
				vi.useRealTimers();
			}
		},
	);

	test('awaits the exact post-opening descriptor delta before releasing gated content', async (): Promise<void> => {
		const page = recordingReviewProbePage();
		const gate = createBridgeProductDeferred<void>();
		const probe = await installReviewRouteProbe(page, { contentGate: gate });
		const requestTasks: Promise<void>[] = [];
		const deliver = (descriptorId: string): Promise<void> => {
			const request = { url: (): string => contentUrl(descriptorId) };
			const route = {
				request: () => request,
				continue: async (): Promise<void> => {},
				fulfill: async (): Promise<void> => {},
			};
			const callback = page.route.mock.calls.find(([pattern]) =>
				pattern.includes('/review-content/'),
			)?.[1];
			if (typeof callback !== 'function') throw new Error('Missing Review content route owner.');
			const task = callback(route);
			requestTasks.push(task);
			return probe.waitForContentHits((urls): boolean => urls.includes(contentUrl(descriptorId)));
		};
		try {
			await deliver('target-base');
			const beforeHitCount = probe.contentHitCount();
			const observedProofs: unknown[] = [];
			const readiness = waitForReviewContentRouteHitAfterIndex({
				beforeHitCount,
				expectedContentDescriptorIds: ['target-base', 'target-head'],
				expectedItemId: 'target-item',
				routeProbe: probe,
			}).then((proof) => {
				observedProofs.push(proof);
				return proof;
			});
			await deliver('unrelated');
			expect(observedProofs).toEqual([]);
			await deliver('target-head');
			const proof = await readiness;
			expect(proof.matchingPreClickHitUrls).toEqual([contentUrl('target-base')]);
			expect(proof.matchingPostClickHitUrls).toEqual([contentUrl('target-head')]);
			expect(proof.contentRouteSatisfiedBy).toBe('matching-post-click-route');
			await waitForReviewContentRouteHitContaining({ needle: 'target-head', routeProbe: probe });
			await waitForReviewContentRouteHitCountAbove({ minHitCount: 3, routeProbe: probe });
		} finally {
			gate.resolve();
			await Promise.all(requestTasks);
			await probe.dispose();
		}
	});

	test('page closure rejects a pending route observation', async (): Promise<void> => {
		const page = recordingReviewProbePage();
		const probe = await installReviewRouteProbe(page);
		const outcome = waitForReviewContentRouteHitCountAbove({
			minHitCount: 1,
			routeProbe: probe,
		}).then(
			(): string => 'unexpected completion',
			(error: unknown): string => String(error),
		);
		const closeListener = page.on.mock.calls.find(([event]) => event === 'close')?.[1];
		if (closeListener === undefined) throw new Error('Missing page-close observation.');
		closeListener();
		expect(await outcome).toContain('Review content route probe closed');
		await probe.dispose();
	});
});

function recordingReviewProbePage(): {
	readonly route: ReturnType<typeof vi.fn<ReviewRouteProbePage['route']>>;
	readonly unroute: ReturnType<typeof vi.fn<ReviewRouteProbePage['unroute']>>;
	readonly on: ReturnType<typeof vi.fn<ReviewRouteProbePage['on']>>;
	readonly off: ReturnType<typeof vi.fn<ReviewRouteProbePage['off']>>;
} {
	return {
		route: vi.fn<ReviewRouteProbePage['route']>().mockResolvedValue(undefined),
		unroute: vi.fn<ReviewRouteProbePage['unroute']>().mockResolvedValue(undefined),
		on: vi.fn<ReviewRouteProbePage['on']>(),
		off: vi.fn<ReviewRouteProbePage['off']>(),
	} satisfies ReviewRouteProbePage;
}

function contentUrl(descriptorId: string): string {
	return `${worktreeDevServerOrigin}/__bridge-worktree/review-content/${descriptorId}`;
}

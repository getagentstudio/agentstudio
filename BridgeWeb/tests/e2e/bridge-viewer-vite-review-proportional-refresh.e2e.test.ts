import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

import type { JSHandle, Page, Request } from 'playwright';
import { describe, expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { bridgeProductControlRequestSchema } from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import { bridgeTelemetryWorkerSnapshotSchema } from '../../src/core/telemetry-worker/bridge-telemetry-worker-contracts.js';
import {
	selectReviewFile,
	waitForSelectedReviewReady,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { waitForProductCallSettlement } from './bridge-viewer-vite-product-operation-response.ts';
import {
	bridgeViewerViteProductReviewUrl,
	requireBridgeViewerVitePrimaryReviewPath,
} from './bridge-viewer-vite-product-url.ts';
import { waitForSettledReviewComparison } from './bridge-viewer-vite-review-comparison-observation.ts';

const proportionalRefreshTimeoutMilliseconds = 120_000;
const retiredAndSuccessorAffectedFileIdentityCount = 2;

interface ReviewContentRequestObservation {
	readonly itemId: string | null;
	readonly responseStatus: number | null;
}

interface ReviewRefreshCandidateReadyObservation {
	readonly affectedStableFileCount: number;
	readonly presentationClass: string;
	readonly reviewGeneration: number;
}

interface ReviewRefreshTelemetryObservation {
	readonly candidateReady: ReviewRefreshCandidateReadyObservation | null;
	readonly candidates: readonly Readonly<Record<string, unknown>>[];
	readonly retainedWorkerTaskCounts: Readonly<Record<string, number>>;
}

interface ReviewRevisionIdentity {
	readonly packageId: string;
	readonly reviewGeneration: number;
	readonly revision: number;
}

interface AppliedReviewPublicationObservation {
	readonly displayed: ReviewRevisionIdentity | null;
	readonly publicationId: string;
}

interface AppliedReviewPublicationWithDisplayed extends AppliedReviewPublicationObservation {
	readonly displayed: ReviewRevisionIdentity;
}

describe('Bridge Viewer proportional Review refresh E2E', () => {
	test('keeps an unchanged selected item mounted without unrelated content opens after one changed worktree file', async () => {
		const fixture = await createBridgeViewerViteProductFixture();
		let server: Awaited<ReturnType<typeof startBridgeViewerOwnedViteProductServer>> | null = null;
		const browser = await launchBridgeViewerE2EChromium();
		let page: Page | null = null;
		let appliedPublications: ReturnType<typeof observeAppliedReviewPublications> | null = null;
		let primaryFailure: { readonly error: unknown } | null = null;
		try {
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			const reviewContentRequests = observeReviewContentRequests(page);
			appliedPublications = observeAppliedReviewPublications(page);
			await page.goto(
				bridgeViewerViteProductReviewUrl(
					server.origin,
					requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
				),
				{
					timeout: proportionalRefreshTimeoutMilliseconds,
					waitUntil: 'domcontentloaded',
				},
			);
			const affectedFile = fixture.oracle.reviewFiles[0];
			const unchangedFile = fixture.oracle.reviewFiles[1];
			if (affectedFile === undefined || unchangedFile === undefined) {
				throw new Error('Proportional Review refresh fixture requires two changed files.');
			}
			const initialComparison = await waitForSettledReviewComparison({
				expectedTargetLabel: 'HEAD',
				expectedTargetOID: fixture.oracle.baseRef,
				page,
				timeoutMilliseconds: proportionalRefreshTimeoutMilliseconds,
			});
			await selectReviewFile({ page, path: unchangedFile.path });
			await waitForSelectedReviewReady({ itemId: unchangedFile.itemId, page });
			const unchangedPaintedContainer = await waitForPaintedReviewItemContainer({
				itemId: unchangedFile.itemId,
				page,
			});
			const initialApplied = await appliedPublications.next();
			expect(initialApplied.publicationId.length).toBeGreaterThan(0);
			const contentRequestCountBeforeRefresh = reviewContentRequests.length;

			const reviewMutation = await fixture.mutateReviewFile();
			const refreshedApplied = await appliedPublications.nextAfter(initialComparison);
			const refreshedIdentity = refreshedApplied.displayed;
			await waitForSelectedReviewReady({ itemId: unchangedFile.itemId, page });
			const unchangedContainerRetained = await reviewItemContainerMatchesHandle({
				handle: unchangedPaintedContainer,
				itemId: unchangedFile.itemId,
				page,
			});
			const refreshContentRequests = reviewContentRequests.slice(contentRequestCountBeforeRefresh);

			expect(reviewMutation.path).toBe(affectedFile.path);
			expect(refreshedIdentity.packageId).toBe(initialComparison.packageId);
			expect(refreshedIdentity.reviewGeneration).toBe(initialComparison.reviewGeneration);
			expect(refreshedIdentity.revision).toBeGreaterThan(initialComparison.revision);
			expect(unchangedContainerRetained).toBe(true);
			expect(
				refreshContentRequests.every(
					(request): boolean =>
						request.itemId !== null &&
						request.itemId !== unchangedFile.itemId &&
						request.responseStatus === 200,
				),
			).toBe(true);
			expect(
				refreshContentRequests.some((request): boolean => request.itemId === unchangedFile.itemId),
			).toBe(false);

			await selectReviewFile({ page, path: reviewMutation.path });
			const selectedChangedPanel = page.locator(
				`[data-testid="bridge-code-view-panel"][data-selected-display-path=${JSON.stringify(reviewMutation.path)}][data-selected-content-state="ready"]`,
			);
			await selectedChangedPanel.waitFor({ state: 'attached' });
			const successorItemId = await selectedChangedPanel.getAttribute('data-selected-item-id');
			expect(successorItemId).toMatch(/\S/u);
			const changedBody = await readFile(join(fixture.oracle.worktreeRoot, reviewMutation.path));
			const changedSha256 = createHash('sha256').update(changedBody).digest('hex');
			const paintedChangedItem = await waitForPaintedReviewItemContainer({
				itemId: successorItemId ?? '',
				observedSha256: changedSha256,
				page,
			});
			const renderPublicationId = await paintedChangedItem.evaluate(
				(container): string | null =>
					container?.getAttribute('data-bridge-painted-publication-id') ?? null,
			);
			expect(renderPublicationId).toMatch(/^publication-\S+$/u);
			const settledChangedItem = page.locator(
				`diffs-container[data-bridge-painted-publication-id="${renderPublicationId}"][data-bridge-render-disposition-settled-publication-id="${renderPublicationId}"]`,
			);
			await settledChangedItem.waitFor({ state: 'visible' });
			expect(
				await settledChangedItem.getAttribute('data-bridge-render-disposition-settled-outcome'),
			).toBe('settled-ok');
			const telemetryReports = await drainReviewRefreshTelemetry(page);
			const telemetryLossSummary = requireTelemetryLossSummary(telemetryReports.drained);
			const lossAttribution = requireReviewRefreshLossAttribution({
				lossSummary: telemetryLossSummary,
				snapshot: telemetryReports.snapshot,
			});
			const telemetryObservation = await readReviewRefreshCandidateReady(
				new URL('/__bridge-dev-telemetry/status', page.url()).toString(),
				{
					affectedStableFileCount: retiredAndSuccessorAffectedFileIdentityCount,
					reviewGeneration: initialComparison.reviewGeneration,
				},
			);
			if (telemetryObservation.candidateReady === null) {
				throw new Error(
					`Review refresh did not emit the exact proportional candidate after telemetry drain: ${JSON.stringify({ lossSummary: telemetryLossSummary, lossAttribution, retainedWorkerTaskCounts: telemetryObservation.retainedWorkerTaskCounts, candidates: telemetryObservation.candidates })}`,
				);
			}
			const candidateReady = telemetryObservation.candidateReady;
			if (telemetryLossSummary['requiredLossCount'] !== 0) {
				throw new Error(
					`Review refresh candidate was observed with required telemetry loss: ${JSON.stringify({ candidateReady, candidates: telemetryObservation.candidates, lossSummary: telemetryLossSummary, lossAttribution })}`,
				);
			}
			expect(candidateReady).toEqual({
				affectedStableFileCount: retiredAndSuccessorAffectedFileIdentityCount,
				presentationClass: 'ordinary',
				reviewGeneration: initialComparison.reviewGeneration,
			});
		} catch (error: unknown) {
			primaryFailure = { error };
		} finally {
			await runAllOwnedCleanupOperations({
				operations: [
					{
						name: 'proportional Review applied receipt observer',
						run: async (): Promise<void> => appliedPublications?.dispose(),
					},
					{
						name: 'proportional Review refresh page',
						run: async (): Promise<void> => {
							await page?.close();
						},
					},
					{
						name: 'proportional Review refresh browser',
						run: async (): Promise<void> => {
							await browser.close();
						},
					},
					{
						name: 'proportional Review refresh server',
						run: async (): Promise<void> => {
							await server?.stop();
						},
					},
					{ name: 'proportional Review refresh fixture', run: fixture.dispose },
				],
				...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
			});
		}
	});
});

function observeReviewContentRequests(page: Page): ReviewContentRequestObservation[] {
	const observations: ReviewContentRequestObservation[] = [];
	const observationByRequest = new WeakMap<Request, number>();
	page.on('request', (request): void => {
		if (
			request.method() !== 'POST' ||
			new URL(request.url()).pathname !== '/__bridge-product/content'
		)
			return;
		const body: unknown = request.postDataJSON();
		if (!isUnknownRecord(body) || body['contentKind'] !== 'review.content') return;
		const descriptor = body['descriptor'];
		const itemId = isUnknownRecord(descriptor) ? descriptor['itemId'] : null;
		observationByRequest.set(
			request,
			observations.push({
				itemId: typeof itemId === 'string' ? itemId : null,
				responseStatus: null,
			}) - 1,
		);
	});
	page.on('response', (response): void => {
		const observationIndex = observationByRequest.get(response.request());
		if (observationIndex === undefined) return;
		const observation = observations[observationIndex];
		if (observation === undefined) return;
		observations[observationIndex] = { ...observation, responseStatus: response.status() };
	});
	return observations;
}

function observeAppliedReviewPublications(page: Page): {
	readonly dispose: () => void;
	readonly next: () => Promise<AppliedReviewPublicationObservation>;
	readonly nextAfter: (
		predecessor: ReviewRevisionIdentity,
	) => Promise<AppliedReviewPublicationWithDisplayed>;
} {
	const cancellation = new AbortController();
	const observations: AppliedReviewPublicationObservation[] = [];
	const waiters: Array<{
		readonly reject: (error: Error) => void;
		readonly resolve: (observation: AppliedReviewPublicationObservation) => void;
	}> = [];
	let failure: Error | null = null;
	let disposed = false;
	const fail = (reason: unknown): void => {
		if (disposed || failure !== null) return;
		failure = reason instanceof Error ? reason : new Error(String(reason));
		for (const waiter of waiters.splice(0)) waiter.reject(failure);
	};
	const publish = (observation: AppliedReviewPublicationObservation): void => {
		if (disposed || failure !== null) return;
		const waiter = waiters.shift();
		if (waiter === undefined) observations.push(observation);
		else waiter.resolve(observation);
	};
	const onRequest = (request: Request): void => {
		if (
			request.method() !== 'POST' ||
			new URL(request.url()).pathname !== '/__bridge-product/command'
		)
			return;
		const parsed = bridgeProductControlRequestSchema.safeParse(request.postDataJSON());
		if (
			!parsed.success ||
			parsed.data.kind !== 'product.call' ||
			parsed.data.call.method !== 'review.publication.applied'
		)
			return;
		const publicationId = parsed.data.call.request.publicationId;
		void waitForProductCallSettlement(
			page,
			(response): boolean => response.request() === request,
			cancellation.signal,
		)
			.then(async (settlement): Promise<void> => {
				if (
					!isUnknownRecord(settlement.result) ||
					settlement.result['kind'] !== 'call.completed' ||
					!isUnknownRecord(settlement.result['call']) ||
					settlement.result['call']['method'] !== 'review.publication.applied'
				) {
					throw new Error('Applied Review publication did not settle as a completed product call.');
				}
				const displayed = await page.evaluate(() => {
					const shell = document.querySelector('[data-testid="review-viewer-shell"]');
					return {
						packageId: shell?.getAttribute('data-review-metadata-id') ?? null,
						reviewGeneration: shell?.getAttribute('data-review-metadata-generation') ?? null,
						revision: shell?.getAttribute('data-review-metadata-revision') ?? null,
					};
				});
				const reviewGeneration =
					displayed.reviewGeneration === null ? null : Number(displayed.reviewGeneration);
				const revision = displayed.revision === null ? null : Number(displayed.revision);
				if (
					(reviewGeneration !== null && !Number.isSafeInteger(reviewGeneration)) ||
					(revision !== null && !Number.isSafeInteger(revision))
				) {
					throw new Error('Applied Review receipt has an invalid displayed package revision.');
				}
				publish({
					displayed:
						displayed.packageId === null || reviewGeneration === null || revision === null
							? null
							: { packageId: displayed.packageId, reviewGeneration, revision },
					publicationId,
				});
			})
			.catch(fail);
	};
	const onClose = (): void => fail(new Error('Page closed before the applied Review receipt.'));
	page.on('request', onRequest);
	page.on('close', onClose);
	const next = async (): Promise<AppliedReviewPublicationObservation> => {
		if (failure !== null) throw failure;
		const observed = observations.shift();
		if (observed !== undefined) return observed;
		return await new Promise((resolve, reject): void => {
			waiters.push({ reject, resolve });
		});
	};
	return {
		dispose: (): void => {
			if (disposed) return;
			disposed = true;
			page.off('request', onRequest);
			page.off('close', onClose);
			cancellation.abort();
			for (const waiter of waiters.splice(0)) {
				waiter.reject(new Error('Applied Review receipt observation was disposed.'));
			}
		},
		next,
		nextAfter: async (predecessor): Promise<AppliedReviewPublicationWithDisplayed> => {
			for (;;) {
				const observation = await next();
				const displayed = observation.displayed;
				if (
					displayed !== null &&
					displayed.packageId === predecessor.packageId &&
					displayed.reviewGeneration === predecessor.reviewGeneration &&
					displayed.revision > predecessor.revision
				)
					return { ...observation, displayed };
			}
		},
	};
}

async function readReviewRefreshCandidateReady(
	statusUrl: string,
	expected: {
		readonly affectedStableFileCount: number;
		readonly reviewGeneration: number;
	},
): Promise<ReviewRefreshTelemetryObservation> {
	const response = await fetch(statusUrl, { cache: 'no-store' });
	if (!response.ok) {
		throw new Error(`Review refresh telemetry status failed: HTTP ${response.status}.`);
	}
	const body: unknown = await response.json();
	if (!isUnknownRecord(body) || !Array.isArray(body['recentSamples'])) {
		throw new Error(
			`Review refresh telemetry status has no recent samples: ${JSON.stringify(body)}`,
		);
	}
	const candidates: Readonly<Record<string, unknown>>[] = [];
	const retainedWorkerTaskCounts: Record<string, number> = {};
	let candidateReady: ReviewRefreshCandidateReadyObservation | null = null;
	for (const sample of body['recentSamples'].toReversed()) {
		if (!isUnknownRecord(sample)) continue;
		const stringAttributes = sample['stringAttributes'];
		if (sample['name'] === 'performance.bridge.worker.task' && isUnknownRecord(stringAttributes)) {
			const taskKind = stringAttributes['agentstudio.bridge.worker.task_kind'];
			if (typeof taskKind === 'string') {
				retainedWorkerTaskCounts[taskKind] = (retainedWorkerTaskCounts[taskKind] ?? 0) + 1;
			}
		}
		if (sample['name'] !== 'performance.bridge.web.review_refresh_lifecycle') {
			continue;
		}
		const numericAttributes = sample['numericAttributes'];
		if (
			!isUnknownRecord(stringAttributes) ||
			stringAttributes['agentstudio.bridge.phase'] !== 'review_refresh_candidate_ready' ||
			!isUnknownRecord(numericAttributes)
		) {
			continue;
		}
		const affectedStableFileCount =
			numericAttributes['agentstudio.bridge.review.refresh.affected_stable_file.count'];
		const presentationClass =
			stringAttributes['agentstudio.bridge.review.refresh.presentation_class'];
		const reviewGeneration = numericAttributes['agentstudio.bridge.review.generation'];
		candidates.push({
			affectedStableFileCount: affectedStableFileCount ?? null,
			presentationClass: presentationClass ?? null,
			reviewGeneration: reviewGeneration ?? null,
			revision: numericAttributes['agentstudio.bridge.review.revision'] ?? null,
			correlation: sample['traceContext'] ?? null,
		});
		if (
			candidateReady === null &&
			typeof affectedStableFileCount === 'number' &&
			affectedStableFileCount === expected.affectedStableFileCount &&
			typeof presentationClass === 'string' &&
			presentationClass === 'ordinary' &&
			typeof reviewGeneration === 'number' &&
			reviewGeneration === expected.reviewGeneration
		) {
			candidateReady = { affectedStableFileCount, presentationClass, reviewGeneration };
		}
	}
	return { candidateReady, candidates, retainedWorkerTaskCounts };
}

function requireTelemetryLossSummary(report: unknown): Readonly<Record<string, unknown>> {
	const sidecar = isUnknownRecord(report) ? report['sidecar'] : null;
	if (
		!isUnknownRecord(sidecar) ||
		typeof sidecar['optionalLossCount'] !== 'number' ||
		typeof sidecar['proofEligible'] !== 'boolean' ||
		typeof sidecar['requiredLossCount'] !== 'number' ||
		typeof sidecar['sequenceGapCount'] !== 'number'
	) {
		throw new Error(
			`Proportional Review telemetry drain has no loss summary: ${JSON.stringify(report)}`,
		);
	}
	return sidecar;
}

async function drainReviewRefreshTelemetry(page: Page): Promise<{
	readonly drained: unknown;
	readonly snapshot: unknown;
}> {
	return await page.evaluate(async () => {
		const control: unknown = Reflect.get(globalThis, '__bridgeTelemetrySidecarControl');
		if (typeof control !== 'object' || control === null) {
			throw new Error('Review refresh telemetry sidecar control is unavailable.');
		}
		const drain: unknown = Reflect.get(control, 'drain');
		const snapshot: unknown = Reflect.get(control, 'snapshot');
		if (typeof drain !== 'function' || typeof snapshot !== 'function') {
			throw new Error('Review refresh telemetry sidecar has no drain or snapshot operation.');
		}
		const drained: unknown = await Reflect.apply(drain, control, []);
		const recordedSnapshot: unknown = await Reflect.apply(snapshot, control, []);
		return { drained, snapshot: recordedSnapshot };
	});
}

function requireReviewRefreshLossAttribution(props: {
	readonly lossSummary: Readonly<Record<string, unknown>>;
	readonly snapshot: unknown;
}): Readonly<Record<string, unknown>> {
	const report = isUnknownRecord(props.snapshot) ? props.snapshot['sidecar'] : null;
	const parsed = bridgeTelemetryWorkerSnapshotSchema.safeParse(report);
	if (!parsed.success) {
		throw new Error(
			`Review refresh telemetry snapshot is invalid: ${JSON.stringify(props.snapshot)}`,
		);
	}
	const lossByProducer = {
		main: { requiredCount: 0, optionalCount: 0 },
		comm: { requiredCount: 0, optionalCount: 0 },
	};
	for (const diagnostic of parsed.data.lossDiagnostics) {
		const counts = lossByProducer[diagnostic.producerId];
		counts.requiredCount += diagnostic.requiredCount;
		counts.optionalCount += diagnostic.optionalCount;
	}
	const attributedRequiredCount =
		lossByProducer.main.requiredCount + lossByProducer.comm.requiredCount;
	const attributedOptionalCount =
		lossByProducer.main.optionalCount + lossByProducer.comm.optionalCount;
	const aggregateRequiredCount = props.lossSummary['requiredLossCount'];
	const aggregateOptionalCount = props.lossSummary['optionalLossCount'];
	return {
		lossByProducer,
		lossDiagnostics: parsed.data.lossDiagnostics,
		lossDiagnosticsAtCapacity: parsed.data.lossDiagnostics.length === 16,
		unattributedRequiredCount:
			typeof aggregateRequiredCount === 'number'
				? aggregateRequiredCount - attributedRequiredCount
				: null,
		unattributedOptionalCount:
			typeof aggregateOptionalCount === 'number'
				? aggregateOptionalCount - attributedOptionalCount
				: null,
	};
}

async function waitForPaintedReviewItemContainer(props: {
	readonly itemId: string;
	readonly observedSha256?: string;
	readonly page: Page;
}): Promise<JSHandle<Element | null>> {
	return await props.page.waitForFunction(
		({ itemId, observedSha256 }): Element | null => {
			for (const container of document.querySelectorAll(
				'diffs-container[data-bridge-painted-source-correlations]',
			)) {
				const encodedCorrelations = container.getAttribute(
					'data-bridge-painted-source-correlations',
				);
				if (encodedCorrelations === null) continue;
				let correlations: unknown;
				try {
					correlations = JSON.parse(encodedCorrelations);
				} catch {
					continue;
				}
				if (
					Array.isArray(correlations) &&
					correlations.some(
						(correlation): boolean =>
							typeof correlation === 'object' &&
							correlation !== null &&
							'itemId' in correlation &&
							correlation.itemId === itemId &&
							(observedSha256 === undefined ||
								('observedSha256' in correlation && correlation.observedSha256 === observedSha256)),
					)
				)
					return container;
			}
			return null;
		},
		{ itemId: props.itemId, observedSha256: props.observedSha256 },
		{ timeout: proportionalRefreshTimeoutMilliseconds },
	);
}

async function reviewItemContainerMatchesHandle(props: {
	readonly handle: Awaited<ReturnType<typeof waitForPaintedReviewItemContainer>>;
	readonly itemId: string;
	readonly page: Page;
}): Promise<boolean> {
	return await props.handle.evaluate((initialContainer, itemId): boolean => {
		for (const container of document.querySelectorAll(
			'diffs-container[data-bridge-painted-source-correlations]',
		)) {
			const encodedCorrelations = container.getAttribute('data-bridge-painted-source-correlations');
			if (encodedCorrelations === null) continue;
			let correlations: unknown;
			try {
				correlations = JSON.parse(encodedCorrelations);
			} catch {
				continue;
			}
			if (
				Array.isArray(correlations) &&
				correlations.some(
					(correlation): boolean =>
						typeof correlation === 'object' &&
						correlation !== null &&
						'itemId' in correlation &&
						correlation.itemId === itemId,
				)
			)
				return initialContainer === container;
		}
		return false;
	}, props.itemId);
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

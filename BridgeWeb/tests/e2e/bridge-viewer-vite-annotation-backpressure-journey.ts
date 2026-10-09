import type { Page, Request } from 'playwright';
import { expect, test } from 'vitest';

import {
	annotationCatalogLongTasksOverlappingMainStaging,
	beginAnnotationCatalogLongTaskObservation,
	cloneSavedAnnotationMessagesIntoCompletedSession,
	finishAnnotationCatalogLongTaskObservation,
	latestAnnotationCatalogCommit,
	markAnnotationCatalogLongTaskPhase,
	observeAnnotationProjectionQueries,
	settleBrowserFrames,
	type AnnotationCatalogLongTaskEntry,
	type AnnotationCatalogLongTaskObservation,
	type AnnotationCatalogTransferTelemetryObservation,
	waitForAnnotationCatalogCommit,
} from './bridge-viewer-vite-annotation-catalog-performance.ts';
import {
	annotationReplyOpeningDiagnostic,
	observeAnnotationReplyInput,
} from './bridge-viewer-vite-annotation-reply-observation.ts';
import {
	runAnnotationSaveJourney,
	selectRangeForAnnotation,
	selectReviewFile,
	waitForSelectedFileReady,
	waitForSelectedReviewReady,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import {
	type CommittedAnnotationOutcome,
	waitForCommittedAnnotationOutcome,
} from './bridge-viewer-vite-annotation-wire-response-observation.ts';
import {
	type BackpressureTelemetryObservation,
	compactTelemetryDiagnostic,
	waitForBackpressureTelemetry,
} from './bridge-viewer-vite-backpressure-telemetry.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { observeSubscriptionReceiptQuiescence } from './bridge-viewer-vite-frame-acknowledgement-quiescence.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
	type BridgeViewerViteProductFixtureOracle,
} from './bridge-viewer-vite-product-fixture.ts';
import { bridgeViewerViteProductFileUrl } from './bridge-viewer-vite-product-url.ts';
import {
	observeBrowserRuntimeDiagnostics,
	readBrowserDiagnosticWithinDeadline,
	type BrowserRuntimeDiagnostics,
} from './bridge-viewer-vite-review-comparison-observation.ts';
import {
	installReviewRenderObservation,
	readReviewRenderObservation,
	readSelectedReviewReadinessDOMSnapshot,
	requireReviewRenderObservationStarted,
} from './bridge-viewer-vite-review-render-observation.ts';
import { observeSelectedItemApplies } from './bridge-viewer-vite-selected-item-apply-observation.ts';

const stressReviewItemCount = 1_699;
const stressAnnotationCatalogCloneCount = 2_000;
const stressJourneyTimeoutMilliseconds = 600_000;
const stressExecutionCeilingMilliseconds = 540_000;
const stressOperationTimeoutMilliseconds = 120_000;
const stressDiagnosticTimeoutMilliseconds = stressOperationTimeoutMilliseconds - 1_000;
const annotationCommandTimeoutMilliseconds = 30_000;
const cleanupOperationTimeoutMilliseconds = 30_000;
const renderReceiptLeaseMilliseconds = 5_000;

type ReplyOrdinal = 1 | 2 | 3 | 4 | 5;
type CommandTransition = 'committed' | 'waiting';
type JourneyMilestone =
	| 'assertions.complete'
	| 'assertions.running'
	| 'browser.launching'
	| 'browser.ready'
	| 'cleanup.fixture.disposed'
	| 'cleanup.fixture.disposing'
	| 'cleanup.server.stopped'
	| 'cleanup.server.stopping'
	| 'file.loading'
	| 'file.ready'
	| 'file.ready.waiting'
	| 'file.telemetry.ready'
	| 'file.telemetry.waiting'
	| 'fixture.ready'
	| 'fixture.starting'
	| 'review.bodies.verified'
	| 'review.bodies.verifying'
	| 'review.item-count.ready'
	| 'review.item-count.waiting'
	| 'review.loading'
	| 'review.range.selected'
	| 'review.range.selecting'
	| 'review.reload.complete'
	| 'review.reload.starting'
	| 'review.selected.ready'
	| 'review.selected.waiting'
	| 'review.selecting'
	| 'review.telemetry.ready'
	| 'review.telemetry.waiting'
	| 'root.body.visible'
	| 'root.body.waiting'
	| `reply.${ReplyOrdinal}.body.visible`
	| `reply.${ReplyOrdinal}.body.waiting`
	| `reply.${ReplyOrdinal}.composer.open`
	| `reply.${ReplyOrdinal}.composer.opening`
	| `reply.${ReplyOrdinal}.${'create' | 'flush' | 'save'}.${CommandTransition}`
	| `root.${'create' | 'flush' | 'save'}.${CommandTransition}`
	| 'server.ready'
	| 'server.starting'
	| 'stopped-demand.checked'
	| 'stopped-demand.checking'
	| 'test.start';

interface JourneyMilestoneDuration {
	readonly elapsedMilliseconds: number;
	readonly milestone: JourneyMilestone;
}

interface JourneyFailureDiagnostic {
	readonly catalogTelemetry?: AnnotationCatalogTelemetryObservation;
	readonly currentElapsedMilliseconds: number;
	readonly currentMilestone: JourneyMilestone;
	readonly errorKind: string;
	readonly errorMessage: string;
	readonly recentMilestones: readonly JourneyMilestoneDuration[];
	readonly telemetry?: readonly Readonly<Record<string, unknown>>[];
}

class AnnotationBackpressureMilestones {
	private catalogTelemetryDiagnostic: AnnotationCatalogTelemetryObservation | null = null;
	private currentMilestone: JourneyMilestone = 'test.start';
	private currentMilestoneStartedAt = performance.now();
	private readonly executionStartedAt = this.currentMilestoneStartedAt;
	private readonly completedMilestones: JourneyMilestoneDuration[] = [];
	private telemetryDiagnostic: readonly Readonly<Record<string, unknown>>[] | null = null;

	transition(nextMilestone: JourneyMilestone): void {
		const now = performance.now();
		this.completedMilestones.push({
			elapsedMilliseconds: Math.round(now - this.currentMilestoneStartedAt),
			milestone: this.currentMilestone,
		});
		this.currentMilestone = nextMilestone;
		this.currentMilestoneStartedAt = now;
		this.telemetryDiagnostic = null;
	}

	recordTelemetry(status: unknown, viewer: 'file' | 'review'): void {
		this.telemetryDiagnostic = compactTelemetryDiagnostic(status, viewer);
	}

	recordFailureTelemetry(status: unknown): void {
		this.telemetryDiagnostic = [
			...compactTelemetryDiagnostic(status, 'file'),
			...compactTelemetryDiagnostic(status, 'review'),
		];
	}

	recordCatalogTelemetry(observation: AnnotationCatalogTelemetryObservation): void {
		this.catalogTelemetryDiagnostic = observation;
	}

	currentTelemetryDiagnostic(): readonly Readonly<Record<string, unknown>>[] {
		return this.telemetryDiagnostic ?? [];
	}

	operationTimeoutMilliseconds(requestedTimeoutMilliseconds: number): number {
		const elapsedMilliseconds = performance.now() - this.executionStartedAt;
		return Math.max(
			1,
			Math.min(
				requestedTimeoutMilliseconds,
				stressExecutionCeilingMilliseconds - elapsedMilliseconds,
			),
		);
	}

	failureDiagnostic(error: unknown): JourneyFailureDiagnostic {
		return {
			...(this.catalogTelemetryDiagnostic === null
				? {}
				: { catalogTelemetry: this.catalogTelemetryDiagnostic }),
			currentElapsedMilliseconds: Math.round(performance.now() - this.currentMilestoneStartedAt),
			currentMilestone: this.currentMilestone,
			errorKind: error instanceof Error ? error.name : typeof error,
			errorMessage: error instanceof Error ? error.message : String(error),
			recentMilestones: this.completedMilestones.slice(-16),
			...(this.telemetryDiagnostic === null ? {} : { telemetry: this.telemetryDiagnostic }),
		};
	}
}

async function runMilestone<TResult>(props: {
	readonly after: JourneyMilestone;
	readonly before: JourneyMilestone;
	readonly milestones: AnnotationBackpressureMilestones;
	readonly operation: () => Promise<TResult>;
	readonly timeoutMilliseconds?: number;
}): Promise<TResult> {
	props.milestones.transition(props.before);
	const result = await withBoundedTimeout(
		props.operation(),
		props.milestones.operationTimeoutMilliseconds(
			props.timeoutMilliseconds ?? stressOperationTimeoutMilliseconds,
		),
	);
	props.milestones.transition(props.after);
	return result;
}

async function withBoundedTimeout<TResult>(
	operation: Promise<TResult>,
	timeoutMilliseconds: number,
): Promise<TResult> {
	let timeoutHandle: ReturnType<typeof setTimeout> | null = null;
	const timeout = new Promise<never>((_resolve, reject): void => {
		timeoutHandle = setTimeout((): void => {
			reject(new Error('Bounded E2E operation timed out.'));
		}, timeoutMilliseconds);
	});
	try {
		return await Promise.race([operation, timeout]);
	} finally {
		if (timeoutHandle !== null) clearTimeout(timeoutHandle);
	}
}

export function registerBridgeViewerViteAnnotationBackpressureJourneyTests(): void {
	test('1,699-item Review keeps root and five replies responsive and durable', async (): Promise<void> => {
		const milestones = new AnnotationBackpressureMilestones();
		let fixture: Awaited<ReturnType<typeof createBridgeViewerViteProductFixture>> | null = null;
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let failure: JourneyFailureDiagnostic | null = null;
		let cleanupFailure: JourneyFailureDiagnostic | null = null;
		let fixtureCleanupState: 'disposed' | 'failed' | 'not-created' = 'not-created';
		let serverCleanupState: 'failed' | 'not-started' | 'stopped' = 'not-started';
		try {
			const createdFixture = await runMilestone({
				after: 'fixture.ready',
				before: 'fixture.starting',
				milestones,
				operation: async () =>
					createBridgeViewerViteProductFixture({
						reviewChangedFileCount: stressReviewItemCount,
					}),
			});
			fixture = createdFixture;
			server = await runMilestone({
				after: 'server.ready',
				before: 'server.starting',
				milestones,
				operation: async () => startBridgeViewerOwnedViteProductServer(createdFixture.oracle),
			});
			const fileSeed = await runAnnotationSaveJourney({
				oracle: createdFixture.oracle,
				server,
				surface: 'file',
			});
			const releaseLargeCatalogFixture = await cloneSavedAnnotationMessagesIntoCompletedSession({
				cloneCount: stressAnnotationCatalogCloneCount,
				dataRootPath: createdFixture.oracle.dataRootPath,
				sourceMessageId: fileSeed.outputIdentity.messageId,
				sourceSessionId: fileSeed.outputIdentity.sessionId,
				sourceThreadId: fileSeed.outputIdentity.threadId,
			});
			const observations = await runAnnotationBackpressureJourney({
				milestones,
				oracle: createdFixture.oracle,
				releaseLargeCatalogFixture,
				server,
				undemandedSessionId: fileSeed.outputIdentity.sessionId,
			});
			milestones.transition('assertions.running');
			expect(createdFixture.oracle.reviewFiles).toHaveLength(stressReviewItemCount);
			expect(observations.exactBodyCountAfterReload).toBe(6);
			expect(new Set(observations.messageIds).size).toBe(6);
			expect(observations.catalogTelemetry.windowCount).toBeGreaterThanOrEqual(2);
			expect(observations.catalogTelemetry.maximumUnitByteCount).toBeLessThanOrEqual(128 * 1024);
			expect(observations.catalogTelemetry.presentationRevisionAfter).toBe(
				observations.catalogTelemetry.presentationRevisionBefore + 1,
			);
			expect(
				observations.catalogTelemetry.longTaskCountDelta,
				`catalog-scoped long-task count: ${JSON.stringify({
					continuousBounds: {
						mainBeginStartTimeMilliseconds:
							observations.catalogTelemetry.mainBeginStartTimeMilliseconds,
						mainCommitStartTimeMilliseconds:
							observations.catalogTelemetry.mainCommitStartTimeMilliseconds,
					},
					mainStagingSamples: observations.catalogTelemetry.mainStagingSamples,
					matchedEntries: observations.catalogTelemetry.longTasksOverlappingMainStaging,
					observation: observations.catalogTelemetry.longTaskObservation,
				})}`,
			).toBe(0);
			expect(
				observations.catalogTelemetry.undemandedSessionRichFetchCount,
				'undemanded-session rich-fetch count',
			).toBe(0);
			expect(
				observations.catalogTelemetry.undemandedSessionAcquireCount,
				'completed seed Review demand-acquire count',
			).toBe(0);
			expect(observations.fileTelemetry.currentCount, 'File outstanding publication count').toBe(0);
			expect(observations.fileTelemetry.highWaterMark).toBe(1);
			expect(
				observations.reviewTelemetry.currentCount,
				'Review outstanding publication count',
			).toBe(0);
			expect(observations.reviewTelemetry.highWaterMark).toBeGreaterThan(0);
			expect(observations.reviewTelemetry.highWaterMark).toBeLessThanOrEqual(12);
			expect(observations.reviewTelemetry.receiptProducedCount).toBeGreaterThan(0);
			expect(observations.reviewTelemetry.receiptPendingCount, 'Review pending receipt count').toBe(
				0,
			);
			expect(observations.reviewTelemetry.receiptHighWaterMark).toBeGreaterThan(0);
			expect(observations.reviewTelemetry.receiptHighWaterMark).toBeLessThanOrEqual(6_144);
			expect(observations.reviewTelemetry.maximumReceiptPendingAgeMilliseconds).toBeLessThan(
				renderReceiptLeaseMilliseconds,
			);
			expect(observations.reviewTelemetry.maximumPublicationAgeMilliseconds).toBeLessThan(
				renderReceiptLeaseMilliseconds,
			);
			expect(observations.reviewTelemetry.maximumWorkerQueueWaitMilliseconds).toBeLessThan(
				renderReceiptLeaseMilliseconds,
			);
			expect(observations.reviewTelemetry.responseBeforeOwnerEffectObserved).toBe(true);
			expect(observations.reviewTelemetry.failureCount, 'Review runtime failure count').toBe(0);
			milestones.transition('assertions.complete');
		} catch (error: unknown) {
			if (server !== null) {
				try {
					const telemetryResponse = await fetch(
						new URL('/__bridge-dev-telemetry/status', server.origin),
					);
					if (telemetryResponse.ok) {
						milestones.recordFailureTelemetry(await telemetryResponse.json());
					}
				} catch {
					// Preserve the product failure when optional diagnostics are unavailable.
				}
			}
			failure = milestones.failureDiagnostic(error);
		} finally {
			if (server !== null) {
				try {
					milestones.transition('cleanup.server.stopping');
					const cleanup = await withBoundedTimeout(
						server.stop(),
						cleanupOperationTimeoutMilliseconds,
					);
					expect(cleanup.forcedTerminationRequired).toBe(false);
					expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
					serverCleanupState = 'stopped';
					milestones.transition('cleanup.server.stopped');
				} catch (error: unknown) {
					serverCleanupState = 'failed';
					cleanupFailure = milestones.failureDiagnostic(error);
				}
			}
			if (fixture !== null) {
				try {
					milestones.transition('cleanup.fixture.disposing');
					await withBoundedTimeout(fixture.dispose(), cleanupOperationTimeoutMilliseconds);
					fixtureCleanupState = 'disposed';
					milestones.transition('cleanup.fixture.disposed');
				} catch (error: unknown) {
					fixtureCleanupState = 'failed';
					cleanupFailure ??= milestones.failureDiagnostic(error);
				}
			}
		}
		if (failure !== null || cleanupFailure !== null) {
			throw new Error(
				`Annotation backpressure journey failed: ${JSON.stringify({
					cleanup: {
						fixture: fixtureCleanupState,
						server: serverCleanupState,
					},
					failure,
					cleanupFailure,
				})}`,
			);
		}
	});
}

interface AnnotationBackpressureJourneyObservations {
	readonly catalogTelemetry: AnnotationCatalogTelemetryObservation;
	readonly exactBodyCountAfterReload: number;
	readonly fileTelemetry: BackpressureTelemetryObservation;
	readonly messageIds: readonly string[];
	readonly reviewTelemetry: BackpressureTelemetryObservation;
}

interface AnnotationCatalogTelemetryObservation {
	readonly longTaskCountDelta: number;
	readonly longTaskObservation: AnnotationCatalogLongTaskObservation;
	readonly longTasksOverlappingMainStaging: readonly AnnotationCatalogLongTaskEntry[];
	readonly mainBeginStartTimeMilliseconds: number;
	readonly mainCommitStartTimeMilliseconds: number;
	readonly mainStagingSamples: AnnotationCatalogTransferTelemetryObservation['mainStagingSamples'];
	readonly maximumUnitByteCount: number;
	readonly presentationRevisionAfter: number;
	readonly presentationRevisionBefore: number;
	readonly undemandedSessionAcquireCount: number;
	readonly undemandedSessionRichFetchCount: number;
	readonly windowCount: number;
}

async function runAnnotationBackpressureJourney(props: {
	readonly milestones: AnnotationBackpressureMilestones;
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly releaseLargeCatalogFixture: () => Promise<void>;
	readonly server: BridgeViewerOwnedViteProductServer;
	readonly undemandedSessionId: string;
}): Promise<AnnotationBackpressureJourneyObservations> {
	const browser = await runMilestone({
		after: 'browser.ready',
		before: 'browser.launching',
		milestones: props.milestones,
		operation: async () => launchBridgeViewerE2EChromium(),
	});
	let page: Page | null = null;
	const exactSavedBodies: string[] = [];
	try {
		const createdPage = await browser.newPage({ viewport: { height: 980, width: 1728 } });
		page = createdPage;
		const frameAcknowledgementQuiescence = observeSubscriptionReceiptQuiescence(createdPage);
		const selectedItemApplyObservation = observeSelectedItemApplies(createdPage);
		const observedReviewFile = props.oracle.reviewFiles[0];
		if (observedReviewFile === undefined)
			throw new Error('Stress Review fixture has no changed file.');
		await installReviewRenderObservation({ itemId: observedReviewFile.itemId, page: createdPage });
		let bootstrapRequestCount = 0;
		createdPage.on('request', (request: Request): void => {
			if (new URL(request.url()).pathname === '/__bridge-product/bootstrap') {
				bootstrapRequestCount += 1;
			}
		});
		const projectionQueries = observeAnnotationProjectionQueries(createdPage);
		const runtimeDiagnostics = observeBrowserRuntimeDiagnostics(createdPage);
		await runMilestone({
			after: 'file.ready.waiting',
			before: 'file.loading',
			milestones: props.milestones,
			operation: async () =>
				createdPage.goto(
					bridgeViewerViteProductFileUrl(props.server.origin, props.oracle.largeFilePath),
					{ timeout: stressJourneyTimeoutMilliseconds, waitUntil: 'domcontentloaded' },
				),
		});
		await runMilestone({
			after: 'file.ready',
			before: 'file.ready.waiting',
			milestones: props.milestones,
			operation: async () => waitForSelectedFileReady({ oracle: props.oracle, page: createdPage }),
		});
		const fileTelemetry = await runMilestone({
			after: 'file.telemetry.ready',
			before: 'file.telemetry.waiting',
			milestones: props.milestones,
			operation: async () =>
				waitForBackpressureTelemetry({
					expectedReceiptProducedCount: 3,
					milestones: props.milestones,
					page: createdPage,
					timeoutMilliseconds: 30_000,
					viewer: 'file',
				}),
			timeoutMilliseconds: 30_000,
		});
		await frameAcknowledgementQuiescence.wait();

		await runMilestone({
			after: 'review.item-count.waiting',
			before: 'review.loading',
			milestones: props.milestones,
			// Mode switching reuses the live session; document navigation starts a new one.
			operation: async () =>
				createdPage
					.getByTestId('bridge-viewer-mode-host-file')
					.getByTestId('bridge-viewer-context-review')
					.click(),
		});
		await runMilestone({
			after: 'review.item-count.ready',
			before: 'review.item-count.waiting',
			milestones: props.milestones,
			operation: async () =>
				waitForReviewItemCount({
					diagnostics: runtimeDiagnostics,
					expectedItemCount: stressReviewItemCount,
					failureContext: (): string => props.server.diagnostics(),
					page: createdPage,
				}),
		});
		expect(bootstrapRequestCount).toBe(1);
		const reviewFile = props.oracle.reviewFiles[0];
		if (reviewFile === undefined) throw new Error('Stress Review fixture has no changed file.');
		await runMilestone({
			after: 'review.selected.waiting',
			before: 'review.selecting',
			milestones: props.milestones,
			operation: async () => selectReviewFile({ page: createdPage, path: reviewFile.path }),
		});
		await runMilestone({
			after: 'review.selected.ready',
			before: 'review.selected.waiting',
			milestones: props.milestones,
			operation: async () =>
				waitForSelectedReviewReady({ itemId: reviewFile.itemId, page: createdPage }),
		});
		await runMilestone({
			after: 'review.range.selected',
			before: 'review.range.selecting',
			milestones: props.milestones,
			operation: async () => {
				await selectedItemApplyObservation.install(reviewFile.itemId);
				await requireReviewRenderObservationStarted(createdPage);
				return selectRangeForAnnotation({
					endLine: 5,
					page: createdPage,
					startLine: 2,
					surface: 'review',
				});
			},
		});

		const rootBody = 'Backpressure root body.';
		const replies: readonly { readonly body: string; readonly replyOrdinal: ReplyOrdinal }[] = [
			{ body: 'Backpressure reply 1.', replyOrdinal: 1 },
			{ body: 'Backpressure reply 2.', replyOrdinal: 2 },
			{ body: 'Backpressure reply 3.', replyOrdinal: 3 },
			{ body: 'Backpressure reply 4.', replyOrdinal: 4 },
			{ body: 'Backpressure reply 5.', replyOrdinal: 5 },
		];
		const bodies = [rootBody, ...replies.map((reply) => reply.body)];
		const messageIds: string[] = [];
		const catalogBaseline = await latestAnnotationCatalogCommit(createdPage);
		// The production probe is cumulative and PerformanceObserver delivery is asynchronous.
		// An operation-scoped observer prevents earlier Review interactions from entering this gate.
		await beginAnnotationCatalogLongTaskObservation(createdPage);
		let catalogTransferTelemetry: AnnotationCatalogTransferTelemetryObservation;
		let catalogLongTaskObservation: AnnotationCatalogLongTaskObservation;
		let rootOutcome: CommittedAnnotationOutcome;
		try {
			rootOutcome = await createAndSaveRoot({
				body: rootBody,
				milestones: props.milestones,
				onPerformancePhase: async (phase): Promise<void> =>
					await markAnnotationCatalogLongTaskPhase(createdPage, phase),
				page: createdPage,
			});
			expect(
				rootOutcome.sessionId.toLowerCase(),
				'completed File seed must remain distinct from the living Review root session',
			).not.toBe(props.undemandedSessionId.toLowerCase());
			messageIds.push(rootOutcome.messageId);
			catalogTransferTelemetry = await waitForAnnotationCatalogCommit({
				minimumCatalogRevisionExclusive: catalogBaseline.catalogRevision,
				page: createdPage,
			});
			await markAnnotationCatalogLongTaskPhase(createdPage, 'catalog_commit_observed');
			await settleBrowserFrames(createdPage, 2);
			await markAnnotationCatalogLongTaskPhase(createdPage, 'settled_frames');
			catalogLongTaskObservation = await finishAnnotationCatalogLongTaskObservation(createdPage);
		} catch (error: unknown) {
			await finishAnnotationCatalogLongTaskObservation(createdPage).catch((): void => {});
			throw error;
		}
		const longTasksOverlappingMainStaging = annotationCatalogLongTasksOverlappingMainStaging(
			catalogLongTaskObservation,
			catalogTransferTelemetry,
		);
		const catalogTelemetry: AnnotationCatalogTelemetryObservation = {
			...catalogTransferTelemetry,
			longTaskCountDelta: longTasksOverlappingMainStaging.length,
			longTaskObservation: catalogLongTaskObservation,
			longTasksOverlappingMainStaging,
			undemandedSessionAcquireCount: projectionQueries
				.acquiredSessionIds()
				.filter((sessionId) => sessionId.toLowerCase() === props.undemandedSessionId.toLowerCase())
				.length,
			undemandedSessionRichFetchCount: projectionQueries
				.sessionIdsForOperation(catalogTransferTelemetry.operationCorrelationId)
				.filter((sessionId) => sessionId.toLowerCase() === props.undemandedSessionId.toLowerCase())
				.length,
		};
		props.milestones.recordCatalogTelemetry(catalogTelemetry);
		await props.releaseLargeCatalogFixture();
		exactSavedBodies.push(rootBody);
		for (const { body, replyOrdinal } of replies) {
			// oxlint-disable-next-line no-await-in-loop -- Every reply must commit before the next exact thread revision.
			const replyMessageId = await createAndSaveReply({
				body,
				canonicalRoot: rootOutcome,
				milestones: props.milestones,
				page: createdPage,
				replyOrdinal,
			});
			messageIds.push(replyMessageId);
			props.milestones.transition(`reply.${replyOrdinal}.body.waiting`);
			// oxlint-disable-next-line no-await-in-loop -- Inspectability is checked after each mutation.
			await withBoundedTimeout(
				createdPage.getByText(body, { exact: true }).waitFor({
					state: 'visible',
					timeout: stressJourneyTimeoutMilliseconds,
				}),
				props.milestones.operationTimeoutMilliseconds(annotationCommandTimeoutMilliseconds),
			);
			props.milestones.transition(`reply.${replyOrdinal}.body.visible`);
			exactSavedBodies.push(body);
		}
		const reviewTelemetry = await runMilestone({
			after: 'review.telemetry.ready',
			before: 'review.telemetry.waiting',
			milestones: props.milestones,
			operation: async () =>
				waitForBackpressureTelemetry({
					expectedReceiptProducedCount: null,
					milestones: props.milestones,
					page: createdPage,
					timeoutMilliseconds: stressJourneyTimeoutMilliseconds,
					viewer: 'review',
				}),
		});
		await Promise.all([
			createdPage.waitForRequest(fileActiveViewerModeUpdateRequestMatches, {
				timeout: stressOperationTimeoutMilliseconds,
			}),
			createdPage
				.getByTestId('bridge-viewer-mode-host-review')
				.getByTestId('bridge-viewer-context-file')
				.click(),
		]);
		await expect
			.poll(
				async (): Promise<string | null> =>
					await createdPage
						.getByTestId('bridge-viewer-mode-host-file')
						.getAttribute('data-bridge-viewer-mode-active'),
				{ timeout: stressOperationTimeoutMilliseconds },
			)
			.toBe('true');
		await settleBrowserFrames(createdPage, 2);
		await runMilestone({
			after: 'stopped-demand.checked',
			before: 'stopped-demand.checking',
			milestones: props.milestones,
			operation: async () => {
				try {
					const stoppedDemandObservation = await waitForBackpressureTelemetry({
						expectedReceiptProducedCount: null,
						milestones: props.milestones,
						page: createdPage,
						timeoutMilliseconds: stressDiagnosticTimeoutMilliseconds,
						viewer: 'review',
					});
					console.info(
						'Stopped Review demand telemetry',
						JSON.stringify({
							observation: stoppedDemandObservation,
							telemetry: props.milestones.currentTelemetryDiagnostic(),
						}),
					);
					return stoppedDemandObservation;
				} catch (error: unknown) {
					throw new Error(
						`Stopped Review demand did not quiesce: ${await runtimeDiagnostics.describe()}; publications=${JSON.stringify(await readBrowserDiagnosticWithinDeadline(readReviewRenderObservation(createdPage)))}; cause=${error instanceof Error ? error.message : String(error)}.`,
						{ cause: error },
					);
				}
			},
		});

		await runMilestone({
			after: 'review.reload.complete',
			before: 'review.reload.starting',
			milestones: props.milestones,
			operation: async () =>
				createdPage.reload({
					timeout: stressJourneyTimeoutMilliseconds,
					waitUntil: 'domcontentloaded',
				}),
		});
		// Reload reopens the original File-target URL. Re-enter Review through its control.
		await runMilestone({
			after: 'file.ready',
			before: 'file.ready.waiting',
			milestones: props.milestones,
			operation: async () => waitForSelectedFileReady({ oracle: props.oracle, page: createdPage }),
		});
		expect(bootstrapRequestCount).toBe(2);
		await frameAcknowledgementQuiescence.wait();
		await createdPage
			.getByTestId('bridge-viewer-mode-host-file')
			.getByTestId('bridge-viewer-context-review')
			.click();
		await runMilestone({
			after: 'review.item-count.ready',
			before: 'review.item-count.waiting',
			milestones: props.milestones,
			operation: async () =>
				waitForReviewItemCount({
					diagnostics: runtimeDiagnostics,
					expectedItemCount: stressReviewItemCount,
					failureContext: (): string => props.server.diagnostics(),
					page: createdPage,
				}),
		});
		expect(bootstrapRequestCount).toBe(2);
		await selectReviewFile({ page: createdPage, path: reviewFile.path });
		try {
			await runMilestone({
				after: 'review.selected.ready',
				before: 'review.selected.waiting',
				milestones: props.milestones,
				operation: async () =>
					waitForSelectedReviewReady({ itemId: reviewFile.itemId, page: createdPage }),
			});
		} catch (error: unknown) {
			const [readinessDOM, renderObservation] = await Promise.all([
				readBrowserDiagnosticWithinDeadline(
					readSelectedReviewReadinessDOMSnapshot({
						expectedItemId: reviewFile.itemId,
						page: createdPage,
					}),
				),
				readBrowserDiagnosticWithinDeadline(readReviewRenderObservation(createdPage)),
			]);
			throw new Error(
				`Post-reload selected Review readiness failed: dom=${JSON.stringify(readinessDOM)} publications=${JSON.stringify(renderObservation)}`,
				{ cause: error },
			);
		}
		const exactBodyCountAfterReload = await runMilestone({
			after: 'review.bodies.verified',
			before: 'review.bodies.verifying',
			milestones: props.milestones,
			operation: async (): Promise<number> => {
				const expansion = createdPage.getByRole('button', {
					name: `Expand ${bodies.length} annotations`,
				});
				await expansion.waitFor({
					state: 'visible',
					timeout: stressJourneyTimeoutMilliseconds,
				});
				await expansion.click();
				let exactBodyCount = 0;
				for (const body of bodies) {
					// oxlint-disable-next-line no-await-in-loop -- Each exact durable body is independently verified.
					await createdPage.getByText(body, { exact: true }).waitFor({
						state: 'visible',
						timeout: stressJourneyTimeoutMilliseconds,
					});
					// oxlint-disable-next-line no-await-in-loop -- Each exact durable body count is independently verified.
					exactBodyCount += await createdPage.getByText(body, { exact: true }).count();
				}
				return exactBodyCount;
			},
		});
		return {
			catalogTelemetry,
			exactBodyCountAfterReload,
			fileTelemetry,
			messageIds,
			reviewTelemetry,
		};
	} finally {
		await page?.close();
		await browser.close();
	}
}

async function waitForReviewItemCount(props: {
	readonly diagnostics: BrowserRuntimeDiagnostics;
	readonly expectedItemCount: number;
	readonly failureContext: () => string;
	readonly page: Page;
}): Promise<void> {
	try {
		await props.page.waitForFunction(
			(count: number): boolean => {
				const shell = document.querySelector('[data-testid="review-viewer-shell"]');
				const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
				return (
					Number(shell?.getAttribute('data-review-metadata-item-count')) === count &&
					Number(panel?.getAttribute('data-code-view-item-count')) === count
				);
			},
			props.expectedItemCount,
			{ timeout: stressDiagnosticTimeoutMilliseconds },
		);
	} catch (error: unknown) {
		const [browserDiagnostic, publicationDiagnostic] = await Promise.all([
			props.diagnostics.describe(),
			readBrowserDiagnosticWithinDeadline(readReviewRenderObservation(props.page)),
		]);
		throw new Error(
			`Review item count did not settle: browser=${browserDiagnostic} publications=${JSON.stringify(publicationDiagnostic)} server=${props.failureContext()}`,
			{ cause: error },
		);
	}
}

async function createAndSaveRoot(props: {
	readonly body: string;
	readonly milestones: AnnotationBackpressureMilestones;
	readonly onPerformancePhase: (phase: string) => Promise<void>;
	readonly page: Page;
}): Promise<CommittedAnnotationOutcome> {
	const composer = props.page.getByRole('textbox', { name: 'Write an annotation in Markdown' });
	props.milestones.transition('root.create.waiting');
	const createOutcome = waitForCommittedAnnotationOutcome(props.page, 'root.create');
	await composer.fill(`${props.body} initial`);
	await props.onPerformancePhase('root_create_fill_complete');
	const created = await withBoundedTimeout(
		createOutcome,
		props.milestones.operationTimeoutMilliseconds(annotationCommandTimeoutMilliseconds),
	);
	await props.onPerformancePhase('root_create_committed');
	props.milestones.transition('root.create.committed');
	props.milestones.transition('root.flush.waiting');
	const flushOutcome = waitForCommittedAnnotationOutcome(props.page, 'draft.flush');
	await composer.fill(props.body);
	await props.onPerformancePhase('root_flush_fill_complete');
	assertSameMessage(
		created,
		await withBoundedTimeout(
			flushOutcome,
			props.milestones.operationTimeoutMilliseconds(annotationCommandTimeoutMilliseconds),
		),
	);
	await props.onPerformancePhase('root_flush_committed');
	props.milestones.transition('root.flush.committed');
	props.milestones.transition('root.save.waiting');
	const saveOutcome = waitForCommittedAnnotationOutcome(props.page, 'draft.save');
	await props.page.getByRole('button', { name: 'Save annotation' }).click();
	await props.onPerformancePhase('root_save_clicked');
	assertSameMessage(
		created,
		await withBoundedTimeout(
			saveOutcome,
			props.milestones.operationTimeoutMilliseconds(annotationCommandTimeoutMilliseconds),
		),
	);
	await props.onPerformancePhase('root_save_committed');
	props.milestones.transition('root.save.committed');
	props.milestones.transition('root.body.waiting');
	await withBoundedTimeout(
		props.page.getByText(props.body, { exact: true }).waitFor({
			state: 'visible',
			timeout: stressJourneyTimeoutMilliseconds,
		}),
		props.milestones.operationTimeoutMilliseconds(annotationCommandTimeoutMilliseconds),
	);
	await props.onPerformancePhase('root_body_visible');
	props.milestones.transition('root.body.visible');
	return created;
}

async function createAndSaveReply(props: {
	readonly body: string;
	readonly canonicalRoot: CommittedAnnotationOutcome;
	readonly milestones: AnnotationBackpressureMilestones;
	readonly page: Page;
	readonly replyOrdinal: ReplyOrdinal;
}): Promise<string> {
	props.milestones.transition(`reply.${props.replyOrdinal}.composer.opening`);
	const replyButton = props.page.getByRole('button', { name: 'Reply to annotation thread' }).last();
	const composer = props.page.getByRole('textbox', { name: 'Reply with Markdown' });
	await observeAnnotationReplyInput(props.page);
	try {
		await replyButton.click();
		await withBoundedTimeout(
			composer.waitFor({ state: 'visible', timeout: stressJourneyTimeoutMilliseconds }),
			props.milestones.operationTimeoutMilliseconds(annotationCommandTimeoutMilliseconds),
		);
	} catch (error: unknown) {
		throw new Error(
			`Reply ${props.replyOrdinal} composer did not open: ${JSON.stringify(
				await annotationReplyOpeningDiagnostic({
					canonicalRoot: props.canonicalRoot,
					page: props.page,
				}),
			)}`,
			{ cause: error },
		);
	}
	props.milestones.transition(`reply.${props.replyOrdinal}.composer.open`);
	props.milestones.transition(`reply.${props.replyOrdinal}.create.waiting`);
	const createOutcome = waitForCommittedAnnotationOutcome(props.page, 'reply.create');
	await composer.fill(`${props.body} initial`);
	const created = await withBoundedTimeout(
		createOutcome,
		props.milestones.operationTimeoutMilliseconds(annotationCommandTimeoutMilliseconds),
	);
	props.milestones.transition(`reply.${props.replyOrdinal}.create.committed`);
	props.milestones.transition(`reply.${props.replyOrdinal}.flush.waiting`);
	const flushOutcome = waitForCommittedAnnotationOutcome(props.page, 'draft.flush');
	await composer.fill(props.body);
	assertSameMessage(
		created,
		await withBoundedTimeout(
			flushOutcome,
			props.milestones.operationTimeoutMilliseconds(annotationCommandTimeoutMilliseconds),
		),
	);
	props.milestones.transition(`reply.${props.replyOrdinal}.flush.committed`);
	props.milestones.transition(`reply.${props.replyOrdinal}.save.waiting`);
	const saveOutcome = waitForCommittedAnnotationOutcome(props.page, 'draft.save');
	await props.page.getByRole('button', { name: 'Save annotation' }).last().click();
	assertSameMessage(
		created,
		await withBoundedTimeout(
			saveOutcome,
			props.milestones.operationTimeoutMilliseconds(annotationCommandTimeoutMilliseconds),
		),
	);
	props.milestones.transition(`reply.${props.replyOrdinal}.save.committed`);
	await withBoundedTimeout(
		composer.waitFor({ state: 'hidden', timeout: stressJourneyTimeoutMilliseconds }),
		props.milestones.operationTimeoutMilliseconds(annotationCommandTimeoutMilliseconds),
	);
	return created.messageId;
}

function assertSameMessage(
	created: CommittedAnnotationOutcome,
	updated: CommittedAnnotationOutcome,
): void {
	if (created.messageId !== updated.messageId) {
		throw new Error('Annotation message identity changed across committed outcomes.');
	}
	if (created.sessionId !== updated.sessionId) {
		throw new Error('Annotation session identity changed across committed outcomes.');
	}
}

function fileActiveViewerModeUpdateRequestMatches(request: Request): boolean {
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	) {
		return false;
	}
	const body: unknown = request.postDataJSON();
	return (
		isRecord(body) &&
		body['kind'] === 'product.call' &&
		isRecord(body['call']) &&
		body['call']['method'] === 'file.activeViewerMode.update'
	);
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

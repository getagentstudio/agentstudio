import type { Page } from 'playwright';

import {
	fileUsablePaintIsVisible,
	reviewUsablePaintIsVisible,
} from '../../src/foundation/diagnostics/bridge-complete-journey-usable-paint.ts';
import type {
	BridgeCompleteJourney,
	BridgeCompleteJourneyAttempt,
	BridgeCompleteJourneyLaunch,
	BridgeCompleteJourneyLaunchEvidence,
	BridgeCompleteJourneyPhaseCompletions,
} from './complete-journey-cohort.ts';
import {
	maximumBridgeCompleteJourneyActivationSequence,
	waitForBridgeCompleteJourneyActivationSequence,
	waitForBridgeCompleteJourneyTelemetryWitnesses,
} from './complete-journey-telemetry.ts';
import { worktreeDevServerOrigin } from './config.ts';
import { makeVerificationPage } from './page-factory.ts';
import {
	collectReviewStartupTimingSample,
	collectWorktreeStartupTimingSample,
	type ReviewStartupTimingSample,
	type WorktreeStartupTimingSample,
} from './startup-load-timing.ts';
import { bridgeDevTelemetryStatusSchema } from './types.ts';

export interface BridgeDevelopmentCompleteJourneyLaunch {
	readonly attemptsByJourney: Readonly<
		Record<BridgeCompleteJourney, readonly BridgeCompleteJourneyAttempt[]>
	>;
	readonly evidence: BridgeCompleteJourneyLaunchEvidence;
	readonly launchId: string;
}

const bridgeCompleteJourneyAttemptTimeoutMilliseconds = 30_000;
const bridgeCompleteJourneyTelemetryEvidenceSchema = bridgeDevTelemetryStatusSchema
	.pick({
		acceptedSampleCount: true,
		failedBatchCount: true,
		marker: true,
		serviceVersion: true,
		worktreeHash: true,
	})
	.loose();

type CompleteJourneyAttemptRunner = (props: {
	readonly journey: BridgeCompleteJourney;
	readonly markCompletedPhases: (phases: BridgeCompleteJourneyPhaseCompletions) => void;
	readonly markFailureReason: (reason: string) => void;
	readonly markTimingStarted: (startedAt: number) => void;
	readonly page: Page;
}) => Promise<BridgeCompleteJourneyPhaseCompletions>;

export interface BridgeCompleteJourneyCollectorDependencies {
	readonly collectJourney?: CompleteJourneyAttemptRunner;
	readonly makePage?: (signal: AbortSignal) => Promise<Page>;
	readonly onAttemptStarted?: (attemptId: string) => void;
	readonly ownerSignal?: AbortSignal;
	readonly observeStep?: <TValue>(name: string, promise: Promise<TValue>) => Promise<TValue>;
	readonly pendingSteps?: Set<string>;
	readonly renewLaunchHangBound?: () => void;
}

export async function collectBridgeDevelopmentCompleteJourneyLaunch(
	props: {
		readonly attemptCount: number;
		readonly launchId: string;
		readonly sourceHead: string;
	},
	dependencies: BridgeCompleteJourneyCollectorDependencies = {},
): Promise<BridgeDevelopmentCompleteJourneyLaunch> {
	const attemptsByJourney = {
		fileToReview: [] as BridgeCompleteJourneyAttempt[],
		firstFile: [] as BridgeCompleteJourneyAttempt[],
		firstReview: [] as BridgeCompleteJourneyAttempt[],
		reviewToFile: [] as BridgeCompleteJourneyAttempt[],
	};
	for (const journey of bridgeCompleteJourneys) {
		for (let attemptIndex = 0; attemptIndex < props.attemptCount; attemptIndex += 1) {
			attemptsByJourney[journey].push(
				// oxlint-disable-next-line no-await-in-loop -- Each measured page lifecycle is intentionally independent and serial.
				await collectBridgeDevelopmentCompleteJourneyAttempt({
					attemptId: `${props.launchId}-${journey}-${attemptIndex}`,
					dependencies,
					journey,
				}),
			);
		}
	}
	const telemetryStatusResponse = await fetch(
		new URL('/__bridge-dev-telemetry/status', worktreeDevServerOrigin),
	);
	const telemetryStatus = bridgeCompleteJourneyTelemetryEvidenceSchema.parse(
		await telemetryStatusResponse.json(),
	);
	return {
		attemptsByJourney,
		evidence: {
			cacheState: 'fresh-empty-vite-cache',
			fixtureIdentity: 'current-worktree',
			sourceHead: props.sourceHead,
			telemetryMarker: telemetryStatus.marker,
			telemetryServiceVersion: telemetryStatus.serviceVersion,
			telemetry: {
				acceptedSampleCount: telemetryStatus.acceptedSampleCount,
				failedBatchCount: telemetryStatus.failedBatchCount,
				kind: 'development-batches',
			},
			worktreeHash: telemetryStatus.worktreeHash,
		},
		launchId: props.launchId,
	};
}

export function bridgeCompleteJourneyLaunchForJourney(
	launch: BridgeDevelopmentCompleteJourneyLaunch,
	journey: BridgeCompleteJourney,
): BridgeCompleteJourneyLaunch {
	return {
		attempts: launch.attemptsByJourney[journey],
		evidence: launch.evidence,
		launchId: launch.launchId,
	};
}

async function collectBridgeDevelopmentCompleteJourneyAttempt(props: {
	readonly attemptId: string;
	readonly dependencies: BridgeCompleteJourneyCollectorDependencies;
	readonly journey: BridgeCompleteJourney;
}): Promise<BridgeCompleteJourneyAttempt> {
	let attemptStartedAt = performance.now();
	let failureReason = 'journey_failed';
	let completedPhases: BridgeCompleteJourneyPhaseCompletions = {};
	let page: Page | null = null;
	const ownerSignal = props.dependencies.ownerSignal ?? new AbortController().signal;
	const pendingSteps = props.dependencies.pendingSteps ?? new Set<string>();
	props.dependencies.renewLaunchHangBound?.();
	props.dependencies.onAttemptStarted?.(props.attemptId);
	try {
		page = await awaitCompleteJourneyStep({
			label: 'verifier page acquisition',
			operation: (
				props.dependencies.makePage ?? ((signal): Promise<Page> => makeVerificationPage({ signal }))
			)(ownerSignal),
			ownerSignal,
			observeStep: props.dependencies.observeStep,
			pendingSteps,
			signal: ownerSignal,
		});
		const phaseCompletionElapsedMilliseconds = await awaitCompleteJourneyStep({
			label: `${props.journey} journey`,
			operation: (props.dependencies.collectJourney ?? collectSuccessfulJourney)({
				journey: props.journey,
				markCompletedPhases: (phases): void => {
					completedPhases = { ...completedPhases, ...phases };
				},
				markFailureReason: (reason): void => {
					failureReason = reason;
				},
				markTimingStarted: (startedAt): void => {
					attemptStartedAt = startedAt;
				},
				page,
			}),
			ownerSignal,
			observeStep: props.dependencies.observeStep,
			pendingSteps,
			signal: ownerSignal,
		});
		return {
			attemptId: props.attemptId,
			durationMilliseconds: phaseCompletionElapsedMilliseconds.commitPaint ?? 0,
			outcome: 'succeeded',
			phaseCompletionElapsedMilliseconds,
		};
	} catch (error: unknown) {
		if (ownerSignal.aborted) throw error;
		return bridgeCompleteJourneyFailedAttempt({
			attemptId: props.attemptId,
			durationMilliseconds: Math.min(
				bridgeCompleteJourneyAttemptTimeoutMilliseconds,
				Math.max(0, performance.now() - attemptStartedAt),
			),
			failureReason: error instanceof Error ? failureReason : 'unknown_failure',
			phaseCompletionElapsedMilliseconds: completedPhases,
		});
	} finally {
		await page?.close().catch((): void => undefined);
	}
}

async function awaitCompleteJourneyStep<TValue>(props: {
	readonly label: string;
	readonly operation: Promise<TValue>;
	readonly ownerSignal: AbortSignal | undefined;
	readonly observeStep:
		| (<TResult>(name: string, promise: Promise<TResult>) => Promise<TResult>)
		| undefined;
	readonly pendingSteps: Set<string>;
	readonly signal: AbortSignal;
}): Promise<TValue> {
	props.pendingSteps.add(props.label);
	const observedOperation = props.observeStep?.(props.label, props.operation) ?? props.operation;
	const abortSignals = [props.signal, props.ownerSignal].filter(
		(signal): signal is AbortSignal => signal !== undefined,
	);
	const abortOperations = abortSignals.map((signal) => {
		let removeAbortListener = (): void => {};
		const promise = new Promise<never>((_resolve, reject): void => {
			const rejectOnAbort = (): void =>
				reject(signal.reason ?? new Error(`Complete journey step aborted: ${props.label}`));
			if (signal.aborted) rejectOnAbort();
			else {
				signal.addEventListener('abort', rejectOnAbort, { once: true });
				removeAbortListener = (): void => signal.removeEventListener('abort', rejectOnAbort);
			}
		});
		return { promise, removeAbortListener };
	});
	try {
		return await Promise.race([
			observedOperation,
			...abortOperations.map(({ promise }) => promise),
		]);
	} finally {
		for (const { removeAbortListener } of abortOperations) removeAbortListener();
		props.pendingSteps.delete(props.label);
	}
}

export function bridgeCompleteJourneyFailedAttempt(props: {
	readonly attemptId: string;
	readonly durationMilliseconds: number;
	readonly failureReason: string;
	readonly phaseCompletionElapsedMilliseconds: BridgeCompleteJourneyPhaseCompletions;
}): BridgeCompleteJourneyAttempt {
	return {
		attemptId: props.attemptId,
		durationMilliseconds: props.durationMilliseconds,
		failureReason: props.failureReason,
		outcome: 'failed',
		phaseCompletionElapsedMilliseconds: props.phaseCompletionElapsedMilliseconds,
	};
}

async function collectSuccessfulJourney(props: {
	readonly journey: BridgeCompleteJourney;
	readonly markCompletedPhases: (phases: BridgeCompleteJourneyPhaseCompletions) => void;
	readonly markFailureReason: (reason: string) => void;
	readonly markTimingStarted: (startedAt: number) => void;
	readonly page: Page;
}): Promise<BridgeCompleteJourneyPhaseCompletions> {
	switch (props.journey) {
		case 'firstFile': {
			props.markFailureReason('first_file_failed');
			let startedAt = performance.now();
			const sample = await collectWorktreeStartupTimingSample(
				props.page,
				(timingStartedAt): void => {
					startedAt = timingStartedAt;
					props.markTimingStarted(timingStartedAt);
				},
			);
			props.markCompletedPhases(phaseCompletionsForFirstFile(sample));
			const commitPaint = await waitForFileUsablePaint(props.page, startedAt);
			const completedPhases = phaseCompletionsForFirstFile(sample, commitPaint);
			props.markCompletedPhases(completedPhases);
			await waitForBridgeCompleteJourneyTelemetryWitnesses({
				activationSequence: null,
				page: props.page,
				viewer: 'file',
			});
			return completedPhases;
		}
		case 'firstReview': {
			props.markFailureReason('first_review_failed');
			let startedAt = performance.now();
			const sample = await collectReviewStartupTimingSample(props.page, (timingStartedAt): void => {
				startedAt = timingStartedAt;
				props.markTimingStarted(timingStartedAt);
			});
			props.markCompletedPhases(phaseCompletionsForFirstReview(sample));
			const commitPaint = await waitForReviewUsablePaint(props.page, startedAt);
			const completedPhases = phaseCompletionsForFirstReview(sample, commitPaint);
			props.markCompletedPhases(completedPhases);
			await waitForBridgeCompleteJourneyTelemetryWitnesses({
				activationSequence: null,
				page: props.page,
				viewer: 'review',
			});
			return completedPhases;
		}
		case 'fileToReview':
			await collectWorktreeStartupTimingSample(props.page);
			return await collectReviewSwitchPhaseCompletions({
				markCompletedPhases: props.markCompletedPhases,
				markFailureReason: props.markFailureReason,
				markTimingStarted: props.markTimingStarted,
				page: props.page,
			});
		case 'reviewToFile':
			await collectReviewStartupTimingSample(props.page);
			return await collectFileSwitchPhaseCompletions({
				markCompletedPhases: props.markCompletedPhases,
				markFailureReason: props.markFailureReason,
				markTimingStarted: props.markTimingStarted,
				page: props.page,
			});
	}
}

function phaseCompletionsForFirstFile(
	sample: WorktreeStartupTimingSample,
	commitPaintMilliseconds?: number,
): BridgeCompleteJourneyPhaseCompletions {
	const pageApplication = sample.pageApplicationMilliseconds;
	const handshakeWorker = Math.max(pageApplication, sample.handshakeWorkerMilliseconds);
	const sourceMetadata = Math.max(
		handshakeWorker,
		sample.sourceAcceptedMilliseconds,
		sample.metadataMilliseconds,
	);
	const selectionContent = Math.max(
		sourceMetadata,
		sample.selectedPathMilliseconds,
		sample.contentRequestStartedMilliseconds,
		sample.contentResponseStartedMilliseconds,
		sample.contentReadyMilliseconds,
	);
	return {
		...(commitPaintMilliseconds === undefined
			? {}
			: {
					commitPaint: Math.max(
						selectionContent,
						sample.firstVisibleContentWindowMilliseconds,
						commitPaintMilliseconds,
					),
				}),
		handshakeWorker,
		pageApplication,
		selectionContent,
		sourceMetadata,
	};
}

function phaseCompletionsForFirstReview(
	sample: ReviewStartupTimingSample,
	commitPaintMilliseconds?: number,
): BridgeCompleteJourneyPhaseCompletions {
	const pageApplication = sample.pageApplicationMilliseconds;
	const handshakeWorker = Math.max(pageApplication, sample.handshakeWorkerMilliseconds);
	const sourceMetadata = Math.max(handshakeWorker, sample.metadataMilliseconds);
	const selectionContent = Math.max(sourceMetadata, sample.selectedContentReadyMilliseconds);
	return {
		...(commitPaintMilliseconds === undefined
			? {}
			: { commitPaint: Math.max(selectionContent, commitPaintMilliseconds) }),
		handshakeWorker,
		pageApplication,
		selectionContent,
		sourceMetadata,
	};
}

async function collectReviewSwitchPhaseCompletions(props: {
	readonly markCompletedPhases: (phases: BridgeCompleteJourneyPhaseCompletions) => void;
	readonly markFailureReason: (reason: string) => void;
	readonly markTimingStarted: (startedAt: number) => void;
	readonly page: Page;
}): Promise<BridgeCompleteJourneyPhaseCompletions> {
	const minimumExclusiveActivationSequence = await maximumBridgeCompleteJourneyActivationSequence(
		props.page,
	);
	const startedAt = performance.now();
	props.markTimingStarted(startedAt);
	props.markFailureReason('review_source_metadata_failed');
	await props.page
		.locator(
			'[data-testid="bridge-viewer-mode-host-file"][data-bridge-viewer-mode-active="true"] [data-testid="bridge-viewer-context-review"]',
		)
		.click();
	await props.page.waitForFunction(reviewMetadataIsCurrentAndActive, undefined, {
		timeout: bridgeCompleteJourneyAttemptTimeoutMilliseconds,
	});
	const sourceMetadata = elapsedSince(startedAt);
	props.markCompletedPhases({ handshakeWorker: 0, pageApplication: 0, sourceMetadata });
	props.markFailureReason('review_selection_content_failed');
	await props.page.waitForFunction(reviewSelectedContentIsReadyAndActive, undefined, {
		timeout: bridgeCompleteJourneyAttemptTimeoutMilliseconds,
	});
	const selectionContent = elapsedSince(startedAt);
	props.markCompletedPhases({ selectionContent });
	props.markFailureReason('review_usable_paint_failed');
	const commitPaint = await waitForReviewUsablePaint(props.page, startedAt);
	props.markCompletedPhases({ commitPaint });
	const activationSequence = await waitForBridgeCompleteJourneyActivationSequence({
		minimumExclusive: minimumExclusiveActivationSequence,
		page: props.page,
		viewer: 'review',
	});
	await waitForBridgeCompleteJourneyTelemetryWitnesses({
		activationSequence,
		page: props.page,
		viewer: 'review',
	});
	return {
		commitPaint,
		handshakeWorker: 0,
		pageApplication: 0,
		selectionContent,
		sourceMetadata,
	};
}

async function collectFileSwitchPhaseCompletions(props: {
	readonly markCompletedPhases: (phases: BridgeCompleteJourneyPhaseCompletions) => void;
	readonly markFailureReason: (reason: string) => void;
	readonly markTimingStarted: (startedAt: number) => void;
	readonly page: Page;
}): Promise<BridgeCompleteJourneyPhaseCompletions> {
	const minimumExclusiveActivationSequence = await maximumBridgeCompleteJourneyActivationSequence(
		props.page,
	);
	const startedAt = performance.now();
	props.markTimingStarted(startedAt);
	props.markFailureReason('file_source_metadata_failed');
	await props.page
		.locator(
			'[data-testid="bridge-viewer-mode-host-review"][data-bridge-viewer-mode-active="true"] [data-testid="bridge-viewer-context-file"]',
		)
		.click();
	await props.page.waitForFunction(fileMetadataIsCurrentAndActive, undefined, {
		timeout: bridgeCompleteJourneyAttemptTimeoutMilliseconds,
	});
	const sourceMetadata = elapsedSince(startedAt);
	props.markCompletedPhases({ handshakeWorker: 0, pageApplication: 0, sourceMetadata });
	props.markFailureReason('file_selection_content_failed');
	await props.page.waitForFunction(fileSelectedContentIsReadyAndActive, undefined, {
		timeout: bridgeCompleteJourneyAttemptTimeoutMilliseconds,
	});
	const selectionContent = elapsedSince(startedAt);
	props.markCompletedPhases({ selectionContent });
	props.markFailureReason('file_usable_paint_failed');
	const commitPaint = await waitForFileUsablePaint(props.page, startedAt);
	props.markCompletedPhases({ commitPaint });
	const activationSequence = await waitForBridgeCompleteJourneyActivationSequence({
		minimumExclusive: minimumExclusiveActivationSequence,
		page: props.page,
		viewer: 'file',
	});
	await waitForBridgeCompleteJourneyTelemetryWitnesses({
		activationSequence,
		page: props.page,
		viewer: 'file',
	});
	return {
		commitPaint,
		handshakeWorker: 0,
		pageApplication: 0,
		selectionContent,
		sourceMetadata,
	};
}

async function waitForReviewUsablePaint(page: Page, startedAt: number): Promise<number> {
	await page.waitForFunction(reviewSelectedContentIsReadyAndActive, undefined, {
		timeout: bridgeCompleteJourneyAttemptTimeoutMilliseconds,
	});
	await waitForTwoAnimationFrames(page);
	if (!(await page.evaluate(reviewUsablePaintIsVisible))) {
		throw new Error('review_usable_paint_missing');
	}
	return elapsedSince(startedAt);
}

async function waitForFileUsablePaint(page: Page, startedAt: number): Promise<number> {
	await page.waitForFunction(fileSelectedContentIsReadyAndActive, undefined, {
		timeout: bridgeCompleteJourneyAttemptTimeoutMilliseconds,
	});
	await waitForTwoAnimationFrames(page);
	if (!(await page.evaluate(fileUsablePaintIsVisible))) {
		throw new Error('file_usable_paint_missing');
	}
	return elapsedSince(startedAt);
}

async function waitForTwoAnimationFrames(page: Page): Promise<void> {
	await page.evaluate(
		(): Promise<void> =>
			new Promise((resolve): void => {
				requestAnimationFrame((): void => {
					requestAnimationFrame((): void => resolve());
				});
			}),
	);
}

function reviewMetadataIsCurrentAndActive(): boolean {
	const host = document.querySelector('[data-testid="bridge-viewer-mode-host-review"]');
	const shell = document.querySelector('[data-testid="review-viewer-shell"]');
	return (
		host instanceof HTMLElement &&
		host.getAttribute('data-bridge-viewer-mode-active') === 'true' &&
		!host.inert &&
		Number(shell?.getAttribute('data-review-metadata-item-count') ?? '0') > 0
	);
}

function reviewSelectedContentIsReadyAndActive(): boolean {
	const host = document.querySelector('[data-testid="bridge-viewer-mode-host-review"]');
	const shell = document.querySelector('[data-testid="review-viewer-shell"]');
	return (
		host instanceof HTMLElement &&
		host.getAttribute('data-bridge-viewer-mode-active') === 'true' &&
		!host.inert &&
		Number(shell?.getAttribute('data-review-metadata-item-count') ?? '0') > 0 &&
		shell?.getAttribute('data-selected-content-state') === 'ready'
	);
}

function fileMetadataIsCurrentAndActive(): boolean {
	const host = document.querySelector('[data-testid="bridge-viewer-mode-host-file"]');
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	return (
		host instanceof HTMLElement &&
		host.getAttribute('data-bridge-viewer-mode-active') === 'true' &&
		!host.inert &&
		shell?.getAttribute('data-file-display-status') === 'ready'
	);
}

function fileSelectedContentIsReadyAndActive(): boolean {
	const host = document.querySelector('[data-testid="bridge-viewer-mode-host-file"]');
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
	return (
		host instanceof HTMLElement &&
		host.getAttribute('data-bridge-viewer-mode-active') === 'true' &&
		!host.inert &&
		shell?.getAttribute('data-file-display-status') === 'ready' &&
		canvas?.getAttribute('data-worktree-open-file-state') === 'ready' &&
		(canvas?.getAttribute('data-worktree-open-file-path')?.length ?? 0) > 0
	);
}

function elapsedSince(startedAt: number): number {
	return Math.max(0, performance.now() - startedAt);
}

const bridgeCompleteJourneys = [
	'firstFile',
	'firstReview',
	'fileToReview',
	'reviewToFile',
] as const satisfies readonly BridgeCompleteJourney[];

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import type { Page, Request, Route } from 'playwright';

import { bridgeProductContentRequestSchema } from '../../src/core/comm-worker/bridge-product-content-contracts.js';
import { bridgeProductControlRequestSchema } from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import { waitForAnnotationMainProjectionReceipt } from './bridge-viewer-vite-annotation-main-projection-observation.ts';
import {
	runAnnotationSaveJourney,
	type AnnotationSaveJourneyObservations,
	type AnnotationSaveJourneyPostSaveResult,
	waitForCommittedAnnotationCommand,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import { waitForCommittedAnnotationOutcome } from './bridge-viewer-vite-annotation-wire-response-observation.ts';
import {
	observeChurnEvidence,
	type ChurnEvidence,
	type ChurnEvidenceObserver,
} from './bridge-viewer-vite-copy-file-churn-evidence.ts';
import {
	holdAnnotationProjectionAcrossFileRefresh,
	type AnnotationProjectionRetirementEvidence,
} from './bridge-viewer-vite-copy-file-churn-projection-retirement.ts';
import type {
	BridgeViewerOwnedViteProductServer,
	BridgeViewerViteProductFixtureOracle,
} from './bridge-viewer-vite-product-fixture.ts';

const churnFileCount = 12;
const churnTimeoutMilliseconds = 30_000;

interface ChurnBurst {
	readonly expectedReadiness: {
		readonly lineCount: number;
		readonly path: string;
		readonly sha256: string;
	};
	readonly settled: Promise<void>;
	readonly writesCommitted: Promise<void>;
}

export interface CopyFileChurnReproductionObservations {
	readonly annotationJourney: AnnotationSaveJourneyObservations;
	readonly completedBurstCount: number;
	readonly editedProjectionRetirement: AnnotationProjectionRetirementEvidence | null;
	readonly initialProjectionRetirement: AnnotationProjectionRetirementEvidence | null;
	readonly evidence: ChurnEvidence;
}

export async function runCopyFileChurnReproduction(props: {
	readonly testSignal: AbortSignal;
	readonly retireEditedProjectionDuringRefresh?: boolean;
	readonly retireEditedBeforeFileRefresh?: boolean;
	readonly retireInitialDraftProjectionDuringRefresh?: boolean;
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly server: BridgeViewerOwnedViteProductServer;
}): Promise<CopyFileChurnReproductionObservations> {
	const selectedPath = join(props.oracle.worktreeRoot, props.oracle.largeFilePath);
	const auxiliaryPaths = props.oracle.changedPaths
		.filter((path): boolean => path !== props.oracle.largeFilePath)
		.slice(0, churnFileCount);
	if (auxiliaryPaths.length !== churnFileCount) {
		throw new Error(`Copy churn requires ${churnFileCount} auxiliary fixture files.`);
	}
	const selectedOriginalBody = await readFile(selectedPath, 'utf8');
	const auxiliaryOriginalBodies = new Map(
		await Promise.all(
			auxiliaryPaths.map(
				async (path): Promise<readonly [string, string]> => [
					path,
					await readFile(join(props.oracle.worktreeRoot, path), 'utf8'),
				],
			),
		),
	);
	let completedBurstCount = 0;
	let editedProjectionRetirement: AnnotationProjectionRetirementEvidence | null = null;
	let initialProjectionRetirement: AnnotationProjectionRetirementEvidence | null = null;
	const initialRetirementRef: {
		current: Awaited<ReturnType<typeof holdAnnotationProjectionAcrossFileRefresh>> | null;
	} = { current: null };
	const evidenceObserverRef: { current: ChurnEvidenceObserver | null } = { current: null };
	const ongoingCopyBurstRef: { current: ChurnBurst | null } = { current: null };

	try {
		const annotationJourney = await runAnnotationSaveJourney({
			testSignal: props.testSignal,
			afterInitialDraftProjection: async (): Promise<void> => {
				if (initialRetirementRef.current === null) return;
				await initialRetirementRef.current.waitForRetirement();
				initialProjectionRetirement = initialRetirementRef.current.evidence();
				await initialRetirementRef.current.stop();
				initialRetirementRef.current = null;
			},
			afterProjectedSave: async ({
				page,
				savedBody,
			}): Promise<AnnotationSaveJourneyPostSaveResult> => {
				const retirement =
					props.retireEditedProjectionDuringRefresh === true
						? await holdAnnotationProjectionAcrossFileRefresh({
								ordering: {
									kind:
										props.retireEditedBeforeFileRefresh === true
											? 'edited-save-before-file-refresh'
											: 'edited-save',
								},
								expectedFileSha256: createHash('sha256')
									.update(selectedBodyForBurst(selectedOriginalBody, 2))
									.digest('hex'),
								page,
								testSignal: props.testSignal,
							})
						: null;
				try {
					await startChurnBurst({
						auxiliaryOriginalBodies,
						burstOrdinal: 1,
						oracle: props.oracle,
						page,
						selectedOriginalBody,
					}).settled;
					completedBurstCount += 1;

					const releaseEditWrites = deferred<void>();
					if (props.retireEditedBeforeFileRefresh !== true) releaseEditWrites.resolve();
					const editBurst = startChurnBurst({
						beforeWrites: releaseEditWrites.promise,
						auxiliaryOriginalBodies,
						burstOrdinal: 2,
						oracle: props.oracle,
						page,
						selectedOriginalBody,
					});
					if (props.retireEditedBeforeFileRefresh !== true) await editBurst.writesCommitted;
					const editedBody = `${savedBody} Edited while File refresh is pending.`;
					const [editResult, burstResult] = await Promise.allSettled([
						editAndSaveCurrentAnnotation({
							editedBody,
							page,
							savedBody,
							beforeSave:
								props.retireEditedBeforeFileRefresh === true
									? retirement?.waitForHeldProjection
									: undefined,
							afterCommittedSave: retirement?.releaseProjection,
							afterSave: (): void => releaseEditWrites.resolve(),
						}).finally((): void => releaseEditWrites.resolve()),
						editBurst.settled,
					]);
					if (editResult.status === 'rejected') throw editResult.reason;
					if (burstResult.status === 'rejected') throw burstResult.reason;
					completedBurstCount += 1;
					return {
						savedBody: editedBody,
						selectedFileReadiness: editBurst.expectedReadiness,
					};
				} finally {
					if (retirement !== null) {
						editedProjectionRetirement = retirement.evidence();
						await retirement.stop();
					}
				}
			},
			captureOutput: async ({ captureDefaultOutput, page }) => {
				const releaseFileContent = deferred<void>();
				const exactFileContentIntercepted = deferred<unknown>();
				const heldRouteCompletions = new Set<Promise<void>>();
				const contentRoutePattern = '**/__bridge-product/content**';
				const contentRouteHandler = async (route: Route): Promise<void> => {
					const body: unknown = route.request().postDataJSON();
					const expectedSha256 = ongoingCopyBurstRef.current?.expectedReadiness.sha256;
					if (!isExactFileContentRequest(body, expectedSha256)) {
						await route.continue();
						return;
					}
					exactFileContentIntercepted.resolve(body);
					const heldRouteCompletion = releaseFileContent.promise.then(async (): Promise<void> => {
						await route.continue();
					});
					heldRouteCompletions.add(heldRouteCompletion);
					try {
						await heldRouteCompletion;
					} finally {
						heldRouteCompletions.delete(heldRouteCompletion);
					}
				};
				const releaseOnCopyRequest = (request: Request): void => {
					if (!isOutputScopeCommitRequest(request)) return;
					const overlap = evidenceObserverRef.current?.evidence.copyRefreshOverlap;
					if (overlap !== null && overlap !== undefined && overlap.releasedBy === null) {
						overlap.releasedBy = 'output.scope.commit';
					}
					releaseFileContent.resolve();
				};
				await page.route(contentRoutePattern, contentRouteHandler);
				page.on('request', releaseOnCopyRequest);
				let captureResult:
					| PromiseSettledResult<AnnotationSaveJourneyObservations['outputIdentity']>
					| undefined;
				try {
					[captureResult] = await Promise.allSettled([
						captureDefaultOutput({
							beforeCopy: async (): Promise<void> => {
								const ongoingCopyBurst = startChurnBurst({
									auxiliaryOriginalBodies,
									burstOrdinal: 3,
									oracle: props.oracle,
									page,
									selectedOriginalBody,
								});
								ongoingCopyBurstRef.current = ongoingCopyBurst;
								const interceptedRequest = page.waitForRequest(
									(request): boolean => {
										const body: unknown = request.postDataJSON();
										return isExactFileContentRequest(
											body,
											ongoingCopyBurst.expectedReadiness.sha256,
										);
									},
									{ timeout: churnTimeoutMilliseconds },
								);
								await ongoingCopyBurst.writesCommitted;
								await interceptedRequest;
								const body = await exactFileContentIntercepted.promise;
								if (evidenceObserverRef.current !== null) {
									evidenceObserverRef.current.evidence.copyRefreshOverlap = {
										expectedSha256: ongoingCopyBurst.expectedReadiness.sha256,
										interceptedBeforeCopy: true,
										paintedBeforeCopy: await isPaintedFileHash(
											page,
											ongoingCopyBurst.expectedReadiness.sha256,
										),
										releasedBy: null,
										workerDerivationEpoch: fileContentWorkerDerivationEpoch(body),
									};
								}
							},
						}),
					]);
				} finally {
					page.off('request', releaseOnCopyRequest);
					const overlap = evidenceObserverRef.current?.evidence.copyRefreshOverlap;
					if (overlap !== null && overlap !== undefined && overlap.releasedBy === null) {
						overlap.releasedBy = 'cleanup';
					}
					releaseFileContent.resolve();
					await Promise.allSettled(heldRouteCompletions);
					await page.unroute(contentRoutePattern, contentRouteHandler);
				}
				const [burstResult] = await Promise.allSettled(
					ongoingCopyBurstRef.current === null ? [] : [ongoingCopyBurstRef.current.settled],
				);
				if (burstResult?.status === 'fulfilled') completedBurstCount += 1;
				if (captureResult === undefined) throw new Error('Missing Copy capture result.');
				if (captureResult.status === 'rejected') throw captureResult.reason;
				if (burstResult?.status === 'rejected') throw burstResult.reason;
				return captureResult.value;
			},
			oracle: props.oracle,
			server: props.server,
			setupPage: async (page): Promise<void> => {
				evidenceObserverRef.current = observeChurnEvidence(page);
				if (props.retireInitialDraftProjectionDuringRefresh === true) {
					const refreshedBody = selectedOriginalBody;
					initialRetirementRef.current = await holdAnnotationProjectionAcrossFileRefresh({
						ordering: {
							kind: 'initial-draft',
							writeFileRefresh: async (): Promise<void> => {
								await writeFile(selectedPath, refreshedBody);
							},
						},
						expectedFileSha256: createHash('sha256').update(refreshedBody).digest('hex'),
						page,
						testSignal: props.testSignal,
					});
				}
			},
			surface: 'file',
		});
		await evidenceObserverRef.current?.drain();
		return {
			annotationJourney,
			completedBurstCount,
			editedProjectionRetirement,
			initialProjectionRetirement,
			evidence: evidenceObserverRef.current?.evidence ?? {
				annotationOutcomes: [],
				copyRefreshOverlap: null,
				fileAnnotationOpens: [],
				subscriptionRetirements: [],
				fileScopeUpdateCount: 0,
				transportRequests: [],
			},
		};
	} catch (error: unknown) {
		if (ongoingCopyBurstRef.current !== null) {
			await Promise.allSettled([ongoingCopyBurstRef.current.settled]);
		}
		await evidenceObserverRef.current?.drain();
		throw new Error(
			`Copy-under-file-churn reproduction failed after ${completedBurstCount} settled bursts: evidence=${JSON.stringify(evidenceObserverRef.current?.evidence)} server=${props.server.diagnostics()}`,
			{ cause: error },
		);
	} finally {
		await initialRetirementRef.current?.stop();
	}
}

function startChurnBurst(props: {
	readonly beforeWrites?: Promise<void>;
	readonly auxiliaryOriginalBodies: ReadonlyMap<string, string>;
	readonly burstOrdinal: number;
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly page: Page;
	readonly selectedOriginalBody: string;
}): ChurnBurst {
	const writes = deferred<void>();
	void writes.promise.catch((): void => {});
	const selectedBody = selectedBodyForBurst(props.selectedOriginalBody, props.burstOrdinal);
	const selectedSha256 = createHash('sha256').update(selectedBody).digest('hex');
	const expectedReadiness = {
		lineCount: selectedFileLineCount(selectedBody),
		path: props.oracle.largeFilePath,
		sha256: selectedSha256,
	};
	const settled = (props.beforeWrites ?? Promise.resolve())
		.then(() =>
			Promise.all([
				writeFile(join(props.oracle.worktreeRoot, props.oracle.largeFilePath), selectedBody),
				...Array.from(props.auxiliaryOriginalBodies, ([path, originalBody]) =>
					writeFile(
						join(props.oracle.worktreeRoot, path),
						`${originalBody}\n// annotation-copy-churn-${props.burstOrdinal}-${path.length}\n`,
					),
				),
			]),
		)
		.then((): void => writes.resolve())
		.then(async (): Promise<void> => {
			await waitForPaintedFileHash(props.page, selectedSha256);
		})
		.catch((error: unknown): never => {
			writes.reject(error);
			throw error;
		});
	return { expectedReadiness, settled, writesCommitted: writes.promise };
}

function selectedBodyForBurst(originalBody: string, burstOrdinal: number): string {
	const lines = originalBody.endsWith('\n')
		? originalBody.slice(0, -1).split('\n')
		: originalBody.split('\n');
	return `${lines
		.map((line, index): string => {
			if (index < 8) return line;
			return `${line}-churn-${burstOrdinal}-${'x'.repeat((index + burstOrdinal) % 17)}`;
		})
		.concat(
			`selected-file-surrounding-size-change-${burstOrdinal}-${'y'.repeat(burstOrdinal * 31)}`,
		)
		.join('\n')}\n`;
}

function selectedFileLineCount(body: string): number {
	return body.endsWith('\n') ? body.slice(0, -1).split('\n').length : body.split('\n').length;
}

async function editAndSaveCurrentAnnotation(props: {
	readonly beforeSave?: (() => Promise<void>) | undefined;
	readonly afterSave?: () => void;
	readonly afterCommittedSave?: (() => void) | undefined;
	readonly editedBody: string;
	readonly page: Page;
	readonly savedBody: string;
}): Promise<void> {
	const message = props.page
		.locator('[data-annotation-message-id]')
		.filter({ hasText: props.savedBody })
		.first();
	await message.getByRole('button', { name: 'Edit annotation', exact: true }).click();
	const editor = message.getByRole('textbox', { name: 'Annotation Markdown', exact: true });
	await editor.waitFor({ state: 'visible', timeout: churnTimeoutMilliseconds });
	const flush = waitForCommittedAnnotationOutcome(props.page, 'draft.flush', 'file');
	await editor.fill(props.editedBody);
	await flush;
	await props.beforeSave?.();
	const save = waitForCommittedAnnotationOutcome(props.page, 'draft.save', 'file');
	const committedSave = waitForCommittedAnnotationCommand(props.page, 'draft.save', 'file');
	await message.getByRole('button', { name: 'Save annotation', exact: true }).click();
	const [receipt] = await Promise.all([save, committedSave]);
	props.afterCommittedSave?.();
	// The File refresh can retire a successful query's descriptor before transfer.
	// Installation of this receipt in the owning Main store survives that retirement.
	await waitForAnnotationMainProjectionReceipt({
		page: props.page,
		receipt,
		messageState: 'saved',
	});
	props.afterSave?.();
	await message
		.getByText(props.editedBody, { exact: true })
		.waitFor({ state: 'visible', timeout: churnTimeoutMilliseconds });
}

function isExactFileContentRequest(body: unknown, expectedSha256: string | undefined): boolean {
	if (expectedSha256 === undefined) return false;
	const parsed = bridgeProductContentRequestSchema.safeParse(body);
	return (
		parsed.success &&
		parsed.data.contentKind === 'file.content' &&
		parsed.data.descriptor.expectedSha256 === expectedSha256
	);
}

function fileContentWorkerDerivationEpoch(body: unknown): number | null {
	const parsed = bridgeProductContentRequestSchema.safeParse(body);
	return parsed.success && parsed.data.contentKind === 'file.content'
		? parsed.data.workerDerivationEpoch
		: null;
}

function isOutputScopeCommitRequest(request: Request): boolean {
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	)
		return false;
	const parsed = bridgeProductControlRequestSchema.safeParse(request.postDataJSON());
	if (!parsed.success || parsed.data.kind !== 'product.call') return false;
	const callRequest: unknown = parsed.data.call.request;
	return (
		parsed.data.call.method === 'file.annotations.command' &&
		isRecord(callRequest) &&
		isRecord(callRequest['operation']) &&
		callRequest['operation']['kind'] === 'output.scope.commit' &&
		callRequest['operation']['outputKind'] === 'clipboardMarkdown'
	);
}

async function waitForPaintedFileHash(page: Page, expectedSha256: string): Promise<void> {
	await page.waitForFunction(
		(expected: string): boolean => {
			const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
			const painted = canvas?.querySelector(
				'diffs-container[data-bridge-painted-source-correlations]',
			);
			const correlations: unknown = JSON.parse(
				painted?.getAttribute('data-bridge-painted-source-correlations') ?? '[]',
			);
			return (
				canvas?.getAttribute('data-worktree-open-file-state') === 'ready' &&
				Array.isArray(correlations) &&
				correlations.some(
					(correlation: unknown): boolean =>
						typeof correlation === 'object' &&
						correlation !== null &&
						'observedSha256' in correlation &&
						correlation.observedSha256 === expected,
				)
			);
		},
		expectedSha256,
		{ timeout: churnTimeoutMilliseconds },
	);
}

async function isPaintedFileHash(page: Page, expectedSha256: string): Promise<boolean> {
	return await page.evaluate((expected: string): boolean => {
		const painted = document
			.querySelector('[data-testid="bridge-file-viewer-code-canvas"]')
			?.querySelector('diffs-container[data-bridge-painted-source-correlations]');
		const correlations: unknown = JSON.parse(
			painted?.getAttribute('data-bridge-painted-source-correlations') ?? '[]',
		);
		return (
			Array.isArray(correlations) &&
			correlations.some(
				(correlation: unknown): boolean =>
					typeof correlation === 'object' &&
					correlation !== null &&
					'observedSha256' in correlation &&
					correlation.observedSha256 === expected,
			)
		);
	}, expectedSha256);
}

function deferred<TResult>(): {
	readonly promise: Promise<TResult>;
	readonly reject: (reason: unknown) => void;
	readonly resolve: (value: TResult) => void;
} {
	let rejectPromise!: (reason: unknown) => void;
	let resolvePromise!: (value: TResult) => void;
	const promise = new Promise<TResult>((resolve, reject): void => {
		resolvePromise = resolve;
		rejectPromise = reject;
	});
	return { promise, reject: rejectPromise, resolve: resolvePromise };
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

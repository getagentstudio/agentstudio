import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import type { Page, Request, Response, Route } from 'playwright';

import { bridgeProductContentRequestSchema } from '../../src/core/comm-worker/bridge-product-content-contracts.js';
import {
	bridgeProductAdmissionResponseSchema,
	bridgeProductOperationResultResponseSchema,
} from '../../src/core/comm-worker/bridge-product-operation-wire-contracts.js';
import { bridgeProductControlRequestSchema } from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import { bridgeProductWorktreeAnnotationCommandOutcomeSchema } from '../../src/core/comm-worker/bridge-product-worktree-annotation-contracts.js';
import { waitForDemandedAnnotationProjectionContent } from './bridge-viewer-vite-annotation-projection-test-support.ts';
import {
	runAnnotationSaveJourney,
	type AnnotationSaveJourneyObservations,
	type AnnotationSaveJourneyPostSaveResult,
	waitForCommittedAnnotationCommand,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import { waitForCommittedAnnotationOutcome } from './bridge-viewer-vite-annotation-wire-response-observation.ts';
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

export interface ChurnEvidence {
	readonly annotationOutcomes: Array<{
		readonly operationKind: string;
		readonly status: string;
	}>;
	copyRefreshOverlap: {
		readonly expectedSha256: string;
		readonly interceptedBeforeCopy: boolean;
		readonly paintedBeforeCopy: boolean;
		releasedBy: 'cleanup' | 'output.scope.commit' | null;
		readonly workerDerivationEpoch: number | null;
	} | null;
	readonly fileAnnotationOpens: Array<{
		readonly workerDerivationEpoch: number;
		readonly workerInstanceId: string;
	}>;
	readonly subscriptionRetirements: Array<{
		readonly subscriptionId: string;
		readonly subscriptionKind: string;
		readonly workerDerivationEpoch: number;
	}>;
	fileScopeUpdateCount: number;
	readonly transportRequests: Array<{
		readonly kind: string;
		readonly method: string | null;
		readonly operationKind: string | null;
		readonly subscriptionId: string | null;
		readonly subscriptionKind: string | null;
		readonly workerDerivationEpoch: number | null;
	}>;
}

interface ChurnEvidenceObserver {
	readonly drain: () => Promise<void>;
	readonly evidence: ChurnEvidence;
}

export interface CopyFileChurnReproductionObservations {
	readonly annotationJourney: AnnotationSaveJourneyObservations;
	readonly completedBurstCount: number;
	readonly evidence: ChurnEvidence;
}

export async function runCopyFileChurnReproduction(props: {
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
	const evidenceObserverRef: { current: ChurnEvidenceObserver | null } = { current: null };
	const ongoingCopyBurstRef: { current: ChurnBurst | null } = { current: null };

	try {
		const annotationJourney = await runAnnotationSaveJourney({
			afterProjectedSave: async ({
				page,
				savedBody,
			}): Promise<AnnotationSaveJourneyPostSaveResult> => {
				await startChurnBurst({
					auxiliaryOriginalBodies,
					burstOrdinal: 1,
					oracle: props.oracle,
					page,
					selectedOriginalBody,
				}).settled;
				completedBurstCount += 1;

				const editBurst = startChurnBurst({
					auxiliaryOriginalBodies,
					burstOrdinal: 2,
					oracle: props.oracle,
					page,
					selectedOriginalBody,
				});
				await editBurst.writesCommitted;
				const editedBody = `${savedBody} Edited while File refresh is pending.`;
				const [editResult, burstResult] = await Promise.allSettled([
					editAndSaveCurrentAnnotation({ editedBody, page, savedBody }),
					editBurst.settled,
				]);
				if (editResult.status === 'rejected') throw editResult.reason;
				if (burstResult.status === 'rejected') throw burstResult.reason;
				completedBurstCount += 1;
				return {
					savedBody: editedBody,
					selectedFileReadiness: editBurst.expectedReadiness,
				};
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
			},
			surface: 'file',
		});
		await evidenceObserverRef.current?.drain();
		return {
			annotationJourney,
			completedBurstCount,
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
	}
}

function startChurnBurst(props: {
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
	const settled = Promise.all([
		writeFile(join(props.oracle.worktreeRoot, props.oracle.largeFilePath), selectedBody),
		...Array.from(props.auxiliaryOriginalBodies, ([path, originalBody]) =>
			writeFile(
				join(props.oracle.worktreeRoot, path),
				`${originalBody}\n// annotation-copy-churn-${props.burstOrdinal}-${path.length}\n`,
			),
		),
	])
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
	const save = waitForCommittedAnnotationOutcome(props.page, 'draft.save', 'file');
	const committedSave = waitForCommittedAnnotationCommand(props.page, 'draft.save', 'file');
	const projectedSave = waitForDemandedAnnotationProjectionContent({
		afterRequestSequence: committedSave.then(({ requestSequence }) => requestSequence),
		page: props.page,
		sessionId: committedSave.then(({ sessionId }) => {
			if (sessionId === null)
				throw new Error('Edited annotation save omitted its session identity.');
			return sessionId;
		}),
	});
	await message.getByRole('button', { name: 'Save annotation', exact: true }).click();
	await Promise.all([save, committedSave, projectedSave]);
	await message
		.getByText(props.editedBody, { exact: true })
		.waitFor({ state: 'visible', timeout: churnTimeoutMilliseconds });
}

function observeChurnEvidence(page: Page): ChurnEvidenceObserver {
	const evidence: ChurnEvidence = {
		annotationOutcomes: [],
		copyRefreshOverlap: null,
		fileAnnotationOpens: [],
		subscriptionRetirements: [],
		fileScopeUpdateCount: 0,
		transportRequests: [],
	};
	const pendingOutcomeReads = new Set<Promise<void>>();
	const operationKindById = new Map<string, string>();
	const resultByOperationId = new Map<string, unknown>();
	const recordedOperationIds = new Set<string>();
	page.on('request', (request): void => recordTransportRequest(evidence, request));
	page.on('response', (response): void => {
		const read = recordAnnotationOutcome({
			evidence,
			operationKindById,
			recordedOperationIds,
			response,
			resultByOperationId,
		}).finally((): void => {
			pendingOutcomeReads.delete(read);
		});
		pendingOutcomeReads.add(read);
	});
	return {
		drain: async (): Promise<void> => {
			await Promise.allSettled(pendingOutcomeReads);
		},
		evidence,
	};
}

function recordTransportRequest(evidence: ChurnEvidence, request: Request): void {
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	)
		return;
	const parsed = bridgeProductControlRequestSchema.safeParse(request.postDataJSON());
	if (!parsed.success) return;
	const control = parsed.data;
	const call = control.kind === 'product.call' ? control.call : null;
	const callRequest: unknown = call?.request;
	const operation = isRecord(callRequest) ? callRequest['operation'] : null;
	if (
		control.kind === 'subscription.open' &&
		control.subscription.subscriptionKind === 'file.annotations'
	) {
		evidence.fileAnnotationOpens.push({
			workerDerivationEpoch: control.workerDerivationEpoch,
			workerInstanceId: control.workerInstanceId,
		});
	}
	if (control.kind === 'subscription.setScope' && control.subscriptionKind === 'file.metadata') {
		evidence.fileScopeUpdateCount += 1;
	}
	if (control.kind === 'subscription.cancel') {
		evidence.subscriptionRetirements.push({
			subscriptionId: control.subscriptionId,
			subscriptionKind: control.subscriptionKind,
			workerDerivationEpoch: control.workerDerivationEpoch,
		});
	}
	evidence.transportRequests.push({
		kind: control.kind,
		method: call?.method ?? null,
		operationKind:
			isRecord(operation) && typeof operation['kind'] === 'string' ? operation['kind'] : null,
		subscriptionId:
			'subscriptionId' in control && typeof control.subscriptionId === 'string'
				? control.subscriptionId
				: null,
		subscriptionKind:
			'subscriptionKind' in control && typeof control.subscriptionKind === 'string'
				? control.subscriptionKind
				: control.kind === 'subscription.open'
					? control.subscription.subscriptionKind
					: null,
		workerDerivationEpoch:
			'workerDerivationEpoch' in control && typeof control.workerDerivationEpoch === 'number'
				? control.workerDerivationEpoch
				: null,
	});
	if (evidence.transportRequests.length > 128) evidence.transportRequests.shift();
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

async function recordAnnotationOutcome(props: {
	readonly evidence: ChurnEvidence;
	readonly operationKindById: Map<string, string>;
	readonly recordedOperationIds: Set<string>;
	readonly response: Response;
	readonly resultByOperationId: Map<string, unknown>;
}): Promise<void> {
	const { evidence, operationKindById, recordedOperationIds, response, resultByOperationId } =
		props;
	const request = response.request();
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	)
		return;
	const requestBody: unknown = request.postDataJSON();
	if (!isRecord(requestBody)) return;
	if (requestBody['kind'] === 'product.call') {
		const admission = bridgeProductAdmissionResponseSchema.safeParse(
			await response.json().catch((): null => null),
		);
		if (!admission.success || admission.data.kind !== 'operation.admitted') return;
		const call = requestBody['call'];
		if (
			!isRecord(call) ||
			(call['method'] !== 'file.annotations.command' &&
				call['method'] !== 'review.annotations.command') ||
			!isRecord(call['request'])
		)
			return;
		const operation = call['request']['operation'];
		if (!isRecord(operation) || typeof operation['kind'] !== 'string') return;
		operationKindById.set(admission.data.operationId, operation['kind']);
		const priorResult = resultByOperationId.get(admission.data.operationId);
		if (priorResult !== undefined) {
			recordSettledAnnotationOutcome(
				evidence,
				operation['kind'],
				priorResult,
				admission.data.operationId,
				recordedOperationIds,
			);
		}
		return;
	}
	if (requestBody['kind'] !== 'operation.result') return;
	const settlement = bridgeProductOperationResultResponseSchema.safeParse(
		await response.json().catch((): null => null),
	);
	if (
		!settlement.success ||
		settlement.data.outcome !== 'succeeded' ||
		settlement.data.operationId !== requestBody['operationId']
	)
		return;
	resultByOperationId.set(settlement.data.operationId, settlement.data.result);
	const operationKind = operationKindById.get(settlement.data.operationId);
	if (operationKind !== undefined) {
		recordSettledAnnotationOutcome(
			evidence,
			operationKind,
			settlement.data.result,
			settlement.data.operationId,
			recordedOperationIds,
		);
	}
}

function recordSettledAnnotationOutcome(
	evidence: ChurnEvidence,
	operationKind: string,
	responseBody: unknown,
	operationId: string,
	recordedOperationIds: Set<string>,
): void {
	if (recordedOperationIds.has(operationId)) return;
	if (!isRecord(responseBody) || !isRecord(responseBody['call'])) return;
	const result = responseBody['call']['result'];
	if (!isRecord(result) || !isRecord(result['outcome'])) return;
	const outcome = bridgeProductWorktreeAnnotationCommandOutcomeSchema.safeParse(result['outcome']);
	if (!outcome.success) return;
	recordedOperationIds.add(operationId);
	evidence.annotationOutcomes.push({
		operationKind,
		status:
			outcome.data.status.kind === 'failed'
				? `failed:${outcome.data.status.code}`
				: outcome.data.status.kind,
	});
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

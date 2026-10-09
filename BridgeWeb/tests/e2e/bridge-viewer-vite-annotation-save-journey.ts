import type { Page, Request, Response, Route } from 'playwright';
import { expect, test } from 'vitest';

import { selectReviewTreeFilePath } from '../../scripts/verify-bridge-viewer-worktree-dev-server/review-tree-click.ts';
import {
	drainAnnotationLifecycleTelemetry,
	requiredAnnotationLifecycleStageCount,
	waitForCompleteAnnotationLifecycleTelemetry,
} from './bridge-viewer-vite-annotation-lifecycle-telemetry.ts';
import {
	observeAnnotationMainProjection,
	readAnnotationMainProjectionObservation,
} from './bridge-viewer-vite-annotation-main-projection-observation.ts';
import {
	type AnnotationOutputIdentityCapture,
	type AnnotationOutputCopyHooks,
	verifyAnnotationOutputCaptures,
} from './bridge-viewer-vite-annotation-output-capture.ts';
import {
	annotationProjectionContentRequestDiagnostic,
	annotationProjectionQueryResultDiagnostic,
	annotationProjectionUiDiagnostic,
	waitForDemandedAnnotationProjectionContent,
} from './bridge-viewer-vite-annotation-projection-test-support.ts';
import {
	reviewAdditionRangeBounds,
	reviewRangeSelectionDiagnostic,
	type AnnotationRangeBounds,
} from './bridge-viewer-vite-annotation-selection-diagnostic.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { observeInteractionProfileFailures } from './bridge-viewer-vite-interaction-profile-diagnostics.ts';
import type {
	BridgeViewerOwnedViteProductServer,
	BridgeViewerViteProductFixtureOracle,
} from './bridge-viewer-vite-product-fixture.ts';
import { waitForProductCallSettlement } from './bridge-viewer-vite-product-operation-response.ts';
import {
	bridgeViewerViteProductFileUrl,
	bridgeViewerViteProductReviewUrl,
	requireBridgeViewerVitePrimaryReviewPath,
} from './bridge-viewer-vite-product-url.ts';
import {
	installReviewRenderObservation,
	readReviewRenderObservation,
} from './bridge-viewer-vite-review-render-observation.ts';
import { observeSelectedItemApplies } from './bridge-viewer-vite-selected-item-apply-observation.ts';

const annotationProjectionResponseTimeoutMilliseconds = 30_000;
export interface AnnotationSaveJourneyObservations {
	readonly correlatedLifecycleStageCount: number;
	readonly gatedProjectionRequestCount: number;
	readonly projectedSavedMessageCount: number;
	readonly reloadedSavedMessageCount: number;
	readonly savingControlCountAfterCommit: number;
	readonly committedBodyCountWhileProjectionGated: number;
	readonly outputIdentity: AnnotationOutputIdentityCapture;
}

export interface AnnotationSaveJourneyHookContext {
	readonly page: Page;
	readonly savedBody: string;
}

export interface AnnotationSaveJourneyPostSaveResult {
	readonly savedBody?: string;
	readonly selectedFileReadiness?: {
		readonly lineCount: number;
		readonly path: string;
		readonly sha256: string;
	};
}

export interface AnnotationSaveJourneyOutputContext extends AnnotationSaveJourneyHookContext {
	readonly captureDefaultOutput: (
		hooks?: AnnotationOutputCopyHooks,
	) => Promise<AnnotationOutputIdentityCapture>;
}

interface ReleasedDraftReloadJourneyObservations {
	readonly reloadedCollapsedDraftCount: number;
	readonly reloadedDraftLabelCount: number;
	readonly removedDraftCount: number;
}

export function registerBridgeViewerViteAnnotationSaveJourneyTests(props: {
	readonly oracle: () => BridgeViewerViteProductFixtureOracle;
	readonly server: () => BridgeViewerOwnedViteProductServer;
}): void {
	test.each(['file', 'review'] as const)(
		'keeps an exact committed annotation visible while the %s projection is gated',
		async (surface) => {
			const observations = await runAnnotationSaveJourney({
				oracle: props.oracle(),
				server: props.server(),
				surface,
			});

			expect(observations.gatedProjectionRequestCount).toBeGreaterThan(0);
			expect(observations.savingControlCountAfterCommit).toBe(0);
			expect(observations.committedBodyCountWhileProjectionGated).toBe(1);
			expect(observations.correlatedLifecycleStageCount).toBe(
				requiredAnnotationLifecycleStageCount,
			);
			expect(observations.projectedSavedMessageCount).toBe(1);
			expect(observations.reloadedSavedMessageCount).toBe(1);
		},
	);

	test('restores a released Review root draft after a full document reload', async () => {
		const observations = await runReleasedDraftReloadJourney({
			oracle: props.oracle(),
			server: props.server(),
		});

		expect(observations.reloadedCollapsedDraftCount).toBe(1);
		expect(observations.reloadedDraftLabelCount).toBeGreaterThan(0);
		expect(observations.removedDraftCount).toBe(0);
	});
}

async function runReleasedDraftReloadJourney(props: {
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly server: BridgeViewerOwnedViteProductServer;
}): Promise<ReleasedDraftReloadJourneyObservations> {
	const browser = await launchBridgeViewerE2EChromium();
	let page: Page | null = null;
	try {
		page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
		// The vitest hang bound is the only clock this journey is allowed.
		page.setDefaultTimeout(0);
		page.setDefaultNavigationTimeout(0);
		const reviewFile = props.oracle.reviewFiles[0];
		if (reviewFile === undefined) {
			throw new Error('Review released-draft journey requires a changed review file.');
		}
		await page.goto(
			bridgeViewerViteProductReviewUrl(
				props.server.origin,
				requireBridgeViewerVitePrimaryReviewPath(props.oracle),
			),
			{
				waitUntil: 'domcontentloaded',
			},
		);
		await selectReviewFile({ page, path: reviewFile.path });
		await waitForSelectedReviewReady({ itemId: reviewFile.itemId, page });
		await selectRangeForAnnotation({ endLine: 5, page, startLine: 2, surface: 'review' });

		const rootCreateCommitted = waitForCommittedAnnotationCommand(page, 'root.create', 'review');
		const draftBody = 'Released Review draft survives document reload.';
		const composer = page.getByRole('textbox', { name: 'Write an annotation in Markdown' });
		await composer.fill(draftBody);
		await rootCreateCommitted;
		await page
			.locator('[data-testid="worktree-annotation-message"][data-annotation-draft="present"]')
			.waitFor({ state: 'visible' });

		const releaseCommitted = waitForCommittedAnnotationCommand(
			page,
			'draft.edit.release',
			'review',
		);
		await composer.press('Escape');
		await releaseCommitted;

		await page.reload({
			waitUntil: 'domcontentloaded',
		});
		await waitForSelectedReviewReady({ itemId: reviewFile.itemId, page });
		const reloadedDraft = page.getByText(draftBody, { exact: true });
		await reloadedDraft.waitFor({
			state: 'visible',
		});
		const reloadedCollapsedDraftCount = await reloadedDraft.count();
		const reloadedDraftLabelCount = await page.getByText('Draft', { exact: true }).count();

		await reloadedDraft.click();
		await page.getByRole('button', { name: 'Revert draft' }).click();
		await reloadedDraft.waitFor({
			state: 'hidden',
		});

		return {
			reloadedCollapsedDraftCount,
			reloadedDraftLabelCount,
			removedDraftCount: await reloadedDraft.count(),
		};
	} finally {
		await page?.close();
		await browser.close();
	}
}

export async function runAnnotationSaveJourney(props: {
	readonly afterProjectedSave?: (
		context: AnnotationSaveJourneyHookContext,
	) => Promise<AnnotationSaveJourneyPostSaveResult | undefined>;
	readonly captureOutput?: (
		context: AnnotationSaveJourneyOutputContext,
	) => Promise<AnnotationOutputIdentityCapture>;
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly server: BridgeViewerOwnedViteProductServer;
	readonly setupPage?: (page: Page) => Promise<void>;
	readonly surface: 'file' | 'review';
}): Promise<AnnotationSaveJourneyObservations> {
	const browser = await launchBridgeViewerE2EChromium();
	const diagnostics: string[] = [];
	let page: Page | null = null;
	let expectedSavedBody: string | null = null;
	let selectedFileReadiness: AnnotationSaveJourneyPostSaveResult['selectedFileReadiness'];
	let transportFailures: Awaited<ReturnType<typeof observeInteractionProfileFailures>> | null =
		null;
	try {
		page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
		// The vitest hang bound is the only clock this journey is allowed.
		page.setDefaultTimeout(0);
		page.setDefaultNavigationTimeout(0);
		transportFailures = await observeInteractionProfileFailures(page);
		observeAnnotationJourneyDiagnostics(page, diagnostics);
		await props.setupPage?.(page);
		const reviewFile = props.oracle.reviewFiles[0];
		if (props.surface === 'review' && reviewFile === undefined) {
			throw new Error('Review annotation Save journey requires a changed review file.');
		}
		if (props.surface === 'review' && reviewFile !== undefined) {
			await installReviewRenderObservation({ itemId: reviewFile.itemId, page });
		}
		const initialReviewProjectionReceived =
			props.surface === 'review' ? waitForAnnotationProjectionContentResponse(page) : null;
		await page.goto(
			props.surface === 'file'
				? bridgeViewerViteProductFileUrl(props.server.origin, props.oracle.largeFilePath)
				: bridgeViewerViteProductReviewUrl(
						props.server.origin,
						requireBridgeViewerVitePrimaryReviewPath(props.oracle),
					),
			{
				waitUntil: 'domcontentloaded',
			},
		);
		if (props.surface === 'file') {
			await waitForSelectedFileReady({ oracle: props.oracle, page });
		} else {
			await selectReviewFile({ page, path: reviewFile?.path ?? '' });
			await waitForSelectedReviewReady({ itemId: reviewFile?.itemId ?? '', page });
			await initialReviewProjectionReceived;
		}
		await selectRangeForAnnotation({ endLine: 5, page, startLine: 2, surface: props.surface });

		const rootCreateCommitted = waitForCommittedAnnotationCommand(
			page,
			'root.create',
			props.surface,
		);
		const sourceRefreshCommitted =
			props.surface === 'file'
				? waitForCommittedAnnotationCommand(page, 'source.refresh', 'file')
				: null;
		// Request sequence numbers are a total order, not a causal one. `source.refresh` and the
		// demanded projection query are issued concurrently by one `acquireSession`, so anchor the
		// gate to `root.create`, which the session genuinely cannot exist before.
		const demandedDraftProjectionCommitted =
			sourceRefreshCommitted === null
				? null
				: waitForDemandedAnnotationProjectionContent({
						afterRequestSequence: rootCreateCommitted.then((receipt) => receipt.requestSequence),
						page,
						sessionId: rootCreateCommitted.then((receipt) => {
							if (receipt.sessionId === null) {
								throw new Error('Committed root annotation did not identify its session.');
							}
							return receipt.sessionId;
						}),
					});
		const savedBody = `${props.surface === 'file' ? 'File' : 'Review'} Save must settle from its exact command receipt.`;
		expectedSavedBody = savedBody;
		await page.getByRole('textbox', { name: 'Write an annotation in Markdown' }).fill(savedBody);
		await rootCreateCommitted;
		if (sourceRefreshCommitted !== null) await sourceRefreshCommitted;
		if (demandedDraftProjectionCommitted !== null) await demandedDraftProjectionCommitted;
		await page
			.locator('[data-testid="worktree-annotation-message"][data-annotation-draft="present"]')
			.waitFor({ state: 'visible' });
		await page.waitForFunction((): boolean => {
			const saveButton = document.querySelector<HTMLButtonElement>(
				'[aria-label="Save annotation"]',
			);
			return saveButton !== null && !saveButton.disabled;
		}, undefined);

		const projectionGate = createDeferred<void>();
		let gatedProjectionRequestCount = 0;
		let savingControlCountAfterCommit = 0;
		let committedBodyCountWhileProjectionGated = 0;
		let projectionOperationCorrelationId: string | null = null;
		const projectionOperationCorrelationIds: string[] = [];
		const observeProjectionRequest = (request: Request): void => {
			if (new URL(request.url()).pathname !== '/__bridge-product/content') return;
			const body: unknown = request.postDataJSON();
			if (!isUnknownRecord(body) || body['contentKind'] !== 'annotation.projection') return;
			const correlationId = body['operationCorrelationId'];
			if (
				typeof correlationId === 'string' &&
				projectionOperationCorrelationIds.at(-1) !== correlationId
			) {
				projectionOperationCorrelationIds.push(correlationId);
			}
		};
		page.on('request', observeProjectionRequest);
		const projectionRoutePattern = '**/__bridge-product/content**';
		const projectionRouteHandler = async (route: Route): Promise<void> => {
			const body: unknown = route.request().postDataJSON();
			if (isUnknownRecord(body) && body['contentKind'] === 'annotation.projection') {
				gatedProjectionRequestCount += 1;
				await projectionGate.promise;
			}
			await route.continue();
		};
		await page.route(projectionRoutePattern, projectionRouteHandler);
		try {
			const gatedProjectionRequest = page.waitForRequest((request): boolean => {
				if (
					request.method() !== 'POST' ||
					new URL(request.url()).pathname !== '/__bridge-product/content'
				) {
					return false;
				}
				const body: unknown = request.postDataJSON();
				return isUnknownRecord(body) && body['contentKind'] === 'annotation.projection';
			});
			const draftSaveCommitted = waitForCommittedAnnotationCommand(
				page,
				'draft.save',
				props.surface,
			);
			await page.getByRole('button', { name: 'Save annotation' }).click();
			await draftSaveCommitted;
			const projectionRequest = await gatedProjectionRequest;
			const projectionRequestBody: unknown = projectionRequest.postDataJSON();
			projectionOperationCorrelationId =
				isUnknownRecord(projectionRequestBody) &&
				typeof projectionRequestBody['operationCorrelationId'] === 'string'
					? projectionRequestBody['operationCorrelationId']
					: null;
			if (projectionOperationCorrelationId === null) {
				throw new Error(
					`Saved annotation projection request did not carry lifecycle correlation: ${JSON.stringify(
						annotationProjectionContentRequestDiagnostic(projectionRequestBody),
					)}.`,
				);
			}
			// The projection is still gated here, so the committed overlay and the cleared Saving control
			// ARE the claim. Wait for those two owner-published states instead of guessing two frames;
			// the counts below then assert the part a barrier cannot give us — that there is exactly one
			// committed body and no second Saving control.
			await page.getByText(savedBody, { exact: true }).first().waitFor({ state: 'visible' });
			await page.getByRole('button', { name: 'Saving annotation' }).waitFor({ state: 'detached' });
			savingControlCountAfterCommit = await page
				.getByRole('button', { name: 'Saving annotation' })
				.count();
			committedBodyCountWhileProjectionGated = await page
				.getByText(savedBody, { exact: true })
				.count();
		} finally {
			projectionGate.resolve();
			await page.unrouteAll({ behavior: 'wait' });
		}
		const savedThreadBody = page
			.getByTestId('worktree-annotation-thread')
			.getByText(savedBody, { exact: true });
		await savedThreadBody.waitFor({
			state: 'visible',
		});
		const projectedSavedMessageCount = await savedThreadBody.count();
		if (projectionOperationCorrelationId === null) {
			throw new Error('Saved annotation projection lifecycle correlation was not retained.');
		}
		// The committed overlay can be visible before authoritative projection finishes.
		// Draining seals producers, so first await this operation's exact terminal stages.
		const correlatedLifecycleStageCount = await waitForCompleteAnnotationLifecycleTelemetry({
			operationCorrelationIds: () => projectionOperationCorrelationIds,
			page,
		});
		page.off('request', observeProjectionRequest);
		const telemetryDrain = await drainAnnotationLifecycleTelemetry(page);
		const telemetrySidecar = isUnknownRecord(telemetryDrain) ? telemetryDrain['sidecar'] : null;
		if (!isUnknownRecord(telemetrySidecar)) {
			throw new Error('Annotation lifecycle telemetry drain had no sidecar loss summary.');
		}
		expect(telemetrySidecar['requiredLossCount']).toBe(0);
		const postSaveResult = await props.afterProjectedSave?.({
			page,
			savedBody,
		});
		if (postSaveResult?.savedBody !== undefined) expectedSavedBody = postSaveResult.savedBody;
		selectedFileReadiness = postSaveResult?.selectedFileReadiness;

		const reloadedItemApplies =
			props.surface === 'review' ? observeSelectedItemApplies(page) : null;
		const reloadedMainProjection =
			props.surface === 'review' ? observeAnnotationMainProjection(page) : null;
		await page.reload({
			waitUntil: 'domcontentloaded',
		});
		if (props.surface === 'file') {
			await waitForSelectedFileReady({
				...(selectedFileReadiness === undefined ? {} : { expected: selectedFileReadiness }),
				oracle: props.oracle,
				page,
			});
		} else {
			await waitForSelectedReviewReady({ itemId: reviewFile?.itemId ?? '', page });
			await reloadedItemApplies?.install(reviewFile?.itemId ?? '');
			await reloadedMainProjection?.install();
		}
		const currentSavedBody = expectedSavedBody ?? savedBody;
		const reloadedSavedThreadBody = page
			.getByTestId('worktree-annotation-thread')
			.getByText(currentSavedBody, { exact: true });
		await reloadedSavedThreadBody.waitFor({
			state: 'visible',
		});
		const reloadedSavedMessageCount = await reloadedSavedThreadBody.count();
		const outputPage = page;
		const captureDefaultOutput = async (
			hooks: AnnotationOutputCopyHooks = {},
		): Promise<AnnotationOutputIdentityCapture> =>
			await verifyAnnotationOutputCaptures({
				...hooks,
				dataRootPath: props.oracle.dataRootPath,
				page: outputPage,
				savedBody: currentSavedBody,
				timeoutMilliseconds: annotationProjectionResponseTimeoutMilliseconds,
				worktreeRoot: props.oracle.worktreeRoot,
			});
		const outputIdentity =
			props.captureOutput === undefined
				? await captureDefaultOutput()
				: await props.captureOutput({
						captureDefaultOutput,
						page,
						savedBody: currentSavedBody,
					});

		return {
			committedBodyCountWhileProjectionGated,
			correlatedLifecycleStageCount,
			gatedProjectionRequestCount,
			outputIdentity,
			projectedSavedMessageCount,
			reloadedSavedMessageCount,
			savingControlCountAfterCommit,
		};
	} catch (error: unknown) {
		if (page !== null) {
			recordAnnotationDiagnostic(
				diagnostics,
				`transport-failures:${JSON.stringify(await transportFailures?.read())}`,
			);
			if (props.surface === 'review') {
				recordAnnotationDiagnostic(
					diagnostics,
					`review-render:${JSON.stringify(await readReviewRenderObservation(page))}`,
				);
				recordAnnotationDiagnostic(
					diagnostics,
					`review-main-projection:${JSON.stringify(await readAnnotationMainProjectionObservation(page))}`,
				);
				recordAnnotationDiagnostic(
					diagnostics,
					`review-item-applies:${JSON.stringify(await page.evaluate((): unknown => Reflect.get(globalThis, '__bridgeSelectedItemApplies')))}`,
				);
			}
			recordAnnotationDiagnostic(
				diagnostics,
				`projection-ui:${JSON.stringify(
					await annotationProjectionUiDiagnostic(page, expectedSavedBody),
				)}`,
			);
			if (props.surface === 'file') {
				recordAnnotationDiagnostic(
					diagnostics,
					`file-readiness:${JSON.stringify(
						await selectedFileReadinessDiagnostic({ oracle: props.oracle, page }),
					)}`,
				);
				recordAnnotationDiagnostic(
					diagnostics,
					`file-render-telemetry:${JSON.stringify(
						await selectedFileRenderTelemetryDiagnostic(page),
					)}`,
				);
			}
		}
		throw new Error(
			`Annotation Save journey failed: cause=${JSON.stringify(annotationSaveJourneyCause(error))} browser=${JSON.stringify(diagnostics)} server=${props.server.diagnostics()}`,
			{ cause: error },
		);
	} finally {
		await page?.close();
		await browser.close();
	}
}

function annotationSaveJourneyCause(error: unknown): Readonly<Record<string, string>> {
	return error instanceof Error
		? { kind: error.name, message: error.message }
		: { kind: typeof error, message: String(error) };
}

function observeAnnotationJourneyDiagnostics(page: Page, diagnostics: string[]): void {
	page.on('console', (message): void => {
		if (message.type() === 'error' || message.type() === 'warning') {
			recordAnnotationDiagnostic(diagnostics, `console:${message.type()}:${message.text()}`);
		}
	});
	page.on('pageerror', (error): void => {
		recordAnnotationDiagnostic(diagnostics, `pageerror:${error.message}`);
	});
	page.on('requestfailed', (request): void => {
		const path = new URL(request.url()).pathname;
		const errorText = request.failure()?.errorText ?? 'unknown';
		if (path === '/__bridge-product/command' && errorText === 'net::ERR_ABORTED') return;
		const body: unknown = request.postDataJSON();
		recordAnnotationDiagnostic(
			diagnostics,
			`requestfailed:${path}:${errorText}:${JSON.stringify(annotationProjectionContentRequestDiagnostic(body))}`,
		);
	});
	page.on('response', (response): void => {
		const request = response.request();
		const path = new URL(request.url()).pathname;
		if (!path.startsWith('/__bridge-product/')) return;
		const body: unknown = request.postDataJSON();
		const kind = isUnknownRecord(body) && typeof body['kind'] === 'string' ? body['kind'] : null;
		const contentKind =
			isUnknownRecord(body) && typeof body['contentKind'] === 'string' ? body['contentKind'] : null;
		const call = isUnknownRecord(body) && isUnknownRecord(body['call']) ? body['call'] : null;
		const requestSequence =
			isUnknownRecord(body) && typeof body['requestSequence'] === 'number'
				? body['requestSequence']
				: null;
		const method = call !== null && typeof call['method'] === 'string' ? call['method'] : null;
		const callRequest = call !== null && isUnknownRecord(call['request']) ? call['request'] : null;
		const operation =
			callRequest !== null && isUnknownRecord(callRequest['operation'])
				? callRequest['operation']
				: null;
		const operationKind =
			operation !== null && typeof operation['kind'] === 'string' ? operation['kind'] : null;
		if (method === 'file.activeViewerMode.update' && call !== null) {
			const activeViewerRequest = call['request'];
			const activeSource = isUnknownRecord(activeViewerRequest)
				? activeViewerRequest['activeSource']
				: null;
			recordAnnotationDiagnostic(
				diagnostics,
				`file-active-source:${JSON.stringify(
					isUnknownRecord(activeSource)
						? {
								generation: activeSource['generation'],
								streamIdPresent:
									typeof activeSource['streamId'] === 'string' &&
									activeSource['streamId'].length > 0,
							}
						: null,
				)}`,
			);
		}
		if (
			method === 'file.annotations.projection.query' ||
			method === 'review.annotations.projection.query'
		) {
			void response
				.json()
				.then((responseBody: unknown): void => {
					recordAnnotationDiagnostic(
						diagnostics,
						`projection-query-result:${JSON.stringify(
							annotationProjectionQueryResultDiagnostic(responseBody, callRequest),
						)}`,
					);
				})
				.catch((): void => {
					recordAnnotationDiagnostic(diagnostics, 'projection-query-result:unreadable');
				});
		}
		if (contentKind === 'annotation.projection') {
			recordAnnotationDiagnostic(
				diagnostics,
				`projection-content:${JSON.stringify(annotationProjectionContentRequestDiagnostic(body))}`,
			);
		}
		if (operationKind === 'output.history') {
			void response
				.json()
				.then((responseBody: unknown): void => {
					recordAnnotationDiagnostic(
						diagnostics,
						`history-result:${JSON.stringify(annotationHistoryResultDiagnostic(responseBody))}`,
					);
				})
				.catch((): void => {
					recordAnnotationDiagnostic(diagnostics, 'history-result:unreadable');
				});
		}
		recordAnnotationDiagnostic(
			diagnostics,
			`response:${path}:${response.status()}:${kind ?? '-'}:${method ?? contentKind ?? '-'}:${operationKind ?? '-'}:${requestSequence ?? '-'}`,
		);
	});
}

function annotationHistoryResultDiagnostic(value: unknown): unknown {
	if (!isUnknownRecord(value) || !isUnknownRecord(value['call'])) return { call: 'missing' };
	const call = value['call'];
	if (!isUnknownRecord(call['result'])) return { result: 'missing' };
	const result = call['result'];
	if (!isUnknownRecord(result['outcome']) || !isUnknownRecord(result['outcome']['status'])) {
		return { outcome: 'missing' };
	}
	const status = result['outcome']['status'];
	const summaries = Array.isArray(status['summaries']) ? status['summaries'] : [];
	const firstSummary = summaries[0];
	return {
		firstKeys: isUnknownRecord(firstSummary) ? Object.keys(firstSummary).toSorted() : [],
		kind: status['kind'],
		firstSessionId: isUnknownRecord(firstSummary) ? firstSummary['sessionId'] : null,
		outcomeSessionId: result['outcome']['sessionId'],
		summaryCount: summaries.length,
	};
}

function recordAnnotationDiagnostic(diagnostics: string[], value: string): void {
	const maximumDiagnosticCount = 128;
	if (diagnostics.length >= maximumDiagnosticCount) diagnostics.shift();
	diagnostics.push(value);
}

function createDeferred<TValue>(): {
	readonly promise: Promise<TValue>;
	readonly resolve: (value: TValue) => void;
} {
	let resolvePromise: ((value: TValue) => void) | null = null;
	const promise = new Promise<TValue>((resolve): void => {
		resolvePromise = resolve;
	});
	return {
		promise,
		resolve: (value): void => {
			if (resolvePromise === null) throw new Error('Deferred resolver is unavailable.');
			resolvePromise(value);
		},
	};
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Review readiness is the Review owner's own published state, not geometry: the code-view panel names
 * the selected item (`data-selected-item-id`, bridge-code-view-panel-frame.tsx) and reports that
 * item's content materialized (`data-selected-content-state`, selectedContentStateForPanel), and the
 * render fulfillment coordinator stamps `data-bridge-painted-source-correlations` on the container it
 * actually painted. Both waits carry no timeout argument, so the caller's page default — the test's
 * hang bound — is the only clock.
 */
export async function waitForSelectedReviewReady(props: {
	readonly itemId: string;
	readonly page: Page;
}): Promise<void> {
	const selectedPanel = props.page.locator(
		`[data-testid="bridge-code-view-panel"][data-selected-item-id=${cssAttributeValue(props.itemId)}][data-selected-content-state="ready"]`,
	);
	await selectedPanel.waitFor({ state: 'attached' });
	await selectedPanel
		.locator('diffs-container[data-bridge-painted-source-correlations]')
		.first()
		.waitFor({ state: 'attached' });
}

function cssAttributeValue(value: string): string {
	return JSON.stringify(value);
}

export async function selectReviewFile(props: {
	readonly page: Page;
	readonly path: string;
}): Promise<void> {
	await props.page.locator('[data-testid="review-viewer-shell"]').waitFor({ state: 'attached' });
	await selectReviewTreeFilePath({ page: props.page, path: props.path });
}

export async function selectRangeForAnnotation(props: {
	readonly endLine: number;
	readonly page: Page;
	readonly startLine: number;
	readonly surface: 'file' | 'review';
}): Promise<void> {
	let startBounds: AnnotationRangeBounds | null;
	let endBounds: AnnotationRangeBounds | null;
	if (props.surface === 'file') {
		const startRow = props.page.locator(`[data-column-number="${props.startLine}"]`).first();
		const endRow = props.page.locator(`[data-column-number="${props.endLine}"]`).first();
		await startRow.waitFor({ state: 'visible' });
		await endRow.waitFor({ state: 'visible' });
		startBounds = await startRow.boundingBox();
		endBounds = await endRow.boundingBox();
	} else {
		const interactionState = await props.page.evaluate(
			(): {
				readonly inert: boolean;
				readonly pointerEvents: string | null;
			} => {
				const canvas = document.querySelector('[data-testid="bridge-review-canvas"]');
				return {
					inert: canvas instanceof HTMLElement && canvas.inert,
					pointerEvents: canvas instanceof Element ? getComputedStyle(canvas).pointerEvents : null,
				};
			},
		);
		if (interactionState.inert || interactionState.pointerEvents === 'none') {
			throw new Error(
				`Review annotation canvas is not interactive: ${JSON.stringify(interactionState)}`,
			);
		}
		const additionRows = props.page
			.locator('[data-testid="bridge-code-view-panel"]')
			.locator('[data-additions] [data-column-number]');
		await additionRows.nth(0).waitFor({ state: 'visible' });
		await additionRows.nth(2).waitFor({ state: 'visible' });
		[startBounds, endBounds] = await reviewAdditionRangeBounds({
			endLine: props.endLine,
			page: props.page,
			startLine: props.startLine,
		});
	}
	if (startBounds === null || endBounds === null) {
		throw new Error('File annotation range rows must have visible pointer geometry.');
	}
	await props.page.mouse.move(startBounds.x + 4, startBounds.y + startBounds.height / 2);
	await props.page.mouse.down();
	await props.page.mouse.move(endBounds.x + 4, endBounds.y + endBounds.height / 2, { steps: 4 });
	await props.page.mouse.up();
	if (props.surface === 'review') {
		const selectionDiagnostic = await reviewRangeSelectionDiagnostic({
			endBounds,
			page: props.page,
			startBounds,
		});
		if (selectionDiagnostic.selectedLineCount === 0) {
			throw new Error(
				`Review annotation drag did not establish Pierre selection: ${JSON.stringify(selectionDiagnostic)}`,
			);
		}
	}
	// No deadlines here: every wait defers to the caller's page default, so a caller that disables it
	// is bounded only by its own hang bound.
	const endpointUtility = props.page.locator('[data-utility-button]').first();
	await endpointUtility.waitFor({ state: 'visible' });
	await endpointUtility.click();
	await props.page
		.getByRole('textbox', { name: 'Write an annotation in Markdown' })
		.waitFor({ state: 'visible' });
}

export async function waitForCommittedAnnotationCommand(
	page: Page,
	operationKind: 'draft.edit.release' | 'draft.save' | 'root.create' | 'source.refresh',
	surface: 'file' | 'review',
): Promise<{ readonly requestSequence: number; readonly sessionId: string | null }> {
	const settled = await waitForProductCallSettlement(page, (candidate): boolean =>
		isAnnotationCommandResponse(candidate, operationKind, surface),
	);
	const body: unknown = settled.result;
	if (
		!isUnknownRecord(body) ||
		body['kind'] !== 'call.completed' ||
		!isUnknownRecord(body['call']) ||
		body['call']['method'] !== `${surface}.annotations.command` ||
		!isUnknownRecord(body['call']['result']) ||
		body['call']['result']['kind'] !== 'completed' ||
		!isUnknownRecord(body['call']['result']['outcome']) ||
		!isUnknownRecord(body['call']['result']['outcome']['status']) ||
		body['call']['result']['outcome']['status']['kind'] !== 'committed'
	) {
		throw new Error(
			`Expected committed ${operationKind} response, received ${JSON.stringify(body)}.`,
		);
	}
	const outcome = body['call']['result']['outcome'];
	return {
		requestSequence: settled.requestSequence,
		sessionId: typeof outcome['sessionId'] === 'string' ? outcome['sessionId'] : null,
	};
}

async function waitForAnnotationProjectionContentResponse(page: Page): Promise<void> {
	const response = await page.waitForResponse((candidate): boolean => {
		const request = candidate.request();
		if (
			request.method() !== 'POST' ||
			new URL(request.url()).pathname !== '/__bridge-product/content'
		) {
			return false;
		}
		const body: unknown = request.postDataJSON();
		return isUnknownRecord(body) && body['contentKind'] === 'annotation.projection';
	});
	if (!response.ok()) {
		throw new Error(`Annotation projection content failed with HTTP ${response.status()}.`);
	}
}

function isAnnotationCommandResponse(
	response: Response,
	operationKind: 'draft.edit.release' | 'draft.save' | 'root.create' | 'source.refresh',
	surface: 'file' | 'review',
): boolean {
	const request = response.request();
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	) {
		return false;
	}
	const body: unknown = request.postDataJSON();
	return (
		isUnknownRecord(body) &&
		body['kind'] === 'product.call' &&
		isUnknownRecord(body['call']) &&
		body['call']['method'] === `${surface}.annotations.command` &&
		isUnknownRecord(body['call']['request']) &&
		isUnknownRecord(body['call']['request']['operation']) &&
		body['call']['request']['operation']['kind'] === operationKind
	);
}

export async function waitForSelectedFileReady(props: {
	readonly expected?: {
		readonly lineCount: number;
		readonly path: string;
		readonly sha256: string;
	};
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly page: Page;
}): Promise<void> {
	const expected = props.expected ?? {
		lineCount: props.oracle.fileContent.lineCount,
		path: props.oracle.largeFilePath,
		sha256: props.oracle.fileContent.sha256,
	};
	await props.page.waitForFunction(
		({ expectedLineCount, expectedSha256, path }): boolean => {
			const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
			const painted = canvas?.querySelector(
				'diffs-container[data-bridge-painted-source-correlations]',
			);
			const correlations: unknown = JSON.parse(
				painted?.getAttribute('data-bridge-painted-source-correlations') ?? '[]',
			);
			return (
				canvas?.getAttribute('data-worktree-open-file-state') === 'ready' &&
				canvas.getAttribute('data-worktree-open-file-path') === path &&
				canvas.getAttribute('data-worktree-rendered-file-path') === path &&
				Number(canvas.getAttribute('data-worktree-rendered-line-count')) === expectedLineCount &&
				Array.isArray(correlations) &&
				correlations.some(
					(correlation): boolean =>
						typeof correlation === 'object' &&
						correlation !== null &&
						'observedSha256' in correlation &&
						correlation.observedSha256 === expectedSha256,
				)
			);
		},
		{
			expectedLineCount: expected.lineCount,
			expectedSha256: expected.sha256,
			path: expected.path,
		},
	);
}

async function selectedFileReadinessDiagnostic(props: {
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly page: Page;
}): Promise<Readonly<Record<string, unknown>>> {
	return await props.page.evaluate(
		({ expectedLineCount, expectedSha256, path }): Readonly<Record<string, unknown>> => {
			const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
			const painted = canvas?.querySelector(
				'diffs-container[data-bridge-painted-source-correlations]',
			);
			const encodedCorrelations =
				painted?.getAttribute('data-bridge-painted-source-correlations') ?? '[]';
			let correlations: unknown = null;
			try {
				correlations = JSON.parse(encodedCorrelations);
			} catch {
				correlations = { invalidJSON: encodedCorrelations.slice(0, 1_000) };
			}
			return {
				canvasPresent: canvas !== null,
				expectedLineCount,
				expectedPath: path,
				expectedSha256,
				observedCorrelations: correlations,
				observedLineCount: canvas?.getAttribute('data-worktree-rendered-line-count') ?? null,
				observedOpenPath: canvas?.getAttribute('data-worktree-open-file-path') ?? null,
				observedOpenState: canvas?.getAttribute('data-worktree-open-file-state') ?? null,
				observedRenderedPath: canvas?.getAttribute('data-worktree-rendered-file-path') ?? null,
			};
		},
		{
			expectedLineCount: props.oracle.fileContent.lineCount,
			expectedSha256: props.oracle.fileContent.sha256,
			path: props.oracle.largeFilePath,
		},
	);
}

async function selectedFileRenderTelemetryDiagnostic(
	page: Page,
): Promise<readonly Readonly<Record<string, unknown>>[]> {
	return await page.evaluate(async (): Promise<readonly Readonly<Record<string, unknown>>[]> => {
		const response = await fetch('/__bridge-dev-telemetry/status');
		if (!response.ok) return [{ status: response.status }];
		const body: unknown = await response.json();
		if (typeof body !== 'object' || body === null) return [{ status: 'invalid-body' }];
		const recentSamples = Reflect.get(body, 'recentSamples');
		if (!Array.isArray(recentSamples)) return [{ status: 'missing-samples' }];
		return recentSamples
			.filter((sample): boolean => {
				if (typeof sample !== 'object' || sample === null) return false;
				const stringAttributes = Reflect.get(sample, 'stringAttributes');
				if (typeof stringAttributes !== 'object' || stringAttributes === null) return false;
				return (
					Reflect.get(stringAttributes, 'agentstudio.bridge.viewer') === 'file' &&
					(Reflect.get(sample, 'name') === 'performance.bridge.web.render_disposition_admission' ||
						Reflect.get(sample, 'name') ===
							'performance.bridge.worker.render_publication_outstanding')
				);
			})
			.slice(-16)
			.map((sample): Readonly<Record<string, unknown>> => {
				const numericAttributes = Reflect.get(sample, 'numericAttributes');
				const stringAttributes = Reflect.get(sample, 'stringAttributes');
				return {
					current:
						typeof numericAttributes === 'object' && numericAttributes !== null
							? Reflect.get(
									numericAttributes,
									'agentstudio.bridge.render_publication.current_count',
								)
							: null,
					event: Reflect.get(sample, 'name'),
					outcome:
						typeof stringAttributes === 'object' && stringAttributes !== null
							? (Reflect.get(stringAttributes, 'agentstudio.bridge.render_publication.outcome') ??
								Reflect.get(stringAttributes, 'agentstudio.bridge.render_disposition.outcome'))
							: null,
					pending:
						typeof numericAttributes === 'object' && numericAttributes !== null
							? Reflect.get(
									numericAttributes,
									'agentstudio.bridge.render_disposition.pending_count',
								)
							: null,
					phase:
						typeof stringAttributes === 'object' && stringAttributes !== null
							? Reflect.get(stringAttributes, 'agentstudio.bridge.phase')
							: null,
				};
			});
	});
}

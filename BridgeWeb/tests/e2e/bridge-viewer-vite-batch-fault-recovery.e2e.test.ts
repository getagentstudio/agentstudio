import type { Browser, Page, Request } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import type { BridgeProductMetadataFrame } from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import {
	selectReviewFile,
	selectRangeForAnnotation,
	waitForSelectedFileReady,
	waitForSelectedReviewReady,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import { waitForCommittedAnnotationOutcome } from './bridge-viewer-vite-annotation-wire-response-observation.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { observeSelectedFileRetention } from './bridge-viewer-vite-file-retention-probe.ts';
import { proveLostViewAcknowledgement } from './bridge-viewer-vite-lost-view-ack-proof.ts';
import {
	observeMetadataFrames,
	type MetadataFrameObservation,
} from './bridge-viewer-vite-metadata-frame-observation.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { bridgeViewerViteProductFileUrl } from './bridge-viewer-vite-product-url.ts';
import type { BridgeSemanticBatchKind } from './bridge-viewer-vite-semantic-batch-fault.ts';
import {
	startBridgeStreamFaultProxy,
	type BridgeStreamFaultProxy,
} from './bridge-viewer-vite-stream-fault-proxy.ts';

interface ReviewContentRequestObservation {
	readonly itemId: string | null;
	readonly responseStatus: number | null;
}

type BatchBegin = Extract<BridgeProductMetadataFrame, { readonly kind: 'subscription.batchBegin' }>;

test('File and Review semantic part faults recover on the live Vite and Swift stream', async () => {
	const fixture = await createBridgeViewerViteProductFixture();
	let server: BridgeViewerOwnedViteProductServer | null = null;
	let proxy: BridgeStreamFaultProxy | null = null;
	let browser: Browser | null = null;
	let page: Page | null = null;
	let retention: Awaited<ReturnType<typeof observeSelectedFileRetention>> | null = null;
	let primaryError: unknown;
	const metadataFrames = observeMetadataFrames();
	try {
		server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
		proxy = await startBridgeStreamFaultProxy(server.origin, {
			onMetadataFrame: metadataFrames.record,
			semanticBatchFaults: true,
		});
		browser = await launchBridgeViewerE2EChromium();
		page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
		const activePage = page;
		const reviewContentRequests = observeReviewContentRequests(page);
		page.setDefaultTimeout(0);
		page.setDefaultNavigationTimeout(0);
		await page.goto(bridgeViewerViteProductFileUrl(proxy.origin, fixture.oracle.largeFilePath), {
			waitUntil: 'domcontentloaded',
		});
		await waitForSelectedFileReady({ oracle: fixture.oracle, page });
		retention = await observeSelectedFileRetention(page, fixture.oracle.largeFilePath);
		const establishedStreamCount = proxy.snapshot().metadataRequestCount;
		expect(establishedStreamCount).toBe(1);
		expect(proxy.snapshot().semanticKindsByResponse).toEqual([
			expect.arrayContaining(['file.metadata']),
		]);

		const faultApplied = proxy.armSemanticBatchFault({
			mode: 'drop',
			subscriptionKind: 'file.metadata',
		});
		const updatedContent = await fixture.mutateLargeFile();
		const applied = await faultApplied;
		expect(applied).toMatchObject({
			mode: 'drop',
			subscriptionKind: 'file.metadata',
		});
		await waitForSelectedFileReady({
			expected: {
				lineCount: updatedContent.lineCount,
				path: fixture.oracle.largeFilePath,
				sha256: updatedContent.sha256,
			},
			oracle: fixture.oracle,
			page,
		});
		expect(proxy.snapshot().metadataRequestCount).toBe(establishedStreamCount);
		expect(await retention.stop()).toBeNull();
		retention = null;
		await proveAnnotationBatchRecovery({
			kind: 'file.annotations',
			metadataFrames,
			page,
			proxy,
			selectedContentReady: async (): Promise<void> =>
				await waitForSelectedFileReady({
					expected: {
						lineCount: updatedContent.lineCount,
						path: fixture.oracle.largeFilePath,
						sha256: updatedContent.sha256,
					},
					oracle: fixture.oracle,
					page: activePage,
				}),
			surface: 'file',
		});
		await page
			.getByTestId('bridge-viewer-mode-host-file')
			.getByRole('button', { name: 'Review', exact: true })
			.click();
		const reviewFile = fixture.oracle.reviewFiles[0];
		if (reviewFile === undefined) throw new Error('Fault recovery needs a changed Review file.');
		const reviewShell = page.getByTestId('review-viewer-shell');
		await reviewShell.waitFor({ state: 'attached' });
		const installedItemCount = Number(
			await reviewShell.getAttribute('data-review-metadata-item-count'),
		);
		const installedTreeRowCount = Number(
			await reviewShell.getAttribute('data-review-metadata-tree-row-count'),
		);
		expect(
			installedItemCount,
			'The changed Review fixture must install item rows.',
		).toBeGreaterThan(0);
		expect(
			installedTreeRowCount,
			'The changed Review fixture must install tree rows.',
		).toBeGreaterThan(0);
		await selectReviewFile({ page, path: reviewFile.path });
		await waitForSelectedReviewReady({ itemId: reviewFile.itemId, page });
		const priorReviewRevision = Number(
			await reviewShell.getAttribute('data-review-metadata-revision'),
		);
		expect(Number.isSafeInteger(priorReviewRevision)).toBe(true);
		const reviewContentRequestCountBeforeMutation = reviewContentRequests.length;
		const reorderApplied = proxy.armSemanticBatchFault({
			mode: 'reorder',
			subscriptionKind: 'review.metadata',
		});
		const changedReviewFile = await fixture.mutateReviewFile();
		expect(changedReviewFile.path).toBe(reviewFile.path);
		expect(await reorderApplied).toMatchObject({
			mode: 'reorder',
			subscriptionKind: 'review.metadata',
		});
		await waitForReviewRevisionAfter(page, priorReviewRevision);
		const recoveredItemId = await waitForSelectedReviewItemAfterMutation({
			expectedPath: changedReviewFile.path,
			page,
			previousItemId: reviewFile.itemId,
		});
		expect(recoveredItemId).not.toBe(reviewFile.itemId);
		expect(
			reviewContentRequests
				.slice(reviewContentRequestCountBeforeMutation)
				.some(
					(request): boolean =>
						request.itemId === recoveredItemId && request.responseStatus === 200,
				),
		).toBe(true);
		const recoveredReviewRevision = Number(
			await reviewShell.getAttribute('data-review-metadata-revision'),
		);
		expect(Number.isSafeInteger(recoveredReviewRevision)).toBe(true);
		expect(recoveredReviewRevision).toBeGreaterThan(priorReviewRevision);
		expect(proxy.snapshot().metadataRequestCount).toBe(establishedStreamCount);
		await proveAnnotationBatchRecovery({
			kind: 'review.annotations',
			metadataFrames,
			page,
			proxy,
			selectedContentReady: async (): Promise<void> =>
				await waitForSelectedReviewReady({ itemId: recoveredItemId, page: activePage }),
			surface: 'review',
		});
		const siblingReviewRevision = Number(
			await reviewShell.getAttribute('data-review-metadata-revision'),
		);
		const siblingReviewMutation = await fixture.mutateReviewFile();
		await waitForReviewRevisionAfter(page, siblingReviewRevision);
		const siblingReviewItemId = await waitForSelectedReviewItemAfterMutation({
			expectedPath: siblingReviewMutation.path,
			page,
			previousItemId: recoveredItemId,
		});
		expect(siblingReviewItemId).not.toBe(recoveredItemId);
		expect(proxy.snapshot().metadataRequestCount).toBe(establishedStreamCount);
		expect(proxy.snapshot().activeMetadataResponses).toBe(1);
		expect(proxy.snapshot().lostViewAcknowledgements).toEqual([]);
		await proveLostViewAcknowledgement({
			metadataFrames,
			page: activePage,
			proxy,
			mutateReviewFile: fixture.mutateReviewFile,
			waitForUpdatedReview: async ({ path, priorRevision }): Promise<void> => {
				await waitForReviewRevisionAfter(activePage, priorRevision);
				await waitForSelectedReviewItemAfterMutation({
					expectedPath: path,
					page: activePage,
					previousItemId: siblingReviewItemId,
				});
			},
		});
		expect(proxy.snapshot().semanticMetadataClosures).toEqual([]);
	} catch (error: unknown) {
		const snapshot = proxy?.snapshot();
		primaryError = new Error(
			`Semantic batch fault journey failed: proxy=${JSON.stringify(
				snapshot === undefined
					? null
					: {
							metadataRequestCount: snapshot.metadataRequestCount,
							semanticFaultsApplied: snapshot.semanticFaultsApplied,
							semanticKindsByResponse: snapshot.semanticKindsByResponse,
							lostViewAcknowledgements: snapshot.lostViewAcknowledgements,
							semanticMetadataClosures: snapshot.semanticMetadataClosures,
						},
			)} backend=${server?.diagnostics() ?? 'not started'}`,
			{ cause: error },
		);
	} finally {
		await runAllOwnedCleanupOperations({
			operations: [
				{
					name: 'last-good File retention',
					run: async (): Promise<void> => {
						if (retention !== null) expect(await retention.stop()).toBeNull();
					},
				},
				{ name: 'browser', run: async (): Promise<void> => await browser?.close() },
				{ name: 'semantic fault proxy', run: async (): Promise<void> => await proxy?.stop() },
				{
					name: 'Vite and Swift',
					run: async (): Promise<void> => {
						if (server === null) return;
						const cleanup = await server.stop();
						expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
						expect(cleanup.forcedTerminationRequired).toBe(false);
					},
				},
				{ name: 'fixture', run: fixture.dispose },
			],
			...(primaryError === undefined ? {} : { primaryError }),
		});
	}
});

async function proveAnnotationBatchRecovery(props: {
	readonly kind: Extract<BridgeSemanticBatchKind, 'file.annotations' | 'review.annotations'>;
	readonly metadataFrames: MetadataFrameObservation;
	readonly page: Page;
	readonly proxy: BridgeStreamFaultProxy;
	readonly selectedContentReady: () => Promise<void>;
	readonly surface: 'file' | 'review';
}): Promise<void> {
	const oldBody = `${props.surface} annotation retained through a semantic batch fault`;
	const oldMessage = await createSavedAnnotation(props.page, props.surface, oldBody);
	const retained = props.page.locator(
		`[data-annotation-message-id="${oldMessage.messageId}"][data-annotation-draft="absent"]`,
	);
	await retained.getByText(oldBody, { exact: true }).waitFor({ state: 'visible' });
	const priorBatch = props.metadataFrames.frames.findLast(
		(frame): frame is BatchBegin =>
			frame.kind === 'subscription.batchBegin' && frame.subscriptionKind === props.kind,
	);
	if (priorBatch === undefined)
		throw new Error(`${props.kind} never installed its initial catalog.`);
	const faultStartIndex = props.metadataFrames.frames.length;
	const streamCount = props.proxy.snapshot().metadataRequestCount;
	const faultApplied = props.proxy.armSemanticBatchFault({
		mode: 'drop',
		subscriptionKind: props.kind,
	});
	const retainedAtFault = faultApplied.then(async (fault): Promise<typeof fault> => {
		await retained.getByText(oldBody, { exact: true }).waitFor({ state: 'visible' });
		expect(props.proxy.snapshot().metadataRequestCount).toBe(streamCount);
		return fault;
	});
	void retainedAtFault.catch((): void => {});
	const newBody = `${props.surface} annotation catalog converged after a dropped batch part`;
	const newMessage = await createSavedReply(
		props.page,
		props.surface,
		oldMessage.threadId,
		newBody,
	);
	const fault = await retainedAtFault;
	const replacement = await props.metadataFrames.waitFor(
		(frame): boolean =>
			frame.kind === 'subscription.batchBegin' &&
			frame.subscriptionKind === props.kind &&
			frame.subscriptionId === fault.subscriptionId &&
			frame.batchId !== fault.batchId,
		faultStartIndex,
	);
	if (replacement.kind !== 'subscription.batchBegin') {
		throw new Error(`${props.kind} replacement did not begin.`);
	}
	await props.proxy.waitForBatchComplete(replacement.batchId);
	await props.page
		.locator(
			`[data-annotation-message-id="${newMessage.messageId}"][data-annotation-draft="absent"]`,
		)
		.getByText(newBody, { exact: true })
		.waitFor({ state: 'visible' });
	await retained.getByText(oldBody, { exact: true }).waitFor({ state: 'visible' });
	await props.selectedContentReady();
	const framesSinceFault = props.metadataFrames.frames.slice(faultStartIndex);
	const annotationBegins = framesSinceFault.filter(
		(frame): frame is BatchBegin =>
			frame.kind === 'subscription.batchBegin' && frame.subscriptionKind === props.kind,
	);
	const oldSubscriptionFrames = framesSinceFault.filter(
		(frame): boolean =>
			'subscriptionId' in frame && frame.subscriptionId === priorBatch.subscriptionId,
	);
	expect(fault.subscriptionId).toBe(priorBatch.subscriptionId);
	expect(annotationBegins.length).toBeGreaterThanOrEqual(2);
	expect(
		annotationBegins.every((begin): boolean => begin.subscriptionId === priorBatch.subscriptionId),
	).toBe(true);
	expect(
		oldSubscriptionFrames.filter(
			(frame): boolean =>
				frame.kind === 'subscription.reset' ||
				frame.kind === 'subscription.end' ||
				frame.kind === 'subscription.cancelled',
		),
	).toEqual([]);
	expect(props.proxy.snapshot().metadataRequestCount).toBe(streamCount);
}

async function createSavedAnnotation(
	page: Page,
	surface: 'file' | 'review',
	body: string,
): Promise<{ readonly messageId: string; readonly threadId: string }> {
	const created = waitForCommittedAnnotationOutcome(page, 'root.create', surface);
	await selectRangeForAnnotation({ endLine: 5, page, startLine: 2, surface });
	const composer = page.getByRole('textbox', { name: 'Write an annotation in Markdown' });
	await composer.fill(`${body} Initial`);
	const creation = await created;
	const flushed = waitForCommittedAnnotationOutcome(page, 'draft.flush', surface);
	await composer.fill(body);
	const flush = await flushed;
	expect(flush.messageId).toBe(creation.messageId);
	const saved = waitForCommittedAnnotationOutcome(page, 'draft.save', surface);
	await page.getByRole('button', { name: 'Save annotation', exact: true }).last().click();
	const save = await saved;
	expect(save.messageId).toBe(creation.messageId);
	await page
		.locator(`[data-annotation-message-id="${save.messageId}"][data-annotation-draft="absent"]`)
		.getByText(body, { exact: true })
		.waitFor({ state: 'visible' });
	return { messageId: save.messageId, threadId: save.context.threadId };
}

async function createSavedReply(
	page: Page,
	surface: 'file' | 'review',
	threadId: string,
	body: string,
): Promise<{ readonly messageId: string }> {
	const thread = page.locator(`[data-annotation-thread-id="${threadId}"]`);
	await thread.getByRole('button', { name: 'Reply to annotation thread', exact: true }).click();
	const composer = page.getByRole('textbox', { name: 'Reply with Markdown', exact: true });
	await composer.waitFor({ state: 'visible' });
	const created = waitForCommittedAnnotationOutcome(page, 'reply.create', surface);
	await composer.fill(`${body} Initial`);
	const creation = await created;
	const flushed = waitForCommittedAnnotationOutcome(page, 'draft.flush', surface);
	await composer.fill(body);
	const flush = await flushed;
	expect(flush.messageId).toBe(creation.messageId);
	const saved = waitForCommittedAnnotationOutcome(page, 'draft.save', surface);
	await thread.getByRole('button', { name: 'Save annotation', exact: true }).last().click();
	const save = await saved;
	expect(save.messageId).toBe(creation.messageId);
	await page
		.locator(`[data-annotation-message-id="${save.messageId}"][data-annotation-draft="absent"]`)
		.getByText(body, { exact: true })
		.waitFor({ state: 'visible' });
	return { messageId: save.messageId };
}

function observeReviewContentRequests(page: Page): ReviewContentRequestObservation[] {
	const observations: ReviewContentRequestObservation[] = [];
	const observationByRequest = new WeakMap<Request, number>();
	page.on('request', (request): void => {
		if (
			request.method() !== 'POST' ||
			new URL(request.url()).pathname !== '/__bridge-product/content'
		)
			return;
		let bodyValue: unknown;
		try {
			bodyValue = JSON.parse(request.postData() ?? 'null');
		} catch {
			return;
		}
		if (typeof bodyValue !== 'object' || bodyValue === null || Array.isArray(bodyValue)) return;
		const body = bodyValue as Readonly<Record<string, unknown>>;
		if (body['contentKind'] !== 'review.content') return;
		const descriptorValue = body['descriptor'];
		const descriptor =
			typeof descriptorValue === 'object' &&
			descriptorValue !== null &&
			!Array.isArray(descriptorValue)
				? (descriptorValue as Readonly<Record<string, unknown>>)
				: null;
		const itemId = descriptor?.['itemId'];
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

async function waitForSelectedReviewItemAfterMutation(props: {
	readonly expectedPath: string;
	readonly page: Page;
	readonly previousItemId: string;
}): Promise<string> {
	return await props.page.evaluate(
		({ expectedPath, previousItemId }): Promise<string> =>
			new Promise((resolve): void => {
				let checkForReadyItem = (): void => {};
				let observeOpenShadowRoots = (_root: ParentNode): void => {};
				const observer = new MutationObserver((mutations): void => {
					for (const mutation of mutations) {
						if (mutation.type !== 'childList') continue;
						for (const node of mutation.addedNodes) {
							if (node instanceof Element) observeOpenShadowRoots(node);
						}
					}
					checkForReadyItem();
				});
				const observedRoots = new WeakSet<Node>();
				const observeRoot = (root: Node): void => {
					if (observedRoots.has(root)) return;
					observedRoots.add(root);
					observer.observe(root, {
						attributeFilter: [
							'data-selected-item-id',
							'data-selected-content-state',
							'data-selected-display-path',
							'data-bridge-painted-source-correlations',
						],
						attributes: true,
						childList: true,
						subtree: true,
					});
				};
				observeOpenShadowRoots = (root: ParentNode): void => {
					if (root instanceof Element && root.shadowRoot !== null) {
						observeRoot(root.shadowRoot);
						observeOpenShadowRoots(root.shadowRoot);
					}
					for (const element of root.querySelectorAll('*')) {
						if (element.shadowRoot === null) continue;
						observeRoot(element.shadowRoot);
						observeOpenShadowRoots(element.shadowRoot);
					}
				};
				const hasPaintedItem = (panel: Element, itemId: string): boolean => {
					const roots: ParentNode[] = [panel];
					while (roots.length > 0) {
						const root = roots.shift();
						if (root === undefined) break;
						for (const container of root.querySelectorAll(
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
										correlation.itemId === itemId,
								)
							)
								return true;
						}
						if (root instanceof Element && root.shadowRoot !== null) roots.push(root.shadowRoot);
						for (const element of root.querySelectorAll('*')) {
							if (element.shadowRoot !== null) roots.push(element.shadowRoot);
						}
					}
					return false;
				};
				checkForReadyItem = (): void => {
					const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
					const itemId = panel?.getAttribute('data-selected-item-id') ?? null;
					if (
						panel === null ||
						itemId === null ||
						itemId === previousItemId ||
						panel.getAttribute('data-selected-display-path') !== expectedPath ||
						panel.getAttribute('data-selected-content-state') !== 'ready' ||
						!hasPaintedItem(panel, itemId)
					)
						return;
					observer.disconnect();
					resolve(itemId);
				};
				observeRoot(document.body);
				observeOpenShadowRoots(document.body);
				checkForReadyItem();
			}),
		{
			expectedPath: props.expectedPath,
			previousItemId: props.previousItemId,
		},
	);
}

async function waitForReviewRevisionAfter(page: Page, priorRevision: number): Promise<void> {
	await page.evaluate(
		(previousRevision): Promise<void> =>
			new Promise((resolve): void => {
				const currentRevision = (): number =>
					Number(
						document
							.querySelector('[data-testid="review-viewer-shell"]')
							?.getAttribute('data-review-metadata-revision'),
					);
				const observer = new MutationObserver((): void => {
					if (currentRevision() <= previousRevision) return;
					observer.disconnect();
					resolve();
				});
				observer.observe(document.body, {
					attributeFilter: ['data-review-metadata-revision'],
					attributes: true,
					childList: true,
					subtree: true,
				});
				if (currentRevision() > previousRevision) {
					observer.disconnect();
					resolve();
				}
			}),
		priorRevision,
	);
}

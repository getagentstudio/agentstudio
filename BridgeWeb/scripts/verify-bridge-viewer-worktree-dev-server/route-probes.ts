import type { Page, Route } from 'playwright';
import { z } from 'zod';

import { BridgeProductTestFactRecorder } from '../../src/core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';
import {
	parseBridgeWorktreeDevFileContentRouteRequest,
	type BridgeWorktreeDevFileContentRouteRequest,
} from '../bridge-worktree-dev-reload-diagnostics.ts';
import {
	buildReviewContentRouteDeltaProof,
	reviewContentRouteDeltaSatisfied,
	type ReviewContentRouteDeltaProof,
	type ReviewMetadataBeforeContentProof,
} from '../verify-bridge-viewer-worktree-review-proof.ts';
import { currentVerifierJourneySignal } from './browser-session.ts';
import {
	scenarioNameFromDevServerUrl,
	worktreeDevServerOrigin,
	worktreeReviewDevServerUrl,
} from './config.ts';
import {
	normalWorktreeReviewPerformanceClickTargets,
	worktreeFilePathEligibleForPerformanceClick,
} from './scroll-performance.ts';
import {
	bridgeDevTelemetryStatusSchema,
	worktreeReviewMetadataFrameResponseSchema,
	type BridgeDevTelemetryStatusSample,
	type ReviewPerformanceClickTarget,
	type ReviewRouteProbe,
	type WorktreeBridgeTelemetrySampleProof,
	type WorktreeFileContentRouteProbe,
	type WorktreeReviewRouteProof,
} from './types.ts';
import type { Deferred } from './utils.ts';

interface ReviewProbeRoute {
	readonly request: () => { readonly url: () => string };
	readonly continue: () => Promise<void>;
	readonly fulfill: (response: {
		readonly status: number;
		readonly contentType: string;
		readonly body: string;
	}) => Promise<void>;
}

export interface ReviewRouteProbePage {
	readonly route: (
		pattern: string,
		handler: (route: ReviewProbeRoute) => Promise<void>,
	) => Promise<unknown>;
	readonly unroute: (
		pattern: string,
		handler: (route: ReviewProbeRoute) => Promise<void>,
	) => Promise<void>;
	readonly on: (event: 'close', listener: () => void) => unknown;
	readonly off: (event: 'close', listener: () => void) => unknown;
}

export async function readBridgeWorktreeVerifierTelemetrySamples(
	page: Page,
): Promise<readonly WorktreeBridgeTelemetrySampleProof[]> {
	return await page.evaluate(
		(): readonly WorktreeBridgeTelemetrySampleProof[] =>
			window.bridgeWorktreeVerifierTelemetrySamples ?? [],
	);
}

export async function readBridgeDevTelemetryStatusSamples(
	page: Page,
): Promise<readonly WorktreeBridgeTelemetrySampleProof[]> {
	const response = await page.request.get(
		new URL('/__bridge-dev-telemetry/status', page.url()).toString(),
	);
	const responseBody = await response.json();
	const parsedStatus = bridgeDevTelemetryStatusSchema.safeParse(responseBody);
	if (!parsedStatus.success) {
		throw new Error('Bridge dev telemetry status endpoint returned an invalid contract');
	}
	return parsedStatus.data.recentSamples.map(mapBridgeTelemetrySampleToProof);
}

export function mapBridgeTelemetrySampleToProof(
	sample: BridgeDevTelemetryStatusSample,
): WorktreeBridgeTelemetrySampleProof {
	return {
		durationMilliseconds: sample.durationMilliseconds,
		name: sample.name,
		numericAttributes: sample.numericAttributes,
		phase: sample.stringAttributes['agentstudio.bridge.phase'] ?? null,
		result: sample.stringAttributes['agentstudio.bridge.result'] ?? null,
		slice: sample.stringAttributes['agentstudio.bridge.slice'] ?? null,
		transport: sample.stringAttributes['agentstudio.bridge.transport'] ?? null,
		viewer: sample.stringAttributes['agentstudio.bridge.viewer'] ?? null,
		workerCommand: sample.stringAttributes['agentstudio.bridge.worker.command'] ?? null,
		workerLane: sample.stringAttributes['agentstudio.bridge.worker.lane'] ?? null,
		workerTaskKind: sample.stringAttributes['agentstudio.bridge.worker.task_kind'] ?? null,
	};
}

export async function installFileContentRouteGate(props: {
	readonly gate: Deferred<void>;
	readonly failFirstHit?: boolean;
	readonly failFirstHitDescriptorId?: string;
	readonly page: Page;
	readonly pathPattern?: string;
}): Promise<WorktreeFileContentRouteProbe> {
	const hitUrls: string[] = [];
	const hits: BridgeWorktreeDevFileContentRouteRequest[] = [];
	const foreignHitUrls: string[] = [];
	const pathPattern = props.pathPattern ?? '**/__bridge-product/content**';
	let failedFirstHit = false;
	const routeHandler = async (route: Route): Promise<void> => {
		const request = route.request();
		const requestUrl = request.url();
		const hit = parseBridgeWorktreeDevFileContentRouteRequest({
			expectedOrigin: worktreeDevServerOrigin,
			method: request.method(),
			postData: request.postData(),
			url: requestUrl,
		});
		if (hit === null) {
			foreignHitUrls.push(requestUrl);
			await route.fulfill({
				status: 599,
				contentType: 'text/plain',
				body: `foreign Worktree/File content route origin rejected: ${requestUrl}`,
			});
			return;
		}
		hits.push(hit);
		hitUrls.push(requestUrl);
		const failFirstHitMatchesRequest =
			props.failFirstHitDescriptorId === undefined ||
			hit.descriptorId === props.failFirstHitDescriptorId;
		if (props.failFirstHit === true && !failedFirstHit && failFirstHitMatchesRequest) {
			failedFirstHit = true;
			await route.fulfill({
				status: 503,
				contentType: 'text/plain',
				body: 'forced refresh failure for Gate 0.a retry proof',
			});
			return;
		}
		await props.gate.promise;
		await route.continue();
	};
	await props.page.route(pathPattern, routeHandler);
	return {
		dispose: async (): Promise<void> => {
			await props.page.unroute(pathPattern, routeHandler);
		},
		foreignHitCount: (): number => foreignHitUrls.length,
		foreignHitUrls: (): readonly string[] => foreignHitUrls,
		hitCount: (): number => hitUrls.length,
		hits: (): readonly BridgeWorktreeDevFileContentRouteRequest[] => hits,
		hitUrls: (): readonly string[] => hitUrls,
	};
}

export async function installReviewRouteProbe(
	page: ReviewRouteProbePage,
	options: { readonly contentGate?: Deferred<void>; readonly signal?: AbortSignal } = {},
): Promise<ReviewRouteProbe> {
	const metadataHitUrls: string[] = [];
	const contentHitUrls: string[] = [];
	const contentHitFacts = new BridgeProductTestFactRecorder<string>();
	let isClosed = false;
	const signal = options.signal ?? currentVerifierJourneySignal();
	let closeReason = new Error('Review content route probe closed.');
	const abortObservation = (): void => {
		closeReason =
			signal?.reason instanceof Error ? signal.reason : new Error(String(signal?.reason));
		closeObservation();
	};
	const closeObservation = (): void => {
		if (isClosed) return;
		isClosed = true;
		contentHitFacts.close(closeReason);
		signal?.removeEventListener('abort', abortObservation);
		page.off('close', closeObservation);
	};
	page.on('close', closeObservation);
	signal?.addEventListener('abort', abortObservation, { once: true });
	if (signal?.aborted) abortObservation();
	const metadataRoutePattern = '**/__bridge-worktree/review-metadata**';
	const contentRoutePattern = '**/__bridge-worktree/review-content/**';
	const assertReviewRouteOrigin = async (route: ReviewProbeRoute): Promise<boolean> => {
		const requestUrl = route.request().url();
		if (bridgeWorktreeDevReviewRouteUsesOrigin(requestUrl)) {
			return true;
		}
		await route.fulfill({
			status: 599,
			contentType: 'text/plain',
			body: `foreign Worktree/Review route origin rejected: ${requestUrl}`,
		});
		return false;
	};
	const metadataRouteHandler = async (route: ReviewProbeRoute): Promise<void> => {
		if (!(await assertReviewRouteOrigin(route))) {
			return;
		}
		metadataHitUrls.push(route.request().url());
		await route.continue();
	};
	const contentRouteHandler = async (route: ReviewProbeRoute): Promise<void> => {
		if (!(await assertReviewRouteOrigin(route))) {
			return;
		}
		contentHitUrls.push(route.request().url());
		if (!isClosed) contentHitFacts.record(route.request().url());
		if (options.contentGate !== undefined) {
			await options.contentGate.promise;
		}
		await route.continue();
	};
	await page.route(metadataRoutePattern, metadataRouteHandler);
	await page.route(contentRoutePattern, contentRouteHandler);
	return {
		contentHitCount: (): number => contentHitUrls.length,
		contentHitUrls: (): readonly string[] => contentHitUrls,
		waitForContentHits: async (matches, label = 'Review content route'): Promise<void> => {
			try {
				if (isClosed) throw closeReason;
				if (matches(contentHitUrls)) return;
				await contentHitFacts.waitFor((): boolean => matches(contentHitUrls));
			} catch (error: unknown) {
				throw new Error(
					`${String(error)}; awaiting ${label}; contentHitUrls=${JSON.stringify(contentHitUrls)}`,
					{ cause: error },
				);
			}
		},
		dispose: async (): Promise<void> => {
			closeObservation();
			const results = await Promise.allSettled([
				page.unroute(metadataRoutePattern, metadataRouteHandler),
				page.unroute(contentRoutePattern, contentRouteHandler),
			]);
			const failures = results.filter((result) => result.status === 'rejected');
			if (failures.length > 0) {
				throw new AggregateError(
					failures.map((result): unknown => result.reason),
					'Review route probe cleanup failed.',
				);
			}
		},
		metadataHitCount: (): number => metadataHitUrls.length,
		metadataHitUrls: (): readonly string[] => metadataHitUrls,
	};
}

export async function waitForReviewMetadataBeforeContentStartupProof(props: {
	readonly page: Page;
	readonly routeProbe: ReviewRouteProbe;
}): Promise<ReviewMetadataBeforeContentProof> {
	await waitForReviewContentRouteHitCountAbove({
		minHitCount: 1,
		routeProbe: props.routeProbe,
	});
	try {
		await props.page.waitForFunction(
			(): boolean => {
				const proof = window.bridgeWorktreeReviewMetadataBeforeContentProof();
				return (
					proof.treeVisibleWhileBlocked &&
					proof.treeVisibleRowCountWhileBlocked > 0 &&
					proof.selectedDisplayPathWhileBlocked !== null &&
					proof.selectedContentStateWhileBlocked !== 'ready'
				);
			},
			undefined,
			{ timeout: 30_000 },
		);
	} catch (error) {
		const diagnostic = await props.page.evaluate(() =>
			window.bridgeWorktreeReviewMetadataBeforeContentProof(),
		);
		throw new Error(
			`Timed out waiting for Worktree/Review metadata projection before content completion: ${JSON.stringify(diagnostic)}`,
			{ cause: error },
		);
	}
	const domProof = await props.page.evaluate(() =>
		window.bridgeWorktreeReviewMetadataBeforeContentProof(),
	);
	return {
		...domProof,
		blockedContentHitCount: props.routeProbe.contentHitCount(),
		metadataHitCount: props.routeProbe.metadataHitCount(),
	};
}

export async function fetchWorktreeReviewItemIdForDisplayPath(
	displayPath: string,
): Promise<string> {
	let metadataFrameResponse = await fetchWorktreeReviewMetadataFrame();
	let inspectedItemCount = 0;
	for (;;) {
		inspectedItemCount += metadataFrameResponse.protocolFrame.itemMetadata.length;
		const item = metadataFrameResponse.protocolFrame.itemMetadata.find(
			(candidate): boolean =>
				candidate.basePath === displayPath || candidate.headPath === displayPath,
		);
		if (item !== undefined) {
			return item.itemId;
		}
		const nextWindowCursor = metadataFrameResponse.nextWindowCursor ?? null;
		if (nextWindowCursor === null) {
			break;
		}
		metadataFrameResponse = await fetchWorktreeReviewMetadataWindowFrame(nextWindowCursor);
	}
	throw new Error(
		`Expected Worktree/Review metadata to include ${displayPath}; got ${inspectedItemCount} items`,
	);
}

export async function fetchWorktreeReviewContentDescriptorIdsForItemId(
	itemId: string,
): Promise<readonly string[]> {
	let metadataFrameResponse = await fetchWorktreeReviewMetadataFrame();
	for (;;) {
		const item = metadataFrameResponse.protocolFrame.itemMetadata.find(
			(candidate): boolean => candidate.itemId === itemId,
		);
		if (item !== undefined) {
			return Object.values(item.contentDescriptorIdsByRole ?? {}).filter(
				(descriptorId): descriptorId is string =>
					typeof descriptorId === 'string' && descriptorId.length > 0,
			);
		}
		const nextWindowCursor = metadataFrameResponse.nextWindowCursor ?? null;
		if (nextWindowCursor === null) {
			break;
		}
		metadataFrameResponse = await fetchWorktreeReviewMetadataWindowFrame(nextWindowCursor);
	}
	throw new Error(`Expected Worktree/Review metadata descriptors for ${itemId}`);
}

export async function fetchWorktreeReviewPerformanceClickTargets(): Promise<
	readonly ReviewPerformanceClickTarget[]
> {
	let metadataFrameResponse = await fetchWorktreeReviewMetadataFrame();
	const displayPathByItemId = new Map<string, string>();
	const lineCountByItemId = new Map<string, number>();
	for (;;) {
		for (const row of metadataFrameResponse.protocolFrame.treeRows ?? []) {
			if (!row.isDirectory && worktreeFilePathEligibleForPerformanceClick(row.path)) {
				displayPathByItemId.set(row.itemId, row.path);
			}
		}
		for (const fact of metadataFrameResponse.protocolFrame.extentFacts ?? []) {
			lineCountByItemId.set(
				fact.itemId,
				(lineCountByItemId.get(fact.itemId) ?? 0) + fact.lineCount,
			);
		}
		const nextWindowCursor = metadataFrameResponse.nextWindowCursor ?? null;
		if (nextWindowCursor === null) {
			break;
		}
		metadataFrameResponse = await fetchWorktreeReviewMetadataWindowFrame(nextWindowCursor);
	}
	return normalWorktreeReviewPerformanceClickTargets(
		[...displayPathByItemId.entries()].map(
			([itemId, displayPath]): ReviewPerformanceClickTarget => ({
				displayPath,
				lineCount: lineCountByItemId.get(itemId) ?? null,
			}),
		),
	);
}

export async function fetchWorktreeReviewMetadataFrame(): Promise<
	z.infer<typeof worktreeReviewMetadataFrameResponseSchema>
> {
	const frameUrl = new URL('/__bridge-worktree/review-metadata', worktreeReviewDevServerUrl);
	frameUrl.searchParams.set('scenario', scenarioNameFromDevServerUrl(worktreeReviewDevServerUrl));
	frameUrl.searchParams.set('frame', 'review-metadata-snapshot');
	const response = await fetch(frameUrl);
	if (!response.ok) {
		throw new Error(`Expected Worktree/Review metadata frame route, got ${response.status}`);
	}
	return worktreeReviewMetadataFrameResponseSchema.parse(await response.json());
}

export function requireWorktreeReviewComparisonProof(
	metadataFrameResponse: z.infer<typeof worktreeReviewMetadataFrameResponseSchema>,
): Pick<
	WorktreeReviewRouteProof,
	| 'reviewMetadataBaseEndpointId'
	| 'reviewMetadataBaseEndpointKind'
	| 'reviewMetadataBaseProviderIdentity'
	| 'reviewMetadataHeadEndpointId'
	| 'reviewMetadataHeadEndpointKind'
	| 'reviewMetadataHeadProviderIdentity'
> {
	const comparison = metadataFrameResponse.protocolFrame.comparison;
	if (comparison === undefined) {
		throw new Error('Expected Worktree/Review metadata snapshot to include comparison identity');
	}
	return {
		reviewMetadataBaseEndpointId: comparison.baseEndpoint.endpointId,
		reviewMetadataBaseEndpointKind: comparison.baseEndpoint.kind,
		reviewMetadataBaseProviderIdentity: comparison.baseEndpoint.providerIdentity,
		reviewMetadataHeadEndpointId: comparison.headEndpoint.endpointId,
		reviewMetadataHeadEndpointKind: comparison.headEndpoint.kind,
		reviewMetadataHeadProviderIdentity: comparison.headEndpoint.providerIdentity,
	};
}

export async function fetchWorktreeReviewMetadataWindowFrame(
	cursor: string,
): Promise<z.infer<typeof worktreeReviewMetadataFrameResponseSchema>> {
	const frameUrl = new URL('/__bridge-worktree/review-metadata', worktreeReviewDevServerUrl);
	frameUrl.searchParams.set('scenario', scenarioNameFromDevServerUrl(worktreeReviewDevServerUrl));
	frameUrl.searchParams.set('frame', 'review-metadata-window');
	frameUrl.searchParams.set('cursor', cursor);
	const response = await fetch(frameUrl);
	if (!response.ok) {
		throw new Error(`Expected Worktree/Review metadata window route, got ${response.status}`);
	}
	return worktreeReviewMetadataFrameResponseSchema.parse(await response.json());
}

export function bridgeWorktreeDevReviewRouteUsesOrigin(url: string): boolean {
	let parsedUrl: URL;
	try {
		parsedUrl = new URL(url);
	} catch {
		return false;
	}
	return (
		parsedUrl.origin === worktreeDevServerOrigin &&
		(parsedUrl.pathname === '/__bridge-worktree/review-metadata' ||
			parsedUrl.pathname.startsWith('/__bridge-worktree/review-content/'))
	);
}

export async function waitForReviewContentRouteHitContaining(props: {
	readonly needle: string;
	readonly routeProbe: ReviewRouteProbe;
}): Promise<void> {
	await props.routeProbe.waitForContentHits(
		(hitUrls): boolean => hitUrls.some((url): boolean => url.includes(props.needle)),
		`needle=${props.needle}`,
	);
}

export async function waitForReviewContentRouteHitCountAbove(props: {
	readonly minHitCount: number;
	readonly routeProbe: ReviewRouteProbe;
}): Promise<void> {
	await props.routeProbe.waitForContentHits(
		(hitUrls): boolean => hitUrls.length >= props.minHitCount,
		`minimum count=${props.minHitCount}`,
	);
}

export async function waitForReviewContentRouteHitAfterIndex(props: {
	readonly beforeHitCount: number;
	readonly expectedContentDescriptorIds?: readonly string[];
	readonly expectedItemId: string;
	readonly routeProbe: ReviewRouteProbe;
}): Promise<ReviewContentRouteDeltaProof> {
	const readProof = (allHitUrls: readonly string[]): ReviewContentRouteDeltaProof =>
		buildReviewContentRouteDeltaProof({
			allHitUrls,
			beforeHitCount: props.beforeHitCount,
			expectedItemId: props.expectedItemId,
			...(props.expectedContentDescriptorIds === undefined
				? {}
				: { expectedContentDescriptorIds: props.expectedContentDescriptorIds }),
		});
	await props.routeProbe.waitForContentHits(
		(hitUrls): boolean => reviewContentRouteDeltaSatisfied(readProof(hitUrls)),
		`item=${props.expectedItemId}; descriptors=${JSON.stringify(props.expectedContentDescriptorIds ?? [])}; after=${props.beforeHitCount}`,
	);
	return readProof(props.routeProbe.contentHitUrls());
}

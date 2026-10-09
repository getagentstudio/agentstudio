import {
	requireFreshReviewRoute,
	requireReviewTreeSelection,
} from './product-only-real-router-review-contract.ts';

export const bridgeProductStartupFixtureIdentities = {
	invalid: 'e51803d06d8dafd56d6c694569ed238bb3dd8bddadfec6d26b2834b5d5892a68',
	valid: '29ddcc6601f7b531f637cf9a3c57a1dbdeee6dcc9e60087218ea951c7edc4498',
} as const;

export const bridgeViewerProductOnlySelectors = {
	activeFileContextButton:
		'[data-bridge-viewer-mode-active="true"] [data-testid="bridge-viewer-context-file"]',
	activeReviewContextButton:
		'[data-bridge-viewer-mode-active="true"] [data-testid="bridge-viewer-context-review"]',
	appRoot: '[data-testid="bridge-app-root"]',
	fileCodeCanvas: '[data-testid="bridge-file-viewer-code-canvas"]',
	fileMarkdownCanvas: '[data-testid="bridge-markdown-canvas"]',
	fileShell: '[data-testid="bridge-file-viewer-shell"]',
	reviewCodePanel: '[data-testid="bridge-code-view-panel"]',
	reviewCodeScrollOwner: '[data-testid="bridge-code-view-panel"] .bridge-code-view-scroll-owner',
	reviewShell: '[data-testid="review-viewer-shell"]',
	reviewTreeHost: '[data-testid="bridge-review-trees-panel"] file-tree-container',
} as const;

export interface BridgeViewerProductRouteTranscriptEntry {
	readonly callMethod?: string | null;
	readonly contentUnknownReadRefusalCorrelated?: boolean;
	readonly contentKind: string | null;
	readonly documentGeneration: number;
	readonly httpStatus: number | null;
	readonly method: string;
	readonly ordinal: number;
	readonly paneSessionId: string | null;
	readonly path: string;
	readonly requestKind: string | null;
	readonly requestSettled: boolean;
	readonly requestSequence: number | null;
	readonly responseCode: string | null;
	readonly responseKind: string | null;
	readonly resultAcknowledged: boolean;
	readonly settledResponseKind: string | null;
	readonly streamKind: string | null;
	readonly subscriptionKind: string | null;
	readonly workerInstanceId: string | null;
}

export interface BridgeViewerLegacyRouteTranscriptEntry {
	readonly finalWindow: boolean | null;
	readonly frameKind: string | null;
	readonly httpStatus: number | null;
	readonly ordinal: number;
	readonly path: string;
	readonly sequence: number | null;
}

export interface BridgeViewerLegacyIntakeTranscriptEntry {
	readonly frameKind: string | null;
	readonly generation: number | null;
	readonly kind: string | null;
	readonly sequence: number | null;
	readonly streamId: string | null;
}

export interface BridgeViewerObservedWorker {
	readonly closed: boolean;
	readonly closedBeforeJourneyCompletion: boolean;
	readonly documentGeneration: number;
	readonly kind: 'comm-worker' | 'module-worker' | 'portable-blob-worker';
	readonly url: string;
}

export interface BridgeViewerProductFailureTransportSnapshot {
	readonly entries: readonly Omit<
		BridgeViewerProductRouteTranscriptEntry,
		'paneSessionId' | 'workerInstanceId'
	>[];
	readonly unfinishedRequestOrdinals: readonly number[];
	readonly unresolvedWaiters: readonly BridgeViewerUnresolvedWaiter[];
}

// A journey waiter still pending (or rejected) when the journey failed, with the
// page generation whose requests alone may settle it.
export interface BridgeViewerUnresolvedWaiter {
	readonly documentGeneration: number;
	readonly name:
		| 'file-metadata-open'
		| 'subscription-receipt'
		| 'legacy-metadata-completion'
		| 'product-response-quiescence'
		| 'review-metadata-open';
}

export interface BridgeViewerReviewFailureDemandSnapshot {
	readonly deferredCount: number | null;
	readonly droppedIntentCount: number | null;
	readonly executorInFlightAfter: number | null;
	readonly executorQueuedLoadAfter: number | null;
	readonly failedCount: number | null;
	readonly foregroundIntentCount: number | null;
	readonly interest: string | null;
	readonly loadedCount: number | null;
	readonly resultReason: string | null;
	readonly resultStatus: string | null;
	readonly staleDropCount: number | null;
	readonly visibleIntentCount: number | null;
}

export interface BridgeViewerReviewFailureSnapshot {
	readonly codeScroll: {
		readonly clientHeight: number;
		readonly scrollHeight: number;
		readonly scrollTop: number;
	};
	readonly codeViewManifestItemCount: number;
	readonly metadataItemCount: number;
	readonly mountedItemCount: number;
	readonly pierreWorkerPool: {
		readonly activeTaskCount: number | null;
		readonly busyWorkerCount: number | null;
		readonly managerState: string | null;
		readonly queuedTaskCount: number | null;
		readonly totalWorkerCount: number | null;
		readonly workersFailed: boolean | null;
	};
	readonly selectedDemand: BridgeViewerReviewFailureDemandSnapshot;
	readonly selectedItemVisible: boolean;
	readonly visibleContentStateCounts: Readonly<Record<string, number>>;
	readonly visibleDemand: BridgeViewerReviewFailureDemandSnapshot;
	readonly visibleItemCount: number;
}

export interface BridgeViewerProductOnlyJourneyFailureCheckpoint {
	readonly browserCleanup: BridgeViewerProductOnlyJourneyProof['browserCleanup'];
	readonly browserDiagnostics: readonly BridgeViewerConsoleDiagnostic[];
	readonly captureStatus: 'captured' | 'unavailable';
	readonly documentGeneration: number;
	readonly failedResponses: readonly BridgeViewerFailedResponse[];
	readonly failureCode: string;
	readonly review: BridgeViewerReviewFailureSnapshot | null;
	readonly transport: BridgeViewerProductFailureTransportSnapshot;
	readonly workers: readonly Omit<BridgeViewerObservedWorker, 'url'>[];
}

export interface BridgeViewerFailedResponse {
	readonly documentGeneration: number;
	readonly method: string;
	readonly path: string;
	readonly resourceType: string;
	readonly status: number;
}

export interface BridgeViewerMainWindowProductRequest {
	readonly method: string;
	readonly path: string;
	readonly transport: 'fetch' | 'xmlHttpRequest';
}

export interface BridgeViewerConsoleDiagnostic {
	readonly columnNumber: number | null;
	readonly lineNumber: number | null;
	readonly path: string | null;
	readonly text: string;
	readonly type: 'error' | 'warning';
}

export interface BridgeViewerFileProductStateSnapshot {
	readonly bodyPreviewCharacterCount: number;
	readonly bodyPreviewSha256: string | null;
	readonly codeCanvasVisible: boolean;
	readonly displayStatus: string | null;
	readonly metadataFileRowCount: number;
	readonly metadataTreeRowCount: number;
	readonly renderedDisplayPath: string | null;
	readonly selectedContentState: string | null;
	readonly selectedDisplayPath: string | null;
	readonly shellCount: number;
}

export interface BridgeViewerFileMarkdownStateSnapshot {
	readonly articleCharacterCount: number;
	readonly canvasVisible: boolean;
	readonly selectedDisplayPath: string | null;
	readonly sourcePath: string | null;
}

export interface BridgeViewerReviewProductStateSnapshot {
	readonly codePanelVisible: boolean;
	readonly metadataItemCount: number;
	readonly metadataTreeRowCount: number;
	readonly selectedContentCacheKeyCount: number;
	readonly selectedContentCacheKeysSha256: string | null;
	readonly selectedContentCharacterCount: number;
	readonly selectedContentLineCount: number;
	readonly selectedContentState: string | null;
	readonly selectedDisplayPath: string | null;
	readonly shellCount: number;
	readonly unavailableTextVisible: boolean;
}

export interface BridgeViewerReviewDirectoryDisclosure {
	readonly expanded: string;
	readonly path: string;
}

export interface BridgeViewerReviewHydrationMilestone {
	readonly hydratedNonSelectedItemIds: readonly string[];
	readonly label: 'final' | 'initial' | 'middle' | 'quarter' | 'threeQuarter';
	readonly visibleNonSelectedItemIds: readonly string[];
}

export interface BridgeViewerReviewHydrationWindowFailure {
	readonly hydratedNonSelectedItemIds: readonly string[];
	readonly scrollTop: number;
	readonly visibleContentStates: readonly {
		readonly contentState: string | null;
		readonly itemId: string;
	}[];
	readonly visibleNonSelectedItemIds: readonly string[];
}

export interface BridgeViewerReviewHydrationCoverage {
	readonly missingHydratedVisibleWindows: readonly BridgeViewerReviewHydrationWindowFailure[];
	readonly observedHydratedNonSelectedItemIds: readonly string[];
	readonly settledWindowCount: number;
}

export interface BridgeViewerReviewMountedHeaderOrderViolation {
	readonly expectedItemIndexes: readonly (number | null)[];
	readonly mountedItemIds: readonly string[];
}

export interface BridgeViewerReviewBackwardTraversalProof {
	readonly completedScrollTop: number;
	readonly hydrationCoverage: BridgeViewerReviewHydrationCoverage;
	readonly mountedHeaderOrderViolations: readonly BridgeViewerReviewMountedHeaderOrderViolation[];
	readonly selectedItemIdAtCompletion: string | null;
}

export interface BridgeViewerReviewFreshRouteProof {
	readonly backwardTraversal: BridgeViewerReviewBackwardTraversalProof;
	readonly codeScrollOwnerIdentityStable: boolean;
	readonly codeViewManifestItemCount: number;
	readonly completedScroll: {
		readonly clientHeight: number;
		readonly scrollHeight: number;
		readonly scrollTop: number;
	};
	readonly expectedItemIds: readonly string[];
	readonly finalDirectoryDisclosure: readonly BridgeViewerReviewDirectoryDisclosure[];
	readonly hydrationCoverage: BridgeViewerReviewHydrationCoverage;
	readonly hydrationMilestones: readonly BridgeViewerReviewHydrationMilestone[];
	readonly initialDirectoryDisclosure: readonly BridgeViewerReviewDirectoryDisclosure[];
	readonly metadataItemCount: number;
	readonly mountedHeaderOrderViolations: readonly BridgeViewerReviewMountedHeaderOrderViolation[];
	readonly observedHeaderItemIds: readonly string[];
	readonly selectedItemIdAtCompletion: string | null;
	readonly selectedItemIdAtStart: string | null;
	readonly treeHostIdentityStable: boolean;
	readonly treeShadowRootIdentityStable: boolean;
}

export interface BridgeViewerReviewTreeSelectionProof {
	readonly codeViewManifestItemCountAfterSelection: number;
	readonly codeViewManifestItemCountBeforeSelection: number;
	readonly mountedHeaderOrderViolation: BridgeViewerReviewMountedHeaderOrderViolation | null;
	readonly selectedContentState: string | null;
	readonly selectedItemIdAtCompletion: string | null;
	readonly selectedItemIdAtStart: string | null;
	readonly targetItemId: string;
	readonly targetPath: string;
}

export interface BridgeViewerSelectorSnapshot {
	readonly activeFileContextButtonCount: number;
	readonly activeReviewContextButtonCount: number;
	readonly fileCodeCanvasCount: number;
	readonly fileShellCount: number;
	readonly reviewShellCount: number;
}

export interface BridgeViewerProductOnlyJourneyProof {
	readonly browser: {
		readonly headless: true;
		readonly name: string;
		readonly version: string;
	};
	readonly browserCleanup: {
		readonly browserConnectedAfterClose: boolean;
		readonly closedWorkerCount: number;
		readonly observedWorkerCount: number;
		readonly pageClosed: boolean;
	};
	readonly consoleDiagnostics: readonly BridgeViewerConsoleDiagnostic[];
	readonly consoleErrors: readonly string[];
	readonly documentGeneration: {
		readonly atJourneyCompletion: number;
		readonly atJourneyStart: number;
	};
	readonly failedResponses: readonly BridgeViewerFailedResponse[];
	readonly fileAfterReviewFirstSwitch: BridgeViewerFileProductStateSnapshot;
	readonly fileAfterFirstAcknowledgement: BridgeViewerFileProductStateSnapshot;
	readonly fileAtCompletion: BridgeViewerFileProductStateSnapshot;
	readonly fileMarkdownAtReviewFirstSwitch: BridgeViewerFileMarkdownStateSnapshot;
	readonly legacyIntakeTranscript: readonly BridgeViewerLegacyIntakeTranscriptEntry[];
	readonly legacyRouteTranscript: readonly BridgeViewerLegacyRouteTranscriptEntry[];
	readonly mainWindowProductRouteTranscript: readonly BridgeViewerMainWindowProductRequest[];
	readonly observedPageUrl: string;
	readonly productRouteTranscript: readonly BridgeViewerProductRouteTranscriptEntry[];
	readonly reviewFreshRoute: BridgeViewerReviewFreshRouteProof;
	readonly reviewTreeSelection: BridgeViewerReviewTreeSelectionProof;
	readonly reviewAtCompletion: BridgeViewerReviewProductStateSnapshot;
	readonly selectors: typeof bridgeViewerProductOnlySelectors;
	readonly selectorSnapshot: BridgeViewerSelectorSnapshot;
	readonly workers: readonly BridgeViewerObservedWorker[];
}

export interface BridgeViewerProductOnlyContractViolation {
	readonly actual: unknown;
	readonly code: string;
	readonly expected: string;
}

const minimumNontrivialContentCharacterCount = 64;
const minimumNontrivialContentLineCount = 2;

export function collectBridgeViewerProductOnlyContractViolations(
	proof: BridgeViewerProductOnlyJourneyProof,
): readonly BridgeViewerProductOnlyContractViolation[] {
	const violations: BridgeViewerProductOnlyContractViolation[] = [];
	if (
		proof.documentGeneration.atJourneyStart <= 0 ||
		proof.documentGeneration.atJourneyCompletion !== proof.documentGeneration.atJourneyStart
	) {
		violations.push({
			actual: proof.documentGeneration,
			code: 'browser.document-generation-stable-during-journey',
			expected: 'one unchanged main-frame document generation during File -> Review -> File',
		});
	}
	const measuredProductRouteTranscript = proof.productRouteTranscript.filter(
		(entry): boolean => entry.documentGeneration === proof.documentGeneration.atJourneyStart,
	);
	const measuredProof: BridgeViewerProductOnlyJourneyProof = {
		...proof,
		productRouteTranscript: measuredProductRouteTranscript,
	};
	const subscriptionReceiptEntries = measuredProductRouteTranscript.filter(
		(entry): boolean => entry.requestKind === 'subscription.acknowledge',
	);
	if (
		subscriptionReceiptEntries.length === 0 ||
		subscriptionReceiptEntries.some(
			(entry): boolean =>
				entry.httpStatus !== 200 || entry.responseKind !== 'subscription.acknowledged',
		)
	) {
		violations.push({
			actual: subscriptionReceiptEntries.map((entry) => ({
				status: entry.httpStatus,
				responseKind: entry.responseKind,
			})),
			code: 'transport.subscription-receipt-accepted',
			expected:
				'at least one cumulative subscription receipt acknowledged with HTTP 200 and subscription.acknowledged',
		});
	}
	const contentAcknowledgementEntries = measuredProductRouteTranscript.filter(
		(entry): boolean => entry.requestKind === 'content.acknowledge',
	);
	if (
		contentAcknowledgementEntries.length === 0 ||
		contentAcknowledgementEntries.some(
			(entry): boolean =>
				entry.httpStatus !== 204 &&
				!(entry.httpStatus === 404 && entry.contentUnknownReadRefusalCorrelated === true),
		)
	) {
		violations.push({
			actual: contentAcknowledgementEntries.map((entry) => ({
				status: entry.httpStatus,
				unknownReadCorrelated: entry.contentUnknownReadRefusalCorrelated ?? false,
			})),
			code: 'transport.content-acknowledgement-bodyless-204',
			expected:
				'at least one content credit accepted with bodyless HTTP 204, or a strictly correlated unknownRead 404',
		});
	}

	requireAcceptedSubscription({
		proof: measuredProof,
		subscriptionKind: 'file.metadata',
		violations,
	});
	requireAcceptedSubscription({
		proof: measuredProof,
		subscriptionKind: 'review.metadata',
		violations,
	});

	if (!fileProductStateReady(proof.fileAfterReviewFirstSwitch)) {
		violations.push({
			actual: proof.fileAfterReviewFirstSwitch,
			code: 'journey.review-first-file-switch-visible-readable',
			expected:
				'Review-first same-document activation paints nonempty File metadata and readable selected File content',
		});
	}

	if (!observesCurrentWorktreeFileStart(proof)) {
		violations.push({
			actual: {
				file: proof.fileAfterFirstAcknowledgement,
				observedPageUrl: proof.observedPageUrl,
			},
			code: 'journey.file-start-visible-readable',
			expected:
				'current-worktree File starts active with one real path and non-empty rendered content identity',
		});
	}

	if (!fileProductStateReady(proof.fileAtCompletion)) {
		violations.push({
			actual: proof.fileAtCompletion,
			code: 'file.product-display-ready',
			expected: 'File product metadata rows and selected product content are ready',
		});
	}
	if (!fileMarkdownStateReady(proof.fileMarkdownAtReviewFirstSwitch)) {
		violations.push({
			actual: proof.fileMarkdownAtReviewFirstSwitch,
			code: 'file.markdown-visible-readable',
			expected:
				'selected Markdown paints a visible article with its exact source path and nonempty text',
		});
	}
	if (!fileSelectedContentNontrivial(proof.fileAtCompletion)) {
		violations.push({
			actual: {
				bodyPreviewCharacterCount: proof.fileAtCompletion.bodyPreviewCharacterCount,
				selectedDisplayPath: proof.fileAtCompletion.selectedDisplayPath,
			},
			code: 'file.product-selected-content-nontrivial',
			expected: `at least ${minimumNontrivialContentCharacterCount} characters of actual selected File content`,
		});
	}
	if (!fileReturnPreservesVisibleContent(proof)) {
		violations.push({
			actual: {
				fileAtCompletion: proof.fileAtCompletion,
				fileAtStart: proof.fileAfterFirstAcknowledgement,
			},
			code: 'journey.file-return-stable-visible-readable',
			expected:
				'File is visible and readable after Review and retains its selected path and rendered body identity',
		});
	}
	if (!reviewProductStateReady(proof.reviewAtCompletion)) {
		violations.push({
			actual: proof.reviewAtCompletion,
			code: 'review.product-display-ready',
			expected: 'Review product metadata and selected product content are ready',
		});
	}
	if (!reviewSelectedContentNontrivial(proof.reviewAtCompletion)) {
		violations.push({
			actual: {
				metadataItemCount: proof.reviewAtCompletion.metadataItemCount,
				metadataTreeRowCount: proof.reviewAtCompletion.metadataTreeRowCount,
				selectedContentCharacterCount: proof.reviewAtCompletion.selectedContentCharacterCount,
				selectedContentLineCount: proof.reviewAtCompletion.selectedContentLineCount,
				selectedDisplayPath: proof.reviewAtCompletion.selectedDisplayPath,
			},
			code: 'review.product-selected-content-nontrivial',
			expected: `at least ${minimumNontrivialContentCharacterCount} characters and ${minimumNontrivialContentLineCount} lines of actual selected Review diff content`,
		});
	}
	requireFreshReviewRoute({ proof: proof.reviewFreshRoute, violations });
	requireReviewTreeSelection({ proof: proof.reviewTreeSelection, violations });
	if (proof.consoleDiagnostics.length > 0) {
		violations.push({
			actual: proof.consoleDiagnostics,
			code: 'browser.console-clean',
			expected: 'zero browser console warnings or errors',
		});
	}
	const measuredFailedResponses = proof.failedResponses.filter(
		(response): boolean => response.documentGeneration === proof.documentGeneration.atJourneyStart,
	);
	if (measuredFailedResponses.length > 0) {
		violations.push({
			actual: measuredFailedResponses,
			code: 'browser.failed-responses-absent',
			expected: 'zero measured-document browser responses with HTTP status >= 400',
		});
	}

	requireProductContentRequest({
		contentKind: 'file.content',
		proof: measuredProof,
		violations,
	});
	requireProductContentRequest({
		contentKind: 'review.content',
		proof: measuredProof,
		violations,
	});

	if (proof.legacyRouteTranscript.length > 0) {
		violations.push({
			actual: proof.legacyRouteTranscript,
			code: 'legacy.review-route-traffic-absent',
			expected: 'zero /__bridge-worktree/review-* requests',
		});
	}
	if (proof.legacyIntakeTranscript.length > 0) {
		violations.push({
			actual: proof.legacyIntakeTranscript,
			code: 'legacy.intake-json-traffic-absent',
			expected: 'zero __bridge_intake_json events',
		});
	}
	const mainWindowBootstrapEntries = proof.mainWindowProductRouteTranscript.filter(
		(entry): boolean => entry.method === 'POST' && entry.path === '/__bridge-product/bootstrap',
	);
	if (
		proof.mainWindowProductRouteTranscript.length !== 1 ||
		mainWindowBootstrapEntries.length !== 1
	) {
		violations.push({
			actual: proof.mainWindowProductRouteTranscript,
			code: 'transport.main-window-product-egress-bootstrap-only',
			expected:
				'exactly one main-window POST /__bridge-product/bootstrap and no main-window command, stream, or content request',
		});
	}

	const commWorkers = proof.workers.filter(
		(worker): boolean =>
			worker.kind === 'comm-worker' &&
			worker.documentGeneration === proof.documentGeneration.atJourneyStart,
	);
	if (commWorkers.length !== 1) {
		violations.push({
			actual: commWorkers,
			code: 'worker.single-real-pane-comm-worker',
			expected: 'exactly one real bridge-comm-worker-vite-entry module Worker',
		});
	}
	if (commWorkers.some((worker): boolean => worker.closedBeforeJourneyCompletion)) {
		violations.push({
			actual: commWorkers,
			code: 'worker.comm-worker-survives-measured-journey',
			expected:
				'the measured document generation comm worker remains open through File -> Review -> File',
		});
	}
	if (
		!proof.browserCleanup.pageClosed ||
		proof.browserCleanup.browserConnectedAfterClose ||
		proof.browserCleanup.observedWorkerCount !== proof.workers.length ||
		proof.browserCleanup.closedWorkerCount !== proof.browserCleanup.observedWorkerCount
	) {
		violations.push({
			actual: proof.browserCleanup,
			code: 'worker.teardown-closes-observed-workers',
			expected:
				'closed page, disconnected browser, and one close observation for every observed page worker',
		});
	}
	const workerSessionIdentities = uniqueWorkerSessionIdentities(measuredProductRouteTranscript);
	if (workerSessionIdentities.length !== 1) {
		violations.push({
			actual: workerSessionIdentities,
			code: 'worker.single-pane-session-identity',
			expected: 'exactly one non-empty paneSessionId/workerInstanceId pair',
		});
	}

	const expectedSelectorCounts = {
		activeFileContextButtonCount: 1,
		activeReviewContextButtonCount: 1,
		fileCodeCanvasCount: 1,
		fileShellCount: 1,
		reviewShellCount: 1,
	};
	if (
		proof.selectorSnapshot.activeFileContextButtonCount !==
			expectedSelectorCounts.activeFileContextButtonCount ||
		proof.selectorSnapshot.activeReviewContextButtonCount !==
			expectedSelectorCounts.activeReviewContextButtonCount ||
		proof.selectorSnapshot.fileCodeCanvasCount !== expectedSelectorCounts.fileCodeCanvasCount ||
		proof.selectorSnapshot.fileShellCount !== expectedSelectorCounts.fileShellCount ||
		proof.selectorSnapshot.reviewShellCount !== expectedSelectorCounts.reviewShellCount
	) {
		violations.push({
			actual: proof.selectorSnapshot,
			code: 'composition.stable-selectors-present',
			expected: JSON.stringify(expectedSelectorCounts),
		});
	}

	const startupOrder = requiredProductStartupOrder(measuredProductRouteTranscript);
	if (!startupOrder.satisfied) {
		violations.push({
			actual: startupOrder,
			code: 'transport.exact-startup-order',
			expected:
				'workerSession.open -> metadataStream.open -> Review and File subscription opens, then a subscription receipt',
		});
	}
	return violations;
}

export function uniqueWorkerSessionIdentities(
	transcript: readonly BridgeViewerProductRouteTranscriptEntry[],
): readonly { readonly paneSessionId: string; readonly workerInstanceId: string }[] {
	const identities = new Map<
		string,
		{ readonly paneSessionId: string; readonly workerInstanceId: string }
	>();
	for (const entry of transcript) {
		if (entry.paneSessionId === null || entry.workerInstanceId === null) continue;
		identities.set(`${entry.paneSessionId}\0${entry.workerInstanceId}`, {
			paneSessionId: entry.paneSessionId,
			workerInstanceId: entry.workerInstanceId,
		});
	}
	return [...identities.values()];
}

export function summarizeBridgeProductRequestBody(
	value: unknown,
): Pick<
	BridgeViewerProductRouteTranscriptEntry,
	| 'callMethod'
	| 'contentKind'
	| 'paneSessionId'
	| 'requestKind'
	| 'requestSequence'
	| 'streamKind'
	| 'subscriptionKind'
	| 'workerInstanceId'
> {
	const body = unknownRecord(value);
	const call = unknownRecord(body?.['call']);
	const subscription = unknownRecord(body?.['subscription']);
	return {
		callMethod: stringValue(call?.['method']),
		contentKind: stringValue(body?.['contentKind']),
		paneSessionId: stringValue(body?.['paneSessionId']),
		requestKind: stringValue(body?.['kind']),
		requestSequence: numberValue(body?.['requestSequence']),
		streamKind: stringValue(body?.['streamKind']),
		subscriptionKind:
			stringValue(body?.['subscriptionKind']) ?? stringValue(subscription?.['subscriptionKind']),
		workerInstanceId: stringValue(body?.['workerInstanceId']),
	};
}

export function summarizeBridgeProductResponseBody(value: unknown): {
	readonly responseCode: string | null;
	readonly responseKind: string | null;
} {
	const body = unknownRecord(value);
	return {
		responseCode: stringValue(body?.['code']),
		responseKind: stringValue(body?.['kind']),
	};
}

function requireAcceptedSubscription(props: {
	readonly proof: BridgeViewerProductOnlyJourneyProof;
	readonly subscriptionKind: 'file.metadata' | 'review.metadata';
	readonly violations: BridgeViewerProductOnlyContractViolation[];
}): void {
	const entries = props.proof.productRouteTranscript.filter(
		(entry): boolean =>
			entry.requestKind === 'subscription.open' &&
			entry.subscriptionKind === props.subscriptionKind,
	);
	if (
		entries.length === 0 ||
		entries.some(
			(entry): boolean =>
				entry.responseKind !== 'operation.admitted' ||
				entry.settledResponseKind !== 'subscription.openAccepted' ||
				!entry.resultAcknowledged,
		)
	) {
		props.violations.push({
			actual: entries.map((entry) => ({
				code: entry.responseCode,
				responseKind: entry.responseKind,
				resultAcknowledged: entry.resultAcknowledged,
				settledResponseKind: entry.settledResponseKind,
				status: entry.httpStatus,
			})),
			code: `transport.${props.subscriptionKind}-accepted`,
			expected: `${props.subscriptionKind} admission has a subscription.openAccepted result and an acknowledged read`,
		});
	}
}

function requireProductContentRequest(props: {
	readonly contentKind: 'file.content' | 'review.content';
	readonly proof: BridgeViewerProductOnlyJourneyProof;
	readonly violations: BridgeViewerProductOnlyContractViolation[];
}): void {
	const entries = props.proof.productRouteTranscript.filter(
		(entry): boolean =>
			entry.path === '/__bridge-product/content' && entry.contentKind === props.contentKind,
	);
	if (!entries.some((entry): boolean => entry.httpStatus === 200)) {
		props.violations.push({
			actual: entries.map((entry) => entry.httpStatus),
			code: `transport.${props.contentKind}-request`,
			expected: `at least one successful ${props.contentKind} product request`,
		});
	}
	const unclosedEntries = entries.filter((entry): boolean => !entry.requestSettled);
	if (unclosedEntries.length > 0) {
		props.violations.push({
			actual: unclosedEntries.map((entry) => ({
				ordinal: entry.ordinal,
				status: entry.httpStatus,
			})),
			code: `transport.${props.contentKind}-request-unclosed`,
			expected: `zero unclosed ${props.contentKind} product requests at browser teardown`,
		});
	}
}

function fileProductStateReady(state: BridgeViewerFileProductStateSnapshot): boolean {
	return (
		state.shellCount === 1 &&
		state.codeCanvasVisible &&
		state.displayStatus === 'ready' &&
		state.metadataFileRowCount > 0 &&
		state.metadataTreeRowCount > 0 &&
		state.selectedContentState === 'ready' &&
		state.selectedDisplayPath !== null &&
		state.renderedDisplayPath === state.selectedDisplayPath &&
		state.bodyPreviewCharacterCount > 0 &&
		state.bodyPreviewSha256 !== null
	);
}

function fileMarkdownStateReady(state: BridgeViewerFileMarkdownStateSnapshot): boolean {
	return (
		state.canvasVisible &&
		state.selectedDisplayPath !== null &&
		state.sourcePath === state.selectedDisplayPath &&
		state.articleCharacterCount > 0
	);
}

function reviewProductStateReady(state: BridgeViewerReviewProductStateSnapshot): boolean {
	return (
		state.shellCount === 1 &&
		state.codePanelVisible &&
		state.metadataItemCount > 0 &&
		state.metadataTreeRowCount > 0 &&
		state.selectedContentState === 'ready' &&
		state.selectedDisplayPath !== null &&
		state.selectedContentCacheKeyCount > 0 &&
		state.selectedContentCacheKeysSha256 !== null &&
		state.selectedContentCharacterCount > 0 &&
		state.selectedContentLineCount > 0 &&
		!state.unavailableTextVisible
	);
}

function fileSelectedContentNontrivial(state: BridgeViewerFileProductStateSnapshot): boolean {
	return state.bodyPreviewCharacterCount >= minimumNontrivialContentCharacterCount;
}

function reviewSelectedContentNontrivial(state: BridgeViewerReviewProductStateSnapshot): boolean {
	return (
		state.selectedContentCharacterCount >= minimumNontrivialContentCharacterCount &&
		state.selectedContentLineCount >= minimumNontrivialContentLineCount
	);
}

function observesCurrentWorktreeFileStart(proof: BridgeViewerProductOnlyJourneyProof): boolean {
	const pageUrl = new URL(proof.observedPageUrl);
	return (
		pageUrl.searchParams.get('scenario') === 'current-worktree' &&
		pageUrl.searchParams.get('viewer') === 'file' &&
		fileProductStateReady(proof.fileAfterFirstAcknowledgement)
	);
}

function fileReturnPreservesVisibleContent(proof: BridgeViewerProductOnlyJourneyProof): boolean {
	return (
		fileProductStateReady(proof.fileAtCompletion) &&
		proof.fileAtCompletion.selectedDisplayPath ===
			proof.fileAfterFirstAcknowledgement.selectedDisplayPath &&
		proof.fileAtCompletion.renderedDisplayPath ===
			proof.fileAfterFirstAcknowledgement.renderedDisplayPath &&
		proof.fileAtCompletion.bodyPreviewSha256 ===
			proof.fileAfterFirstAcknowledgement.bodyPreviewSha256
	);
}

function requiredProductStartupOrder(
	transcript: readonly BridgeViewerProductRouteTranscriptEntry[],
): {
	readonly fileSubscriptionOpenIndex: number;
	readonly subscriptionReceiptIndex: number;
	readonly metadataStreamOpenIndex: number;
	readonly reviewSubscriptionOpenIndex: number;
	readonly satisfied: boolean;
	readonly workerSessionOpenIndex: number;
} {
	const workerSessionOpenIndex = transcript.findIndex(
		(entry): boolean => entry.requestKind === 'workerSession.open',
	);
	const metadataStreamOpenIndex = transcript.findIndex(
		(entry): boolean => entry.requestKind === 'metadataStream.open',
	);
	const subscriptionReceiptIndex = transcript.findIndex(
		(entry): boolean => entry.requestKind === 'subscription.acknowledge',
	);
	const reviewSubscriptionOpenIndex = transcript.findIndex(
		(entry): boolean =>
			entry.requestKind === 'subscription.open' && entry.subscriptionKind === 'review.metadata',
	);
	const fileSubscriptionOpenIndex = transcript.findIndex(
		(entry): boolean =>
			entry.requestKind === 'subscription.open' && entry.subscriptionKind === 'file.metadata',
	);
	return {
		fileSubscriptionOpenIndex,
		subscriptionReceiptIndex,
		metadataStreamOpenIndex,
		reviewSubscriptionOpenIndex,
		satisfied:
			workerSessionOpenIndex >= 0 &&
			metadataStreamOpenIndex > workerSessionOpenIndex &&
			reviewSubscriptionOpenIndex > metadataStreamOpenIndex &&
			fileSubscriptionOpenIndex > metadataStreamOpenIndex &&
			subscriptionReceiptIndex > Math.min(reviewSubscriptionOpenIndex, fileSubscriptionOpenIndex),
		workerSessionOpenIndex,
	};
}

function unknownRecord(value: unknown): Readonly<Record<string, unknown>> | null {
	return isUnknownRecord(value) ? value : null;
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown): string | null {
	return typeof value === 'string' ? value : null;
}

function numberValue(value: unknown): number | null {
	return typeof value === 'number' && Number.isSafeInteger(value) ? value : null;
}

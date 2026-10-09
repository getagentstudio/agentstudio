import { readFile } from 'node:fs/promises';

import { errors, type Page } from 'playwright';
import { describe, expect, test } from 'vitest';

import {
	fileState,
	makePassingProductOnlyProof,
	makeProductEntry,
	passingTranscript,
} from './product-only-real-router-contract.test-support.ts';
import {
	collectBridgeViewerProductOnlyContractViolations,
	type BridgeViewerProductOnlyJourneyProof,
} from './product-only-real-router-contract.ts';
import {
	bridgeReviewOracleTrackedDiffArguments,
	bridgeReviewOraclePathOrder,
	bridgeViewerCleanupProofAfterOwnedStops,
	bridgeViewerProductOnlyRegressionPhase,
} from './product-only-real-router-regression.ts';
import { classifyFreshReviewHydrationWindow } from './product-only-real-router-review-hydration-window.ts';
import { waitForFreshReviewManifestState } from './product-only-real-router-review-proof.ts';

describe('Bridge Viewer product-only real-router regression contract', () => {
	test('requires a painted Markdown source as well as the selected code canvas', () => {
		const passingProof = makePassingProductOnlyProof();
		const missingMarkdownPaint = {
			...passingProof,
			fileMarkdownAtReviewFirstSwitch: {
				articleCharacterCount: 0,
				canvasVisible: false,
				selectedDisplayPath: 'README.md',
				sourcePath: null,
			},
		};

		expect(
			collectBridgeViewerProductOnlyContractViolations(missingMarkdownPaint).map(
				(violation) => violation.code,
			),
		).toContain('file.markdown-visible-readable');
	});

	test('requires correlated painted Review evidence for a visible hydrated item', () => {
		const visibleItem = {
			contentState: 'windowed',
			itemId: 'review-item-1',
			publicationId: 'publication-1',
			renderedLineCount: 8,
			sourceCorrelations: JSON.stringify([
				{
					itemId: 'review-item-1',
					pierreItemId: 'review-item-1',
					publicationId: 'publication-1',
					semanticItemId: 'review-item-1',
				},
			]),
		};
		const painted = classifyFreshReviewHydrationWindow({
			excludedItemIds: [],
			scrollTop: 0,
			selectedItemId: null,
			visibleItems: [visibleItem],
		});
		const mismatched = classifyFreshReviewHydrationWindow({
			excludedItemIds: [],
			scrollTop: 0,
			selectedItemId: null,
			visibleItems: [{ ...visibleItem, publicationId: 'other-publication' }],
		});

		expect(painted.hydratedNonSelectedItemIds).toEqual(['review-item-1']);
		expect(mismatched.visibleNonSelectedItemIds).toEqual(['review-item-1']);
		expect(mismatched.hydratedNonSelectedItemIds).toEqual([]);
	});

	test('uses native Review rename similarity for oracle items', () => {
		// Arrange
		const reviewBase = 'fixture-base';

		// Act
		const trackedDiffArguments = bridgeReviewOracleTrackedDiffArguments(reviewBase);

		// Assert
		expect(trackedDiffArguments).toEqual([
			'diff',
			'--name-status',
			'-z',
			'--find-renames=50%',
			reviewBase,
			'--',
		]);
	});

	test('orders mixed-case Review paths with the product Git comparator', () => {
		// Arrange
		const paths = [
			'docs/specification.md',
			'Package.swift',
			'BridgeWeb/src/app.ts',
			'Package.resolved',
		];

		// Act
		const orderedPaths = paths.toSorted(bridgeReviewOraclePathOrder);

		// Assert
		expect(orderedPaths).toEqual([
			'BridgeWeb/src/app.ts',
			'Package.resolved',
			'Package.swift',
			'docs/specification.md',
		]);
	});

	test('fails immediately when the Review manifest never matches the oracle', async () => {
		// Arrange
		// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The unit fake exercises only the manifest wait boundary.
		const page = {
			waitForFunction: async (): Promise<never> => {
				throw new errors.TimeoutError('manifest mismatch');
			},
		} as unknown as Page;

		// Act / Assert
		await expect(waitForFreshReviewManifestState({ expectedItemCount: 925, page })).rejects.toThrow(
			'REVIEW_FRESH_ROUTE_MANIFEST_MISMATCH: expected=925',
		);
	});

	test('reports backend cleanup facts when Vite never started', () => {
		// Arrange
		const cleanupBeforeStops = {
			exitCode: null,
			exitSignal: null,
			exitedWithinTimeout: true,
			forcedTerminationRequired: false,
			ownedProcessAliveAfterStop: false,
			pid: null,
		} as const;

		// Act
		const cleanup = bridgeViewerCleanupProofAfterOwnedStops({
			backend: {
				exitCode: null,
				exitSignal: null,
				forcedTerminationRequired: true,
				ownedProcessAliveAfterStop: true,
			},
			cleanupBeforeStops,
			vite: null,
		});

		// Assert
		expect(cleanup).toEqual({
			...cleanupBeforeStops,
			forcedTerminationRequired: true,
			ownedProcessAliveAfterStop: true,
		});
	});

	test('keeps the observed acknowledgement, product subscription, legacy, and display topology red', () => {
		const proof = makePassingProductOnlyProof({
			fileReady: false,
			legacyTraffic: true,
			reviewReady: false,
			transcript: [
				makeProductEntry(1, '/__bridge-product/command', 'workerSession.open', 200),
				makeProductEntry(2, '/__bridge-product/stream', 'metadataStream.open', 200),
				{
					...makeProductEntry(3, '/__bridge-product/command', 'subscription.acknowledge', 400),
					responseKind: 'request.error',
				},
				{
					...makeProductEntry(4, '/__bridge-product/command', 'subscription.open', 200),
					responseCode: 'unsupported_subscription',
					responseKind: 'request.error',
					subscriptionKind: 'review.metadata',
				},
				{
					...makeProductEntry(5, '/__bridge-product/command', 'subscription.open', 200),
					responseCode: 'resync_required',
					responseKind: 'request.error',
					subscriptionKind: 'file.metadata',
				},
			],
		});

		const violations = collectBridgeViewerProductOnlyContractViolations(proof);
		const codes = violations.map((violation) => violation.code);

		expect(codes).toContain('transport.subscription-receipt-accepted');
		expect(codes).toContain('transport.content-acknowledgement-bodyless-204');
		expect(codes).toContain('transport.file.metadata-accepted');
		expect(codes).toContain('transport.review.metadata-accepted');
		expect(codes).toContain('file.product-display-ready');
		expect(codes).toContain('review.product-display-ready');
		expect(codes).toContain('legacy.review-route-traffic-absent');
		expect(codes).toContain('legacy.intake-json-traffic-absent');
		expect(bridgeViewerProductOnlyRegressionPhase(violations)).toBe(
			'initial-product-transport-red',
		);
	});

	test('accepts only a correlated typed unknown-read content refusal', () => {
		const correlatedTranscript = passingTranscript().map((entry) =>
			entry.requestKind === 'content.acknowledge' && entry.ordinal === 7
				? {
						...entry,
						contentUnknownReadRefusalCorrelated: true,
						httpStatus: 404,
						responseKind: 'content.acknowledgementRefused',
					}
				: entry,
		);
		const correlatedProof = makePassingProductOnlyProof({ transcript: correlatedTranscript });
		expect(
			collectBridgeViewerProductOnlyContractViolations(correlatedProof).map(
				(violation) => violation.code,
			),
		).not.toContain('transport.content-acknowledgement-bodyless-204');

		const uncorrelatedProof = makePassingProductOnlyProof({
			transcript: correlatedTranscript.map((entry) =>
				entry.httpStatus === 404 ? { ...entry, contentUnknownReadRefusalCorrelated: false } : entry,
			),
		});
		expect(
			collectBridgeViewerProductOnlyContractViolations(uncorrelatedProof).map(
				(violation) => violation.code,
			),
		).toContain('transport.content-acknowledgement-bodyless-204');
	});

	test('uses the same permanent contract for the product-only green state', () => {
		const proof = makePassingProductOnlyProof();

		const violations = collectBridgeViewerProductOnlyContractViolations(proof);

		expect(violations).toEqual([]);
		expect(bridgeViewerProductOnlyRegressionPhase(violations)).toBe('a0-product-only-green');
	});

	test('rejects browser console diagnostics and failed responses from product-only proof', () => {
		// Arrange
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...makePassingProductOnlyProof(),
			consoleDiagnostics: [
				{
					columnNumber: 0,
					lineNumber: 0,
					path: '/favicon.ico',
					text: 'Failed to load resource',
					type: 'error',
				},
			],
			consoleErrors: ['Failed to load resource'],
			failedResponses: [
				{
					documentGeneration: 1,
					method: 'GET',
					path: '/favicon.ico',
					resourceType: 'image',
					status: 404,
				},
			],
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('browser.console-clean');
		expect(violationCodes).toContain('browser.failed-responses-absent');
	});

	test('attributes failed responses to the measured document generation', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const retiredDocumentProof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			failedResponses: [
				{
					documentGeneration: passingProof.documentGeneration.atJourneyStart - 1,
					method: 'POST',
					path: '/__bridge-product/command',
					resourceType: 'fetch',
					status: 409,
				},
			],
		};
		const measuredDocumentProof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			failedResponses: [
				{
					documentGeneration: passingProof.documentGeneration.atJourneyStart,
					method: 'POST',
					path: '/__bridge-product/command',
					resourceType: 'fetch',
					status: 409,
				},
			],
		};

		// Act
		const retiredDocumentViolationCodes = collectBridgeViewerProductOnlyContractViolations(
			retiredDocumentProof,
		).map((violation) => violation.code);
		const measuredDocumentViolationCodes = collectBridgeViewerProductOnlyContractViolations(
			measuredDocumentProof,
		).map((violation) => violation.code);

		// Assert
		expect(retiredDocumentViolationCodes).not.toContain('browser.failed-responses-absent');
		expect(measuredDocumentViolationCodes).toContain('browser.failed-responses-absent');
	});

	test('separates a completed File content response from unclosed teardown residue', () => {
		// Arrange
		const transcript = [
			...passingTranscript(),
			{
				...makeProductEntry(8, '/__bridge-product/content', 'content.open', null),
				contentKind: 'file.content',
			},
		];
		const proof = makePassingProductOnlyProof({ transcript });

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).not.toContain('transport.file.content-request');
		expect(violationCodes).toContain('transport.file.content-request-unclosed');
	});

	test('requires the real File to Review to File journey to retain visible content identity', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			fileAtCompletion: {
				...passingProof.fileAtCompletion,
				bodyPreviewSha256: 'different-returned-content',
				codeCanvasVisible: false,
			},
			reviewAtCompletion: {
				...passingProof.reviewAtCompletion,
				selectedContentCharacterCount: 0,
			},
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('file.product-display-ready');
		expect(violationCodes).toContain('review.product-display-ready');
		expect(violationCodes).toContain('journey.file-return-stable-visible-readable');
	});

	test('rejects an empty File surface after a Review-first same-document switch', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			fileAfterReviewFirstSwitch: fileState(false),
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('journey.review-first-file-switch-visible-readable');
	});

	test('rejects ordinary product requests issued by the main window', () => {
		// Arrange
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...makePassingProductOnlyProof(),
			mainWindowProductRouteTranscript: [
				{ method: 'POST', path: '/__bridge-product/bootstrap', transport: 'fetch' },
				{ method: 'POST', path: '/__bridge-product/content', transport: 'fetch' },
				{
					method: 'POST',
					path: '/__bridge-product/command',
					transport: 'xmlHttpRequest',
				},
			],
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('transport.main-window-product-egress-bootstrap-only');
	});

	test('requires every observed worker to close during browser teardown', () => {
		// Arrange
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...makePassingProductOnlyProof(),
			browserCleanup: {
				browserConnectedAfterClose: false,
				closedWorkerCount: 0,
				observedWorkerCount: 1,
				pageClosed: true,
			},
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('worker.teardown-closes-observed-workers');
	});

	test('rejects a main-frame document replacement during the measured File to Review to File journey', () => {
		const proof = {
			...makePassingProductOnlyProof(),
			documentGeneration: {
				atJourneyCompletion: 2,
				atJourneyStart: 1,
			},
		};

		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		expect(violationCodes).toContain('browser.document-generation-stable-during-journey');
	});

	test('rejects replacement comm workers and session identities across the journey', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			productRouteTranscript: [
				...passingProof.productRouteTranscript,
				{
					...makeProductEntry(8, '/__bridge-product/content', null, 200),
					contentKind: 'file.content',
					paneSessionId: 'pane-session-2',
					workerInstanceId: 'worker-instance-2',
				},
			],
			workers: [
				...passingProof.workers,
				{
					closed: false,
					closedBeforeJourneyCompletion: false,
					documentGeneration: 1,
					kind: 'comm-worker',
					url: '/src/core/comm-worker/bridge-comm-worker-vite-entry.ts?replacement&type=module',
				},
			],
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('worker.single-real-pane-comm-worker');
		expect(violationCodes).toContain('worker.single-pane-session-identity');
	});

	test('rejects a token-sized Review payload presented as readable current-worktree content', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			reviewAtCompletion: {
				...passingProof.reviewAtCompletion,
				metadataItemCount: 1_215,
				metadataTreeRowCount: 1_215,
				selectedContentCharacterCount: 4,
				selectedContentLineCount: 1,
			},
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('review.product-selected-content-nontrivial');
	});

	test('requires at least one completed File content HTTP 200 independently of teardown closure', () => {
		// Arrange
		const transcript = [
			...passingTranscript().filter((entry) => entry.contentKind !== 'file.content'),
			{
				...makeProductEntry(8, '/__bridge-product/content', 'content.open', null),
				contentKind: 'file.content',
			},
		];
		const proof = makePassingProductOnlyProof({ transcript });

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('transport.file.content-request');
		expect(violationCodes).toContain('transport.file.content-request-unclosed');
	});

	test('separates missing fresh-route Pierre membership from selected Review readiness', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			reviewFreshRoute: {
				...passingProof.reviewFreshRoute,
				observedHeaderItemIds: passingProof.reviewFreshRoute.observedHeaderItemIds.slice(0, -1),
			},
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('REVIEW_FRESH_ROUTE_MANIFEST_MISSING');
		expect(violationCodes).not.toContain('review.product-display-ready');
	});

	test('accepts complete first-seen membership when virtualization observes headers across changing windows', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			reviewFreshRoute: {
				...passingProof.reviewFreshRoute,
				observedHeaderItemIds: ['review-item-1', 'review-item-3', 'review-item-4', 'review-item-2'],
			},
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).not.toContain('REVIEW_FRESH_ROUTE_MANIFEST_MISSING');
		expect(violationCodes).not.toContain('REVIEW_FRESH_ROUTE_LOGICAL_ORDER_MISMATCH');
	});

	test('rejects a mounted Pierre viewport whose headers contradict catalog order', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			reviewFreshRoute: {
				...passingProof.reviewFreshRoute,
				mountedHeaderOrderViolations: [
					{
						expectedItemIndexes: [0, 2, 1],
						mountedItemIds: ['review-item-1', 'review-item-3', 'review-item-2'],
					},
				],
			},
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('REVIEW_FRESH_ROUTE_LOGICAL_ORDER_MISMATCH');
		expect(violationCodes).not.toContain('REVIEW_FRESH_ROUTE_MANIFEST_MISSING');
	});

	test('rejects a tree selection that changes the continuous manifest or fails to hydrate in place', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			reviewTreeSelection: {
				codeViewManifestItemCountAfterSelection: 5,
				codeViewManifestItemCountBeforeSelection: 4,
				mountedHeaderOrderViolation: {
					expectedItemIndexes: [0, 2, 1],
					mountedItemIds: ['review-item-1', 'review-item-3', 'review-item-2'],
				},
				selectedContentState: 'placeholder',
				selectedItemIdAtCompletion: 'review-item-2',
				selectedItemIdAtStart: 'review-item-1',
				targetItemId: 'review-item-2',
				targetPath: '.gitignore',
			},
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('REVIEW_TREE_SELECTION_MANIFEST_CHANGED');
		expect(violationCodes).toContain('REVIEW_TREE_SELECTION_LOGICAL_ORDER_MISMATCH');
		expect(violationCodes).toContain('REVIEW_TREE_SELECTION_CONTENT_MISSING');
	});

	test('rejects mixed fresh disclosure independently of continuous Review membership', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const mixedDisclosure = [
			...passingProof.reviewFreshRoute.initialDirectoryDisclosure,
			{ expanded: 'false', path: 'Sources/AgentStudio' },
		];
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			reviewFreshRoute: {
				...passingProof.reviewFreshRoute,
				finalDirectoryDisclosure: mixedDisclosure,
				initialDirectoryDisclosure: mixedDisclosure,
			},
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('REVIEW_FRESH_ROUTE_DISCLOSURE_MIXED');
		expect(violationCodes).not.toContain('REVIEW_FRESH_ROUTE_MANIFEST_MISSING');
	});

	test('rejects a settled visible Review window whose non-selected body never hydrates', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			reviewFreshRoute: {
				...passingProof.reviewFreshRoute,
				hydrationMilestones: passingProof.reviewFreshRoute.hydrationMilestones.map((milestone) =>
					milestone.label === 'middle'
						? { ...milestone, hydratedNonSelectedItemIds: [] }
						: milestone,
				),
			},
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('REVIEW_FRESH_ROUTE_VISIBLE_HYDRATION_MISSING');
		expect(violationCodes).not.toContain('REVIEW_FRESH_ROUTE_MANIFEST_MISSING');
	});

	test('accepts a milestone with no non-selected visible body', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			reviewFreshRoute: {
				...passingProof.reviewFreshRoute,
				hydrationMilestones: passingProof.reviewFreshRoute.hydrationMilestones.map((milestone) =>
					milestone.label === 'initial'
						? { ...milestone, hydratedNonSelectedItemIds: [], visibleNonSelectedItemIds: [] }
						: milestone,
				),
			},
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).not.toContain('REVIEW_FRESH_ROUTE_VISIBLE_HYDRATION_MISSING');
	});

	test('rejects incomplete full-traversal visible-body hydration coverage between milestones', () => {
		// Arrange: the legacy five milestones are all green, but the exhaustive traversal receipt
		// records that one expected non-selected item was never observed hydrated while visible.
		const passingProof = makePassingProductOnlyProof();
		const reviewFreshRouteWithIncompleteCoverage = {
			...passingProof.reviewFreshRoute,
			hydrationCoverage: {
				expectedNonSelectedItemIds: ['review-item-2', 'review-item-3', 'review-item-4'],
				missingHydratedVisibleWindows: [],
				observedHydratedNonSelectedItemIds: ['review-item-2', 'review-item-4'],
				settledWindowCount: 12,
			},
		};
		const proof: BridgeViewerProductOnlyJourneyProof = {
			...passingProof,
			reviewFreshRoute: reviewFreshRouteWithIncompleteCoverage,
		};

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('REVIEW_FRESH_ROUTE_VISIBLE_HYDRATION_COVERAGE_MISSING');
		expect(violationCodes).not.toContain('REVIEW_FRESH_ROUTE_VISIBLE_HYDRATION_MISSING');
	});

	test('rejects backward traversal that misses hydrated windows or changes selection', () => {
		// Arrange
		const passingProof = makePassingProductOnlyProof();
		const proof = {
			...passingProof,
			reviewFreshRoute: {
				...passingProof.reviewFreshRoute,
				backwardTraversal: {
					completedScrollTop: 900,
					hydrationCoverage: {
						missingHydratedVisibleWindows: [],
						observedHydratedNonSelectedItemIds: [],
						settledWindowCount: 0,
					},
					mountedHeaderOrderViolations: [
						{
							expectedItemIndexes: [2, 1],
							mountedItemIds: ['review-item-3', 'review-item-2'],
						},
					],
					selectedItemIdAtCompletion: 'review-item-2',
				},
			},
		} as unknown as BridgeViewerProductOnlyJourneyProof;

		// Act
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);

		// Assert
		expect(violationCodes).toContain('REVIEW_FRESH_ROUTE_BACKWARD_INVALID');
	});

	test('routes performance-only work to the representative runner and keeps product-only as default', async () => {
		const registeredVerifierSource = await readFile(
			new URL('../verify-bridge-viewer-worktree-dev-server.ts', import.meta.url),
			'utf8',
		);

		expect(registeredVerifierSource).toContain('performanceOnlyMode');
		expect(registeredVerifierSource).toContain('runSelfHostedBridgeViewerPerformanceVerifier');
		expect(registeredVerifierSource).toContain('runBridgeViewerWorktreeDevServerVerifier');
		expect(registeredVerifierSource).toContain('runSelfHostedBridgeViewerProductOnlyRegression');
		expect(registeredVerifierSource).toMatch(
			/performanceOnlyMode[\s\S]*runSelfHostedBridgeViewerPerformanceVerifier\(\)[\s\S]*runSelfHostedBridgeViewerProductOnlyRegression\(\)/u,
		);
	});

	test('launches Browser Mode and the real-router journey through installed Chrome', async () => {
		// Arrange
		const [browserConfigSource, realRouterPageSource] = await Promise.all([
			readFile(new URL('../../vitest.browser.config.ts', import.meta.url), 'utf8'),
			readFile(new URL('./product-only-real-router-page.ts', import.meta.url), 'utf8'),
		]);

		// Act
		const browserConfigUsesNamedInstalledChromeInstances =
			/provider:\s*playwright\(\{\s*launchOptions:\s*\{\s*channel:\s*'chrome',?\s*\},?\s*\}\)/u.test(
				browserConfigSource,
			) &&
			/instances:\s*\[\s*\{\s*browser:\s*'chromium',\s*name:\s*'integration-chromium',?\s*\},?\s*\]/u.test(
				browserConfigSource,
			) &&
			/instances:\s*\[\s*\{\s*browser:\s*'chromium',\s*name:\s*'benchmark-chromium',?\s*\},?\s*\]/u.test(
				browserConfigSource,
			);
		const realRouterUsesInstalledChrome =
			/chromium\.launch\(\{\s*channel:\s*'chrome',\s*headless:\s*true\s*\}\)/u.test(
				realRouterPageSource,
			);

		// Assert
		expect(browserConfigSource).toContain(
			"import { playwright } from '@vitest/browser-playwright';",
		);
		expect(browserConfigUsesNamedInstalledChromeInstances).toBe(true);
		expect(realRouterUsesInstalledChrome).toBe(true);
	});

	test('keeps the official journey ordered File to Review to the same visible File surface', async () => {
		// Arrange
		const [source, reviewProofSource] = await Promise.all([
			readFile(new URL('./product-only-real-router-page.ts', import.meta.url), 'utf8'),
			readFile(new URL('./product-only-real-router-review-proof.ts', import.meta.url), 'utf8'),
		]);

		// Act
		const reviewClickIndex = source.indexOf('activeReviewContextButton).click');
		const reviewCaptureIndex = source.indexOf('const reviewAtCompletion');
		const fileReturnClickIndex = source.lastIndexOf('activeFileContextButton).click');
		const fileReturnCaptureIndex = source.indexOf(
			'fileAtCompletion: await readFileProductState(page)',
		);

		// Assert
		expect(reviewClickIndex).toBeGreaterThan(0);
		expect(reviewCaptureIndex).toBeGreaterThan(reviewClickIndex);
		expect(fileReturnClickIndex).toBeGreaterThan(reviewCaptureIndex);
		expect(fileReturnCaptureIndex).toBeGreaterThan(fileReturnClickIndex);
		expect(source).toContain('data-worktree-open-file-body-preview');
		expect(source).toContain('data-selected-content-character-count');
		expect(source).toContain('data-selected-content-cache-keys');
		expect(source.indexOf("pageUrl.searchParams.set('viewer', 'review')")).toBeLessThan(
			source.indexOf("pageUrl.searchParams.set('viewer', 'file')"),
		);
		expect(source).toContain('proveFreshReviewRoute');
		expect(source).toContain('const fileAfterReviewFirstSwitch = await readFileProductState(page)');
		expect(reviewProofSource).toContain('REVIEW_FRESH_ROUTE_CODE_SCROLL_OWNER_MISSING');
		expect(reviewProofSource).toContain("'diffs-container'");
		expect(reviewProofSource).toContain('function bridgeReviewHostElement');
		expect(reviewProofSource).not.toContain("return path !== null && !path.includes('/')");
		expect(reviewProofSource).not.toContain('contentStates[headerIndex]');
	});

	test('bounds Review hydration settlement and owns browser cleanup before journey timeout returns', async () => {
		// Arrange
		const [journeySource, reviewProofSource, settlementSource] = await Promise.all([
			readFile(new URL('./product-only-real-router-page.ts', import.meta.url), 'utf8'),
			readFile(new URL('./product-only-real-router-review-proof.ts', import.meta.url), 'utf8'),
			readFile(new URL('./product-only-real-router-settlement.ts', import.meta.url), 'utf8'),
		]);

		// Act
		const hydrationTimeoutIsTerminal = reviewProofSource.includes(
			'REVIEW_FRESH_ROUTE_HYDRATION_WINDOW_TIMEOUT',
		);
		const frameSettlementIsBounded = reviewProofSource.includes(
			'waitForFreshReviewFrameSettlement',
		);
		const journeyOwnsDeadlineCleanup = journeySource.includes('createOwnedProductJourneyDeadline');
		const initialHydrationSettlementIndex = reviewProofSource.indexOf(
			'const initialHydrationWindow = await captureFreshReviewHydrationWindow',
		);
		const initialVisibleExclusionSnapshotIndex = reviewProofSource.indexOf(
			'const initialVisibleItemIds = viewportState.visibleItems.map',
		);
		const initialObservedHeaderSnapshotIndex = reviewProofSource.indexOf(
			'appendFirstSeenItemIds({',
		);
		const initialMountedOrderSnapshotIndex = reviewProofSource.indexOf(
			'recordMountedHeaderOrderViolation({',
		);
		const initialSelectionSnapshotIndex = reviewProofSource.indexOf(
			'const selectedItemIdAtStart = viewportState.selectedItemId',
		);
		const initialDisclosureSnapshotIndex = reviewProofSource.indexOf(
			'const initialDirectoryDisclosure = viewportState.directoryDisclosure',
		);
		const traversalLoopIndex = reviewProofSource.indexOf(
			'for (let stepIndex = 0; stepIndex < traversalStepBudget; stepIndex += 1)',
			initialHydrationSettlementIndex,
		);
		const traversalHydrationSettlementIndex = reviewProofSource.indexOf(
			'const settledHydrationWindow = await captureFreshReviewHydrationWindow',
			traversalLoopIndex,
		);
		const traversalObservedHeaderSnapshotIndex = reviewProofSource.indexOf(
			'appendFirstSeenItemIds({',
			traversalLoopIndex,
		);
		const traversalMountedOrderSnapshotIndex = reviewProofSource.indexOf(
			'recordMountedHeaderOrderViolation({',
			traversalLoopIndex,
		);

		// Assert
		expect(hydrationTimeoutIsTerminal).toBe(true);
		expect(frameSettlementIsBounded).toBe(true);
		expect(journeyOwnsDeadlineCleanup).toBe(true);
		expect(initialHydrationSettlementIndex).toBeGreaterThan(0);
		expect(initialVisibleExclusionSnapshotIndex).toBeGreaterThan(initialHydrationSettlementIndex);
		expect(initialObservedHeaderSnapshotIndex).toBeGreaterThan(initialHydrationSettlementIndex);
		expect(initialMountedOrderSnapshotIndex).toBeGreaterThan(initialHydrationSettlementIndex);
		expect(initialSelectionSnapshotIndex).toBeGreaterThan(initialHydrationSettlementIndex);
		expect(initialDisclosureSnapshotIndex).toBeGreaterThan(initialHydrationSettlementIndex);
		expect(traversalLoopIndex).toBeGreaterThan(0);
		expect(traversalHydrationSettlementIndex).toBeGreaterThan(traversalLoopIndex);
		expect(traversalObservedHeaderSnapshotIndex).toBeGreaterThan(traversalHydrationSettlementIndex);
		expect(traversalMountedOrderSnapshotIndex).toBeGreaterThan(traversalHydrationSettlementIndex);
		expect(journeySource).toContain('BRIDGE_PRODUCT_JOURNEY_DEADLINE_EXCEEDED');
		expect(journeySource).not.toContain('requestAnimationFrame');
		expect(reviewProofSource).not.toContain('requestAnimationFrame');
		expect(settlementSource).toContain('page.waitForFunction');
		expect(settlementSource).toContain('{ timeout: props.timeoutMilliseconds }');
	});

	test('persists a scrubbed journey failure checkpoint before browser teardown', async () => {
		// Arrange
		const [journeySource, regressionSource, reviewProofSource] = await Promise.all([
			readFile(new URL('./product-only-real-router-page.ts', import.meta.url), 'utf8'),
			readFile(new URL('./product-only-real-router-regression.ts', import.meta.url), 'utf8'),
			readFile(new URL('./product-only-real-router-review-proof.ts', import.meta.url), 'utf8'),
		]);

		// Act
		const failureCaptureIndex = journeySource.indexOf(
			'captureBridgeViewerProductOnlyJourneyFailure',
		);
		const pageCloseIndex = journeySource.indexOf('await page.close()');

		// Assert
		expect(failureCaptureIndex).toBeGreaterThan(0);
		expect(pageCloseIndex).toBeGreaterThan(failureCaptureIndex);
		expect(journeySource).toContain('BridgeViewerProductOnlyJourneyFailure');
		expect(journeySource).toContain('failureTransportSnapshot()');
		expect(journeySource).not.toContain('paneSessionId: entry.paneSessionId');
		expect(journeySource).not.toContain('workerInstanceId: entry.workerInstanceId');
		expect(reviewProofSource).toContain('readFreshReviewFailureSnapshot');
		expect(reviewProofSource).toContain("'data-review-selected-demand-result-status'");
		expect(reviewProofSource).toContain("'data-review-visible-demand-loaded-count'");
		expect(regressionSource).toContain('bridgeViewerProductOnlyJourneyFailureFromError');
		expect(regressionSource).toContain('readonly journeyFailure:');
		expect(regressionSource).toContain('journeyFailure,');
	});
});

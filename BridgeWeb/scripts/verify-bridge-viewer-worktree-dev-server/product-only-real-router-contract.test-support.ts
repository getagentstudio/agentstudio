import {
	bridgeViewerProductOnlySelectors,
	type BridgeViewerProductOnlyJourneyProof,
	type BridgeViewerProductRouteTranscriptEntry,
} from './product-only-real-router-contract.ts';

export function makePassingProductOnlyProof(
	overrides: {
		readonly fileReady?: boolean;
		readonly legacyTraffic?: boolean;
		readonly reviewReady?: boolean;
		readonly transcript?: readonly BridgeViewerProductRouteTranscriptEntry[];
	} = {},
): BridgeViewerProductOnlyJourneyProof {
	const fileReady = overrides.fileReady ?? true;
	const reviewReady = overrides.reviewReady ?? true;
	const legacyTraffic = overrides.legacyTraffic ?? false;
	return {
		browser: { headless: true, name: 'chromium', version: 'test-version' },
		browserCleanup: {
			browserConnectedAfterClose: false,
			closedWorkerCount: 1,
			observedWorkerCount: 1,
			pageClosed: true,
		},
		consoleDiagnostics: [],
		consoleErrors: [],
		documentGeneration: { atJourneyCompletion: 1, atJourneyStart: 1 },
		failedResponses: [],
		fileAfterReviewFirstSwitch: fileState(fileReady),
		fileAfterFirstAcknowledgement: fileState(fileReady),
		fileAtCompletion: fileState(fileReady),
		fileMarkdownAtReviewFirstSwitch: {
			articleCharacterCount: fileReady ? 128 : 0,
			canvasVisible: fileReady,
			selectedDisplayPath: 'README.md',
			sourcePath: fileReady ? 'README.md' : null,
		},
		legacyIntakeTranscript: legacyTraffic
			? [
					{
						frameKind: 'review.metadataSnapshot',
						generation: 1,
						kind: 'snapshot',
						sequence: 1,
						streamId: 'legacy-review-stream',
					},
				]
			: [],
		legacyRouteTranscript: legacyTraffic
			? [
					{
						finalWindow: true,
						frameKind: 'review.metadataSnapshot',
						httpStatus: 200,
						ordinal: 6,
						path: '/__bridge-worktree/review-metadata',
						sequence: 1,
					},
				]
			: [],
		mainWindowProductRouteTranscript: [
			{ method: 'POST', path: '/__bridge-product/bootstrap', transport: 'fetch' },
		],
		observedPageUrl:
			'http://127.0.0.1:50000/?fixture=worktree&scenario=current-worktree&viewer=file',
		productRouteTranscript: overrides.transcript ?? passingTranscript(),
		reviewFreshRoute: {
			backwardTraversal: {
				completedScrollTop: 0,
				hydrationCoverage: {
					missingHydratedVisibleWindows: [],
					observedHydratedNonSelectedItemIds: ['review-item-2', 'review-item-3', 'review-item-4'],
					settledWindowCount: 4,
				},
				mountedHeaderOrderViolations: [],
				selectedItemIdAtCompletion: 'review-item-1',
			},
			codeScrollOwnerIdentityStable: true,
			codeViewManifestItemCount: 4,
			completedScroll: { clientHeight: 900, scrollHeight: 1_800, scrollTop: 900 },
			expectedItemIds: ['review-item-1', 'review-item-2', 'review-item-3', 'review-item-4'],
			finalDirectoryDisclosure: [{ expanded: 'true', path: 'Sources' }],
			hydrationCoverage: {
				missingHydratedVisibleWindows: [],
				observedHydratedNonSelectedItemIds: ['review-item-2', 'review-item-3', 'review-item-4'],
				settledWindowCount: 4,
			},
			hydrationMilestones: (['initial', 'quarter', 'middle', 'threeQuarter', 'final'] as const).map(
				(label) => ({
					hydratedNonSelectedItemIds: ['review-item-2'],
					label,
					visibleNonSelectedItemIds: ['review-item-2'],
				}),
			),
			initialDirectoryDisclosure: [{ expanded: 'true', path: 'Sources' }],
			metadataItemCount: 4,
			mountedHeaderOrderViolations: [],
			observedHeaderItemIds: ['review-item-1', 'review-item-2', 'review-item-3', 'review-item-4'],
			selectedItemIdAtCompletion: 'review-item-1',
			selectedItemIdAtStart: 'review-item-1',
			treeHostIdentityStable: true,
			treeShadowRootIdentityStable: true,
		},
		reviewTreeSelection: {
			codeViewManifestItemCountAfterSelection: 4,
			codeViewManifestItemCountBeforeSelection: 4,
			mountedHeaderOrderViolation: null,
			selectedContentState: 'hydrated',
			selectedItemIdAtCompletion: 'review-item-2',
			selectedItemIdAtStart: 'review-item-1',
			targetItemId: 'review-item-2',
			targetPath: '.gitignore',
		},
		reviewAtCompletion: {
			codePanelVisible: reviewReady,
			metadataItemCount: reviewReady ? 3 : 1,
			metadataTreeRowCount: reviewReady ? 3 : 1,
			selectedContentCacheKeyCount: reviewReady ? 1 : 0,
			selectedContentCacheKeysSha256: reviewReady ? 'review-cache-keys-sha256' : null,
			selectedContentCharacterCount: reviewReady ? 128 : 0,
			selectedContentLineCount: reviewReady ? 8 : 0,
			selectedContentState: reviewReady ? 'ready' : 'failed',
			selectedDisplayPath: 'Sources/AgentStudio/App/AppDelegate.swift',
			shellCount: 1,
			unavailableTextVisible: !reviewReady,
		},
		selectors: bridgeViewerProductOnlySelectors,
		selectorSnapshot: {
			activeFileContextButtonCount: 1,
			activeReviewContextButtonCount: 1,
			fileCodeCanvasCount: 1,
			fileShellCount: 1,
			reviewShellCount: 1,
		},
		workers: [
			{
				closed: true,
				closedBeforeJourneyCompletion: false,
				documentGeneration: 1,
				kind: 'comm-worker',
				url: '/src/core/comm-worker/bridge-comm-worker-vite-entry.ts?worker_file&type=module',
			},
		],
	};
}

export function passingTranscript(): readonly BridgeViewerProductRouteTranscriptEntry[] {
	return [
		makeProductEntry(1, '/__bridge-product/command', 'workerSession.open', 200),
		makeProductEntry(2, '/__bridge-product/stream', 'metadataStream.open', 200),
		{
			...makeProductEntry(3, '/__bridge-product/command', 'subscription.open', 200),
			responseKind: 'operation.admitted',
			resultAcknowledged: true,
			settledResponseKind: 'subscription.openAccepted',
			subscriptionKind: 'review.metadata',
		},
		{
			...makeProductEntry(4, '/__bridge-product/command', 'subscription.open', 200),
			responseKind: 'operation.admitted',
			resultAcknowledged: true,
			settledResponseKind: 'subscription.openAccepted',
			subscriptionKind: 'file.metadata',
		},
		{
			...makeProductEntry(5, '/__bridge-product/command', 'subscription.acknowledge', 200),
			responseKind: 'subscription.acknowledged',
		},
		{
			...makeProductEntry(6, '/__bridge-product/content', null, 200),
			contentKind: 'file.content',
		},
		makeProductEntry(7, '/__bridge-product/command', 'content.acknowledge', 204),
		{
			...makeProductEntry(8, '/__bridge-product/content', null, 200),
			contentKind: 'review.content',
		},
		makeProductEntry(9, '/__bridge-product/command', 'content.acknowledge', 204),
	];
}

export function makeProductEntry(
	ordinal: number,
	path: string,
	requestKind: string | null,
	httpStatus: number | null,
): BridgeViewerProductRouteTranscriptEntry {
	return {
		contentKind: null,
		documentGeneration: 1,
		httpStatus,
		method: 'POST',
		ordinal,
		paneSessionId: 'pane-session-1',
		path,
		requestKind,
		requestSettled: httpStatus !== null,
		requestSequence: ordinal,
		responseCode: null,
		responseKind: null,
		resultAcknowledged: false,
		settledResponseKind: null,
		streamKind: null,
		subscriptionKind: null,
		workerInstanceId: 'worker-instance-1',
	};
}

export function fileState(ready: boolean): BridgeViewerProductOnlyJourneyProof['fileAtCompletion'] {
	return {
		bodyPreviewCharacterCount: ready ? 128 : 0,
		bodyPreviewSha256: ready ? 'file-body-preview-sha256' : null,
		codeCanvasVisible: ready,
		displayStatus: ready ? 'ready' : 'pending',
		metadataFileRowCount: ready ? 3 : 0,
		metadataTreeRowCount: ready ? 3 : 0,
		renderedDisplayPath: ready ? 'Sources/AgentStudio/App/AppDelegate.swift' : null,
		selectedContentState: ready ? 'ready' : null,
		selectedDisplayPath: ready ? 'Sources/AgentStudio/App/AppDelegate.swift' : null,
		shellCount: 1,
	};
}

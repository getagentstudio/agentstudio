import { describe, expect, expectTypeOf, test } from 'vitest';

import { makeBridgeReviewItem } from '../../foundation/review-package/bridge-review-package-test-support.js';
import {
	bridgeCommWorkerAnnotationCommandAcceptedEvent,
	bridgeCommWorkerAnnotationProjectionConvergenceEvent,
} from './bridge-comm-worker-annotation-runtime-events.js';
import { makeContentRequestDescriptor } from './bridge-comm-worker-runtime-protocol.test-support.js';
import { parseBridgeWorkerMainToServerMessage } from './bridge-worker-contract-parsers.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeCommWorkerBootstrapRequestSchema,
	bridgeWorkerReviewRenderSemanticsSchema,
	bridgeWorkerFileViewContentMetadataSchema,
	bridgeWorkerReviewContentRequestDescriptorSchema,
	bridgeWorkerReviewContentMetadataSchema,
	bridgeWorkerMainToServerMessageSchema,
	bridgeWorkerServerToMainMessageSchema,
	bridgeWorkerSlicePatchEventSchema,
	type BridgeWorkerMainToServerMessage,
	type BridgeWorkerReviewRenderSemantics,
	type BridgeWorkerFileViewContentMetadata,
	type BridgeWorkerReviewContentRequestDescriptor,
	type BridgeWorkerReviewContentMetadata,
} from './bridge-worker-contracts.js';
import { buildBridgeWorkerPierreRenderJob } from './bridge-worker-pierre-render-job.js';

describe('BridgeWorkerContracts', () => {
	test('carries strict per-view recovery status and retry commands', () => {
		const event = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'serverWorkerToMain',
			kind: 'viewRecoveryStatus',
			transferDescriptors: [],
			view: { kind: 'review.annotations', subscriptionId: 'review-comments-1' },
			status: 'failedRetryable',
		} as const;
		const retry = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'mainToServerWorker',
			kind: 'command',
			command: 'viewRecoveryRetry',
			requestId: 'view-recovery-retry-1',
			epoch: 3,
			transferDescriptors: [],
			view: { kind: 'review.annotations', subscriptionId: 'review-comments-1' },
		} as const;

		expect(bridgeWorkerServerToMainMessageSchema.parse(event)).toEqual(event);
		expect(
			bridgeWorkerServerToMainMessageSchema.safeParse({ ...event, status: 'retrying' }).success,
		).toBe(false);
		expect(bridgeWorkerMainToServerMessageSchema.parse(retry)).toEqual(retry);
	});

	test('carries strict annotation commands, acceptance correlation, and complete snapshots per surface', () => {
		const command = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'mainToServerWorker',
			kind: 'command',
			command: 'annotationCommand',
			requestId: 'annotation-worker-request-1',
			epoch: 3,
			transferDescriptors: [],
			surface: 'fileView',
			operation: { kind: 'session.discover' },
		} as const;
		const accepted = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			requestId: command.requestId,
			productRequestId: 'annotation-product-request-1',
			surface: command.surface,
			transferDescriptors: [],
		} as const;
		const historyAccepted = {
			...accepted,
			productRequestId: 'annotation-history-product-request-1',
			outcome: {
				requestId: 'annotation-history-product-request-1',
				sessionId: '00000000-0000-7000-8000-000000000041',
				status: {
					kind: 'history',
					summaries: [
						{
							attemptId: '00000000-0000-7000-8000-000000000042',
							canMarkNotHandled: true,
							createdAt: 1_700_000_000_000,
							messageCount: 1,
							outputKind: 'clipboard_markdown',
							repeatedFromAttemptId: null,
							sessionId: '00000000-0000-7000-8000-000000000041',
							state: 'succeeded',
							updatedAt: 1_700_000_000_001,
						},
					],
				},
				surface: 'file',
			},
		} as const;
		const readyConvergence = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			surface: command.surface,
			transferDescriptors: [],
			state: {
				contentSessionIds: [],
				kind: 'ready',
				stageAttempt: 0,
				snapshot: {
					expectedMessageCount: 0,
					expectedSessionCount: 0,
					expectedThreadCount: 0,
					projectionRevision: 1,
					recoveryStatus: 'available',
					sessions: [],
					sourceGeneration: 1,
					threads: [],
					worktreeId: 'worktree-1',
				},
			},
		} as const;
		const projectionRefreshing = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: { catalogAuthorityRetired: false, kind: 'refreshing' },
			surface: command.surface,
			transferDescriptors: [],
		} as const;
		const projectionUnavailable = {
			...projectionRefreshing,
			state: { catalogAuthorityRetired: false, kind: 'unavailable', retryable: true },
		} as const;

		expect(bridgeWorkerMainToServerMessageSchema.parse(command)).toEqual(command);
		expect(bridgeWorkerServerToMainMessageSchema.parse(accepted)).toEqual(accepted);
		expect(bridgeWorkerServerToMainMessageSchema.parse(historyAccepted)).toEqual(historyAccepted);
		expect(
			bridgeWorkerServerToMainMessageSchema.parse(
				bridgeCommWorkerAnnotationCommandAcceptedEvent({
					actionResult: { kind: 'completed', outcome: historyAccepted.outcome },
					command: {
						method: 'file.annotations.command',
						params: {
							operation: {
								kind: 'output.history',
								sessionId: '00000000-0000-7000-8000-000000000041',
							},
						},
					},
					requestId: accepted.requestId,
				}),
			),
		).toEqual(historyAccepted);
		expect(bridgeWorkerServerToMainMessageSchema.parse(readyConvergence)).toEqual(readyConvergence);
		expect(bridgeWorkerServerToMainMessageSchema.parse(projectionRefreshing)).toEqual(
			projectionRefreshing,
		);
		expect(bridgeWorkerServerToMainMessageSchema.parse(projectionUnavailable)).toEqual(
			projectionUnavailable,
		);
		expect(
			bridgeWorkerServerToMainMessageSchema.parse(
				bridgeCommWorkerAnnotationProjectionConvergenceEvent({
					operationCorrelationId: null,
					state: {
						catalogAuthorityRetired: true,
						error: new Error('Annotation metadata subscription ended.'),
						kind: 'unavailable',
					},
					surface: 'file',
				}),
			),
		).toMatchObject({ state: { catalogAuthorityRetired: true, retryable: false } });
		expect(
			bridgeWorkerServerToMainMessageSchema.safeParse({
				...projectionUnavailable,
				state: { kind: 'unavailable', retryable: true },
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerMainToServerMessageSchema.safeParse({
				...command,
				operation: { kind: 'thread.delete' },
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerServerToMainMessageSchema.safeParse({
				...readyConvergence,
				surface: 'all',
			}).success,
		).toBe(false);
	});

	test('carries a strict surface-bound annotation output inspection with transferred exact bytes', () => {
		const attemptId = '00000000-0000-7000-8000-000000000031';
		const exactBytes = new TextEncoder().encode('# Exact annotation output\n').buffer;
		const command = {
			attemptId,
			command: 'annotationOutputInspect',
			direction: 'mainToServerWorker',
			epoch: 3,
			kind: 'command',
			requestId: 'annotation-output-worker-request-1',
			surface: 'fileView',
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		} as const;
		const descriptor = {
			attemptId,
			contentKind: 'annotation.output',
			contentType: 'text/markdown; charset=utf-8',
			declaredByteLength: exactBytes.byteLength,
			descriptorId: 'annotation-output-descriptor-1',
			encoding: 'utf-8',
			expectedSha256: 'a'.repeat(64),
			formatVersion: 1,
			maximumBytes: exactBytes.byteLength,
			outputKind: 'clipboard_markdown',
			surface: 'file',
		} as const;
		const result = {
			descriptor,
			direction: 'serverWorkerToMain',
			exactBytes,
			kind: 'annotationOutputInspection',
			requestId: command.requestId,
			surface: command.surface,
			transferDescriptors: [
				{
					byteLength: exactBytes.byteLength,
					fieldPath: ['exactBytes'],
					messageKind: 'annotationOutputInspection',
					mode: 'transfer',
				},
			],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		} as const;

		expect(bridgeWorkerMainToServerMessageSchema.parse(command)).toEqual(command);
		expect(bridgeWorkerServerToMainMessageSchema.parse(result)).toEqual(result);
		for (const invalidCommand of [
			{ ...command, unexpected: true },
			{ ...command, attemptId: 'not-a-uuidv7' },
			{ ...command, wireVersion: BRIDGE_WORKER_WIRE_VERSION + 1 },
		]) {
			expect(bridgeWorkerMainToServerMessageSchema.safeParse(invalidCommand).success).toBe(false);
		}
		for (const invalidResult of [
			{ ...result, unexpected: true },
			{ ...result, surface: 'review' },
			{ ...result, descriptor: { ...descriptor, surface: 'review' } },
			{ ...result, transferDescriptors: [] },
			{
				...result,
				transferDescriptors: [{ ...result.transferDescriptors[0], mode: 'clone' }],
			},
		]) {
			expect(bridgeWorkerServerToMainMessageSchema.safeParse(invalidResult).success).toBe(false);
		}
	});

	test('requires selection identity and source to be cleared together', () => {
		// Arrange
		const selectionCommand = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'mainToServerWorker',
			kind: 'command',
			command: 'select',
			requestId: 'request-selection-pair',
			epoch: 3,
			transferDescriptors: [],
			surface: 'review',
		};

		// Act
		const missingSelectionSource = bridgeWorkerMainToServerMessageSchema.safeParse({
			...selectionCommand,
			selectedItemId: 'item-1',
			selectedSource: null,
		});
		const missingSelectionIdentity = bridgeWorkerMainToServerMessageSchema.safeParse({
			...selectionCommand,
			selectedItemId: null,
			selectedSource: 'user',
		});
		const clearedSelection = bridgeWorkerMainToServerMessageSchema.safeParse({
			...selectionCommand,
			selectedItemId: null,
			selectedSource: null,
		});

		// Assert
		expect(missingSelectionSource.success).toBe(false);
		expect(missingSelectionIdentity.success).toBe(false);
		expect(clearedSelection.success).toBe(true);
	});

	test('accepts policy-only session bootstrap and rejects every legacy runtime carrier', () => {
		// Arrange
		const policyOnlyBootstrap = {
			schemaVersion: BRIDGE_WORKER_WIRE_VERSION,
			method: 'bridgeCommWorker.bootstrap',
			requestId: 'policy-only-bootstrap',
			runtime: {
				bridgeDemandRank: { lane: 'selected', priority: 0 },
				budget: {
					className: 'interactive',
					maxBytes: 512 * 1024,
					maxWindowLines: 400,
				},
			},
		};

		// Act
		const parsedBootstrap = bridgeCommWorkerBootstrapRequestSchema.safeParse(policyOnlyBootstrap);

		// Assert
		expect(parsedBootstrap.success).toBe(true);
		if (!parsedBootstrap.success) return;
		expect(parsedBootstrap.data).toEqual(policyOnlyBootstrap);
		for (const legacyRuntimeField of [
			'contentItems',
			'contentRequestDescriptors',
			'renderSemantics',
			'rows',
		] as const) {
			expect(
				bridgeCommWorkerBootstrapRequestSchema.safeParse({
					...policyOnlyBootstrap,
					runtime: {
						...policyOnlyBootstrap.runtime,
						[legacyRuntimeField]: [],
					},
				}).success,
				`expected strict bootstrap rejection for legacy runtime.${legacyRuntimeField}`,
			).toBe(false);
		}
	});

	test('rejects main-seeded Review source payloads from the worker command boundary', () => {
		// Arrange
		const mainSeededReviewSourceUpdate = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'mainToServerWorker',
			kind: 'command',
			command: 'reviewSourceUpdate',
			requestId: 'request-main-seeded-review-source',
			epoch: 3,
			transferDescriptors: [],
			contentItems: [],
			contentRequestDescriptors: [],
			renderSemantics: [],
			rows: [],
		};

		// Act
		const parsedMainSeededReviewSourceUpdate = bridgeWorkerMainToServerMessageSchema.safeParse(
			mainSeededReviewSourceUpdate,
		);

		// Assert
		expect(
			parsedMainSeededReviewSourceUpdate.success,
			'MAIN_SEEDED_REVIEW_SOURCE_UPDATE_ACCEPTED',
		).toBe(false);
		type ReviewSourceUpdateCommand = Extract<
			BridgeWorkerMainToServerMessage,
			{ readonly command: 'reviewSourceUpdate' }
		>;
		expectTypeOf<ReviewSourceUpdateCommand>().toEqualTypeOf<never>();
	});

	test('accepts strict Review projection intent and rejects extra projection authority', () => {
		// Arrange
		const reviewProjectionUpdate = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'mainToServerWorker',
			kind: 'command',
			command: 'reviewProjectionUpdate',
			requestId: 'request-review-projection',
			epoch: 8,
			transferDescriptors: [],
			query: {
				categoryFilter: 'source',
				gitStatusFilter: 'added',
				showBinary: false,
				showLarge: false,
			},
		};

		// Act
		const parsedReviewProjectionUpdate =
			bridgeWorkerMainToServerMessageSchema.safeParse(reviewProjectionUpdate);
		const parsedReviewProjectionUpdateWithExtra = bridgeWorkerMainToServerMessageSchema.safeParse({
			...reviewProjectionUpdate,
			query: {
				...reviewProjectionUpdate.query,
				orderedItemIds: ['main-owned-item'],
			},
		});

		// Assert
		expect(parsedReviewProjectionUpdate.success).toBe(true);
		expect(parsedReviewProjectionUpdateWithExtra.success).toBe(false);
	});

	test('rejects untyped main to server worker messages at schema boundary', () => {
		const selectCommand = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'mainToServerWorker',
			kind: 'command',
			command: 'select',
			requestId: 'request-select',
			epoch: 3,
			transferDescriptors: [],
			surface: 'review',
			selectedItemId: 'item-1',
			selectedSource: 'user',
		} satisfies BridgeWorkerMainToServerMessage;

		expect(parseBridgeWorkerMainToServerMessage(selectCommand)).toEqual(selectCommand);
		expect(bridgeWorkerMainToServerMessageSchema.safeParse(selectCommand).success).toBe(true);
		expect(
			bridgeWorkerMainToServerMessageSchema.safeParse({
				...selectCommand,
				surface: undefined,
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerMainToServerMessageSchema.safeParse({
				...selectCommand,
				surface: 'all',
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerMainToServerMessageSchema.safeParse({
				...selectCommand,
				wireVersion: BRIDGE_WORKER_WIRE_VERSION + 1,
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerMainToServerMessageSchema.safeParse({
				wireVersion: BRIDGE_WORKER_WIRE_VERSION,
				direction: 'mainToServerWorker',
				kind: 'command',
				command: 'startFetch',
				requestId: 'request-fetch',
				epoch: 3,
				transferDescriptors: [],
			}).success,
		).toBe(false);

		const healthEvent = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'health',
			requestId: 'request-select',
			status: 'ready',
		};
		expect(bridgeWorkerServerToMainMessageSchema.safeParse(healthEvent).success).toBe(true);
		expect(
			bridgeWorkerServerToMainMessageSchema.safeParse({
				...healthEvent,
				status: 'degraded',
				diagnostic: {
					kind: 'productMetadataStream',
					lastSubscriptionTermination: null,
					routeFailureSubscriptionId: null,
					activeSubscriptionCount: 1,
					committedFrameCount: 1,
					decoderState: 'poisoned',
					expectedNextStreamSequence: 1,
					failureStage: 'decode',
					failureCode: 'stream_identity_mismatch',
					identityMismatchField: 'metadataStreamId',
					lastChunkByteCount: 128,
					lastCommittedFrameKind: 'metadataStream.accepted',
					lastRoutedFrameKind: 'metadataStream.accepted',
					lifecycleState: 'failed',
					peakRetainedByteCount: 512,
					pushCount: 2,
					readFulfilledCount: 2,
					readPending: false,
					readRequestCount: 2,
					receivedByteCount: 256,
					retainedByteCount: 0,
					routeFailureCode: null,
					routedFrameCount: 1,
					streamOpenCount: 1,
				},
			}).success,
		).toBe(true);

		const invalidCommand: BridgeWorkerMainToServerMessage = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'mainToServerWorker',
			kind: 'command',
			// @ts-expect-error Unknown command shapes must be rejected before runtime.
			command: 'startFetch',
			requestId: 'request-fetch',
			epoch: 3,
			transferDescriptors: [],
		};
		expectTypeOf(invalidCommand).toMatchTypeOf<BridgeWorkerMainToServerMessage>();
	});

	test('accepts only a closed identity-bound render disposition command', () => {
		// Arrange
		const renderDispositionCommand = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'mainToServerWorker',
			kind: 'command',
			command: 'renderDisposition',
			requestId: 'request-render-disposition',
			epoch: 4,
			transferDescriptors: [],
			receipts: [
				{
					kind: 'render.disposition',
					disposition: 'painted',
					receivedAtMilliseconds: 125,
					attemptId: 'render-attempt-review-4-11',
					itemId: 'item-11',
					operationCorrelationId: null,
					paneSessionId: 'pane-session-1',
					publicationId: 'render-publication-review-4-11',
					publicationSequence: 11,
					submissionId: 'render-submission-review-4-11',
					surface: 'review',
					windowKey: 'review-cache-key-11',
					workerDerivationEpoch: 4,
					workerInstanceId: 'worker-instance-1',
				},
			],
		};

		// Act
		const parsedCommand = bridgeWorkerMainToServerMessageSchema.safeParse(renderDispositionCommand);

		// Assert
		expect(parsedCommand.success, 'RENDER_DISPOSITION_COMMAND_UNREACHABLE').toBe(true);
		for (const requiredIdentityField of [
			'attemptId',
			'itemId',
			'operationCorrelationId',
			'paneSessionId',
			'publicationId',
			'publicationSequence',
			'submissionId',
			'surface',
			'windowKey',
			'workerDerivationEpoch',
			'workerInstanceId',
		] as const) {
			const receiptWithoutIdentityField = { ...renderDispositionCommand.receipts[0] };
			Reflect.deleteProperty(receiptWithoutIdentityField, requiredIdentityField);
			expect(
				bridgeWorkerMainToServerMessageSchema.safeParse({
					...renderDispositionCommand,
					receipts: [receiptWithoutIdentityField],
				}).success,
				`expected ${requiredIdentityField} to be required`,
			).toBe(false);
		}
		expect(
			bridgeWorkerMainToServerMessageSchema.safeParse({
				...renderDispositionCommand,
				receipts: [{ ...renderDispositionCommand.receipts[0], undeclaredIdentity: true }],
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerMainToServerMessageSchema.safeParse({
				...renderDispositionCommand,
				receipts: [],
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerMainToServerMessageSchema.safeParse({
				...renderDispositionCommand,
				receipt: renderDispositionCommand.receipts[0],
				receipts: undefined,
			}).success,
		).toBe(false);
	});

	test('requires complete receipt identity on Pierre publications and rejects cross-field drift', () => {
		const job = buildBridgeWorkerPierreRenderJob({
			bridgeDemandRank: { lane: 'visible', priority: 1 },
			budget: { className: 'visible', maxBytes: 1024, maxWindowLines: 4 },
			contentCacheKey: 'cache-item-11',
			contentHash: 'a'.repeat(64),
			itemId: 'item-11',
			language: 'text',
			payload: {
				kind: 'codeViewFileItem',
				item: {
					bridgeMetadata: {
						cacheKey: 'cache-item-11',
						contentRoles: ['file'],
						contentState: 'hydrated',
						displayPath: 'item-11.txt',
						itemId: 'item-11',
						lineCount: 1,
					},
					file: { cacheKey: 'cache-item-11', contents: 'content', name: 'item-11.txt' },
					id: 'item-11',
					type: 'file',
				},
			},
			renderKind: 'fileText',
			window: { endLine: 1, startLine: 1, totalLineCount: 1 },
		});
		const receiptIdentity = {
			attemptId: 'render-attempt-review-4-11',
			itemId: 'item-11',
			operationCorrelationId: null,
			paneSessionId: 'pane-session-1',
			publicationId: 'render-publication-review-4-11',
			publicationSequence: 11,
			submissionId: 'render-submission-review-4-11',
			surface: 'review',
			windowKey: 'review-window-11',
			workerDerivationEpoch: 4,
			workerInstanceId: 'worker-instance-1',
		} as const;
		const publication = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'reviewPierreRenderJob',
			job,
			publicationSequence: 11,
			renderReceiptIdentity: receiptIdentity,
			reviewPublicationIdentity: {
				packageId: 'review-package-11',
				publicationId: '00000000-0000-7000-8000-000000000011',
				reviewGeneration: 4,
				revision: 11,
				sourceIdentity: 'review-source-11',
			},
			surface: 'review',
			workerDerivationEpoch: 4,
		};

		expect(
			bridgeWorkerServerToMainMessageSchema.safeParse(publication).success,
			'RENDER_PUBLICATION_RECEIPT_IDENTITY_UNREACHABLE',
		).toBe(true);
		expect(
			bridgeWorkerServerToMainMessageSchema.safeParse({
				...publication,
				renderReceiptIdentity: undefined,
			}).success,
		).toBe(false);
		for (const renderReceiptIdentity of [
			{ ...receiptIdentity, itemId: 'item-foreign' },
			{ ...receiptIdentity, publicationSequence: 12 },
			{ ...receiptIdentity, surface: 'file' },
			{ ...receiptIdentity, workerDerivationEpoch: 5 },
		] as const) {
			expect(
				bridgeWorkerServerToMainMessageSchema.safeParse({
					...publication,
					renderReceiptIdentity,
				}).success,
			).toBe(false);
		}
	});

	test('requires every worker message to declare transfer descriptors explicitly', () => {
		const selectCommand = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'mainToServerWorker',
			kind: 'command',
			command: 'select',
			requestId: 'request-select',
			epoch: 1,
			transferDescriptors: [],
			surface: 'fileView',
			selectedItemId: 'item-1',
			selectedSource: 'user',
		};
		const slicePatchEvent = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'slicePatch',
			epoch: 1,
			sequence: 2,
			patches: [
				{
					slice: 'rowPaint',
					operation: 'upsert',
					itemId: 'item-1',
					payload: { label: 'README.md' },
				},
			],
		};

		expect(bridgeWorkerMainToServerMessageSchema.parse(selectCommand)).toEqual(selectCommand);
		expect(bridgeWorkerSlicePatchEventSchema.parse(slicePatchEvent)).toEqual(slicePatchEvent);
		expect(
			bridgeWorkerMainToServerMessageSchema.safeParse({
				...selectCommand,
				transferDescriptors: undefined,
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerSlicePatchEventSchema.safeParse({
				...slicePatchEvent,
				transferDescriptors: undefined,
			}).success,
		).toBe(false);
	});

	test('rejects boundary-visible unknown slice patch payloads', () => {
		const slicePatchEvent = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'slicePatch',
			epoch: 1,
			sequence: 2,
			patches: [
				{
					slice: 'rowPaint',
					operation: 'upsert',
					itemId: 'item-1',
					payload: {
						metadata: {
							nestedUnknownRecord: true,
						},
					},
				},
			],
		};

		expect(bridgeWorkerSlicePatchEventSchema.safeParse(slicePatchEvent).success).toBe(false);
	});

	test('defines strict worker review content metadata without package snapshots', () => {
		const item = makeBridgeReviewItem({
			itemId: 'item-worker-metadata',
			path: 'Sources/App/WorkerMetadata.swift',
		});
		const metadata = {
			itemId: item.itemId,
			path: item.headPath ?? item.basePath ?? item.itemId,
			language: item.language ?? null,
			cacheKey: item.cacheKey,
			sizeBytes: item.sizeBytes,
			availableContentRoles: ['base', 'head'],
			contentLineCountsByRole: item.contentLineCountsByRole ?? {},
		} satisfies BridgeWorkerReviewContentMetadata;

		expect(bridgeWorkerReviewContentMetadataSchema.parse(metadata)).toEqual(metadata);
		expect(JSON.stringify(metadata)).not.toMatch(/"contentRoles"|resourceUrl|endpointId/i);
		expect(
			bridgeWorkerReviewContentMetadataSchema.safeParse({
				...metadata,
				itemsById: {},
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerReviewContentMetadataSchema.safeParse({
				...metadata,
				contentRoles: item.contentRoles,
			}).success,
		).toBe(false);
	});

	test('defines strict worker review content request descriptors separate from metadata', () => {
		const item = makeBridgeReviewItem({
			itemId: 'item-worker-content-request',
			path: 'Sources/App/WorkerContentRequest.swift',
		});
		const descriptor = makeContentRequestDescriptor({
			itemId: item.itemId,
			role: 'head',
			text: 'let workerContent = true;\n',
		});

		expect(bridgeWorkerReviewContentRequestDescriptorSchema.parse(descriptor)).toEqual(descriptor);
		expect(JSON.stringify(descriptor)).not.toMatch(
			/"contentRoles"|itemsById|"cacheKey"|resourceUrl/i,
		);
		expect(descriptor.contentKind).toBe('review.content');
		expect(descriptor.descriptorId).toContain(item.itemId);
		const inexactDescriptor = {
			...descriptor,
			declaredByteLength: null,
			maximumBytes: 64,
			wholeByteLength: null,
			window: { ...descriptor.window, maximumBytes: 64 },
		} satisfies BridgeWorkerReviewContentRequestDescriptor;
		expect(bridgeWorkerReviewContentRequestDescriptorSchema.parse(inexactDescriptor)).toEqual(
			inexactDescriptor,
		);
		expect(
			bridgeWorkerReviewContentRequestDescriptorSchema.safeParse({
				...descriptor,
				resourceUrl: 'agentstudio://resource/review/content/legacy',
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerReviewContentRequestDescriptorSchema.safeParse({
				...descriptor,
				maximumBytes: 0,
				window: { ...descriptor.window, maximumBytes: 0 },
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerReviewContentRequestDescriptorSchema.safeParse({
				...descriptor,
				window: { ...descriptor.window, maximumBytes: descriptor.maximumBytes + 1 },
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerReviewContentRequestDescriptorSchema.safeParse({
				...descriptor,
				declaredByteLength: descriptor.maximumBytes + 1,
			}).success,
		).toBe(false);
	});

	test('defines strict worker review render semantics without content handles', () => {
		const item = makeBridgeReviewItem({
			itemId: 'item-render-semantics',
			path: 'Sources/App/RenderSemantics.swift',
		});
		const semantics = {
			itemId: item.itemId,
			itemKind: item.itemKind,
			changeKind: item.changeKind,
			displayPath: item.headPath ?? item.basePath ?? item.itemId,
			basePath: item.basePath ?? null,
			headPath: item.headPath ?? null,
			language: item.language ?? null,
			contentLineCountsByRole: item.contentLineCountsByRole ?? {},
		} satisfies BridgeWorkerReviewRenderSemantics;

		expect(bridgeWorkerReviewRenderSemanticsSchema.parse(semantics)).toEqual(semantics);
		expect(JSON.stringify(semantics)).not.toMatch(
			/"contentRoles"|resourceUrl|handleId|contentHash|endpointId/i,
		);
		expect(
			bridgeWorkerReviewRenderSemanticsSchema.safeParse({
				...semantics,
				contentRoles: item.contentRoles,
			}).success,
		).toBe(false);
	});

	test('defines strict worker File View prefix metadata without resource carriers', () => {
		const metadata = {
			metadataKind: 'fileView',
			itemId: 'file-1',
			path: 'Sources/App/FileView.swift',
			language: 'swift',
			cacheKey: 'file-view:sha256:file-1',
			sizeBytes: 128,
			descriptorId: 'descriptor-file-1',
			contentHash: 'sha256:file-1',
			encoding: 'utf-8',
			endsMidLine: false,
			endsWithNewline: true,
			virtualizedExtentKind: 'exactLineCount',
			payloadByteCount: 128,
			payloadLineCount: 7,
			totalLineCount: 7,
			truncationKind: 'none',
			isBinary: false,
			canFetchContent: true,
		} satisfies BridgeWorkerFileViewContentMetadata;

		expect(bridgeWorkerFileViewContentMetadataSchema.parse(metadata)).toEqual(metadata);
		expect(JSON.stringify(metadata)).not.toMatch(
			/contentHandle|resourceUrl|worktree\.fileContent|contents|text|body/i,
		);
		for (const invalidMetadata of [
			{ ...metadata, contentHandle: 'legacy-handle' },
			{ ...metadata, lineCount: 7 },
			{ ...metadata, resourceUrl: 'agentstudio://resource/legacy' },
		]) {
			expect(bridgeWorkerFileViewContentMetadataSchema.safeParse(invalidMetadata).success).toBe(
				false,
			);
		}
	});
});

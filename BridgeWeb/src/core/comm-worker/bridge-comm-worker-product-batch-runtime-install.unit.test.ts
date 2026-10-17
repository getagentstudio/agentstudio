import { describe, expect, test } from 'vitest';

import { createBridgeCommWorkerCommandHandler } from './bridge-comm-worker-command-handler.js';
import { BridgeCommWorkerFileDisplayEventAuthority } from './bridge-comm-worker-file-display-event-authority.js';
import { BridgeCommWorkerFileQueryProjection } from './bridge-comm-worker-file-query-projection.js';
import { installBridgeCommWorkerProductBatchRuntime } from './bridge-comm-worker-product-batch-runtime-install.js';
import { encodeBridgeWorkerSelectCommand } from './bridge-comm-worker-protocol.js';
import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';
import {
	makeReviewTestBatch,
	createReviewBatchSinkCapture,
	makeIdleReviewMetadataSubscription,
	makeReviewProductTransport,
} from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import type { BridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';

const subscriptionId = 'review-batch-runtime-install-failure';
const activePublicationId = '00000000-0000-7000-8000-000000000011';
const failedPublicationId = '00000000-0000-7000-8000-000000000012';

describe('Bridge comm worker product batch runtime Review transaction', () => {
	test('restores the real Review store when runtime application fails after applying B', async () => {
		let appliedPublicationIdAtFailure: string | null = null;
		const harness = createRuntimeInstallHarness({
			failRuntimeApplicationPublicationId: failedPublicationId,
			onRuntimeApplicationFailure: (store): void => {
				appliedPublicationIdAtFailure = failedPublicationId;
				expect(store.getState().contentMetadataByItemId.get('item-1')?.path).toBe(
					'Sources/B.swift',
				);
			},
		});
		await harness.batchCapture.install(
			reviewBatch({ publicationId: activePublicationId, itemPath: 'Sources/A.swift' }),
		);

		const reviewStore = requireReviewStore(harness.reviewStore());
		expect(reviewStore.getState().contentMetadataByItemId.get('item-1')?.path).toBe(
			'Sources/A.swift',
		);
		await expect(
			harness.batchCapture.install(
				reviewBatch({
					generation: 8,
					itemPath: 'Sources/B.swift',
					packageId: 'package-2',
					publicationId: failedPublicationId,
					sourceIdentity: 'source-2',
				}),
			),
		).rejects.toThrow('Injected Review runtime application failure.');

		expect(appliedPublicationIdAtFailure).toBe(failedPublicationId);
		expect(harness.currentRuntimePublicationId()).toBe(activePublicationId);
		expect(reviewStore.getState().contentMetadataByItemId.get('item-1')?.path).toBe(
			'Sources/A.swift',
		);
		expect([...reviewStore.getState().rowById.keys()]).toContain('item-1');
		expect(harness.messages()).toContainEqual(
			expect.objectContaining({
				kind: 'reviewCandidateFailed',
				publicationId: failedPublicationId,
			}),
		);
	});

	test('restores the real Review store when W4 display publication fails after applying B', async () => {
		let appliedPublicationIdAtFailure: string | null = null;
		const harness = createRuntimeInstallHarness({
			failDisplayPublicationId: failedPublicationId,
			onReviewDisplayPublication: (source, store): void => {
				if (source?.reviewPublicationIdentity?.publicationId !== failedPublicationId) return;
				appliedPublicationIdAtFailure = source.reviewPublicationIdentity.publicationId;
				expect(store?.getState().contentMetadataByItemId.get('item-1')?.path).toBe(
					'Sources/B.swift',
				);
			},
		});
		await harness.batchCapture.install(
			reviewBatch({ publicationId: activePublicationId, itemPath: 'Sources/A.swift' }),
		);

		const reviewStore = requireReviewStore(harness.reviewStore());
		expect(reviewStore.getState().contentMetadataByItemId.get('item-1')?.path).toBe(
			'Sources/A.swift',
		);
		await expect(
			harness.batchCapture.install(
				reviewBatch({
					generation: 8,
					itemPath: 'Sources/B.swift',
					packageId: 'package-2',
					publicationId: failedPublicationId,
					sourceIdentity: 'source-2',
				}),
			),
		).rejects.toThrow('Injected Review display publication failure.');

		expect(appliedPublicationIdAtFailure).toBe(failedPublicationId);
		expect(harness.currentRuntimePublicationId()).toBe(activePublicationId);
		expect(reviewStore.getState().contentMetadataByItemId.get('item-1')?.path).toBe(
			'Sources/A.swift',
		);
		expect([...reviewStore.getState().rowById.keys()]).toContain('item-1');
		expect(harness.messages()).toContainEqual(
			expect.objectContaining({
				kind: 'reviewCandidateFailed',
				publicationId: failedPublicationId,
			}),
		);
	});

	test('keeps a committed Review bank when one post-commit drain fails and the next proceeds', async () => {
		let recordPostCommitProgress = false;
		const postCommitOrder: string[] = [];
		const reportedPostCommitFailures: unknown[] = [];
		const harness = createRuntimeInstallHarness({
			onPostCommitFailure: (error): void => {
				reportedPostCommitFailures.push(error);
			},
			onSelectedPreparation: (store): void => {
				if (!recordPostCommitProgress) return;
				postCommitOrder.push('selectedPreparation');
				expect(store.getState().contentMetadataByItemId.get('item-1')?.path).toBe(
					'Sources/B.swift',
				);
				throw new Error('Injected Review selected preparation drain failure.');
			},
			onDemandExecution: (store): void => {
				if (!recordPostCommitProgress) return;
				postCommitOrder.push('demandExecution');
				expect(store.getState().contentMetadataByItemId.get('item-1')?.path).toBe(
					'Sources/B.swift',
				);
			},
			onDidInstallReview: (publicationId): void => {
				if (recordPostCommitProgress && publicationId === failedPublicationId) {
					postCommitOrder.push('didInstallReview');
				}
			},
		});
		await harness.batchCapture.install(
			reviewBatch({
				itemPath: 'Sources/A.swift',
				publicationId: activePublicationId,
				withContent: true,
			}),
		);
		harness.selectReviewItem('item-1');
		recordPostCommitProgress = true;

		await harness.batchCapture.install(
			reviewBatch({
				generation: 8,
				itemPath: 'Sources/B.swift',
				publicationId: failedPublicationId,
				packageId: 'package-2',
				sourceIdentity: 'source-2',
				withContent: true,
			}),
		);

		const reviewStore = requireReviewStore(harness.reviewStore());
		expect(postCommitOrder).toEqual(['selectedPreparation', 'demandExecution', 'didInstallReview']);
		expect(reportedPostCommitFailures).toHaveLength(1);
		expect(reportedPostCommitFailures[0]).toMatchObject({
			message: 'Injected Review selected preparation drain failure.',
		});
		expect(harness.currentRuntimePublicationId()).toBe(failedPublicationId);
		expect(reviewStore.getState().contentMetadataByItemId.get('item-1')?.path).toBe(
			'Sources/B.swift',
		);
		expect(harness.messages()).toContainEqual(
			expect.objectContaining({
				kind: 'reviewCandidateReady',
				publicationId: failedPublicationId,
			}),
		);
	});
});

interface RuntimeInstallHarnessProps {
	readonly failRuntimeApplicationPublicationId?: string;
	readonly failDisplayPublicationId?: string;
	readonly onRuntimeSourceUpdate?: (
		source: BridgeCommWorkerReviewRuntimeSource,
		store: BridgeCommWorkerStore | null,
	) => void;
	readonly onRuntimeApplicationFailure?: (store: BridgeCommWorkerStore) => void;
	readonly onReviewDisplayPublication?: (
		source: BridgeCommWorkerReviewRuntimeSource | null,
		store: BridgeCommWorkerStore | null,
	) => void;
	readonly onSelectedPreparation?: (store: BridgeCommWorkerStore) => void;
	readonly onDemandExecution?: (store: BridgeCommWorkerStore) => void;
	readonly onPostCommitFailure?: (error: unknown) => void;
	readonly onDidInstallReview?: (publicationId: string | null) => void;
}

function createRuntimeInstallHarness(props: RuntimeInstallHarnessProps = {}): {
	readonly batchCapture: ReturnType<typeof createReviewBatchSinkCapture>;
	readonly commandHandler: ReturnType<typeof createBridgeCommWorkerCommandHandler>;
	readonly currentRuntimePublicationId: () => string | null;
	readonly messages: () => readonly BridgeWorkerServerToMainMessage[];
	readonly reviewStore: () => BridgeCommWorkerStore | null;
	readonly selectReviewItem: (itemId: string) => void;
} {
	const batchCapture = createReviewBatchSinkCapture();
	const messages: BridgeWorkerServerToMainMessage[] = [];
	let reviewStore: BridgeCommWorkerStore | null = null;
	let runtimeSource: BridgeCommWorkerReviewRuntimeSource | null = null;
	const reviewSubscription = makeIdleReviewMetadataSubscription(subscriptionId);
	const productTransport = makeReviewProductTransport({
		onBatchFrameSinks: batchCapture.onBatchFrameSinks,
		reviewSubscription,
		subscribedKinds: [],
	});
	const commandHandler = createBridgeCommWorkerCommandHandler({
		contentItems: [],
		createSequence: (): number => {
			if (
				runtimeSource?.reviewPublicationIdentity?.publicationId ===
				props.failRuntimeApplicationPublicationId
			) {
				const store = requireReviewStore(reviewStore);
				props.onRuntimeApplicationFailure?.(store);
				throw new Error('Injected Review runtime application failure.');
			}
			return 1;
		},
		rows: [],
		onReviewMetadataPostCommitFailure: (error): void => props.onPostCommitFailure?.(error),
		scheduleDemandExecution: ({ store }): void => {
			reviewStore = store;
			props.onDemandExecution?.(store);
		},
		scheduleSelectedReviewContentReadyPreparation: ({ store }): void => {
			reviewStore = store;
			props.onSelectedPreparation?.(store);
		},
		scheduleSelectedFileViewContentReadyPreparation: (): void => {},
		updateReviewRuntimeSource: (source): void => {
			runtimeSource = source;
			props.onRuntimeSourceUpdate?.(source, reviewStore);
		},
	});
	installBridgeCommWorkerProductBatchRuntime({
		applyCommentCatalog: (): void => {},
		applyFileRuntimeMutation: (): readonly BridgeWorkerServerToMainMessage[] => [],
		prepareReviewRuntimeApplication: (application) =>
			commandHandler.prepareReviewMetadataApplication(application),
		beforeApplyFile: (): void => {},
		createSequence: (): number => 1,
		didInstallFile: (): void => {},
		didInstallReview: (presentation): void => {
			props.onDidInstallReview?.(presentation.publication.displayed?.publicationId ?? null);
		},
		fileDisplayAuthority: new BridgeCommWorkerFileDisplayEventAuthority({
			createSequence: (): number => 1,
		}),
		fileQueryProjection: new BridgeCommWorkerFileQueryProjection(),
		productTransport,
		publishMessage: (message): void => {
			messages.push(message);
		},
		publishReviewDisplay: ({ reviewPublicationIdentity }): void => {
			props.onReviewDisplayPublication?.(runtimeSource, reviewStore);
			if (reviewPublicationIdentity?.publicationId === props.failDisplayPublicationId) {
				throw new Error('Injected Review display publication failure.');
			}
		},
		reportResnapshotFailure: (): void => {},
		reportReviewPostCommitFailure: (): void => {},
	});
	return {
		batchCapture,
		commandHandler,
		currentRuntimePublicationId: (): string | null =>
			runtimeSource?.reviewPublicationIdentity?.publicationId ?? null,
		messages: (): readonly BridgeWorkerServerToMainMessage[] => messages,
		reviewStore: (): BridgeCommWorkerStore | null => reviewStore,
		selectReviewItem: (itemId): void => {
			commandHandler.handleMessage(
				encodeBridgeWorkerSelectCommand({
					epoch: 1,
					requestId: 'review-batch-runtime-install-select',
					selectedItemId: itemId,
					selectedSource: 'user',
					surface: 'review',
				}),
			);
		},
	};
}

function reviewBatch(props: {
	readonly publicationId: string;
	readonly generation?: number;
	readonly packageId?: string;
	readonly sourceIdentity?: string;
	readonly itemId?: string;
	readonly itemPath: string;
	readonly withContent?: boolean;
}): ReturnType<typeof makeReviewTestBatch> {
	const itemId = props.itemId ?? 'item-1';
	const installation = makeReviewTestBatch({
		snapshotCause: 'open',
		...(props.generation === undefined ? {} : { generation: props.generation }),
		itemId,
		itemCount: 1,
		...(props.packageId === undefined ? {} : { packageId: props.packageId }),
		publicationId: props.publicationId,
		revision: (props.generation ?? 7) + 4,
		...(props.sourceIdentity === undefined ? {} : { sourceIdentity: props.sourceIdentity }),
		subscriptionId,
		...(props.withContent === undefined ? {} : { withContent: props.withContent }),
	});
	return {
		...installation,
		records: installation.records.map((record) => {
			if (record.key !== itemId) return record;
			const value = bridgeProductReviewBatchRecordSchema.parse(record.value);
			if (value.recordKind !== 'item') throw new Error('Review item fixture is missing.');
			return {
				...record,
				value: bridgeProductReviewBatchRecordSchema.parse({
					...value,
					basePath: props.itemPath,
					headPath: props.itemPath,
					parentPath: 'Sources',
				}),
			};
		}),
	};
}

function requireReviewStore(store: BridgeCommWorkerStore | null): BridgeCommWorkerStore {
	if (store === null) throw new Error('Expected the real Review worker store.');
	return store;
}

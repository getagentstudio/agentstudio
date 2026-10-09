import { uuidv7 } from 'uuidv7';
import { describe, expect, test } from 'vitest';

import reviewCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import {
	encodeBridgeWorkerActiveViewerModeUpdateCommand,
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES } from './bridge-product-contract-primitives.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import type {
	BridgeWorkerReviewDisplayPatchEvent,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import { WindowedReviewWorkerHarness } from './test-fixtures/comm-runtime-protocol.review-windowed-publication.worker-harness.browser.test-support.js';
import type {
	WindowedReviewBatchPart,
	WindowedReviewViewScopeRequest,
} from './test-fixtures/comm-runtime-protocol.review-windowed-publication.worker-test-fixture.js';

const reviewItemCount = 1_699;
const recordPartSize = 32;
const reviewIdentity = {
	generation: 1,
	packageId: 'review-windowed-runtime-package',
	publicationId: '00000000-0000-7000-8000-000000001699',
	revision: 1,
	sourceIdentity: 'review-windowed-runtime-source',
} as const;

describe('Bridge comm worker windowed Review publication runtime', () => {
	test('publishes one complete 1,699-item Review view after bounded certified parts', async () => {
		const harness = new WindowedReviewWorkerHarness();
		const viewScopes: WindowedReviewViewScopeRequest[] = [];
		let resolveSelectedScope: ((request: WindowedReviewViewScopeRequest) => void) | null = null;
		const selectedScope = new Promise<WindowedReviewViewScopeRequest>((resolve): void => {
			resolveSelectedScope = resolve;
		});
		harness.onViewScope = (request): void => {
			viewScopes.push(request);
			if (
				request.scope.kind === 'review' &&
				request.scope.interests.some((interest) => interest.lane === 'foreground')
			)
				resolveSelectedScope?.(request);
		};
		try {
			await harness.installed;
			harness.worker.postMessage(activeReviewModeCommand('windowed-review-mode-initial', 1));
			await harness.waitForMessage(
				(message) =>
					message.kind === 'health' && message.requestId === 'windowed-review-mode-initial',
			);

			const installation = windowedReviewInstallation('open');
			const parts = boundedReviewParts(installation);
			expect(parts).toHaveLength(Math.ceil(installation.records.length / recordPartSize));
			for (const part of parts) {
				expect(part.records.length).toBeLessThanOrEqual(recordPartSize);
				expect(new TextEncoder().encode(JSON.stringify(part)).byteLength).toBeLessThanOrEqual(
					BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES - 4_096,
				);
			}
			for (const part of parts.slice(0, -1)) harness.publishBatchPart(part);
			const previousPart = parts.at(-2);
			if (previousPart === undefined) throw new Error('Expected multiple Review batch parts.');
			await harness.waitUntilPartProcessed(previousPart.partIndex);
			harness.worker.postMessage(activeReviewModeCommand('windowed-review-mode-barrier', 2));
			await harness.waitForMessage(
				(message) =>
					message.kind === 'health' && message.requestId === 'windowed-review-mode-barrier',
			);

			// A bounded prefix cannot become a partial visible publication.
			expect(messagesOfKind(harness.observedMessages, 'reviewDisplayPatch')).toEqual([]);
			expect(messagesOfKind(harness.observedMessages, 'reviewCandidateFailed')).toEqual([]);

			const finalPart = parts.at(-1);
			if (finalPart === undefined) throw new Error('Expected final Review batch part.');
			harness.publishBatchPart(finalPart);
			await harness.waitForMessage((message) => message.kind === 'reviewDisplayPatch');
			await harness.waitUntilPartProcessed(finalPart.partIndex);

			const displayMessages = messagesOfKind(harness.observedMessages, 'reviewDisplayPatch');
			expect(displayMessages).toHaveLength(1);
			expect(messagesOfKind(harness.observedMessages, 'reviewCandidateFailed')).toEqual([]);
			expect(
				harness.observedMessages.filter(
					(message) => message.kind === 'health' && message.status === 'degraded',
				),
			).toEqual([]);
			assertCompleteDisplayPublication(displayMessages[0]);

			const firstItemId = `item-git-diff-${sha256Fixture(0)}`;
			harness.worker.postMessage(
				encodeBridgeWorkerSelectCommand({
					epoch: 3,
					requestId: 'windowed-review-selected-scope',
					selectedItemId: firstItemId,
					selectedSource: 'user',
					surface: 'review',
				}),
			);
			harness.worker.postMessage(
				encodeBridgeWorkerViewportCommand({
					epoch: 4,
					firstVisibleIndex: 0,
					lastVisibleIndex: 8,
					phase: 'settled',
					requestId: 'windowed-review-visible-scope',
					surface: 'review',
					visibleItemIds: Array.from(
						{ length: 9 },
						(_, index) => `item-git-diff-${sha256Fixture(index)}`,
					),
				}),
			);
			const selectedRequest = await selectedScope;
			if (selectedRequest.scope.kind !== 'review') throw new Error('Expected Review view scope.');
			expect(
				selectedRequest.scope.interests.find((interest) => interest.lane === 'foreground'),
			).toMatchObject({ itemIds: [firstItemId] });
			expect(viewScopes).toContain(selectedRequest);
		} finally {
			harness.terminate();
		}
	});
});

function activeReviewModeCommand(
	requestId: string,
	sequence: number,
): ReturnType<typeof encodeBridgeWorkerActiveViewerModeUpdateCommand> {
	return encodeBridgeWorkerActiveViewerModeUpdateCommand({
		epoch: sequence,
		requestId,
		update: {
			activeSource: null,
			mode: 'review',
			nativeSelectionRequestId: null,
			sequence,
			sessionId: 'windowed-review-runtime-session',
		},
	});
}

function windowedReviewInstallation(
	snapshotCause: import('./bridge-product-batch-wire-contracts.js').BridgeProductSnapshotCause,
): BridgeProductViewInstallation {
	const itemFixture = bridgeProductReviewBatchRecordSchema.parse(reviewCorpus.records[0]?.record);
	const publicationFixture = bridgeProductReviewBatchRecordSchema.parse(
		reviewCorpus.records[2]?.record,
	);
	if (
		itemFixture.recordKind !== 'item' ||
		publicationFixture.recordKind !== 'publication' ||
		publicationFixture.displayed === null
	)
		throw new Error('Review record corpus is incomplete.');
	const headFixture = itemFixture.contentByRole.head;
	if (headFixture.state !== 'available')
		throw new Error('Review record corpus lacks head content.');
	const records = Array.from({ length: reviewItemCount }, (_unused, itemIndex) => {
		const groupName = `group-${String(Math.floor(itemIndex / 6) + 1).padStart(2, '0')}`;
		const path = `nested/${groupName}/file-${String(itemIndex + 1).padStart(2, '0')}.ts`;
		const itemId = `item-git-diff-${sha256Fixture(itemIndex)}`;
		const contentForRole = (
			role: 'base' | 'head',
		): {
			readonly state: 'available';
			readonly source: typeof headFixture.source;
		} => ({
			state: 'available',
			source: {
				...headFixture.source,
				contentDigest: {
					algorithm: 'sha256',
					authority: 'authoritative',
					value: sha256Fixture(itemIndex * 2 + (role === 'head' ? 1 : 0)),
				},
				descriptorId: `descriptor-${itemIndex}-${role}`,
				endpointId: role,
				handleId: `handle-${itemIndex}-${role}`,
				itemId,
				mimeType: 'text/typescript',
				packageId: reviewIdentity.packageId,
				reviewGeneration: reviewIdentity.generation,
				role,
				sourceIdentity: reviewIdentity.sourceIdentity,
				wholeByteLength: 154,
			},
		});
		const item = bridgeProductReviewBatchRecordSchema.parse({
			...itemFixture,
			additions: 1,
			basePath: path,
			changeKind: 'modified',
			contentByRole: {
				base: contentForRole('base'),
				diff: { state: 'absent' },
				file: { state: 'absent' },
				head: contentForRole('head'),
			},
			contentHashesByRole: {
				base: sha256Fixture(itemIndex * 2),
				head: sha256Fixture(itemIndex * 2 + 1),
			},
			deletions: 1,
			extension: 'ts',
			headPath: path,
			itemId,
			language: 'typescript',
			mimeTypes: ['text/typescript'],
			parentPath: `nested/${groupName}`,
			sortKey: itemIndex,
		});
		if (item.recordKind !== 'item') throw new Error('Expected Review item.');
		return { key: itemId, revision: reviewIdentity.revision, value: item };
	});
	const publication = bridgeProductReviewBatchRecordSchema.parse({
		...publicationFixture,
		desired: { reviewComparison: null, status: 'ready' },
		displayed: {
			...publicationFixture.displayed,
			generation: reviewIdentity.generation,
			packageId: reviewIdentity.packageId,
			publicationId: reviewIdentity.publicationId,
			query: { ...publicationFixture.displayed.query, queryId: reviewIdentity.sourceIdentity },
			revision: reviewIdentity.revision,
			summary: {
				additions: reviewItemCount,
				deletions: reviewItemCount,
				filesChanged: reviewItemCount,
				hiddenFileCount: 0,
				visibleFileCount: reviewItemCount,
			},
		},
		publicationId: reviewIdentity.publicationId,
		revision: reviewIdentity.revision,
	});
	const begin = bridgeProductBatchFrameSchema.parse({
		...sessionCorpus.transportV2.batchFrames[0],
		snapshotCause,
		batchId: uuidv7(),
		partCount: records.length + 1,
		publicationId: reviewIdentity.publicationId,
		scope: { kind: 'review', interests: [] },
		subscriptionId: 'review-windowed-runtime-subscription',
		subscriptionKind: 'review.metadata',
		targetRevision: reviewIdentity.revision,
	});
	if (begin.kind !== 'subscription.batchBegin') throw new Error('Review batch begin missing.');
	return {
		certified: true,
		staleRecords: [],
		begin,
		domain: 'default',
		records: [
			...records,
			{ key: 'publication', revision: reviewIdentity.revision, value: publication },
		],
	};
}

function boundedReviewParts(
	installation: BridgeProductViewInstallation,
): readonly WindowedReviewBatchPart[] {
	const parts: WindowedReviewBatchPart[] = [];
	for (let startIndex = 0; startIndex < installation.records.length; startIndex += recordPartSize) {
		const partIndex = parts.length;
		parts.push({
			...(partIndex === 0 ? { begin: installation.begin } : {}),
			final: startIndex + recordPartSize >= installation.records.length,
			partIndex,
			records: installation.records.slice(startIndex, startIndex + recordPartSize),
		});
	}
	return parts;
}

function assertCompleteDisplayPublication(
	displayMessage: BridgeWorkerReviewDisplayPatchEvent | undefined,
): void {
	if (displayMessage === undefined) throw new Error('Expected one Review display publication.');
	expect(displayMessage.reviewPublicationIdentity).toEqual({
		packageId: reviewIdentity.packageId,
		publicationId: reviewIdentity.publicationId,
		reviewGeneration: reviewIdentity.generation,
		revision: reviewIdentity.revision,
		sourceIdentity: reviewIdentity.sourceIdentity,
	});
	const sourcePatch = displayMessage.patches.find(
		(patch) => patch.slice === 'reviewSource' && patch.operation === 'upsert',
	);
	const itemPatch = displayMessage.patches.find(
		(patch) => patch.slice === 'reviewItem' && patch.operation === 'batch',
	);
	const treePatch = displayMessage.patches.find(
		(patch) => patch.slice === 'reviewTree' && patch.operation === 'batch',
	);
	expect(sourcePatch?.payload).toMatchObject({
		totalItemCount: reviewItemCount,
		totalTreeRowCount: reviewItemCount + Math.ceil(reviewItemCount / 6) + 1,
	});
	expect(itemPatch?.payload.items).toHaveLength(reviewItemCount);
	expect(itemPatch?.payload.reset).toBe(true);
	expect(treePatch?.payload.windows).toHaveLength(1);
	expect(treePatch?.payload.windows[0]?.rows).toHaveLength(
		reviewItemCount + Math.ceil(reviewItemCount / 6) + 1,
	);
}

function messagesOfKind<TKind extends BridgeWorkerServerToMainMessage['kind']>(
	messages: readonly BridgeWorkerServerToMainMessage[],
	kind: TKind,
): Array<Extract<BridgeWorkerServerToMainMessage, { readonly kind: TKind }>> {
	return messages.filter(
		(message): message is Extract<BridgeWorkerServerToMainMessage, { readonly kind: TKind }> =>
			message.kind === kind,
	);
}

function sha256Fixture(value: number): string {
	return value.toString(16).padStart(64, '0');
}

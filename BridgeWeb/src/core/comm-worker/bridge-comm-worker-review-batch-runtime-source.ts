import type { BridgeCommWorkerReviewBatchPresentation } from './bridge-comm-worker-review-batch-installer.js';
import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';
import {
	BRIDGE_PRODUCT_MAXIMUM_REVIEW_CONTENT_RANGE_BYTES,
	bridgeProductReviewContentDescriptorSchema,
	type BridgeProductReviewContentSourceDescriptor,
} from './bridge-product-content-contracts.js';
import type { BridgeProductReviewBatchRecord } from './bridge-product-review-batch-record-contracts.js';
import type {
	BridgeWorkerReviewContentMetadata,
	BridgeWorkerReviewContentRequestDescriptor,
	BridgeWorkerReviewRenderSemantics,
} from './bridge-worker-contracts.js';

type ReviewBatchItem = Extract<BridgeProductReviewBatchRecord, { readonly recordKind: 'item' }>;
type ReviewContentRole = keyof ReviewBatchItem['contentByRole'];
const reviewContentRoleOrder: readonly ReviewContentRole[] = ['base', 'head', 'diff', 'file'];

/** Converts one installed, role-qualified Review bank without an event projection. */
export function bridgeCommWorkerReviewRuntimeSourceFromBatch(
	presentation: Pick<
		BridgeCommWorkerReviewBatchPresentation,
		'orderedItems' | 'publication' | 'treeRows'
	>,
): BridgeCommWorkerReviewRuntimeSource {
	const displayed = presentation.publication.displayed;
	return {
		contentItems: presentation.orderedItems.map(reviewContentMetadata),
		contentRequestDescriptors: presentation.orderedItems.flatMap((item) =>
			reviewContentRoleOrder.flatMap((role) => {
				const source = usableRoleSource(item, role);
				return source === null ? [] : [reviewContentRequestDescriptor(source)];
			}),
		),
		renderSemantics: presentation.orderedItems.map(reviewRenderSemantics),
		reviewPublicationIdentity:
			displayed === null
				? null
				: {
						packageId: displayed.packageId,
						publicationId: displayed.publicationId,
						reviewGeneration: displayed.generation,
						revision: displayed.revision,
						sourceIdentity: displayed.query.queryId,
					},
		rows: presentation.treeRows.map((row) => ({
			id: row.id,
			index: row.index,
			parentId: row.parentId,
		})),
	};
}

function reviewContentMetadata(item: ReviewBatchItem): BridgeWorkerReviewContentMetadata {
	const sources = reviewContentRoleOrder.flatMap((role) => {
		const source = usableRoleSource(item, role);
		return source === null ? [] : [source];
	});
	return {
		availableContentRoles: sources.map((source) => source.role),
		cacheKey: reviewSemanticCacheKey(item),
		contentLineCountsByRole: reviewLineCounts(item),
		itemId: item.itemId,
		language: item.language,
		path: reviewDisplayPath(item),
		sizeBytes: Math.max(0, ...sources.map((source) => source.wholeByteLength ?? 0)),
	};
}

function reviewRenderSemantics(item: ReviewBatchItem): BridgeWorkerReviewRenderSemantics {
	return {
		basePath: item.basePath,
		changeKind: item.changeKind,
		contentLineCountsByRole: reviewLineCounts(item),
		displayPath: reviewDisplayPath(item),
		headPath: item.headPath,
		itemId: item.itemId,
		itemKind: reviewItemKind(item),
		language: item.language,
	};
}

function reviewSemanticCacheKey(item: ReviewBatchItem): string {
	const roleKeys = reviewContentRoleOrder.flatMap((role) => {
		if (item.contentByRole[role].state === 'absent') return [];
		const source = usableRoleSource(item, role);
		if (source !== null) {
			return [
				`${role}:${source.contentDigest.algorithm}:${source.contentDigest.authority}:${source.contentDigest.value}`,
			];
		}
		const metadataHash = item.contentHashesByRole[role] ?? null;
		return metadataHash === null ? [`${role}:unavailable`] : [`${role}:metadata:${metadataHash}`];
	});
	return `review:${reviewItemKind(item)}:${roleKeys.length === 0 ? `item:${item.itemId}` : roleKeys.join('|')}`;
}

function reviewLineCounts(
	item: ReviewBatchItem,
): BridgeWorkerReviewContentMetadata['contentLineCountsByRole'] {
	const lineCounts: Partial<Record<ReviewContentRole, number>> = {};
	for (const role of reviewContentRoleOrder) {
		const count = item.extentByRole[role];
		if (count !== null) lineCounts[role] = count;
	}
	return lineCounts;
}

function usableRoleSource(
	item: ReviewBatchItem,
	role: ReviewContentRole,
): BridgeProductReviewContentSourceDescriptor | null {
	const content = item.contentByRole[role];
	return content.state === 'available' &&
		!content.source.isBinary &&
		content.source.encoding === 'utf-8'
		? content.source
		: null;
}

function reviewContentRequestDescriptor(
	source: BridgeProductReviewContentSourceDescriptor,
): BridgeWorkerReviewContentRequestDescriptor {
	const declaredByteLength =
		source.wholeByteLength !== null &&
		source.wholeByteLength <= BRIDGE_PRODUCT_MAXIMUM_REVIEW_CONTENT_RANGE_BYTES
			? source.wholeByteLength
			: null;
	const expectedSha256 =
		declaredByteLength !== null && source.contentDigest.authority === 'authoritative'
			? source.contentDigest.value
			: null;
	return bridgeProductReviewContentDescriptorSchema.parse({
		...source,
		declaredByteLength,
		encoding: 'utf-8',
		expectedSha256,
		isBinary: false,
		maximumBytes: BRIDGE_PRODUCT_MAXIMUM_REVIEW_CONTENT_RANGE_BYTES,
		window: {
			kind: 'byteRange',
			maximumBytes: BRIDGE_PRODUCT_MAXIMUM_REVIEW_CONTENT_RANGE_BYTES,
			startByte: 0,
		},
	});
}

function reviewItemKind(item: ReviewBatchItem): BridgeWorkerReviewRenderSemantics['itemKind'] {
	return item.contentByRole.file.state !== 'absent' &&
		reviewContentRoleOrder
			.filter((role) => role !== 'file')
			.every((role) => item.contentByRole[role].state === 'absent')
		? 'file'
		: 'diff';
}

function reviewDisplayPath(item: ReviewBatchItem): string {
	return item.headPath ?? item.basePath ?? item.itemId;
}

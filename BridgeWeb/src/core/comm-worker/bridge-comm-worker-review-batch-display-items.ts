import type { BridgeProductReviewBatchRecord } from './bridge-product-review-batch-record-contracts.js';
import { bridgeProductReviewItemMetadataSchema } from './bridge-product-review-metadata-contracts.js';
import type { BridgeWorkerReviewDisplayItem } from './bridge-worker-contracts.js';

type ReviewBatchItem = Extract<BridgeProductReviewBatchRecord, { readonly recordKind: 'item' }>;
type ReviewBatchPublication = Extract<
	BridgeProductReviewBatchRecord,
	{ readonly recordKind: 'publication' }
>;
type DisplayedPublication = NonNullable<ReviewBatchPublication['displayed']>;
type ReviewContentRole = keyof ReviewBatchItem['contentByRole'];
const reviewContentRoleOrder: readonly ReviewContentRole[] = ['base', 'head', 'diff', 'file'];

/** The typed record, not a metadata event, owns every display item fact. */
export function bridgeCommWorkerReviewDisplayItemFromBatch(
	item: ReviewBatchItem,
	displayed: DisplayedPublication,
): BridgeWorkerReviewDisplayItem {
	const {
		contentByRole,
		extentByRole,
		parentPath: _parentPath,
		recordKind: _recordKind,
		sortKey: _sortKey,
		...itemFacts
	} = item;
	const contentRoles = reviewContentRoleOrder.filter(
		(role) => contentByRole[role].state !== 'absent',
	);
	const contentSources = reviewContentRoleOrder.flatMap((role) => {
		const content = contentByRole[role];
		return content.state === 'available' ? [content.source] : [];
	});
	const metadata = bridgeProductReviewItemMetadataSchema.parse({
		...itemFacts,
		contentDescriptorIdsByRole: Object.fromEntries(
			contentSources.map((source) => [source.role, source.descriptorId]),
		),
		contentRoles,
	});
	const semanticDocumentRevision = JSON.stringify([
		'bridge-semantic-document-v1',
		contentRoles.includes('base') || contentRoles.includes('diff') ? 'diff' : 'file',
		contentSources.map((source) => [
			source.role,
			source.contentDigest.algorithm,
			source.contentDigest.authority,
			source.contentDigest.value,
		]),
	]);
	return {
		contentFacts: contentSources.map((source) => ({
			contentDigest: source.contentDigest,
			role: source.role,
			semanticDocumentRevision,
		})),
		extentFacts: reviewContentRoleOrder.flatMap((role) => {
			const lineCount = extentByRole[role];
			return lineCount === null ? [] : [{ contentRole: role, itemId: item.itemId, lineCount }];
		}),
		metadata,
		metadataWindowIdentity: JSON.stringify([
			'bridge-review-metadata-window-v1',
			displayed.query.queryId,
			displayed.generation,
			displayed.publicationId,
			displayed.revision,
			item.itemId,
		]),
	};
}

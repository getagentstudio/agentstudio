import { describe, expect, test } from 'vitest';

import recordCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import { bridgeCommWorkerReviewDisplayItemFromBatch } from './bridge-comm-worker-review-batch-display-items.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import { bridgeWorkerReviewDisplayPatchSchema } from './bridge-worker-contracts.js';

describe('Bridge Review certified display item', () => {
	test('projects role, extent, metadata hash and displayed window identity', () => {
		const item = bridgeProductReviewBatchRecordSchema.parse(recordCorpus.records[0]?.record);
		const publication = bridgeProductReviewBatchRecordSchema.parse(recordCorpus.records[2]?.record);
		if (
			item.recordKind !== 'item' ||
			publication.recordKind !== 'publication' ||
			publication.displayed === null
		)
			throw new Error('Expected a displayed Review item fixture.');
		const displayItem = bridgeCommWorkerReviewDisplayItemFromBatch(item, publication.displayed);
		expect(displayItem.metadata.contentRoles).toEqual(['head', 'diff']);
		expect(displayItem.metadata.contentHashesByRole.diff).toBe('diff-unavailable-hash-1');
		expect(displayItem.contentFacts.map((fact) => fact.role)).toEqual(['head']);
		expect(displayItem.extentFacts).toEqual([
			{ contentRole: 'head', itemId: item.itemId, lineCount: 3 },
		]);
		expect(displayItem.metadataWindowIdentity).toContain(publication.displayed.publicationId);
		expect(
			bridgeWorkerReviewDisplayPatchSchema.safeParse({
				operation: 'batch',
				payload: { items: [displayItem], operations: [], reset: true, startIndex: 0 },
				slice: 'reviewItem',
			}).success,
		).toBe(true);
	});
});

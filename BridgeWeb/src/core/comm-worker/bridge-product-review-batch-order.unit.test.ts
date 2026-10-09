import { createHash } from 'node:crypto';

import { describe, expect, test } from 'vitest';

import recordCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import { deriveBridgeProductReviewBatchOrder } from './bridge-product-review-batch-order.js';
import {
	bridgeProductReviewBatchRecordSchema,
	type BridgeProductReviewBatchRecord,
} from './bridge-product-review-batch-record-contracts.js';

type ReviewBatchItem = Extract<BridgeProductReviewBatchRecord, { readonly recordKind: 'item' }>;

const parsedFixture = bridgeProductReviewBatchRecordSchema.parse(recordCorpus.records[0]?.record);
if (parsedFixture.recordKind !== 'item') throw new Error('Expected a Review item fixture.');
const fixtureItem: ReviewBatchItem = parsedFixture;

function reviewItem(itemId: string, path: string, sortKey: number): ReviewBatchItem {
	const source = fixtureItem.contentByRole.head;
	const parentPath = path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : null;
	return {
		...fixtureItem,
		contentByRole: {
			...fixtureItem.contentByRole,
			head:
				source.state === 'available' ? { ...source, source: { ...source.source, itemId } } : source,
		},
		headPath: path,
		itemId,
		parentPath,
		sortKey,
	};
}

describe('Bridge product Review batch order', () => {
	test('preserves package order instead of alphabetizing paths and reuses stable directory identity', async () => {
		const result = await deriveBridgeProductReviewBatchOrder([
			reviewItem('review-b', 'src/z.swift', 0),
			reviewItem('review-a', 'src/a.swift', 1),
		]);
		const directoryId = `review-directory-${createHash('sha256').update('src').digest('hex').slice(0, 32)}`;
		expect(result.orderedItems.map((item) => item.itemId)).toEqual(['review-b', 'review-a']);
		expect(result.treeRows.map((row) => [row.id, row.parentId, row.path])).toEqual([
			[directoryId, null, 'src'],
			['review-b', directoryId, 'src/z.swift'],
			['review-a', directoryId, 'src/a.swift'],
		]);
	});

	test('uses item id as a deterministic sort-key tie break and accepts an empty publication', async () => {
		const tied = await deriveBridgeProductReviewBatchOrder([
			reviewItem('review-z', 'z.swift', 4),
			reviewItem('review-a', 'a.swift', 4),
		]);
		expect(tied.orderedItems.map((item) => item.itemId)).toEqual(['review-a', 'review-z']);
		expect((await deriveBridgeProductReviewBatchOrder([])).treeRows).toEqual([]);
	});

	test('rejects duplicate ids and a parent that does not describe the display path', async () => {
		await expect(
			deriveBridgeProductReviewBatchOrder([
				reviewItem('same-item', 'src/a.swift', 0),
				reviewItem('same-item', 'src/b.swift', 1),
			]),
		).rejects.toThrow('duplicate item id');
		await expect(
			deriveBridgeProductReviewBatchOrder([
				{ ...reviewItem('review-a', 'src/a.swift', 0), parentPath: 'other' },
			]),
		).rejects.toThrow('parent differs');
	});
});

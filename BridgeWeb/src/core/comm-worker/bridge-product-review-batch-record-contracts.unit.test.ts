import { describe, expect, test } from 'vitest';

import recordCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';

describe('Bridge product Review batch records', () => {
	test('retains ordered item semantics and an empty publication', () => {
		expect(recordCorpus.records).toHaveLength(3);
		for (const { recordKey, record } of recordCorpus.records) {
			const parsed = bridgeProductReviewBatchRecordSchema.parse(record);
			expect(parsed).toEqual(record);
			if (parsed.recordKind === 'item') {
				expect(parsed.itemId).toBe(recordKey);
				expect(parsed.sortKey).toBe(0);
			} else {
				expect(recordKey).toBe('publication');
				expect(parsed.revision).toBeGreaterThan(0);
				if (parsed.displayed !== null) {
					expect(parsed.displayed.revision).toBe(0);
					expect(
						bridgeProductReviewBatchRecordSchema.safeParse({
							...parsed,
							displayed: { ...parsed.displayed, revision: -1 },
						}).success,
					).toBe(false);
					expect(parsed.publicationId).not.toBe(parsed.displayed.publicationId);
					expect(parsed.desired.status).toBe('failedRetryable');
				}
			}
		}
	});

	test('requires an identity even for a status-only publication', () => {
		const statusOnly = recordCorpus.records[1]?.record;
		expect(statusOnly).toBeDefined();
		if (statusOnly === undefined) return;
		expect(
			bridgeProductReviewBatchRecordSchema.safeParse({ ...statusOnly, publicationId: undefined })
				.success,
		).toBe(false);
	});

	test('requires the nullable classified refresh impact field', () => {
		const record = recordCorpus.records[1]?.record;
		expect(record).toBeDefined();
		if (record === undefined) return;
		expect(bridgeProductReviewBatchRecordSchema.safeParse(record).success).toBe(true);
		expect(
			bridgeProductReviewBatchRecordSchema.safeParse({
				...record,
				classifiedRefreshImpact: undefined,
			}).success,
		).toBe(false);
	});

	test('rejects a content source assigned to another item or role', () => {
		const record = bridgeProductReviewBatchRecordSchema.parse(recordCorpus.records[0]?.record);
		if (record.recordKind !== 'item') return;
		const head = record.contentByRole.head;
		if (head.state !== 'available') return;
		expect(
			bridgeProductReviewBatchRecordSchema.safeParse({
				...record,
				contentByRole: {
					...record.contentByRole,
					head: { ...head, source: { ...head.source, itemId: 'another-item' } },
				},
			}).success,
		).toBe(false);
	});
});

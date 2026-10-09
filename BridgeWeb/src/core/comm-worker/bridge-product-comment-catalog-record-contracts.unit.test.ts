import { describe, expect, test } from 'vitest';

import recordCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-comment-catalog-record-corpus.json' with { type: 'json' };
import {
	bridgeProductCommentCatalogRecordKey,
	bridgeProductCommentCatalogRecordSchema,
} from './bridge-product-comment-catalog-record-contracts.js';

describe('Bridge product comment catalog records', () => {
	test('round-trips keyed records with independent wire and semantic revisions', () => {
		expect(recordCorpus.records).toHaveLength(4);
		for (const { recordKey, record } of recordCorpus.records) {
			const parsed = bridgeProductCommentCatalogRecordSchema.parse(record);
			expect(parsed).toEqual(record);
			expect(bridgeProductCommentCatalogRecordKey(parsed)).toBe(recordKey);
		}
	});

	test('wire revision can advance while the session concurrency revision stays current', () => {
		const session = recordCorpus.records[0];
		expect(session).toBeDefined();
		if (session === undefined) return;
		expect(
			bridgeProductCommentCatalogRecordSchema.safeParse({ ...session.record, revision: 2 }).success,
		).toBe(true);
		expect(
			bridgeProductCommentCatalogRecordSchema.safeParse({ ...session.record, revision: 0 }).success,
		).toBe(false);
		expect(
			bridgeProductCommentCatalogRecordSchema.safeParse({
				...session.record,
				entry: { ...session.record.entry, semanticRevision: -1 },
			}).success,
		).toBe(false);
	});
});

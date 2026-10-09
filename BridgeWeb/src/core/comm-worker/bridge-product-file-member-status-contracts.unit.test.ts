import { describe, expect, test } from 'vitest';

import corpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import {
	BRIDGE_PRODUCT_FILE_MEMBER_STATUS_KEY,
	bridgeProductFileBatchRecordSchema,
	bridgeProductFileMemberStatusRecordSchema,
} from './bridge-product-file-member-status-contracts.js';

describe('Bridge product File member-status record', () => {
	test('keeps source identity and last-good git facts through stale and failed states', () => {
		expect(corpus.memberStatuses).toHaveLength(3);
		for (const { recordKey, record } of corpus.memberStatuses) {
			expect(recordKey).toBe(BRIDGE_PRODUCT_FILE_MEMBER_STATUS_KEY);
			expect(bridgeProductFileMemberStatusRecordSchema.parse(record)).toEqual(record);
			expect(bridgeProductFileBatchRecordSchema.parse(record)).toEqual(record);
			expect(record.branchName).toBe('main');
			expect(record.staged).toBe(3);
		}
	});

	test('rejects a negative count or missing source on a status record', () => {
		const fixture = corpus.memberStatuses[0]?.record;
		if (fixture === undefined) throw new Error('Member-status fixture missing.');
		expect(
			bridgeProductFileMemberStatusRecordSchema.safeParse({ ...fixture, ahead: -1 }).success,
		).toBe(false);
		const { source: _source, ...withoutSource } = fixture;
		expect(bridgeProductFileMemberStatusRecordSchema.safeParse(withoutSource).success).toBe(false);
	});
});

import { describe, expect, test } from 'vitest';

import rowCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import { bridgeProductFileBatchRowSchema } from './bridge-product-file-batch-row-contracts.js';

describe('Bridge product File batch row', () => {
	test('retains canonical record identity while a deleted ghost has no read descriptor', () => {
		expect(rowCorpus.rows).toHaveLength(3);
		for (const { recordKey, row } of rowCorpus.rows) {
			expect(recordKey.startsWith('/workspace/')).toBe(true);
			expect(bridgeProductFileBatchRowSchema.parse(row)).toEqual(row);
			if (row.kind === 'file') {
				expect(row.fileClass).toBe('source');
				expect(row.fileId).toBe('file-1');
				expect(row.name).toBe('a.ts');
				expect(row.depth).toBe(1);
				expect(row.sizeBytes).toBe(3);
				expect(row.lineCount).toBe(1);
				expect(row.descriptorOutcome?.rowId).toBe(row.rowId);
				expect(row.descriptorOutcome?.path).toBe(row.displayKey);
			} else {
				expect(row.fileClass).toBeNull();
				expect(row.fileId).toBeNull();
				expect(row.sizeBytes).toBeNull();
				expect(row.lineCount).toBeNull();
				expect(row.descriptorOutcome).toBeNull();
			}
			if (row.kind === 'deleted') {
				expect(row.readDescriptor).toBeNull();
				expect(row.oldPath).not.toBeNull();
			}
		}
	});

	test('rejects lost classification and extent facts on a file or ghost', () => {
		const fileRow = rowCorpus.rows[0]?.row;
		const ghostRow = rowCorpus.rows[2]?.row;
		expect(fileRow).toBeDefined();
		expect(ghostRow).toBeDefined();
		if (fileRow === undefined || ghostRow === undefined) return;
		expect(bridgeProductFileBatchRowSchema.safeParse({ ...fileRow, fileClass: null }).success).toBe(
			false,
		);
		expect(bridgeProductFileBatchRowSchema.safeParse({ ...ghostRow, sizeBytes: 3 }).success).toBe(
			false,
		);
		expect(
			bridgeProductFileBatchRowSchema.safeParse({
				...fileRow,
				descriptorOutcome: { ...fileRow.descriptorOutcome, rowId: 'other-row' },
			}).success,
		).toBe(false);
	});

	test('rejects a read descriptor on a deleted ghost', () => {
		const fileRow = rowCorpus.rows[0];
		const deletedRow = rowCorpus.rows[2];
		expect(fileRow).toBeDefined();
		expect(deletedRow).toBeDefined();
		if (fileRow === undefined || deletedRow === undefined) return;
		expect(
			bridgeProductFileBatchRowSchema.safeParse({
				...deletedRow.row,
				readDescriptor: fileRow.row.readDescriptor,
			}).success,
		).toBe(false);
	});
});

import { describe, expect, test } from 'vitest';

import recordCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import type { BridgeCommWorkerReviewBatchPresentation } from './bridge-comm-worker-review-batch-installer.js';
import { bridgeCommWorkerReviewRuntimeSourceFromBatch } from './bridge-comm-worker-review-batch-runtime-source.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';

describe('Bridge Review certified batch runtime source', () => {
	test('keeps the displayed identity and unavailable-role metadata hash after desired failure', () => {
		const item = bridgeProductReviewBatchRecordSchema.parse(recordCorpus.records[0]?.record);
		const publication = bridgeProductReviewBatchRecordSchema.parse(recordCorpus.records[2]?.record);
		if (item.recordKind !== 'item' || publication.recordKind !== 'publication')
			throw new Error('Expected Review item and publication fixtures.');
		const presentation: Pick<
			BridgeCommWorkerReviewBatchPresentation,
			'orderedItems' | 'publication' | 'treeRows'
		> = {
			orderedItems: [item],
			publication,
			treeRows: [
				{
					depth: 0,
					id: 'review-directory-src',
					index: 0,
					isDirectory: true,
					itemId: null,
					parentId: null,
					path: 'src',
				},
				{
					depth: 1,
					id: item.itemId,
					index: 1,
					isDirectory: false,
					itemId: item.itemId,
					parentId: 'review-directory-src',
					path: 'src/New.swift',
				},
			],
		};
		const source = bridgeCommWorkerReviewRuntimeSourceFromBatch(presentation);
		expect(source.reviewPublicationIdentity).toEqual({
			packageId: publication.displayed?.packageId,
			publicationId: publication.displayed?.publicationId,
			reviewGeneration: publication.displayed?.generation,
			revision: publication.displayed?.revision,
			sourceIdentity: publication.displayed?.query.queryId,
		});
		expect(source.contentItems[0]?.cacheKey).toContain('diff:metadata:diff-unavailable-hash-1');
		const changedHashSource = bridgeCommWorkerReviewRuntimeSourceFromBatch({
			...presentation,
			orderedItems: [
				{
					...item,
					contentHashesByRole: { ...item.contentHashesByRole, diff: 'diff-unavailable-hash-2' },
				},
			],
		});
		expect(changedHashSource.contentItems[0]?.cacheKey).not.toBe(source.contentItems[0]?.cacheKey);
		expect(source.contentItems[0]?.availableContentRoles).toEqual(['head']);
		expect(source.contentRequestDescriptors.map((descriptor) => descriptor.role)).toEqual(['head']);
		expect(source.rows).toEqual([
			{ id: 'review-directory-src', index: 0, parentId: null },
			{ id: item.itemId, index: 1, parentId: 'review-directory-src' },
		]);
	});

	test('keeps a declared binary role unavailable for text preparation', () => {
		const item = bridgeProductReviewBatchRecordSchema.parse(recordCorpus.records[0]?.record);
		const publication = bridgeProductReviewBatchRecordSchema.parse(recordCorpus.records[2]?.record);
		if (item.recordKind !== 'item' || publication.recordKind !== 'publication')
			throw new Error('Expected Review item and publication fixtures.');
		const head = item.contentByRole.head;
		if (head.state !== 'available') throw new Error('Expected a head source fixture.');
		const binaryItem = bridgeProductReviewBatchRecordSchema.parse({
			...item,
			contentByRole: {
				...item.contentByRole,
				head: { state: 'available', source: { ...head.source, encoding: null, isBinary: true } },
			},
		});
		if (binaryItem.recordKind !== 'item') throw new Error('Expected a binary item.');
		const source = bridgeCommWorkerReviewRuntimeSourceFromBatch({
			orderedItems: [binaryItem],
			publication,
			treeRows: [],
		});
		expect(source.contentItems[0]?.availableContentRoles).toEqual([]);
		expect(source.contentItems[0]?.cacheKey).toContain(
			'head:metadata:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
		);
		expect(source.contentRequestDescriptors).toEqual([]);
		expect(source.renderSemantics[0]?.itemKind).toBe('diff');
	});
});

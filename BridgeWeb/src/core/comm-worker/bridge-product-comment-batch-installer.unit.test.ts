import { describe, expect, test } from 'vitest';

import commentCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-comment-catalog-record-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { installBridgeProductCommentBatch } from './bridge-product-comment-batch-installer.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';

function commentInstallation(): BridgeProductViewInstallation {
	const reviewBegin = sessionCorpus.transportV2.batchFrames.find(
		(frame) => frame.kind === 'subscription.batchBegin',
	);
	if (reviewBegin === undefined) throw new Error('Batch begin fixture missing.');
	const begin = bridgeProductBatchFrameSchema.parse({
		...reviewBegin,
		publicationId: undefined,
		batchId: 'comment-batch-1',
		scope: { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' },
		subscriptionId: 'comment-subscription-1',
		subscriptionKind: 'file.annotations',
		targetRevision: 4,
	});
	if (begin.kind !== 'subscription.batchBegin') throw new Error('Comment begin is invalid.');
	return {
		certified: true,
		staleRecords: [],
		begin,
		domain: 'default',
		records: [
			...new Map(
				commentCorpus.records.map(({ recordKey, record }) => [
					recordKey,
					{ key: recordKey, revision: record.revision, value: record },
				]),
			).values(),
		],
	};
}

const authority = {
	subscriptionId: 'comment-subscription-1',
	workerDerivationEpoch: 2,
	worktreeId: 'worktree-1',
} as const;

describe('Bridge product comment batch installer', () => {
	test('installs a certified hierarchy with independent wire and semantic revisions', () => {
		const catalog = installBridgeProductCommentBatch(commentInstallation(), authority);
		expect(catalog.catalogRevision).toBe(4);
		expect(catalog.entries).toHaveLength(3);
		expect(catalog.orderedSessionIds).toEqual(['11111111-1111-7111-8111-111111111111']);
		expect(catalog.sessionsById.get('11111111-1111-7111-8111-111111111111')?.semanticRevision).toBe(
			0,
		);
	});

	test('rejects a record whose key or certified revision differs', () => {
		const installation = commentInstallation();
		const first = installation.records[0];
		if (first === undefined) throw new Error('Comment fixture missing.');
		expect(() =>
			installBridgeProductCommentBatch(
				{
					...installation,
					records: [{ ...first, key: 'session:wrong' }, ...installation.records.slice(1)],
				},
				authority,
			),
		).toThrow(/certified key or revision/);
		expect(() =>
			installBridgeProductCommentBatch(
				{ ...installation, records: [{ ...first, revision: 2 }, ...installation.records.slice(1)] },
				authority,
			),
		).toThrow(/certified key or revision/);
	});

	test('requires a coherent range after a cascade deletion', () => {
		const installation = commentInstallation();
		const orphaned = installation.records.filter((record) => !record.key.startsWith('thread:'));
		expect(() =>
			installBridgeProductCommentBatch({ ...installation, records: orphaned }, authority),
		).toThrow(/unknown_thread/);
		expect(
			installBridgeProductCommentBatch({ ...installation, records: [] }, authority).entries,
		).toEqual([]);
	});
});

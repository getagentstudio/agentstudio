import { describe, expect, test } from 'vitest';

import fileCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { BridgeProductViewBatchReceiver } from './bridge-product-view-batch-receiver.js';

const narrowScope = {
	kind: 'file',
	changeFilter: { kind: 'none' },
	interests: [],
	pathScope: ['Sources'],
} as const;
const broadScope = { ...narrowScope, pathScope: [] } as const;
const frameIdentity = {
	batchId: 'narrow-batch',
	domain: 'default',
	handle: 'file-handle',
	incarnation: 'file-incarnation',
	metadataStreamId: 'file-stream',
	paneSessionId: 'pane-1',
	scopeRevision: 1,
	subscriptionId: 'file-subscription',
	subscriptionKind: 'file.metadata',
	wireVersion: 2,
	workerInstanceId: 'worker-1',
} as const;

describe('Bridge File W4 membership filter', () => {
	test('a delayed narrow path snapshot cannot install after path scope broadens', () => {
		const row = fileCorpus.rows[0];
		if (row === undefined) throw new Error('File row corpus is empty.');
		const receiver = new BridgeProductViewBatchReceiver({
			handle: frameIdentity.handle,
			scope: narrowScope,
			scopeRevision: 1,
			subscriptionId: frameIdentity.subscriptionId,
			subscriptionKind: 'file.metadata',
		});
		receiver.admitDomain('default', frameIdentity.incarnation);
		expect(
			receiver.accept(
				bridgeProductBatchFrameSchema.parse({
					...frameIdentity,
					kind: 'subscription.batchBegin',
					streamSequence: 1,
					baseRevision: 0,
					mode: 'snapshot',
					snapshotCause: 'open',
					partCount: 1,
					targetRevision: 1,
					scope: narrowScope,
				}),
			).kind,
		).toBe('staged');
		expect(
			receiver.accept(
				bridgeProductBatchFrameSchema.parse({
					...frameIdentity,
					kind: 'subscription.batchPart',
					streamSequence: 2,
					deliverySequence: 1,
					partIndex: 0,
					part: { operation: 'put', key: row.recordKey, revision: 1, value: row.row },
				}),
			).kind,
		).toBe('staged');

		expect(receiver.setScope(broadScope, 2)).toBe(true);
		expect(
			receiver.accept(
				bridgeProductBatchFrameSchema.parse({
					...frameIdentity,
					kind: 'subscription.batchComplete',
					streamSequence: 3,
					coveredScope: narrowScope,
				}),
			).kind,
		).not.toBe('installed');
		expect(receiver.records('default')).toEqual([]);
		expect(
			receiver.accept(
				bridgeProductBatchFrameSchema.parse({
					...frameIdentity,
					batchId: 'broad-batch',
					kind: 'subscription.batchBegin',
					streamSequence: 4,
					scopeRevision: 2,
					baseRevision: 0,
					mode: 'snapshot',
					snapshotCause: 'open',
					partCount: 1,
					targetRevision: 2,
					scope: broadScope,
				}),
			).kind,
		).toBe('staged');
		expect(
			receiver.accept(
				bridgeProductBatchFrameSchema.parse({
					...frameIdentity,
					batchId: 'broad-batch',
					kind: 'subscription.batchPart',
					streamSequence: 5,
					scopeRevision: 2,
					deliverySequence: 2,
					partIndex: 0,
					part: { operation: 'put', key: row.recordKey, revision: 2, value: row.row },
				}),
			).kind,
		).toBe('staged');
		expect(
			receiver.accept(
				bridgeProductBatchFrameSchema.parse({
					...frameIdentity,
					batchId: 'broad-batch',
					kind: 'subscription.batchComplete',
					streamSequence: 6,
					scopeRevision: 2,
					coveredScope: broadScope,
				}),
			).kind,
		).toBe('installed');
		expect(receiver.records('default')).toHaveLength(1);
	});
});

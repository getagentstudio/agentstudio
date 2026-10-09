import { describe, expect, test } from 'vitest';

import recordCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { BridgeCommWorkerReviewBatchInstaller } from './bridge-comm-worker-review-batch-installer.js';
import {
	bridgeProductBatchFrameSchema,
	type BridgeProductBatchFrame,
} from './bridge-product-batch-wire-contracts.js';
import { deriveBridgeProductReviewBatchOrder } from './bridge-product-review-batch-order.js';
import {
	bridgeProductReviewBatchRecordSchema,
	type BridgeProductReviewBatchRecord,
} from './bridge-product-review-batch-record-contracts.js';
import { BridgeProductViewBatchReceiver } from './bridge-product-view-batch-receiver.js';

type ReviewBatchBegin = Extract<
	BridgeProductBatchFrame,
	{ readonly kind: 'subscription.batchBegin' }
>;
type ReviewBatchItem = Extract<BridgeProductReviewBatchRecord, { readonly recordKind: 'item' }>;
type ReviewBatchPublication = Extract<
	BridgeProductReviewBatchRecord,
	{ readonly recordKind: 'publication' }
>;

const item = bridgeProductReviewBatchRecordSchema.parse(recordCorpus.records[0]?.record);
const emptyPublication = bridgeProductReviewBatchRecordSchema.parse(
	recordCorpus.records[1]?.record,
);
const failedPublication = bridgeProductReviewBatchRecordSchema.parse(
	recordCorpus.records[2]?.record,
);
if (
	item.recordKind !== 'item' ||
	emptyPublication.recordKind !== 'publication' ||
	failedPublication.recordKind !== 'publication'
) {
	throw new Error('Expected Review batch record fixtures.');
}
const fixtureItem: ReviewBatchItem = item;
const fixtureEmptyPublication: ReviewBatchPublication = emptyPublication;
const fixtureFailedPublication: ReviewBatchPublication = failedPublication;

function begin(publicationId: string, targetRevision: number, mode = 'snapshot'): ReviewBatchBegin {
	const fixtureFrame: Readonly<Record<string, unknown>> | undefined =
		sessionCorpus.transportV2.batchFrames[0];
	const { snapshotCause, ...fixture } = fixtureFrame ?? {};
	const parsed = bridgeProductBatchFrameSchema.parse({
		...fixture,
		mode,
		// Only a snapshot begin carries a cause; the strict contract rejects one on change.
		...(mode === 'snapshot' ? { snapshotCause } : {}),
		publicationId,
		targetRevision,
	});
	if (parsed.kind !== 'subscription.batchBegin') throw new Error('Expected Review batch begin.');
	return parsed;
}

function installedRecord(record: BridgeProductReviewBatchRecord): {
	readonly key: string;
	readonly revision: number;
	readonly value: unknown;
} {
	return {
		key: record.recordKind === 'item' ? record.itemId : 'publication',
		revision: record.recordKind === 'item' ? 1 : record.revision,
		value: record,
	};
}

describe('Bridge comm worker typed Review batch installer', () => {
	test('installs a complete certified W4 bank after parts arrive', async () => {
		const batchBegin = bridgeProductBatchFrameSchema.parse({
			...begin(fixtureFailedPublication.publicationId, 12),
			partCount: 2,
		});
		if (batchBegin.kind !== 'subscription.batchBegin') throw new Error('Expected batch begin.');
		const receiver = new BridgeProductViewBatchReceiver({
			handle: batchBegin.handle,
			scope: batchBegin.scope,
			scopeRevision: batchBegin.scopeRevision,
			subscriptionId: batchBegin.subscriptionId,
			subscriptionKind: 'review.metadata',
		});
		receiver.admitDomain(batchBegin.domain, batchBegin.incarnation);
		const identity = {
			batchId: batchBegin.batchId,
			domain: batchBegin.domain,
			handle: batchBegin.handle,
			incarnation: batchBegin.incarnation,
			metadataStreamId: batchBegin.metadataStreamId,
			paneSessionId: batchBegin.paneSessionId,
			scopeRevision: batchBegin.scopeRevision,
			subscriptionId: batchBegin.subscriptionId,
			subscriptionKind: batchBegin.subscriptionKind,
			wireVersion: batchBegin.wireVersion,
			workerInstanceId: batchBegin.workerInstanceId,
		};
		const part = (record: BridgeProductReviewBatchRecord, index: number): BridgeProductBatchFrame =>
			bridgeProductBatchFrameSchema.parse({
				...identity,
				deliverySequence: index + 1,
				kind: 'subscription.batchPart',
				part: {
					key: record.recordKind === 'item' ? record.itemId : 'publication',
					operation: 'put',
					revision: record.recordKind === 'item' ? 1 : record.revision,
					value: record,
				},
				partIndex: index,
				streamSequence: index + 2,
			});
		const complete = bridgeProductBatchFrameSchema.parse({
			...identity,
			coveredScope: batchBegin.scope,
			kind: 'subscription.batchComplete',
			streamSequence: 4,
		});
		expect(receiver.accept(batchBegin).kind).toBe('staged');
		expect(receiver.accept(part(fixtureItem, 0)).kind).toBe('staged');
		expect(receiver.accept(part(fixtureFailedPublication, 1)).kind).toBe('staged');
		expect(receiver.accept(complete).kind).toBe('installed');
		const installer = new BridgeCommWorkerReviewBatchInstaller({ handle: batchBegin.handle });
		expect(
			await installer.install({ begin: batchBegin, records: receiver.records('default') }),
		).toBe('installed');
		expect(installer.presentation?.treeRows.map((row) => row.path)).toEqual([
			'src',
			'src/New.swift',
		]);
		expect(installer.presentation?.runtimeSource.contentItems[0]?.itemId).toBe(fixtureItem.itemId);
		expect(installer.presentation?.runtimeSource.reviewPublicationIdentity?.publicationId).toBe(
			fixtureFailedPublication.displayed?.publicationId,
		);
	});

	test('installs an empty publication and then a failed desired comparison with old displayed content', async () => {
		const installer = new BridgeCommWorkerReviewBatchInstaller({ handle: 'review-handle-1' });
		const emptyBegin = begin(fixtureEmptyPublication.publicationId, 1);
		expect(
			await installer.install({
				begin: emptyBegin,
				records: [installedRecord(fixtureEmptyPublication)],
			}),
		).toBe('installed');
		expect(installer.presentation?.orderedItems).toEqual([]);

		const failedBegin = begin(fixtureFailedPublication.publicationId, 12);
		expect(
			await installer.install({
				begin: failedBegin,
				records: [installedRecord(fixtureItem), installedRecord(fixtureFailedPublication)],
			}),
		).toBe('installed');
		expect(installer.presentation?.orderedItems.map((value) => value.itemId)).toEqual([
			'review-item-1',
		]);
		expect(installer.presentation?.publication.desired.status).toBe('failedRetryable');
		expect(installer.presentation?.publication.displayed?.publicationId).not.toBe(
			installer.presentation?.publication.publicationId,
		);
		expect(installer.acceptsBegin(begin(fixtureEmptyPublication.publicationId, 13, 'change'))).toBe(
			false,
		);
	});

	test('rejects a record key or role extent without current content, retaining the prior bank', async () => {
		const installer = new BridgeCommWorkerReviewBatchInstaller({ handle: 'review-handle-1' });
		const currentBegin = begin(fixtureFailedPublication.publicationId, 12);
		await installer.install({
			begin: currentBegin,
			records: [installedRecord(fixtureItem), installedRecord(fixtureFailedPublication)],
		});
		const previous = installer.presentation;
		await expect(
			installer.install({
				begin: currentBegin,
				records: [
					{ ...installedRecord(fixtureItem), key: 'wrong-item' },
					installedRecord(fixtureFailedPublication),
				],
			}),
		).rejects.toThrow('key differs');
		const staleExtent = bridgeProductReviewBatchRecordSchema.parse({
			...fixtureItem,
			extentByRole: { ...fixtureItem.extentByRole, diff: 3 },
		});
		await expect(
			installer.install({
				begin: currentBegin,
				records: [installedRecord(staleExtent), installedRecord(fixtureFailedPublication)],
			}),
		).rejects.toThrow('retained an extent');
		expect(installer.presentation).toBe(previous);
	});

	test('replaces a shared item id with the new comparison snapshot value', async () => {
		const installer = new BridgeCommWorkerReviewBatchInstaller({ handle: 'review-handle-1' });
		await installer.install({
			begin: begin(fixtureFailedPublication.publicationId, 12),
			records: [installedRecord(fixtureItem), installedRecord(fixtureFailedPublication)],
		});
		const nextPublicationId = '00000000-0000-7000-8000-000000000014';
		const head = fixtureItem.contentByRole.head;
		if (head.state !== 'available' || fixtureFailedPublication.displayed === null) {
			throw new Error('Expected available content and displayed publication fixtures.');
		}
		const replacementItem = bridgeProductReviewBatchRecordSchema.parse({
			...fixtureItem,
			contentByRole: {
				...fixtureItem.contentByRole,
				head: {
					...head,
					source: {
						...head.source,
						packageId: 'review-package-2',
						sourceIdentity: 'review-query-2',
					},
				},
			},
			headPath: 'src/Replaced.swift',
		});
		const replacementPublication = bridgeProductReviewBatchRecordSchema.parse({
			...fixtureFailedPublication,
			desired: { reviewComparison: null, status: 'ready' },
			displayed: {
				...fixtureFailedPublication.displayed,
				packageId: 'review-package-2',
				publicationId: nextPublicationId,
				query: { ...fixtureFailedPublication.displayed.query, queryId: 'review-query-2' },
				revision: 13,
			},
			publicationId: nextPublicationId,
			revision: 13,
		});
		expect(
			await installer.install({
				begin: begin(nextPublicationId, 13),
				records: [
					{ ...installedRecord(replacementItem), revision: 13 },
					installedRecord(replacementPublication),
				],
			}),
		).toBe('installed');
		expect(installer.presentation?.orderedItems[0]?.itemId).toBe(fixtureItem.itemId);
		expect(installer.presentation?.treeRows.at(-1)?.path).toBe('src/Replaced.swift');
	});

	test('fences a completed derivation when the handle was replaced during it', async () => {
		const derived = await deriveBridgeProductReviewBatchOrder([fixtureItem]);
		let releaseDerivation: (() => void) | undefined;
		const heldDerivation = new Promise<typeof derived>((resolve) => {
			releaseDerivation = (): void => resolve(derived);
		});
		const installer = new BridgeCommWorkerReviewBatchInstaller({
			deriveOrder: () => heldDerivation,
			handle: 'review-handle-1',
		});
		const pending = installer.install({
			begin: begin(fixtureFailedPublication.publicationId, 12),
			records: [installedRecord(fixtureItem), installedRecord(fixtureFailedPublication)],
		});
		installer.replaceHandle('review-handle-2');
		releaseDerivation?.();
		expect(await pending).toBe('ignored');
		expect(installer.presentation).toBeNull();
	});
});

import { describe, expect, test } from 'vitest';

import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { createBridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import { BridgeProductBatchFrameRouter } from './bridge-product-batch-frame-router.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import {
	installBridgeProductFileBatch,
	type BridgeProductInstalledFileView,
} from './bridge-product-file-batch-installer.js';
import { bridgeProductFileBatchRowSchema } from './bridge-product-file-batch-row-contracts.js';
import { bridgeProductFileMemberStatusRecordSchema } from './bridge-product-file-member-status-contracts.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import { makeFileBatchInstallation } from './comm-runtime-protocol.file-product.test-support.js';

describe('retained File E3 revision continuity', () => {
	test('W4 installs the rebuilt source descriptor and admits selected demand', () => {
		const router = new BridgeProductBatchFrameRouter({
			deadlineClock: { schedule: () => (): void => {} },
			progressDeadlineMilliseconds: 5_000,
		});
		const state: { installed: BridgeProductInstalledFileView | null } = { installed: null };
		router.setSinks({
			verify: (installation): void => {
				installBridgeProductFileBatch(installation, state.installed);
			},
			install: (installation): void => {
				state.installed = installBridgeProductFileBatch(installation, state.installed);
			},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
		});
		let streamSequence = 0;
		let deliverySequence = 0;
		const send = (installation: BridgeProductViewInstallation): void => {
			const begin = bridgeProductBatchFrameSchema.parse({
				...installation.begin,
				partCount: installation.records.length,
				streamSequence: ++streamSequence,
			});
			if (begin.kind !== 'subscription.batchBegin') throw new Error('Expected a File batch begin.');
			router.accept(begin);
			for (const [partIndex, record] of installation.records.entries()) {
				router.accept(
					bridgeProductBatchFrameSchema.parse({
						...sessionCorpus.transportV2.batchFrames[1],
						batchId: begin.batchId,
						deliverySequence: ++deliverySequence,
						domain: begin.domain,
						handle: begin.handle,
						incarnation: begin.incarnation,
						metadataStreamId: begin.metadataStreamId,
						paneSessionId: begin.paneSessionId,
						partIndex,
						part: {
							key: record.key,
							operation: 'put',
							revision: record.revision,
							value: record.value,
						},
						scopeRevision: begin.scopeRevision,
						streamSequence: ++streamSequence,
						subscriptionId: begin.subscriptionId,
						subscriptionKind: begin.subscriptionKind,
						wireVersion: begin.wireVersion,
						workerInstanceId: begin.workerInstanceId,
					}),
				);
			}
			router.accept(
				bridgeProductBatchFrameSchema.parse({
					...sessionCorpus.transportV2.batchFrames[4],
					batchId: begin.batchId,
					coveredScope: begin.scope,
					domain: begin.domain,
					handle: begin.handle,
					incarnation: begin.incarnation,
					metadataStreamId: begin.metadataStreamId,
					paneSessionId: begin.paneSessionId,
					scopeRevision: begin.scopeRevision,
					streamSequence: ++streamSequence,
					subscriptionId: begin.subscriptionId,
					subscriptionKind: begin.subscriptionKind,
					wireVersion: begin.wireVersion,
					workerInstanceId: begin.workerInstanceId,
				}),
			);
		};

		const subscriptionId = 'retained-file-e3';
		send(makeFileBatchInstallation('open', subscriptionId, { revision: 4 }));
		const first = requireInstalledFileView(state);
		const store = createBridgeCommWorkerStore({
			contentItems: first.contentItems,
			rows: first.runtimeRows,
			surface: 'file',
		});
		store.actions.applySelectedFact({ epoch: 1, itemId: 'file-1' });
		expect(store.getState().demandByKey.get('file-1')).toBe('selected:1');

		send(rebuiltFileInstallation(subscriptionId, 5));
		const second = requireInstalledFileView(state);
		const selectedRequest = second.contentRequests.find((request) => request.itemId === 'file-1');
		expect(selectedRequest?.contentDescriptor.source.subscriptionGeneration).toBe(12);
		expect(selectedRequest?.contentDescriptor.descriptorId).toBe('file-descriptor-2');
		store.actions.applyFileViewSourceUpdateFact({
			contentItems: second.contentItems,
			epoch: 2,
			rows: second.runtimeRows,
			selectedContentRequestChanged: true,
		});
		expect(store.getState().demandByKey.get('file-1')).toBe('selected:2');
	});
});

function rebuiltFileInstallation(
	subscriptionId: string,
	revision: number,
): BridgeProductViewInstallation {
	const base = makeFileBatchInstallation('open', subscriptionId, { revision });
	const firstFileRecord = base.records.find((record) => record.key === '/workspace/src/a.ts');
	if (firstFileRecord === undefined) throw new Error('File batch fixture has no selected row.');
	const row = bridgeProductFileBatchRowSchema.parse(firstFileRecord.value);
	if (row.descriptorOutcome?.availability.availabilityKind !== 'available') {
		throw new Error('File batch fixture has no selected descriptor.');
	}
	const source = {
		...row.descriptorOutcome.source,
		sourceCursor: 'source-cursor-2',
		sourceId: 'source-2',
		subscriptionGeneration: 12,
	};
	const contentDescriptor = {
		...row.descriptorOutcome.availability.contentDescriptor,
		descriptorId: 'file-descriptor-2',
		expectedSha256: '94dda0ed4b1c44a08e3ef62b978ddd97258b6e3016696ea645e176730091e885',
		source,
	};
	const successorRow = {
		...row,
		descriptorOutcome: {
			...row.descriptorOutcome,
			availability: { availabilityKind: 'available' as const, contentDescriptor },
			source,
		},
		readDescriptor: contentDescriptor,
	};
	return {
		...base,
		records: base.records.map((record) =>
			record.key === firstFileRecord.key
				? { ...record, value: successorRow }
				: record.key === 'member-status'
					? {
							...record,
							value: { ...bridgeProductFileMemberStatusRecordSchema.parse(record.value), source },
						}
					: record,
		),
	};
}

function requireInstalledFileView(state: {
	readonly installed: BridgeProductInstalledFileView | null;
}): BridgeProductInstalledFileView {
	if (state.installed === null) throw new Error('File bank was not installed.');
	return state.installed;
}

import { describe, expect, test } from 'vitest';

import fileCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { applyBridgeCommWorkerFileBatchToRuntime } from './bridge-comm-worker-file-batch-runtime-application.js';
import { BridgeCommWorkerFileDisplayEventAuthority } from './bridge-comm-worker-file-display-event-authority.js';
import { BridgeCommWorkerFileQueryProjection } from './bridge-comm-worker-file-query-projection.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { installBridgeProductFileBatch } from './bridge-product-file-batch-installer.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';

describe('certified File batch runtime application', () => {
	test('publishes the complete tree and runtime source from one certified bank', () => {
		const fixture = sessionCorpus.transportV2.batchFrames[0];
		const begin = bridgeProductBatchFrameSchema.parse({
			...fixture,
			publicationId: undefined,
			scope: { kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] },
			subscriptionKind: 'file.metadata',
			targetRevision: 4,
		});
		if (begin.kind !== 'subscription.batchBegin') throw new Error('Expected File batch begin.');
		const view = installBridgeProductFileBatch({
			certified: true,
			staleRecords: [],
			begin,
			domain: 'default',
			records: [
				...fileCorpus.rows.map(({ recordKey, row }) => ({
					key: recordKey,
					revision: 1,
					value: row,
				})),
				{ key: 'member-status', revision: 1, value: fileCorpus.memberStatuses[0]?.record },
			],
		});
		const messages: BridgeWorkerServerToMainMessage[] = [];
		const mutations: string[] = [];
		applyBridgeCommWorkerFileBatchToRuntime({
			applyRuntimeMutation: (mutation) => {
				mutations.push(mutation.kind);
				return [];
			},
			displayAuthority: new BridgeCommWorkerFileDisplayEventAuthority({ createSequence: () => 1 }),
			epoch: 3,
			publishMessage: (message): void => {
				messages.push(message);
			},
			queryProjection: new BridgeCommWorkerFileQueryProjection(),
			view,
		});
		expect(mutations).toEqual(['reset']);
		const displayEvents = messages.filter((message) => message.kind === 'fileDisplayPatch');
		expect(displayEvents.length).toBeGreaterThan(0);
		expect(
			displayEvents
				.flatMap((event) => event.patches)
				.some((patch) => patch.slice === 'fileTree' && patch.operation === 'replacementCommit'),
		).toBe(true);
		expect(
			displayEvents
				.flatMap((event) => event.patches)
				.some((patch) => patch.slice === 'fileTree' && patch.operation === 'batch'),
		).toBe(true);
	});
});

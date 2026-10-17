import { describe, expect, test } from 'vitest';

import {
	type BridgeCommWorkerPort,
	createBridgeCommWorkerScopePortAdapter,
	postPreparedBridgeCommWorkerMessage,
} from './bridge-comm-worker-entry.js';
import {
	makeFetchedReviewContentResource,
	makeReviewPublicationIdentity,
	makeRenderSemantics,
} from './bridge-comm-worker-entry.test-support.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';
import { makeBridgeWorkerRenderReceiptIdentity } from './bridge-worker-render-fulfillment.test-support.js';
import { prepareBridgeWorkerReviewContentRenderJobEvent } from './bridge-worker-review-content-ready.js';

interface PostedBridgeWorkerMessage {
	readonly message: BridgeWorkerServerToMainMessage;
	readonly transferList: readonly Transferable[] | undefined;
}

function assertPreparedEntryPostRejectsSyntheticMessages(port: BridgeCommWorkerPort): void {
	const syntheticPreparedMessage = {
		message: { kind: 'pierreRenderJob', transferDescriptors: [] },
		transferList: [],
	};
	// @ts-expect-error Entry posting accepts only schema-derived server-to-main worker DTOs.
	postPreparedBridgeCommWorkerMessage(port, syntheticPreparedMessage);
}

function assertBrowserMessagePortMatchesEntryPort(port: MessagePort): BridgeCommWorkerPort {
	return port;
}

describe('Bridge comm worker prepared messages', () => {
	test('posts prepared review content-ready worker messages as structured CodeView payloads', () => {
		const postedMessages: PostedBridgeWorkerMessage[] = [];
		const port: BridgeCommWorkerPort = {
			postMessage: (
				message: BridgeWorkerServerToMainMessage,
				transferList?: Transferable[],
			): void => {
				postedMessages.push({ message, transferList });
			},
			addEventListener: (): void => {},
		};
		const preparedMessage = prepareBridgeWorkerReviewContentRenderJobEvent({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			publicationSequence: 1,
			renderReceiptIdentity: makeBridgeWorkerRenderReceiptIdentity({
				itemId: 'item-1',
				publicationSequence: 1,
				surface: 'review',
				workerDerivationEpoch: 1,
			}),
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			resources: [
				makeFetchedReviewContentResource({
					contentHash: 'sha256:item-1:base',
					role: 'base',
					text: 'base content\n',
				}),
				makeFetchedReviewContentResource({
					contentHash: 'sha256:item-1:head',
					role: 'head',
					text: 'head content\n',
				}),
			],
			semantics: makeRenderSemantics(),
			workerDerivationEpoch: 1,
		});
		if (preparedMessage === null) throw new Error('Expected review content-ready render job.');

		postPreparedBridgeCommWorkerMessage(port, preparedMessage);

		expect(postedMessages).toEqual([{ message: preparedMessage.message, transferList: [] }]);
		expect(postedMessages[0]?.transferList).not.toBe(preparedMessage.transferList);
		expect(preparedMessage.message.job.payload.kind).toBe('codeViewDiffItem');
		expect(preparedMessage.message.transferDescriptors).toEqual([
			{
				messageKind: 'reviewPierreRenderJob',
				fieldPath: ['job', 'payload'],
				byteLength: preparedMessage.message.job.payloadByteLength,
				mode: 'clone',
			},
		]);
		expect(typeof assertPreparedEntryPostRejectsSyntheticMessages).toBe('function');
		expect(typeof assertBrowserMessagePortMatchesEntryPort).toBe('function');
	});

	test('forwards structured prepared messages through the worker scope adapter', () => {
		const postedMessages: PostedBridgeWorkerMessage[] = [];
		const scope = {
			postMessage: (
				message: BridgeWorkerServerToMainMessage,
				transferList?: Transferable[],
			): void => {
				postedMessages.push({ message, transferList });
			},
			addEventListener: (): void => {},
		};
		const preparedMessage = prepareBridgeWorkerReviewContentRenderJobEvent({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			publicationSequence: 1,
			renderReceiptIdentity: makeBridgeWorkerRenderReceiptIdentity({
				itemId: 'item-1',
				publicationSequence: 1,
				surface: 'review',
				workerDerivationEpoch: 1,
			}),
			reviewPublicationIdentity: makeReviewPublicationIdentity(),
			resources: [
				makeFetchedReviewContentResource({
					contentHash: 'sha256:item-1:file',
					role: 'file',
					text: 'file content\n',
				}),
			],
			semantics: makeRenderSemantics({
				changeKind: 'modified',
				contentLineCountsByRole: { file: 80 },
				itemKind: 'file',
			}),
			workerDerivationEpoch: 1,
		});
		if (preparedMessage === null) throw new Error('Expected review content-ready render job.');

		postPreparedBridgeCommWorkerMessage(
			createBridgeCommWorkerScopePortAdapter(scope),
			preparedMessage,
		);

		expect(postedMessages).toEqual([{ message: preparedMessage.message, transferList: [] }]);
		expect(preparedMessage.message.job.payload.kind).toBe('codeViewFileItem');
		expect(preparedMessage.message.transferDescriptors).toEqual([
			{
				messageKind: 'reviewPierreRenderJob',
				fieldPath: ['job', 'payload'],
				byteLength: preparedMessage.message.job.payloadByteLength,
				mode: 'clone',
			},
		]);
	});
});

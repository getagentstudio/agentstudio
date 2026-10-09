import { describe, expect, it } from 'vitest';

import corpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-retained-minter-corpus.json' with { type: 'json' };
import {
	bridgeProductBatchFrameSchema,
	type BridgeProductBatchFrame,
} from './bridge-product-batch-wire-contracts.js';
import { BridgeProductViewBatchReceiver } from './bridge-product-view-batch-receiver.js';

type NativeCapture = typeof corpus.coverage | typeof corpus.certificate;

const scope = {
	kind: 'file',
	changeFilter: { kind: 'none' },
	pathScope: [],
	interests: [],
} satisfies Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>['scope'];
const identity = {
	domain: 'default',
	handle: 'file-view-handle-1',
	incarnation: 'file-incarnation',
	metadataStreamId: 'retained-minter-stream',
	paneSessionId: 'retained-minter-pane',
	scopeRevision: 1,
	subscriptionId: 'file-subscription-1',
	subscriptionKind: 'file.metadata',
	wireVersion: 2,
	workerInstanceId: 'retained-minter-worker',
};

function replayFrames(capture: NativeCapture, batchId: string): readonly BridgeProductBatchFrame[] {
	const begin = bridgeProductBatchFrameSchema.parse({
		...identity,
		batchId,
		baseRevision: 0,
		kind: 'subscription.batchBegin',
		mode: capture.mode,
		partCount: capture.parts.length,
		scope,
		streamSequence: batchId === 'coverage' ? 1 : 101,
		targetRevision: capture.targetRevision,
	});
	const parts = capture.parts.map(
		(part, partIndex): BridgeProductBatchFrame =>
			bridgeProductBatchFrameSchema.parse({
				...identity,
				batchId,
				deliverySequence:
					(batchId === 'coverage' ? 0 : corpus.coverage.parts.length) + partIndex + 1,
				kind: 'subscription.batchPart',
				part,
				partIndex,
				streamSequence: (batchId === 'coverage' ? 2 : 102) + partIndex,
			}),
	);
	const complete = bridgeProductBatchFrameSchema.parse({
		...identity,
		batchId,
		coveredScope: scope,
		kind: 'subscription.batchComplete',
		streamSequence: (batchId === 'coverage' ? 2 : 102) + parts.length,
	});
	return [begin, ...parts, complete];
}

describe('native File retained-minter replay', (): void => {
	it('installs smaller Retry inventory on the retained handle and prunes old coverage', (): void => {
		const receiver = new BridgeProductViewBatchReceiver({
			handle: identity.handle,
			scope,
			scopeRevision: identity.scopeRevision,
			subscriptionId: identity.subscriptionId,
			subscriptionKind: 'file.metadata',
		});
		receiver.admitDomain(identity.domain, identity.incarnation);
		for (const frame of replayFrames(corpus.coverage, 'coverage')) receiver.accept(frame);
		const coverage = receiver.takeInstallations();
		expect(coverage).toHaveLength(1);
		expect(coverage[0]?.certified).toBe(false);
		expect(coverage[0]?.records).toHaveLength(corpus.coverage.parts.length);

		// This is the same receiver, domain, incarnation and handle. There is no
		// replaceHandle, bank clear or new E3 to conceal a regressed native floor.
		const [begin, ...following] = replayFrames(corpus.certificate, 'certificate');
		if (begin === undefined) throw new Error('Expected a native certificate begin.');
		expect(receiver.accept(begin)).toEqual({ kind: 'staged' });
		for (const frame of following) receiver.accept(frame);
		const repaired = receiver.takeInstallations();
		expect(repaired).toHaveLength(1);
		expect(repaired[0]?.certified).toBe(true);
		expect(repaired[0]?.begin.targetRevision).toBeGreaterThan(corpus.coverage.targetRevision);
		const expectedRecords = corpus.certificate.parts.map((part) => ({
			key: part.key,
			revision: part.revision,
			value: part.value,
		}));
		expect(repaired[0]?.records).toEqual(expectedRecords);
		expect(receiver.cursor(identity.domain)).toBe(corpus.certificate.targetRevision);
		expect(repaired[0]?.staleRecords).toEqual([]);
		expect(repaired[0]?.records).toHaveLength(2); // One row and the member status.
	});
});

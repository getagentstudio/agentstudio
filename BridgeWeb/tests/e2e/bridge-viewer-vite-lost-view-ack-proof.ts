import type { Page, Request } from 'playwright';
import { expect } from 'vitest';

import { bridgeProductViewResnapshotRequestSchema } from '../../src/core/comm-worker/bridge-product-view-control-wire-contracts.js';
import { BridgeProductTestFactRecorder } from '../../src/core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';
import type { MetadataFrameObservation } from './bridge-viewer-vite-metadata-frame-observation.ts';
import type { BridgeStreamFaultProxy } from './bridge-viewer-vite-stream-fault-proxy.ts';

interface ScopedResnapshotObservation {
	readonly domain: string;
	readonly frameCountAtRequest: number;
	readonly subscriptionId: string;
}

interface LostViewAckProofProps {
	readonly metadataFrames: MetadataFrameObservation;
	readonly mutateReviewFile: () => Promise<{ readonly path: string }>;
	readonly page: Page;
	readonly proxy: BridgeStreamFaultProxy;
	readonly waitForUpdatedReview: (props: {
		readonly path: string;
		readonly priorRevision: number;
	}) => Promise<void>;
}

/** The live fault drops only a reply: native already consumed the original cumulative ACK. */
export async function proveLostViewAcknowledgement(props: LostViewAckProofProps): Promise<void> {
	const primary = props.metadataFrames.frames.findLast(
		(frame) =>
			frame.kind === 'subscription.batchBegin' && frame.subscriptionKind === 'review.metadata',
	);
	const sibling = props.metadataFrames.frames.findLast(
		(frame) =>
			frame.kind === 'subscription.batchBegin' && frame.subscriptionKind === 'file.metadata',
	);
	if (primary?.kind !== 'subscription.batchBegin' || sibling?.kind !== 'subscription.batchBegin')
		throw new Error('Lost-ACK proof requires installed Review and File views.');
	const streamCount = props.proxy.snapshot().metadataRequestCount;
	const startingAt = props.metadataFrames.frames.length;
	const priorRevision = Number(
		await props.page
			.getByTestId('review-viewer-shell')
			.getAttribute('data-review-metadata-revision'),
	);
	const resnapshots = new BridgeProductTestFactRecorder<ScopedResnapshotObservation>();
	const observeRequest = (request: Request): void => {
		if (request.method() !== 'POST') return;
		let body: unknown;
		try {
			body = JSON.parse(request.postData() ?? 'null');
		} catch {
			return;
		}
		const parsed = bridgeProductViewResnapshotRequestSchema.safeParse(body);
		if (!parsed.success) return;
		resnapshots.record({
			domain: parsed.data.domain,
			frameCountAtRequest: props.metadataFrames.frames.length,
			subscriptionId: parsed.data.subscriptionId,
		});
	};
	props.page.on('request', observeRequest);
	try {
		const lostReply = props.proxy.loseNextViewAcknowledgement(primary.subscriptionId);
		const recovery = Promise.race([
			lostReply.then((observation) => ({ kind: 'exactReplay' as const, observation })),
			resnapshots
				.waitFor((observation): boolean => observation.subscriptionId === primary.subscriptionId)
				.then((observation) => ({ kind: 'scopedResnapshot' as const, observation })),
		]);
		const mutation = await props.mutateReviewFile();
		const recovered = await recovery;
		expect(recovered.observation.subscriptionId).toBe(primary.subscriptionId);
		expect(recovered.observation.domain).toBe(primary.domain);
		if (recovered.kind === 'exactReplay') {
			expect(recovered.observation.exactReplayObserved).toBe(true);
			expect(recovered.observation.receivedThroughDeliverySequence).toBeGreaterThan(0);
		} else {
			const replacement = await props.metadataFrames.waitFor(
				(frame): boolean =>
					frame.kind === 'subscription.batchBegin' &&
					frame.subscriptionId === primary.subscriptionId &&
					frame.domain === primary.domain &&
					frame.mode === 'snapshot',
				recovered.observation.frameCountAtRequest,
			);
			if (replacement.kind !== 'subscription.batchBegin')
				throw new Error('Lost ACK recovery did not produce a scoped snapshot.');
			await props.proxy.waitForBatchComplete(replacement.batchId);
		}
		await props.waitForUpdatedReview({ path: mutation.path, priorRevision });
		const siblingComplete = await props.metadataFrames.waitFor(
			(frame): boolean =>
				frame.kind === 'subscription.batchComplete' &&
				frame.subscriptionId === sibling.subscriptionId,
			startingAt,
		);
		expect('subscriptionId' in siblingComplete && siblingComplete.subscriptionId).toBe(
			sibling.subscriptionId,
		);
		const afterFault = props.metadataFrames.frames.slice(startingAt);
		expect(
			afterFault.some(
				(frame) =>
					'subscriptionId' in frame &&
					frame.subscriptionId === sibling.subscriptionId &&
					(frame.kind === 'subscription.reset' ||
						frame.kind === 'subscription.end' ||
						frame.kind === 'subscription.cancelled'),
			),
		).toBe(false);
		expect(
			afterFault
				.filter(
					(frame) =>
						frame.kind === 'subscription.batchBegin' &&
						frame.subscriptionId === sibling.subscriptionId,
				)
				.every(
					(frame) => frame.kind === 'subscription.batchBegin' && frame.handle === sibling.handle,
				),
		).toBe(true);
		expect(props.proxy.snapshot().metadataRequestCount).toBe(streamCount);
		expect(props.proxy.snapshot().activeMetadataResponses).toBe(1);
		expect(props.proxy.snapshot().semanticMetadataClosures).toEqual([]);
	} finally {
		props.page.off('request', observeRequest);
		resnapshots.close(new Error('lost view ACK proof closed'));
	}
}

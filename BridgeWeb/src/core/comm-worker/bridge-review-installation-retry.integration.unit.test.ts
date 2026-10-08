import { afterEach, describe, expect, test, vi } from 'vitest';

import reviewCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import { BridgeCommWorkerProductBatchApplication } from './bridge-comm-worker-product-batch-application.js';
import { bridgeCommWorkerReviewDisplayPatchesFromBatch } from './bridge-comm-worker-review-batch-display.js';
import { createBridgeMainRenderSnapshotStore } from './bridge-main-render-snapshot-store.js';
import type { BridgeMainReviewPublicationIdentity } from './bridge-main-review-candidate-bank.js';
import { createBridgeMainReviewPresentationInstallationGate } from './bridge-main-review-presentation-installation-gate.js';
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import { bridgeProductReviewMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import type { BridgeProductMetadataStreamRequest } from './bridge-product-session-contracts.js';
import { bridgeWorkerReviewDisplayPatchEventSchema } from './bridge-worker-contracts.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	metadataAccepted,
	requestErrorResponse,
	subscriptionAccepted,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async (): Promise<void> => {
	try {
		await disposeTransportHarnesses();
	} finally {
		vi.unstubAllGlobals();
	}
});

describe('Review installation failure and unchanged-publication Retry through real transport', () => {
	test('W4 certifies B, admission throws, then same-E3 Retry reoffers B and completes INST', async () => {
		const harness = createTransportHarness({
			deadlineClock: { schedule: (): (() => void) => (): void => {} },
		});
		const store = createBridgeMainRenderSnapshotStore();
		let admissionCount = 0;
		let failedAdmissionRequestId: string | null = null;
		harness.server.productCallHandler = (request): Response => {
			if (request.call.method === 'review.publication.install.admit') {
				failedAdmissionRequestId ??= request.requestId;
				if (request.requestId === failedAdmissionRequestId)
					return requestErrorResponse(request, 'internal');
			}
			return new Response(
				JSON.stringify({
					kind: 'call.completed',
					paneSessionId: request.paneSessionId,
					requestId: request.requestId,
					requestSequence: request.requestSequence,
					wireVersion: request.wireVersion,
					workerInstanceId: request.workerInstanceId,
					call: {
						method: request.call.method,
						result:
							request.call.method === 'review.publication.install.admit'
								? { status: 'admitted' }
								: null,
					},
				}),
				{ headers: { 'Content-Type': 'application/json' } },
			);
		};
		const receipts: BridgeMainReviewPublicationIdentity[] = [];
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: {
				requestWorkerReplacement: (): void => {
					throw new Error('Unexpected replacement.');
				},
				requestInstallAdmission: async (request) => {
					admissionCount += 1;
					return {
						...(await harness.transport.call('review.publication.install.admit', request)),
						candidatePublicationId: request.candidatePublicationId,
					};
				},
				sendInstalledReceipt: async (publication): Promise<void> => {
					await harness.transport.call('review.publication.applied', {
						publicationId: publication.publicationId,
					});
					receipts.push(publication);
				},
			},
			prepareActiveEditorsForInstallation: (): Promise<boolean> => Promise.resolve(true),
			store,
		});
		const offers = [createBridgeProductDeferred<void>(), createBridgeProductDeferred<void>()];
		let offerCount = 0;
		let sequence = 0;
		let installation: Promise<void> = Promise.resolve();
		const application = new BridgeCommWorkerProductBatchApplication({
			applyComment: (): void => {
				throw new Error('Unexpected Comment batch.');
			},
			applyFile: (): void => {
				throw new Error('Unexpected File batch.');
			},
			applyReview: (presentation): void => {
				const source = presentation.runtimeSource.reviewPublicationIdentity;
				if (source === null) throw new Error('Complete publication missing identity.');
				expect(
					store.stageReviewCandidateDisplayEvent({
						identity: { ...source, generation: source.reviewGeneration },
						event: bridgeWorkerReviewDisplayPatchEventSchema.parse({
							direction: 'serverWorkerToMain',
							epoch: 1,
							kind: 'reviewDisplayPatch',
							patches: bridgeCommWorkerReviewDisplayPatchesFromBatch(presentation),
							projectionRevision: ++sequence,
							reviewPublicationIdentity: source,
							sequence,
							surface: 'review',
							transferDescriptors: [],
							wireVersion: 1,
						}),
					}),
				).toBe(true);
			},
			createSequence: (): number => ++sequence,
			publishMessage: (message): void => {
				if (message.kind === 'reviewCandidateStarted')
					expect(
						store.startReviewCandidate({
							disposition: message.disposition,
							identity: {
								generation: message.reviewGeneration,
								packageId: message.packageId,
								publicationId: message.publicationId,
								revision: message.revision,
								sourceIdentity: message.sourceIdentity,
							},
						}),
					).toBe(true);
				else if (message.kind === 'reviewCandidateReady') {
					installation = gate.handleCandidateReady(message, {
						activeEditorStableFileIdentities: [],
						stableFileIdentities: [],
					});
					offerCount += 1;
					offers[offerCount - 1]?.resolve();
				} else throw new Error('Unexpected candidate source failure.');
			},
			publishReviewDisplay: (): void => {
				throw new Error('Unexpected recovery exposure.');
			},
			requestResnapshot: (): void => {
				throw new Error('Unexpected malformed bank.');
			},
			requestResnapshotLatest: (): void => {
				throw new Error('Unexpected malformed bank.');
			},
			workerDerivationEpoch: (): number => 1,
		});
		harness.transport.setBatchFrameSinks?.(application.sinks());
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		try {
			const stream = await harness.server.waitForMetadataStreamOpened();
			harness.server.emitMetadata(metadataAccepted(stream, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'review.metadata',
					request: stream,
					streamSequence: 1,
					subscriptionId: subscription.subscriptionId,
				}),
			);
			const scope = await harness.server.waitForControlRequest('subscription.setScope');
			if (scope.kind !== 'subscription.setScope') throw new Error('Expected Review scope.');
			const publication = bridgeProductReviewBatchRecordSchema.parse(
				reviewCorpus.records[2]?.record,
			);
			if (publication.recordKind !== 'publication' || publication.displayed === null)
				throw new Error('Complete publication fixture missing.');
			const publicationId = publication.displayed.publicationId;
			const emitSnapshot = (targetRevision: number): void =>
				emitSamePublicationSnapshot({
					stream,
					publicationId,
					targetRevision,
					publication: {
						...publication,
						desired: { ...publication.desired, status: 'ready' },
						displayed: publication.displayed,
						publicationId,
						revision: targetRevision,
					},
					scope,
					emit: (frame): void => harness.server.emitMetadata(frame),
				});
			emitSnapshot(1);
			await offers[0]?.promise;
			await installation;
			expect(offerCount).toBe(1);
			expect(store.getReviewRefreshPresentation().failure).toMatchObject({
				identity: { publicationId },
				kind: 'installation',
				retryable: true,
			});
			expect(receipts).toEqual([]);
			await harness.transport.retryView?.(subscription.subscriptionId);
			await harness.server.waitForControlRequest('subscription.resnapshot');
			expect(store.getReviewRefreshPresentation().failure).not.toBeNull();
			emitSnapshot(2);
			await offers[1]?.promise;
			await installation;
			expect(offerCount).toBe(2);
			expect(store.getReviewRefreshPresentation()).toMatchObject({
				activeIdentity: { publicationId },
				candidate: null,
				failure: null,
			});
			expect(receipts.map((receipt) => receipt.publicationId)).toEqual([publicationId]);
			expect(admissionCount).toBe(2);
			expect(
				harness.server.controlRequests.filter((request) => request.kind === 'subscription.open'),
			).toHaveLength(1);
		} finally {
			gate.close();
			await subscription.cancel();
		}
	});
});

function emitSamePublicationSnapshot(props: {
	readonly stream: BridgeProductMetadataStreamRequest;
	readonly scope: Extract<
		import('./bridge-product-session-contracts.js').BridgeProductControlRequest,
		{ kind: 'subscription.setScope' }
	>;
	readonly publicationId: string;
	readonly targetRevision: number;
	readonly publication: import('./bridge-product-review-batch-record-contracts.js').BridgeProductReviewBatchRecord;
	readonly emit: (
		frame: import('./bridge-product-session-contracts.js').BridgeProductMetadataFrame,
	) => void;
}): void {
	const identity = {
		wireVersion: 2 as const,
		paneSessionId: props.stream.paneSessionId,
		workerInstanceId: props.stream.workerInstanceId,
		metadataStreamId: props.stream.metadataStreamId,
		subscriptionId: props.scope.subscriptionId,
		subscriptionKind: 'review.metadata' as const,
		domain: props.scope.domain,
		handle: props.scope.handle,
		incarnation: props.scope.incarnation,
		scopeRevision: props.scope.scopeRevision,
		batchId: `retry-batch-${props.targetRevision}`,
	};
	const streamSequence = 2 + (props.targetRevision - 1) * 3;
	props.emit({
		...identity,
		kind: 'subscription.batchBegin',
		streamSequence,
		mode: 'snapshot',
		snapshotCause: 'open',
		baseRevision: 0,
		targetRevision: props.targetRevision,
		partCount: 1,
		publicationId: props.publicationId,
		scope: props.scope.scope,
	});
	props.emit({
		...identity,
		kind: 'subscription.batchPart',
		streamSequence: streamSequence + 1,
		deliverySequence: props.targetRevision,
		partIndex: 0,
		part: {
			operation: 'put',
			key: 'publication',
			revision: props.targetRevision,
			value: props.publication,
		},
	});
	props.emit({
		...identity,
		kind: 'subscription.batchComplete',
		streamSequence: streamSequence + 2,
		coveredScope: props.scope.scope,
	});
}

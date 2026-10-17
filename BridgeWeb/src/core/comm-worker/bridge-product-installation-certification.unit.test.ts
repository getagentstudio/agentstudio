import { describe, expect, test } from 'vitest';

import { BridgeCommWorkerFileDisplayEventAuthority } from './bridge-comm-worker-file-display-event-authority.js';
import { BridgeCommWorkerFileQueryProjection } from './bridge-comm-worker-file-query-projection.js';
import { installBridgeCommWorkerProductBatchRuntime } from './bridge-comm-worker-product-batch-runtime-install.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import type { BridgeProductBatchFrame } from './bridge-product-batch-wire-contracts.js';
import { BridgeProductViewBatchReceiver } from './bridge-product-view-batch-receiver.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import {
	makeFileBatchInstallation,
	makeFileProductTestTransport,
} from './comm-runtime-protocol.file-product.test-support.js';

type BatchBegin = Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>;

describe('W4 installation certification carried to the File runtime', () => {
	test.each(['snapshot', 'coverage', 'change'] as const)(
		'%s carries its certification through the typed application and runtime callback',
		async (mode) => {
			const fixture = makeFileBatchInstallation('open', 'certification-subscription');
			const receiver = new BridgeProductViewBatchReceiver({
				handle: fixture.begin.handle,
				scope: fixture.begin.scope,
				scopeRevision: fixture.begin.scopeRevision,
				subscriptionId: fixture.begin.subscriptionId,
				subscriptionKind: fixture.begin.subscriptionKind,
			});
			receiver.admitDomain(fixture.domain, fixture.begin.incarnation);
			const installedCertifications: boolean[] = [];
			let sequence = 0;
			const application = installBridgeCommWorkerProductBatchRuntime({
				applyCommentCatalog: (): void => {},
				applyFileRuntimeMutation: () => [],
				beforeApplyFile: (): void => {},
				createSequence: (): number => ++sequence,
				didInstallFile: (_view, _begin, certified): void => {
					installedCertifications.push(certified);
				},
				didInstallReview: (): void => {},
				fileDisplayAuthority: new BridgeCommWorkerFileDisplayEventAuthority({
					createSequence: (): number => ++sequence,
				}),
				fileQueryProjection: new BridgeCommWorkerFileQueryProjection(),
				prepareReviewRuntimeApplication: () => {
					throw new Error('File installation must not enter Review application.');
				},
				productTransport: makeFileProductTestTransport({
					onDiscoverSource: (): void => {},
					onOpenDescriptor: (): void => {},
					subscription: {
						cancel: async (): Promise<void> => {},
						events: new BridgeProductBoundedAsyncQueue<never>(16),
						subscriptionId: fixture.begin.subscriptionId,
						subscriptionKind: 'file.metadata',
					},
				}),
				publishMessage: (): void => {},
				publishReviewDisplay: (): void => {},
				reportResnapshotFailure: (): void => {
					throw new Error('Certification fixture must install without recovery.');
				},
				reportReviewPostCommitFailure: (): void => {},
			});
			let streamSequence = 0;
			let deliverySequence = 0;
			const install = async (begin: BatchBegin): Promise<void> => {
				const identity = {
					batchId: begin.batchId,
					domain: fixture.domain,
					handle: begin.handle,
					incarnation: begin.incarnation,
					metadataStreamId: begin.metadataStreamId,
					paneSessionId: begin.paneSessionId,
					scopeRevision: begin.scopeRevision,
					subscriptionId: begin.subscriptionId,
					subscriptionKind: begin.subscriptionKind,
					wireVersion: begin.wireVersion,
					workerInstanceId: begin.workerInstanceId,
				};
				const sinks: BridgeProductBatchFrameSinks = application.sinks();
				receiver.accept({ ...begin, streamSequence: ++streamSequence });
				for (const [partIndex, record] of fixture.records.entries()) {
					receiver.accept({
						...identity,
						deliverySequence: ++deliverySequence,
						kind: 'subscription.batchPart',
						part: {
							key: record.key,
							operation: 'put',
							revision: begin.targetRevision,
							value: record.value,
						},
						partIndex,
						streamSequence: ++streamSequence,
					});
				}
				expect(
					receiver.accept(
						{
							...identity,
							coveredScope: begin.scope,
							kind: 'subscription.batchComplete',
							streamSequence: ++streamSequence,
						},
						sinks.verify,
					).kind,
				).toBe('installed');
				const installation: BridgeProductViewInstallation | undefined =
					receiver.takeInstallations()[0];
				if (installation === undefined) throw new Error('W4 installation missing.');
				await sinks.install(installation);
			};
			await install({
				...fixture.begin,
				mode: 'snapshot',
				snapshotCause: 'open',
				partCount: fixture.records.length,
			});
			await install({
				...fixture.begin,
				baseRevision: fixture.begin.targetRevision,
				batchId: 'certification-successor',
				mode,
				partCount: fixture.records.length,
				targetRevision: fixture.begin.targetRevision + 1,
			});
			expect(installedCertifications).toEqual([true, mode !== 'coverage']);
		},
	);
});

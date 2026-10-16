import { describe, expect, test } from 'vitest';

import reviewCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { BridgeCommWorkerProductBatchApplication } from './bridge-comm-worker-product-batch-application.js';
import { bridgeCommWorkerReviewDisplayPatchesFromBatch } from './bridge-comm-worker-review-batch-display.js';
import { createBridgeMainRenderSnapshotStore } from './bridge-main-render-snapshot-store.js';
import type { BridgeMainReviewPublicationIdentity } from './bridge-main-review-candidate-bank.js';
import {
	createBridgeMainReviewPresentationInstallationGate,
	type BridgeMainReviewInstallAdmissionRequest,
	type BridgeMainReviewSemanticAttention,
} from './bridge-main-review-presentation-installation-gate.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import {
	BridgeProductViewBatchReceiver,
	type BridgeProductViewInstallation,
} from './bridge-product-view-batch-receiver.js';
import { bridgeWorkerReviewDisplayPatchEventSchema } from './bridge-worker-contracts.js';

describe('empty Review publication through batch application, candidate bank and INST', () => {
	test('first empty comparison completes INST without content, render or paint', async () => {
		const fixture = installationFixture();
		try {
			await fixture.install(publicationInstallation(1, false));
			expect(fixture.requests).toEqual([
				{ candidatePublicationId: publicationId(1), expectedDisplayedPublicationId: null },
			]);
			expect(fixture.receipts).toHaveLength(1);
			expect(fixture.receipts[0]).toMatchObject({ publicationId: publicationId(1) });
			expectEmptyInstalled(fixture);
		} finally {
			fixture.close();
		}
	});

	test('empty and nonempty comparisons replace each other through ordinary INST', async () => {
		const fixture = installationFixture();
		try {
			await fixture.install(publicationInstallation(1, false));
			expectEmptyInstalled(fixture);
			await fixture.install(publicationInstallation(2, true));
			expect(fixture.store.getSnapshot().reviewItemIdsByIndex).toEqual(['review-item-1']);
			await fixture.install(publicationInstallation(3, false));
			expectEmptyInstalled(fixture);
			expect(fixture.receipts.map((receipt) => receipt.publicationId)).toEqual([
				publicationId(1),
				publicationId(2),
				publicationId(3),
			]);
		} finally {
			fixture.close();
		}
	});

	test('protected editor on A keeps empty B pending until editor continuity permits installation', async () => {
		const fixture = installationFixture();
		try {
			await fixture.install(publicationInstallation(1, true));
			fixture.setEditorProtected(true);
			await fixture.install(publicationInstallation(2, false));
			expect(fixture.store.getSnapshot().reviewItemIdsByIndex).toEqual(['review-item-1']);
			expect(fixture.store.getReviewRefreshPresentation()).toMatchObject({
				activeIdentity: { publicationId: publicationId(1) },
				candidate: { identity: { publicationId: publicationId(2) }, role: 'updateReady' },
			});
			expect(fixture.receipts).toHaveLength(1);
			fixture.setEditorProtected(false);
			await fixture.releaseAttention();
			expectEmptyInstalled(fixture);
			expect(fixture.receipts).toHaveLength(2);
		} finally {
			fixture.close();
		}
	});

	test('A to empty B to main keeps exact install admission and receipt lineage', async () => {
		const fixture = installationFixture();
		try {
			await fixture.install(publicationInstallation(1, true, 'A'));
			await fixture.install(publicationInstallation(2, false, 'B'));
			expectEmptyInstalled(fixture);
			await fixture.install(publicationInstallation(3, true, 'main'));
			expect(fixture.requests.map((request) => request.expectedDisplayedPublicationId)).toEqual([
				null,
				publicationId(1),
				publicationId(2),
			]);
			expect(fixture.store.getSnapshot().panelChromeSlice.reviewComparison?.activeTarget).toEqual({
				basis: 'commonCommit',
				kind: 'branch',
				name: 'main',
			});
			expect(fixture.store.getReviewRefreshPresentation().activeIdentity?.publicationId).toBe(
				publicationId(3),
			);
		} finally {
			fixture.close();
		}
	});
});

function publicationId(revision: number): string {
	return `00000000-0000-7000-8000-${String(revision).padStart(12, '0')}`;
}

function publicationInstallation(
	revision: number,
	hasItem: boolean,
	target = 'main',
): BridgeProductViewInstallation {
	const source = bridgeProductReviewBatchRecordSchema.parse(reviewCorpus.records[2]?.record);
	const item = bridgeProductReviewBatchRecordSchema.parse(reviewCorpus.records[0]?.record);
	if (
		source.recordKind !== 'publication' ||
		source.displayed === null ||
		item.recordKind !== 'item'
	)
		throw new Error('Complete Review fixture is missing.');
	const comparison = {
		...source.desired.reviewComparison,
		activeTarget: { basis: 'commonCommit', kind: 'branch', name: target },
		attempt: { status: 'settled', reviewGeneration: source.displayed.generation },
		displayedSnapshot: {
			packageId: source.displayed.packageId,
			reviewGeneration: source.displayed.generation,
			revision,
			status: 'current',
		},
		repositoryDefaultTarget: null,
	};
	const publication = bridgeProductReviewBatchRecordSchema.parse({
		...source,
		classifiedRefreshImpact: {
			addedLineCount: 0,
			affectedFileCount: 1,
			affectedStableFileIdentities: ['review-item-1'],
			deletedLineCount: 0,
			newlyImportedCommitCount: 0,
			preDeliveryPresentationClass: { kind: 'ordinary' },
		},
		desired: { reviewComparison: comparison, status: 'ready' },
		displayed: {
			...source.displayed,
			publicationId: publicationId(revision),
			revision,
			reviewComparison: comparison,
			summary: {
				additions: hasItem ? 3 : 0,
				deletions: 0,
				filesChanged: hasItem ? 1 : 0,
				hiddenFileCount: 0,
				visibleFileCount: hasItem ? 1 : 0,
			},
		},
		publicationId: publicationId(revision),
		revision,
	});
	const begin = bridgeProductBatchFrameSchema.parse({
		...sessionCorpus.transportV2.batchFrames[0],
		publicationId: publicationId(revision),
		targetRevision: revision,
	});
	if (begin.kind !== 'subscription.batchBegin') throw new Error('Review begin fixture is missing.');
	return {
		begin,
		certified: true,
		staleRecords: [],
		domain: 'default',
		records: [
			...(hasItem ? [{ key: item.itemId, revision, value: item }] : []),
			{ key: 'publication', revision, value: publication },
		],
	};
}

function installationFixture(): {
	readonly close: () => void;
	readonly install: (installation: BridgeProductViewInstallation) => Promise<void>;
	readonly receipts: BridgeMainReviewPublicationIdentity[];
	readonly releaseAttention: () => Promise<void>;
	readonly requests: BridgeMainReviewInstallAdmissionRequest[];
	readonly setEditorProtected: (isProtected: boolean) => void;
	readonly store: ReturnType<typeof createBridgeMainRenderSnapshotStore>;
} {
	const store = createBridgeMainRenderSnapshotStore();
	const receipts: BridgeMainReviewPublicationIdentity[] = [];
	const requests: BridgeMainReviewInstallAdmissionRequest[] = [];
	let editorProtected = false;
	let sequence = 0;
	let installationWork: Promise<void> = Promise.resolve();
	const attention = (): BridgeMainReviewSemanticAttention => ({
		activeEditorStableFileIdentities: editorProtected ? ['review-item-1'] : [],
		stableFileIdentities: [],
	});
	const gate = createBridgeMainReviewPresentationInstallationGate({
		installationPort: {
			requestWorkerReplacement: (): void => {
				throw new Error('Unexpected worker replacement.');
			},
			requestInstallAdmission: (
				request,
			): Promise<{ candidatePublicationId: string; status: 'admitted' }> => {
				requests.push(request);
				return Promise.resolve({
					candidatePublicationId: request.candidatePublicationId,
					status: 'admitted',
				});
			},
			sendInstalledReceipt: (identity): Promise<void> => {
				receipts.push(identity);
				return Promise.resolve();
			},
		},
		prepareActiveEditorsForInstallation: (): Promise<boolean> => Promise.resolve(!editorProtected),
		store,
	});
	const application = new BridgeCommWorkerProductBatchApplication({
		applyComment: (): void => {
			throw new Error('Unexpected comment application.');
		},
		applyFile: (): void => {
			throw new Error('Unexpected File application.');
		},
		applyReview: (presentation): void => {
			const source = presentation.runtimeSource.reviewPublicationIdentity;
			if (source === null) throw new Error('Complete empty publication lost identity.');
			const identity = {
				generation: source.reviewGeneration,
				packageId: source.packageId,
				publicationId: source.publicationId,
				revision: source.revision,
				sourceIdentity: source.sourceIdentity,
			};
			expect(
				store.stageReviewCandidateDisplayEvent({
					identity,
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
			if (message.kind === 'reviewCandidateStarted') {
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
			} else if (message.kind === 'reviewCandidateReady') {
				installationWork = gate.handleCandidateReady(message, attention());
			} else throw new Error('Unexpected candidate failure.');
		},
		publishReviewDisplay: (): void => {
			throw new Error('Unexpected re-exposure.');
		},
		requestResnapshot: (): void => {
			throw new Error('Unexpected resnapshot.');
		},
		requestResnapshotLatest: (): void => {
			throw new Error('Unexpected resnapshot.');
		},
		workerDerivationEpoch: (): number => 1,
	});
	const initial = publicationInstallation(1, false).begin;
	const receiver = new BridgeProductViewBatchReceiver({
		handle: initial.handle,
		scope: initial.scope,
		scopeRevision: initial.scopeRevision,
		subscriptionId: initial.subscriptionId,
		subscriptionKind: initial.subscriptionKind,
	});
	receiver.admitDomain(initial.domain, initial.incarnation);
	let streamSequence = 0;
	let deliverySequence = 0;
	return {
		close: (): void => gate.close(),
		receipts,
		requests,
		store,
		install: async (installation): Promise<void> => {
			const begin = {
				...installation.begin,
				batchId: `batch-${installation.begin.targetRevision}`,
				partCount: installation.records.length,
				streamSequence: ++streamSequence,
			};
			expect(receiver.accept(begin).kind).toBe('staged');
			for (const [partIndex, record] of installation.records.entries()) {
				const frame = bridgeProductBatchFrameSchema.parse({
					...sessionCorpus.transportV2.batchFrames[1],
					batchId: begin.batchId,
					kind: 'subscription.batchPart',
					streamSequence: ++streamSequence,
					partIndex,
					deliverySequence: ++deliverySequence,
					part: {
						operation: 'put',
						key: record.key,
						revision: record.revision,
						value: record.value,
					},
				});
				expect(receiver.accept(frame).kind).toBe('staged');
			}
			const complete = bridgeProductBatchFrameSchema.parse({
				...sessionCorpus.transportV2.batchFrames[4],
				batchId: begin.batchId,
				kind: 'subscription.batchComplete',
				streamSequence: ++streamSequence,
				coveredScope: begin.scope,
			});
			expect(receiver.accept(complete, application.sinks().verify).kind).toBe('installed');
			for (const certified of receiver.takeInstallations())
				await application.sinks().install(certified);
			await installationWork;
		},
		releaseAttention: (): Promise<void> => gate.semanticAttentionChanged(attention()),
		setEditorProtected: (isProtected): void => {
			editorProtected = isProtected;
		},
	};
}

function expectEmptyInstalled(fixture: ReturnType<typeof installationFixture>): void {
	const snapshot = fixture.store.getSnapshot();
	const source = snapshot.reviewSourceSlice;
	expect(source).toMatchObject({ status: 'ready', totalItemCount: 0, totalTreeRowCount: 0 });
	expect(source).not.toHaveProperty('kind', 'readyEmpty');
	expect(snapshot.reviewItemIdsByIndex).toEqual([]);
	expect(snapshot.reviewTreeRowsByIndex).toEqual([]);
	expect(snapshot.codeViewItemsById).toEqual({});
	expect(snapshot.contentAvailabilityById).toEqual({});
	expect(snapshot.rowPaintById).toEqual({});
	expect(fixture.store.getReviewRefreshPresentation().candidate).toBeNull();
}

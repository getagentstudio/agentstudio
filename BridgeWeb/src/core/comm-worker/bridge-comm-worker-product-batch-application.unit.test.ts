import { describe, expect, test } from 'vitest';

import commentCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-comment-catalog-record-corpus.json' with { type: 'json' };
import fileCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import reviewCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { BridgeCommWorkerProductBatchApplication } from './bridge-comm-worker-product-batch-application.js';
import { bridgeCommWorkerReviewDisplayPatchesFromBatch } from './bridge-comm-worker-review-batch-display.js';
import type { BridgeCommWorkerReviewBatchPresentation } from './bridge-comm-worker-review-batch-installer.js';
import {
	bridgeProductBatchFrameSchema,
	type BridgeProductBatchFrame,
} from './bridge-product-batch-wire-contracts.js';
import {
	bridgeProductReviewBatchRecordSchema,
	type BridgeProductReviewBatchRecord,
} from './bridge-product-review-batch-record-contracts.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import type {
	BridgeWorkerReviewDisplayPatch,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

type ReviewBatchItem = Extract<BridgeProductReviewBatchRecord, { readonly recordKind: 'item' }>;
type ReviewBatchPublication = Extract<
	BridgeProductReviewBatchRecord,
	{ readonly recordKind: 'publication' }
>;

function batchBegin(
	subscriptionKind: 'file.metadata' | 'review.metadata' | 'file.annotations',
): Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }> {
	const source = sessionCorpus.transportV2.batchFrames.find(
		(frame) => frame.kind === 'subscription.batchBegin',
	);
	const publication = reviewCorpus.records[1]?.record;
	const frame = bridgeProductBatchFrameSchema.parse({
		...source,
		publicationId:
			subscriptionKind === 'review.metadata' && publication?.recordKind === 'publication'
				? publication.publicationId
				: undefined,
		scope:
			subscriptionKind === 'file.metadata'
				? { kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] }
				: subscriptionKind === 'review.metadata'
					? { kind: 'review', interests: [] }
					: { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' },
		subscriptionKind,
		targetRevision: subscriptionKind === 'review.metadata' ? 1 : 4,
	});
	if (frame.kind !== 'subscription.batchBegin') throw new Error('Batch begin fixture missing.');
	return frame;
}

describe('Bridge comm worker product batch application owner', () => {
	test('re-exposes a successor complete display bank between its started and ready facts after predecessor rejection', async () => {
		const publications: Array<
			| { readonly kind: 'started' | 'ready'; readonly publicationId: string }
			| {
					readonly kind: 'display';
					readonly publicationId: string | null;
					readonly patches: readonly BridgeWorkerReviewDisplayPatch[];
			  }
		> = [];
		let sequence = 0;
		const application = new BridgeCommWorkerProductBatchApplication({
			applyComment: (): void => {},
			applyFile: (): void => {},
			applyReview: (): void => {},
			createSequence: (): number => ++sequence,
			publishMessage: (message): void => {
				if (message.kind === 'reviewCandidateStarted')
					publications.push({ kind: 'started', publicationId: message.publicationId });
				if (message.kind === 'reviewCandidateReady')
					publications.push({ kind: 'ready', publicationId: message.publicationId });
			},
			publishReviewDisplay: ({ patches, reviewPublicationIdentity }): void => {
				publications.push({
					kind: 'display',
					publicationId: reviewPublicationIdentity?.publicationId ?? null,
					patches,
				});
			},
			requestResnapshot: (): void => {},
			requestResnapshotLatest: (): void => {},
			workerDerivationEpoch: (): number => 2,
		});
		const predecessor = reviewImpactInstallation({
			item: reviewImpactItem('review-item-old', 'a'),
			revision: 12,
		});
		const successor = reviewImpactInstallation({
			item: reviewImpactItem('review-item-new', 'b'),
			revision: 13,
		});
		await application.sinks().install(predecessor);
		await application.sinks().install(successor);
		publications.length = 0;

		expect(
			application.handleSuccessorReExposureSettlement(
				{
					candidatePublicationId: predecessor.begin.publicationId ?? '',
					kind: 'admissionRejected',
				},
				2,
			),
		).toBe(true);
		expect(publications.map(({ kind }) => kind)).toEqual(['started', 'display', 'ready']);
		expect(publications[1]).toMatchObject({
			kind: 'display',
			publicationId: successor.begin.publicationId,
			patches: expect.arrayContaining([
				expect.objectContaining({
					slice: 'reviewSource',
					payload: expect.objectContaining({ status: 'ready' }),
				}),
				expect.objectContaining({ slice: 'reviewItem' }),
			]),
		});
	});

	test('routes certified File, Review and Comment banks to their typed owners', async () => {
		const installedKinds: string[] = [];
		const application = new BridgeCommWorkerProductBatchApplication({
			applyComment: (catalog, surface): void => {
				expect(catalog.orderedSessionIds).toHaveLength(1);
				expect(surface).toBe('file');
				installedKinds.push('comment');
			},
			applyFile: (view): void => {
				expect(view.memberStatus.kind).toBe('memberStatus');
				installedKinds.push('file');
			},
			applyReview: (presentation): void => {
				expect(presentation.publication.displayed).toBeNull();
				installedKinds.push('review');
			},
			createSequence: (): number => 1,
			publishMessage: (): void => {},
			publishReviewDisplay: (): void => {},
			requestResnapshot: (): void => {},
			requestResnapshotLatest: (): void => {},
			workerDerivationEpoch: (): number => 2,
		});
		const fileInstallation: BridgeProductViewInstallation = {
			certified: true,
			staleRecords: [],
			begin: batchBegin('file.metadata'),
			domain: 'default',
			records: [
				...fileCorpus.rows.map(({ recordKey, row }) => ({
					key: recordKey,
					revision: 1,
					value: row,
				})),
				{ key: 'member-status', revision: 1, value: fileCorpus.memberStatuses[0]?.record },
			],
		};
		const emptyPublication = reviewCorpus.records[1];
		if (emptyPublication?.record.recordKind !== 'publication')
			throw new Error('Review publication fixture missing.');
		if (emptyPublication.record.revision === undefined)
			throw new Error('Review publication fixture has no revision.');
		const reviewInstallation: BridgeProductViewInstallation = {
			certified: true,
			staleRecords: [],
			begin: batchBegin('review.metadata'),
			domain: 'default',
			records: [
				{
					key: emptyPublication.recordKey,
					revision: emptyPublication.record.revision,
					value: emptyPublication.record,
				},
			],
		};
		const commentInstallation: BridgeProductViewInstallation = {
			certified: true,
			staleRecords: [],
			begin: batchBegin('file.annotations'),
			domain: 'default',
			records: [
				...new Map(
					commentCorpus.records.map(({ recordKey, record }) => [
						recordKey,
						{ key: recordKey, revision: record.revision, value: record },
					]),
				).values(),
			],
		};
		await application.sinks().install(fileInstallation);
		await application.sinks().install(reviewInstallation);
		await application.sinks().install(commentInstallation);
		expect(installedKinds).toEqual(['file', 'review', 'comment']);
	});

	test('publishes one W4 candidate lifecycle and retains its installed bank on metadata failure', async () => {
		const publicationRecord = bridgeProductReviewBatchRecordSchema.parse(
			reviewCorpus.records[2]?.record,
		);
		const itemRecord = bridgeProductReviewBatchRecordSchema.parse(reviewCorpus.records[0]?.record);
		if (
			publicationRecord.recordKind !== 'publication' ||
			publicationRecord.displayed === null ||
			itemRecord.recordKind !== 'item'
		) {
			throw new Error('Review batch corpus lacks a complete displayed publication.');
		}
		const publicationId = publicationRecord.displayed.publicationId;
		const targetRevision = publicationRecord.revision;
		const readyPublication = bridgeProductReviewBatchRecordSchema.parse({
			...publicationRecord,
			desired: { ...publicationRecord.desired, status: 'ready' },
			publicationId,
			revision: targetRevision,
		});
		const begin = {
			...batchBegin('review.metadata'),
			publicationId,
			targetRevision,
		};
		const installation: BridgeProductViewInstallation = {
			certified: true,
			staleRecords: [],
			begin,
			domain: 'default',
			records: [
				{
					key: itemRecord.itemId,
					revision: 1,
					value: itemRecord,
				},
				{
					key: 'publication',
					revision: targetRevision,
					value: readyPublication,
				},
			],
		};
		const publishedMessages: BridgeWorkerServerToMainMessage[] = [];
		const publishedDisplayPatches: Array<readonly BridgeWorkerReviewDisplayPatch[]> = [];
		const application = new BridgeCommWorkerProductBatchApplication({
			applyComment: (): void => {},
			applyFile: (): void => {},
			applyReview: (presentation): void => {
				publishedDisplayPatches.push(bridgeCommWorkerReviewDisplayPatchesFromBatch(presentation));
			},
			createSequence: (() => {
				let sequence = 0;
				return (): number => ++sequence;
			})(),
			publishMessage: (message): void => {
				publishedMessages.push(message);
			},
			publishReviewDisplay: ({ patches }): void => {
				publishedDisplayPatches.push(patches);
			},
			requestResnapshot: (): void => {},
			requestResnapshotLatest: (): void => {},
			workerDerivationEpoch: (): number => 2,
		});
		const corruptedItem = {
			...itemRecord,
			contentByRole: {
				...itemRecord.contentByRole,
				head: {
					...itemRecord.contentByRole.head,
					...(itemRecord.contentByRole.head.state === 'available'
						? {
								source: { ...itemRecord.contentByRole.head.source, sourceIdentity: 'wrong-source' },
							}
						: {}),
				},
			},
		};
		const installedPublication = installation.records[1];
		if (installedPublication === undefined) throw new Error('Review publication fixture missing.');
		expect(() =>
			application.sinks().verify?.({
				...installation,
				records: [
					{ key: itemRecord.itemId, revision: 1, value: corruptedItem },
					installedPublication,
				],
			}),
		).toThrow('Review content source belongs to another publication.');
		application.sinks().verify?.(installation);

		await application.sinks().install(installation);

		expect(publishedMessages.map(({ kind }) => kind)).toEqual([
			'reviewCandidateStarted',
			'reviewCandidateReady',
		]);
		expect(publishedMessages[0]).toMatchObject({
			disposition: {
				affectedStableFileIdentities: ['review-item-1'],
				kind: 'sameSource',
				presentationClass: { kind: 'promoted', reason: 'files' },
			},
		});
		const activeDisplay = publishedDisplayPatches[0];
		if (activeDisplay === undefined) throw new Error('Installed Review display was not published.');

		const failureDisposition = application.handleMetadataFailure(2);

		expect(failureDisposition).toBe('retainedActive');
		expect(publishedDisplayPatches).toHaveLength(2);
		expect(publishedDisplayPatches[1]).toEqual([
			expect.objectContaining({
				operation: 'upsert',
				payload: expect.objectContaining({ status: 'stale' }),
				slice: 'reviewSource',
			}),
		]);
		expect(activeDisplay.some((patch) => patch.slice === 'reviewItem')).toBe(true);
	});

	test('keeps the displayed A bank stale when failed desired publication B retains it', async () => {
		const publicationRecord = bridgeProductReviewBatchRecordSchema.parse(
			reviewCorpus.records[2]?.record,
		);
		const itemRecord = bridgeProductReviewBatchRecordSchema.parse(reviewCorpus.records[0]?.record);
		if (
			publicationRecord.recordKind !== 'publication' ||
			publicationRecord.desired.status !== 'failedRetryable' ||
			publicationRecord.displayed === null ||
			itemRecord.recordKind !== 'item'
		) {
			throw new Error(
				'Review batch corpus lacks a failed desired publication with a displayed bank.',
			);
		}
		const displayedPublicationId = publicationRecord.displayed.publicationId;
		const begin = {
			...batchBegin('review.metadata'),
			publicationId: publicationRecord.publicationId,
			targetRevision: publicationRecord.revision,
		};
		const installation: BridgeProductViewInstallation = {
			certified: true,
			staleRecords: [],
			begin,
			domain: 'default',
			records: [
				{ key: itemRecord.itemId, revision: 1, value: itemRecord },
				{
					key: 'publication',
					revision: publicationRecord.revision,
					value: publicationRecord,
				},
			],
		};
		const publishedMessages: BridgeWorkerServerToMainMessage[] = [];
		const installedPresentations: BridgeCommWorkerReviewBatchPresentation[] = [];
		const publishedDisplayPatches: Array<readonly BridgeWorkerReviewDisplayPatch[]> = [];
		const application = new BridgeCommWorkerProductBatchApplication({
			applyComment: (): void => {},
			applyFile: (): void => {},
			applyReview: (presentation): void => {
				installedPresentations.push(presentation);
				publishedDisplayPatches.push(bridgeCommWorkerReviewDisplayPatchesFromBatch(presentation));
			},
			createSequence: (): number => 1,
			publishMessage: (message): void => {
				publishedMessages.push(message);
			},
			publishReviewDisplay: ({ patches }): void => {
				publishedDisplayPatches.push(patches);
			},
			requestResnapshot: (): void => {},
			requestResnapshotLatest: (): void => {},
			workerDerivationEpoch: (): number => 2,
		});

		await application.sinks().install(installation);

		expect(publishedMessages).toEqual([]);
		expect(installedPresentations).toHaveLength(1);
		expect(installedPresentations[0]?.runtimeSource.reviewPublicationIdentity?.publicationId).toBe(
			displayedPublicationId,
		);
		expect(publishedDisplayPatches[0]).toEqual(
			expect.arrayContaining([
				expect.objectContaining({
					operation: 'upsert',
					payload: expect.objectContaining({ status: 'stale' }),
					slice: 'reviewSource',
				}),
				expect.objectContaining({ slice: 'reviewItem' }),
			]),
		);
		expect(application.handleMetadataFailure(2)).toBe('retainedActive');
	});

	test('refines empty native impact from retired and successor Review runtime signatures', async () => {
		const { application, publishedMessages } = reviewImpactApplication();
		await application
			.sinks()
			.install(
				reviewImpactInstallation({ item: reviewImpactItem('review-item-old', 'a'), revision: 12 }),
			);
		publishedMessages.length = 0;

		await application.sinks().install(
			reviewImpactInstallation({
				item: reviewImpactItem('review-item-new', 'b'),
				impact: ordinaryReviewImpact([]),
				revision: 13,
			}),
		);

		expect(publishedMessages[0]).toMatchObject({
			kind: 'reviewCandidateStarted',
			disposition: {
				affectedStableFileIdentities: ['review-item-old', 'review-item-new'],
				kind: 'sameSource',
				presentationClass: { kind: 'ordinary' },
			},
		});
	});

	test('passes native Review impact through when no predecessor is installed', async () => {
		const { application, publishedMessages } = reviewImpactApplication();
		await application.sinks().install(
			reviewImpactInstallation({
				item: reviewImpactItem('review-item-new', 'b'),
				impact: ordinaryReviewImpact(['native-file']),
				revision: 12,
			}),
		);

		expect(publishedMessages[0]).toMatchObject({
			disposition: {
				affectedStableFileIdentities: ['native-file'],
				kind: 'sameSource',
				presentationClass: { kind: 'ordinary' },
			},
		});
	});

	test('leaves native unknown Review impact symbolic across a changed successor', async () => {
		const { application, publishedMessages } = reviewImpactApplication();
		await application
			.sinks()
			.install(
				reviewImpactInstallation({ item: reviewImpactItem('review-item-old', 'a'), revision: 12 }),
			);
		publishedMessages.length = 0;
		await application.sinks().install(
			reviewImpactInstallation({
				item: reviewImpactItem('review-item-new', 'b'),
				impact: {
					addedLineCount: null,
					affectedFileCount: null,
					affectedStableFileIdentities: [],
					deletedLineCount: null,
					newlyImportedCommitCount: null,
					preDeliveryPresentationClass: { kind: 'promoted', reason: 'unknown' },
				},
				revision: 13,
			}),
		);

		expect(publishedMessages[0]).toMatchObject({
			disposition: {
				affectedStableFileIdentities: [],
				kind: 'sameSource',
				presentationClass: { kind: 'promoted', reason: 'unknown' },
			},
		});
	});

	test('keeps affected Review identities empty when successor signatures are identical', async () => {
		const { application, publishedMessages } = reviewImpactApplication();
		const item = reviewImpactItem('review-item-1', 'a');
		await application.sinks().install(reviewImpactInstallation({ item, revision: 12 }));
		publishedMessages.length = 0;
		await application
			.sinks()
			.install(reviewImpactInstallation({ item, impact: ordinaryReviewImpact([]), revision: 13 }));

		expect(publishedMessages[0]).toMatchObject({
			disposition: { affectedStableFileIdentities: [], kind: 'sameSource' },
		});
	});
});

function reviewImpactApplication(): {
	readonly application: BridgeCommWorkerProductBatchApplication;
	readonly publishedMessages: BridgeWorkerServerToMainMessage[];
} {
	const publishedMessages: BridgeWorkerServerToMainMessage[] = [];
	let sequence = 0;
	return {
		application: new BridgeCommWorkerProductBatchApplication({
			applyComment: (): void => {},
			applyFile: (): void => {},
			applyReview: (): void => {},
			createSequence: (): number => ++sequence,
			publishMessage: (message): void => {
				publishedMessages.push(message);
			},
			publishReviewDisplay: (): void => {},
			requestResnapshot: (): void => {},
			requestResnapshotLatest: (): void => {},
			workerDerivationEpoch: (): number => 2,
		}),
		publishedMessages,
	};
}

function reviewImpactInstallation(props: {
	readonly item: ReviewBatchItem;
	readonly impact?: ReviewBatchPublication['classifiedRefreshImpact'];
	readonly revision: number;
}): BridgeProductViewInstallation {
	const fixture = bridgeProductReviewBatchRecordSchema.parse(reviewCorpus.records[2]?.record);
	if (fixture.recordKind !== 'publication' || fixture.displayed === null) {
		throw new Error('Review impact fixture requires a displayed publication.');
	}
	const publicationId =
		props.revision === 12
			? fixture.displayed.publicationId
			: '00000000-0000-7000-8000-000000000014';
	const publication = bridgeProductReviewBatchRecordSchema.parse({
		...fixture,
		classifiedRefreshImpact: props.impact ?? null,
		desired: { ...fixture.desired, status: 'ready' },
		displayed: { ...fixture.displayed, publicationId, revision: props.revision },
		publicationId,
		revision: props.revision,
	});
	return {
		certified: true,
		staleRecords: [],
		begin: {
			...batchBegin('review.metadata'),
			publicationId,
			targetRevision: props.revision,
		},
		domain: 'default',
		records: [
			{ key: props.item.itemId, revision: 1, value: props.item },
			{ key: 'publication', revision: props.revision, value: publication },
		],
	};
}

function reviewImpactItem(itemId: string, digestCharacter: string): ReviewBatchItem {
	const fixture = bridgeProductReviewBatchRecordSchema.parse(reviewCorpus.records[0]?.record);
	if (fixture.recordKind !== 'item' || fixture.contentByRole.head.state !== 'available') {
		throw new Error('Review impact fixture requires an available head item.');
	}
	const digest = digestCharacter.repeat(64);
	const item = bridgeProductReviewBatchRecordSchema.parse({
		...fixture,
		itemId,
		contentByRole: {
			...fixture.contentByRole,
			head: {
				state: 'available',
				source: {
					...fixture.contentByRole.head.source,
					contentDigest: { ...fixture.contentByRole.head.source.contentDigest, value: digest },
					descriptorId: `descriptor-${itemId}`,
					itemId,
				},
			},
		},
		contentHashesByRole: { ...fixture.contentHashesByRole, head: digest },
	});
	if (item.recordKind !== 'item') throw new Error('Review impact fixture item is invalid.');
	return item;
}

function ordinaryReviewImpact(
	affectedStableFileIdentities: readonly string[],
): NonNullable<ReviewBatchPublication['classifiedRefreshImpact']> {
	return {
		addedLineCount: 0,
		affectedFileCount: 0,
		affectedStableFileIdentities,
		deletedLineCount: 0,
		newlyImportedCommitCount: 0,
		preDeliveryPresentationClass: { kind: 'ordinary' },
	};
}

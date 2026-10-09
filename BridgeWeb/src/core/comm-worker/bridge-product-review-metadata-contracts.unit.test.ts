import { readFileSync } from 'node:fs';

import { describe, expect, test } from 'vitest';

import {
	bridgeProductReviewItemMetadataSchema,
	bridgeProductReviewMetadataEventSchema,
} from './bridge-product-review-metadata-contracts.js';

const reviewSourceIdentity = {
	eventKind: 'review.sourceAccepted',
	operationCorrelationId: null,
	generation: 7,
	packageId: 'review-package-1',
	publicationId: '00000000-0000-7000-8000-000000000011',
	revision: 11,
	sourceIdentity: 'review-query-1',
} as const;

const reviewContentSource = {
	contentDigest: {
		algorithm: 'sha256',
		authority: 'authoritative',
		value: 'a'.repeat(64),
	},
	contentKind: 'review.content',
	descriptorId: 'review-descriptor-1',
	encoding: 'utf-8',
	endpointId: 'review-endpoint-1',
	handleId: 'review-handle-1',
	isBinary: false,
	itemId: 'review-item-1',
	language: 'typescript',
	mimeType: 'text/plain',
	packageId: 'review-package-1',
	reviewGeneration: 7,
	role: 'head',
	sourceIdentity: 'review-query-1',
	wholeByteLength: 12,
} as const;

const reviewComparison = {
	activeTarget: { basis: 'commonCommit', kind: 'branch', name: 'origin/main' },
	attempt: { reviewGeneration: 7, status: 'settled' },
	displayedSnapshot: {
		packageId: 'review-package-1',
		reviewGeneration: 7,
		revision: 11,
		status: 'current',
	},
	repositoryDefaultTarget: null,
} as const;

const reviewRefreshImpact = {
	addedLineCount: 2,
	affectedFileCount: 1,
	affectedStableFileIdentities: ['review-item-1'],
	deletedLineCount: 1,
	newlyImportedCommitCount: 1,
	preDeliveryPresentationClass: { kind: 'ordinary' },
} as const;

describe('Bridge product Review metadata contracts', () => {
	test('does not import the legacy Review package or resource URL vocabulary', () => {
		const source = readFileSync(
			new URL('./bridge-product-review-metadata-contracts.ts', import.meta.url),
			'utf8',
		);

		expect(source).not.toContain('foundation/review-package');
		expect(source).not.toContain('resourceUrl');
	});

	test('preserves the identity-only source-accepted lifecycle event', () => {
		// Arrange / Act / Assert
		expect(bridgeProductReviewMetadataEventSchema.parse(reviewSourceIdentity)).toEqual(
			reviewSourceIdentity,
		);
		for (const publicationId of [
			'00000000-0000-7000-8000-00000000001A',
			'00000000-0000-4000-8000-000000000011',
			'00000000-0000-9000-8000-000000000011',
			'00000000-0000-7000-7000-000000000011',
		]) {
			expect(
				bridgeProductReviewMetadataEventSchema.safeParse({
					...reviewSourceIdentity,
					publicationId,
				}).success,
			).toBe(false);
		}
	});

	test('admits a bounded snapshot with worker projection facts and URL-free sources', () => {
		// Arrange
		const snapshot = {
			...reviewSourceIdentity,
			baseEndpoint: {
				createdAtUnixMilliseconds: 1,
				endpointId: 'review-base-endpoint',
				kind: 'gitRef',
				label: 'main',
				providerIdentity: 'git-ref:main',
				repoId: 'repo-1',
				worktreeId: 'worktree-1',
			},
			comparisonOrigin: {
				baseOID: 'contribution-base-oid',
				baseRole: 'commonCommit',
				comparedRole: 'capturedWorkingTree',
				kind: 'contribution',
				resolvedTargetOID: 'resolved-target-oid',
				reviewedHeadOID: 'reviewed-head-oid',
				reviewedSubjectBranchName: null,
				symbolicTarget: { basis: 'commonCommit', kind: 'branch', name: 'integration' },
			},
			contentSources: [reviewContentSource],
			eventKind: 'review.snapshot',
			operationCorrelationId: null,
			extentFacts: [{ contentRole: 'head', itemId: 'review-item-1', lineCount: 3 }],
			headEndpoint: {
				createdAtUnixMilliseconds: 2,
				endpointId: 'review-head-endpoint',
				kind: 'workingTree',
				label: 'Working Tree',
				providerIdentity: 'working-tree',
				repoId: 'repo-1',
				worktreeId: 'worktree-1',
			},
			itemMetadata: [
				{
					additions: 2,
					basePath: 'src/file.ts',
					changeKind: 'modified',
					contentDescriptorIdsByRole: { head: 'review-descriptor-1' },
					contentHashesByRole: { head: 'a'.repeat(64) },
					contentRoles: ['head'],
					deletions: 1,
					extension: 'ts',
					fileClass: 'source',
					headPath: 'src/file.ts',
					isHiddenByDefault: false,
					itemId: 'review-item-1',
					language: 'typescript',
					mimeTypes: ['text/plain'],
					provenance: { agentSessionIds: [], operationIds: [], promptIds: [] },
					reviewPriority: 'normal',
					reviewState: 'unreviewed',
				},
			],
			itemWindow: {
				finalWindow: true,
				itemCount: 1,
				startIndex: 0,
				totalItemCount: 1,
			},
			presentationRevision: 19,
			query: {
				baseEndpointId: 'review-base-endpoint',
				comparisonSemantics: 'threeDot',
				fileTarget: null,
				grouping: { kind: 'folder' },
				headEndpointId: 'review-head-endpoint',
				pathScope: [],
				provenanceFilter: {
					agentSessionIds: [],
					operationIds: [],
					paneIds: [],
					promptIds: [],
					sourceKinds: [],
				},
				queryId: 'review-query-1',
				queryKind: 'compare',
				repoId: 'repo-1',
				viewFilter: {
					changeKinds: [],
					excludedExtensions: [],
					excludedFileClasses: [],
					excludedPathGlobs: [],
					includedExtensions: [],
					includedFileClasses: [],
					includedPathGlobs: [],
					reviewStates: [],
					showBinaryFiles: true,
					showHiddenFiles: false,
					showLargeFiles: true,
				},
				worktreeId: 'worktree-1',
			},
			reviewedSubjectLabel: 'feature/review-comments',
			reviewComparison,
			summary: {
				additions: 2,
				deletions: 1,
				filesChanged: 1,
				hiddenFileCount: 0,
				visibleFileCount: 1,
			},
			treeRows: [
				{
					depth: 0,
					isDirectory: false,
					itemId: 'review-item-1',
					path: 'src/file.ts',
					rowId: 'review-row-1',
				},
			],
			treeWindow: {
				finalWindow: true,
				rowCount: 1,
				startIndex: 0,
				totalRowCount: 1,
			},
		} as const;

		// Act
		const parsed = bridgeProductReviewMetadataEventSchema.parse(snapshot);
		const snapshotItem = snapshot.itemMetadata[0];
		if (snapshotItem === undefined) throw new Error('Expected one Review snapshot item.');

		// Assert
		expect(parsed.eventKind).toBe('review.snapshot');
		expect(parsed).toMatchObject({
			comparisonOrigin: snapshot.comparisonOrigin,
			reviewedSubjectLabel: snapshot.reviewedSubjectLabel,
		});
		expect(
			bridgeProductReviewMetadataEventSchema.safeParse({
				...snapshot,
				...reviewRefreshImpact,
			}).success,
		).toBe(false);
		expect(JSON.stringify(parsed)).not.toMatch(/resourceUrl|contentHandle|"contents":/i);
		for (const mismatchedSource of [
			{ ...reviewContentSource, packageId: 'review-package-2' },
			{ ...reviewContentSource, reviewGeneration: 8 },
			{ ...reviewContentSource, sourceIdentity: 'review-query-2' },
		]) {
			expect(() =>
				bridgeProductReviewMetadataEventSchema.parse({
					...snapshot,
					contentSources: [mismatchedSource],
				}),
			).toThrow(/identity/i);
		}
		expect(() =>
			bridgeProductReviewItemMetadataSchema.parse({
				...snapshotItem,
				resourceUrl: 'agentstudio://resource/review/content/legacy',
			}),
		).toThrow();
		for (const invalidWindow of [
			{
				...snapshot,
				itemWindow: { ...snapshot.itemWindow, itemCount: 0 },
			},
			{
				...snapshot,
				itemWindow: { ...snapshot.itemWindow, finalWindow: false },
			},
			{
				...snapshot,
				treeWindow: { ...snapshot.treeWindow, startIndex: 1, totalRowCount: 2 },
			},
		]) {
			expect(() => bridgeProductReviewMetadataEventSchema.parse(invalidWindow)).toThrow(/window/i);
		}
		for (const missingCommitKey of ['presentationRevision', 'reviewComparison'] as const) {
			const invalidTerminal: Partial<typeof snapshot> = { ...snapshot };
			delete invalidTerminal[missingCommitKey];
			expect(() => bridgeProductReviewMetadataEventSchema.parse(invalidTerminal)).toThrow(
				/final display barrier/i,
			);
		}
		const nonterminalSnapshot = {
			...snapshot,
			itemWindow: { ...snapshot.itemWindow, finalWindow: false, totalItemCount: 2 },
		};
		for (const incompleteCommit of [{ presentationRevision: 19 }, { reviewComparison }]) {
			expect(() =>
				bridgeProductReviewMetadataEventSchema.parse({
					...nonterminalSnapshot,
					presentationRevision: undefined,
					reviewComparison: undefined,
					...incompleteCommit,
				}),
			).toThrow(/final display barrier/i);
		}
		expect(
			bridgeProductReviewMetadataEventSchema.parse({
				contentSources: snapshot.contentSources,
				eventKind: 'review.window',
				operationCorrelationId: null,
				extentFacts: snapshot.extentFacts,
				generation: snapshot.generation,
				itemMetadata: snapshot.itemMetadata,
				itemWindow: {
					finalWindow: true,
					itemCount: 1,
					startIndex: 3,
					totalItemCount: 4,
				},
				packageId: snapshot.packageId,
				presentationRevision: snapshot.presentationRevision,
				publicationId: snapshot.publicationId,
				reviewComparison: snapshot.reviewComparison,
				revision: snapshot.revision,
				sourceIdentity: snapshot.sourceIdentity,
				summary: snapshot.summary,
				treeRows: snapshot.treeRows,
				treeWindow: {
					finalWindow: true,
					rowCount: 1,
					startIndex: 6,
					totalRowCount: 7,
				},
			}),
		).toMatchObject({ eventKind: 'review.window' });
		expect(
			bridgeProductReviewMetadataEventSchema.parse({
				...reviewSourceIdentity,
				...reviewRefreshImpact,
				contentSources: [],
				eventKind: 'review.delta',
				operationCorrelationId: null,
				fromRevision: 10,
				operations: [
					{
						deleteCount: 1,
						operationKind: 'spliceTreeRows',
						rows: snapshot.treeRows,
						startIndex: 3,
					},
				],
				presentationRevision: snapshot.presentationRevision,
				reviewComparison: snapshot.reviewComparison,
				summary: snapshot.summary,
				toRevision: 11,
			}),
		).toMatchObject({ eventKind: 'review.delta' });
		expect(() =>
			bridgeProductReviewMetadataEventSchema.parse({
				...reviewSourceIdentity,
				contentSources: [],
				eventKind: 'review.delta',
				operationCorrelationId: null,
				fromRevision: 10,
				operations: [
					{
						operationKind: 'upsertTreeRows',
						rows: snapshot.treeRows,
					},
				],
				summary: snapshot.summary,
				toRevision: 11,
			}),
		).toThrow();
		expect(
			bridgeProductReviewMetadataEventSchema.parse({
				...reviewSourceIdentity,
				...reviewRefreshImpact,
				comparisonOrigin: snapshot.comparisonOrigin,
				eventKind: 'review.reset',
				operationCorrelationId: null,
				reason: 'sourceChanged',
				reviewedSubjectLabel: snapshot.reviewedSubjectLabel,
			}),
		).toMatchObject({
			comparisonOrigin: snapshot.comparisonOrigin,
			preDeliveryPresentationClass: { kind: 'ordinary' },
			reviewedSubjectLabel: snapshot.reviewedSubjectLabel,
		});
		expect(
			bridgeProductReviewMetadataEventSchema.parse({
				...reviewSourceIdentity,
				...reviewRefreshImpact,
				affectedStableFileIdentities: [],
				addedLineCount: null,
				affectedFileCount: null,
				deletedLineCount: null,
				eventKind: 'review.reset',
				newlyImportedCommitCount: null,
				preDeliveryPresentationClass: { kind: 'promoted', reason: 'unknown' },
				reason: 'sourceChanged',
			}),
		).toMatchObject({ preDeliveryPresentationClass: { kind: 'promoted', reason: 'unknown' } });
		expect(() =>
			bridgeProductReviewMetadataEventSchema.parse({
				...snapshot,
				comparisonOrigin: {
					...snapshot.comparisonOrigin,
					baseRole: 'capturedWorkingTree',
				},
			}),
		).toThrow();
	});

	test('rejects legacy resource URLs and main-owned selection in Review snapshots', () => {
		// Arrange / Act / Assert
		expect(() =>
			bridgeProductReviewMetadataEventSchema.parse({
				...reviewSourceIdentity,
				eventKind: 'review.snapshot',
				operationCorrelationId: null,
				resourceUrl: 'agentstudio://resource/review/content/legacy',
				selectedItemId: 'review-item-1',
			}),
		).toThrow();
	});
});

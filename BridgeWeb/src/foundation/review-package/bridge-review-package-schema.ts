import { z } from 'zod';

export const bridgeReviewGenerationSchema = z.number().int().nonnegative();

export const bridgeReviewComparisonBasisSchema = z.enum(['commonCommit', 'branchTip']);
export const bridgeReviewComparisonBaseRoleSchema = z.enum(['commonCommit', 'selectedTarget']);

export const bridgeReviewComparisonTargetSchema = z.discriminatedUnion('kind', [
	z
		.object({
			basis: bridgeReviewComparisonBasisSchema,
			branchName: z.string().min(1),
			kind: z.literal('localDefaultBranch'),
		})
		.strict(),
	z
		.object({
			basis: bridgeReviewComparisonBasisSchema,
			branchName: z.string().min(1),
			kind: z.literal('originDefaultBranch'),
			remoteName: z.string().min(1),
		})
		.strict(),
	z
		.object({
			basis: bridgeReviewComparisonBasisSchema,
			kind: z.literal('branch'),
			name: z.string().min(1),
		})
		.strict(),
	z
		.object({
			kind: z.literal('commit'),
			oid: z.string().regex(/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/iu),
		})
		.strict(),
	z
		.object({
			basis: bridgeReviewComparisonBasisSchema,
			kind: z.literal('ref'),
			name: z.string().min(1),
		})
		.strict(),
]);

export const bridgeReviewComparisonOriginSchema = z
	.object({
		baseOID: z.string().min(1),
		baseRole: bridgeReviewComparisonBaseRoleSchema,
		comparedRole: z.literal('capturedWorkingTree'),
		kind: z.literal('contribution'),
		resolvedTargetOID: z.string().min(1),
		reviewedHeadOID: z.string().min(1),
		reviewedSubjectBranchName: z.string().min(1).nullable(),
		symbolicTarget: bridgeReviewComparisonTargetSchema,
	})
	.strict();

export const bridgeSourceEndpointKindSchema = z.enum([
	'gitRef',
	'workingTree',
	'index',
	'promptCheckpoint',
	'sessionCheckpoint',
	'manualCheckpoint',
	'savedTimeWindowCheckpoint',
]);

export const bridgeSourceEndpointSchema = z
	.object({
		endpointId: z.string(),
		kind: bridgeSourceEndpointKindSchema,
		repoId: z.string(),
		worktreeId: z.string(),
		label: z.string(),
		createdAtUnixMilliseconds: z.number().int().nonnegative(),
		contentSetHash: z.string().nullable().optional(),
		providerIdentity: z.string(),
	})
	.strict();

export const bridgeFileClassSchema = z.enum([
	'source',
	'test',
	'docs',
	'config',
	'generated',
	'vendor',
	'binary',
	'large',
	'fixture',
	'unknown',
]);

export const bridgeFileChangeKindSchema = z.enum([
	'added',
	'modified',
	'deleted',
	'renamed',
	'copied',
]);

export const bridgeFileReviewStateSchema = z.enum([
	'unreviewed',
	'viewed',
	'annotated',
	'resolved',
]);

export const bridgeReviewPrioritySchema = z.enum(['low', 'normal', 'high']);

export const bridgeContentRoleSchema = z.enum(['base', 'head', 'diff', 'file']);

export const bridgeContentHandleSchema = z
	.object({
		handleId: z.string(),
		itemId: z.string(),
		role: bridgeContentRoleSchema,
		endpointId: z.string(),
		reviewGeneration: bridgeReviewGenerationSchema,
		contentHash: z.string(),
		contentHashAlgorithm: z.string(),
		cacheKey: z.string(),
		mimeType: z.string(),
		language: z.string().nullable().optional(),
		sizeBytes: z.number().int().nonnegative(),
		sizeBytesIsExact: z.boolean().optional(),
		maxBytes: z.number().int().positive().optional(),
		isBinary: z.boolean(),
	})
	.strict();

export const bridgeReviewContentRolesSchema = z
	.object({
		base: bridgeContentHandleSchema.nullable().optional(),
		head: bridgeContentHandleSchema.nullable().optional(),
		diff: bridgeContentHandleSchema.nullable().optional(),
		file: bridgeContentHandleSchema.nullable().optional(),
	})
	.strict();

export const bridgeReviewContentLineCountsByRoleSchema = z
	.object({
		base: z.number().int().nonnegative().nullable().optional(),
		head: z.number().int().nonnegative().nullable().optional(),
		diff: z.number().int().nonnegative().nullable().optional(),
		file: z.number().int().nonnegative().nullable().optional(),
	})
	.strict();

export const bridgeProvenanceSummarySchema = z
	.object({
		paneIds: z.array(z.string()),
		agentSessionIds: z.array(z.string()),
		promptIds: z.array(z.string()),
		operationIds: z.array(z.string()),
		sourceKinds: z.array(z.string()),
	})
	.strict();

export const bridgeAnnotationSummarySchema = z
	.object({
		threadCount: z.number().int().nonnegative(),
		unresolvedThreadCount: z.number().int().nonnegative(),
		commentCount: z.number().int().nonnegative(),
	})
	.strict();

export const bridgeReviewItemDescriptorSchema = z
	.object({
		itemId: z.string(),
		itemKind: z.enum(['file', 'diff']),
		itemVersion: z.number().int().nonnegative(),
		basePath: z.string().nullable().optional(),
		headPath: z.string().nullable().optional(),
		changeKind: bridgeFileChangeKindSchema,
		fileClass: bridgeFileClassSchema,
		language: z.string().nullable().optional(),
		extension: z.string().nullable().optional(),
		sizeBytes: z.number().int().nonnegative(),
		baseContentHash: z.string().nullable().optional(),
		headContentHash: z.string().nullable().optional(),
		contentHashAlgorithm: z.string(),
		additions: z.number().int().nonnegative(),
		deletions: z.number().int().nonnegative(),
		isHiddenByDefault: z.boolean(),
		hiddenReason: z.string().nullable().optional(),
		reviewPriority: bridgeReviewPrioritySchema,
		contentRoles: bridgeReviewContentRolesSchema,
		contentLineCountsByRole: bridgeReviewContentLineCountsByRoleSchema.optional(),
		cacheKey: z.string(),
		provenance: bridgeProvenanceSummarySchema,
		annotationSummary: bridgeAnnotationSummarySchema,
		reviewState: bridgeFileReviewStateSchema,
		collapsed: z.boolean(),
	})
	.strict();

export const bridgeViewFilterSchema = z
	.object({
		includedPathGlobs: z.array(z.string()),
		excludedPathGlobs: z.array(z.string()),
		includedFileClasses: z.array(bridgeFileClassSchema),
		excludedFileClasses: z.array(bridgeFileClassSchema),
		includedExtensions: z.array(z.string()),
		excludedExtensions: z.array(z.string()),
		changeKinds: z.array(bridgeFileChangeKindSchema),
		reviewStates: z.array(bridgeFileReviewStateSchema),
		showHiddenFiles: z.boolean(),
		showBinaryFiles: z.boolean(),
		showLargeFiles: z.boolean(),
	})
	.strict();

export const bridgeChangeGroupingKindSchema = z.enum([
	'flat',
	'folder',
	'fileClass',
	'changeKind',
	'reviewState',
	'agentStream',
	'prompt',
	'session',
	'checkpoint',
	'timeWindow',
	'custom',
]);

export const bridgeChangeGroupingSchema = z
	.object({
		kind: bridgeChangeGroupingKindSchema,
		label: z.string().nullable().optional(),
	})
	.strict();

export const bridgeProvenanceFilterSchema = z
	.object({
		paneIds: z.array(z.string()),
		agentSessionIds: z.array(z.string()),
		promptIds: z.array(z.string()),
		operationIds: z.array(z.string()),
		createdAfterUnixMilliseconds: z.number().int().nonnegative().nullable().optional(),
		createdBeforeUnixMilliseconds: z.number().int().nonnegative().nullable().optional(),
		sourceKinds: z.array(z.string()),
	})
	.strict();

export const bridgeReviewQuerySchema = z
	.object({
		queryId: z.string(),
		queryKind: z.enum(['compare', 'openFile', 'browseTree', 'filterPackage', 'groupPackage']),
		repoId: z.string(),
		worktreeId: z.string(),
		baseEndpointId: z.string().nullable().optional(),
		headEndpointId: z.string().nullable().optional(),
		comparisonSemantics: z.enum([
			'twoDot',
			'threeDot',
			'checkpointDelta',
			'indexDelta',
			'workingTreeDelta',
			'notApplicable',
		]),
		pathScope: z.array(z.string()),
		fileTarget: z.string().nullable().optional(),
		viewFilter: bridgeViewFilterSchema,
		grouping: bridgeChangeGroupingSchema,
		provenanceFilter: bridgeProvenanceFilterSchema,
	})
	.strict();

export const bridgeReviewGroupSchema = z
	.object({
		groupId: z.string(),
		grouping: bridgeChangeGroupingSchema,
		label: z.string(),
		orderedItemIds: z.array(z.string()),
		summary: z
			.object({
				filesChanged: z.number().int().nonnegative(),
				additions: z.number().int().nonnegative(),
				deletions: z.number().int().nonnegative(),
			})
			.strict(),
		hiddenSummary: z
			.object({
				hiddenFileCount: z.number().int().nonnegative(),
				hiddenAdditions: z.number().int().nonnegative(),
				hiddenDeletions: z.number().int().nonnegative(),
				hiddenFileClasses: z.array(bridgeFileClassSchema),
			})
			.strict(),
	})
	.strict();

export const bridgeReviewPackageSummarySchema = z
	.object({
		filesChanged: z.number().int().nonnegative(),
		additions: z.number().int().nonnegative(),
		deletions: z.number().int().nonnegative(),
		visibleFileCount: z.number().int().nonnegative(),
		hiddenFileCount: z.number().int().nonnegative(),
	})
	.strict();

export const bridgeReviewPackageSchema = z
	.object({
		packageId: z.string(),
		schemaVersion: z.literal(1),
		reviewGeneration: bridgeReviewGenerationSchema,
		revision: z.number().int().nonnegative(),
		query: bridgeReviewQuerySchema,
		baseEndpoint: bridgeSourceEndpointSchema,
		comparisonOrigin: bridgeReviewComparisonOriginSchema.nullable().optional(),
		headEndpoint: bridgeSourceEndpointSchema,
		orderedItemIds: z.array(z.string()),
		itemsById: z.record(z.string(), bridgeReviewItemDescriptorSchema),
		groups: z.array(bridgeReviewGroupSchema),
		reviewedSubjectLabel: z.string().min(1).nullable().optional(),
		summary: bridgeReviewPackageSummarySchema,
		filterState: bridgeViewFilterSchema,
		generatedAtUnixMilliseconds: z.number().int().nonnegative(),
	})
	.strict();

export type BridgeReviewGeneration = z.infer<typeof bridgeReviewGenerationSchema>;
export type BridgeSourceEndpointKind = z.infer<typeof bridgeSourceEndpointKindSchema>;
export type BridgeSourceEndpoint = z.infer<typeof bridgeSourceEndpointSchema>;
export type BridgeFileClass = z.infer<typeof bridgeFileClassSchema>;
export type BridgeFileChangeKind = z.infer<typeof bridgeFileChangeKindSchema>;
export type BridgeFileReviewState = z.infer<typeof bridgeFileReviewStateSchema>;
export type BridgeReviewPriority = z.infer<typeof bridgeReviewPrioritySchema>;
export type BridgeContentRole = z.infer<typeof bridgeContentRoleSchema>;
export type BridgeContentHandle = z.infer<typeof bridgeContentHandleSchema>;
export type BridgeReviewContentRoles = z.infer<typeof bridgeReviewContentRolesSchema>;
export type BridgeProvenanceSummary = z.infer<typeof bridgeProvenanceSummarySchema>;
export type BridgeAnnotationSummary = z.infer<typeof bridgeAnnotationSummarySchema>;
export type BridgeReviewItemDescriptor = z.infer<typeof bridgeReviewItemDescriptorSchema>;
export type BridgeViewFilter = z.infer<typeof bridgeViewFilterSchema>;
export type BridgeChangeGroupingKind = z.infer<typeof bridgeChangeGroupingKindSchema>;
export type BridgeChangeGrouping = z.infer<typeof bridgeChangeGroupingSchema>;
export type BridgeProvenanceFilter = z.infer<typeof bridgeProvenanceFilterSchema>;
export type BridgeReviewQuery = z.infer<typeof bridgeReviewQuerySchema>;
export type BridgeReviewGroup = z.infer<typeof bridgeReviewGroupSchema>;
export type BridgeReviewPackageSummary = z.infer<typeof bridgeReviewPackageSummarySchema>;
export type BridgeReviewPackageFromSchema = z.infer<typeof bridgeReviewPackageSchema>;
export type BridgeReviewPackage = BridgeReviewPackageFromSchema;

export const bridgeReviewDeltaOperationsSchema = z
	.object({
		addItems: z.array(bridgeReviewItemDescriptorSchema),
		updateItems: z.array(bridgeReviewItemDescriptorSchema),
		removeItems: z.array(z.string()),
		moveItems: z.array(z.string()),
		updateGroups: z.array(bridgeReviewGroupSchema).nullable(),
		updateSummary: bridgeReviewPackageSummarySchema.nullable(),
		invalidateContent: z.array(z.string()),
	})
	.strict();

export const bridgeReviewDeltaSchema = z
	.object({
		packageId: z.string(),
		reviewGeneration: bridgeReviewGenerationSchema,
		revision: z.number().int().nonnegative(),
		operations: bridgeReviewDeltaOperationsSchema,
	})
	.strict();

export type BridgeReviewDeltaFromSchema = z.infer<typeof bridgeReviewDeltaSchema>;
export type BridgeReviewDelta = BridgeReviewDeltaFromSchema;

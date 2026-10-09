import { z } from 'zod';

import { bridgeProductReviewComparisonTargetsContentDescriptorSchema } from './bridge-product-content-contracts.js';
import {
	type BridgeProductAssert,
	bridgeProductDisplayPathSchema,
	bridgeProductIdentifierSchema,
	bridgeProductUnicodeScalarUtf8ByteLength,
	type BridgeProductRegistryValue,
	type BridgeProductTypeSetsEqual,
} from './bridge-product-contract-primitives.js';
import { bridgeProductReviewComparisonTargetSchema } from './bridge-product-review-comparison-contracts.js';
import { bridgeProductReviewPublicationIdSchema } from './bridge-product-review-primitives.js';
import { bridgeProductFileSourceConfigurationSchema } from './bridge-product-subscription-contracts.js';
import {
	bridgeProductWorktreeAnnotationCommandOutcomeSchema,
	bridgeProductWorktreeAnnotationDecodedCommandOutcomeSchema,
} from './bridge-product-worktree-annotation-contracts.js';
import {
	bridgeProductWorktreeAnnotationOutputInspectRequestSchema,
	bridgeProductWorktreeAnnotationOutputInspectResultSchema,
} from './bridge-product-worktree-annotation-output-contracts.js';
import {
	bridgeProductAnnotationProjectionQueryRequestSchema,
	bridgeProductAnnotationProjectionQueryResultSchema,
	bridgeProductReviewAnnotationPublicationIdentitySchema,
	type BridgeProductReviewAnnotationPublicationIdentity,
} from './bridge-product-worktree-annotation-projection-query-contracts.js';

export { bridgeProductWorktreeAnnotationOutputInspectResultSchema } from './bridge-product-worktree-annotation-output-contracts.js';

export { bridgeProductReviewComparisonTargetSchema } from './bridge-product-review-comparison-contracts.js';

export const bridgeProductFileSourceCurrentRequestSchema = z.object({}).strict();
export const bridgeProductFileRefreshRetryRequestSchema = z.object({}).strict();
export const bridgeProductFileRefreshRetryResultSchema = z.null();
export const bridgeProductFileSourceCurrentResultSchema = z.discriminatedUnion('status', [
	z
		.object({
			source: bridgeProductFileSourceConfigurationSchema,
			status: z.literal('available'),
		})
		.strict(),
	z
		.object({
			reason: z.literal('no-file-source-authority'),
			status: z.literal('unavailable'),
		})
		.strict(),
]);

export const bridgeProductReviewMarkFileViewedRequestSchema = z
	.object({ itemId: bridgeProductIdentifierSchema })
	.strict();
export const bridgeProductReviewMarkFileViewedResultSchema = z.null();
export const bridgeProductReviewIntakeReadyRequestSchema = z
	.object({
		reason: bridgeProductIdentifierSchema.nullable(),
		streamId: bridgeProductIdentifierSchema.nullable(),
	})
	.strict();
export const bridgeProductReviewIntakeReadyResultSchema = z.null();
export const bridgeProductReviewPublicationAppliedRequestSchema = z
	.object({ publicationId: bridgeProductReviewPublicationIdSchema })
	.strict();
export const bridgeProductReviewPublicationAppliedResultSchema = z.null();
export const bridgeProductReviewPublicationInstallAdmissionRequestSchema = z
	.object({
		candidatePublicationId: bridgeProductReviewPublicationIdSchema,
		expectedDisplayedPublicationId: bridgeProductReviewPublicationIdSchema.nullable(),
	})
	.strict();
export const bridgeProductReviewPublicationInstallAdmissionResultSchema = z
	.object({ status: z.enum(['admitted', 'rejected']) })
	.strict();

export const bridgeProductReviewComparisonUpdateRequestSchema = z
	.object({ target: bridgeProductReviewComparisonTargetSchema })
	.strict();
export const bridgeProductReviewComparisonUpdateResultSchema = z.null();
export const bridgeProductReviewComparisonTargetsQueryRequestSchema = z.object({}).strict();
export const bridgeProductReviewComparisonTargetsQueryResultSchema = z
	.object({
		descriptor: bridgeProductReviewComparisonTargetsContentDescriptorSchema,
	})
	.strict();

const bridgeProductActiveViewerSourceBaseSchema = z
	.object({
		generation: z.number().int().nonnegative(),
		streamId: bridgeProductIdentifierSchema,
	})
	.strict();

export const bridgeProductReviewActiveViewerModeUpdateRequestSchema = z
	.object({
		activeSource: bridgeProductActiveViewerSourceBaseSchema.nullable(),
		nativeSelectionRequestId: bridgeProductIdentifierSchema.nullable(),
		sequence: z.number().int().positive(),
		sessionId: bridgeProductIdentifierSchema,
	})
	.strict();
export const bridgeProductFileActiveViewerModeUpdateRequestSchema = z
	.object({
		activeSource: bridgeProductActiveViewerSourceBaseSchema.nullable(),
		nativeSelectionRequestId: bridgeProductIdentifierSchema.nullable(),
		sequence: z.number().int().positive(),
		sessionId: bridgeProductIdentifierSchema,
	})
	.strict();
export const bridgeProductActiveViewerModeUpdateResultSchema = z.null();

const bridgeProductWorktreeAnnotationIdSchema = bridgeProductReviewPublicationIdSchema;
const bridgeProductWorktreeAnnotationBodySchema = z
	.string()
	.refine((body) => body.trim().length > 0, 'Annotation bodies cannot be empty.')
	.refine((body) => {
		const byteLength = bridgeProductUnicodeScalarUtf8ByteLength(body);
		return byteLength !== null && byteLength <= 16 * 1024;
	}, 'Annotation bodies cannot exceed 16 KiB of UTF-8.');
const bridgeProductWorktreeAnnotationDraftEditBodySchema = z.string().refine((body) => {
	const byteLength = bridgeProductUnicodeScalarUtf8ByteLength(body);
	return byteLength !== null && byteLength <= 16 * 1024;
}, 'Annotation draft edits cannot exceed 16 KiB of UTF-8.');
const bridgeProductWorktreeAnnotationAdmissionSchema = z.discriminatedUnion('kind', [
	z.object({ kind: z.literal('implicitOrSingle') }).strict(),
	z.object({ kind: z.literal('newSession') }).strict(),
	z
		.object({
			kind: z.literal('selected'),
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
		})
		.strict(),
]);
const bridgeProductWorktreeAnnotationOriginSchema = z
	.object({
		diffSide: z.enum(['additions', 'deletions']).nullable(),
		endLine: z.number().int().positive(),
		kind: z.literal('located'),
		path: bridgeProductDisplayPathSchema,
		sourceIdentity: bridgeProductIdentifierSchema,
		sourceRole: z.enum(['file', 'reviewBase', 'reviewHead']),
		startLine: z.number().int().positive(),
	})
	.strict()
	.refine((origin) => origin.endLine >= origin.startLine, {
		message: 'Annotation endLine cannot precede startLine.',
	});
const bridgeProductWorktreeAnnotationViewedItemSchema = z
	.object({
		expectedSavedRevision: z.number().int().positive(),
		messageId: bridgeProductWorktreeAnnotationIdSchema,
	})
	.strict();
export const bridgeProductWorktreeAnnotationOperationSchema = z.discriminatedUnion('kind', [
	z.object({ kind: z.literal('session.discover') }).strict(),
	z
		.object({
			kind: z.literal('demand.acquire'),
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
		})
		.strict(),
	z
		.object({
			kind: z.literal('demand.release'),
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
		})
		.strict(),
	z
		.object({
			admission: bridgeProductWorktreeAnnotationAdmissionSchema,
			body: bridgeProductWorktreeAnnotationBodySchema,
			editToken: bridgeProductIdentifierSchema,
			kind: z.literal('root.create'),
			origin: bridgeProductWorktreeAnnotationOriginSchema,
		})
		.strict(),
	z
		.object({
			body: bridgeProductWorktreeAnnotationBodySchema,
			editToken: bridgeProductIdentifierSchema,
			expectedThreadRevision: z.number().int().nonnegative(),
			kind: z.literal('reply.create'),
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
			threadId: bridgeProductWorktreeAnnotationIdSchema,
		})
		.strict(),
	z
		.object({
			body: bridgeProductWorktreeAnnotationDraftEditBodySchema,
			editToken: bridgeProductIdentifierSchema,
			expectedDraftRevision: z.number().int().nonnegative().nullable(),
			expectedMessageRevision: z.number().int().nonnegative(),
			kind: z.literal('draft.flush'),
			messageId: bridgeProductWorktreeAnnotationIdSchema,
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
		})
		.strict(),
	...(['draft.edit.acquire', 'draft.edit.release'] as const).map((kind) =>
		z
			.object({
				editToken: bridgeProductIdentifierSchema,
				expectedDraftRevision: z.number().int().nonnegative(),
				expectedMessageRevision: z.number().int().nonnegative(),
				kind: z.literal(kind),
				messageId: bridgeProductWorktreeAnnotationIdSchema,
				sessionId: bridgeProductWorktreeAnnotationIdSchema,
			})
			.strict(),
	),
	...(['draft.save', 'draft.revert'] as const).map((kind) =>
		z
			.object({
				editToken: bridgeProductIdentifierSchema,
				expectedDraftRevision: z.number().int().nonnegative(),
				expectedMessageRevision: z.number().int().nonnegative(),
				kind: z.literal(kind),
				messageId: bridgeProductWorktreeAnnotationIdSchema,
				sessionId: bridgeProductWorktreeAnnotationIdSchema,
			})
			.strict(),
	),
	z
		.object({
			expectedThreadRevision: z.number().int().nonnegative(),
			kind: z.literal('thread.resolution.set'),
			resolution: z.enum(['open', 'resolved']),
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
			threadId: bridgeProductWorktreeAnnotationIdSchema,
		})
		.strict(),
	z
		.object({
			decision: z.enum(['acceptCurrentSource', 'keepDetached']),
			expectedSessionRevision: z.number().int().nonnegative(),
			kind: z.literal('continuity.choose'),
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
		})
		.strict(),
	z
		.object({
			kind: z.literal('source.refresh'),
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
			sourceEpoch: z.number().int().nonnegative(),
		})
		.strict(),
	z
		.object({
			items: z
				.array(bridgeProductWorktreeAnnotationViewedItemSchema)
				.min(1)
				.max(256)
				.refine(
					(items) =>
						new Set(items.map((item) => `${item.messageId}:${item.expectedSavedRevision}`)).size ===
						items.length,
					{ message: 'Viewed annotation items must be unique.' },
				),
			kind: z.literal('message.viewed.mark'),
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
		})
		.strict(),
	z
		.object({
			attemptId: bridgeProductWorktreeAnnotationIdSchema,
			expectedSessionRevision: z.number().int().nonnegative(),
			kind: z.literal('output.handled.clear'),
		})
		.strict(),
	z
		.object({
			destination: z.enum(['remembered', 'choose']).optional(),
			displayedProjectionRevision: z.number().int().nonnegative(),
			expectedSessionRevision: z.number().int().nonnegative(),
			kind: z.literal('output.scope.commit'),
			outputKind: z.enum(['clipboardMarkdown', 'jsonFile']),
			scope: z.enum(['pending', 'all']),
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
			sourceGeneration: z.number().int().nonnegative(),
		})
		.strict()
		.refine(
			(operation) =>
				operation.outputKind === 'jsonFile'
					? operation.destination !== undefined
					: operation.destination === undefined,
			{ message: 'Only JSON export requires a destination.' },
		),
	z.object({ kind: z.literal('output.preference.changeFolder') }).strict(),
	z
		.object({
			attemptId: bridgeProductWorktreeAnnotationIdSchema,
			kind: z.literal('output.reveal'),
		})
		.strict(),
	z
		.object({
			kind: z.literal('output.history'),
			sessionId: bridgeProductWorktreeAnnotationIdSchema,
		})
		.strict(),
	z
		.object({
			attemptId: bridgeProductWorktreeAnnotationIdSchema,
			kind: z.literal('output.repeat'),
		})
		.strict(),
	z.object({ kind: z.literal('recovery.acknowledge') }).strict(),
]);
export const bridgeProductFileWorktreeAnnotationCommandRequestSchema = z
	.object({ operation: bridgeProductWorktreeAnnotationOperationSchema })
	.strict();
export const bridgeProductReviewWorktreeAnnotationCommandRequestSchema = z
	.object({
		operation: bridgeProductWorktreeAnnotationOperationSchema,
		reviewPublicationIdentity: bridgeProductReviewAnnotationPublicationIdentitySchema,
	})
	.strict();
export const bridgeProductWorktreeAnnotationCommandResultSchema = z
	.object({
		kind: z.literal('completed'),
		outcome: bridgeProductWorktreeAnnotationCommandOutcomeSchema,
	})
	.strict();
export const bridgeProductWorktreeAnnotationDecodedCommandResultSchema = z
	.object({
		kind: z.literal('completed'),
		outcome: bridgeProductWorktreeAnnotationDecodedCommandOutcomeSchema,
	})
	.strict();

const bridgeProductFileAnnotationOutputInspectResultSchema =
	bridgeProductWorktreeAnnotationOutputInspectResultSchema.refine(
		(result) => result.descriptor.surface === 'file',
		{
			message: 'File annotation output descriptors must remain File-surface bound.',
			path: ['descriptor', 'surface'],
		},
	);
const bridgeProductReviewAnnotationOutputInspectResultSchema =
	bridgeProductWorktreeAnnotationOutputInspectResultSchema.refine(
		(result) => result.descriptor.surface === 'review',
		{
			message: 'Review annotation output descriptors must remain Review-surface bound.',
			path: ['descriptor', 'surface'],
		},
	);

export type BridgeProductWorktreeAnnotationOperation = z.infer<
	typeof bridgeProductWorktreeAnnotationOperationSchema
>;
export {
	bridgeProductReviewAnnotationPublicationIdentitySchema,
	type BridgeProductReviewAnnotationPublicationIdentity,
};

export type BridgeProductCallRegistry = {
	readonly 'file.annotations.command': {
		readonly request: z.infer<typeof bridgeProductFileWorktreeAnnotationCommandRequestSchema>;
		readonly result: z.infer<typeof bridgeProductWorktreeAnnotationCommandResultSchema>;
		readonly surface: 'file';
	};
	readonly 'file.annotations.output.inspect': {
		readonly request: z.infer<typeof bridgeProductWorktreeAnnotationOutputInspectRequestSchema>;
		readonly result: z.infer<typeof bridgeProductWorktreeAnnotationOutputInspectResultSchema>;
		readonly surface: 'file';
	};
	readonly 'file.annotations.projection.query': {
		readonly request: z.infer<typeof bridgeProductAnnotationProjectionQueryRequestSchema>;
		readonly result: z.infer<typeof bridgeProductAnnotationProjectionQueryResultSchema>;
		readonly surface: 'file';
	};
	readonly 'file.source.current': {
		readonly request: z.infer<typeof bridgeProductFileSourceCurrentRequestSchema>;
		readonly result: z.infer<typeof bridgeProductFileSourceCurrentResultSchema>;
		readonly surface: 'file';
	};
	readonly 'file.refresh.retry': {
		readonly request: z.infer<typeof bridgeProductFileRefreshRetryRequestSchema>;
		readonly result: z.infer<typeof bridgeProductFileRefreshRetryResultSchema>;
		readonly surface: 'file';
	};
	readonly 'file.activeViewerMode.update': {
		readonly request: z.infer<typeof bridgeProductFileActiveViewerModeUpdateRequestSchema>;
		readonly result: z.infer<typeof bridgeProductActiveViewerModeUpdateResultSchema>;
		readonly surface: 'file';
	};
	readonly 'review.markFileViewed': {
		readonly request: z.infer<typeof bridgeProductReviewMarkFileViewedRequestSchema>;
		readonly result: z.infer<typeof bridgeProductReviewMarkFileViewedResultSchema>;
		readonly surface: 'review';
	};
	readonly 'review.intake.ready': {
		readonly request: z.infer<typeof bridgeProductReviewIntakeReadyRequestSchema>;
		readonly result: z.infer<typeof bridgeProductReviewIntakeReadyResultSchema>;
		readonly surface: 'review';
	};
	readonly 'review.publication.applied': {
		readonly request: z.infer<typeof bridgeProductReviewPublicationAppliedRequestSchema>;
		readonly result: z.infer<typeof bridgeProductReviewPublicationAppliedResultSchema>;
		readonly surface: 'review';
	};
	readonly 'review.publication.install.admit': {
		readonly request: z.infer<typeof bridgeProductReviewPublicationInstallAdmissionRequestSchema>;
		readonly result: z.infer<typeof bridgeProductReviewPublicationInstallAdmissionResultSchema>;
		readonly surface: 'review';
	};
	readonly 'review.activeViewerMode.update': {
		readonly request: z.infer<typeof bridgeProductReviewActiveViewerModeUpdateRequestSchema>;
		readonly result: z.infer<typeof bridgeProductActiveViewerModeUpdateResultSchema>;
		readonly surface: 'review';
	};
	readonly 'review.comparison.update': {
		readonly request: z.infer<typeof bridgeProductReviewComparisonUpdateRequestSchema>;
		readonly result: z.infer<typeof bridgeProductReviewComparisonUpdateResultSchema>;
		readonly surface: 'review';
	};
	readonly 'review.comparisonTargets.query': {
		readonly request: z.infer<typeof bridgeProductReviewComparisonTargetsQueryRequestSchema>;
		readonly result: z.infer<typeof bridgeProductReviewComparisonTargetsQueryResultSchema>;
		readonly surface: 'review';
	};
	readonly 'review.annotations.command': {
		readonly request: z.infer<typeof bridgeProductReviewWorktreeAnnotationCommandRequestSchema>;
		readonly result: z.infer<typeof bridgeProductWorktreeAnnotationCommandResultSchema>;
		readonly surface: 'review';
	};
	readonly 'review.annotations.output.inspect': {
		readonly request: z.infer<typeof bridgeProductWorktreeAnnotationOutputInspectRequestSchema>;
		readonly result: z.infer<typeof bridgeProductWorktreeAnnotationOutputInspectResultSchema>;
		readonly surface: 'review';
	};
	readonly 'review.annotations.projection.query': {
		readonly request: z.infer<typeof bridgeProductAnnotationProjectionQueryRequestSchema>;
		readonly result: z.infer<typeof bridgeProductAnnotationProjectionQueryResultSchema>;
		readonly surface: 'review';
	};
};

export type BridgeProductCallKind = keyof BridgeProductCallRegistry;
export type BridgeProductCallRequest<TCallKind extends BridgeProductCallKind> =
	BridgeProductRegistryValue<BridgeProductCallRegistry, TCallKind, 'request'>;
export type BridgeProductCallResult<TCallKind extends BridgeProductCallKind> =
	BridgeProductRegistryValue<BridgeProductCallRegistry, TCallKind, 'result'>;

const bridgeProductSurfaceByCallKind = {
	'file.annotations.command': 'file',
	'file.annotations.output.inspect': 'file',
	'file.annotations.projection.query': 'file',
	'file.activeViewerMode.update': 'file',
	'file.source.current': 'file',
	'file.refresh.retry': 'file',
	'review.activeViewerMode.update': 'review',
	'review.comparison.update': 'review',
	'review.comparisonTargets.query': 'review',
	'review.intake.ready': 'review',
	'review.markFileViewed': 'review',
	'review.publication.applied': 'review',
	'review.publication.install.admit': 'review',
	'review.annotations.command': 'review',
	'review.annotations.output.inspect': 'review',
	'review.annotations.projection.query': 'review',
} as const satisfies {
	readonly [TCallKind in BridgeProductCallKind]: BridgeProductCallRegistry[TCallKind]['surface'];
};

export function bridgeProductSurfaceForCallKind<TCallKind extends BridgeProductCallKind>(
	callKind: TCallKind,
): BridgeProductCallRegistry[TCallKind]['surface'] {
	return bridgeProductSurfaceByCallKind[callKind];
}

export const bridgeProductCallRequestSchema = z.discriminatedUnion('method', [
	z
		.object({
			method: z.literal('file.annotations.projection.query'),
			request: bridgeProductAnnotationProjectionQueryRequestSchema.refine(
				(request) => request.surface === 'file',
				{ message: 'File annotation projection query must remain File-surface bound.' },
			),
		})
		.strict(),
	z
		.object({
			method: z.literal('file.annotations.command'),
			request: bridgeProductFileWorktreeAnnotationCommandRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('file.annotations.output.inspect'),
			request: bridgeProductWorktreeAnnotationOutputInspectRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('file.source.current'),
			request: bridgeProductFileSourceCurrentRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('file.refresh.retry'),
			request: bridgeProductFileRefreshRetryRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('file.activeViewerMode.update'),
			request: bridgeProductFileActiveViewerModeUpdateRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.activeViewerMode.update'),
			request: bridgeProductReviewActiveViewerModeUpdateRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.comparison.update'),
			request: bridgeProductReviewComparisonUpdateRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.comparisonTargets.query'),
			request: bridgeProductReviewComparisonTargetsQueryRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.markFileViewed'),
			request: bridgeProductReviewMarkFileViewedRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.intake.ready'),
			request: bridgeProductReviewIntakeReadyRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.publication.applied'),
			request: bridgeProductReviewPublicationAppliedRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.publication.install.admit'),
			request: bridgeProductReviewPublicationInstallAdmissionRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.annotations.command'),
			request: bridgeProductReviewWorktreeAnnotationCommandRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.annotations.output.inspect'),
			request: bridgeProductWorktreeAnnotationOutputInspectRequestSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.annotations.projection.query'),
			request: bridgeProductAnnotationProjectionQueryRequestSchema.refine(
				(request) => request.surface === 'review',
				{ message: 'Review annotation projection query must remain Review-surface bound.' },
			),
		})
		.strict(),
]);

export const bridgeProductCallResultSchema = z.discriminatedUnion('method', [
	z
		.object({
			method: z.literal('file.annotations.projection.query'),
			result: bridgeProductAnnotationProjectionQueryResultSchema.refine(
				(result) => result.kind === 'source_stale' || result.descriptor.surface === 'file',
				{ message: 'File annotation projection descriptor must remain File-surface bound.' },
			),
		})
		.strict(),
	z
		.object({
			method: z.literal('file.annotations.command'),
			result: bridgeProductWorktreeAnnotationCommandResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('file.annotations.output.inspect'),
			result: bridgeProductFileAnnotationOutputInspectResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('file.source.current'),
			result: bridgeProductFileSourceCurrentResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('file.refresh.retry'),
			result: bridgeProductFileRefreshRetryResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('file.activeViewerMode.update'),
			result: bridgeProductActiveViewerModeUpdateResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.activeViewerMode.update'),
			result: bridgeProductActiveViewerModeUpdateResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.comparison.update'),
			result: bridgeProductReviewComparisonUpdateResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.comparisonTargets.query'),
			result: bridgeProductReviewComparisonTargetsQueryResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.markFileViewed'),
			result: bridgeProductReviewMarkFileViewedResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.intake.ready'),
			result: bridgeProductReviewIntakeReadyResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.publication.applied'),
			result: bridgeProductReviewPublicationAppliedResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.publication.install.admit'),
			result: bridgeProductReviewPublicationInstallAdmissionResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.annotations.command'),
			result: bridgeProductWorktreeAnnotationCommandResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.annotations.output.inspect'),
			result: bridgeProductReviewAnnotationOutputInspectResultSchema,
		})
		.strict(),
	z
		.object({
			method: z.literal('review.annotations.projection.query'),
			result: bridgeProductAnnotationProjectionQueryResultSchema.refine(
				(result) => result.kind === 'source_stale' || result.descriptor.surface === 'review',
				{ message: 'Review annotation projection descriptor must remain Review-surface bound.' },
			),
		})
		.strict(),
]);

export type BridgeProductCallRequestWire = z.infer<typeof bridgeProductCallRequestSchema>;
export type BridgeProductCallResultWire = z.infer<typeof bridgeProductCallResultSchema>;
export type BridgeProductCallRequestRegistryParity = BridgeProductAssert<
	BridgeProductTypeSetsEqual<BridgeProductCallRequestWire['method'], BridgeProductCallKind>
>;
export type BridgeProductCallResultRegistryParity = BridgeProductAssert<
	BridgeProductTypeSetsEqual<BridgeProductCallResultWire['method'], BridgeProductCallKind>
>;

export function bridgeProductCallResultForMethod<TCallKind extends BridgeProductCallKind>(
	method: TCallKind,
	call: BridgeProductCallResultWire,
): BridgeProductCallResult<TCallKind> {
	switch (method) {
		case 'file.annotations.command':
			if (call.method !== 'file.annotations.command') {
				throw new Error('Bridge product File annotation command returned a cross-wired result.');
			}
			return call.result;
		case 'file.annotations.output.inspect':
			if (call.method !== 'file.annotations.output.inspect') {
				throw new Error('Bridge product File annotation inspection returned a cross-wired result.');
			}
			return call.result;
		case 'file.annotations.projection.query':
			if (call.method !== 'file.annotations.projection.query') {
				throw new Error(
					'Bridge product File annotation projection query returned a cross-wired result.',
				);
			}
			return call.result;
		case 'file.source.current':
			if (call.method !== 'file.source.current') {
				throw new Error('Bridge product File source call returned a cross-wired result.');
			}
			return call.result;
		case 'file.refresh.retry':
		case 'file.activeViewerMode.update':
		case 'review.activeViewerMode.update':
		case 'review.comparison.update':
		case 'review.intake.ready':
		case 'review.markFileViewed':
		case 'review.publication.applied':
			if (call.result !== null) {
				throw new Error('Bridge product null-result call returned a non-null result.');
			}
			return null;
		case 'review.comparisonTargets.query':
			if (call.method !== 'review.comparisonTargets.query') {
				throw new Error('Bridge product comparison-target query returned a cross-wired result.');
			}
			return call.result;
		case 'review.publication.install.admit':
			if (call.method !== 'review.publication.install.admit') {
				throw new Error(
					'Bridge product Review publication install admission returned a cross-wired result.',
				);
			}
			return call.result;
		case 'review.annotations.command':
			if (call.method !== 'review.annotations.command') {
				throw new Error('Bridge product Review annotation command returned a cross-wired result.');
			}
			return call.result;
		case 'review.annotations.output.inspect':
			if (call.method !== 'review.annotations.output.inspect') {
				throw new Error(
					'Bridge product Review annotation inspection returned a cross-wired result.',
				);
			}
			return call.result;
		case 'review.annotations.projection.query':
			if (call.method !== 'review.annotations.projection.query') {
				throw new Error(
					'Bridge product Review annotation projection query returned a cross-wired result.',
				);
			}
			return call.result;
		default:
			return assertNeverBridgeProductCallKind(method);
	}
}

function assertNeverBridgeProductCallKind(callKind: never): never {
	throw new Error(`Unhandled Bridge product call kind: ${String(callKind)}`);
}

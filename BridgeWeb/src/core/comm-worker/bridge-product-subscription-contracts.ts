import { z } from 'zod';

import type { BridgeDemandLane } from '../models/bridge-demand-models.js';
import { bridgeProductFileContentDescriptorSchema } from './bridge-product-content-contracts.js';
import {
	type BridgeProductAssert,
	bridgeProductDemandLaneSchema,
	bridgeProductDisplayPathSchema,
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
	bridgeProductOpaqueReferenceSchema,
	bridgeProductSafeMessageSchema,
	type BridgeProductTypeSetsEqual,
} from './bridge-product-contract-primitives.js';
import {
	bridgeProductFileSourceIdentitySchema,
	type BridgeProductFileSourceIdentity,
} from './bridge-product-file-contracts.js';
import type { BridgeProductMetadataApplicationOptions } from './bridge-product-metadata-application-protocol.js';
import type { BridgeProductRegisteredMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import { bridgeProductReviewMetadataEventSchema } from './bridge-product-review-metadata-contracts.js';
import { bridgeProductWorktreeAnnotationEventSchema } from './bridge-product-worktree-annotation-contracts.js';

export {
	bridgeProductFileSourceIdentitySchema,
	type BridgeProductFileSourceIdentity,
} from './bridge-product-file-contracts.js';
export {
	bridgeProductFileChangeStatusSchema,
	bridgeProductFileTreeFileClassSchema,
	bridgeProductFileTreeRowSchema,
	type BridgeProductFileTreeFileClass,
} from './bridge-product-file-tree-contracts.js';

export type BridgeProductDemandLaneParity = BridgeProductAssert<
	BridgeProductTypeSetsEqual<z.infer<typeof bridgeProductDemandLaneSchema>, BridgeDemandLane>
>;

export const bridgeProductFileSourceConfigurationSchema = z
	.object({
		cwdScope: bridgeProductDisplayPathSchema.nullable(),
		freshness: z.literal('live'),
		includeStatuses: z.boolean(),
		repoId: z.uuid(),
		rootPathToken: bridgeProductOpaqueReferenceSchema,
		worktreeId: z.uuid(),
	})
	.strict();

export const bridgeProductFileVirtualizedExtentKindSchema = z.enum([
	'exactLineCount',
	'estimatedHeight',
	'previewBounded',
	'unavailable',
]);

export const bridgeProductFileTruncationKindSchema = z.enum([
	'none',
	'byteLimit',
	'lineLimit',
	'both',
]);

const bridgeProductFileDescriptorAvailabilitySchema = z.discriminatedUnion('availabilityKind', [
	z
		.object({
			availabilityKind: z.literal('available'),
			contentDescriptor: bridgeProductFileContentDescriptorSchema,
		})
		.strict(),
	z.object({ availabilityKind: z.literal('binary') }).strict(),
	z
		.object({
			availabilityKind: z.literal('unavailable'),
			reason: z.enum(['unreadable', 'unsupported_encoding', 'outside_scope']),
		})
		.strict(),
]);

const bridgeProductFileDescriptorReadyPayloadShape = {
	availability: bridgeProductFileDescriptorAvailabilitySchema,
	encoding: z.literal('utf-8').nullable(),
	endsMidLine: z.boolean(),
	endsWithNewline: z.boolean(),
	estimatedContentHeightPixels: z.number().finite().nonnegative().nullable(),
	fileExtension: bridgeProductSafeMessageSchema.nullable(),
	fileId: bridgeProductIdentifierSchema,
	language: bridgeProductSafeMessageSchema.nullable(),
	modifiedAtUnixMilliseconds: bridgeProductNonnegativeSequenceSchema.nullable(),
	path: bridgeProductDisplayPathSchema,
	payloadByteCount: bridgeProductNonnegativeSequenceSchema,
	payloadLineCount: bridgeProductNonnegativeSequenceSchema,
	rowId: bridgeProductIdentifierSchema,
	sizeBytes: bridgeProductNonnegativeSequenceSchema,
	source: bridgeProductFileSourceIdentitySchema,
	totalLineCount: bridgeProductNonnegativeSequenceSchema.nullable(),
	truncationKind: bridgeProductFileTruncationKindSchema,
	virtualizedExtentKind: bridgeProductFileVirtualizedExtentKindSchema,
} as const;

export const bridgeProductFileDescriptorReadyPayloadSchema = z
	.object(bridgeProductFileDescriptorReadyPayloadShape)
	.strict()
	.superRefine((descriptor, context): void => {
		if (
			descriptor.virtualizedExtentKind === 'exactLineCount' &&
			descriptor.totalLineCount === null
		) {
			context.addIssue({
				code: 'custom',
				message: 'Exact File metadata extents require a total line count.',
				path: ['totalLineCount'],
			});
		}
		if (
			descriptor.availability.availabilityKind === 'available' &&
			(descriptor.availability.contentDescriptor.fileId !== descriptor.fileId ||
				!bridgeProductFileSourceIdentitiesEqual(
					descriptor.availability.contentDescriptor.source,
					descriptor.source,
				))
		) {
			context.addIssue({
				code: 'custom',
				message: 'File metadata and content descriptor identities must match.',
				path: ['availability', 'contentDescriptor', 'fileId'],
			});
		}
		validateBridgeProductFileExtentFacts(descriptor, context);
		validateBridgeProductFilePrefixFacts(descriptor, context);
	});

function validateBridgeProductFileExtentFacts(
	descriptor: z.infer<z.ZodObject<typeof bridgeProductFileDescriptorReadyPayloadShape>>,
	context: z.RefinementCtx,
): void {
	if (
		descriptor.virtualizedExtentKind === 'estimatedHeight' ||
		descriptor.estimatedContentHeightPixels !== null
	) {
		addBridgeProductFilePrefixIssue(
			context,
			'File metadata cannot fabricate an estimated display height.',
			['virtualizedExtentKind'],
		);
	}
	if (descriptor.availability.availabilityKind !== 'available') {
		if (descriptor.virtualizedExtentKind !== 'unavailable') {
			addBridgeProductFilePrefixIssue(
				context,
				'Binary and unavailable File descriptors require an unavailable extent.',
				['virtualizedExtentKind'],
			);
		}
		return;
	}
	const expectedExtentKind =
		descriptor.truncationKind === 'none' ? 'exactLineCount' : 'previewBounded';
	if (descriptor.virtualizedExtentKind !== expectedExtentKind) {
		addBridgeProductFilePrefixIssue(
			context,
			'Available File descriptor extent must match complete or truncated prefix facts.',
			['virtualizedExtentKind'],
		);
	}
}

function validateBridgeProductFilePrefixFacts(
	descriptor: z.infer<z.ZodObject<typeof bridgeProductFileDescriptorReadyPayloadShape>>,
	context: z.RefinementCtx,
): void {
	if (descriptor.payloadByteCount > descriptor.sizeBytes) {
		addBridgeProductFilePrefixIssue(
			context,
			'File payload bytes cannot exceed the authoritative source byte count.',
			['payloadByteCount'],
		);
	}
	if (
		descriptor.totalLineCount !== null &&
		descriptor.payloadLineCount > descriptor.totalLineCount
	) {
		addBridgeProductFilePrefixIssue(
			context,
			'File payload lines cannot exceed the authoritative total line count.',
			['payloadLineCount'],
		);
	}
	if (descriptor.endsMidLine && descriptor.endsWithNewline) {
		addBridgeProductFilePrefixIssue(
			context,
			'A File payload cannot end both mid-line and with a newline.',
			['endsMidLine'],
		);
	}
	if (
		(descriptor.payloadByteCount === 0 && descriptor.payloadLineCount !== 0) ||
		(descriptor.payloadByteCount > 0 && descriptor.payloadLineCount === 0)
	) {
		addBridgeProductFilePrefixIssue(
			context,
			'File payload byte and line emptiness facts must agree.',
			['payloadLineCount'],
		);
	}
	if (descriptor.payloadByteCount === 0 && (descriptor.endsMidLine || descriptor.endsWithNewline)) {
		addBridgeProductFilePrefixIssue(
			context,
			'An empty File payload cannot carry a terminal line-boundary fact.',
			['endsWithNewline'],
		);
	}

	if (descriptor.availability.availabilityKind !== 'available') {
		validateBridgeProductUnavailableFilePrefixFacts(descriptor, context);
		return;
	}
	validateBridgeProductAvailableFilePrefixFacts(descriptor, context);
}

function validateBridgeProductUnavailableFilePrefixFacts(
	descriptor: z.infer<z.ZodObject<typeof bridgeProductFileDescriptorReadyPayloadShape>>,
	context: z.RefinementCtx,
): void {
	if (
		descriptor.encoding !== null ||
		descriptor.payloadByteCount !== 0 ||
		descriptor.payloadLineCount !== 0 ||
		descriptor.totalLineCount !== null ||
		descriptor.truncationKind !== 'none' ||
		descriptor.endsMidLine ||
		descriptor.endsWithNewline
	) {
		addBridgeProductFilePrefixIssue(
			context,
			'Binary and unavailable File descriptors must carry explicit empty prefix facts.',
			['availability'],
		);
	}
}

function validateBridgeProductAvailableFilePrefixFacts(
	descriptor: z.infer<z.ZodObject<typeof bridgeProductFileDescriptorReadyPayloadShape>>,
	context: z.RefinementCtx,
): void {
	if (descriptor.availability.availabilityKind !== 'available') {
		return;
	}
	const contentDescriptor = descriptor.availability.contentDescriptor;
	if (descriptor.encoding !== 'utf-8') {
		addBridgeProductFilePrefixIssue(
			context,
			'Available File descriptors require literal UTF-8 encoding.',
			['encoding'],
		);
	}
	if (contentDescriptor.declaredByteLength !== descriptor.payloadByteCount) {
		addBridgeProductFilePrefixIssue(
			context,
			'File content declared bytes must equal the descriptor payload byte count.',
			['availability', 'contentDescriptor', 'declaredByteLength'],
		);
	}
	if (descriptor.payloadByteCount > contentDescriptor.window.maximumBytes) {
		addBridgeProductFilePrefixIssue(
			context,
			'File payload bytes exceed the declared prefix window.',
			['payloadByteCount'],
		);
	}
	if (descriptor.payloadLineCount > contentDescriptor.window.maximumLines) {
		addBridgeProductFilePrefixIssue(
			context,
			'File payload lines exceed the declared prefix window.',
			['payloadLineCount'],
		);
	}

	const isTruncated = descriptor.truncationKind !== 'none';
	if (isTruncated === (descriptor.payloadByteCount === descriptor.sizeBytes)) {
		addBridgeProductFilePrefixIssue(
			context,
			'File truncation must agree with payload and source byte counts.',
			['truncationKind'],
		);
	}
	if (descriptor.truncationKind === 'none') {
		if (descriptor.endsMidLine) {
			addBridgeProductFilePrefixIssue(context, 'An untruncated File payload cannot end mid-line.', [
				'endsMidLine',
			]);
		}
		if (
			descriptor.totalLineCount !== null &&
			descriptor.totalLineCount !== descriptor.payloadLineCount
		) {
			addBridgeProductFilePrefixIssue(
				context,
				'An untruncated File payload must equal the authoritative total line count.',
				['totalLineCount'],
			);
		}
		return;
	}
	if (descriptor.endsMidLine && descriptor.truncationKind === 'lineLimit') {
		addBridgeProductFilePrefixIssue(
			context,
			'A line-limited File payload must stop at a complete line terminator.',
			['endsMidLine'],
		);
	}
	if (
		(descriptor.truncationKind === 'lineLimit' || descriptor.truncationKind === 'both') &&
		descriptor.payloadLineCount !== contentDescriptor.window.maximumLines
	) {
		addBridgeProductFilePrefixIssue(
			context,
			'Line-limited File payloads must fill the declared line window.',
			['payloadLineCount'],
		);
	}
	if (
		descriptor.truncationKind === 'lineLimit' &&
		(!descriptor.endsWithNewline || descriptor.endsMidLine)
	) {
		addBridgeProductFilePrefixIssue(
			context,
			'A line-limited File payload must end with a newline.',
			['endsWithNewline'],
		);
	}
	if (
		(descriptor.truncationKind === 'byteLimit' || descriptor.truncationKind === 'both') &&
		descriptor.sizeBytes <= contentDescriptor.window.maximumBytes
	) {
		addBridgeProductFilePrefixIssue(
			context,
			'Byte-limited File payloads require a source larger than the byte window.',
			['sizeBytes'],
		);
	}
	if (
		descriptor.truncationKind === 'byteLimit' &&
		descriptor.payloadLineCount >= contentDescriptor.window.maximumLines
	) {
		addBridgeProductFilePrefixIssue(
			context,
			'A byte-only File truncation cannot also fill the line window.',
			['payloadLineCount'],
		);
	}
}

function addBridgeProductFilePrefixIssue(
	context: z.RefinementCtx,
	message: string,
	path: readonly PropertyKey[],
): void {
	context.addIssue({ code: 'custom', message, path: [...path] });
}

function bridgeProductFileSourceIdentitiesEqual(
	left: BridgeProductFileSourceIdentity,
	right: BridgeProductFileSourceIdentity,
): boolean {
	return (
		left.repoId === right.repoId &&
		left.rootRevisionToken === right.rootRevisionToken &&
		left.sourceCursor === right.sourceCursor &&
		left.sourceId === right.sourceId &&
		left.subscriptionGeneration === right.subscriptionGeneration &&
		left.worktreeId === right.worktreeId
	);
}

export type BridgeProductSubscriptionKind =
	BridgeProductRegisteredMetadataApplicationProtocol['kind'];
export const bridgeProductSubscriptionKindSchema = z.enum([
	'file.annotations',
	'file.metadata',
	'review.annotations',
	'review.metadata',
]);

type BridgeProductProtocolForSubscriptionKind<
	TSubscriptionKind extends BridgeProductSubscriptionKind,
> = Extract<
	BridgeProductRegisteredMetadataApplicationProtocol,
	{ readonly kind: TSubscriptionKind }
>;

export type BridgeProductSubscriptionOptions<
	TSubscriptionKind extends BridgeProductSubscriptionKind,
> = BridgeProductMetadataApplicationOptions<
	BridgeProductProtocolForSubscriptionKind<TSubscriptionKind>
>;
export type BridgeProductSubscriptionEvent<
	TSubscriptionKind extends Exclude<BridgeProductSubscriptionKind, 'file.metadata'>,
> = TSubscriptionKind extends 'file.annotations'
	? z.infer<typeof bridgeProductFileAnnotationSubscriptionDataSchema>['event']
	: TSubscriptionKind extends 'review.annotations'
		? z.infer<typeof bridgeProductReviewAnnotationSubscriptionDataSchema>['event']
		: z.infer<typeof bridgeProductReviewMetadataSubscriptionDataSchema>['event'];
export const bridgeProductFileAnnotationSubscriptionDataSchema = z
	.object({
		event: bridgeProductWorktreeAnnotationEventSchema,
		subscriptionKind: z.literal('file.annotations'),
	})
	.strict();

export const bridgeProductReviewAnnotationSubscriptionDataSchema = z
	.object({
		event: bridgeProductWorktreeAnnotationEventSchema,
		subscriptionKind: z.literal('review.annotations'),
	})
	.strict();

export const bridgeProductReviewMetadataSubscriptionDataSchema = z
	.object({
		event: bridgeProductReviewMetadataEventSchema,
		subscriptionKind: z.literal('review.metadata'),
	})
	.strict();

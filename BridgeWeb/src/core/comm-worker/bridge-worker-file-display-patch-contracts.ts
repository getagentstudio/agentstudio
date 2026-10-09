import { z } from 'zod';

import {
	BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
	bridgeProductDisplayPathSchema,
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
	bridgeProductSafeMessageSchema,
} from './bridge-product-contract-primitives.js';
import { bridgeProductReviewFileClassSchema } from './bridge-product-review-primitives.js';
import {
	bridgeProductFileChangeStatusSchema,
	bridgeProductFileTruncationKindSchema,
} from './bridge-product-subscription-contracts.js';
import { bridgeWorkerFileQueryDisplayPayloadSchema } from './bridge-worker-file-query-contracts.js';

export const BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT = 256;
const bridgeWorkerFileDisplayMaximumPayloadLineCount = 10_000;

const bridgeWorkerFileTreeDisplayRowSchema = z
	.object({
		changeStatus: bridgeProductFileChangeStatusSchema.nullable(),
		depth: bridgeProductNonnegativeSequenceSchema,
		fileId: bridgeProductIdentifierSchema.nullable(),
		fileClass: bridgeProductReviewFileClassSchema.nullable(),
		isDirectory: z.boolean(),
		lineCount: bridgeProductNonnegativeSequenceSchema.nullable(),
		name: bridgeProductSafeMessageSchema,
		parentPath: bridgeProductDisplayPathSchema.nullable(),
		path: bridgeProductDisplayPathSchema,
		projectionIndex: bridgeProductNonnegativeSequenceSchema,
		rowId: bridgeProductIdentifierSchema,
		sizeBytes: bridgeProductNonnegativeSequenceSchema.nullable(),
	})
	.strict()
	.superRefine((row, context): void => {
		if (row.isDirectory && row.fileClass !== null) {
			context.addIssue({
				code: 'custom',
				message: 'File display directory rows cannot carry a file class.',
				path: ['fileClass'],
			});
		}
		if (!row.isDirectory && row.fileClass === null) {
			context.addIssue({
				code: 'custom',
				message: 'File display file rows require a path-and-size-backed file class.',
				path: ['fileClass'],
			});
		}
	});

const bridgeWorkerFileTreeDisplayOperationSchema = z.discriminatedUnion('operation', [
	z.object({ operation: z.literal('upsert'), row: bridgeWorkerFileTreeDisplayRowSchema }).strict(),
	z
		.object({
			operation: z.literal('remove'),
			path: bridgeProductDisplayPathSchema,
			rowId: bridgeProductIdentifierSchema,
		})
		.strict(),
]);

const bridgeWorkerFileTreeSourceIdentitySchema = z
	.object({
		sourceGeneration: bridgeProductNonnegativeSequenceSchema,
		sourceId: bridgeProductIdentifierSchema,
	})
	.strict();

const bridgeWorkerFileTreeDisplayPatchSchema = z.discriminatedUnion('operation', [
	z.object({ operation: z.literal('clear'), slice: z.literal('fileTree') }).strict(),
	z
		.object({
			operation: z.literal('reset'),
			payload: bridgeWorkerFileTreeSourceIdentitySchema,
			slice: z.literal('fileTree'),
		})
		.strict(),
	z
		.object({
			operation: z.literal('replacementCommit'),
			payload: bridgeWorkerFileTreeSourceIdentitySchema,
			slice: z.literal('fileTree'),
		})
		.strict(),
	z
		.object({
			operation: z.literal('batch'),
			payload: z
				.object({
					operations: z
						.array(bridgeWorkerFileTreeDisplayOperationSchema)
						.max(BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT)
						.readonly(),
				})
				.strict(),
			slice: z.literal('fileTree'),
		})
		.strict(),
]);

const bridgeWorkerFileItemDisplayExtentSchema = z.discriminatedUnion('kind', [
	z
		.object({
			kind: z.literal('exactLineCount'),
			lineCount: bridgeProductNonnegativeSequenceSchema,
		})
		.strict(),
	z.object({ kind: z.literal('previewBounded') }).strict(),
	z.object({ kind: z.literal('unavailable') }).strict(),
]);

const bridgeWorkerFileItemDisplayAvailabilitySchema = z.discriminatedUnion('kind', [
	z.object({ kind: z.literal('available') }).strict(),
	z.object({ kind: z.literal('binary') }).strict(),
	z
		.object({
			kind: z.literal('unavailable'),
			reason: z.enum(['unreadable', 'unsupported_encoding', 'outside_scope']),
		})
		.strict(),
]);

const bridgeWorkerFileItemDisplayPayloadShape = {
	availability: bridgeWorkerFileItemDisplayAvailabilitySchema,
	displayPath: bridgeProductDisplayPathSchema,
	endsMidLine: z.boolean(),
	endsWithNewline: z.boolean(),
	extent: bridgeWorkerFileItemDisplayExtentSchema,
	fileExtension: bridgeProductSafeMessageSchema.nullable(),
	language: bridgeProductSafeMessageSchema.nullable(),
	payloadByteCount: bridgeProductNonnegativeSequenceSchema,
	payloadLineCount: bridgeProductNonnegativeSequenceSchema,
	rowId: bridgeProductIdentifierSchema,
	sizeBytes: bridgeProductNonnegativeSequenceSchema,
	totalLineCount: bridgeProductNonnegativeSequenceSchema.nullable(),
	truncationKind: bridgeProductFileTruncationKindSchema,
} as const;

type BridgeWorkerFileItemDisplayPayloadDraft = z.infer<
	z.ZodObject<typeof bridgeWorkerFileItemDisplayPayloadShape>
>;

const bridgeWorkerFileItemDisplayPayloadSchema = z
	.object(bridgeWorkerFileItemDisplayPayloadShape)
	.strict()
	.superRefine(validateBridgeWorkerFileItemDisplayPayload);

const bridgeWorkerFileItemDisplayPatchSchema = z.discriminatedUnion('operation', [
	z
		.object({
			itemId: bridgeProductIdentifierSchema,
			operation: z.literal('upsert'),
			payload: bridgeWorkerFileItemDisplayPayloadSchema,
			slice: z.literal('fileItem'),
		})
		.strict(),
	z
		.object({
			itemId: bridgeProductIdentifierSchema,
			operation: z.literal('delete'),
			slice: z.literal('fileItem'),
		})
		.strict(),
	z.object({ operation: z.literal('reset'), slice: z.literal('fileItem') }).strict(),
]);

const bridgeWorkerFileStatusDisplayPayloadSchema = z.discriminatedUnion('state', [
	z
		.object({
			ahead: bridgeProductNonnegativeSequenceSchema.nullable(),
			behind: bridgeProductNonnegativeSequenceSchema.nullable(),
			branchName: bridgeProductSafeMessageSchema.nullable(),
			staged: bridgeProductNonnegativeSequenceSchema.nullable(),
			state: z.literal('ready'),
			unstaged: bridgeProductNonnegativeSequenceSchema.nullable(),
			untracked: bridgeProductNonnegativeSequenceSchema.nullable(),
		})
		.strict(),
	z.object({ state: z.enum(['loading', 'stale', 'failed', 'noSource']) }).strict(),
]);

const bridgeWorkerFileStatusDisplayPatchSchema = z.discriminatedUnion('operation', [
	z
		.object({
			operation: z.literal('upsert'),
			payload: bridgeWorkerFileStatusDisplayPayloadSchema,
			slice: z.literal('fileStatus'),
		})
		.strict(),
	z.object({ operation: z.literal('reset'), slice: z.literal('fileStatus') }).strict(),
]);

const bridgeWorkerFileQueryDisplayPatchSchema = z
	.object({
		operation: z.literal('upsert'),
		payload: bridgeWorkerFileQueryDisplayPayloadSchema,
		slice: z.literal('fileQuery'),
	})
	.strict();

export const bridgeWorkerFileDisplayPatchSchema = z.discriminatedUnion('slice', [
	bridgeWorkerFileTreeDisplayPatchSchema,
	bridgeWorkerFileItemDisplayPatchSchema,
	bridgeWorkerFileStatusDisplayPatchSchema,
	bridgeWorkerFileQueryDisplayPatchSchema,
]);

export type BridgeWorkerFileDisplayPatch = z.infer<typeof bridgeWorkerFileDisplayPatchSchema>;

function validateBridgeWorkerFileItemDisplayPayload(
	payload: BridgeWorkerFileItemDisplayPayloadDraft,
	context: z.RefinementCtx,
): void {
	if (payload.totalLineCount !== null && payload.payloadLineCount > payload.totalLineCount) {
		context.addIssue({
			code: 'custom',
			message: 'File display payload lines cannot exceed the total line count.',
			path: ['payloadLineCount'],
		});
	}
	if (payload.endsMidLine && payload.endsWithNewline) {
		context.addIssue({
			code: 'custom',
			message: 'File display payload cannot end both mid-line and with a newline.',
			path: ['endsMidLine'],
		});
	}
	if (
		(payload.payloadByteCount === 0 && payload.payloadLineCount !== 0) ||
		(payload.payloadByteCount > 0 && payload.payloadLineCount === 0)
	) {
		context.addIssue({
			code: 'custom',
			message: 'File display payload byte and line emptiness facts must agree.',
			path: ['payloadLineCount'],
		});
	}
	if (payload.availability.kind !== 'available') {
		if (
			payload.payloadByteCount !== 0 ||
			payload.payloadLineCount !== 0 ||
			payload.totalLineCount !== null ||
			payload.truncationKind !== 'none' ||
			payload.endsMidLine ||
			payload.endsWithNewline
		) {
			context.addIssue({
				code: 'custom',
				message: 'Unavailable File display items require explicit empty payload facts.',
				path: ['availability'],
			});
		}
		return;
	}
	const isTruncated = payload.truncationKind !== 'none';
	if (isTruncated === (payload.payloadByteCount === payload.sizeBytes)) {
		context.addIssue({
			code: 'custom',
			message: 'File display truncation must agree with payload and source bytes.',
			path: ['truncationKind'],
		});
	}
	if (payload.truncationKind === 'none' && payload.endsMidLine) {
		context.addIssue({
			code: 'custom',
			message: 'An untruncated File display payload cannot end mid-line.',
			path: ['endsMidLine'],
		});
	}
	if (
		(payload.truncationKind === 'lineLimit' || payload.truncationKind === 'both') &&
		payload.payloadLineCount !== bridgeWorkerFileDisplayMaximumPayloadLineCount
	) {
		context.addIssue({
			code: 'custom',
			message: 'Line-limited File display payloads must fill the line window.',
			path: ['payloadLineCount'],
		});
	}
	if (payload.truncationKind === 'lineLimit' && (!payload.endsWithNewline || payload.endsMidLine)) {
		context.addIssue({
			code: 'custom',
			message: 'A line-limited File display payload must end with a newline.',
			path: ['endsWithNewline'],
		});
	}
	if (
		(payload.truncationKind === 'byteLimit' || payload.truncationKind === 'both') &&
		payload.sizeBytes <= BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES
	) {
		context.addIssue({
			code: 'custom',
			message: 'Byte-limited File display payloads require a source larger than the byte cap.',
			path: ['sizeBytes'],
		});
	}
}

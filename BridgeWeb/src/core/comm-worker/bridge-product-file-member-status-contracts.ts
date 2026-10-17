import { z } from 'zod';

import {
	bridgeProductNonnegativeSequenceSchema,
	bridgeProductSafeMessageSchema,
} from './bridge-product-contract-primitives.js';
import { bridgeProductFileBatchRowSchema } from './bridge-product-file-batch-row-contracts.js';
import { bridgeProductFileSourceIdentitySchema } from './bridge-product-file-contracts.js';

export const BRIDGE_PRODUCT_FILE_MEMBER_STATUS_KEY = 'member-status';

export const bridgeProductFileMemberStatusRecordSchema = z
	.object({
		ahead: bridgeProductNonnegativeSequenceSchema.nullable(),
		behind: bridgeProductNonnegativeSequenceSchema.nullable(),
		branchName: bridgeProductSafeMessageSchema.nullable(),
		kind: z.literal('memberStatus'),
		source: bridgeProductFileSourceIdentitySchema,
		staged: bridgeProductNonnegativeSequenceSchema.nullable(),
		status: z.enum(['loading', 'ready', 'stale', 'failed']),
		unstaged: bridgeProductNonnegativeSequenceSchema.nullable(),
		untracked: bridgeProductNonnegativeSequenceSchema.nullable(),
	})
	.strict();

export const bridgeProductFileBatchRecordSchema = z.union([
	bridgeProductFileBatchRowSchema,
	bridgeProductFileMemberStatusRecordSchema,
]);

export type BridgeProductFileMemberStatusRecord = z.infer<
	typeof bridgeProductFileMemberStatusRecordSchema
>;
export type BridgeProductFileBatchRecord = z.infer<typeof bridgeProductFileBatchRecordSchema>;

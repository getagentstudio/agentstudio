import { z } from 'zod';

import { bridgeProductFileContentDescriptorSchema } from './bridge-product-content-contracts.js';
import {
	bridgeProductDisplayPathSchema,
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
} from './bridge-product-contract-primitives.js';
import { bridgeProductFileChangeStatusSchema } from './bridge-product-file-tree-contracts.js';
import { bridgeProductReviewFileClassSchema } from './bridge-product-review-primitives.js';
import { bridgeProductFileDescriptorReadyPayloadSchema } from './bridge-product-subscription-contracts.js';

export const bridgeProductFileBatchRowSchema = z
	.object({
		changeStatus: bridgeProductFileChangeStatusSchema.nullable(),
		descriptorOutcome: bridgeProductFileDescriptorReadyPayloadSchema.nullable(),
		depth: bridgeProductNonnegativeSequenceSchema,
		displayKey: bridgeProductDisplayPathSchema,
		fileClass: bridgeProductReviewFileClassSchema.nullable(),
		fileId: bridgeProductIdentifierSchema.nullable(),
		kind: z.enum(['file', 'directory', 'deleted']),
		name: bridgeProductDisplayPathSchema,
		lineCount: bridgeProductNonnegativeSequenceSchema.nullable(),
		oldPath: bridgeProductDisplayPathSchema.nullable(),
		parentDisplayKey: bridgeProductDisplayPathSchema.nullable(),
		readDescriptor: bridgeProductFileContentDescriptorSchema.nullable(),
		rowId: bridgeProductIdentifierSchema,
		sizeBytes: bridgeProductNonnegativeSequenceSchema.nullable(),
		sortKey: bridgeProductDisplayPathSchema,
	})
	.strict()
	.superRefine((row, context): void => {
		if (row.kind === 'file' && (row.fileClass === null || row.fileId === null)) {
			context.addIssue({ code: 'custom', message: 'File rows require a file class and id.' });
		}
		if (
			row.kind !== 'file' &&
			(row.fileClass !== null ||
				row.fileId !== null ||
				row.sizeBytes !== null ||
				row.lineCount !== null ||
				row.descriptorOutcome !== null)
		) {
			context.addIssue({
				code: 'custom',
				message: 'Directory and ghost rows have no file extent facts.',
			});
		}
		if (row.descriptorOutcome !== null && row.descriptorOutcome.fileId !== row.fileId) {
			context.addIssue({
				code: 'custom',
				message: 'File descriptor outcome id differs from its row.',
			});
		}
		if (
			row.descriptorOutcome !== null &&
			(row.descriptorOutcome.rowId !== row.rowId || row.descriptorOutcome.path !== row.displayKey)
		) {
			context.addIssue({
				code: 'custom',
				message: 'File descriptor outcome identity differs from its row.',
			});
		}
		const currentDescriptor =
			row.descriptorOutcome?.availability.availabilityKind === 'available'
				? row.descriptorOutcome.availability.contentDescriptor
				: null;
		if (
			canonicalDescriptorJSON(currentDescriptor) !== canonicalDescriptorJSON(row.readDescriptor)
		) {
			context.addIssue({
				code: 'custom',
				message: 'File read descriptor differs from its newest outcome.',
			});
		}
		if (row.kind !== 'file' && row.readDescriptor !== null) {
			context.addIssue({ code: 'custom', message: 'Directory and deleted rows cannot be opened.' });
		}
		if (
			row.kind === 'deleted' &&
			row.changeStatus !== 'deleted' &&
			row.changeStatus !== 'renamed'
		) {
			context.addIssue({
				code: 'custom',
				message: 'A deleted row requires deleted or renamed status.',
			});
		}
	});

export type BridgeProductFileBatchRow = z.infer<typeof bridgeProductFileBatchRowSchema>;

function canonicalDescriptorJSON(value: unknown): string {
	if (Array.isArray(value)) return `[${value.map(canonicalDescriptorJSON).join(',')}]`;
	if (isJSONRecord(value)) {
		return `{${Object.keys(value)
			.sort()
			.map((key) => `${JSON.stringify(key)}:${canonicalDescriptorJSON(value[key])}`)
			.join(',')}}`;
	}
	return JSON.stringify(value) ?? 'undefined';
}

function isJSONRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

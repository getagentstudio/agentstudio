import { z } from 'zod';

export const BRIDGE_PRODUCT_CAPABILITY_HEADER_NAME =
	'X-AgentStudio-Bridge-Product-Capability' as const;
export const BRIDGE_PRODUCT_REQUEST_METHOD = 'POST' as const;
export const BRIDGE_PRODUCT_WIRE_VERSION = 2 as const;
export const BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH = 32;
export const BRIDGE_PRODUCT_MAXIMUM_ACTIVE_SUBSCRIPTION_COUNT = 64;
export const BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES = 256 * 1024;
export const BRIDGE_PRODUCT_MAXIMUM_SUBSCRIPTION_INTEREST_STATE_BYTES = 128 * 1024;
export const BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES = 128 * 1024;
export const BRIDGE_PRODUCT_MAXIMUM_CONTENT_CONTROL_BODY_BYTES = 16 * 1024;
export const BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES = 256 * 1024;
// Frame-body budget minus tag, sequence, offset, and correlation envelope.
export const BRIDGE_PRODUCT_MAXIMUM_CONTENT_DATA_PAYLOAD_BYTES =
	BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES - (1 + 4 + 4 + 33);
export const BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES = 64;
export const BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES = 4 * 1024 * 1024;
export const BRIDGE_PRODUCT_MAXIMUM_CONTENT_STREAM_BYTES = 0xffff_ffff;
export const BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES = 2 * 1024 * 1024;
export const BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE = 1;
export const BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE = Number.MAX_SAFE_INTEGER - 1;
export const BRIDGE_PRODUCT_MAXIMUM_RESUMABLE_STREAM_SEQUENCE = Number.MAX_SAFE_INTEGER - 2;

const bridgeProductTextEncoder = new TextEncoder();

export const bridgeProductIdentifierSchema = z
	.string()
	.min(1)
	.regex(/^[A-Za-z0-9._:-]+$/u)
	.refine(
		(value) => bridgeProductTextEncoder.encode(value).byteLength <= 128,
		'Bridge product identifiers cannot exceed 128 UTF-8 bytes.',
	);

export const bridgeProductOpaqueReferenceSchema = z
	.string()
	.min(1)
	.regex(/^[\u0021-\u007e]+$/u)
	.refine(
		(value) => bridgeProductTextEncoder.encode(value).byteLength <= 256,
		'Bridge product references cannot exceed 256 UTF-8 bytes.',
	);

export const bridgeProductDisplayPathSchema = z
	.string()
	.min(1)
	.superRefine((value, context): void => {
		const byteLength = bridgeProductUnicodeScalarUtf8ByteLength(value);
		if (byteLength === null) {
			context.addIssue({
				code: 'custom',
				message: 'Bridge product display paths must contain only Unicode scalar values.',
			});
			return;
		}
		if (byteLength > 4096) {
			context.addIssue({
				code: 'custom',
				message: 'Bridge product display paths cannot exceed 4096 UTF-8 bytes.',
			});
		}
	});

export const bridgeProductSafeMessageSchema = z
	.string()
	.min(1)
	.superRefine((value, context): void => {
		const byteLength = bridgeProductUnicodeScalarUtf8ByteLength(value);
		if (byteLength === null) {
			context.addIssue({
				code: 'custom',
				message: 'Bridge product safe messages must contain only Unicode scalar values.',
			});
			return;
		}
		if (byteLength > 256) {
			context.addIssue({
				code: 'custom',
				message: 'Bridge product safe messages cannot exceed 256 UTF-8 bytes.',
			});
		}
	});

export const bridgeProductPositiveSequenceSchema = z
	.number()
	.int()
	.positive()
	.max(Number.MAX_SAFE_INTEGER);

export const bridgeProductNonnegativeSequenceSchema = z
	.number()
	.int()
	.nonnegative()
	.max(Number.MAX_SAFE_INTEGER);

export const bridgeProductDemandLaneSchema = z.enum([
	'foreground',
	'active',
	'visible',
	'nearby',
	'speculative',
	'idle',
]);
export const bridgeProductSurfaceSchema = z.enum(['review', 'file']);
export const bridgeProductSha256Schema = z.string().regex(/^[0-9a-f]{64}$/u);

export const bridgeProductResetReasonSchema = z.enum([
	'producer_overflow',
	'sequence_gap',
	'stale_source',
	'snapshot_required',
	// Native ended the subscription when its surface floor passed the admitted epoch.
	'epoch_retired',
]);

export const bridgeProductRequestErrorCodeSchema = z.enum([
	'invalid_request',
	'unauthorized',
	'stale_worker',
	'sequence_conflict',
	'resync_required',
	'stale_source',
	'superseded',
	'result_capacity_exhausted',
	'mutation_watch_capacity_exhausted',
	'payload_too_large',
	'unsupported_call',
	'unsupported_subscription',
	'unknown_subscription',
	'unsupported_content',
	'internal',
]);

export type BridgeProductSurface = z.infer<typeof bridgeProductSurfaceSchema>;
export type BridgeProductRequestErrorCode = z.infer<typeof bridgeProductRequestErrorCodeSchema>;
export type BridgeProductResetReason = z.infer<typeof bridgeProductResetReasonSchema>;

export type BridgeProductRegistryValue<
	TRegistry,
	TRegistryKind extends keyof TRegistry,
	TRegistryMember extends keyof TRegistry[TRegistryKind],
> = TRegistry[TRegistryKind][TRegistryMember];

export type BridgeProductTypeSetsEqual<TLeft, TRight> = [
	Exclude<TLeft, TRight>,
	Exclude<TRight, TLeft>,
] extends [never, never]
	? true
	: false;

export type BridgeProductAssert<TCondition extends true> = TCondition;

export function bridgeProductUnicodeScalarUtf8ByteLength(value: string): number | null {
	let byteLength = 0;
	for (let codeUnitIndex = 0; codeUnitIndex < value.length; codeUnitIndex += 1) {
		const codeUnit = value.charCodeAt(codeUnitIndex);
		if (codeUnit <= 0x7f) {
			byteLength += 1;
			continue;
		}
		if (codeUnit <= 0x7ff) {
			byteLength += 2;
			continue;
		}
		if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
			const trailingCodeUnit = value.charCodeAt(codeUnitIndex + 1);
			if (
				codeUnitIndex + 1 >= value.length ||
				trailingCodeUnit < 0xdc00 ||
				trailingCodeUnit > 0xdfff
			) {
				return null;
			}
			byteLength += 4;
			codeUnitIndex += 1;
			continue;
		}
		if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
			return null;
		}
		byteLength += 3;
	}
	return byteLength;
}

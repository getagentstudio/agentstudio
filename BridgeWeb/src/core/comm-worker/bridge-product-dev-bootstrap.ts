import { z } from 'zod';

import {
	BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	bridgeProductDisplayPathSchema,
	bridgeProductIdentifierSchema,
} from './bridge-product-contract-primitives.js';
import {
	bridgeProductSessionBootstrapSchema,
	type BridgeProductSessionBootstrap,
} from './bridge-product-session-contracts.js';
import { parseBridgeProductStrictJSON } from './bridge-product-strict-json.js';

export const BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE = '/__bridge-product/bootstrap' as const;
export const BRIDGE_PRODUCT_DEV_HEALTH_ROUTE = '/__bridge-product/health' as const;
export const BRIDGE_PRODUCT_DEV_BOOTSTRAP_REQUEST_MEDIA_TYPE = 'application/json' as const;
export const BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE = 'application/octet-stream' as const;

const bridgeProductDevBootstrapEnvelopeVersion = 1;
const bridgeProductDevBootstrapEnvelopePrefixBytes = 5;
const bridgeProductDevMaximumBootstrapMetadataBytes = 4 * 1024;

const bridgeProductDevNavigationContextIntentSchema = z
	.object({
		commandId: bridgeProductIdentifierSchema,
		commandKind: z.literal('activateContext'),
		surface: z.enum(['file', 'review']),
	})
	.strict();

const bridgeProductDevFileNavigationTargetIntentSchema = z
	.object({
		commandId: bridgeProductIdentifierSchema,
		commandKind: z.literal('activateTarget'),
		surface: z.literal('file'),
		target: z
			.object({
				path: bridgeProductDisplayPathSchema,
				targetKind: z.literal('file'),
				version: z.enum(['base', 'head', 'current']),
			})
			.strict(),
	})
	.strict();

const bridgeProductDevReviewNavigationTargetIntentSchema = z
	.object({
		commandId: bridgeProductIdentifierSchema,
		commandKind: z.literal('activateTarget'),
		surface: z.literal('review'),
		target: z
			.object({
				path: bridgeProductDisplayPathSchema.optional(),
				reviewItemId: bridgeProductIdentifierSchema.optional(),
				targetKind: z.literal('review'),
				version: z.enum(['base', 'head', 'current']).optional(),
			})
			.strict()
			.superRefine((target, context): void => {
				if (target.path === undefined && target.reviewItemId === undefined) {
					context.addIssue({
						code: 'custom',
						message: 'Review navigation intent requires a path or Review item identity.',
					});
				}
				if ((target.path === undefined) !== (target.version === undefined)) {
					context.addIssue({
						code: 'custom',
						message: 'Review navigation intent path and version must be supplied together.',
					});
				}
			}),
	})
	.strict();

export const bridgeProductDevNavigationIntentSchema = z.union([
	bridgeProductDevNavigationContextIntentSchema,
	bridgeProductDevFileNavigationTargetIntentSchema,
	bridgeProductDevReviewNavigationTargetIntentSchema,
]);

export type BridgeProductDevNavigationIntent = z.infer<
	typeof bridgeProductDevNavigationIntentSchema
>;

export const bridgeProductDevBootstrapRequestSchema = z.discriminatedUnion('reason', [
	z
		.object({
			navigationIntent: bridgeProductDevNavigationIntentSchema,
			reason: z.literal('initial'),
			tabId: bridgeProductIdentifierSchema,
		})
		.strict(),
	z
		.object({
			navigationIntent: bridgeProductDevNavigationIntentSchema,
			paneSessionId: bridgeProductIdentifierSchema,
			reason: z.literal('workerReplacement'),
			tabId: bridgeProductIdentifierSchema,
		})
		.strict(),
]);

export type BridgeProductDevBootstrapRequest = z.infer<
	typeof bridgeProductDevBootstrapRequestSchema
>;

export interface BridgeProductDevBootstrapDelivery {
	readonly bootstrap: BridgeProductSessionBootstrap;
	readonly productCapability: ArrayBuffer;
}

export function encodeBridgeProductDevBootstrapDelivery(
	delivery: BridgeProductDevBootstrapDelivery,
): Uint8Array {
	const bootstrap = bridgeProductSessionBootstrapSchema.parse(delivery.bootstrap);
	const capabilityBytes = new Uint8Array(delivery.productCapability);
	if (capabilityBytes.byteLength !== BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH) {
		throw new Error('Bridge product dev bootstrap capability has an invalid byte length.');
	}
	const metadataBytes = new TextEncoder().encode(JSON.stringify(bootstrap));
	if (metadataBytes.byteLength > bridgeProductDevMaximumBootstrapMetadataBytes) {
		throw new Error('Bridge product dev bootstrap metadata exceeds its byte limit.');
	}
	const envelope = new Uint8Array(
		bridgeProductDevBootstrapEnvelopePrefixBytes +
			metadataBytes.byteLength +
			BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	);
	const view = new DataView(envelope.buffer);
	envelope[0] = bridgeProductDevBootstrapEnvelopeVersion;
	view.setUint32(1, metadataBytes.byteLength, false);
	envelope.set(metadataBytes, bridgeProductDevBootstrapEnvelopePrefixBytes);
	envelope.set(
		capabilityBytes,
		bridgeProductDevBootstrapEnvelopePrefixBytes + metadataBytes.byteLength,
	);
	return envelope;
}

export function decodeBridgeProductDevBootstrapDelivery(
	encoded: ArrayBuffer | Uint8Array,
): BridgeProductDevBootstrapDelivery {
	const envelope = encoded instanceof Uint8Array ? encoded : new Uint8Array(encoded);
	if (
		envelope.byteLength <
		bridgeProductDevBootstrapEnvelopePrefixBytes + BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH
	) {
		throw new Error('Bridge product dev bootstrap envelope is truncated.');
	}
	if (envelope[0] !== bridgeProductDevBootstrapEnvelopeVersion) {
		throw new Error('Bridge product dev bootstrap envelope version is unsupported.');
	}
	const metadataByteLength = new DataView(
		envelope.buffer,
		envelope.byteOffset,
		envelope.byteLength,
	).getUint32(1, false);
	if (metadataByteLength > bridgeProductDevMaximumBootstrapMetadataBytes) {
		throw new Error('Bridge product dev bootstrap metadata exceeds its byte limit.');
	}
	const expectedByteLength =
		bridgeProductDevBootstrapEnvelopePrefixBytes +
		metadataByteLength +
		BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH;
	if (envelope.byteLength !== expectedByteLength) {
		throw new Error('Bridge product dev bootstrap envelope has an invalid byte length.');
	}
	const metadataStart = bridgeProductDevBootstrapEnvelopePrefixBytes;
	const capabilityStart = metadataStart + metadataByteLength;
	const bootstrap = bridgeProductSessionBootstrapSchema.parse(
		parseBridgeProductStrictJSON(envelope.subarray(metadataStart, capabilityStart)),
	);
	const productCapability = Uint8Array.from(envelope.subarray(capabilityStart)).buffer;
	envelope.fill(0);
	return { bootstrap, productCapability };
}

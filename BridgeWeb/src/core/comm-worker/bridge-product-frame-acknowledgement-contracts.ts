import { z } from 'zod';

import {
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from './bridge-product-contract-primitives.js';

const bridgeProductFrameAcknowledgementCommonIdentityShape = {
	paneSessionId: bridgeProductIdentifierSchema,
	wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
	workerInstanceId: bridgeProductIdentifierSchema,
} as const;

export const bridgeProductFrameAcknowledgementRequestSchema = z
	.object({
		...bridgeProductFrameAcknowledgementCommonIdentityShape,
		contentRequestId: bridgeProductIdentifierSchema,
		receivedThroughContentSequence: bridgeProductNonnegativeSequenceSchema,
		kind: z.literal('content.acknowledge'),
		leaseId: bridgeProductIdentifierSchema,
	})
	.strict();

export const bridgeProductContentAcknowledgementRefusedSchema = z
	.object({
		...bridgeProductFrameAcknowledgementCommonIdentityShape,
		contentRequestId: bridgeProductIdentifierSchema,
		receivedThroughContentSequence: bridgeProductNonnegativeSequenceSchema,
		kind: z.literal('content.acknowledgementRefused'),
		leaseId: bridgeProductIdentifierSchema,
		reason: z.literal('unknownRead'),
	})
	.strict();

export const bridgeProductFrameAcknowledgementRejectedStatusSchema = z.union([
	z.literal(400),
	z.literal(401),
	z.literal(403),
	z.literal(404),
	z.literal(405),
	z.literal(409),
	z.literal(413),
	z.literal(415),
]);

export type BridgeProductFrameAcknowledgementRequest = z.infer<
	typeof bridgeProductFrameAcknowledgementRequestSchema
>;
export type BridgeProductFrameAcknowledgementRejectedStatus = z.infer<
	typeof bridgeProductFrameAcknowledgementRejectedStatusSchema
>;

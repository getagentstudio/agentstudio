import { z } from 'zod';

import { bridgeProductIdentifierSchema } from './bridge-product-contract-primitives.js';
import {
	bridgeWorkerMainToServerBaseSchema,
	bridgeWorkerServerToMainBaseSchema,
} from './bridge-worker-wire-base-contracts.js';

export const bridgeWorkerViewRecoveryKindSchema = z.enum([
	'file.annotations',
	'file.metadata',
	'review.annotations',
	'review.metadata',
]);

export const bridgeWorkerViewRecoveryViewSchema = z
	.object({
		kind: bridgeWorkerViewRecoveryKindSchema,
		subscriptionId: bridgeProductIdentifierSchema,
	})
	.strict();

export const bridgeWorkerViewRecoveryStatusEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		kind: z.literal('viewRecoveryStatus'),
		view: bridgeWorkerViewRecoveryViewSchema,
		status: z.enum(['ready', 'recovering', 'failedRetryable']),
	})
	.strict();

export const bridgeWorkerViewRecoveryRetryCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('viewRecoveryRetry'),
		view: bridgeWorkerViewRecoveryViewSchema,
	})
	.strict();

export type BridgeWorkerViewRecoveryView = z.infer<typeof bridgeWorkerViewRecoveryViewSchema>;
export type BridgeWorkerViewRecoveryStatusEvent = z.infer<
	typeof bridgeWorkerViewRecoveryStatusEventSchema
>;
export type BridgeWorkerViewRecoveryRetryCommand = z.infer<
	typeof bridgeWorkerViewRecoveryRetryCommandSchema
>;

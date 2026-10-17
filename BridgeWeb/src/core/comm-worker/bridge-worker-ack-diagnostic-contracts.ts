import { z } from 'zod';

import { bridgeProductRequestErrorCodeSchema } from './bridge-product-contract-primitives.js';
import {
	bridgeProductOperationResultAckRefusalKindSchema,
	bridgeProductOperationResultAckReplayRejectionKindSchema,
} from './bridge-product-operation-wire-contracts.js';

export const bridgeWorkerAckAttemptOutcomeSchema = z.discriminatedUnion('kind', [
	z
		.object({ kind: z.literal('deadlineExpired'), requestSequence: z.number().int().positive() })
		.strict(),
	z
		.object({ kind: z.literal('transportFailure'), requestSequence: z.number().int().positive() })
		.strict(),
	z
		.object({
			kind: z.literal('httpStatus'),
			code: z.number().int().min(100).max(599),
			requestSequence: z.number().int().positive(),
		})
		.strict(),
	z
		.object({ kind: z.literal('parseFailure'), requestSequence: z.number().int().positive() })
		.strict(),
	z
		.object({ kind: z.literal('identityMismatch'), requestSequence: z.number().int().positive() })
		.strict(),
	z
		.object({
			kind: z.literal('nativeRefusal'),
			nextExpectedRequestSequence: z.number().int().positive().optional(),
			replayRejectionKind: bridgeProductOperationResultAckReplayRejectionKindSchema.optional(),
			refusalKind: z.union([
				bridgeProductOperationResultAckRefusalKindSchema,
				bridgeProductRequestErrorCodeSchema,
			]),
			requestSequence: z.number().int().positive(),
		})
		.strict(),
	z
		.object({ kind: z.literal('responseSizeLimit'), requestSequence: z.number().int().positive() })
		.strict(),
]);

export type BridgeWorkerAckAttemptOutcome = z.infer<typeof bridgeWorkerAckAttemptOutcomeSchema>;

export const bridgeWorkerControlAttemptOutcomeSchema = z.discriminatedUnion('kind', [
	z.object({ kind: z.literal('parse') }).strict(),
	z.object({ kind: z.literal('identity') }).strict(),
	z.object({ kind: z.literal('transport') }).strict(),
	z.object({ kind: z.literal('deadline') }).strict(),
	z.object({ kind: z.literal('httpStatus'), code: z.number().int().min(100).max(599) }).strict(),
	z
		.object({ kind: z.literal('nativeRefusal'), refusalKind: bridgeProductRequestErrorCodeSchema })
		.strict(),
]);

export type BridgeWorkerControlAttemptOutcome = z.infer<
	typeof bridgeWorkerControlAttemptOutcomeSchema
>;

export const bridgeWorkerPriorControlRequestSchema = z
	.object({
		kind: z.enum([
			'workerSession.open',
			'product.call',
			'subscription.open',
			'subscription.setScope',
			'subscription.resnapshot',
			'subscription.cancel',
			'workerSession.resync',
			'operation.lateOutcomeAcknowledgement',
		]),
		outcome: z.enum(['ok', 'ambiguous', 'refused']),
		attemptOutcomes: z.array(bridgeWorkerControlAttemptOutcomeSchema).max(64).readonly(),
		requestSequence: z.number().int().positive(),
	})
	.strict();

export type BridgeWorkerPriorControlRequest = z.infer<typeof bridgeWorkerPriorControlRequestSchema>;

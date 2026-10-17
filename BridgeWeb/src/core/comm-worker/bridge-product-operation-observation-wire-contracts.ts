import { z } from 'zod';

import {
	BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE,
	BRIDGE_PRODUCT_WIRE_VERSION,
	bridgeProductIdentifierSchema,
	bridgeProductPositiveSequenceSchema,
	bridgeProductRequestErrorCodeSchema,
} from './bridge-product-contract-primitives.js';
import { bridgeProductOperationSettlementSchema } from './bridge-product-operation-wire-contracts.js';

export const bridgeProductOperationObservationRequestSchema = z
	.object({
		after: bridgeProductPositiveSequenceSchema,
		kind: z.literal('operation.observe'),
		operationId: bridgeProductIdentifierSchema,
		paneSessionId: bridgeProductIdentifierSchema,
		wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
		workerInstanceId: bridgeProductIdentifierSchema,
	})
	.strict();

const presentResultSchema = z.custom<unknown>((value): boolean => value !== undefined);

export const bridgeProductOperationObservationResponseSchema = z.discriminatedUnion('kind', [
	z
		.object({
			kind: z.literal('operation.stillUnknown'),
			operationId: bridgeProductIdentifierSchema,
			revision: bridgeProductPositiveSequenceSchema,
		})
		.strict(),
	z
		.object({
			failureCode: bridgeProductRequestErrorCodeSchema.nullable(),
			kind: z.literal('operation.lateOutcome'),
			operationId: bridgeProductIdentifierSchema,
			outcome: bridgeProductOperationSettlementSchema,
			result: presentResultSchema,
			revision: bridgeProductPositiveSequenceSchema,
		})
		.strict()
		.superRefine((response, context): void => {
			if (response.outcome === 'outcomeUnknown') {
				context.addIssue({ code: 'custom', message: 'Late evidence must be a known outcome.' });
			}
			if (response.outcome !== 'succeeded' && response.result !== null) {
				context.addIssue({
					code: 'custom',
					message: 'Non-successful late evidence cannot carry a result.',
				});
			}
			if (
				response.outcome !== 'refused' &&
				response.outcome !== 'failed' &&
				response.failureCode !== null
			) {
				context.addIssue({
					code: 'custom',
					message: 'Only refused or failed late evidence may carry a failure code.',
				});
			}
		}),
]);

export const bridgeProductOperationLateOutcomeAcknowledgementSchema = z
	.object({
		kind: z.literal('operation.lateOutcomeAcknowledgement'),
		operationId: bridgeProductIdentifierSchema,
		paneSessionId: bridgeProductIdentifierSchema,
		requestId: bridgeProductIdentifierSchema,
		requestSequence: bridgeProductPositiveSequenceSchema.max(
			BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE,
		),
		revision: bridgeProductPositiveSequenceSchema,
		wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
		workerInstanceId: bridgeProductIdentifierSchema,
	})
	.strict();

export type BridgeProductOperationObservationRequest = z.infer<
	typeof bridgeProductOperationObservationRequestSchema
>;
export type BridgeProductOperationObservationResponse = z.infer<
	typeof bridgeProductOperationObservationResponseSchema
>;
export type BridgeProductOperationLateOutcomeAcknowledgement = z.infer<
	typeof bridgeProductOperationLateOutcomeAcknowledgementSchema
>;

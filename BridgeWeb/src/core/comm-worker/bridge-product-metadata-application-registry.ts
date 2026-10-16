import { z } from 'zod';

import {
	defineBridgeProductMetadataApplicationProtocol,
	BridgeProductMetadataApplicationRegistry,
	registerBridgeProductMetadataApplicationProtocol,
} from './bridge-product-metadata-application-protocol.js';
import {
	bridgeProductControlRequestSchema,
	type BridgeProductControlRequest,
} from './bridge-product-session-contracts.js';
import { bridgeProductFileSourceConfigurationSchema } from './bridge-product-subscription-contracts.js';

const emptyOptionsSchema = z.object({}).strict();
const fileAnnotationOpenSchema = z
	.object({ subscriptionKind: z.literal('file.annotations') })
	.strict();
const reviewAnnotationOpenSchema = z
	.object({ subscriptionKind: z.literal('review.annotations') })
	.strict();
const fileMetadataOptionsSchema = z
	.object({ source: bridgeProductFileSourceConfigurationSchema })
	.strict();
const fileMetadataOpenSchema = z
	.object({
		source: fileMetadataOptionsSchema.shape.source,
		subscriptionKind: z.literal('file.metadata'),
	})
	.strict();
const reviewMetadataOpenSchema = z
	.object({ subscriptionKind: z.literal('review.metadata') })
	.strict();

export const bridgeProductFileAnnotationMetadataApplicationProtocol =
	defineBridgeProductMetadataApplicationProtocol({
		initialOpen: () => ({ subscriptionKind: 'file.annotations' }),
		kind: 'file.annotations',
		openSchema: fileAnnotationOpenSchema,
		optionsSchema: emptyOptionsSchema,
		surface: 'file',
	});

export const bridgeProductReviewAnnotationMetadataApplicationProtocol =
	defineBridgeProductMetadataApplicationProtocol({
		initialOpen: () => ({ subscriptionKind: 'review.annotations' }),
		kind: 'review.annotations',
		openSchema: reviewAnnotationOpenSchema,
		optionsSchema: emptyOptionsSchema,
		surface: 'review',
	});

export const bridgeProductFileMetadataApplicationProtocol =
	defineBridgeProductMetadataApplicationProtocol({
		initialOpen: (options) => ({
			source: fileMetadataOptionsSchema.parse(options).source,
			subscriptionKind: 'file.metadata',
		}),
		kind: 'file.metadata',
		openSchema: fileMetadataOpenSchema,
		optionsSchema: fileMetadataOptionsSchema,
		surface: 'file',
	});

export const bridgeProductReviewMetadataApplicationProtocol =
	defineBridgeProductMetadataApplicationProtocol({
		initialOpen: () => ({ subscriptionKind: 'review.metadata' }),
		kind: 'review.metadata',
		openSchema: reviewMetadataOpenSchema,
		optionsSchema: emptyOptionsSchema,
		surface: 'review',
	});

export type BridgeProductRegisteredMetadataApplicationProtocol =
	| typeof bridgeProductFileAnnotationMetadataApplicationProtocol
	| typeof bridgeProductFileMetadataApplicationProtocol
	| typeof bridgeProductReviewAnnotationMetadataApplicationProtocol
	| typeof bridgeProductReviewMetadataApplicationProtocol;

export const bridgeProductMetadataApplicationRegistry =
	new BridgeProductMetadataApplicationRegistry([
		registerBridgeProductMetadataApplicationProtocol(
			bridgeProductFileAnnotationMetadataApplicationProtocol,
		),
		registerBridgeProductMetadataApplicationProtocol(bridgeProductFileMetadataApplicationProtocol),
		registerBridgeProductMetadataApplicationProtocol(
			bridgeProductReviewAnnotationMetadataApplicationProtocol,
		),
		registerBridgeProductMetadataApplicationProtocol(
			bridgeProductReviewMetadataApplicationProtocol,
		),
	]);

export function parseBridgeProductRegisteredControlRequest(
	value: unknown,
): BridgeProductControlRequest {
	const request = bridgeProductControlRequestSchema.parse(value);
	switch (request.kind) {
		case 'subscription.open':
			bridgeProductMetadataApplicationRegistry.validateOpen(
				request.subscription.subscriptionKind,
				request.subscription,
			);
			break;
		case 'subscription.cancel':
		case 'subscription.setScope':
		case 'subscription.resnapshot':
			bridgeProductMetadataApplicationRegistry.lookup(request.subscriptionKind);
			break;
		case 'workerSession.resync': {
			const epochBySurface = new Map<'file' | 'review', number>();
			for (const activeSubscription of request.activeSubscriptions) {
				const protocol = bridgeProductMetadataApplicationRegistry.lookup(
					activeSubscription.subscriptionKind,
				);
				const existingEpoch = epochBySurface.get(protocol.surface);
				if (
					existingEpoch !== undefined &&
					existingEpoch !== activeSubscription.workerDerivationEpoch
				) {
					throw new Error('Active subscriptions for one surface must share one derivation epoch.');
				}
				epochBySurface.set(protocol.surface, activeSubscription.workerDerivationEpoch);
			}
			break;
		}
		case 'product.call':
		case 'workerSession.open':
			break;
	}
	return request;
}

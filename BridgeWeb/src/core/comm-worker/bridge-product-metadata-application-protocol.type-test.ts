import { z } from 'zod';

import {
	type BridgeProductMetadataApplicationOptions,
	defineBridgeProductMetadataApplicationProtocol,
} from './bridge-product-metadata-application-protocol.js';
import type { BridgeProductMetadataApplicationSubscription } from './bridge-product-transport-contract.js';

const inferredProtocol = defineBridgeProductMetadataApplicationProtocol({
	initialOpen: (options) => ({ source: options.source, subscriptionKind: 'inference.metadata' }),
	kind: 'inference.metadata',
	openSchema: z
		.object({ source: z.string(), subscriptionKind: z.literal('inference.metadata') })
		.strict(),
	optionsSchema: z.object({ source: z.string() }).strict(),
	surface: 'review',
});

const inferredOptions: BridgeProductMetadataApplicationOptions<typeof inferredProtocol> = {
	source: 'source-1',
};
declare const inferredSubscription: BridgeProductMetadataApplicationSubscription<
	typeof inferredProtocol
>;
const terminalEvents: AsyncIterable<never> = inferredSubscription.events;
void inferredOptions;
void terminalEvents;

const optionsWithInterestState: BridgeProductMetadataApplicationOptions<typeof inferredProtocol> = {
	source: 'source-1',
	// @ts-expect-error Subscription options contain only values needed to open the lifecycle.
	interests: [],
};
void optionsWithInterestState;

// @ts-expect-error Application subscriptions no longer expose the legacy interest update API.
void inferredSubscription.update({ source: 'source-2' });

// @ts-expect-error The lifecycle protocol does not carry raw application data schemas.
void inferredProtocol.dataSchema;

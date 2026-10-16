import { z } from 'zod';

import {
	bridgeWorkerRenderDispositionBatchMaximumReceiptCount,
	bridgeWorkerRenderDispositionReceiptSchema,
	bridgeWorkerPaintReleasedSchema,
} from './bridge-worker-render-fulfillment.js';
import { bridgeWorkerMainToServerBaseSchema } from './bridge-worker-wire-base-contracts.js';

export const bridgeWorkerRenderDispositionCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('renderDisposition'),
		receipts: z
			.array(z.union([bridgeWorkerRenderDispositionReceiptSchema, bridgeWorkerPaintReleasedSchema]))
			.min(1)
			.max(bridgeWorkerRenderDispositionBatchMaximumReceiptCount)
			.readonly(),
	})
	.strict();

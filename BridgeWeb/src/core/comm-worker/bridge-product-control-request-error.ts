import type { BridgeProductRequestErrorCode } from './bridge-product-contract-primitives.js';
import { bridgeProductOperationResultResponseSchema } from './bridge-product-operation-wire-contracts.js';
import type { BridgeProductLateOutcomeObservation } from './bridge-product-session-authority.js';

export class BridgeProductControlRequestError extends Error {
	readonly code: BridgeProductRequestErrorCode;
	readonly outcome?: ReturnType<typeof bridgeProductOperationResultResponseSchema.parse>['outcome'];
	readonly retryAfterMilliseconds: number | null;
	readonly retryable: boolean;
	readonly observeLateOutcome?: () => Promise<BridgeProductLateOutcomeObservation>;

	constructor(props: {
		readonly code: BridgeProductRequestErrorCode;
		readonly message: string;
		readonly outcome?: ReturnType<
			typeof bridgeProductOperationResultResponseSchema.parse
		>['outcome'];
		readonly retryAfterMilliseconds: number | null;
		readonly retryable: boolean;
		readonly observeLateOutcome?: () => Promise<BridgeProductLateOutcomeObservation>;
	}) {
		super(props.message);
		this.name = 'BridgeProductControlRequestError';
		this.code = props.code;
		if (props.outcome !== undefined) this.outcome = props.outcome;
		this.retryAfterMilliseconds = props.retryAfterMilliseconds;
		this.retryable = props.retryable;
		if (props.observeLateOutcome !== undefined) this.observeLateOutcome = props.observeLateOutcome;
	}
}

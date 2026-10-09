import type {
	BridgeProductCallKind,
	BridgeProductCallRequest,
	BridgeProductCallResult,
} from './bridge-product-call-contracts.js';
import type {
	BridgeProductContentDescriptor,
	BridgeProductContentKind,
	BridgeProductContentFrameFor,
	BridgeProductContentTerminal,
} from './bridge-product-content-contracts.js';
import type {
	BridgeProductMetadataApplicationKind,
	BridgeProductMetadataApplicationProtocol,
	BridgeProductMetadataApplicationProtocolIdentity,
} from './bridge-product-metadata-application-protocol.js';
import type { BridgeProductSubscriptionKind } from './bridge-product-subscription-contracts.js';

export type BridgeProductCallOptions = {
	readonly signal?: AbortSignal;
};

type BridgeProductCallArguments = {
	[TCallKind in BridgeProductCallKind]: readonly [
		method: TCallKind,
		request: BridgeProductCallRequest<TCallKind>,
		options?: BridgeProductCallOptions,
	];
}[BridgeProductCallKind];

export type BridgeProductSubscription<TSubscriptionKind extends BridgeProductSubscriptionKind> = {
	[TRegistrySubscriptionKind in TSubscriptionKind]: {
		readonly events: AsyncIterable<never>;
		readonly subscriptionId: string;
		readonly subscriptionKind: TRegistrySubscriptionKind;
		cancel(): Promise<void>;
	};
}[TSubscriptionKind];

export type BridgeProductMetadataApplicationSubscription<
	TProtocol extends BridgeProductMetadataApplicationProtocolIdentity,
> = {
	readonly events: AsyncIterable<never>;
	readonly subscriptionId: string;
	readonly subscriptionKind: BridgeProductMetadataApplicationKind<TProtocol>;
	cancel(): Promise<void>;
};

export type BridgeProductContentStream<TContentKind extends BridgeProductContentKind> = {
	readonly contentKind: TContentKind;
	readonly contentRequestId: string;
	readonly frames: AsyncIterable<BridgeProductContentFrameFor<TContentKind>>;
	readonly responseStartControl?: BridgeProductContentResponseStartControl;
	readonly terminal: Promise<BridgeProductContentTerminal<TContentKind>>;
};

export interface BridgeProductContentResponseStartControl {
	pauseBeforeStart(): void;
	resumeBeforeStart(): void;
}

export type BridgeProductTransport = {
	call<TCallArguments extends BridgeProductCallArguments>(
		...arguments_: TCallArguments
	): Promise<BridgeProductCallResult<TCallArguments[0]>>;
	openContent<TContentKind extends BridgeProductContentKind>(
		descriptor: BridgeProductContentDescriptor<TContentKind>,
		abortSignal: AbortSignal,
		operationCorrelationId?: string | null,
	): BridgeProductContentStream<TContentKind>;
	subscribe<TKind extends string, TOptions, TOpen extends { readonly subscriptionKind: TKind }>(
		protocol: BridgeProductMetadataApplicationProtocol<TKind, TOptions, TOpen>,
		options: TOptions,
	): {
		readonly events: AsyncIterable<never>;
		readonly subscriptionId: string;
		readonly subscriptionKind: TKind;
		cancel(): Promise<void>;
	};
};

export type { BridgeProductCallResult } from './bridge-product-call-contracts.js';
export type { BridgeProductContentTerminal } from './bridge-product-content-contracts.js';

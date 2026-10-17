import {
	bridgeProductControlRequestSchema,
	type BridgeProductControlRequest,
	type BridgeProductControlResponse,
	type BridgeProductSessionBootstrap,
} from './bridge-product-session-contracts.js';
import type {
	BridgeProductViewResnapshotRequest,
	BridgeProductViewScopeRequest,
} from './bridge-product-view-control-wire-contracts.js';

type ViewControlAccepted<TKind extends BridgeProductControlResponse['kind']> = Extract<
	BridgeProductControlResponse,
	{ readonly kind: TKind }
>;

interface ControlAdmissionIdentity {
	readonly paneSessionId: string;
	readonly requestId: string;
	readonly requestSequence: number;
	readonly wireVersion: BridgeProductSessionBootstrap['wireVersion'];
	readonly workerInstanceId: string;
}

interface ViewControlAdmission<TResult> {
	readonly acceptResponse: (response: BridgeProductControlResponse) => TResult;
	readonly buildRequest: (identity: ControlAdmissionIdentity) => BridgeProductControlRequest;
	readonly signal?: AbortSignal;
}

export interface ViewScopeAdmissionProps {
	readonly domain: string;
	readonly handle: string;
	readonly incarnation: string;
	readonly scope: BridgeProductViewScopeRequest['scope'];
	readonly scopeRevision: number;
	readonly signal?: AbortSignal;
	readonly subscriptionId: string;
	readonly subscriptionKind: BridgeProductViewScopeRequest['subscriptionKind'];
}

export type ViewResnapshotAdmissionProps = Omit<ViewScopeAdmissionProps, 'scope'> & {
	readonly subscriptionKind: BridgeProductViewResnapshotRequest['subscriptionKind'];
};

export function viewScopeAdmission(
	props: ViewScopeAdmissionProps,
): ViewControlAdmission<ViewControlAccepted<'subscription.scopeAccepted'>> {
	return {
		acceptResponse: (response) => {
			if (!matchesViewAcceptance(response, props, 'subscription.scopeAccepted')) {
				throw new Error('Bridge product view scope result does not match its request.');
			}
			return response;
		},
		buildRequest: (identity): BridgeProductControlRequest =>
			bridgeProductControlRequestSchema.parse({
				...identity,
				domain: props.domain,
				handle: props.handle,
				incarnation: props.incarnation,
				kind: 'subscription.setScope',
				scope: props.scope,
				scopeRevision: props.scopeRevision,
				subscriptionId: props.subscriptionId,
				subscriptionKind: props.subscriptionKind,
			}),
		...(props.signal === undefined ? {} : { signal: props.signal }),
	};
}

export function viewResnapshotAdmission(
	props: ViewResnapshotAdmissionProps,
): ViewControlAdmission<ViewControlAccepted<'subscription.resnapshotAccepted'>> {
	return {
		acceptResponse: (response) => {
			if (!matchesViewAcceptance(response, props, 'subscription.resnapshotAccepted')) {
				throw new Error('Bridge product view resnapshot result does not match its request.');
			}
			return response;
		},
		buildRequest: (identity): BridgeProductControlRequest =>
			bridgeProductControlRequestSchema.parse({
				...identity,
				domain: props.domain,
				handle: props.handle,
				incarnation: props.incarnation,
				kind: 'subscription.resnapshot',
				scopeRevision: props.scopeRevision,
				subscriptionId: props.subscriptionId,
				subscriptionKind: props.subscriptionKind,
			}),
		...(props.signal === undefined ? {} : { signal: props.signal }),
	};
}

function matchesViewAcceptance<
	TKind extends 'subscription.scopeAccepted' | 'subscription.resnapshotAccepted',
>(
	response: BridgeProductControlResponse,
	props: ViewResnapshotAdmissionProps,
	kind: TKind,
): response is ViewControlAccepted<TKind> {
	return (
		response.kind === kind &&
		response.domain === props.domain &&
		response.handle === props.handle &&
		response.incarnation === props.incarnation &&
		response.scopeRevision === props.scopeRevision &&
		response.subscriptionId === props.subscriptionId &&
		response.subscriptionKind === props.subscriptionKind
	);
}

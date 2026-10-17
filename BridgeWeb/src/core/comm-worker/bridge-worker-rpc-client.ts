import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerMainToServerMessageSchema,
	type BridgeWorkerMainToServerMessage,
	type BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import type {
	BridgeWorkerRpcLifecycleSnapshot,
	BridgeWorkerRpcLifecycleStore,
} from './bridge-worker-rpc-lifecycle-store.js';

export type BridgePaneSurface = 'fileView' | 'review';
export type BridgeWorkerRpcClientSurface = BridgePaneSurface | 'pane';

type BridgeWorkerRpcWireOwnedField =
	| 'direction'
	| 'issuedAtMilliseconds'
	| 'kind'
	| 'requestId'
	| 'transferDescriptors'
	| 'wireVersion';

type BridgeWorkerRpcCommandInputByCommand = {
	[TMessage in BridgeWorkerMainToServerMessage as TMessage['command']]: Omit<
		TMessage,
		BridgeWorkerRpcWireOwnedField
	>;
};

export type BridgeWorkerRpcCommandInput =
	BridgeWorkerRpcCommandInputByCommand[keyof BridgeWorkerRpcCommandInputByCommand];

export interface BridgeWorkerRpcClient {
	readonly dispose: () => void;
	readonly getLifecycleSnapshot: () => BridgeWorkerRpcLifecycleSnapshot;
	readonly receive: (message: BridgeWorkerServerToMainMessage) => boolean;
	readonly send: (command: BridgeWorkerRpcCommandInput) => string;
	readonly subscribe: (listener: (message: BridgeWorkerServerToMainMessage) => void) => () => void;
}

export interface CreateBridgeWorkerRpcClientProps {
	readonly dispatch: (message: BridgeWorkerMainToServerMessage) => void;
	readonly lifecycleStore: BridgeWorkerRpcLifecycleStore;
	readonly requestIdFactory?: () => string;
	readonly requestTimeoutMilliseconds?: number;
	readonly surface: BridgeWorkerRpcClientSurface;
}

const defaultBridgeWorkerRpcRequestTimeoutMilliseconds = 5000;

export function createBridgeWorkerRpcClient(
	props: CreateBridgeWorkerRpcClientProps,
): BridgeWorkerRpcClient {
	const listeners = new Set<(message: BridgeWorkerServerToMainMessage) => void>();
	const requestTimeouts = new Map<string, ReturnType<typeof globalThis.setTimeout>>();
	const requestIdFactory = props.requestIdFactory ?? createBridgeWorkerRpcRequestIdFactory();
	const requestTimeoutMilliseconds =
		props.requestTimeoutMilliseconds ?? defaultBridgeWorkerRpcRequestTimeoutMilliseconds;
	let isDisposed = false;

	const clearRequestTimeout = (requestId: string): void => {
		const timeout = requestTimeouts.get(requestId);
		if (timeout === undefined) return;
		globalThis.clearTimeout(timeout);
		requestTimeouts.delete(requestId);
	};

	const getLifecycleSnapshot = (): BridgeWorkerRpcLifecycleSnapshot => {
		const requestsById = Object.fromEntries(
			Object.entries(props.lifecycleStore.getSnapshot().requestsById).filter(
				([, request]): boolean => request.surface === props.surface,
			),
		);
		return { requestsById };
	};

	return {
		dispose: (): void => {
			if (isDisposed) return;
			isDisposed = true;
			for (const requestId of requestTimeouts.keys()) clearRequestTimeout(requestId);
			listeners.clear();
		},
		getLifecycleSnapshot,
		receive: (message): boolean => {
			if (isDisposed || !bridgeWorkerMessageMatchesSurface(message, props.surface)) return false;
			settleBridgeWorkerRpcLifecycleFromMessage({
				clearRequestTimeout,
				lifecycleStore: props.lifecycleStore,
				message,
				surface: props.surface,
			});
			for (const listener of listeners) listener(message);
			return true;
		},
		send: (command): string => {
			if (isDisposed) throw new Error('Bridge worker RPC client is disposed.');
			assertBridgeWorkerCommandMatchesSurface(command, props.surface);
			if (!bridgeWorkerCommandMatchesSurface(command, props.surface)) {
				throw new Error(
					`Bridge worker ${command.command} command does not belong to ${props.surface} surface.`,
				);
			}
			const requestId = requestIdFactory();
			const message = bridgeWorkerMainToServerMessageSchema.parse({
				...command,
				direction: 'mainToServerWorker',
				kind: 'command',
				requestId,
				transferDescriptors: [],
				wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			});
			props.lifecycleStore.startRequest({
				command: message.command,
				requestId,
				surface: props.surface,
			});
			const timeout = globalThis.setTimeout((): void => {
				requestTimeouts.delete(requestId);
				const request = props.lifecycleStore.getSnapshot().requestsById[requestId];
				if (request?.state === 'pending') props.lifecycleStore.timeoutRequest({ requestId });
			}, requestTimeoutMilliseconds);
			requestTimeouts.set(requestId, timeout);
			try {
				props.dispatch(message);
			} catch (error: unknown) {
				clearRequestTimeout(requestId);
				props.lifecycleStore.rollbackRequest({ requestId });
				throw error;
			}
			return requestId;
		},
		subscribe: (listener): (() => void) => {
			if (isDisposed) throw new Error('Bridge worker RPC client is disposed.');
			listeners.add(listener);
			return (): void => {
				listeners.delete(listener);
			};
		},
	};
}

function bridgeWorkerCommandMatchesSurface(
	command: BridgeWorkerRpcCommandInput,
	surface: BridgeWorkerRpcClientSurface,
): boolean {
	switch (command.command) {
		case 'annotationCommand':
		case 'annotationOutputInspect':
		case 'annotationProjectionRetry':
			return command.surface === surface;
		case 'viewRecoveryRetry':
			return bridgeWorkerViewRecoveryKindMatchesSurface(command.view.kind, surface);
		case 'fileDisplayResync':
		case 'fileQueryUpdate':
		case 'fileRefreshRetry':
			return surface === 'fileView';
		case 'markFileViewed':
		case 'metadataInterestUpdate':
		case 'reviewIntakeReady':
		case 'reviewComparisonUpdate':
		case 'reviewComparisonTargetsQuery':
		case 'reviewComparisonTargetsQueryCancel':
		case 'reviewInvalidate':
		case 'reviewProjectionUpdate':
		case 'reviewPublicationInstallAdmit':
		case 'reviewPublicationInstalled':
			return surface === 'review';
		case 'renderDisposition':
			return command.receipts[0]?.surface === 'file'
				? surface === 'fileView'
				: surface === 'review';
		case 'hover':
		case 'select':
		case 'viewport':
			return surface !== 'pane';
		case 'activeViewerModeUpdate':
		case 'mode':
			return surface === 'pane';
	}
	return unreachableBridgeWorkerValue(command);
}

function assertBridgeWorkerCommandMatchesSurface(
	command: BridgeWorkerRpcCommandInput,
	surface: BridgeWorkerRpcClientSurface,
): void {
	if (command.command === 'renderDisposition') {
		const receiptSurface = command.receipts[0]?.surface === 'file' ? 'fileView' : 'review';
		if (
			command.receipts.some(
				(receipt): boolean =>
					(receipt.surface === 'file' ? 'fileView' : 'review') !== receiptSurface,
			)
		) {
			throw new Error('Bridge worker renderDisposition command cannot mix surfaces.');
		}
		if (receiptSurface !== surface) {
			throw new Error(
				`Bridge worker renderDisposition command targets ${receiptSurface}, not ${surface}.`,
			);
		}
		return;
	}
	if (
		command.command !== 'hover' &&
		command.command !== 'select' &&
		command.command !== 'viewport'
	) {
		return;
	}
	const interactionCommand = command as BridgeWorkerRpcCommandInput & {
		readonly surface?: unknown;
	};
	if (interactionCommand.surface !== 'fileView' && interactionCommand.surface !== 'review') {
		throw new Error(
			`Bridge worker ${command.command} command requires an explicit surface target.`,
		);
	}
	if (interactionCommand.surface !== surface) {
		throw new Error(
			`Bridge worker ${command.command} command targets ${interactionCommand.surface} instead of ${surface} surface.`,
		);
	}
}

function bridgeWorkerMessageMatchesSurface(
	message: BridgeWorkerServerToMainMessage,
	surface: BridgeWorkerRpcClientSurface,
): boolean {
	switch (message.kind) {
		case 'annotationCommandAccepted':
		case 'annotationCatalogStaging':
		case 'annotationOutputInspection':
		case 'annotationProjectionConvergence':
			return message.surface === surface;
		case 'viewRecoveryStatus':
			return bridgeWorkerViewRecoveryKindMatchesSurface(message.view.kind, surface);
		case 'health':
			return true;
		case 'nativeSurfaceSelectionRequest':
			return surface === 'pane';
		case 'fileDisplayPatch':
		case 'filePierreRenderJob':
		case 'fileRenderPatch':
			return surface === 'fileView';
		case 'reviewDisplayPatch':
		case 'reviewCandidateReady':
		case 'reviewCandidateFailed':
		case 'reviewCandidateStarted':
		case 'reviewPierreRenderJob':
		case 'reviewPublicationInstallAdmission':
		case 'reviewRenderPatch':
		case 'reviewComparisonTargetsQuery':
			return surface === 'review';
		case 'subscription':
			return message.subscription === 'fileViewContent'
				? surface === 'fileView'
				: message.subscription === 'reviewContent' && surface === 'review';
		case 'slicePatch':
			return false;
	}
	return unreachableBridgeWorkerValue(message);
}

function bridgeWorkerViewRecoveryKindMatchesSurface(
	kind: 'file.annotations' | 'file.metadata' | 'review.annotations' | 'review.metadata',
	surface: BridgeWorkerRpcClientSurface,
): boolean {
	return kind === 'file.annotations' || kind === 'file.metadata'
		? surface === 'fileView'
		: surface === 'review';
}

function settleBridgeWorkerRpcLifecycleFromMessage(props: {
	readonly clearRequestTimeout: (requestId: string) => void;
	readonly lifecycleStore: BridgeWorkerRpcLifecycleStore;
	readonly message: BridgeWorkerServerToMainMessage;
	readonly surface: BridgeWorkerRpcClientSurface;
}): void {
	if (
		props.message.kind !== 'annotationCommandAccepted' &&
		props.message.kind !== 'annotationOutputInspection' &&
		props.message.kind !== 'health' &&
		props.message.kind !== 'reviewPublicationInstallAdmission' &&
		props.message.kind !== 'subscription' &&
		props.message.kind !== 'reviewComparisonTargetsQuery'
	)
		return;
	const requestId = props.message.requestId;
	if (requestId === undefined) return;
	const request = props.lifecycleStore.getSnapshot().requestsById[requestId];
	if (request?.state !== 'pending' || request.surface !== props.surface) return;
	props.clearRequestTimeout(requestId);
	if (
		props.message.kind === 'annotationCommandAccepted' ||
		(props.message.kind === 'health' && props.message.status === 'degraded') ||
		(props.message.kind === 'subscription' && props.message.status === 'rejected') ||
		(props.message.kind === 'reviewComparisonTargetsQuery' && props.message.status === 'failed')
	) {
		if (props.message.kind === 'annotationCommandAccepted') {
			props.lifecycleStore.ackRequest({ acknowledgedAtSequence: 0, requestId });
			return;
		}
		props.lifecycleStore.failRequest({
			reason:
				props.message.kind === 'health'
					? (props.message.errorKind ?? props.message.message ?? 'worker_degraded')
					: props.message.kind === 'subscription'
						? 'subscription_rejected'
						: (props.message.message ?? 'comparison_targets_query_failed'),
			requestId,
		});
		return;
	}
	props.lifecycleStore.ackRequest({ acknowledgedAtSequence: 0, requestId });
}

function createBridgeWorkerRpcRequestIdFactory(): () => string {
	let nextRequestSequence = 0;
	return (): string => {
		nextRequestSequence += 1;
		return `bridge-worker-rpc-${nextRequestSequence}`;
	};
}

function unreachableBridgeWorkerValue(value: never): never {
	throw new Error(`Unexpected Bridge worker value: ${String(value)}`);
}

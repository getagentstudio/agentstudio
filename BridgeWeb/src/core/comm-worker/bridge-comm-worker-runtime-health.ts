import {
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerHealthEvent,
	type BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

export function bridgeWorkerRuntimeMessagesContainReadyRequest(props: {
	readonly messages: readonly BridgeWorkerServerToMainMessage[];
	readonly requestId: string;
}): boolean {
	return props.messages.some((message): boolean =>
		bridgeWorkerRuntimeMessageIsReadyRequest({
			message,
			requestId: props.requestId,
		}),
	);
}

export function bridgeWorkerRuntimeMessageIsReadyRequest(props: {
	readonly message: BridgeWorkerServerToMainMessage;
	readonly requestId: string;
}): boolean {
	return (
		props.message.kind === 'health' &&
		props.message.requestId === props.requestId &&
		props.message.status === 'ready'
	);
}

export function buildBridgeWorkerRuntimeDegradedHealthEvent(): BridgeWorkerServerToMainMessage {
	return {
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'health',
		status: 'degraded',
		message: 'Bridge comm worker received invalid message.',
	};
}

export function buildBridgeWorkerRuntimeCommandFailedHealthEvent(props: {
	readonly deliveryStatus?: 'unknownAfterDispatch';
	readonly errorKind?:
		| 'transport'
		| 'requestRefused'
		| 'invalidResult'
		| 'unexpected'
		| 'workerUnavailable';
	readonly message: string;
	readonly requestId: string;
}): BridgeWorkerServerToMainMessage {
	return {
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'health',
		requestId: props.requestId,
		status: 'degraded',
		message: props.message,
		...(props.deliveryStatus === undefined ? {} : { deliveryStatus: props.deliveryStatus }),
		...(props.errorKind === undefined ? {} : { errorKind: props.errorKind }),
	};
}

export function buildBridgeWorkerFileMetadataFailureHealthEvent(
	diagnostic?: BridgeWorkerHealthEvent['diagnostic'],
): BridgeWorkerServerToMainMessage {
	return {
		direction: 'serverWorkerToMain',
		kind: 'health',
		message: 'Bridge File metadata subscription failed.',
		status: 'degraded',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		...(diagnostic === undefined ? {} : { diagnostic }),
	};
}

export function buildBridgeWorkerFileMetadataInterestFailureHealthEvent(): BridgeWorkerServerToMainMessage {
	return {
		direction: 'serverWorkerToMain',
		kind: 'health',
		message: 'Bridge File metadata interest update failed.',
		status: 'degraded',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
}

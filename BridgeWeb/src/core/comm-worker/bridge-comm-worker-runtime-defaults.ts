import type { RegisterBridgeCommWorkerRuntimePortProtocolProps } from './bridge-comm-worker-runtime-protocol-contracts.js';
import type { BridgeProductControlCommand } from './bridge-product-control-contracts.js';
import {
	createWorkerContentPreparationPump,
	type WorkerContentPreparationPump,
} from './bridge-worker-content-preparation-pump.js';
import type { BridgeWorkerFileViewContentOpen } from './bridge-worker-file-view-content-fetch.js';
import type { BridgeWorkerReviewContentOpen } from './bridge-worker-review-content-fetch.js';

export function scheduleDefaultBridgeRenderFulfillmentWake(
	delayMilliseconds: number,
	wake: () => void,
): () => void {
	const timeoutId = globalThis.setTimeout(wake, delayMilliseconds);
	return (): void => globalThis.clearTimeout(timeoutId);
}

export async function rejectUninstalledBridgeProductControl(
	command: BridgeProductControlCommand,
): Promise<never> {
	throw new Error(`Bridge product-control sender is not installed for ${command.method}.`);
}

export async function rejectUninstalledReviewMetadataInterestUpdate(): Promise<never> {
	throw new Error('Bridge Review metadata product subscription is not installed.');
}

export function rejectUninstalledBridgeFileContentOpen(): never {
	throw new Error('Bridge File content transport is not installed.');
}

export function bridgeCommWorkerProductControlFailureMessage(props: {
	readonly command: BridgeProductControlCommand;
}): string {
	return `Bridge comm worker failed to forward ${props.command.method}.`;
}

export function publishBridgeCommWorkerPostCommitFailureBestEffort(
	publishFailure: () => void,
): void {
	try {
		publishFailure();
	} catch {
		// A closed main port cannot invalidate already committed worker authority.
	}
}

export function resolveBridgeCommWorkerFileContentOpen(
	props: Pick<
		RegisterBridgeCommWorkerRuntimePortProtocolProps,
		'openFileViewContent' | 'productTransport'
	>,
): BridgeWorkerFileViewContentOpen {
	const transport = props.productTransport;
	return (
		props.openFileViewContent ??
		(transport === undefined
			? rejectUninstalledBridgeFileContentOpen
			: (descriptor, signal, correlationId) =>
					transport.openContent(descriptor, signal, correlationId))
	);
}

export function resolveBridgeCommWorkerReviewContentOpen(
	props: Pick<
		RegisterBridgeCommWorkerRuntimePortProtocolProps,
		'openReviewContent' | 'productTransport'
	>,
): BridgeWorkerReviewContentOpen | undefined {
	const transport = props.productTransport;
	return (
		props.openReviewContent ??
		(transport === undefined
			? undefined
			: (descriptor, signal) => transport.openContent(descriptor, signal))
	);
}

export function resolveBridgeCommWorkerPreparationPump(
	props: Pick<
		RegisterBridgeCommWorkerRuntimePortProtocolProps,
		'pump' | 'maxPreparationSliceMs' | 'now' | 'telemetryClient'
	>,
): WorkerContentPreparationPump {
	return (
		props.pump ??
		createWorkerContentPreparationPump({
			maxSliceMs: props.maxPreparationSliceMs ?? 8,
			...(props.now === undefined ? {} : { now: props.now }),
			...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
		})
	);
}

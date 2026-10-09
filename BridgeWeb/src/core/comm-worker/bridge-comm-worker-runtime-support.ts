import { readBridgeCommWorkerAbsoluteNowMilliseconds } from './bridge-comm-worker-clock.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import type { BridgeWorkerHealthEvent } from './bridge-worker-contracts.js';

export function readBridgeCommWorkerRuntimeNowMilliseconds(
	now: (() => number) | undefined,
): number {
	if (now !== undefined) {
		return now();
	}
	return readBridgeCommWorkerAbsoluteNowMilliseconds();
}

export function createBridgeWorkerRuntimeSequenceCounter(): () => number {
	let nextSequence = 1;
	return (): number => {
		const sequence = nextSequence;
		nextSequence += 1;
		return sequence;
	};
}

export function scheduleDefaultBridgeCommWorkerPreparationDrain(
	drain: () => Promise<unknown>,
): void {
	queueMicrotask(() => {
		void drain();
	});
}

export function sendBridgeCommWorkerActionWithTimeout<TResult>(props: {
	readonly send: () => Promise<TResult>;
	readonly timeoutMilliseconds: number;
}): Promise<TResult> {
	return new Promise<TResult>((resolve, reject): void => {
		let didSettle = false;
		const timeoutId = globalThis.setTimeout((): void => {
			if (didSettle) return;
			didSettle = true;
			reject(new Error('Bridge comm worker command action timed out.'));
		}, props.timeoutMilliseconds);
		void props.send().then(
			(actionResult: TResult): void => {
				if (didSettle) return;
				didSettle = true;
				globalThis.clearTimeout(timeoutId);
				resolve(actionResult);
			},
			(error: unknown): void => {
				if (didSettle) return;
				didSettle = true;
				globalThis.clearTimeout(timeoutId);
				reject(error);
			},
		);
	});
}

/**
 * A deadline that reports without abandoning the action. Timing out cannot cancel a
 * native effect already dispatched, so the returned promise still settles with the
 * action's real outcome; `onDeadlineExceeded` fires once if the deadline passes first.
 */
export function sendBridgeCommWorkerActionWithOutcomeDeadline<TResult>(props: {
	readonly onDeadlineExceeded: () => void;
	readonly send: () => Promise<TResult>;
	readonly timeoutMilliseconds: number;
}): Promise<TResult> {
	let didSettle = false;
	const timeoutId = globalThis.setTimeout((): void => {
		if (!didSettle) props.onDeadlineExceeded();
	}, props.timeoutMilliseconds);
	return Promise.resolve()
		.then(props.send)
		.finally((): void => {
			didSettle = true;
			globalThis.clearTimeout(timeoutId);
		});
}

export function bridgeProductMetadataStreamHealthDiagnostic(
	transport: BridgeProductTransportSession,
): BridgeWorkerHealthEvent['diagnostic'] | undefined {
	const readDiagnostics = (
		transport as Partial<Pick<BridgeProductTransportSession, 'metadataStreamDiagnostics'>>
	).metadataStreamDiagnostics;
	if (typeof readDiagnostics !== 'function') return undefined;
	return {
		kind: 'productMetadataStream',
		...readDiagnostics.call(transport),
	};
}

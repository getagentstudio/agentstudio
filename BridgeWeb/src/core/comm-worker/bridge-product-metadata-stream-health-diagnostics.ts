import type { BridgeProductMetadataRouteFailureCode } from './bridge-product-metadata-route-failure.js';
import type {
	BridgeProductMetadataStreamDecoderDiagnostics,
	BridgeProductMetadataStreamIdentityField,
} from './bridge-product-metadata-stream-decoder.js';
import type { BridgeProductMetadataFrame } from './bridge-product-session-contracts.js';

export interface BridgeProductMetadataStreamHealthDiagnostics {
	readonly lastSubscriptionTermination: {
		readonly subscriptionId: string;
		readonly outcome: 'terminal' | 'failed';
		readonly reason: BridgeProductMetadataRouteFailureCode | null;
	} | null;
	readonly routeFailureSubscriptionId: string | null;
	readonly activeSubscriptionCount: number;
	readonly committedFrameCount: number;
	readonly decoderState: BridgeProductMetadataStreamDecoderDiagnostics['state'];
	readonly expectedNextStreamSequence: number;
	readonly failureStage: BridgeProductMetadataStreamFailureStage | null;
	readonly failureCode: BridgeProductMetadataStreamDecoderDiagnostics['failureCode'];
	readonly identityMismatchField: BridgeProductMetadataStreamIdentityField | null;
	readonly lastChunkByteCount: number;
	readonly lastCommittedFrameKind: BridgeProductMetadataFrame['kind'] | null;
	readonly lastRoutedFrameKind: BridgeProductMetadataFrame['kind'] | null;
	readonly lifecycleState: BridgeProductMetadataStreamLifecycleState;
	readonly peakRetainedByteCount: number;
	readonly pushCount: number;
	readonly readFulfilledCount: number;
	readonly readPending: boolean;
	readonly readRequestCount: number;
	readonly receivedByteCount: number;
	readonly retainedByteCount: number;
	readonly routeFailureCode: BridgeProductMetadataRouteFailureCode | null;
	readonly routedFrameCount: number;
	readonly streamOpenCount: number;
}

export type BridgeProductMetadataStreamFailureStage =
	| 'authority'
	| 'decode'
	| 'fetch'
	| 'finish'
	| 'read'
	| 'route'
	| 'unexpectedEof';

export type BridgeProductMetadataStreamLifecycleState = 'failed' | 'idle' | 'opening' | 'reading';

export interface BridgeProductMetadataStreamLifecycleObservation {
	readonly transition:
		| 'fetchStarted'
		| 'responseReceived'
		| 'firstByteRead'
		| 'acceptedRouted'
		| 'failed'
		| 'restartScheduled';
	readonly responseStatus: number | null;
	readonly diagnostics: BridgeProductMetadataStreamHealthDiagnostics;
}

export function createBridgeProductMetadataStreamHealthDiagnostics(): BridgeProductMetadataStreamHealthDiagnostics {
	return {
		lastSubscriptionTermination: null,
		routeFailureSubscriptionId: null,
		activeSubscriptionCount: 0,
		committedFrameCount: 0,
		decoderState: 'open',
		expectedNextStreamSequence: 0,
		failureStage: null,
		failureCode: null,
		identityMismatchField: null,
		lastChunkByteCount: 0,
		lastCommittedFrameKind: null,
		lastRoutedFrameKind: null,
		lifecycleState: 'idle',
		peakRetainedByteCount: 0,
		pushCount: 0,
		readFulfilledCount: 0,
		readPending: false,
		readRequestCount: 0,
		receivedByteCount: 0,
		retainedByteCount: 0,
		routeFailureCode: null,
		routedFrameCount: 0,
		streamOpenCount: 0,
	};
}

export type BridgeProductMetadataStreamHealthSink = (
	observation: BridgeProductMetadataStreamLifecycleObservation,
) => void;

export function isolatedBridgeProductMetadataStreamHealthSink(
	sink: BridgeProductMetadataStreamHealthSink,
): BridgeProductMetadataStreamHealthSink {
	return (observation): void => {
		try {
			sink(observation);
		} catch {
			// Diagnostic observers cannot change the stream's admission or recovery.
		}
	};
}

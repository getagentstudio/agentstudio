import type {
	BridgeViewerOwnedViteServer,
	BridgeViewerViteServerCleanupProof,
} from '../verify-bridge-viewer-worktree-dev-server/product-only-real-router-regression.ts';
import type {
	startOwnedBridgeDevelopmentServer,
	OwnedBridgeDevelopmentServerCleanup,
} from './bridge-development-server-process.ts';

export interface BridgeWebOwnedProductDataClient {
	readonly close: () => Promise<void>;
	readonly abort: (reason: unknown) => Promise<void>;
}

export type BridgeWebViteLateListenerRetirement =
	| { readonly kind: 'not-required' }
	| { readonly kind: 'closed'; readonly closeEventObserved: true }
	| { readonly kind: 'failed'; readonly closeEventObserved: boolean };

export interface BridgeWebTestLaunchCleanup {
	readonly backend: OwnedBridgeDevelopmentServerCleanup | null;
	readonly browserDisconnected: boolean;
	readonly dataRootRemoved: boolean;
	readonly failures: readonly string[];
	readonly viteClosed: boolean;
	readonly lateViteListenerRetirement: BridgeWebViteLateListenerRetirement;
	readonly viteProcess: BridgeViewerViteServerCleanupProof | null;
}

export interface BridgeWebTestLaunchSpec {
	readonly backend?: Omit<
		Parameters<typeof startOwnedBridgeDevelopmentServer>[0],
		'dataRootPath' | 'onSpawn'
	>;
	readonly dataRootPrefix?: string;
	readonly signal?: AbortSignal;
}

export interface BridgeWebTestLaunchDependencies {
	readonly startBackend: typeof startOwnedBridgeDevelopmentServer;
	readonly startViteChild?: typeof BridgeViewerOwnedViteServer.start;
}

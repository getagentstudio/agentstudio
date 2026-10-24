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

export interface BridgeWebTestLaunchCleanup {
	readonly backend: OwnedBridgeDevelopmentServerCleanup | null;
	readonly browserDisconnected: boolean;
	readonly dataRootRemoved: boolean;
	readonly failures: readonly string[];
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
	readonly startBrowserHost?: typeof import('./owned-bridge-web-browser-host.ts').startOwnedBridgeWebBrowserHost;
	readonly startBackend: typeof startOwnedBridgeDevelopmentServer;
	readonly startViteChild?: typeof BridgeViewerOwnedViteServer.start;
}

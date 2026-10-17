import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { createServer } from 'vite';

import type { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';

// Code evaluation only. Never load product config or place a loader cache under
// a launch root: product HTTP, optimization and cache ownership belong to a child.
export async function createBridgeWebVerifierModuleLoader(launch: BridgeWebTestLaunch): Promise<{
	readonly loadModule: (path: string) => Promise<unknown>;
}> {
	const bridgeWebRoot = fileURLToPath(new URL('../../', import.meta.url));
	const acquisition = handleLaunchPromise(
		createServer({
			root: bridgeWebRoot,
			configFile: false,
			cacheDir: join(bridgeWebRoot, 'node_modules/.vite-verifier-module-loader'),
			optimizeDeps: { noDiscovery: true, include: [] },
			server: { hmr: false, ws: false, middlewareMode: true, watch: null },
		}),
		'verifier module loader',
	);
	launch.ownFixture('verifier module loader', async (): Promise<void> => {
		const outcome = await acquisition.settled;
		if (outcome.kind === 'succeeded') await outcome.value.close();
	});
	const loader = await launch.runStep(
		'verifier module loader acquisition',
		async () => await acquisition.value(),
	);
	return { loadModule: async (path: string): Promise<unknown> => await loader.ssrLoadModule(path) };
}

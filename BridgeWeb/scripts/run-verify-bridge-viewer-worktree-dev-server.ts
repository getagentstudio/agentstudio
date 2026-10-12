import { BridgeWebTestLaunch } from './dev-server/bridge-web-test-launch.ts';
import { createBridgeWebVerifierModuleLoader } from './dev-server/bridge-web-verifier-module-loader.ts';

const launch = await BridgeWebTestLaunch.start();
try {
	const moduleLoader = await createBridgeWebVerifierModuleLoader(launch);
	await launch.run(async (): Promise<void> => {
		await launch.runStep('verifier module and owned stack', async (): Promise<void> => {
			const entry = await moduleLoader.loadModule(
				'/scripts/verify-bridge-viewer-worktree-dev-server.ts',
			);
			if (
				typeof entry !== 'object' ||
				entry === null ||
				!('runBridgeViewerWorktreeVerifier' in entry) ||
				typeof entry.runBridgeViewerWorktreeVerifier !== 'function'
			)
				throw new Error('Expected verifier entrypoint');
			await entry.runBridgeViewerWorktreeVerifier(
				async (productLaunch: BridgeWebTestLaunch): Promise<unknown> => {
					// A fresh evaluation captures this cold lifecycle's origin, not
					// the entry module's or a previous cohort launch's configuration.
					const runnerLoader = await createBridgeWebVerifierModuleLoader(productLaunch);
					return await runnerLoader.loadModule(
						'/scripts/verify-bridge-viewer-worktree-dev-server/runner.ts',
					);
				},
			);
		});
	});
} finally {
	await launch.dispose();
}
